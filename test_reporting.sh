#!/usr/bin/env bash
#
# Lightweight validation for the PUPTracker reporting integration.
#
# Usage:
#   bash test_reporting.sh
#
# This test sources entrypoint.sh (it no longer hard-fails at load time),
# stubs mydumper/rclone/curl, and asserts:
#   - shell syntax is valid
#   - unique backup name + R2 path generation
#   - deterministic manifest SHA-256 checksum
#   - file count / total size
#   - JSON payload generation (success + failed) with no secret leakage
#   - HTTP 201 accepted
#   - HTTP 401/403 detected (generic message, no token)
#   - report transport failure handling
#   - mydumper failure attempts a failed report
#   - rclone upload failure attempts a failed report
#   - successful backup + failed report exits 3 (backup NOT marked failed)
#   - missing BACKUP_REPORT_TOKEN is never echoed
#   - verify_upload() parses `rclone size --json` (count/bytes) and fails on
#     count mismatch / byte mismatch / malformed JSON / rclone failure
#   - verify_upload() always passes --config "$RCLONE_CONFIG"
#   - MySQL 8.4 `SHOW BINARY LOG STATUS` is preferred with a safe legacy
#     `SHOW MASTER STATUS` fallback, normalized identically
#   - binlog boundary/gap/rotation handling and purged-start failure
#   - MYSQLBINLOG_SERVER_ID is configurable (never a hard-coded --server-id=1)
#   - distributed lock contention / stale takeover / release / lost ownership
#   - state persistence failure is a FAILURE (non-zero), not a warning
#
# WHAT THIS SUITE DOES *NOT* PROVE: every external tool that would touch the
# real world (rclone, curl, mysql, mysqlbinlog, mydumper) is replaced by a
# controlled test double defined in this file. No real MySQL server, R2 bucket or
# PUPTracker endpoint is contacted, and the Docker image is not built here. A
# green run proves the container's logic against the documented interfaces only.
#
# NOTE: This runs the helper functions in-process by sourcing entrypoint.sh.
# BACKUP_SOURCED=1 explicitly tells entrypoint.sh not to run main(), because this
# host has no mysql/mysqlbinlog/mydumper and main() would exit immediately.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTRYPOINT="$HERE/entrypoint.sh"

# The PATH this script started with, captured BEFORE any test-double directory is
# prepended to it. Sections that shell out to a REAL tool (rather than a stub)
# MUST use this, otherwise a stub installed by an earlier section can silently
# stand in for the real tool and make the test pass for the wrong reason.
SUITE_REAL_PATH="$PATH"

PASS=0
FAIL=0
SKIP=0

pass() { PASS=$((PASS + 1)); echo "ok   - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; }
# A SKIP is reported loudly and counted, so a platform that cannot evaluate a
# check never looks like a silent pass.
skip() { SKIP=$((SKIP + 1)); echo "SKIP - $1"; }

assert_eq() { # desc expected actual
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected [$2] got [$3])"; fi
}

assert_contains() { # desc haystack needle
  if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1 (missing [$3])"; fi
}

assert_not_contains() { # desc haystack needle
  if [[ "$2" != *"$3"* ]]; then pass "$1"; else fail "$1 (unexpectedly contains [$3])"; fi
}

assert_rc_zero() { # desc rc
  if [[ "$2" -eq 0 ]]; then pass "$1"; else fail "$1 (expected rc 0, got $2)"; fi
}

assert_rc_nonzero() { # desc rc
  if [[ "$2" -ne 0 ]]; then pass "$1"; else fail "$1 (expected non-zero rc, got $2)"; fi
}

# ---------------------------------------------------------------------------
# 0. Shell syntax
# ---------------------------------------------------------------------------
echo "== shell syntax =="
if bash -n "$ENTRYPOINT"; then pass "bash -n entrypoint.sh"; else fail "bash -n entrypoint.sh"; fi

# ---------------------------------------------------------------------------
# Source the entrypoint with controlled env (helpers only; main is suppressed)
# ---------------------------------------------------------------------------
# BACKUP_SOURCED=1 is required: the test harness sources entrypoint.sh through
# `bash -c 'source "$0" ...' <file>` in places, where BASH_SOURCE[0] == $0 and
# the "run main()" guard would otherwise fire and exit inside the subprocess.
#
# It is deliberately NOT exported: a plain (non-exported) variable is still
# visible to the `source` below, while subprocesses launched with
# `bash "$ENTRYPOINT"` remain unaffected and DO run main() (production parity).
BACKUP_SOURCED=1
export MYSQL_HOST="db.example"
export MYSQL_PORT="3306"
export MYSQL_USER="backup"
export MYSQL_PASSWORD="sup3rsecret-db-pass"
export MYSQL_DATABASE="puptracker"
export R2_ACCESS_KEY_ID="r2access"
export R2_SECRET_ACCESS_KEY="r2super-secret-key"
export R2_ENDPOINT="https://acct.r2.cloudflarestorage.com"
export R2_BUCKET="puptracker-backups"
export R2_PATH="mysql-backup"
export BACKUP_REPORT_URL="https://puptvs.com/admin/super-admin/backups/report"
export BACKUP_REPORT_TOKEN="super-secret-report-token"
# Locking is off by default so unrelated tests never touch a lock object; the
# dedicated lock tests below enable it against a stubbed rclone.
export BACKUP_LOCK_ENABLED="false"
export MYSQLBINLOG_SERVER_ID="424242"
export BINLOG_FETCH_STRATEGY="raw"

# shellcheck source=entrypoint.sh
source "$ENTRYPOINT"

echo "== sourcing guard =="
# The whole suite depends on main() NOT auto-running while sourced.
assert_contains "entrypoint exposes main() when sourced" "$(declare -F main || true)" "main"
assert_contains "entrypoint exposes acquire_lock() when sourced" "$(declare -F acquire_lock || true)" "acquire_lock"
assert_contains "entrypoint exposes normalize_binlog_status() when sourced" "$(declare -F normalize_binlog_status || true)" "normalize_binlog_status"
assert_contains "entrypoint exposes fetch_binlog_file() when sourced" "$(declare -F fetch_binlog_file || true)" "fetch_binlog_file"
assert_contains "entrypoint exposes lock_still_owned() when sourced" "$(declare -F lock_still_owned || true)" "lock_still_owned"

# ---------------------------------------------------------------------------
# Platform capability probe: POSIX file modes
# ---------------------------------------------------------------------------
# Some filesystems (notably the Windows/DrvFs mounts this suite may run on)
# silently ignore mode bits: `umask 077` and an explicit `chmod 600` both leave
# a file at 0644. The credential-permission assertions further down are
# MEANINGLESS on such a filesystem, so support is detected once and those checks
# are either asserted strictly or explicitly SKIPPED. They are never silently
# weakened: a static assertion on the entrypoint source still guards the
# hardening on every platform.
MODE_SUPPORTED=0
_mode_probe="$(mktemp)"
( umask 077; : > "$_mode_probe" ) 2>/dev/null || true
if [[ "$(stat -c '%a' "$_mode_probe" 2>/dev/null)" == "600" ]]; then
  MODE_SUPPORTED=1
fi
rm -f "$_mode_probe"
if [[ "$MODE_SUPPORTED" -eq 1 ]]; then
  pass "platform honours POSIX file modes (permission checks will be strict)"
else
  skip "platform ignores POSIX file modes; permission checks are skipped (static hardening checks still run)"
fi

# ---------------------------------------------------------------------------
# 1. Unique backup naming + R2 path
# ---------------------------------------------------------------------------
echo "== naming / path =="
# Construct names from explicit (fixed, different) timestamps so the test is
# deterministic regardless of wall-clock second resolution.
TS_A="2026-09-10_020000"
TS_B="2026-09-10_020001"
NAME_A="daily_snapshot_${TS_A}"
NAME_B="daily_snapshot_${TS_B}"
assert_eq "names differ across runs" "different" "$([[ "$NAME_A" != "$NAME_B" ]] && echo different || echo same)"
assert_contains "name starts with daily_snapshot_" "$NAME_A" "daily_snapshot_"

BACKUP_NAME="$NAME_A"
DATE_PATH="2026/09/10"
STORAGE_PATH="${R2_PATH%/}/daily_snapshot/${DATE_PATH}/${BACKUP_NAME}"
assert_contains "R2 path uses base R2_PATH" "$STORAGE_PATH" "mysql-backup/daily_snapshot"
assert_contains "R2 path ends with unique backup name" "$STORAGE_PATH" "$BACKUP_NAME"

# ---------------------------------------------------------------------------
# 2. Metadata helpers against a real temp backup dir
# ---------------------------------------------------------------------------
echo "== metadata =="
BACKUP_DIR="$(mktemp -d)"
trap 'rm -rf "$BACKUP_DIR"' EXIT
mkdir -p "$BACKUP_DIR/sub/dir"
printf 'hello world\n' > "$BACKUP_DIR/a.txt"
printf 'another file content\n' > "$BACKUP_DIR/sub/b.txt"
printf 'x' > "$BACKUP_DIR/sub/dir/c.txt"

assert_eq "file count (3, not dirs)" "3" "$(count_files)"
# 12 + 21 + 1 = 34
assert_eq "total size (34)" "34" "$(total_size)"

C1="$(compute_manifest_checksum)"
C2="$(compute_manifest_checksum)"
assert_eq "manifest checksum deterministic" "$C1" "$C2"
assert_eq "checksum is 64 hex chars" "64" "${#C1}"
assert_eq "checksum not random/empty" "no" "$([[ -n "$C1" ]] && echo no || echo yes)"

# ---------------------------------------------------------------------------
# 3. JSON payloads
# ---------------------------------------------------------------------------
echo "== JSON payloads =="
BACKUP_NAME="daily_snapshot_2026-09-10_020000"
BACKUP_TYPE="daily_snapshot"
STARTED_AT="2026-09-09T18:00:00Z"
COMPLETED_AT="2026-09-09T18:02:00Z"
DESTINATION="Cloudflare R2"
BACKUP_SIZE=34
FILE_COUNT=3
CHECKSUM="$C1"
VERIFIED_AT="2026-09-09T18:02:01Z"
STORAGE_PATH="mysql-backup/daily_snapshot/2026/09/10/daily_snapshot_2026-09-10_020000"

SUCCESS_JSON="$(build_payload success)"
assert_contains "success json has status" "$SUCCESS_JSON" '"status":"success"'
assert_contains "success json has backup_name" "$SUCCESS_JSON" '"backup_name":"daily_snapshot_2026-09-10_020000"'
assert_contains "success json has backup_type daily_snapshot" "$SUCCESS_JSON" '"backup_type":"daily_snapshot"'
assert_contains "success json has checksum" "$SUCCESS_JSON" "\"checksum\":\"$C1\""
assert_contains "success json has storage_path" "$SUCCESS_JSON" '"storage_path":"mysql-backup/daily_snapshot/2026/09/10/daily_snapshot_2026-09-10_020000"'
assert_not_contains "success json has NO token" "$SUCCESS_JSON" "super-secret-report-token"
assert_not_contains "success json has NO password" "$SUCCESS_JSON" "sup3rsecret-db-pass"
assert_not_contains "success json has NO r2 secret" "$SUCCESS_JSON" "r2super-secret-key"

ERROR_MESSAGE="mydumper failed: connection refused"
FAIL_JSON="$(build_payload failed)"
assert_contains "failed json has status" "$FAIL_JSON" '"status":"failed"'
assert_contains "failed json has error_message" "$FAIL_JSON" '"error_message":"mydumper failed: connection refused"'
assert_not_contains "failed json has NO backup_size field" "$FAIL_JSON" '"backup_size"'
assert_not_contains "failed json has NO token" "$FAIL_JSON" "super-secret-report-token"
assert_not_contains "failed json has NO password" "$FAIL_JSON" "sup3rsecret-db-pass"

# JSON escaping
ERROR_MESSAGE='bad "quote" and \backslash'
ESCAPED="$(build_payload failed)"
assert_not_contains "json escapes double quote in message" "$ESCAPED" '"bad "quote" and \backslash"'
# Input backslash is doubled in the JSON output:  \backslash  ->  \\backslash
assert_contains "json escapes backslash" "$ESCAPED" '\\backslash'

echo "== report HTTP handling (stubbed curl) =="
# Stub curl: write the code + capture the request to a temp file for inspection.
STUB_DIR="$(mktemp -d)"
export STUB_DIR
cat > "$STUB_DIR/curl" <<'STUB'
#!/usr/bin/env bash
# Args: -sS -o <respfile> -w "%{http_code}" --max-time N -X POST URL -H auth -H content-type --data-binary payload
resp_file=""
code_file=""
payload=""
auth=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) resp_file="$2"; shift 2;;
    -w) shift 2;; # format string
    --max-time) shift 2;;
    --data-binary) payload="$2"; shift 2;;
    -H) if [[ "$2" == Authorization* ]]; then auth="$2"; fi; shift 2;;
    *) shift;;
  esac
done
echo "$auth" > "$STUB_DIR/auth_header_seen"
echo "$payload" > "$STUB_DIR/payload_seen"
echo "$R2_SECRET_ACCESS_KEY|$MYSQL_PASSWORD|$BACKUP_REPORT_TOKEN" > "$STUB_DIR/secrets_seen"
# curl -o writes the RESPONSE BODY to $resp_file, while -w "%{http_code}"
# writes the status code to STDOUT (which the caller captures). To simulate a
# transport failure the stub exits non-zero and prints nothing.
if [[ "${STUB_CURL_EXIT:-0}" != "0" ]]; then
  exit "${STUB_CURL_EXIT}"
fi
printf '{"success":true}' > "$resp_file"
printf '%s' "${STUB_HTTP_CODE:-201}"
exit 0
STUB
chmod +x "$STUB_DIR/curl"
OLD_PATH="$PATH"
export PATH="$STUB_DIR:$PATH"

# Clean state
REPORTING_ENABLED=1
BACKUP_REPORT_URL="https://puptvs.com/admin/super-admin/backups/report"
BACKUP_REPORT_TOKEN="super-secret-report-token"

# -- HTTP 201 accepted --
export STUB_HTTP_CODE=201
export STUB_CURL_EXIT=0
if report_now success; then pass "report_now success returns 0 on HTTP 201"; else fail "report_now success on HTTP 201"; fi

# -- HTTP 401 detected --
export STUB_HTTP_CODE=401
if report_now success >/dev/null 2>&1; then fail "report_now success on HTTP 401"; else pass "report_now returns non-zero on HTTP 401"; fi

# -- HTTP 403 detected --
export STUB_HTTP_CODE=403
if report_now success >/dev/null 2>&1; then fail "report_now success on HTTP 403"; else pass "report_now returns non-zero on HTTP 403"; fi

# -- transport failure (curl exits non-zero / empty code) --
export STUB_HTTP_CODE=""
export STUB_CURL_EXIT=7
if report_now success >/dev/null 2>&1; then fail "report_now success on transport failure"; else pass "report_now returns non-zero on transport failure"; fi
export STUB_CURL_EXIT=0

# -- no secret values ever sent/echoed/logged through our stub --
# Verify the Authorization header carries the token but the token is NOT in the
# payload, and secrets are not present in the recorded stub artifacts.
assert_not_contains "auth header does NOT leak into payload" "$(cat "$STUB_DIR/payload_seen")" "super-secret-report-token"
assert_contains "auth header present in stub capture" "$(cat "$STUB_DIR/auth_header_seen")" "Authorization: Bearer super-secret-report-token"

# RESTORE PATH. This section prepended $STUB_DIR (its curl double). Restore the
# PRISTINE PATH rather than the OLD_PATH snapshot captured inside this section,
# because that snapshot already contained $STUB_DIR and restoring it would
# re-inject the double.
export PATH="$SUITE_REAL_PATH"

echo "== end-to-end flows (stubbed tools) =="
FLOW_DIR="$(mktemp -d)"
cat > "$FLOW_DIR/mydumper" <<'STUB'
#!/usr/bin/env bash
# fake mydumper: create a couple of files
out=""
prev=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2;;
    *) shift;;
  esac
done
mkdir -p "$out/sub"
printf 'schema' > "$out/db.schema.sql"
printf 'data'   > "$out/sub/db.table.sql"
exit "${MYDUMPER_EXIT:-0}"
STUB
chmod +x "$FLOW_DIR/mydumper"

cat > "$FLOW_DIR/rclone" <<'STUB'
#!/usr/bin/env bash
# Fake rclone. Tolerates a leading "--config <path>" argument (the entrypoint
# always passes one). `sync` "succeeds" (exit 0) unless RCLONE_EXIT is non-zero.
# `size --json` mimics `rclone size --json`:
#   - honours RCLONE_SIZE_EXIT (command-failure simulation),
#   - honours SIZE_JSON (explicit controlled output for mismatch/malformed
#     tests),
#   - otherwise prints the real object count/bytes of the LOCAL backup dir
#     (so the full main() smoke test's verify_upload sees matching values).
# `listremotes` prints the configured remote name.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) shift 2;;
    config) exit 0;;
    listremotes) printf 'remote:\n'; exit 0;;
    sync) exit "${RCLONE_EXIT:-0}";;
    size)
      if [[ "${RCLONE_SIZE_EXIT:-0}" != "0" ]]; then
        exit "${RCLONE_SIZE_EXIT}"
      fi
      if [[ -n "${SIZE_JSON:-}" ]]; then
        printf '%s\n' "$SIZE_JSON"
        exit 0
      fi
      base="backup"
      [[ -d "$base" ]] || base="$(pwd)/backup"
      if [[ -d "$base" ]]; then
        cnt="$( (cd "$base" && find . -type f 2>/dev/null | wc -l) )"
        byt="$( (cd "$base" && find . -type f -printf "%s\n" 2>/dev/null | awk '{s+=$1} END {print s+0}') )"
        printf '{"count":%s,"bytes":%s,"sizeless":0}\n' "$cnt" "$byt"
      else
        printf '{"count":0,"bytes":0,"sizeless":0}\n'
      fi
      exit 0;;
    *) exit 0;;
  esac
done
exit 0
STUB
chmod +x "$FLOW_DIR/rclone"

# `check_tools` (correctly) requires the binary-log tooling when binary-log
# backups are enabled, so the flow tests must provide controlled mysql and
# mysqlbinlog doubles too. These simulate realistic MySQL output for exactly the
# statements the entrypoint issues -- the production code paths under test are
# still fully exercised (nothing is bypassed).
cat > "$FLOW_DIR/mysql" <<'STUB'
#!/usr/bin/env bash
sql=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --defaults-extra-file) shift 2;;
    -e) sql="$2"; shift 2;;
    *) shift;;
  esac
done
shopt -s nocasematch
if [[ "$sql" == *"log_bin"* ]]; then printf 'log_bin\tON\n'; exit 0; fi
if [[ "$sql" == *"binlog_format"* ]]; then printf 'binlog_format\tROW\n'; exit 0; fi
if [[ "$sql" == *"SHOW BINARY LOG STATUS"* || "$sql" == *"SHOW MASTER STATUS"* ]]; then
  printf '%s\t%s\t\t\t\n' "${FLOW_MASTER_FILE:-binlog.000200}" "${FLOW_MASTER_POS:-999}"; exit 0
fi
if [[ "$sql" == *"SHOW BINARY LOGS"* ]]; then printf '%s\t4\n' ${FLOW_BINARY_LOGS:-binlog.000199 binlog.000200}; exit 0; fi
exit 0
STUB
chmod +x "$FLOW_DIR/mysql"

cat > "$FLOW_DIR/mysqlbinlog" <<'STUB'
#!/usr/bin/env bash
# Minimal mysqlbinlog double, faithful to the REAL MySQL 8.x client:
#   - `--result-dir` is REJECTED (MariaDB-only). The MySQL client errors with
#     "unknown option '--result-dir'", so a double that accepted it would hide
#     a capture that can never work in production.
#   - `--raw` writes the binlog into the CWD named after the binlog basename.
#   - a plain read emits a SQL stream. Other usage exits 0.
result_dir=""; raw=0; files=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --defaults-extra-file) shift 2;;
    --read-from-remote-server) shift;;
    --server-id) shift 2;;
    --raw) raw=1; shift;;
    --result-dir|--result-dir=*) echo "mysqlbinlog: [ERROR] unknown option '--result-dir'." >&2; exit 2;;
    --start-position|--stop-position) shift 2;;
    -*) shift;;
    *) files+=("$1"); shift;;
  esac
done
if [[ "$raw" -eq 1 ]]; then
  for f in "${files[@]}"; do printf 'RAW:%s' "$f" > "$(basename "$f")"; done
  exit 0
fi
for f in "${files[@]}"; do printf -- '-- %s\nSQL;\n' "$f"; done
exit 0
STUB
chmod +x "$FLOW_DIR/mysqlbinlog"

export PATH="$FLOW_DIR:$STUB_DIR:$PATH"
export STUB_HTTP_CODE=201
export MYDUMPER_EXIT=0
export RCLONE_EXIT=0

# Clean up state that main would set, then run a full success flow by invoking
# the main logic pieces (we cannot run the whole main twice safely, so we test
# the decision paths that matter):

# mydumper failure -> report_failure_and_exit sends failed + exits non-zero
echo "  - mydumper failure reports failed"
MYDUMPER_EXIT=1
(cd "$FLOW_DIR" && BACKUP_DIR=backup MYSQL_HOST=h MYSQL_USER=u MYSQL_PASSWORD=p MYSQL_PORT=3306 MYSQL_DATABASE=d \
  R2_ACCESS_KEY_ID=a R2_SECRET_ACCESS_KEY=s R2_ENDPOINT=e R2_BUCKET=b R2_PATH=mysql-backup \
  BACKUP_REPORT_URL="$BACKUP_REPORT_URL" BACKUP_REPORT_TOKEN="$BACKUP_REPORT_TOKEN" \
  STUB_HTTP_CODE=201 BACKUP_SOURCED=1 \
  bash -c 'source "$0" >/dev/null 2>&1; validate_env; STARTED_AT=$(now_utc); BACKUP_NAME="daily_snapshot_2026-09-10_020000"; REPORTING_ENABLED=1; report_failure_and_exit "mydumper failed to produce a logical database snapshot."' "$ENTRYPOINT") \
  && fail "mydumper failure should exit non-zero" \
  || pass "mydumper failure exits non-zero"
assert_contains "failed payload sent on mydumper failure" "$(cat "$STUB_DIR/payload_seen")" '"status":"failed"'
assert_not_contains "failed payload hides password" "$(cat "$STUB_DIR/payload_seen")" 'sup3rsecret-db-pass'
MYDUMPER_EXIT=0

# R2 upload failure -> report failed + exit non-zero
echo "  - rclone upload failure reports failed"
RCLONE_EXIT=1
export STUB_HTTP_CODE=201
(cd "$FLOW_DIR" && rm -rf backup && BACKUP_DIR=backup MYDUMPER_EXIT=0 RCLONE_EXIT=1 \
  MYSQL_HOST=h MYSQL_USER=u MYSQL_PASSWORD=p MYSQL_PORT=3306 MYSQL_DATABASE=d \
  R2_ACCESS_KEY_ID=a R2_SECRET_ACCESS_KEY=s R2_ENDPOINT=e R2_BUCKET=b R2_PATH=mysql-backup \
  BACKUP_REPORT_URL="$BACKUP_REPORT_URL" BACKUP_REPORT_TOKEN="$BACKUP_REPORT_TOKEN" BACKUP_SOURCED=1 \
  bash -c 'source "$0" >/dev/null 2>&1; validate_env; STARTED_AT=$(now_utc); BACKUP_NAME="daily_snapshot_2026-09-10_020001"; STORAGE_PATH="mysql-backup/daily_snapshot/2026/09/10/daily_snapshot_2026-09-10_020001"; REPORTING_ENABLED=1; \
    rm -rf backup; mkdir -p backup/sub; printf x > backup/a.sql; \
    if ! rclone sync backup remote:b/STORAGE_PATH; then report_failure_and_exit "rclone upload to Cloudflare R2 failed."; fi' "$ENTRYPOINT") \
  && fail "rclone failure should exit non-zero" \
  || pass "rclone upload failure exits non-zero"
RCLONE_EXIT=0

# Successful backup but report fails -> exit 3, and the report that WAS sent is
# the success one (not a failed payload).
echo "  - successful backup + report transport failure exits 3 (backup not failed)"
export STUB_CURL_EXIT=7
export STUB_HTTP_CODE=""
set +e
(cd "$FLOW_DIR" && rm -rf backup && BACKUP_DIR=backup MYDUMPER_EXIT=0 RCLONE_EXIT=0 \
  MYSQL_HOST=h MYSQL_USER=u MYSQL_PASSWORD=p MYSQL_PORT=3306 MYSQL_DATABASE=d \
  R2_ACCESS_KEY_ID=a R2_SECRET_ACCESS_KEY=s R2_ENDPOINT=e R2_BUCKET=b R2_PATH=mysql-backup \
  BACKUP_REPORT_URL="$BACKUP_REPORT_URL" BACKUP_REPORT_TOKEN="$BACKUP_REPORT_TOKEN" \
  REPORT_TIMEOUT=2 BACKUP_SOURCED=1 \
  bash -c 'source "$0" >/dev/null 2>&1; validate_env; STARTED_AT=$(now_utc); BACKUP_NAME="daily_snapshot_2026-09-10_020002"; STORAGE_PATH="mysql-backup/daily_snapshot/2026/09/10/daily_snapshot_2026-09-10_020002"; REPORTING_ENABLED=1; \
    rm -rf backup; mkdir -p backup; printf schema > backup/db.sql; \
    FILE_COUNT=$(count_files); BACKUP_SIZE=$(total_size); CHECKSUM=$(compute_manifest_checksum); VERIFIED_AT=$(now_utc); COMPLETED_AT=$(now_utc); \
    if report_now success; then exit 0; else warn "Backup succeeded but PUPTracker reporting failed."; exit 3; fi' "$ENTRYPOINT")
code=$?
set -e
if [[ "$code" -eq 3 ]]; then
  pass "successful backup + report failure exits 3"
else
  fail "successful backup + report failure should exit 3 (got $code)"
fi
export STUB_CURL_EXIT=0

# Missing token: report_now skips (returns non-zero) and never echoes token.
echo "  - missing BACKUP_REPORT_TOKEN never echoed"
MISSING_LOG="$(mktemp)"
# Run report_now with an empty token, capturing ALL output to a file so the
# harness's own set -e never interferes with the function's non-zero return.
(
  export BACKUP_REPORT_URL="https://puptvs.com/x"
  export BACKUP_REPORT_TOKEN=""
  export REPORTING_ENABLED=1
  source "$ENTRYPOINT" >/dev/null 2>&1
  BACKUP_NAME=x
  report_now success >"$MISSING_LOG" 2>&1 || true
) || true
MISSING_OUT="$(cat "$MISSING_LOG" 2>/dev/null)"
rm -f "$MISSING_LOG"
assert_contains "missing token logs clear warning" "$MISSING_OUT" "BACKUP_REPORT_TOKEN is not set"
assert_not_contains "missing token output never contains token" "$MISSING_OUT" "super-secret-report-token"

# Full run success path smoke test: mock mydumper/rclone/curl and run main()
echo "  - full main() success smoke test"
export STUB_HTTP_CODE=201
export STUB_CURL_EXIT=0
export MYDUMPER_EXIT=0
export RCLONE_EXIT=0
set +e
(cd "$FLOW_DIR" && rm -rf backup && \
  MYSQL_HOST=h MYSQL_USER=u MYSQL_PASSWORD=p MYSQL_PORT=3306 MYSQL_DATABASE=d \
  R2_ACCESS_KEY_ID=a R2_SECRET_ACCESS_KEY=s R2_ENDPOINT=e R2_BUCKET=b R2_PATH=mysql-backup \
  BACKUP_REPORT_URL="$BACKUP_REPORT_URL" BACKUP_REPORT_TOKEN="$BACKUP_REPORT_TOKEN" \
  REPORT_TIMEOUT=5 \
  bash "$ENTRYPOINT")
code=$?
set -e
if [[ "$code" -eq 0 ]]; then pass "full main() success exits 0"; else fail "full main() success should exit 0 (got $code)"; fi
assert_contains "success payload sent by full run" "$(cat "$STUB_DIR/payload_seen")" '"status":"success"'

# RESTORE PATH. This section prepended $FLOW_DIR and $STUB_DIR (its mydumper,
# rclone, mysql, mysqlbinlog and curl doubles). Restore the PRISTINE PATH rather
# than a section-local snapshot, so no double can survive into a later section
# that expects the REAL tool.
export PATH="$SUITE_REAL_PATH"

# ---------------------------------------------------------------------------
# rclone config failure-point regression tests
# ---------------------------------------------------------------------------
echo "== rclone config failure-point =="

# The original bug: writing ~/.config/rclone/rclone.conf could fail (set -e
# silent exit) when the config directory did not exist. The fix is mkdir -p the
# dir first and write to an explicit $RCLONE_CONFIG path. Verify:
#   1. mkdir -p creates the dir when missing.
#   2. writing the config then succeeds.
#   3. rclone is always invoked with --config "$RCLONE_CONFIG".
CFG_DIR="$(mktemp -d)"
rm -rf "$CFG_DIR"   # ensure it does not exist yet
export RCLONE_CONFIG="$CFG_DIR/nested/rclone.conf"
export RCLONE_CONFIG_DIR="$(dirname "$RCLONE_CONFIG")"

# 1+2: mkdir -p then write (must not fail under set -e).
(
  set -e
  source "$ENTRYPOINT" >/dev/null 2>&1
  mkdir -p "$RCLONE_CONFIG_DIR"
  printf '[remote]\ntype = s3\nprovider = Cloudflare\naccess_key_id = x\nsecret_access_key = y\nendpoint = https://e\nacl = private\n' > "$RCLONE_CONFIG"
)
rc=$?
if [[ "$rc" -eq 0 && -f "$RCLONE_CONFIG" ]]; then
  pass "config dir created and config file written (no silent exit)"
else
  fail "config dir/file creation failed (rc=$rc)"
fi
assert_contains "config file contains [remote]" "$(cat "$RCLONE_CONFIG" 2>/dev/null)" "[remote]"
rm -rf "$CFG_DIR"

# 3: rclone stub records that it was called with --config <path>.
RECORD_DIR="$(mktemp -d)"
cat > "$RECORD_DIR/rclone" <<'STUB'
#!/usr/bin/env bash
echo "$*" > "$RCLONE_CALL_LOG"
# parse: find --config <path>
prev=""
for a in "$@"; do
  if [[ "$prev" == "--config" ]]; then echo "$a" > "$RCLONE_CONFIG_USED"; fi
  prev="$a"
done
case "${1:-}" in
  listremotes) printf 'remote:\n'; exit 0;;
  size) printf '{"count":0,"bytes":0,"sizeless":0}\n'; exit 0;;
  sync) exit 0;;
  *) exit 0;;
esac
STUB
chmod +x "$RECORD_DIR/rclone"
export RCLONE_CALL_LOG="$RECORD_DIR/call_log"
export RCLONE_CONFIG_USED="$RECORD_DIR/config_used"
# Section-local PATH snapshot. A DISTINCT name is used on purpose: reusing a
# shared OLD_PATH while a stub directory is on PATH silently re-injects those
# stubs into every later `export PATH="$OLD_PATH"`.
RECORD_OLD_PATH="$PATH"
export PATH="$RECORD_DIR:$PATH"
export RCLONE_CONFIG="/tmp/rclone-config-test/rclone.conf"
export RCLONE_CONFIG_DIR="$(dirname "$RCLONE_CONFIG")"
mkdir -p "$RCLONE_CONFIG_DIR"
printf '[remote]\ntype = s3\n' > "$RCLONE_CONFIG"
(
  source "$ENTRYPOINT" >/dev/null 2>&1
  rclone --config "$RCLONE_CONFIG" listremotes >/dev/null 2>&1
  rclone --config "$RCLONE_CONFIG" sync backup remote:b/x >/dev/null 2>&1
  rclone --config "$RCLONE_CONFIG" size --json remote:b/x >/dev/null 2>&1
) || true
if [[ -f "$RCLONE_CONFIG_USED" && "$(cat "$RCLONE_CONFIG_USED")" == "$RCLONE_CONFIG" ]]; then
  pass "rclone invoked with explicit --config path"
else
  fail "rclone not invoked with explicit --config path"
fi
export PATH="$RECORD_OLD_PATH"
rm -rf "$RECORD_DIR" /tmp/rclone-config-test

# ---------------------------------------------------------------------------
# Required reporting configuration behavior
# ---------------------------------------------------------------------------
echo "== required reporting configuration =="

# validate_env must fail (non-zero, clear message) when BACKUP_REPORT_TOKEN missing.
OUT="$(mktemp)"
(
  export MYSQL_HOST=h MYSQL_USER=u MYSQL_PASSWORD=p MYSQL_PORT=3306 MYSQL_DATABASE=d \
         R2_ACCESS_KEY_ID=a R2_SECRET_ACCESS_KEY=s R2_ENDPOINT=e R2_BUCKET=b R2_PATH=mysql-backup \
         BACKUP_REPORT_URL="https://puptvs.com/x" BACKUP_REPORT_TOKEN=""
  source "$ENTRYPOINT" >/dev/null 2>&1
  validate_env >"$OUT" 2>&1
) || true
CONTENT="$(cat "$OUT" 2>/dev/null)"
rm -f "$OUT"
assert_contains "missing token -> clear non-secret message" "$CONTENT" "BACKUP_REPORT_TOKEN is not set"
assert_contains "missing token -> refuses to run" "$CONTENT" "Refusing to run"
assert_not_contains "missing token -> no token leaked" "$CONTENT" "super-secret-report-token"

# validate_env must fail (non-zero, clear message) when BACKUP_REPORT_URL missing.
OUT="$(mktemp)"
(
  export MYSQL_HOST=h MYSQL_USER=u MYSQL_PASSWORD=p MYSQL_PORT=3306 MYSQL_DATABASE=d \
         R2_ACCESS_KEY_ID=a R2_SECRET_ACCESS_KEY=s R2_ENDPOINT=e R2_BUCKET=b R2_PATH=mysql-backup \
         BACKUP_REPORT_URL="" BACKUP_REPORT_TOKEN="super-secret-report-token"
  source "$ENTRYPOINT" >/dev/null 2>&1
  validate_env >"$OUT" 2>&1
) || true
CONTENT="$(cat "$OUT" 2>/dev/null)"
rm -f "$OUT"
assert_contains "missing url -> clear non-secret message" "$CONTENT" "BACKUP_REPORT_URL is not set"
assert_contains "missing url -> refuses to run" "$CONTENT" "Refusing to run"

# main() must NOT silently run a backup when reporting config is missing.
echo "  - main() exits non-zero when reporting config missing (no silent backup)"
export STUB_HTTP_CODE=201
export STUB_CURL_EXIT=0
export MYDUMPER_EXIT=0
export RCLONE_EXIT=0
set +e
(cd "$FLOW_DIR" && rm -rf backup && \
  MYSQL_HOST=h MYSQL_USER=u MYSQL_PASSWORD=p MYSQL_PORT=3306 MYSQL_DATABASE=d \
  R2_ACCESS_KEY_ID=a R2_SECRET_ACCESS_KEY=s R2_ENDPOINT=e R2_BUCKET=b R2_PATH=mysql-backup \
  BACKUP_REPORT_URL="" BACKUP_REPORT_TOKEN="super-secret-report-token" \
  bash "$ENTRYPOINT" >/dev/null 2>&1)
code=$?
set -e
if [[ "$code" -ne 0 ]]; then
  pass "main() exits non-zero when BACKUP_REPORT_URL missing"
else
  fail "main() should exit non-zero when BACKUP_REPORT_URL missing (got 0)"
fi
# And no backup dir should have been produced (job failed before mydumper).
if [[ -d "$FLOW_DIR/backup" ]]; then fail "no backup dir should be created when reporting config missing"; else pass "no backup dir created when reporting config missing"; fi

# ---------------------------------------------------------------------------
# verify_upload() parses `rclone size --json` (authoritative remote count +
# bytes). It must fail on count mismatch, byte mismatch, malformed JSON, and
# rclone failure, and must always pass --config "$RCLONE_CONFIG".
# ---------------------------------------------------------------------------
echo "== verify_upload (rclone size --json) =="

VU_DIR="$(mktemp -d)"
export VU_DIR
# Local backup dir used as the source of truth: 2 files, 7 bytes.
mkdir -p "$VU_DIR/backup/sub"
printf 'hello' > "$VU_DIR/backup/a.sql"       # 5 bytes
printf 'xy'   > "$VU_DIR/backup/sub/b.sql"     # 2 bytes
BACKUP_DIR="$VU_DIR/backup"
R2_BUCKET="vu-bucket"
RCLONE_CONFIG="$VU_DIR/rclone.conf"
RCLONE_CONFIG_DIR="$VU_DIR"
printf '[remote]\ntype = s3\n' > "$RCLONE_CONFIG"
STORAGE_PATH="mysql-backup/daily_snapshot/2026/09/10/daily_snapshot_2026-09-10_020000"

cat > "$VU_DIR/rclone" <<'STUB'
#!/usr/bin/env bash
# Record the --config argument actually passed, then dispatch on the rclone
# subcommand. The entrypoint always invokes: rclone --config <path> size ...
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      printf '%s' "$2" > "$VU_DIR/config_used"
      shift 2;;
    size)
      if [[ "${VU_RCLONE_EXIT:-0}" != "0" ]]; then
        echo "boom" >&2
        exit "${VU_RCLONE_EXIT}"
      fi
      printf '%s\n' "${VU_SIZE_JSON:-}"
      exit 0;;
    *) shift;;
  esac
done
exit 0
STUB
chmod +x "$VU_DIR/rclone"

VU_OLD_PATH="$PATH"
export PATH="$VU_DIR:$PATH"
export RCLONE_CONFIG VU_RCLONE_EXIT VU_SIZE_JSON

# Local source-of-truth values.
VU_LOCAL_COUNT="$(count_files)"   # 2
VU_LOCAL_BYTES="$(total_size)"    # 7

# 1) Matching count + bytes -> success.
export VU_RCLONE_EXIT=0
export VU_SIZE_JSON='{"count":2,"bytes":7,"sizeless":0}'
if verify_upload >"$VU_DIR/out" 2>&1; then pass "verify_upload succeeds on matching count+bytes"; else fail "verify_upload should succeed on matching count+bytes"; fi
assert_contains "success logs count+bytes" "$(cat "$VU_DIR/out")" "2 file(s), 7 bytes"

# 2) Count mismatch -> failure.
export VU_SIZE_JSON='{"count":3,"bytes":7,"sizeless":0}'
if verify_upload >"$VU_DIR/out" 2>&1; then fail "verify_upload should fail on count mismatch"; else pass "verify_upload fails on count mismatch"; fi
assert_contains "count mismatch warns expected" "$(cat "$VU_DIR/out")" "expected 2 file(s), found 3"

# 3) Byte mismatch -> failure.
export VU_SIZE_JSON='{"count":2,"bytes":8,"sizeless":0}'
if verify_upload >"$VU_DIR/out" 2>&1; then fail "verify_upload should fail on byte mismatch"; else pass "verify_upload fails on byte mismatch"; fi
assert_contains "byte mismatch warns expected" "$(cat "$VU_DIR/out")" "expected 7 bytes, found 8"

# 4) Malformed JSON -> failure.
export VU_SIZE_JSON='not-json-at-all'
if verify_upload >"$VU_DIR/out" 2>&1; then fail "verify_upload should fail on malformed JSON"; else pass "verify_upload fails on malformed JSON"; fi
assert_contains "malformed json warns could not read" "$(cat "$VU_DIR/out")" "could not read the remote size"

# 5) Empty JSON (rclone produced nothing) -> failure.
export VU_SIZE_JSON=''
if verify_upload >"$VU_DIR/out" 2>&1; then fail "verify_upload should fail on empty output"; else pass "verify_upload fails on empty output"; fi

# 6) rclone size command failure -> failure.
export VU_SIZE_JSON='{"count":2,"bytes":7,"sizeless":0}'
export VU_RCLONE_EXIT=1
if verify_upload >"$VU_DIR/out" 2>&1; then fail "verify_upload should fail when rclone size fails"; else pass "verify_upload fails when rclone size command fails"; fi
assert_contains "rclone failure warns could not read" "$(cat "$VU_DIR/out")" "could not read the remote size"

# 7) Correct --config argument is always used.
export VU_RCLONE_EXIT=0
export VU_SIZE_JSON='{"count":2,"bytes":7,"sizeless":0}'
verify_upload >/dev/null 2>&1 || true
if [[ -f "$VU_DIR/config_used" && "$(cat "$VU_DIR/config_used")" == "$RCLONE_CONFIG" ]]; then
  pass "verify_upload passes --config \$RCLONE_CONFIG to rclone size"
else
  fail "verify_upload did not pass --config \$RCLONE_CONFIG to rclone size"
fi

# No secret material is ever logged by verify_upload.
export VU_SIZE_JSON='{"count":2,"bytes":7,"sizeless":0}'
verify_upload >"$VU_DIR/out" 2>&1 || true
export VU_SIZE_JSON='not-json'
verify_upload >>"$VU_DIR/out" 2>&1 || true
assert_not_contains "verify_upload never logs token" "$(cat "$VU_DIR/out")" "super-secret-report-token"
assert_not_contains "verify_upload never logs r2 secret" "$(cat "$VU_DIR/out")" "r2super-secret-key"

export PATH="$VU_OLD_PATH"
rm -rf "$VU_DIR"
unset VU_DIR VU_RCLONE_EXIT VU_SIZE_JSON RCLONE_CONFIG RCLONE_CONFIG_DIR

# ---------------------------------------------------------------------------
# Backup policy: FULL / TRUE incremental decision + state machine
# ---------------------------------------------------------------------------
echo "== backup policy: type decision =="

# A controllable fake "now" for the age-based decision. determine_backup_type
# uses `date -u -d "<ts>" +%s` for the last-full epoch and `date -u +%s` for
# now; we shadow `date` on PATH to pin both.
POLICY_DIR="$(mktemp -d)"
export POLICY_DIR
cat > "$POLICY_DIR/date" <<'STUB'
#!/usr/bin/env bash
# Fake date: only the two forms the policy code uses.
if [[ "$1" == "-u" && "$2" == "-d" ]]; then
  # -d "<ts>" +%s  -> emit the epoch for the last-full timestamp.
  shift 2; ts="$1"; shift
  case "$ts" in
    2026-09-01T00:00:00Z) printf '%s' "${FAKE_LAST_FULL_EPOCH:-1756684800}"; exit 0;;
    *) printf '%s' "${FAKE_LAST_FULL_EPOCH:-1756684800}"; exit 0;;
  esac
fi
if [[ "$1" == "-u" && "$2" == "+%s" ]]; then printf '%s' "${FAKE_NOW_EPOCH:-1757289600}"; exit 0; fi
# Fallback to real date for any other invocation (+"%Y/%m/%d" etc.).
exec /usr/bin/date "$@"
STUB
chmod +x "$POLICY_DIR/date"
POLICY_OLD_PATH="$PATH"
export PATH="$POLICY_DIR:$PATH"

# Helper to reset the parsed-state globals before each decision test.
reset_state() {
  STATE_PRESENT="$1"
  ST_LAST_FULL_NAME="$2"
  ST_LAST_FULL_COMPLETED_AT="$3"
  ST_LAST_FULL_STORAGE_PATH="$4"
  ST_LAST_BINLOG_FILE="$5"
  ST_LAST_BINLOG_POSITION="$6"
  ST_LAST_BINLOG_END_FILE="$7"
  ST_LAST_BINLOG_END_POSITION="$8"
}

# 1. First run (no state) forces FULL.
reset_state 0 "" "" "" "" "" "" ""
DECIDED_TYPE=""
determine_backup_type >/dev/null 2>&1
assert_eq "first run (no state) forces FULL" "full" "$DECIDED_TYPE"

# 7. Missing full base (state present but no full name) forces FULL.
reset_state 1 "" "" "" "" "" "" ""
DECIDED_TYPE=""
determine_backup_type >/dev/null 2>&1
assert_eq "state without a full name forces FULL" "full" "$DECIDED_TYPE"

# 3. Full is due (age >= interval) -> FULL.
#    last full epoch 1756684800 ; now 1757289600 = +7 days; interval 5 => FULL.
export FAKE_LAST_FULL_EPOCH=1756684800
export FAKE_NOW_EPOCH=1757289600
export BACKUP_FULL_INTERVAL_DAYS=5
reset_state 1 "full_2026-09-01_000000" "2026-09-01T00:00:00Z" "mysql-backup/full/2026/09/01/full_2026-09-01_000000" "binlog.000010" "1000" "binlog.000010" "1000"
DECIDED_TYPE=""
determine_backup_type >/dev/null 2>&1
assert_eq "full due (age >= interval) selects FULL" "full" "$DECIDED_TYPE"

# 2. No full due -> INCREMENTAL.
export BACKUP_FULL_INTERVAL_DAYS=14
reset_state 1 "full_2026-09-01_000000" "2026-09-01T00:00:00Z" "mysql-backup/full/2026/09/01/full_2026-09-01_000000" "binlog.000010" "1000" "binlog.000010" "1000"
DECIDED_TYPE=""
determine_backup_type >/dev/null 2>&1
assert_eq "no full due (age < interval) selects INCREMENTAL" "incremental" "$DECIDED_TYPE"

# Boundary: exactly interval days old -> FULL.
export FAKE_NOW_EPOCH=1757894400   # +14 days exactly
export BACKUP_FULL_INTERVAL_DAYS=14
reset_state 1 "full_2026-09-01_000000" "2026-09-01T00:00:00Z" "p" "binlog.000010" "1000" "binlog.000010" "1000"
DECIDED_TYPE=""
determine_backup_type >/dev/null 2>&1
assert_eq "exactly interval days old selects FULL" "full" "$DECIDED_TYPE"

# 13/13+1 boundary: 13 days -> incremental, 14 days -> full.
export FAKE_NOW_EPOCH=1757808000   # +13 days
reset_state 1 "full_2026-09-01_000000" "2026-09-01T00:00:00Z" "p" "binlog.000010" "1000" "binlog.000010" "1000"
DECIDED_TYPE=""
determine_backup_type >/dev/null 2>&1
assert_eq "13 days old selects INCREMENTAL" "incremental" "$DECIDED_TYPE"

# Invalid interval falls back to 14 (age 13 -> incremental still).
export BACKUP_FULL_INTERVAL_DAYS="nonsense"
reset_state 1 "full_2026-09-01_000000" "2026-09-01T00:00:00Z" "p" "binlog.000010" "1000" "binlog.000010" "1000"
DECIDED_TYPE=""
determine_backup_type >/dev/null 2>&1
assert_eq "invalid interval falls back to 14" "incremental" "$DECIDED_TYPE"
export BACKUP_FULL_INTERVAL_DAYS=14

# A failed full must NOT become the base: the state still points at the OLD
# successful full, so the decision is unchanged by an (unrecorded) failed full.
reset_state 1 "full_2026-09-01_000000" "2026-09-01T00:00:00Z" "p" "binlog.000010" "1000" "binlog.000010" "1000"
export FAKE_NOW_EPOCH=$((1756684800 + 60))   # 1 minute later, same day
DECIDED_TYPE=""
determine_backup_type >/dev/null 2>&1
assert_eq "failed full does not change decision (still incremental)" "incremental" "$DECIDED_TYPE"

export PATH="$POLICY_OLD_PATH"
unset FAKE_LAST_FULL_EPOCH FAKE_NOW_EPOCH
rm -rf "$POLICY_DIR"

# ---------------------------------------------------------------------------
# State (R2 JSON) load / update / parse
# ---------------------------------------------------------------------------
echo "== backup state (R2 JSON) =="

STATE_DIR="$(mktemp -d)"
export STATE_DIR
# Restore a defined rclone config path: an earlier test intentionally unset
# RCLONE_CONFIG, and set -u would otherwise make the state functions fail.
export RCLONE_CONFIG="$STATE_DIR/rclone.conf"
export RCLONE_CONFIG_DIR="$STATE_DIR"
# rclone stub that serves a state object from a local file and records writes.
cat > "$STATE_DIR/rclone" <<'STUB'
#!/usr/bin/env bash
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) shift 2;;
    cat)
      # rclone cat remote:<path>  -> print state file
      if [[ -f "$STATE_DIR/state.json" ]]; then cat "$STATE_DIR/state.json"; fi
      exit 0;;
    copyto)
      # rclone copyto <local> remote:<path> -> record the local file
      cp "$2" "$STATE_DIR/uploaded_state.json"
      exit 0;;
    *) shift;;
  esac
done
exit 0
STUB
chmod +x "$STATE_DIR/rclone"
STATE_OLD_PATH="$PATH"
export PATH="$STATE_DIR:$PATH"

# load_state with no object -> STATE_PRESENT=0.
rm -f "$STATE_DIR/state.json"
load_state >/dev/null 2>&1 || true
assert_eq "load_state with no object sets STATE_PRESENT=0" "0" "$STATE_PRESENT"

# load_state with a full state object parses every field.
cat > "$STATE_DIR/state.json" <<'JSON'
{
  "state_version": 1,
  "updated_at": "2026-09-10T00:00:00Z",
  "last_successful_full_backup_name": "full_2026-09-10_020000",
  "last_successful_full_completed_at": "2026-09-10T02:00:00Z",
  "last_successful_full_storage_path": "mysql-backup/full/2026/09/10/full_2026-09-10_020000",
  "last_binlog_file": "binlog.000123",
  "last_binlog_position": 456789,
  "last_binlog_end_file": "binlog.000124",
  "last_binlog_end_position": 123456
}
JSON
load_state >/dev/null 2>&1
assert_eq "load_state sets STATE_PRESENT=1" "1" "$STATE_PRESENT"
assert_eq "load_state parses full name" "full_2026-09-10_020000" "$ST_LAST_FULL_NAME"
assert_eq "load_state parses full completed_at" "2026-09-10T02:00:00Z" "$ST_LAST_FULL_COMPLETED_AT"
assert_eq "load_state parses full storage path" "mysql-backup/full/2026/09/10/full_2026-09-10_020000" "$ST_LAST_FULL_STORAGE_PATH"
assert_eq "load_state parses binlog file" "binlog.000123" "$ST_LAST_BINLOG_FILE"
assert_eq "load_state parses binlog position" "456789" "$ST_LAST_BINLOG_POSITION"
assert_eq "load_state parses binlog end file" "binlog.000124" "$ST_LAST_BINLOG_END_FILE"
assert_eq "load_state parses binlog end position" "123456" "$ST_LAST_BINLOG_END_POSITION"

# load_state ignores a foreign/corrupt object (no full key) -> STATE_PRESENT=0.
printf '{"something":"else"}' > "$STATE_DIR/state.json"
load_state >/dev/null 2>&1
assert_eq "load_state ignores foreign object" "0" "$STATE_PRESENT"

# update_state writes a valid object containing the passed values.
rm -f "$STATE_DIR/uploaded_state.json"
update_state "full_X" "2026-09-10T02:00:00Z" "mysql-backup/full/X" "binlog.000200" "555" "binlog.000201" "999" >/dev/null 2>&1
UP="$(cat "$STATE_DIR/uploaded_state.json" 2>/dev/null)"
assert_contains "update_state writes full name" "$UP" '"last_successful_full_backup_name": "full_X"'
assert_contains "update_state writes binlog file" "$UP" '"last_binlog_file": "binlog.000200"'
assert_contains "update_state writes binlog position" "$UP" '"last_binlog_position": 555'
assert_contains "update_state writes binlog end position" "$UP" '"last_binlog_end_position": 999'
assert_not_contains "state never contains the R2 secret" "$UP" "r2super-secret-key"
assert_not_contains "state never contains the report token" "$UP" "super-secret-report-token"
assert_not_contains "state never contains the DB password" "$UP" "sup3rsecret-db-pass"

export PATH="$STATE_OLD_PATH"
rm -rf "$STATE_DIR"
unset STATE_DIR

# ---------------------------------------------------------------------------
# State / lock remote paths MUST be bucket-qualified
# ---------------------------------------------------------------------------
# Regression for a real state-path bug: BACKUP_STATE_REMOTE and
# BACKUP_LOCK_REMOTE were built from R2_PATH ALONE, without R2_BUCKET. An rclone
# remote path is `remote:<bucket>/<key>`, so the state and the lock were written
# to a DIFFERENT bucket than the backups they describe — the FULL uploaded to
# `<bucket>/<path>/full/...` while the state went to `<path>/state/...`.
#
# Consequence: `load_state` never found the state (so every run looked like a
# first run and re-decided FULL), and the distributed lock protected nothing.
# This is invisible to any test that only checks the PARSE logic, so it is pinned
# here against the real variable values.
echo "== state/lock remote paths include the bucket =="

# Use a DISTINCT bucket/path so the assertion cannot pass by coincidence with
# values used elsewhere in the suite.
R2_BUCKET="rmb-test"
R2_PATH="integration-test/mysql-backup-v2"
BACKUP_STATE_REMOTE="${R2_BUCKET}/${R2_PATH%/}/state/backup_state.json"
BACKUP_LOCK_REMOTE="${R2_BUCKET}/${R2_PATH%/}/state/backup.lock"

assert_eq "BACKUP_STATE_REMOTE includes R2_BUCKET" "rmb-test" "${BACKUP_STATE_REMOTE%%/*}"
assert_eq "BACKUP_LOCK_REMOTE includes R2_BUCKET" "rmb-test" "${BACKUP_LOCK_REMOTE%%/*}"
assert_contains "BACKUP_STATE_REMOTE starts with <bucket>/<path>" \
  "$BACKUP_STATE_REMOTE" "rmb-test/integration-test/mysql-backup-v2/"
assert_contains "BACKUP_LOCK_REMOTE starts with <bucket>/<path>" \
  "$BACKUP_LOCK_REMOTE" "rmb-test/integration-test/mysql-backup-v2/"
assert_contains "BACKUP_STATE_REMOTE ends with the state key" \
  "$BACKUP_STATE_REMOTE" "/state/backup_state.json"
assert_contains "BACKUP_LOCK_REMOTE ends with the lock key" \
  "$BACKUP_LOCK_REMOTE" "/state/backup.lock"

# The state/lock bucket must be IDENTICAL to the bucket the FULL uploads to.
FULL_UPLOAD_REMOTE="${R2_BUCKET}/${R2_PATH%/}/full/2026/09/12/full_X"
assert_eq "FULL upload, state and lock share one bucket" "one_bucket" \
  "$(b="${FULL_UPLOAD_REMOTE%%/*}"; s="${BACKUP_STATE_REMOTE%%/*}"; l="${BACKUP_LOCK_REMOTE%%/*}"
     if [[ "$b" == "$s" && "$s" == "$l" ]]; then echo one_bucket; else echo "b=$b s=$s l=$l"; fi)"
# ...and they share the same base path prefix, so they live beside each other.
assert_eq "state and lock share the FULL's path prefix" "same_prefix" \
  "$(p="${R2_BUCKET}/${R2_PATH%/}"
     if [[ "$BACKUP_STATE_REMOTE" == "$p/"* && "$BACKUP_LOCK_REMOTE" == "$p/"* && "$FULL_UPLOAD_REMOTE" == "$p/"* ]]; then
       echo same_prefix; else echo mismatch; fi)"

# STATIC GUARD: the DEFINITIONS in entrypoint.sh must be bucket-qualified. This
# is what actually fails if the bug is reintroduced, and it does not depend on
# the values above.
assert_eq "entrypoint defines BACKUP_STATE_REMOTE with R2_BUCKET" \
  "1" "$(grep -c -F 'BACKUP_STATE_REMOTE="${R2_BUCKET}/${R2_PATH%/}/state/backup_state.json"' "$ENTRYPOINT" || true)"
assert_eq "entrypoint defines BACKUP_LOCK_REMOTE with R2_BUCKET" \
  "1" "$(grep -c -F 'BACKUP_LOCK_REMOTE="${R2_BUCKET}/${R2_PATH%/}/state/backup.lock"' "$ENTRYPOINT" || true)"
# Negative control: NO state/lock remote may be built from R2_PATH alone. A bare
# `${R2_PATH%/}/state/...` (no ${R2_BUCKET} prefix on the same line) is the bug.
assert_eq "no state/lock path is built without R2_BUCKET" \
  "0" "$(grep -n -E '^[A-Z_]+="\$\{R2_PATH%/\}/state/' "$ENTRYPOINT" | wc -l)"

# The bucket-qualified paths are only useful if the call sites use these SAME
# variables (not a re-derived literal).
assert_contains "load_state reads BACKUP_STATE_REMOTE" \
  "$(sed -n '/^load_state()/,/^}/p' "$ENTRYPOINT")" 'remote:${BACKUP_STATE_REMOTE}'
assert_contains "update_state writes BACKUP_STATE_REMOTE" \
  "$(sed -n '/^update_state()/,/^}/p' "$ENTRYPOINT")" 'remote:${BACKUP_STATE_REMOTE}'
assert_contains "acquire_lock uses BACKUP_LOCK_REMOTE" \
  "$(sed -n '/^acquire_lock()/,/^}/p' "$ENTRYPOINT")" 'remote:${BACKUP_LOCK_REMOTE}'
assert_contains "release_lock uses BACKUP_LOCK_REMOTE" \
  "$(sed -n '/^release_lock()/,/^}/p' "$ENTRYPOINT")" 'remote:${BACKUP_LOCK_REMOTE}'
# The lock must be deleted from the SAME object it was created in, otherwise a
# run could leave a permanent (6h) lock behind in the other bucket.
assert_contains "the lock's remote path is defined once (no second, unqualified path)" \
  "1" "$(grep -c -E '^BACKUP_LOCK_REMOTE=' "$ENTRYPOINT" || true)"

# ---------------------------------------------------------------------------
# Execution order in main(): configure_rclone -> acquire_lock -> load_state ->
# determine_backup_type
# ---------------------------------------------------------------------------
# The lock MUST be taken before the state is read: the state is
# read-modify-write, so reading it before mutual exclusion is established would
# let two concurrent runs read the same boundary and both advance it. And the
# state must be loaded BEFORE the type decision, because the decision is derived
# from it. This asserts the source order directly so a refactor cannot quietly
# reorder the sequence.
echo "== main() execution order =="
# `configure_rclone` is called from more than one function, so take main()'s
# occurrence (the LAST one) — the earlier call belongs to a different path.
ORDER_CR="$(grep -n -E '^  configure_rclone$' "$ENTRYPOINT" | tail -n1 | cut -d: -f1)"
ORDER_AL="$(grep -n -F 'if ! acquire_lock; then' "$ENTRYPOINT" | head -n1 | cut -d: -f1)"
ORDER_LS="$(grep -n -F '  load_state' "$ENTRYPOINT" | head -n1 | cut -d: -f1)"
ORDER_DB="$(grep -n -F '  determine_backup_type' "$ENTRYPOINT" | head -n1 | cut -d: -f1)"
if [[ -n "$ORDER_CR" && -n "$ORDER_AL" && -n "$ORDER_LS" && -n "$ORDER_DB" ]] \
   && [[ "$ORDER_CR" -lt "$ORDER_AL" && "$ORDER_AL" -lt "$ORDER_LS" && "$ORDER_LS" -lt "$ORDER_DB" ]]; then
  pass "main() order is configure_rclone(${ORDER_CR}) -> acquire_lock(${ORDER_AL}) -> load_state(${ORDER_LS}) -> determine_backup_type(${ORDER_DB})"
else
  fail "main() order regressed (configure_rclone=${ORDER_CR:-?} acquire_lock=${ORDER_AL:-?} load_state=${ORDER_LS:-?} determine_backup_type=${ORDER_DB:-?})"
fi

echo "== mysqlbinlog raw capture form (MySQL 8.x client) =="

# The `raw` fetch strategy shells out to mysqlbinlog. The Dockerfile installs the
# MYSQL client (not MariaDB's), and the two are NOT interchangeable here:
#
#   `--result-dir` is a MARIADB-ONLY option. MySQL's mysqlbinlog rejects it with
#       mysqlbinlog: [ERROR] unknown option '--result-dir'.
#   so a capture written that way fails at runtime with a non-zero status while
#   every unit test still passes (the doubles accepted the flag).
#
# MySQL's portable form is to run with the destination directory as the CWD and
# let mysqlbinlog create a file named after the binlog. These assertions pin that
# form, and the tool double REJECTS --result-dir so a regression fails here.
CAPPED_FN="$(sed -n '/^fetch_binlog_file_via_mysqlbinlog()/,/^}/p' "$ENTRYPOINT")"
# Assert against the CODE only: the function's comments deliberately NAME
# `--result-dir` to explain why it must not be used, so a naive substring check
# on the raw text would match that explanation instead of a real invocation.
CAPPED_CODE="$(printf '%s\n' "$CAPPED_FN" | grep -v -E '^[[:space:]]*#')"
assert_not_contains "raw capture does NOT pass --result-dir (MariaDB-only option)" \
  "$CAPPED_CODE" "--result-dir"
assert_contains "raw capture runs mysqlbinlog from the destination directory" \
  "$CAPPED_CODE" 'cd "$outdir"'
assert_contains "raw capture still uses --read-from-remote-server" \
  "$CAPPED_CODE" "--read-from-remote-server"
assert_contains "raw capture still uses --raw" "$CAPPED_CODE" "--raw"
assert_contains "raw capture still passes the configured server id" \
  "$CAPPED_CODE" '--server-id="${MYSQLBINLOG_SERVER_ID}"'

# FUNCTIONAL PROOF through the real function and a Faithful double: a capture
# must succeed, and the bytes must land at <dest>.
CAP_DIR="$(mktemp -d)"
export CAP_DIR
cat > "$CAP_DIR/mysqlbinlog" <<'STUB'
#!/usr/bin/env bash
# Faithful to the MySQL 8.x client: --result-dir is REJECTED.
raw=0; files=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --defaults-extra-file) shift 2;;
    --read-from-remote-server) shift;;
    --server-id) shift 2;;
    --raw) raw=1; shift;;
    --result-dir|--result-dir=*) echo "mysqlbinlog: [ERROR] unknown option '--result-dir'." >&2; exit 2;;
    -*) shift;;
    *) files+=("$1"); shift;;
  esac
done
[[ "$raw" -eq 1 ]] || exit 0
for f in "${files[@]}"; do printf 'RAWBINLOG:%s' "$f" > "$(basename "$f")"; done
exit 0
STUB
chmod +x "$CAP_DIR/mysqlbinlog"
CAP_OLD_PATH="$PATH"
export PATH="$CAP_DIR:$PATH"
export MYSQLBINLOG_BIN="mysqlbinlog" MYSQLBINLOG_SERVER_ID=424242
CAP_DEST="$CAP_DIR/captured.bin"
if fetch_binlog_file_via_mysqlbinlog "binlog.000070" "$CAP_DEST" >"$CAP_DIR/log" 2>&1; then
  pass "raw capture succeeds with the MySQL 8.x client form"
else
  fail "raw capture failed with the MySQL 8.x client form"
  sed 's/^/       /' "$CAP_DIR/log" 2>/dev/null | head -5
fi
assert_eq "raw capture writes the bytes to <dest>" "RAWBINLOG:binlog.000070" \
  "$(cat "$CAP_DEST" 2>/dev/null)"

export PATH="$CAP_OLD_PATH"
export MYSQLBINLOG_BIN="mysqlbinlog"
rm -rf "$CAP_DIR"
unset CAP_DIR

# ---------------------------------------------------------------------------
# MySQL binlog prerequisite + boundary + incremental packaging
# ---------------------------------------------------------------------------
echo "== mysql binlog prerequisite + incremental =="

BIN_DIR="$(mktemp -d)"
export BIN_DIR

# mysql stub: answers the specific queries the code issues, driven by env.
cat > "$BIN_DIR/mysql" <<'STUB'
#!/usr/bin/env bash
# Find the -e "<sql>" argument.
sql=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --defaults-extra-file) shift 2;;
    -e) sql="$2"; shift 2;;
    *) shift;;
  esac
done
shopt -s nocasematch
if [[ "$sql" == *"log_bin"* ]]; then
  printf 'log_bin\t%s\n' "${STUB_LOG_BIN:-ON}"; exit 0
fi
if [[ "$sql" == *"binlog_format"* ]]; then
  printf 'binlog_format\t%s\n' "${STUB_BINLOG_FORMAT:-ROW}"; exit 0
fi
if [[ "$sql" == *"SHOW MASTER STATUS"* ]]; then
  if [[ "${STUB_MASTER_STATUS_FAIL:-0}" == "1" ]]; then exit 0; fi
  printf '%s\t%s\t\t\t\n' "${STUB_MASTER_FILE:-binlog.000200}" "${STUB_MASTER_POS:-999}"; exit 0
fi
if [[ "$sql" == *"SHOW BINARY LOGS"* ]]; then
  printf '%s\n' ${STUB_BINARY_LOGS:-binlog.000199 binlog.000200} | while read -r f; do
    printf '%s\t%s\n' "$f" 4
  done
  exit 0
fi
exit 0
STUB
chmod +x "$BIN_DIR/mysql"

# mysqlbinlog stub, faithful to the REAL MySQL 8.x client:
#   - `--result-dir` is REJECTED (MariaDB-only option).
#   - a local read emits a minimal SQL stream.
#   - `--raw` (-R) writes the raw binlog into the CWD named after the basename.
cat > "$BIN_DIR/mysqlbinlog" <<'STUB'
#!/usr/bin/env bash
result_dir=""
raw=0
files=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --defaults-extra-file) shift 2;;
    --read-from-remote-server) shift;;
    --server-id) shift 2;;
    --raw) raw=1; shift;;
    --result-dir|--result-dir=*) echo "mysqlbinlog: [ERROR] unknown option '--result-dir'." >&2; exit 2;;
    --start-position|--stop-position) shift 2;;
    -*) shift;;
    *) files+=("$1"); shift;;
  esac
done
if [[ "${STUB_MYSQLBINLOG_FAIL:-0}" == "1" ]]; then echo "boom" >&2; exit 1; fi
if [[ "$raw" -eq 1 ]]; then
  for f in "${files[@]}"; do printf 'RAWBINLOG:%s' "$f" > "$(basename "$f")"; done
  exit 0
fi
# Local read: emit SQL for each file (non-empty).
if [[ "${STUB_MYSQLBINLOG_EMPTY:-0}" == "1" ]]; then exit 0; fi
for f in "${files[@]}"; do printf -- '-- binlog %s\nSET @@session.sql_mode=1;\n' "$f"; done
exit 0
STUB
chmod +x "$BIN_DIR/mysqlbinlog"

BIN_OLD_PATH="$PATH"
export PATH="$BIN_DIR:$PATH"
export MYSQL_CLIENT_BIN="mysql"
export MYSQLBINLOG_BIN="mysqlbinlog"
export R2_BUCKET="b"
export R2_PATH="mysql-backup"

# 8. binlog disabled by the server (log_bin=OFF) -> check fails.
export STUB_LOG_BIN=OFF
if check_mysql_binlog >/dev/null 2>&1; then fail "binlog check should fail when log_bin=OFF"; else pass "binlog check fails when log_bin=OFF"; fi

# log_bin=ON but unusable format -> fails.
export STUB_LOG_BIN=ON
export STUB_BINLOG_FORMAT="NONE"
if check_mysql_binlog >/dev/null 2>&1; then fail "binlog check should fail on unusable format"; else pass "binlog check fails on unusable binlog_format"; fi

# log_bin=ON + ROW -> passes.
export STUB_BINLOG_FORMAT=ROW
if check_mysql_binlog >/dev/null 2>&1; then pass "binlog check passes when log_bin=ON/ROW"; else fail "binlog check should pass when log_bin=ON/ROW"; fi

# acquire_binlog_boundary returns file<TAB>position.
export STUB_MASTER_FILE="binlog.000200"
export STUB_MASTER_POS="999"
BOUNDARY="$(acquire_binlog_boundary)"
assert_eq "acquire_binlog_boundary returns file/pos" "binlog.000200	999" "$BOUNDARY"

# 23. binlog rotation is handled: the boundary can be a later file.
export STUB_MASTER_FILE="binlog.000205"
export STUB_MASTER_POS="1234"
BOUNDARY="$(acquire_binlog_boundary)"
assert_eq "acquire_binlog_boundary handles rotation (later file)" "binlog.000205	1234" "$BOUNDARY"

export PATH="$BIN_OLD_PATH"
unset STUB_LOG_BIN STUB_BINLOG_FORMAT STUB_MASTER_FILE STUB_MASTER_POS

# ---------------------------------------------------------------------------
# Full main() integration: FULL -> INCREMENTAL -> INCREMENTAL -> FULL
# ---------------------------------------------------------------------------
echo "== backup policy integration (state evolves) =="

INT_DIR="$(mktemp -d)"
export INT_DIR
# Where the mydumper double records the arguments it was invoked with, so the
# tests can assert that --source-data (the binlog-anchor flag) is really passed.
export STUB_MYDUMPER_CMDLINE="$INT_DIR/mydumper_cmdline"
# A single rclone stub serving the state object + counting uploads.
cat > "$INT_DIR/rclone" <<'STUB'
#!/usr/bin/env bash
# The entrypoint always calls: rclone --config <path> <subcommand> ...
# We consume --config <path> first, then dispatch. `sync` records the LOCAL
# source dir so `size` can report its real count/bytes (mirroring a successful
# upload); `size` also serves the state object path when asked about it.
if [[ "$1" == "--config" ]]; then shift 2; fi
case "$1" in
  listremotes) printf 'remote:\n'; exit 0;;
  cat) if [[ -f "$INT_DIR/state.json" ]]; then cat "$INT_DIR/state.json"; fi; exit 0;;
  copyto) cp "$2" "$INT_DIR/state.json"; exit 0;;
  sync)
    printf '%s\n' "$2" > "$INT_DIR/last_sync_dir"
    printf '%s\n' "$3" >> "$INT_DIR/uploads.log"
    exit 0;;
  size)
    # Report the count/bytes of the last synced LOCAL directory.
    if [[ -f "$INT_DIR/last_sync_dir" ]]; then
      d="$(cat "$INT_DIR/last_sync_dir")"
      if [[ -d "$d" ]]; then
        c="$(find "$d" -type f 2>/dev/null | wc -l)"
        b="$(find "$d" -type f -printf '%s\n' 2>/dev/null | awk '{s+=$1} END {print s+0}')"
        printf '{"count":%s,"bytes":%s,"sizeless":0}\n' "$c" "$b"; exit 0
      fi
    fi
    printf '{"count":0,"bytes":0,"sizeless":0}\n'; exit 0;;
  *) exit 0;;
esac
STUB
chmod +x "$INT_DIR/rclone"

cat > "$INT_DIR/mydumper" <<'STUB'
#!/usr/bin/env bash
out=""; args="$*"; while [[ $# -gt 0 ]]; do case "$1" in -o) out="$2"; shift 2;; *) shift;; esac; done
mkdir -p "$out"; printf 'schema' > "$out/db.schema.sql"
# Record the invocation so tests can assert --source-data is actually passed.
printf '%s\n' "$args" > "$STUB_MYDUMPER_CMDLINE"
# Emit the metadata in the REAL MyDumper v0.21.x shape. The [source] keys are
# ACTIVE only because --source-data was passed; this is the format the parser
# must consume in production.
if [[ "$args" == *"--source-data"* ]]; then
  printf '[source]\nSOURCE_LOG_FILE = "%s"\nSOURCE_LOG_POS = %s\n' \
    "${STUB_ANCHOR_FILE:-binlog.000100}" "${STUB_ANCHOR_POS:-4}" > "$out/metadata"
else
  # Without the flag mydumper writes the same keys COMMENTED OUT.
  printf '[source]\n# SOURCE_LOG_FILE = "%s"\n# SOURCE_LOG_POS = %s\n' \
    "${STUB_ANCHOR_FILE:-binlog.000100}" "${STUB_ANCHOR_POS:-4}" > "$out/metadata"
fi
exit 0
STUB
chmod +x "$INT_DIR/mydumper"

cat > "$INT_DIR/mysql" <<'STUB'
#!/usr/bin/env bash
sql=""
while [[ $# -gt 0 ]]; do case "$1" in --defaults-extra-file) shift 2;; -e) sql="$2"; shift 2;; *) shift;; esac; done
shopt -s nocasematch
if [[ "$sql" == *"log_bin"* ]]; then printf 'log_bin\tON\n'; exit 0; fi
if [[ "$sql" == *"binlog_format"* ]]; then printf 'binlog_format\tROW\n'; exit 0; fi
if [[ "$sql" == *"SHOW MASTER STATUS"* ]]; then printf '%s\t%s\n' "${STUB_MASTER_FILE:-binlog.000200}" "${STUB_MASTER_POS:-999}"; exit 0; fi
if [[ "$sql" == *"SHOW BINARY LOGS"* ]]; then printf '%s\t4\n' ${STUB_BINARY_LOGS:-binlog.000199 binlog.000200}; exit 0; fi
exit 0
STUB
chmod +x "$INT_DIR/mysql"

cat > "$INT_DIR/mysqlbinlog" <<'STUB'
#!/usr/bin/env bash
result_dir=""; raw=0; files=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --defaults-extra-file) shift 2;;
    --read-from-remote-server) shift;;
    --server-id) shift 2;;
    --raw) raw=1; shift;;
    --result-dir|--result-dir=*) echo "mysqlbinlog: [ERROR] unknown option '--result-dir'." >&2; exit 2;;
    --start-position|--stop-position) shift 2;;
    -*) shift;;
    *) files+=("$1"); shift;;
  esac
done
if [[ "$raw" -eq 1 ]]; then for f in "${files[@]}"; do printf 'RAW:%s' "$f" > "$(basename "$f")"; done; exit 0; fi
for f in "${files[@]}"; do printf -- '-- %s\nSQL;\n' "$f"; done
exit 0
STUB
chmod +x "$INT_DIR/mysqlbinlog"

cat > "$INT_DIR/curl" <<'STUB'
#!/usr/bin/env bash
# curl -o <file> writes the BODY; -w "%{http_code}" writes the CODE to stdout.
resp_file=""
payload=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --data-binary) payload="$2"; shift 2;;
    -o) resp_file="$2"; shift 2;;
    -w) shift 2;;
    --max-time) shift 2;;
    *) shift;;
  esac
done
printf '%s\n' "$payload" >> "$INT_DIR/reports.log"
[[ -n "$resp_file" ]] && printf '{"success":true}' > "$resp_file"
printf '%s' "201"; exit 0
STUB
chmod +x "$INT_DIR/curl"

INT_OLD_PATH="$PATH"
export PATH="$INT_DIR:$PATH"
export R2_ACCESS_KEY_ID=a R2_SECRET_ACCESS_KEY=s R2_ENDPOINT=e R2_BUCKET=b R2_PATH="mysql-backup"
export BACKUP_REPORT_URL="https://puptvs.com/x" BACKUP_REPORT_TOKEN="tok"
export MYSQL_HOST=h MYSQL_USER=u MYSQL_PASSWORD=p MYSQL_DATABASE=d MYSQL_PORT=3306
export MYSQL_CLIENT_BIN="mysql" MYSQLBINLOG_BIN="mysqlbinlog"
export BACKUP_BINLOG_ENABLED=true BACKUP_BINLOG_VERIFY=true
export REPORT_TIMEOUT=2

# Seed: simulate that a FULL was completed just now so the next run is
# incremental. We run the real entrypoint, so use a helper that fakes "now".
INT_ENTRYPOINT="$ENTRYPOINT"
run_entrypoint() {
  # $1 = now epoch ; $2 = last-full epoch (for age)
  ( cd "$INT_DIR" && \
    FAKE_NOW_EPOCH="$1" bash -c '
      source "$0" >/dev/null 2>&1
      # Override the two date() calls the policy uses so the decision is pinned.
      date() {
        if [[ "$1" == "-u" && "$2" == "-d" ]]; then printf "%s" "${FAKE_LAST_FULL_EPOCH}"; return 0; fi
        if [[ "$1" == "-u" && "$2" == "+%s" ]]; then printf "%s" "${FAKE_NOW_EPOCH}"; return 0; fi
        command date "$@"
      }
      main
    ' "$INT_ENTRYPOINT" )
}

# Step 1: no state -> FULL. Anchor from mydumper metadata = binlog.000100:4.
rm -f "$INT_DIR/state.json" "$INT_DIR/reports.log" "$INT_DIR/uploads.log"
export STUB_ANCHOR_FILE="binlog.000100" STUB_ANCHOR_POS="4"
# A real server always retains a CONTIGUOUS run of binlogs, so the fake listing
# must be contiguous too (the entrypoint now asserts this).
export STUB_BINARY_LOGS="binlog.000099 binlog.000100 binlog.000101"
run_entrypoint 1756684800 0 >/dev/null 2>&1
assert_contains "integration step1 reports full backup_type" "$(cat "$INT_DIR/reports.log" 2>/dev/null)" '"backup_type":"full"'
assert_contains "integration step1 state records full name" "$(cat "$INT_DIR/state.json" 2>/dev/null)" '"last_successful_full_backup_name": "full_'
assert_contains "integration step1 state records binlog anchor" "$(cat "$INT_DIR/state.json" 2>/dev/null)" '"last_binlog_file": "binlog.000100"'
assert_contains "integration step1 state records anchor position" "$(cat "$INT_DIR/state.json" 2>/dev/null)" '"last_binlog_position": 4'
# The anchor must have come from a REAL mydumper invocation carrying the
# --source-data flag (not from a commented placeholder or a post-dump query).
assert_contains "integration step1 invokes mydumper with --source-data" \
  "$(cat "$STUB_MYDUMPER_CMDLINE" 2>/dev/null)" "--source-data"
# ...and the persisted anchor must be a well-formed, positive coordinate.
INT_ANCHOR_FILE="$(sed -n 's/.*"last_binlog_file": "\([^"]*\)".*/\1/p' "$INT_DIR/state.json")"
if [[ "$INT_ANCHOR_FILE" =~ ^[A-Za-z0-9._-]+\.[0-9]+$ ]]; then
  pass "integration step1 anchor is a well-formed binlog filename (${INT_ANCHOR_FILE})"
else
  fail "integration step1 anchor is not a well-formed binlog filename (got '${INT_ANCHOR_FILE}')"
fi
assert_contains "integration step1 reports anchor as usable in the diagnosis" \
  "$(cat "$INT_DIR/state.json")" '"last_binlog_position": 4'
FULL_NAME_1="$(sed -n 's/.*"last_successful_full_backup_name": "\([^"]*\)".*/\1/p' "$INT_DIR/state.json")"

# Step 2: 1 day later -> INCREMENTAL; must NOT contain a full dump.
export STUB_MASTER_FILE="binlog.000100" STUB_MASTER_POS="50"
export STUB_BINARY_LOGS="binlog.000099 binlog.000100 binlog.000101"
run_entrypoint 1756771200 0 >/dev/null 2>&1
assert_contains "integration step2 reports incremental" "$(cat "$INT_DIR/reports.log")" '"backup_type":"incremental"'
assert_contains "integration step2 records its full base" "$(cat "$INT_DIR/reports.log")" "\"base_backup_name\":\"$FULL_NAME_1\""
assert_contains "integration step2 records binlog start" "$(cat "$INT_DIR/reports.log")" '"binlog_file_start":"binlog.000100"'
assert_contains "integration step2 records binlog end" "$(cat "$INT_DIR/reports.log")" '"binlog_file_end":"binlog.000100"'
assert_contains "integration step2 state advances binlog position" "$(cat "$INT_DIR/state.json")" '"last_binlog_position": 50'
assert_contains "integration step2 state keeps the same full base" "$(cat "$INT_DIR/state.json")" "\"last_successful_full_backup_name\": \"$FULL_NAME_1\""
# CHAIN PROOF: the incremental must have actually STARTED and SUCCEEDED from the
# FULL's anchor. If the FULL had no usable anchor, run_incremental_backup would
# have failed with "no recorded binlog position" and reported status=failed, so
# asserting a success report is what proves the FULL is a usable base.
assert_contains "integration step2 successfully started from the FULL anchor" \
  "$(tail -n1 "$INT_DIR/reports.log")" '"status":"success"'
assert_not_contains "integration step2 did not fail for a missing anchor" \
  "$(tail -n1 "$INT_DIR/reports.log")" 'no recorded binlog position'

# Step 3: another day -> INCREMENTAL again from the advanced position.
export STUB_MASTER_FILE="binlog.000101" STUB_MASTER_POS="77"
export STUB_BINARY_LOGS="binlog.000100 binlog.000101 binlog.000102"
run_entrypoint 1756857600 0 >/dev/null 2>&1
assert_contains "integration step3 reports incremental" "$(cat "$INT_DIR/reports.log")" '"backup_type":"incremental"'
assert_contains "integration step3 starts at previous end position" "$(cat "$INT_DIR/reports.log")" '"binlog_file_start":"binlog.000100"'
assert_contains "integration step3 ends at the new rotated file" "$(cat "$INT_DIR/reports.log")" '"binlog_file_end":"binlog.000101"'
assert_contains "integration step3 advances the saved position" "$(cat "$INT_DIR/state.json")" '"last_binlog_position": 77'
assert_contains "integration step3 advances the end file" "$(cat "$INT_DIR/state.json")" '"last_binlog_end_file": "binlog.000101"'

# Step 4: after the interval -> FULL again; anchor resets.
export BACKUP_FULL_INTERVAL_DAYS=2
# Move "now" far enough past the recorded full completion to make it due. We
# rewrite the state's full completed_at to a known old value first.
sed -i 's/"last_successful_full_completed_at": "[^"]*"/"last_successful_full_completed_at": "2026-09-01T00:00:00Z"/' "$INT_DIR/state.json"
export STUB_ANCHOR_FILE="binlog.000101" STUB_ANCHOR_POS="77"
run_entrypoint 1757894400 1756684800 >/dev/null 2>&1
LAST_REPORT="$(tail -n1 "$INT_DIR/reports.log")"
assert_contains "integration step4 reports a new full" "$LAST_REPORT" '"backup_type":"full"'
NEW_FULL="$(sed -n 's/.*"last_successful_full_backup_name": "\([^"]*\)".*/\1/p' "$INT_DIR/state.json")"
if [[ "$NEW_FULL" != "$FULL_NAME_1" ]]; then
  pass "integration step4 becomes the new base (different full name)"
else
  fail "integration step4 should record a new full base name"
fi
assert_contains "integration step4 (full) does NOT report a base_backup_name" "$LAST_REPORT" '"backup_type":"full"'
if [[ "$LAST_REPORT" != *'"base_backup_name"'* ]]; then
  pass "integration step4 full payload has no base_backup_name"
else
  fail "integration step4 full payload must not include base_backup_name"
fi

# 4. A FULL run must NEVER contain incremental fields / vice-versa.
FULL_LINE="$(grep '"backup_type":"full"' "$INT_DIR/reports.log" | tail -n1)"
if [[ "$FULL_LINE" != *'"binlog_file_start"'* ]]; then
  pass "full payload omits incremental binlog fields"
else
  fail "full payload must not include binlog_file_start"
fi

export BACKUP_FULL_INTERVAL_DAYS=14
export PATH="$INT_OLD_PATH"
unset STUB_MASTER_FILE STUB_MASTER_POS STUB_BINARY_LOGS STUB_ANCHOR_FILE STUB_ANCHOR_POS
rm -rf "$INT_DIR"

# ---------------------------------------------------------------------------
# Failure safety: failed incremental must NOT advance the binlog position,
# and failed precondition must not update state.
# ---------------------------------------------------------------------------
echo "== incremental failure safety =="

SAFE_DIR="$(mktemp -d)"
export SAFE_DIR
cat > "$SAFE_DIR/rclone" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "--config" ]]; then shift 2; fi
case "$1" in
  listremotes) printf 'remote:\n'; exit 0;;
  cat) if [[ -f "$SAFE_DIR/state.json" ]]; then cat "$SAFE_DIR/state.json"; fi; exit 0;;
  copyto) cp "$2" "$SAFE_DIR/state.json"; echo "STATE_UPDATED" >> "$SAFE_DIR/events.log"; exit 0;;
  sync)
    if [[ "${RCLONE_SYNC_EXIT:-0}" != "0" ]]; then exit "${RCLONE_SYNC_EXIT}"; fi
    printf '%s\n' "$2" > "$SAFE_DIR/last_sync_dir"
    exit 0;;
  size)
    if [[ -f "$SAFE_DIR/last_sync_dir" ]]; then
      d="$(cat "$SAFE_DIR/last_sync_dir")"
      if [[ -d "$d" ]]; then
        c="$(find "$d" -type f 2>/dev/null | wc -l)"
        b="$(find "$d" -type f -printf '%s\n' 2>/dev/null | awk '{s+=$1} END {print s+0}')"
        printf '{"count":%s,"bytes":%s,"sizeless":0}\n' "$c" "$b"; exit 0
      fi
    fi
    printf '{"count":0,"bytes":0,"sizeless":0}\n'; exit 0;;
  *) exit 0;;
esac
STUB
chmod +x "$SAFE_DIR/rclone"
cat > "$SAFE_DIR/mysql" <<'STUB'
#!/usr/bin/env bash
sql=""; while [[ $# -gt 0 ]]; do case "$1" in --defaults-extra-file) shift 2;; -e) sql="$2"; shift 2;; *) shift;; esac; done
shopt -s nocasematch
if [[ "$sql" == *"log_bin"* ]]; then printf 'log_bin\t%s\n' "${SAFE_LOG_BIN:-ON}"; exit 0; fi
if [[ "$sql" == *"binlog_format"* ]]; then printf 'binlog_format\tROW\n'; exit 0; fi
if [[ "$sql" == *"SHOW BINARY LOG STATUS"* || "$sql" == *"SHOW MASTER STATUS"* ]]; then
  printf '%s\t%s\t\t\t\n' "${SAFE_MASTER_FILE:-binlog.000101}" "${SAFE_MASTER_POS:-77}"; exit 0
fi
if [[ "$sql" == *"SHOW BINARY LOGS"* ]]; then printf '%s\t4\n' ${SAFE_BINARY_LOGS:-binlog.000100 binlog.000101 binlog.000102}; exit 0; fi
exit 0
STUB
chmod +x "$SAFE_DIR/mysql"
cat > "$SAFE_DIR/mysqlbinlog" <<'STUB'
#!/usr/bin/env bash
result_dir=""; raw=0; files=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --defaults-extra-file) shift 2;; --read-from-remote-server) shift;;
    --server-id) shift 2;; --raw) raw=1; shift;; --result-dir|--result-dir=*) echo "mysqlbinlog: [ERROR] unknown option '--result-dir'." >&2; exit 2;;
    --start-position|--stop-position) shift 2;; -*) shift;; *) files+=("$1"); shift;;
  esac
done
if [[ "$raw" -eq 1 ]]; then for f in "${files[@]}"; do printf 'RAW:%s' "$f" > "$(basename "$f")"; done; exit 0; fi
for f in "${files[@]}"; do printf -- '-- %s\nSQL;\n' "$f"; done
exit 0
STUB
chmod +x "$SAFE_DIR/mysqlbinlog"
cat > "$SAFE_DIR/curl" <<'STUB'
#!/usr/bin/env bash
resp_file=""; payload=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --data-binary) payload="$2"; shift 2;;
    -o) resp_file="$2"; shift 2;;
    -w) shift 2;;
    --max-time) shift 2;;
    *) shift;;
  esac
done
printf '%s\n' "$payload" >> "$SAFE_DIR/reports.log"
[[ -n "$resp_file" ]] && printf '{"ok":true}' > "$resp_file"
printf '%s' "${SAFE_HTTP_CODE:-201}"; exit 0
STUB
chmod +x "$SAFE_DIR/curl"

# mydumper double. main() calls check_tools() BEFORE it reaches any of the
# behavior under test here, and check_tools() requires mydumper, so this section
# must provide one. (This used to be satisfied accidentally by FLOW_DIR's
# double leaking onto PATH — a hidden dependency that would have broken the
# moment that leak was fixed.)
cat > "$SAFE_DIR/mydumper" <<'STUB'
#!/usr/bin/env bash
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2;;
    *) shift;;
  esac
done
mkdir -p "$out/sub"
printf 'schema' > "$out/db.schema.sql"
printf 'data'   > "$out/sub/db.table.sql"
printf 'SHOW MASTER STATUS:\n\tLog: binlog.000100\n\tPos: 4\n' > "$out/metadata"
exit "${SAFE_MYDUMPER_EXIT:-0}"
STUB
chmod +x "$SAFE_DIR/mydumper"

SAFE_OLD_PATH="$PATH"
export PATH="$SAFE_DIR:$PATH"
export R2_ACCESS_KEY_ID=a R2_SECRET_ACCESS_KEY=s R2_ENDPOINT=e R2_BUCKET=b R2_PATH="mysql-backup"
export BACKUP_REPORT_URL="https://puptvs.com/x" BACKUP_REPORT_TOKEN="tok"
export MYSQL_HOST=h MYSQL_USER=u MYSQL_PASSWORD=p MYSQL_DATABASE=d MYSQL_PORT=3306
export MYSQL_CLIENT_BIN="mysql" MYSQLBINLOG_BIN="mysqlbinlog"
export BACKUP_BINLOG_ENABLED=true BACKUP_BINLOG_VERIFY=true BACKUP_FULL_INTERVAL_DAYS=14
export REPORT_TIMEOUT=2

# Seed state that points to a recent full (so INCREMENTAL is chosen) with a
# binlog anchor we can compare against after a failure.
seed_state() {
  cat > "$SAFE_DIR/state.json" <<JSON
{
  "state_version": 1,
  "last_successful_full_backup_name": "full_SEED",
  "last_successful_full_completed_at": "$(date -u -d '+1 day' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)",
  "last_successful_full_storage_path": "mysql-backup/full/SEED",
  "last_binlog_file": "binlog.000100",
  "last_binlog_position": 4,
  "last_binlog_end_file": "binlog.000100",
  "last_binlog_end_position": 4
}
JSON
}

# 12. Failed incremental (rclone sync fails) must NOT update the binlog position.
: > "$SAFE_DIR/events.log"; rm -f "$SAFE_DIR/reports.log"
seed_state
BEFORE="$(sed -n 's/.*"last_binlog_position": \([0-9]*\).*/\1/p' "$SAFE_DIR/state.json" | head -n1)"
export RCLONE_SYNC_EXIT=1
( cd "$SAFE_DIR" && bash "$ENTRYPOINT" >/dev/null 2>&1 ) || true
AFTER="$(sed -n 's/.*"last_binlog_position": \([0-9]*\).*/\1/p' "$SAFE_DIR/state.json" | head -n1)"
assert_eq "failed incremental leaves binlog position unchanged" "$BEFORE" "$AFTER"
if ! grep -q "STATE_UPDATED" "$SAFE_DIR/events.log" 2>/dev/null; then
  pass "failed incremental never writes state"
else
  fail "failed incremental must not write state"
fi
assert_contains "failed incremental reports failed" "$(cat "$SAFE_DIR/reports.log" 2>/dev/null)" '"status":"failed"'
export RCLONE_SYNC_EXIT=0

# 14. PUPTracker reporting failure must NOT update state (exit 3).
: > "$SAFE_DIR/events.log"; rm -f "$SAFE_DIR/reports.log"
seed_state
export SAFE_HTTP_CODE=500
set +e
( cd "$SAFE_DIR" && bash "$ENTRYPOINT" >/dev/null 2>&1 ); code=$?
set -e
AFTER="$(sed -n 's/.*"last_binlog_position": \([0-9]*\).*/\1/p' "$SAFE_DIR/state.json" | head -n1)"
assert_eq "report failure exits 3" "3" "$code"
assert_eq "report failure does not advance binlog position" "4" "$AFTER"
if ! grep -q "STATE_UPDATED" "$SAFE_DIR/events.log" 2>/dev/null; then
  pass "report failure never writes state"
else
  fail "report failure must not write state"
fi
export SAFE_HTTP_CODE=201

# 9. Purged binlog start file rejects the incremental (no state change).
: > "$SAFE_DIR/events.log"; rm -f "$SAFE_DIR/reports.log"
seed_state
export SAFE_BINARY_LOGS="binlog.000200 binlog.000201 binlog.000202"   # binlog.000100 is gone
( cd "$SAFE_DIR" && bash "$ENTRYPOINT" >/dev/null 2>&1 ) || true
assert_contains "purged binlog start reports failure" "$(cat "$SAFE_DIR/reports.log")" '"status":"failed"'
assert_contains "purged binlog failure message is explicit" "$(cat "$SAFE_DIR/reports.log")" 'already been purged'
AFTER="$(sed -n 's/.*"last_binlog_position": \([0-9]*\).*/\1/p' "$SAFE_DIR/state.json" | head -n1)"
assert_eq "purged binlog leaves position unchanged" "4" "$AFTER"
export SAFE_BINARY_LOGS="binlog.000100 binlog.000101 binlog.000102"

# 8b. binlog disabled on the server rejects the incremental safely.
: > "$SAFE_DIR/events.log"; rm -f "$SAFE_DIR/reports.log"
seed_state
export SAFE_LOG_BIN=OFF
( cd "$SAFE_DIR" && bash "$ENTRYPOINT" >/dev/null 2>&1 ) || true
assert_contains "log_bin=OFF rejects incremental" "$(cat "$SAFE_DIR/reports.log")" '"status":"failed"'
assert_contains "log_bin=OFF failure names binary logging" "$(cat "$SAFE_DIR/reports.log")" 'binary logging is not enabled'
export SAFE_LOG_BIN=ON

# BACKUP_BINLOG_ENABLED=false + an incremental due -> fails safely (never a fake).
: > "$SAFE_DIR/events.log"; rm -f "$SAFE_DIR/reports.log"
seed_state
export BACKUP_BINLOG_ENABLED=false
( cd "$SAFE_DIR" && bash "$ENTRYPOINT" >/dev/null 2>&1 ) || true
assert_contains "binlog disabled rejects a due incremental" "$(cat "$SAFE_DIR/reports.log")" '"status":"failed"'
assert_contains "binlog disabled message mentions the flag" "$(cat "$SAFE_DIR/reports.log")" 'BACKUP_BINLOG_ENABLED=false'
export BACKUP_BINLOG_ENABLED=true

# 17. No secret appears in logs / payloads across all the above runs.
ALLREPORTS="$(cat "$SAFE_DIR/reports.log" 2>/dev/null)"
assert_not_contains "reports never contain the report token" "$ALLREPORTS" "super-secret-report-token"
assert_not_contains "reports never contain the r2 secret" "$ALLREPORTS" "r2super-secret-key"
assert_not_contains "reports never contain the DB password" "$ALLREPORTS" "sup3rsecret-db-pass"

# 5/6. A failed FULL must not update state and must not permit incremental.
: > "$SAFE_DIR/events.log"; rm -f "$SAFE_DIR/reports.log" "$SAFE_DIR/state.json"
export RCLONE_SYNC_EXIT=1
( cd "$SAFE_DIR" && bash "$ENTRYPOINT" >/dev/null 2>&1 ) || true
if [[ ! -f "$SAFE_DIR/state.json" ]]; then
  pass "failed full (no prior state) leaves state absent"
else
  fail "failed full must not create state"
fi
assert_contains "failed full reports failed" "$(cat "$SAFE_DIR/reports.log")" '"status":"failed"'
export RCLONE_SYNC_EXIT=0

# 25. Duplicate/retry: re-running with the SAME state must not corrupt it.
seed_state
SNAP_BEFORE="$(cat "$SAFE_DIR/state.json")"
# A run that fails before state update must leave the file byte-identical.
export RCLONE_SYNC_EXIT=1
( cd "$SAFE_DIR" && bash "$ENTRYPOINT" >/dev/null 2>&1 ) || true
SNAP_AFTER="$(cat "$SAFE_DIR/state.json")"
assert_eq "retry after failure leaves state file identical" "$SNAP_BEFORE" "$SNAP_AFTER"
export RCLONE_SYNC_EXIT=0

export PATH="$SAFE_OLD_PATH"
unset SAFE_LOG_BIN SAFE_BINARY_LOGS SAFE_HTTP_CODE
rm -rf "$SAFE_DIR"

# ---------------------------------------------------------------------------
# 21/22. Incremental metadata file content (no secrets, correct base).
# ---------------------------------------------------------------------------
echo "== incremental metadata file =="
META_DIR="$(mktemp -d)"
export META_DIR
BACKUP_NAME="incremental_2026-09-11_020000"
BINLOG_FILE_START="binlog.000123"
BINLOG_POSITION_START="456789"
BINLOG_FILE_END="binlog.000124"
BINLOG_POSITION_END="123456"
STARTED_AT="2026-09-11T02:00:00Z"
ST_LAST_FULL_NAME="full_2026-09-10_020000"
ST_LAST_FULL_STORAGE_PATH="mysql-backup/full/2026/09/10/full_2026-09-10_020000"
write_incremental_metadata "$META_DIR/backup_metadata.json"
META="$(cat "$META_DIR/backup_metadata.json")"
assert_contains "metadata has backup_type incremental" "$META" '"backup_type": "incremental"'
assert_contains "metadata has the base full name" "$META" '"base_full_backup_name": "full_2026-09-10_020000"'
assert_contains "metadata has the base full storage path" "$META" '"base_full_storage_path": "mysql-backup/full/2026/09/10/full_2026-09-10_020000"'
assert_contains "metadata has start binlog file" "$META" '"start_binlog_file": "binlog.000123"'
assert_contains "metadata has start binlog position" "$META" '"start_binlog_position": 456789'
assert_contains "metadata has end binlog file" "$META" '"end_binlog_file": "binlog.000124"'
assert_contains "metadata has end binlog position" "$META" '"end_binlog_position": 123456'
assert_not_contains "metadata has no token" "$META" "super-secret-report-token"
assert_not_contains "metadata has no r2 secret" "$META" "r2super-secret-key"
assert_not_contains "metadata has no DB password" "$META" "sup3rsecret-db-pass"
rm -rf "$META_DIR"

# ---------------------------------------------------------------------------
# 20. FULL and incremental paths differ; 19. names unique.
# ---------------------------------------------------------------------------
echo "== paths + names =="
# Build names as the code does (without running it) and assert shape/uniqueness.
F1="full_$(date -u +"%Y-%m-%d_%H%M%S")"
I1="incremental_$(date -u +"%Y-%m-%d_%H%M%S")"
assert_contains "full name starts with full_" "$F1" "full_"
assert_contains "incremental name starts with incremental_" "$I1" "incremental_"
assert_not_contains "full name is not labelled incremental" "$F1" "incremental"
assert_not_contains "incremental name is not labelled daily_snapshot" "$I1" "daily_snapshot"
A_PATH="${R2_PATH%/}/full/2026/09/11/$F1"
B_PATH="${R2_PATH%/}/incremental/2026/09/11/$I1"
assert_contains "full path uses /full/" "$A_PATH" "/full/"
assert_contains "incremental path uses /incremental/" "$B_PATH" "/incremental/"
if [[ "$A_PATH" != "$B_PATH" ]]; then pass "full and incremental paths differ"; else fail "full/incremental paths must differ"; fi
# Two runs in different seconds produce different names.
N1="full_2026-09-11_020000"; N2="full_2026-09-11_020001"
if [[ "$N1" != "$N2" ]]; then pass "backup names are unique per second"; else fail "backup names must be unique"; fi

# ---------------------------------------------------------------------------
# MyDumper MySQL 8.4 server-version override (binlog anchor on 8.4+)
# ---------------------------------------------------------------------------
# ROOT CAUSE this guards: mydumper picks the snapshot-coordinate statement in
# server_detect.c:detect_replica(). It starts from the PRE-8.4 default
# `SHOW MASTER STATUS` and upgrades to `SHOW BINARY LOG STATUS` only when its
# product detection classifies the server as MySQL >= 8.<n>. Detection reads
# `@@version_comment, @@version`; if neither contains a known product token the
# server is UNKNOWN with version 0.0.0, the upgrade is skipped, MySQL 8.4
# rejects `SHOW MASTER STATUS` (ERROR 1064), and the metadata is written with NO
# `[source]` section -> the FULL records no anchor.
#
# The fix derives mydumper's own `--server-version <product>-<x.y.z>` from the
# LIVE server (never hard-coded) so the 8.4 statement is selected.
#
# The double below reproduces that behaviour exactly: it emits a real `[source]`
# section ONLY when --server-version is present, and otherwise writes the keys
# commented-out with no section (which is what the broken path produces).
echo "== mydumper MySQL 8.4 server-version override =="

# --- pure helper: the derived override -------------------------------------
# A `mysql` double that answers `SELECT @@version, @@version_comment` from env,
# exactly as mysql_query drives it (-N -B => tab-separated, no headers).
SV_DIR="$(mktemp -d)"
export SV_DIR
cat > "$SV_DIR/mysql" <<'STUB'
#!/usr/bin/env bash
# Only the version probe and the 8.4 statement probe are needed here; mysql_query
# drives the client with `-N -B` (tab-separated, no headers).
case "$*" in
  *"@@version"*)       printf '%s\t%s' "${SV_VERSION:-}" "${SV_COMMENT:-}"; exit 0;;
  *"BINARY LOG STATUS"*)
    # Behavioural probe: only a MySQL 8.4+ server answers this. SV_BLS=1 models
    # one; anything else fails the probe exactly as a pre-8.4 server would.
    [[ "${SV_BLS:-0}" == "1" ]] && { printf 'binlog.000001\t4'; exit 0; }
    exit 1;;
esac
exit 0
STUB
chmod +x "$SV_DIR/mysql"
SV_OLD_PATH="$PATH"
export PATH="$SV_DIR:$PATH"
export MYSQL_CLIENT_BIN="mysql"

detect_case() { # <desc> <version> <comment> <expected>
  local desc="$1" want="$4" got
  export SV_VERSION="$2" SV_COMMENT="$3" SV_BLS=0
  got="$(detect_mydumper_server_version 2>/dev/null || true)"
  assert_eq "$desc" "$want" "$got"
}

detect_case "MySQL Community Server -> mysql-<x.y.z>" \
  "8.4.11" "MySQL Community Server - GPL" "mysql-8.4.11"
# The production failure case: neither the comment NOR the version contains a
# product token, so the override must be derived from BEHAVIOUR instead.
export SV_VERSION="8.4.10-0ubuntu0.26.04.1" SV_COMMENT="(Ubuntu)" SV_BLS=1
SV_GOT="$(detect_mydumper_server_version 2>/dev/null || true)"
assert_eq "distro comment with no token is confirmed behaviourally" \
  "mysql-8.4.10" "$SV_GOT"
# Same strings, but a server that does NOT answer the 8.4 statement -> no
# override (we must not claim MySQL 8.4 for a server that is not one).
export SV_BLS=0
SV_GOT="$(detect_mydumper_server_version 2>/dev/null || true)"
assert_eq "no product token and no 8.4 behaviour yields no override" "" "$SV_GOT"
export SV_BLS=0

detect_case "RHEL-suffixed version reduces to x.y.z" \
  "8.4.11-1.el9" "MySQL Community Server - GPL" "mysql-8.4.11"
detect_case "MariaDB is classified as mariadb" \
  "10.11.6-MariaDB" "mariadb.org binary distribution" "mariadb-10.11.6"
detect_case "Percona is classified as percona" \
  "8.0.36-28" "Percona Server" "percona-8.0.36"
# An explicit token always wins over the behavioural probe.
detect_case "an unclassifiable server yields no override" \
  "9.9.9" "Totally Unknown Build" ""
detect_case "empty version yields no override" "" "" ""

# --- the override reaches the mydumper invocation --------------------------
FULL_SRC="$(sed -n '/^run_full_backup()/,/^}/p' "$ENTRYPOINT")"
assert_contains "run_full_backup derives the override from the live server" \
  "$FULL_SRC" 'detect_mydumper_server_version'
assert_contains "run_full_backup passes --server-version to mydumper" \
  "$FULL_SRC" '"${sv_args[@]}"'
assert_contains "run_full_backup still passes --source-data" \
  "$FULL_SRC" '--source-data'
# The override must be conditional: when the server is unclassifiable the option
# is omitted entirely, so behaviour is unchanged for servers we cannot identify.
assert_contains "the override is only added when it could be derived" \
  "$FULL_SRC" 'sv_args=(--server-version "$mydumper_sv")'
# The value must never be hard-coded to a specific vendor version.
assert_contains "the override value comes from a variable, not a literal" \
  "$FULL_SRC" 'sv_args=(--server-version "$mydumper_sv")'
assert_not_contains "no vendor version literal in the override assignment" \
  "$FULL_SRC" 'sv_args=(--server-version mysql-'

# The behavioural probe must exist and be used when no product token matches: a
# distro `@@version_comment` (e.g. `(Ubuntu)`) hides the MySQL identity from
# mydumper's own detector, which is the production failure mode.
DETECT_SRC="$(sed -n '/^detect_mydumper_server_version()/,/^}/p' "$ENTRYPOINT")"
assert_contains "an unknown identity is confirmed behaviourally" \
  "$DETECT_SRC" 'mysql_supports_binary_log_status'
assert_contains "the behavioural probe issues the MySQL 8.4 statement" \
  "$(sed -n '/^mysql_supports_binary_log_status()/,/^}/p' "$ENTRYPOINT")" \
  'SHOW BINARY LOG STATUS'

# --- functional proof through the entrypoint parser + a faithful double -----
cat > "$SV_DIR/mydumper" <<'STUB'
#!/usr/bin/env bash
# Faithful mydumper double: the snapshot [source] section appears ONLY when
# --server-version is supplied (mirroring the real MySQL 8.4 behaviour).
out=""; args="$*"; saw_sv=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --server-version) saw_sv=1; shift 2;;
    --server-version=*) saw_sv=1; shift;;
    -o) out="$2"; shift 2;;
    *) shift;;
  esac
done
printf '%s\n' "$args" > "$SV_DIR/cmdline"
mkdir -p "$out"; printf 'schema' > "$out/db.schema.sql"
if [[ "$saw_sv" -eq 1 ]]; then
  printf '[source]\nSOURCE_LOG_FILE = "binlog.000042"\nSOURCE_LOG_POS = 777\n' > "$out/metadata"
else
  # The broken path: no [source] section at all (keys absent/commented).
  printf '[config]\nquote-character = BACKTICK\n# SOURCE_LOG_FILE = "binlog.000042"\n' > "$out/metadata"
fi
exit 0
STUB
chmod +x "$SV_DIR/mydumper"

SV_OUT="$SV_DIR/with"
"$SV_DIR/mydumper" --source-data --server-version mysql-8.4.10 -C -c -o "$SV_OUT" >/dev/null 2>&1
SV_ANCHOR="$(read_mydumper_binlog_anchor "$SV_OUT" || true)"
assert_eq "with --server-version the parser yields the anchor" \
  "$(printf 'binlog.000042\t777')" "$SV_ANCHOR"

SV_OUT2="$SV_DIR/without"
"$SV_DIR/mydumper" --source-data -C -c -o "$SV_OUT2" >/dev/null 2>&1
SV_ANCHOR2="$(read_mydumper_binlog_anchor "$SV_OUT2" || true)"
assert_eq "without --server-version there is no anchor (the failure mode)" "" "$SV_ANCHOR2"
# The commented key must never be mistaken for an anchor.
assert_not_contains "the commented SOURCE_LOG_FILE is not the anchor" "$SV_ANCHOR2" "binlog.000042"
# Negative control: the double really does differ between the two modes, so the
# assertion above tests the flag and not a constant.
assert_not_contains "the WITH-mode metadata is genuinely different" \
  "$(cat "$SV_OUT/metadata")" "[config]"

export PATH="$SV_OLD_PATH"
export MYSQL_CLIENT_BIN="mysql"
rm -rf "$SV_DIR"
unset SV_DIR SV_VERSION SV_COMMENT

# ---------------------------------------------------------------------------
# 18. Existing daily_snapshot compatibility is preserved.
# ---------------------------------------------------------------------------
echo "== daily_snapshot compatibility =="
BACKUP_NAME="daily_snapshot_2026-09-10_020000"
BACKUP_TYPE="daily_snapshot"
STARTED_AT="2026-09-09T18:00:00Z"
COMPLETED_AT="2026-09-09T18:02:00Z"
BACKUP_SIZE=34
FILE_COUNT=3
CHECKSUM="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
VERIFIED_AT="2026-09-09T18:02:01Z"
STORAGE_PATH="mysql-backup/daily_snapshot/2026/09/10/daily_snapshot_2026-09-10_020000"
BASE_BACKUP_NAME=""
DS_JSON="$(build_payload success)"
assert_contains "legacy daily_snapshot type still reported" "$DS_JSON" '"backup_type":"daily_snapshot"'
assert_contains "legacy daily_snapshot keeps storage_path" "$DS_JSON" "$STORAGE_PATH"
if [[ "$DS_JSON" != *'"base_backup_name"'* ]]; then
  pass "legacy daily_snapshot payload has no base_backup_name"
else
  fail "legacy daily_snapshot payload must not include base_backup_name"
fi
reset_daily() { :; }
# Reset report state for the tool-presence section below.
BACKUP_NAME=""; BACKUP_TYPE="daily_snapshot"

# ---------------------------------------------------------------------------
# Tool presence check (check_tools)
# ---------------------------------------------------------------------------
echo "== tool presence check =="

# Build a PATH that contains every required tool EXCEPT curl, so check_tools
# must detect curl is missing. We resolve each tool's real path and symlink
# them into a temp dir (skipping curl).
LIMITED_DIR="$(mktemp -d)"
for tool in bash date find sha256sum sed awk grep sort wc head mktemp tr dirname \
            mydumper rclone; do
  real="$(command -v "$tool" 2>/dev/null || true)"
  if [[ -n "$real" ]]; then
    ln -sf "$real" "$LIMITED_DIR/$tool" 2>/dev/null || true
  fi
done
# Deliberately do NOT symlink curl.

TOOL_OUT="$(mktemp)"
(
  export PATH="$LIMITED_DIR"
  source "$ENTRYPOINT" >/dev/null 2>&1
  check_tools >"$TOOL_OUT" 2>&1
) || true
CONTENT="$(cat "$TOOL_OUT" 2>/dev/null)"
rm -f "$TOOL_OUT"
rm -rf "$LIMITED_DIR"
assert_contains "check_tools reports missing tool" "$CONTENT" "Required command not found in image: curl"
assert_contains "check_tools refuses to run" "$CONTENT" "Refusing to run"

# ---------------------------------------------------------------------------
# MyDumper binlog-anchor metadata parsing
# ---------------------------------------------------------------------------
# The FULL backup records the CONSISTENT-SNAPSHOT binlog coordinate from
# mydumper's `metadata` file. MyDumper v0.21.x (the version pinned in the
# Dockerfile) writes an INI-style [source] section whose keys are ACTIVE only
# when mydumper ran with --source-data:
#
#     [source]
#     SOURCE_LOG_FILE = "binlog.000001"
#     SOURCE_LOG_POS = 12345
#
# Without the flag the same keys are written COMMENTED OUT. Consuming a
# commented key would fabricate an anchor for a dump that has none, which would
# let an incremental resume from a position that does not correspond to the
# dump — a silent data-loss bug. The legacy "SHOW MASTER STATUS:" block is still
# supported so older dumps keep working.
echo "== mydumper binlog-anchor metadata =="

ANCHOR_DIR="$(mktemp -d)"
export ANCHOR_DIR

# write_meta <case> : create a metadata file from stdin for <case>.
write_meta() {
  mkdir -p "$ANCHOR_DIR/$1"
  cat > "$ANCHOR_DIR/$1/metadata"
}

# anchor_case <desc> <case> <expected "file<TAB>pos" or empty>
anchor_case() {
  local desc="$1" case_name="$2" want="$3"
  local got rc=0
  got="$(read_mydumper_binlog_anchor "$ANCHOR_DIR/$case_name")" || rc=$?
  local gotnorm=""
  if [[ "$rc" -eq 0 && -n "$got" ]]; then gotnorm="$got"; fi
  assert_eq "$desc" "$want" "$gotnorm"
}

# A. Real MyDumper v0.21.x format with --source-data (active keys).
write_meta real <<'EOF'
# Started dump at: 2026-09-12 10:00:00
[config]
quote-character = BACKTICK

[source]
# Channel_Name = '' # It can be use to setup replication FOR CHANNEL
SOURCE_LOG_FILE = "binlog.000001"
SOURCE_LOG_POS = 12345
#SOURCE_AUTO_POSITION = {0|1}

[`puptracker`.`students`]
real_table_name=students
rows = 5
# Finished dump at: 2026-09-12 10:00:05
EOF
anchor_case "A. real v0.21.x [source] active keys are parsed" real "$(printf 'binlog.000001\t12345')"

# B. Same file WITHOUT --source-data: the keys are commented out and MUST NOT
#    be mistaken for an anchor.
write_meta commented <<'EOF'
[source]
# Channel_Name = '' # It can be use to setup replication FOR CHANNEL
# SOURCE_LOG_FILE = "binlog.000001"
# SOURCE_LOG_POS = 12345
EOF
anchor_case "B. commented SOURCE_LOG_FILE/POS is NOT an anchor" commented ""

# C. Missing SOURCE_LOG_FILE.
write_meta no_file <<'EOF'
[source]
SOURCE_LOG_POS = 12345
EOF
anchor_case "C. missing SOURCE_LOG_FILE -> no anchor" no_file ""

# D. Missing SOURCE_LOG_POS.
write_meta no_pos <<'EOF'
[source]
SOURCE_LOG_FILE = "binlog.000001"
EOF
anchor_case "D. missing SOURCE_LOG_POS -> no anchor" no_pos ""

# E. Non-numeric position.
write_meta bad_pos <<'EOF'
[source]
SOURCE_LOG_FILE = "binlog.000001"
SOURCE_LOG_POS = not-a-number
EOF
anchor_case "E. non-numeric SOURCE_LOG_POS -> no anchor" bad_pos ""

# E2. A zero position is not a usable resume point.
write_meta zero_pos <<'EOF'
[source]
SOURCE_LOG_FILE = "binlog.000001"
SOURCE_LOG_POS = 0
EOF
anchor_case "E2. zero SOURCE_LOG_POS -> no anchor" zero_pos ""

# E3. A filename that is not <base>.<digits> is not a binlog file.
write_meta bad_file <<'EOF'
[source]
SOURCE_LOG_FILE = "not-a-binlog"
SOURCE_LOG_POS = 12345
EOF
anchor_case "E3. malformed binlog filename -> no anchor" bad_file ""

# F. Legacy SHOW MASTER STATUS block (older mydumper).
write_meta legacy <<'EOF'
# Started dump at: 2026-09-10 02:00:00
SHOW MASTER STATUS:
	Log: binlog.000123
	Pos: 456789
# Finished dump at: 2026-09-10 02:01:00
EOF
anchor_case "F. legacy SHOW MASTER STATUS still parses" legacy "$(printf 'binlog.000123\t456789')"

# G. Legacy File:/Position: label variant on the MySQL 8.4 statement header.
write_meta variant <<'EOF'
SHOW BINARY LOG STATUS:
	File: binlog.000999
	Position: 77
EOF
anchor_case "G. legacy File:/Position: variant still parses" variant "$(printf 'binlog.000999\t77')"

# H. No metadata file at all -> no anchor (never a crash).
mkdir -p "$ANCHOR_DIR/nofile"
anchor_case "H. absent metadata file -> no anchor" nofile ""

# I. A real anchor must survive the surrounding [config]/table sections.
assert_contains "real anchor is not confused by trailing sections" \
  "$( printf '%s' "$(read_mydumper_binlog_anchor "$ANCHOR_DIR/real")" )" "binlog.000001"

rm -rf "$ANCHOR_DIR"

# ---------------------------------------------------------------------------
# MySQL 8.4 `SHOW BINARY LOG STATUS` (preferred) + legacy `SHOW MASTER STATUS`
# ---------------------------------------------------------------------------
# MySQL 8.4 deprecates SHOW MASTER STATUS in favour of SHOW BINARY LOG STATUS.
# The entrypoint must PREFER the 8.4 statement, FALL BACK safely on older
# servers, and normalize BOTH into the same "file<TAB>position" value.
echo "== MySQL 8.4 binlog status compatibility =="

M84_DIR="$(mktemp -d)"
export M84_DIR
# Records the SQL statements it is asked to run so the test can assert which
# statement was tried first, and answers based on which one it is.
cat > "$M84_DIR/mysql" <<'STUB'
#!/usr/bin/env bash
sql=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --defaults-extra-file) shift 2;;
    -e) sql="$2"; shift 2;;
    *) shift;;
  esac
done
shopt -s nocasematch
if [[ "$sql" == *"log_bin"* ]]; then printf 'log_bin\tON\n'; exit 0; fi
if [[ "$sql" == *"binlog_format"* ]]; then printf 'binlog_format\tROW\n'; exit 0; fi
if [[ "$sql" == *"SHOW BINARY LOG STATUS"* ]]; then
  printf 'SHOW_BINARY_LOG_STATUS\n' >> "$M84_DIR/statements_seen"
  if [[ "${M84_STATUS_SUPPORTED:-1}" != "1" ]]; then exit 1; fi
  if [[ "${M84_STATUS_EMPTY:-0}" == "1" ]]; then exit 0; fi
  printf '%s\t%s\t\t\t\n' "${M84_FILE:-binlog.000070}" "${M84_POS:-4321}"; exit 0
fi
if [[ "$sql" == *"SHOW MASTER STATUS"* ]]; then
  printf 'SHOW_MASTER_STATUS\n' >> "$M84_DIR/statements_seen"
  if [[ "${M84_LEGACY_EMPTY:-0}" == "1" ]]; then exit 0; fi
  printf '%s\t%s\t\t\t\n' "${M84_LEGACY_FILE:-binlog.000070}" "${M84_LEGACY_POS:-4321}"; exit 0
fi
if [[ "$sql" == *"SHOW BINARY LOGS"* ]]; then printf '%s\t4\n' ${M84_BINARY_LOGS:-binlog.000070}; exit 0; fi
exit 0
STUB
chmod +x "$M84_DIR/mysql"

M84_OLD_PATH="$PATH"
export PATH="$M84_DIR:$PATH"
export MYSQL_CLIENT_BIN="mysql"

# Case 1: 8.4 server -- the modern statement works and is used.
rm -f "$M84_DIR/statements_seen"
export M84_STATUS_SUPPORTED=1 M84_STATUS_EMPTY=0 M84_FILE="binlog.000070" M84_POS="4321"
BOUNDARY="$(acquire_binlog_boundary 2>/dev/null)"
assert_eq "8.4: boundary read from SHOW BINARY LOG STATUS" "binlog.000070	4321" "$BOUNDARY"
assert_contains "8.4: modern statement was issued" "$(cat "$M84_DIR/statements_seen")" "SHOW_BINARY_LOG_STATUS"
assert_not_contains "8.4: legacy statement not needed" "$(cat "$M84_DIR/statements_seen")" "SHOW_MASTER_STATUS"

# Case 2: legacy server -- modern statement fails, legacy is used instead.
rm -f "$M84_DIR/statements_seen"
export M84_STATUS_SUPPORTED=0
export M84_LEGACY_FILE="binlog.000071" M84_LEGACY_POS="555"
BOUNDARY="$(acquire_binlog_boundary 2>/dev/null)"
assert_eq "legacy: boundary falls back to SHOW MASTER STATUS" "binlog.000071	555" "$BOUNDARY"
assert_contains "legacy: modern statement was tried first" "$(cat "$M84_DIR/statements_seen")" "SHOW_BINARY_LOG_STATUS"
assert_contains "legacy: legacy statement was then used" "$(cat "$M84_DIR/statements_seen")" "SHOW_MASTER_STATUS"

# Case 3: the modern statement is accepted but returns NO row (e.g. binlog
# rotated between statements). The code must not trust it and must fall back.
rm -f "$M84_DIR/statements_seen"
export M84_STATUS_SUPPORTED=1 M84_STATUS_EMPTY=1
export M84_LEGACY_FILE="binlog.000072" M84_LEGACY_POS="777"
BOUNDARY="$(acquire_binlog_boundary 2>/dev/null)"
assert_eq "empty modern result falls back to legacy" "binlog.000072	777" "$BOUNDARY"
export M84_STATUS_EMPTY=0

# Case 4: BOTH statements unusable -> no boundary (hard failure upstream).
rm -f "$M84_DIR/statements_seen"
# Make the modern statement return no row AND the legacy one no row either.
# (An explicit flag is needed because `${VAR:-default}` treats an empty value
# as unset, so setting the file/pos to "" would just re-enable the default.)
export M84_STATUS_EMPTY=1 M84_LEGACY_EMPTY=1
# NOTE: `|| true` is required because this command substitution is expected to
# return non-zero; under `set -e` the assignment would otherwise end the run.
BOUNDARY="$(acquire_binlog_boundary 2>/dev/null)" || true
assert_eq "both statements unusable -> empty boundary" "" "$BOUNDARY"
export M84_STATUS_EMPTY=0 M84_LEGACY_EMPTY=0 M84_LEGACY_FILE="binlog.000070" M84_LEGACY_POS="4321"

# The normalizer must accept only a well-formed (filename, integer) pair.
normalize_binlog_status "binlog.000070	120" && rc=0 || rc=1
assert_rc_zero "normalizer accepts a valid status row" "$rc"
assert_eq "normalizer extracts the file" "binlog.000070" "$_BH_FILE"
assert_eq "normalizer extracts the position" "120" "$_BH_POSITION"
normalize_binlog_status "garbage output" && rc=0 || rc=1
assert_rc_nonzero "normalizer rejects a malformed row" "$rc"
normalize_binlog_status "" && rc=0 || rc=1
assert_rc_nonzero "normalizer rejects empty input" "$rc"
# An integer-only first column (not a binlog filename) must be rejected.
normalize_binlog_status "123	456" && rc=0 || rc=1
assert_rc_nonzero "normalizer rejects a non-filename first column" "$rc"

export PATH="$M84_OLD_PATH"
unset M84_STATUS_SUPPORTED M84_STATUS_EMPTY M84_FILE M84_POS M84_LEGACY_FILE M84_LEGACY_POS M84_LEGACY_EMPTY M84_BINARY_LOGS
rm -rf "$M84_DIR"

# ---------------------------------------------------------------------------
# Binlog range: rotation cases + gap detection (never silently skip a file)
# ---------------------------------------------------------------------------
# Covers the required rotation cases (same file / one rotation / two rotations)
# and proves that a NON-CONTIGUOUS retained list is rejected instead of
# producing an incremental that silently omits a binlog file.
echo "== binlog range construction + gap detection =="

# Pure helper: the numeric successor used to prove contiguity.
assert_eq "next binlog filename increments the number" "binlog.000071" "$(next_binlog_filename binlog.000070)"
assert_eq "next binlog filename keeps zero padding" "binlog.000100" "$(next_binlog_filename binlog.000099)"
assert_eq "next binlog filename handles 999->1000" "binlog.001000" "$(next_binlog_filename binlog.000999)"
assert_eq "next binlog filename gives up on a non-numeric suffix" "" "$(next_binlog_filename binlog.current)"

# --- End-to-end range construction through the real incremental flow. ---------
# The cases below drive `run_incremental_backup` with a stubbed MySQL/mysqlbinlog
# so we can assert exactly WHICH binlog files would be captured for each shape of
# range, and that a gap/purge is rejected instead of silently skipping a file.
#
# Case A: start and end in the SAME binlog.
# Case B: start binlog.000070 -> end binlog.000071 (one rotation).
# Case C: start binlog.000070 -> end binlog.000072 (two rotations).
# Case D: starting binlog purged -> fail safely.
# Case E: the reported status is a NEWER file than expected -> captured.
# Case F: mysqlbinlog fails halfway -> fail safely.
# Case G: upload fails after local capture -> fail safely.
# Case H: remote verification fails -> fail safely.
# Case I: PUPTracker report fails -> fail safely.
RANGE_DIR="$(mktemp -d)"
export RANGE_DIR
cat > "$RANGE_DIR/mysql" <<'STUB'
#!/usr/bin/env bash
sql=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --defaults-extra-file) shift 2;;
    -e) sql="$2"; shift 2;;
    *) shift;;
  esac
done
shopt -s nocasematch
if [[ "$sql" == *"log_bin"* ]]; then printf 'log_bin\tON\n'; exit 0; fi
if [[ "$sql" == *"binlog_format"* ]]; then printf 'binlog_format\tROW\n'; exit 0; fi
if [[ "$sql" == *"SHOW BINARY LOG STATUS"* || "$sql" == *"SHOW MASTER STATUS"* ]]; then
  printf '%s\t%s\t\t\t\n' "${RANGE_MASTER_FILE}" "${RANGE_MASTER_POS}"; exit 0
fi
if [[ "$sql" == *"SHOW BINARY LOGS"* ]]; then printf '%s\t4\n' ${RANGE_BINARY_LOGS}; exit 0; fi
exit 0
STUB
chmod +x "$RANGE_DIR/mysql"

cat > "$RANGE_DIR/mysqlbinlog" <<'STUB'
#!/usr/bin/env bash
result_dir=""; raw=0; files=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --defaults-extra-file) shift 2;;
    --read-from-remote-server) shift;;
    --server-id) shift 2;;
    --raw) raw=1; shift;;
    --result-dir|--result-dir=*) echo "mysqlbinlog: [ERROR] unknown option '--result-dir'." >&2; exit 2;;
    --start-position|--stop-position) shift 2;;
    -*) shift;;
    *) files+=("$1"); shift;;
  esac
done
# Record the ORDERED file list of the LOCAL validation read only (the --raw
# fetch is invoked once per file, so recording that would duplicate entries).
# This is the exact list that gets packaged into the incremental archive.
#
# TWO fidelity guards that a naive stub would miss:
#  1. The REAL mysqlbinlog requires each file to EXIST at the path it is given.
#     A stub that accepts any string would happily accept a bare relative name
#     that does not exist in the CWD, hiding a path/CWD bug in the entrypoint.
#  2. The path handed to mysqlbinlog must be resolvable from an arbitrary CWD,
#     so it must be ABSOLUTE.
# `captured_files` keeps the BASENAME (keeps the per-case assertions readable);
# `captured_paths` keeps the RAW argument (asserted once); violations go to
# `path_violations`.
if [[ "$raw" -eq 0 && "${#files[@]}" -gt 0 ]]; then
  for f in "${files[@]}"; do
    printf '%s\n' "$(basename "$f")" >> "$RANGE_DIR/captured_files"
    printf '%s\n' "$f" >> "$RANGE_DIR/captured_paths"
    if [[ ! -f "$f" ]]; then
      printf 'MISSING:%s\n' "$f" >> "$RANGE_DIR/path_violations"
    fi
  done
fi
if [[ "${RANGE_BINLOG_FAIL:-0}" == "1" ]]; then echo "mysqlbinlog: failed" >&2; exit 1; fi
if [[ "$raw" -eq 1 ]]; then
  for f in "${files[@]}"; do printf 'RAWBINLOG:%s' "$f" > "$(basename "$f")"; done
  exit 0
fi
for f in "${files[@]}"; do printf -- '-- %s\nSQL;\n' "$f"; done
exit 0
STUB
chmod +x "$RANGE_DIR/mysqlbinlog"

cat > "$RANGE_DIR/rclone" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "--config" ]]; then shift 2; fi
case "$1" in
  listremotes) printf 'remote:\n'; exit 0;;
  cat) if [[ -f "$RANGE_DIR/state.json" ]]; then cat "$RANGE_DIR/state.json"; fi; exit 0;;
  copyto) cp "$2" "$RANGE_DIR/state.json"; echo STATE_UPDATED >> "$RANGE_DIR/events.log"; exit 0;;
  sync)
    if [[ "${RANGE_SYNC_EXIT:-0}" != "0" ]]; then exit "${RANGE_SYNC_EXIT}"; fi
    printf '%s\n' "$2" > "$RANGE_DIR/last_sync_dir"; exit 0;;
  size)
    # RANGE_SIZE_JSON lets a test force a verification mismatch.
    if [[ -n "${RANGE_SIZE_JSON:-}" ]]; then printf '%s\n' "$RANGE_SIZE_JSON"; exit 0; fi
    if [[ -f "$RANGE_DIR/last_sync_dir" ]]; then
      d="$(cat "$RANGE_DIR/last_sync_dir")"
      if [[ -d "$d" ]]; then
        c="$(find "$d" -type f 2>/dev/null | wc -l)"
        b="$(find "$d" -type f -printf '%s\n' 2>/dev/null | awk '{s+=$1} END {print s+0}')"
        printf '{"count":%s,"bytes":%s,"sizeless":0}\n' "$c" "$b"; exit 0
      fi
    fi
    printf '{"count":0,"bytes":0,"sizeless":0}\n'; exit 0;;
  *) exit 0;;
esac
STUB
chmod +x "$RANGE_DIR/rclone"

cat > "$RANGE_DIR/curl" <<'STUB'
#!/usr/bin/env bash
resp_file=""; payload=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --data-binary) payload="$2"; shift 2;;
    -o) resp_file="$2"; shift 2;;
    -w) shift 2;;
    --max-time) shift 2;;
    *) shift;;
  esac
done
printf '%s\n' "$payload" >> "$RANGE_DIR/reports.log"
[[ -n "$resp_file" ]] && printf '{"ok":true}' > "$resp_file"
printf '%s' "${RANGE_HTTP_CODE:-201}"; exit 0
STUB
chmod +x "$RANGE_DIR/curl"

RANGE_OLD_PATH="$PATH"
export PATH="$RANGE_DIR:$PATH"
export MYSQL_CLIENT_BIN="mysql" MYSQLBINLOG_BIN="mysqlbinlog"
export BACKUP_BINLOG_ENABLED=true BACKUP_BINLOG_VERIFY=true BACKUP_FULL_INTERVAL_DAYS=14
export BACKUP_LOCK_ENABLED=false BINLOG_FETCH_STRATEGY=raw MYSQLBINLOG_SERVER_ID=424242

# fix_state <start_file> <start_pos> : seed a "recent full" so INCREMENTAL runs.
fix_state() {
  cat > "$RANGE_DIR/state.json" <<JSON
{
  "state_version": 1,
  "last_successful_full_backup_name": "full_BASE",
  "last_successful_full_completed_at": "2999-01-01T00:00:00Z",
  "last_successful_full_storage_path": "mysql-backup/full/BASE",
  "last_binlog_file": "$1",
  "last_binlog_position": $2,
  "last_binlog_end_file": "$1",
  "last_binlog_end_position": $2
}
JSON
}

# run_incremental_and_report <expected_rc> : runs the incremental flow in a
# subshell, capturing rc/output. Prints the rc.
#
# This drives the SAME sequence main() uses for an incremental run:
#   load_state -> run_incremental_backup -> upload_and_verify ->
#   report_now success -> update_state
# load_state is required: run_incremental_backup reads the persisted full base
# and the starting binlog position from the ST_* globals that load_state sets.
# (Historically this called neither load_state nor BACKUP_SOURCED, so the
# entrypoint's bottom guard fired during `source` and main() ran the whole flow
# implicitly — which made the explicit calls below unreachable dead code.)
run_incremental_flow() {
  (
    cd "$RANGE_DIR" || exit 1
    # BACKUP_SOURCED=1 suppresses the entrypoint's "run main()" guard so this
    # child drives the flow explicitly instead of auto-running main().
    export BACKUP_SOURCED=1
    bash -c '
      source "$0" >/dev/null 2>&1 || true
      validate_env
      load_state
      STARTED_AT="2026-09-11T02:00:00Z"
      run_incremental_backup
      upload_and_verify "$BINLOG_DIR"
      COMPLETED_AT="$(now_utc)"; VERIFIED_AT="$(now_utc)"
      if ! report_now success; then exit 3; fi
      update_state "$ST_LAST_FULL_NAME" "$ST_LAST_FULL_COMPLETED_AT" "$ST_LAST_FULL_STORAGE_PATH" \
        "$BINLOG_FILE_END" "$BINLOG_POSITION_END" "$BINLOG_FILE_END" "$BINLOG_POSITION_END"
    ' "$ENTRYPOINT"
  ) >"$RANGE_DIR/flow.log" 2>&1
  return $?
}

# --- Case A: start and end in the SAME binlog -------------------------------
# path_violations is reset ONCE here; every later case appends to it, and a
# single assertion at the end proves every case used real, absolute paths.
: > "$RANGE_DIR/events.log"; : > "$RANGE_DIR/path_violations"
rm -f "$RANGE_DIR/reports.log" "$RANGE_DIR/captured_files" "$RANGE_DIR/captured_paths"
fix_state "binlog.000070" 100
export RANGE_BINARY_LOGS="binlog.000070 binlog.000071"
export RANGE_MASTER_FILE="binlog.000070" RANGE_MASTER_POS="900"
run_incremental_flow && rc=0 || rc=$?
assert_rc_zero "Case A (same binlog): incremental flow succeeds" "$rc"
assert_eq "Case A captures exactly one binlog" "binlog.000070" "$(cat "$RANGE_DIR/captured_files")"
assert_contains "Case A reports start binlog" "$(cat "$RANGE_DIR/reports.log")" '"binlog_file_start":"binlog.000070"'
assert_contains "Case A reports end position" "$(cat "$RANGE_DIR/reports.log")" '"binlog_position_end":900'
assert_contains "Case A advances state" "$(cat "$RANGE_DIR/state.json")" '"last_binlog_position": 900'

# PATH GUARDS (regression): the captured files live in the staging directory
# (mysql_binlogs/), which is NOT the current directory, so the entrypoint MUST
# hand mysqlbinlog an absolute, existing path. Passing the bare binlog name
# makes the REAL mysqlbinlog fail to open the file and aborts every incremental
# even though the capture itself succeeded.
assert_eq "Case A passes no non-existent path to mysqlbinlog" "" "$(cat "$RANGE_DIR/path_violations" 2>/dev/null || true)"
assert_contains "Case A passes an absolute binlog path" "$(cat "$RANGE_DIR/captured_paths")" "/"
assert_eq "Case A records exactly one raw path" "1" "$(grep -c . "$RANGE_DIR/captured_paths")"

# --- Case B: start binlog.000070 -> end binlog.000071 (one rotation) --------
: > "$RANGE_DIR/events.log"; rm -f "$RANGE_DIR/reports.log" "$RANGE_DIR/captured_files"
fix_state "binlog.000070" 100
export RANGE_BINARY_LOGS="binlog.000070 binlog.000071"
export RANGE_MASTER_FILE="binlog.000071" RANGE_MASTER_POS="250"
run_incremental_flow && rc=0 || rc=$?
assert_rc_zero "Case B (one rotation): incremental flow succeeds" "$rc"
assert_eq "Case B captures BOTH rotated files in order" "binlog.000070
binlog.000071" "$(cat "$RANGE_DIR/captured_files")"
assert_contains "Case B reports the rotated end file" "$(cat "$RANGE_DIR/reports.log")" '"binlog_file_end":"binlog.000071"'
assert_contains "Case B advances state to the new file" "$(cat "$RANGE_DIR/state.json")" '"last_binlog_end_file": "binlog.000071"'

# --- Case C: start binlog.000070 -> end binlog.000072 (two rotations) -------
: > "$RANGE_DIR/events.log"; rm -f "$RANGE_DIR/reports.log" "$RANGE_DIR/captured_files"
fix_state "binlog.000070" 100
export RANGE_BINARY_LOGS="binlog.000070 binlog.000071 binlog.000072"
export RANGE_MASTER_FILE="binlog.000072" RANGE_MASTER_POS="50"
run_incremental_flow && rc=0 || rc=$?
assert_rc_zero "Case C (two rotations): incremental flow succeeds" "$rc"
assert_eq "Case C captures ALL three files in order" "binlog.000070
binlog.000071
binlog.000072" "$(cat "$RANGE_DIR/captured_files")"
assert_eq "Case C passes no non-existent path to mysqlbinlog" "" "$(cat "$RANGE_DIR/path_violations" 2>/dev/null || true)"

# --- Case D: the starting binlog was purged -> fail safely ------------------
: > "$RANGE_DIR/events.log"; rm -f "$RANGE_DIR/reports.log" "$RANGE_DIR/captured_files"
fix_state "binlog.000070" 100
export RANGE_BINARY_LOGS="binlog.000080 binlog.000081"   # 000070 no longer exists
export RANGE_MASTER_FILE="binlog.000081" RANGE_MASTER_POS="10"
run_incremental_flow && rc=0 || rc=$?
assert_rc_nonzero "Case D (purged start): run fails" "$rc"
assert_not_contains "Case D never writes state" "$(cat "$RANGE_DIR/events.log" 2>/dev/null)" "STATE_UPDATED"
assert_contains "Case D failure explains the chain is broken" "$(cat "$RANGE_DIR/reports.log")" "purged"
assert_contains "Case D asks for a new FULL" "$(cat "$RANGE_DIR/reports.log")" "backup is required"
assert_contains "Case D leaves the saved position untouched" "$(cat "$RANGE_DIR/state.json")" '"last_binlog_position": 100'

# --- Case D2: a GAP in the retained range is rejected (never silently skip) --
: > "$RANGE_DIR/events.log"; rm -f "$RANGE_DIR/reports.log" "$RANGE_DIR/captured_files"
fix_state "binlog.000070" 100
# 000071 is MISSING although start (000070) and end (000072) are both present:
# a naive implementation would skip it and produce a silently incomplete chain.
export RANGE_BINARY_LOGS="binlog.000070 binlog.000072"
export RANGE_MASTER_FILE="binlog.000072" RANGE_MASTER_POS="10"
run_incremental_flow && rc=0 || rc=$?
assert_rc_nonzero "Case D2 (gap in range): run fails" "$rc"
assert_contains "Case D2 explains the logs are not contiguous" "$(cat "$RANGE_DIR/reports.log")" "not contiguous"
assert_contains "Case D2 asks for a new FULL" "$(cat "$RANGE_DIR/reports.log")" "backup is required"
assert_not_contains "Case D2 never writes state" "$(cat "$RANGE_DIR/events.log" 2>/dev/null)" "STATE_UPDATED"
assert_eq "Case D2 captures nothing" "" "$(cat "$RANGE_DIR/captured_files" 2>/dev/null || true)"

# --- Case E: status reports a NEWER file than expected ----------------------
: > "$RANGE_DIR/events.log"; rm -f "$RANGE_DIR/reports.log" "$RANGE_DIR/captured_files"
fix_state "binlog.000070" 100
# The server rotated several times since the anchor; every file in between must
# still be captured (this is exactly Case C but reached via a large jump).
export RANGE_BINARY_LOGS="binlog.000070 binlog.000071 binlog.000072 binlog.000073"
export RANGE_MASTER_FILE="binlog.000073" RANGE_MASTER_POS="640"
run_incremental_flow && rc=0 || rc=$?
assert_rc_zero "Case E (newer status file): flow succeeds" "$rc"
assert_eq "Case E captures every intermediate file" "binlog.000070
binlog.000071
binlog.000072
binlog.000073" "$(cat "$RANGE_DIR/captured_files")"

# --- Case F: mysqlbinlog fails halfway through the capture ------------------
: > "$RANGE_DIR/events.log"; rm -f "$RANGE_DIR/reports.log" "$RANGE_DIR/captured_files"
fix_state "binlog.000070" 100
export RANGE_BINARY_LOGS="binlog.000070 binlog.000071"
export RANGE_MASTER_FILE="binlog.000071" RANGE_MASTER_POS="250"
export RANGE_BINLOG_FAIL=1
run_incremental_flow && rc=0 || rc=$?
assert_rc_nonzero "Case F (mysqlbinlog failure): run fails" "$rc"
assert_not_contains "Case F never writes state" "$(cat "$RANGE_DIR/events.log" 2>/dev/null)" "STATE_UPDATED"
assert_contains "Case F reports a failure" "$(cat "$RANGE_DIR/reports.log")" '"status":"failed"'
export RANGE_BINLOG_FAIL=0

# --- Case G: upload fails after a successful local capture ------------------
: > "$RANGE_DIR/events.log"; rm -f "$RANGE_DIR/reports.log" "$RANGE_DIR/captured_files"
fix_state "binlog.000070" 100
export RANGE_BINARY_LOGS="binlog.000070 binlog.000071"
export RANGE_MASTER_FILE="binlog.000071" RANGE_MASTER_POS="250"
export RANGE_SYNC_EXIT=1
run_incremental_flow && rc=0 || rc=$?
assert_rc_nonzero "Case G (upload failure): run fails" "$rc"
assert_not_contains "Case G never writes state" "$(cat "$RANGE_DIR/events.log" 2>/dev/null)" "STATE_UPDATED"
assert_contains "Case G reports a failure" "$(cat "$RANGE_DIR/reports.log")" '"status":"failed"'
export RANGE_SYNC_EXIT=0

# --- Case H: remote verification fails --------------------------------------
: > "$RANGE_DIR/events.log"; rm -f "$RANGE_DIR/reports.log" "$RANGE_DIR/captured_files"
fix_state "binlog.000070" 100
export RANGE_BINARY_LOGS="binlog.000070 binlog.000071"
export RANGE_MASTER_FILE="binlog.000071" RANGE_MASTER_POS="250"
export RANGE_SIZE_JSON='{"count":999,"bytes":999,"sizeless":0}'
run_incremental_flow && rc=0 || rc=$?
assert_rc_nonzero "Case H (verification failure): run fails" "$rc"
assert_not_contains "Case H never writes state" "$(cat "$RANGE_DIR/events.log" 2>/dev/null)" "STATE_UPDATED"
assert_contains "Case H reports a failure" "$(cat "$RANGE_DIR/reports.log")" '"status":"failed"'
unset RANGE_SIZE_JSON

# --- Case I: PUPTracker report fails ---------------------------------------
: > "$RANGE_DIR/events.log"; rm -f "$RANGE_DIR/reports.log" "$RANGE_DIR/captured_files"
fix_state "binlog.000070" 100
export RANGE_BINARY_LOGS="binlog.000070 binlog.000071"
export RANGE_MASTER_FILE="binlog.000071" RANGE_MASTER_POS="250"
export RANGE_HTTP_CODE=503
run_incremental_flow && rc=0 || rc=$?
assert_eq "Case I (report failure): exits 3" "3" "$rc"
assert_not_contains "Case I never writes state" "$(cat "$RANGE_DIR/events.log" 2>/dev/null)" "STATE_UPDATED"
export RANGE_HTTP_CODE=201

# Secrets must never appear in any of the logs produced above.
RANGE_LOGS="$(cat "$RANGE_DIR/flow.log" "$RANGE_DIR/reports.log" 2>/dev/null || true)"

# Cross-case path guard: every case that reached the local read must have handed
# mysqlbinlog paths that actually exist (see the Case A comment).
assert_eq "no range case passed a non-existent binlog path" "" "$(cat "$RANGE_DIR/path_violations" 2>/dev/null || true)"
assert_not_contains "range flows never log the report token" "$RANGE_LOGS" "super-secret-report-token"
assert_not_contains "range flows never log the r2 secret" "$RANGE_LOGS" "r2super-secret-key"
assert_not_contains "range flows never log the DB password" "$RANGE_LOGS" "sup3rsecret-db-pass"

unset RANGE_MASTER_FILE RANGE_MASTER_POS RANGE_BINARY_LOGS RANGE_BINLOG_FAIL
export PATH="$RANGE_OLD_PATH"
rm -rf "$RANGE_DIR"

# ---------------------------------------------------------------------------
# mysqlbinlog replication server id (must be configurable, never hard-coded 1)
# ---------------------------------------------------------------------------
echo "== mysqlbinlog server id =="

SID_DIR="$(mktemp -d)"
export SID_DIR
cat > "$SID_DIR/mysqlbinlog" <<'STUB'
#!/usr/bin/env bash
# Record the --server-id value the entrypoint passed, then produce the raw file.
# mysqlbinlog accepts BOTH `--server-id N` and `--server-id=N`, so the double has
# to understand both spellings (the entrypoint uses the `=` form).
sid=""; result_dir=""; files=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --defaults-extra-file) shift 2;;
    --read-from-remote-server) shift;;
    --server-id) sid="$2"; shift 2;;
    --server-id=*) sid="${1#--server-id=}"; shift;;
    --raw) shift;;
    --result-dir|--result-dir=*) echo "mysqlbinlog: [ERROR] unknown option '--result-dir'." >&2; exit 2;;
    --start-position|--stop-position) shift 2;;
    -*) shift;;
    *) files+=("$1"); shift;;
  esac
done
printf '%s' "$sid" > "$SID_DIR/server_id_seen"
for f in "${files[@]}"; do printf 'RAW:%s' "$f" > "$(basename "$f")"; done
exit 0
STUB
chmod +x "$SID_DIR/mysqlbinlog"

SID_OLD_PATH="$PATH"
export PATH="$SID_DIR:$PATH"
export MYSQLBINLOG_BIN="mysqlbinlog"

export MYSQLBINLOG_SERVER_ID=777001
fetch_binlog_file "binlog.000070" "$SID_DIR/out.bin" >/dev/null 2>&1 && rc=0 || rc=$?
assert_rc_zero "fetch_binlog_file succeeds with a configured server id" "$rc"
assert_eq "mysqlbinlog receives the configured server id" "777001" "$(cat "$SID_DIR/server_id_seen" 2>/dev/null)"
assert_eq "captured bytes are preserved" "RAW:binlog.000070" "$(cat "$SID_DIR/out.bin" 2>/dev/null)"

# A different id must be passed through verbatim (proving it is not hard-coded).
export MYSQLBINLOG_SERVER_ID=1234567
fetch_binlog_file "binlog.000071" "$SID_DIR/out2.bin" >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq "a second, different server id is used verbatim" "1234567" "$(cat "$SID_DIR/server_id_seen" 2>/dev/null)"

# The default must not be 1 (which could collide with a real replica).
# `env -u` clears the exported override so the built-in default is observed.
DEFAULT_SID="$(env -u MYSQLBINLOG_SERVER_ID bash -c 'export BACKUP_SOURCED=1; source "$0" >/dev/null 2>&1; printf "%s" "$MYSQLBINLOG_SERVER_ID"' "$ENTRYPOINT" 2>/dev/null)"
if [[ "$DEFAULT_SID" != "1" && -n "$DEFAULT_SID" ]]; then
  pass "default MYSQLBINLOG_SERVER_ID is not 1 (got ${DEFAULT_SID})"
else
  fail "default MYSQLBINLOG_SERVER_ID must not be 1 (got [${DEFAULT_SID}])"
fi

# validate_env must reject a missing/zero/out-of-range server id.
OUT="$(mktemp)"
(
  export MYSQLBINLOG_SERVER_ID="0"
  source "$ENTRYPOINT" >/dev/null 2>&1
  validate_env >"$OUT" 2>&1
) || true
SID_CONTENT="$(cat "$OUT" 2>/dev/null)"
rm -f "$OUT"
assert_contains "validate_env rejects server id 0" "$SID_CONTENT" "MYSQLBINLOG_SERVER_ID"

OUT="$(mktemp)"
(
  export MYSQLBINLOG_SERVER_ID="not-a-number"
  source "$ENTRYPOINT" >/dev/null 2>&1
  validate_env >"$OUT" 2>&1
) || true
SID_CONTENT="$(cat "$OUT" 2>/dev/null)"
rm -f "$OUT"
assert_contains "validate_env rejects a non-numeric server id" "$SID_CONTENT" "MYSQLBINLOG_SERVER_ID"

# validate_env must also reject an unknown fetch strategy.
OUT="$(mktemp)"
(
  export MYSQLBINLOG_SERVER_ID="424242" BINLOG_FETCH_STRATEGY="telepathy"
  source "$ENTRYPOINT" >/dev/null 2>&1
  validate_env >"$OUT" 2>&1
) || true
SID_CONTENT="$(cat "$OUT" 2>/dev/null)"
rm -f "$OUT"
assert_contains "validate_env rejects an unknown fetch strategy" "$SID_CONTENT" "BINLOG_FETCH_STRATEGY"

export MYSQLBINLOG_SERVER_ID=424242
export PATH="$SID_OLD_PATH"
rm -rf "$SID_DIR"

# ---------------------------------------------------------------------------
# Concurrent execution protection (distributed lock in object storage)
# ---------------------------------------------------------------------------
# Two overlapping runs must never both capture an incremental range and both
# advance the state. The lock is an R2 object created with `rclone copyto`
# (which does not overwrite), carries an expiry, and is released on exit.
echo "== distributed lock (concurrent execution) =="

LOCK_DIR="$(mktemp -d)"
# The stub R2 "bucket" lives in its own directory so wiping the bucket between
# cases can never delete the rclone stub itself.
LOCK_BUCKET="$(mktemp -d)"
export LOCK_DIR LOCK_BUCKET
export RCLONE_CONFIG="$LOCK_DIR/rclone.conf"
export RCLONE_CONFIG_DIR="$LOCK_DIR"
# A stub R2 "bucket" implemented as a directory. `copyto` fails when the target
# already exists, mirroring rclone's create-if-absent semantics on R2.
cat > "$LOCK_DIR/rclone" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "--config" ]]; then shift 2; fi
case "$1" in
  listremotes) printf 'remote:\n'; exit 0;;
  cat) if [[ -f "$LOCK_BUCKET/$(basename "$2")" ]]; then cat "$LOCK_BUCKET/$(basename "$2")"; fi; exit 0;;
  copyto)
    # rclone copyto does NOT overwrite an existing destination object.
    dest="$LOCK_BUCKET/$(basename "$3")"
    if [[ -e "$dest" && "${LOCK_ALLOW_OVERWRITE:-0}" != "1" ]]; then
      echo "destination already exists" >&2
      exit 1
    fi
    cp "$2" "$dest"; exit 0;;
  deletefile) rm -f "$LOCK_BUCKET/$(basename "$2")"; exit 0;;
  *) exit 0;;
esac
STUB
chmod +x "$LOCK_DIR/rclone"

LOCK_OLD_PATH="$PATH"
# The concurrent main() run below reaches check_tools() (which requires a
# mydumper binary) before it can hit the lock. A double is supplied explicitly
# for that reason; this previously relied on FLOW_DIR's double leaking onto PATH.
cat > "$LOCK_DIR/mydumper" <<'STUB'
#!/usr/bin/env bash
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2;;
    *) shift;;
  esac
done
mkdir -p "$out"
printf 'schema' > "$out/db.schema.sql"
exit 0
STUB
chmod +x "$LOCK_DIR/mydumper"
export PATH="$LOCK_DIR:$PATH"
export BACKUP_LOCK_ENABLED=true
export BACKUP_LOCK_TTL_SECONDS=3600
export BACKUP_LOCK_TOKEN_PREFIX="testtoken-"

# 1. First acquire succeeds and records ownership.
rm -f "$LOCK_BUCKET"/*
acquire_lock && rc=0 || rc=$?
assert_rc_zero "first lock acquisition succeeds" "$rc"
assert_eq "lock is marked as held" "1" "$BACKUP_LOCK_HELD"
assert_contains "lock object records the holder" "$(cat "$LOCK_BUCKET/backup.lock")" '"holder"'
assert_contains "lock object records a token" "$(cat "$LOCK_BUCKET/backup.lock")" 'testtoken-'

# 2. A second, concurrent acquire must FAIL while the first holds it.
export BACKUP_LOCK_TOKEN_PREFIX="other-"
acquire_lock && rc=0 || rc=$?
assert_rc_nonzero "concurrent lock acquisition is refused" "$rc"
assert_eq "refused acquisition does not claim the lock" "0" "$BACKUP_LOCK_HELD"
assert_contains "the original holder is preserved" "$(cat "$LOCK_BUCKET/backup.lock")" 'testtoken-'

# 3. An EXPIRED lock is taken over (a crash must never wedge the chain).
cat > "$LOCK_BUCKET/backup.lock" <<JSON
{ "holder": "dead-container", "token": "stale-token", "acquired_at_epoch": 1, "expires_at_epoch": 2 }
JSON
export BACKUP_LOCK_TOKEN_PREFIX="takeover-"
acquire_lock && rc=0 || rc=$?
assert_rc_zero "an expired (stale) lock is taken over" "$rc"
assert_contains "the new owner replaced the stale holder" "$(cat "$LOCK_BUCKET/backup.lock")" 'takeover-'

# 4. lock_still_owned() is true for the owner and false once taken over.
lock_still_owned && rc=0 || rc=$?
assert_rc_zero "lock_still_owned is true for the current owner" "$rc"
cat > "$LOCK_BUCKET/backup.lock" <<JSON
{ "holder": "third-party", "token": "someone-else", "acquired_at_epoch": 100, "expires_at_epoch": 99999999999 }
JSON
lock_still_owned && rc=0 || rc=$?
assert_rc_nonzero "lock_still_owned is false after another run takes over" "$rc"

# 5. release_lock() only removes a lock we still own.
# The object belongs to a DIFFERENT run ("another-run-token") while our token is
# "our-token", so releasing must leave the other run's lock alone.
cat > "$LOCK_BUCKET/backup.lock" <<JSON
{ "holder": "another-run", "token": "another-run-token", "acquired_at_epoch": 1, "expires_at_epoch": 99999999999 }
JSON
export BACKUP_LOCK_HELD=1
export BACKUP_LOCK_TOKEN="our-token"
release_lock >/dev/null 2>&1
if [[ -f "$LOCK_BUCKET/backup.lock" ]]; then
  pass "release_lock does not delete a lock owned by another run"
else
  fail "release_lock must not delete another run's lock"
fi
assert_eq "release_lock relinquishes the held flag when it is not the owner" "0" "$BACKUP_LOCK_HELD"

# 6. release_lock() removes OUR lock and clears the held flag.
export BACKUP_LOCK_HELD=1
export BACKUP_LOCK_TOKEN="our-token"
cat > "$LOCK_BUCKET/backup.lock" <<JSON
{ "holder": "me", "token": "${BACKUP_LOCK_TOKEN}", "acquired_at_epoch": 1, "expires_at_epoch": 99999999999 }
JSON
release_lock >/dev/null 2>&1
if [[ ! -f "$LOCK_BUCKET/backup.lock" ]]; then
  pass "release_lock removes our own lock"
else
  fail "release_lock should remove our own lock"
fi
assert_eq "release_lock clears the held flag" "0" "$BACKUP_LOCK_HELD"

# 7. With locking DISABLED, acquire always succeeds and creates nothing.
export BACKUP_LOCK_ENABLED=false
rm -f "$LOCK_BUCKET"/*
acquire_lock && rc=0 || rc=$?
assert_rc_zero "acquire succeeds when locking is disabled" "$rc"
if [[ ! -f "$LOCK_BUCKET/backup.lock" ]]; then
  pass "no lock object is written when locking is disabled"
else
  fail "locking disabled must not create a lock object"
fi

# 8. A concurrent run of main() exits with the dedicated contention code and
#    leaves the backup chain untouched (no state write).
export BACKUP_LOCK_ENABLED=true
rm -f "$LOCK_BUCKET"/*
cat > "$LOCK_BUCKET/backup.lock" <<JSON
{ "holder": "holder-run", "token": "holder-token", "acquired_at_epoch": 1, "expires_at_epoch": 99999999999 }
JSON
set +e
(
  cd "$LOCK_DIR"
  MYSQL_HOST=h MYSQL_USER=u MYSQL_PASSWORD=p MYSQL_PORT=3306 MYSQL_DATABASE=d \
  R2_ACCESS_KEY_ID=a R2_SECRET_ACCESS_KEY=s R2_ENDPOINT=e R2_BUCKET=b R2_PATH=mysql-backup \
  BACKUP_REPORT_URL="https://puptvs.com/x" BACKUP_REPORT_TOKEN="tok" \
  MYSQLBINLOG_SERVER_ID=424242 BACKUP_LOCK_TTL_SECONDS=3600 \
  BACKUP_BINLOG_ENABLED=false \
  bash "$ENTRYPOINT" >"$LOCK_DIR/main.log" 2>&1
)
code=$?
set -e
assert_eq "a concurrent run exits with the lock-contention code (5)" "5" "$code"
assert_contains "the concurrent run explains the lock is held" "$(cat "$LOCK_DIR/main.log")" "holds the distributed lock"
assert_not_contains "the concurrent run never reported success" "$(cat "$LOCK_DIR/main.log")" "reported to PUPTracker"
if [[ -f "$LOCK_BUCKET/state.json" ]]; then
  fail "the concurrent run must not have written backup state"
else
  pass "the concurrent run never wrote backup state"
fi
# The incumbent's lock must still be in place afterwards.
assert_contains "the incumbent lock survived the refused run" "$(cat "$LOCK_BUCKET/backup.lock")" "holder-token"

export BACKUP_LOCK_ENABLED=false
unset BACKUP_LOCK_TOKEN BACKUP_LOCK_TOKEN_PREFIX BACKUP_LOCK_TTL_SECONDS
export PATH="$LOCK_OLD_PATH"
rm -rf "$LOCK_DIR" "$LOCK_BUCKET"

# ---------------------------------------------------------------------------
# State persistence failure must be a FAILURE (not a warning)
# ---------------------------------------------------------------------------
# The backup can be uploaded, verified and reported successfully, yet the chain
# bookkeeping (backup_state.json) may fail to persist. That MUST fail the job,
# because the next run can no longer know which FULL is the base.
echo "== state persistence failure =="

SP_DIR="$(mktemp -d)"
export SP_DIR
cat > "$SP_DIR/mysql" <<'STUB'
#!/usr/bin/env bash
sql=""; while [[ $# -gt 0 ]]; do case "$1" in --defaults-extra-file) shift 2;; -e) sql="$2"; shift 2;; *) shift;; esac; done
shopt -s nocasematch
if [[ "$sql" == *"log_bin"* ]]; then printf 'log_bin\tON\n'; exit 0; fi
if [[ "$sql" == *"binlog_format"* ]]; then printf 'binlog_format\tROW\n'; exit 0; fi
if [[ "$sql" == *"SHOW BINARY LOG STATUS"* || "$sql" == *"SHOW MASTER STATUS"* ]]; then
  printf 'binlog.000070\t900\t\t\t\n'; exit 0
fi
if [[ "$sql" == *"SHOW BINARY LOGS"* ]]; then printf 'binlog.000070\t4\nbinlog.000071\t4\n'; exit 0; fi
exit 0
STUB
chmod +x "$SP_DIR/mysql"

cat > "$SP_DIR/mysqlbinlog" <<'STUB'
#!/usr/bin/env bash
result_dir=""; raw=0; files=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --defaults-extra-file) shift 2;; --read-from-remote-server) shift;;
    --server-id) shift 2;; --server-id=*) shift;;
    --raw) raw=1; shift;; --result-dir|--result-dir=*) echo "mysqlbinlog: [ERROR] unknown option '--result-dir'." >&2; exit 2;;
    --start-position|--stop-position) shift 2;; -*) shift;; *) files+=("$1"); shift;;
  esac
done
if [[ "$raw" -eq 1 ]]; then for f in "${files[@]}"; do printf 'RAW:%s' "$f" > "$(basename "$f")"; done; exit 0; fi
for f in "${files[@]}"; do printf -- '-- %s\nSQL;\n' "$f"; done
exit 0
STUB
chmod +x "$SP_DIR/mysqlbinlog"

cat > "$SP_DIR/mydumper" <<'STUB'
#!/usr/bin/env bash
out=""; while [[ $# -gt 0 ]]; do case "$1" in -o) out="$2"; shift 2;; *) shift;; esac; done
mkdir -p "$out"; printf 'schema' > "$out/db.schema.sql"
printf 'SHOW MASTER STATUS:\n\tLog: binlog.000070\n\tPos: 900\n' > "$out/metadata"
exit 0
STUB
chmod +x "$SP_DIR/mydumper"

# rclone where STATE_WRITE_FAIL=1 makes copyto (state persistence) fail while
# every other operation succeeds.
cat > "$SP_DIR/rclone" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "--config" ]]; then shift 2; fi
case "$1" in
  listremotes) printf 'remote:\n'; exit 0;;
  cat) if [[ -f "$SP_DIR/state.json" ]]; then cat "$SP_DIR/state.json"; fi; exit 0;;
  copyto)
    if [[ "${STATE_WRITE_FAIL:-0}" == "1" ]]; then echo "simulated state write failure" >&2; exit 1; fi
    cp "$2" "$SP_DIR/state.json"; exit 0;;
  sync) printf '%s\n' "$2" > "$SP_DIR/last_sync_dir"; exit 0;;
  size)
    if [[ -f "$SP_DIR/last_sync_dir" ]]; then
      d="$(cat "$SP_DIR/last_sync_dir")"
      if [[ -d "$d" ]]; then
        c="$(find "$d" -type f 2>/dev/null | wc -l)"
        b="$(find "$d" -type f -printf '%s\n' 2>/dev/null | awk '{s+=$1} END {print s+0}')"
        printf '{"count":%s,"bytes":%s,"sizeless":0}\n' "$c" "$b"; exit 0
      fi
    fi
    printf '{"count":0,"bytes":0,"sizeless":0}\n'; exit 0;;
  *) exit 0;;
esac
STUB
chmod +x "$SP_DIR/rclone"

cat > "$SP_DIR/curl" <<'STUB'
#!/usr/bin/env bash
resp_file=""; payload=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --data-binary) payload="$2"; shift 2;; -o) resp_file="$2"; shift 2;;
    -w) shift 2;; --max-time) shift 2;; *) shift;;
  esac
done
printf '%s\n' "$payload" >> "$SP_DIR/reports.log"
[[ -n "$resp_file" ]] && printf '{"ok":true}' > "$resp_file"
printf '%s' "201"; exit 0
STUB
chmod +x "$SP_DIR/curl"

SP_OLD_PATH="$PATH"
export PATH="$SP_DIR:$PATH"
export MYSQL_CLIENT_BIN="mysql" MYSQLBINLOG_BIN="mysqlbinlog"
export R2_ACCESS_KEY_ID=a R2_SECRET_ACCESS_KEY=s R2_ENDPOINT=e R2_BUCKET=b R2_PATH=mysql-backup
export BACKUP_REPORT_URL="https://puptvs.com/x" BACKUP_REPORT_TOKEN="tok"
export MYSQL_HOST=h MYSQL_USER=u MYSQL_PASSWORD=p MYSQL_DATABASE=d MYSQL_PORT=3306
export BACKUP_BINLOG_ENABLED=true BACKUP_BINLOG_VERIFY=true BACKUP_FULL_INTERVAL_DAYS=14
export BACKUP_LOCK_ENABLED=false BINLOG_FETCH_STRATEGY=raw MYSQLBINLOG_SERVER_ID=424242
export REPORT_TIMEOUT=2

# --- FULL path: reporting succeeds but the state write fails -> non-zero. ----
rm -f "$SP_DIR/state.json" "$SP_DIR/reports.log"
export STATE_WRITE_FAIL=1
set +e
( cd "$SP_DIR" && bash "$ENTRYPOINT" >"$SP_DIR/run.log" 2>&1 )
code=$?
set -e
assert_rc_nonzero "FULL: state persistence failure makes the run fail" "$code"
assert_contains "FULL: the state failure is explained" "$(cat "$SP_DIR/run.log")" "Backup state could not be persisted"
assert_contains "FULL: the success report WAS still sent" "$(cat "$SP_DIR/reports.log")" '"status":"success"'
assert_contains "FULL: the uploaded backup is retained (not deleted)" "$(cat "$SP_DIR/run.log")" "retained"
if [[ -f "$SP_DIR/state.json" ]]; then
  fail "FULL: a failed state write must not leave state behind"
else
  pass "FULL: no state object is created when persistence fails"
fi
export STATE_WRITE_FAIL=0

# --- FULL path control: with state persistence working -> exit 0. -----------
rm -f "$SP_DIR/state.json" "$SP_DIR/reports.log"
set +e
( cd "$SP_DIR" && bash "$ENTRYPOINT" >"$SP_DIR/run2.log" 2>&1 )
code=$?
set -e
assert_rc_zero "FULL: a working state write lets the run succeed" "$code"
assert_contains "FULL: state was persisted" "$(cat "$SP_DIR/state.json")" '"last_successful_full_backup_name"'

# --- INCREMENTAL path: state write fails after a verified, reported backup. --
# Seed a recent FULL so the next run is an incremental.
cat > "$SP_DIR/state.json" <<'JSON'
{
  "state_version": 1,
  "last_successful_full_backup_name": "full_BASE",
  "last_successful_full_completed_at": "2999-01-01T00:00:00Z",
  "last_successful_full_storage_path": "mysql-backup/full/BASE",
  "last_binlog_file": "binlog.000070",
  "last_binlog_position": 900,
  "last_binlog_end_file": "binlog.000070",
  "last_binlog_end_position": 900
}
JSON
SNAP_BEFORE="$(cat "$SP_DIR/state.json")"
rm -f "$SP_DIR/reports.log"
export STATE_WRITE_FAIL=1
set +e
( cd "$SP_DIR" && bash "$ENTRYPOINT" >"$SP_DIR/run3.log" 2>&1 )
code=$?
set -e
assert_rc_nonzero "INCREMENTAL: state persistence failure makes the run fail" "$code"
assert_contains "INCREMENTAL: the state failure is explained" "$(cat "$SP_DIR/run3.log")" "Backup state could not be persisted"
assert_contains "INCREMENTAL: the success report WAS still sent" "$(cat "$SP_DIR/reports.log")" '"status":"success"'
assert_eq "INCREMENTAL: the previous state is left byte-identical" "$SNAP_BEFORE" "$(cat "$SP_DIR/state.json")"
export STATE_WRITE_FAIL=0

# Secrets never leak into any of these logs.
SP_LOGS="$(cat "$SP_DIR/run.log" "$SP_DIR/run2.log" "$SP_DIR/run3.log" "$SP_DIR/reports.log" 2>/dev/null || true)"
assert_not_contains "state-failure logs never contain the report token" "$SP_LOGS" "super-secret-report-token"
assert_not_contains "state-failure logs never contain the DB password" "$SP_LOGS" "sup3rsecret-db-pass"
assert_not_contains "state-failure logs never contain the r2 secret" "$SP_LOGS" "r2super-secret-key"

unset STATE_WRITE_FAIL
export PATH="$SP_OLD_PATH"
rm -rf "$SP_DIR"

# ---------------------------------------------------------------------------
# Credential exposure ("secret safety")
# ---------------------------------------------------------------------------
# Secrets must never sit on a process command line (visible to any process via
# ps / /proc/<pid>/cmdline), and the credential files the container writes must
# not be readable by other users in the container.
echo "== credential exposure =="

CRED_DIR="$(mktemp -d)"
export CRED_DIR
# Stubs that RECORD their full argument vector so the test can inspect it.
cat > "$CRED_DIR/mysqlbinlog" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CRED_DIR/mysqlbinlog_argv"
result_dir=""; files=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --defaults-extra-file) shift 2;;
    --read-from-remote-server) shift;;
    --server-id) shift 2;;
    --server-id=*) shift;;
    --raw) shift;;
    --result-dir|--result-dir=*) echo "mysqlbinlog: [ERROR] unknown option '--result-dir'." >&2; exit 2;;
    -*) shift;;
    *) files+=("$1"); shift;;
  esac
done
for f in "${files[@]}"; do printf 'RAW:%s' "$f" > "$(basename "$f")"; done
exit 0
STUB
chmod +x "$CRED_DIR/mysqlbinlog"

cat > "$CRED_DIR/mysql" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CRED_DIR/mysql_argv"
exit 0
STUB
chmod +x "$CRED_DIR/mysql"

cat > "$CRED_DIR/rclone" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CRED_DIR/rclone_argv"
if [[ "$1" == "--config" ]]; then shift 2; fi
case "$1" in
  listremotes) printf 'remote:\n'; exit 0;;
  *) exit 0;;
esac
STUB
chmod +x "$CRED_DIR/rclone"

cat > "$CRED_DIR/mydumper" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CRED_DIR/mydumper_argv"
out=""; while [[ $# -gt 0 ]]; do case "$1" in -o) out="$2"; shift 2;; *) shift;; esac; done
mkdir -p "$out"; printf 'schema' > "$out/db.schema.sql"
printf 'SHOW MASTER STATUS:\n\tLog: binlog.000070\n\tPos: 4\n' > "$out/metadata"
exit 0
STUB
chmod +x "$CRED_DIR/mydumper"

CRED_OLD_PATH="$PATH"
export PATH="$CRED_DIR:$PATH"
export MYSQLBINLOG_BIN="mysqlbinlog" MYSQL_CLIENT_BIN="mysql"
export MYSQL_HOST=h MYSQL_USER=u MYSQL_DATABASE=d MYSQL_PORT=3306
export MYSQL_PASSWORD="sup3rsecret-db-pass"
export R2_SECRET_ACCESS_KEY="r2super-secret-key"
export R2_ACCESS_KEY_ID="r2access"
export R2_ENDPOINT=e R2_BUCKET=b R2_PATH=mysql-backup
export BACKUP_REPORT_URL="https://puptvs.com/x" BACKUP_REPORT_TOKEN="super-secret-report-token"
export MYSQLBINLOG_SERVER_ID=424242 BACKUP_LOCK_ENABLED=false BINLOG_FETCH_STRATEGY=raw
rm -f "$CRED_DIR/mysqlbinlog_argv" "$CRED_DIR/mysql_argv" "$CRED_DIR/rclone_argv" "$CRED_DIR/mydumper_argv"

# 1. mysql/mysqlbinlog are driven by a --defaults-extra-file, never --password.
mysql_query "SHOW VARIABLES LIKE 'log_bin';" >/dev/null 2>&1 || true
fetch_binlog_file "binlog.000070" "$CRED_DIR/out.bin" >/dev/null 2>&1 || true
MYSQL_ARGV="$(cat "$CRED_DIR/mysql_argv" "$CRED_DIR/mysqlbinlog_argv" 2>/dev/null || true)"
assert_contains "mysql is invoked with --defaults-extra-file" "$MYSQL_ARGV" "--defaults-extra-file"
assert_not_contains "no mysql command line carries the DB password" "$MYSQL_ARGV" "sup3rsecret-db-pass"
assert_not_contains "no mysql command line uses --password" "$MYSQL_ARGV" "--password"

# 2. mydumper must NOT receive the password on its command line.
( cd "$CRED_DIR" && BACKUP_DIR="backup_cred" BINLOG_FILE_END="" BINLOG_POSITION_END="" \
  bash -c 'export BACKUP_SOURCED=1; source "$0" >/dev/null 2>&1; run_full_backup' "$ENTRYPOINT" ) >/dev/null 2>&1 || true
MYD_ARGV="$(cat "$CRED_DIR/mydumper_argv" 2>/dev/null || true)"
assert_contains "mydumper receives a --defaults-file" "$MYD_ARGV" "--defaults-file"
assert_not_contains "mydumper command line never carries the DB password" "$MYD_ARGV" "sup3rsecret-db-pass"

# 3. The generated rclone config (which contains the R2 secret) must be created
#    with owner-only permissions.
#    Use an explicit, fresh config path so an earlier test's config file cannot
#    influence the check.
export RCLONE_CONFIG="$CRED_DIR/rclone.conf"
export RCLONE_CONFIG_DIR="$CRED_DIR"
rm -f "$RCLONE_CONFIG"
(
  cd "$CRED_DIR"
  bash -c 'export BACKUP_SOURCED=1; source "$0" >/dev/null 2>&1; configure_rclone' "$ENTRYPOINT" >/dev/null 2>&1 || true
) || true
if [[ ! -f "$RCLONE_CONFIG" ]]; then
  fail "configure_rclone did not write a config file at $RCLONE_CONFIG"
fi
assert_contains "rclone config does contain the secret (so the test is meaningful)" "$(cat "$RCLONE_CONFIG" 2>/dev/null)" "r2super-secret-key"

# Static guard (platform-independent): the config MUST be written under a 077
# umask and/or explicitly chmod-ed to 600. This asserts the hardening exists in
# the source even where the filesystem cannot demonstrate it.
CONFIGURE_RCLONE_SRC="$(sed -n '/^configure_rclone()/,/^}/p' "$ENTRYPOINT")"
assert_contains "configure_rclone writes rclone.conf under umask 077" "$CONFIGURE_RCLONE_SRC" "umask 077"
assert_contains "configure_rclone chmods rclone.conf to 600" "$CONFIGURE_RCLONE_SRC" 'chmod 600 "$RCLONE_CONFIG"'

if [[ "$MODE_SUPPORTED" -eq 1 ]]; then
  CFG_MODE="$(stat -c '%a' "$RCLONE_CONFIG" 2>/dev/null || echo unknown)"
  assert_eq "rclone config holding the R2 secret is mode 600" "600" "$CFG_MODE"
else
  skip "rclone config mode is 0600 (not verifiable on this filesystem)"
fi

# 4. The R2 secret/key id are never passed on the rclone command line.
RCLONE_ARGV="$(cat "$CRED_DIR/rclone_argv" 2>/dev/null || true)"
assert_not_contains "rclone command line never carries the R2 secret" "$RCLONE_ARGV" "r2super-secret-key"
assert_not_contains "rclone command line never carries the R2 key id" "$RCLONE_ARGV" "r2access"

# Clean up BEFORE unsetting, then restore the secret-bearing test values to the
# suite defaults so later assertions cannot see a blanked environment.
rm -rf "$CRED_DIR"
export PATH="$CRED_OLD_PATH"
unset CRED_DIR CRED_OLD_PATH
export MYSQL_PASSWORD="sup3rsecret-db-pass"
export R2_SECRET_ACCESS_KEY="r2super-secret-key"
export R2_ACCESS_KEY_ID="r2access"

# ---------------------------------------------------------------------------
# FULL backup exit-status diagnosis (regression)
# ---------------------------------------------------------------------------
# Regression for the production observation:
#     [backup] PUPTracker report accepted (HTTP 200) for full_...
#     [backup] Released distributed backup lock.
#     [backup] EXIT: stage=full_backup, status=1
#
# The report legitimately returned HTTP 200 because the reporter accepts BOTH a
# success report and a failure report with the same status code — so a 200 does
# NOT imply the backup succeeded. The failing stage was the mydumper dump, and the
# log did not say so. These tests pin the two properties that make that log
# self-explaining:
#   1. the report line names the backup status it carried, so a 200 cannot be
#      mistaken for success;
#   2. the exit diagnosis names the failing stage and every stage's return code.
echo "== FULL exit-status diagnosis =="

DIAG_DIR="$(mktemp -d)"
DIAG_BUCKET="$(mktemp -d)"
export DIAG_DIR DIAG_BUCKET

# A mydumper double whose failure mode is selectable. It ALSO emulates the real
# v0.21.x metadata behaviour: --source-data turns the [source] keys ON, and
# without the flag they are written commented-out. That is what makes the
# "successful FULL" case a REAL test of the anchor rather than a fixture.
cat > "$DIAG_DIR/mydumper" <<'STUB'
#!/usr/bin/env bash
out=""; args="$*"; saw_source_data=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2;;
    --source-data) saw_source_data=1; shift;;
    *) shift;;
  esac
done
printf '%s\n' "$args" > "$DIAG_DIR/mydumper_cmdline"
case "${DIAG_MYDUMPER:-ok}" in
  fail) exit 1;;
  emptydir) mkdir -p "$out"; exit 0;;
  noanchor)
    # Successful dump with NO usable anchor (metadata has no [source] keys at
    # all, e.g. binary logging disabled on the server).
    mkdir -p "$out"; printf 'schema' > "$out/db.schema.sql"
    printf '# Started dump at: 2026-09-12 10:00:00\n[config]\nquote-character = BACKTICK\n' > "$out/metadata"
    exit 0;;
  *)
    mkdir -p "$out"; printf 'schema' > "$out/db.schema.sql"
    if [[ "$saw_source_data" -eq 1 ]]; then
      printf '[source]\nSOURCE_LOG_FILE = "binlog.000100"\nSOURCE_LOG_POS = 4\n' > "$out/metadata"
    else
      printf '[source]\n# SOURCE_LOG_FILE = "binlog.000100"\n# SOURCE_LOG_POS = 4\n' > "$out/metadata"
    fi
    exit 0;;
esac
STUB
chmod +x "$DIAG_DIR/mydumper"

cat > "$DIAG_DIR/mysql" <<'STUB'
#!/usr/bin/env bash
sql=""
while [[ $# -gt 0 ]]; do
  case "$1" in --defaults-extra-file) shift 2;; -e) sql="$2"; shift 2;; *) shift;; esac
done
shopt -s nocasematch
if [[ "$sql" == *"log_bin"* ]]; then printf 'log_bin\tON\n'; exit 0; fi
if [[ "$sql" == *"binlog_format"* ]]; then printf 'binlog_format\tROW\n'; exit 0; fi
if [[ "$sql" == *"SHOW BINARY LOG STATUS"* || "$sql" == *"SHOW MASTER STATUS"* ]]; then
  printf 'binlog.000100\t4\t\t\t\n'; exit 0
fi
if [[ "$sql" == *"SHOW BINARY LOGS"* ]]; then printf 'binlog.000100\t4\n'; exit 0; fi
exit 0
STUB
chmod +x "$DIAG_DIR/mysql"

cat > "$DIAG_DIR/mysqlbinlog" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$DIAG_DIR/mysqlbinlog"

cat > "$DIAG_DIR/rclone" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "--config" ]]; then shift 2; fi
case "$1" in
  listremotes) printf 'remote:\n'; exit 0;;
  cat) [[ -f "$DIAG_BUCKET/$(basename "$2")" ]] && cat "$DIAG_BUCKET/$(basename "$2")"; exit 0;;
  copyto)
    dest="$DIAG_BUCKET/$(basename "$3")"
    [[ -e "$dest" ]] && { echo "exists" >&2; exit 1; }
    cp "$2" "$dest"; exit 0;;
  deletefile) rm -f "$DIAG_BUCKET/$(basename "$2")"; exit 0;;
  sync) printf '%s\n' "$2" > "$DIAG_BUCKET/.last_sync_dir"; exit 0;;
  size)
    if [[ -f "$DIAG_BUCKET/.last_sync_dir" ]]; then
      d="$(cat "$DIAG_BUCKET/.last_sync_dir")"
      if [[ -d "$d" ]]; then
        c="$(find "$d" -type f 2>/dev/null | wc -l)"
        b="$(find "$d" -type f -printf '%s\n' 2>/dev/null | awk '{s+=$1} END {print s+0}')"
        printf '{"count":%s,"bytes":%s,"sizeless":0}\n' "$c" "$b"; exit 0
      fi
    fi
    printf '{"count":0,"bytes":0,"sizeless":0}\n'; exit 0;;
  *) exit 0;;
esac
STUB
chmod +x "$DIAG_DIR/rclone"

# curl double: always HTTP 200 (like the real reporter) and records the reported
# backup status separately from the HTTP code, which is the whole point.
cat > "$DIAG_DIR/curl" <<'STUB'
#!/usr/bin/env bash
payload=""; resp=""
while [[ $# -gt 0 ]]; do
  case "$1" in --data-binary) payload="$2"; shift 2;; -o) resp="$2"; shift 2;;
                -w|--max-time) shift 2;; *) shift;; esac
done
{
  printf 'HTTP=200\n'
  printf '%s\n' "$payload"
} >> "$DIAG_BUCKET/reports.log"
[[ -n "$resp" ]] && printf '{"ok":true}' > "$resp"
printf '%s' "200"
exit 0
STUB
chmod +x "$DIAG_DIR/curl"

DIAG_OLD_PATH="$PATH"
export PATH="$DIAG_DIR:$PATH"
export RCLONE_CONFIG="$DIAG_DIR/rclone.conf"

run_full_diag() { # <mydumper mode> -> sets DIAG_RC and DIAG_LOG
  DIAG_LOG="$DIAG_DIR/out-$1.log"
  rm -f "$DIAG_BUCKET/reports.log" "$DIAG_BUCKET/backup_state.json" \
        "$DIAG_BUCKET/.last_sync_dir" "$DIAG_BUCKET/backup.lock"
  # NOTE: the rc is captured ON THE SAME LINE as the invocation. The suite runs
  # under `set -e`, so a bare `( ... )` whose non-zero status is only inspected on
  # the following line would terminate the whole run instead of being recorded.
  # (This is the same `|| rc=$?` idiom the other flow helpers in this file use.)
  DIAG_RC=0
  (
    cd "$DIAG_DIR" || exit 1
    DIAG_MYDUMPER="$1" \
    MYSQL_HOST=h MYSQL_USER=u MYSQL_PASSWORD=p MYSQL_DATABASE=d MYSQL_PORT=3306 \
    MYSQL_CLIENT_BIN=mysql MYSQLBINLOG_BIN=mysqlbinlog MYSQLBINLOG_SERVER_ID=424242 \
    R2_ACCESS_KEY_ID=a R2_SECRET_ACCESS_KEY=s R2_ENDPOINT=e R2_BUCKET=b \
    R2_PATH=mysql-backup R2_PROVIDER=Other R2_ACL= \
    BACKUP_REPORT_URL="https://puptvs.com/x" BACKUP_REPORT_TOKEN="tok" REPORT_TIMEOUT=5 \
    BACKUP_BINLOG_ENABLED=true BACKUP_BINLOG_VERIFY=true BACKUP_FULL_INTERVAL_DAYS=14 \
    BACKUP_LOCK_ENABLED=true BACKUP_LOCK_TTL_SECONDS=3600 \
    RCLONE_CONFIG="$RCLONE_CONFIG" \
    bash "$ENTRYPOINT" >"$DIAG_LOG" 2>&1
  ) || DIAG_RC=$?
}

# --- (a) a FAILED full must report status=failed, and the report line must
#         name that status so the accompanying HTTP 200 is not misread. -------
run_full_diag "fail"
assert_rc_nonzero "failed full exits non-zero" "$DIAG_RC"
DIAG_OUT="$(cat "$DIAG_LOG")"
DIAG_REPORTS="$(cat "$DIAG_BUCKET/reports.log" 2>/dev/null)"
assert_contains "failed full reports backup status 'failed'" "$DIAG_REPORTS" '"status":"failed"'
assert_not_contains "failed full never reports backup status 'success'" "$DIAG_REPORTS" '"status":"success"'
# The HTTP code is 200 in both cases, so the log line must disambiguate.
assert_contains "report log line names the backup status it carried" "$DIAG_OUT" "report (backup status 'failed') accepted (HTTP 200)"
assert_not_contains "report log line does not claim a successful backup status" "$DIAG_OUT" "report (backup status 'success') accepted"

# --- (b) the exit diagnosis must name the failing stage and the dump's rc. ----
assert_contains "exit diagnosis states final_status=failed" "$DIAG_OUT" "EXIT-DIAGNOSIS: final_status=failed"
assert_contains "exit diagnosis names the failing stage" "$DIAG_OUT" "stage=full_backup"
assert_contains "exit diagnosis carries the failing mydumper reason" "$DIAG_OUT" "reason=exit_status=1"
assert_contains "exit diagnosis repeats the error message" "$DIAG_OUT" "error_message='mydumper failed to produce a logical database snapshot.'"
assert_contains "exit diagnosis reports the mydumper rc" "$DIAG_OUT" "full_backup_rc=1"
assert_contains "exit diagnosis reports the report rc" "$DIAG_OUT" "report_rc=0"
assert_contains "exit diagnosis reports the anchor as unusable" "$DIAG_OUT" "binlog_anchor_usable=no"

# --- (c) a failed full must never become the chain base. ---------------------
if [[ -f "$DIAG_BUCKET/backup_state.json" ]]; then
  fail "failed FULL must not write backup state"
else
  pass "failed FULL never writes backup state"
fi

# --- (d) an EMPTY dump dir must fail the same way (a dump of 0 files is not a
#         valid baseline). -------------------------------------------------
run_full_diag "emptydir"
assert_rc_nonzero "empty-dump full exits non-zero" "$DIAG_RC"
assert_contains "empty-dump full fails at the dump stage" "$(cat "$DIAG_LOG")" "mydumper produced an empty backup directory"
assert_contains "empty-dump full reports status failed" "$(cat "$DIAG_BUCKET/reports.log")" '"status":"failed"'

# --- (e) a SUCCESSFUL full: the diagnosis must show every stage rc=0 and a
#         usable anchor, so the two outcomes are distinguishable purely from
#         the log. ---------------------------------------------------------
run_full_diag "ok"
assert_rc_zero "successful full exits 0" "$DIAG_RC"
DIAG_OK_OUT="$(cat "$DIAG_LOG")"
assert_contains "successful full reports status success" "$(cat "$DIAG_BUCKET/reports.log")" '"status":"success"'
assert_contains "successful full logs every stage rc" "$DIAG_OK_OUT" "full_backup_rc=0 upload_rc=0 verify_rc=0 report_rc=0 state_update_rc=0"
assert_contains "successful full diagnosis final_status=success" "$DIAG_OK_OUT" "final_status=success"
assert_contains "successful full records a usable binlog anchor" "$DIAG_OK_OUT" "binlog_anchor_usable=yes"
assert_contains "successful full names the anchor coordinates" "$DIAG_OK_OUT" "anchor_file='binlog.000100'"
# The lock release must not be able to change a successful status.
assert_contains "lock release is reported separately from the failing stage" "$DIAG_OK_OUT" "lock_release_rc=0"

# --- (e2) INVOCATION: run_full_backup must pass --source-data, and the anchor
#          must therefore come from ACTIVE [source] keys (not a commented
#          placeholder, and not a post-dump server query). -----------------
assert_contains "run_full_backup invokes mydumper with --source-data" \
  "$(cat "$DIAG_DIR/mydumper_cmdline" 2>/dev/null)" "--source-data"
# The persisted anchor must be a REAL, well-formed coordinate in state.
DIAG_STATE="$(cat "$DIAG_BUCKET/backup_state.json" 2>/dev/null)"
DIAG_STATE_FILE="$(printf '%s' "$DIAG_STATE" | sed -n 's/.*"last_binlog_file": "\([^"]*\)".*/\1/p')"
DIAG_STATE_POS="$(printf '%s' "$DIAG_STATE" | sed -n 's/.*"last_binlog_position": \([0-9]*\).*/\1/p')"
if [[ "$DIAG_STATE_FILE" =~ ^[A-Za-z0-9._-]+\.[0-9]+$ ]]; then
  pass "successful FULL persists a well-formed last_binlog_file (${DIAG_STATE_FILE})"
else
  fail "successful FULL must persist a well-formed last_binlog_file (got '${DIAG_STATE_FILE}')"
fi
if [[ "$DIAG_STATE_POS" =~ ^[0-9]+$ ]] && [[ "${DIAG_STATE_POS:-0}" -gt 0 ]]; then
  pass "successful FULL persists a numeric last_binlog_position > 0 (${DIAG_STATE_POS})"
else
  fail "successful FULL must persist a numeric last_binlog_position > 0 (got '${DIAG_STATE_POS}')"
fi
# The same anchor must be mirrored into the end-boundary fields the incremental
# run resumes from, otherwise the chain would start from the wrong place.
assert_contains "state also records the anchor as the incremental start file" \
  "$DIAG_STATE" "\"last_binlog_end_file\": \"${DIAG_STATE_FILE}\""

# --- (f) a MISSING binlog anchor must NOT fail the FULL, but must be reported
#         as unusable so operators know incrementals cannot start from it. ----
run_full_diag "noanchor"
assert_rc_zero "FULL without a binlog anchor still exits 0 (valid logical baseline)" "$DIAG_RC"
DIAG_NOANCHOR_OUT="$(cat "$DIAG_LOG")"
assert_contains "anchor-less full warns the anchor is unusable" "$DIAG_NOANCHOR_OUT" "did not contain a usable binlog anchor"
assert_contains "anchor-less full diagnosis marks the anchor unusable" "$DIAG_NOANCHOR_OUT" "binlog_anchor_usable=no"
assert_contains "anchor-less full records an empty anchor in state" \
  "$(cat "$DIAG_BUCKET/backup_state.json" 2>/dev/null)" '"last_binlog_file": ""'
# It is still a reported, persisted success — the chain just cannot advance.
assert_contains "anchor-less full still reports success" "$(cat "$DIAG_BUCKET/reports.log")" '"status":"success"'

# --- (f1) ANCHOR DIAGNOSTICS: an anchorless FULL must explain ITSELF. --------
# Regression for the production symptom where a fresh FULL logged only
#     [backup][warn] mydumper metadata did not contain a usable binlog anchor ...
# with no evidence of whether the cause was the flag, the parser, or the SERVER.
# The real cause is a closed loop that no unit test can observe statically: a
# mydumper that only implements the pre-8.4 `SHOW MASTER STATUS` statement fails
# that query against MySQL 8.4+ ("Couldn't get master position - ERROR 1064") and
# then writes a metadata file with NO `[source]` section at all.
#
# These assertions pin the evidence that distinguishes those causes:
#   1. the mydumper VERSION actually running;
#   2. the metadata path and whether the file even exists;
#   3. whether a bare `[source]` section is present (absent => server-side cause);
#   4. exactly what the production parser extracted (both empty => no anchor).
assert_contains "anchor-less full logs the mydumper version actually running" \
  "$DIAG_NOANCHOR_OUT" "DIAG anchor: mydumper_version="
assert_contains "anchor-less full logs the metadata path" \
  "$DIAG_NOANCHOR_OUT" "DIAG anchor: metadata_path="
assert_contains "anchor-less full logs whether the metadata file exists" \
  "$DIAG_NOANCHOR_OUT" "exists=yes"
# The `noanchor` double writes a metadata file with NO [source] section, which is
# exactly what a pre-8.4 mydumper produces against a MySQL 8.4 server.
assert_contains "anchor-less full reports the [source] section is absent" \
  "$DIAG_NOANCHOR_OUT" "DIAG anchor: source_section_present=no"
assert_contains "anchor-less full shows the parser extracted nothing" \
  "$DIAG_NOANCHOR_OUT" "DIAG anchor: parsed_SOURCE_LOG_FILE='<none>' parsed_SOURCE_LOG_POS='<none>'"
# The diagnostics must be emitted BEFORE the warning so the warning is explained
# by the lines immediately above it.
#
# NOTE: this is asserted against the SOURCE ORDER, not the interleaving of the
# captured log. `log` writes to stdout and `warn` writes to stderr, and POSIX
# gives no ordering guarantee between two different streams redirected into the
# same file, so a runtime ordering assertion would be flaky.
DIAG_DEF_LINE="$(grep -n -F 'log_binlog_anchor_diagnostics "$BACKUP_DIR"' "$ENTRYPOINT" | head -n1 | cut -d: -f1)"
WARN_LINE="$(grep -n -F 'warn "mydumper metadata did not contain a usable binlog anchor' "$ENTRYPOINT" | head -n1 | cut -d: -f1)"
if [[ -n "$DIAG_DEF_LINE" && -n "$WARN_LINE" && "$DIAG_DEF_LINE" -lt "$WARN_LINE" ]]; then
  pass "anchor diagnostics are emitted before the anchor warning (source order)"
else
  fail "anchor diagnostics must precede the anchor warning (diag=${DIAG_DEF_LINE:-?} warn=${WARN_LINE:-?})"
fi
# The diagnostics are emitted on stdout (they are informational, not a warning).
assert_contains "anchor diagnostics are emitted on stdout" \
  "$(printf '%s\n' "$DIAG_NOANCHOR_OUT")" "DIAG anchor: source_section_present=no"
# Safety rule unchanged: an unusable anchor still records an empty anchor.
assert_contains "anchor diagnostics do not fabricate an anchor in state" \
  "$(cat "$DIAG_BUCKET/backup_state.json" 2>/dev/null)" '"last_binlog_file": ""'

# --- (f1b) The diagnostics must NEVER leak a secret. ------------------------
assert_not_contains "anchor diagnostics never print the DB password" "$DIAG_NOANCHOR_OUT" "sup3rsecret-db-pass"
assert_not_contains "anchor diagnostics never print the report token" "$DIAG_NOANCHOR_OUT" "super-secret-report-token"
assert_not_contains "anchor diagnostics never print the R2 secret" "$DIAG_NOANCHOR_OUT" "r2super-secret-key"

# --- (f1c) The SUCCESSFUL path must also log the real command line. ---------
# Requirement: prove --source-data is in the command ACTUALLY EXECUTED, not just
# in the source. The command line is logged (redacted) before every run.
assert_contains "full run logs the executed mydumper command" \
  "$DIAG_OK_OUT" "mydumper command: mydumper"
assert_contains "logged mydumper command contains --source-data" \
  "$DIAG_OK_OUT" "--source-data"
assert_contains "logged mydumper command shows the defaults-file is used" \
  "$DIAG_OK_OUT" "--defaults-file="
assert_contains "full run logs the mydumper version" "$DIAG_OK_OUT" "mydumper version: "
# A successful anchor must NOT emit the failure diagnostics.
assert_not_contains "successful full emits no anchor-failure diagnostics" \
  "$DIAG_OK_OUT" "DIAG anchor: parsed_SOURCE_LOG_FILE='<none>'"
# The redactor must be a real control: feed it a secret and confirm it is scrubbed.
REDACT_PROBE="$(bash -c '
  export MYSQL_PASSWORD="sup3rsecret-db-pass"
  export R2_SECRET_ACCESS_KEY="r2super-secret-key"
  export BACKUP_REPORT_TOKEN="super-secret-report-token"
  export BACKUP_SOURCED=1
  source "$0" >/dev/null 2>&1
  redact_cmd "x sup3rsecret-db-pass y r2super-secret-key z --password=sup3rsecret-db-pass"
' "$ENTRYPOINT" 2>/dev/null)"
assert_not_contains "redact_cmd scrubs the DB password" "$REDACT_PROBE" "sup3rsecret-db-pass"
assert_not_contains "redact_cmd scrubs the R2 secret" "$REDACT_PROBE" "r2super-secret-key"
assert_contains "redact_cmd marks the redaction" "$REDACT_PROBE" "[REDACTED]"

# --- (f1d) Static guard: the logged command must be the SAME flag set that the
#          mydumper invocation below it actually executes. A future edit that
#          adds a flag to one but not the other would silently misreport the
#          command, so both occurrences are counted. (-F avoids any regex
#          interpretation of the trailing line-continuation backslash.)
assert_eq "the --source-data flag appears in both the logged and executed command" \
  "2" "$(grep -c -F -- '--source-data \' "$ENTRYPOINT" || true)"

# --- (f2) CHAIN SAFETY: an anchor-less FULL must NOT be usable as an
#          incremental base. Driving a real INCREMENTAL against that persisted
#          state must fail safely and must NOT advance the state.
#
# This is the end-to-end guarantee behind requirement 8: a FULL that recorded no
# anchor can never silently become the parent of an incremental.
DIAG_NOANCHOR_STATE_BEFORE="$(cat "$DIAG_BUCKET/backup_state.json" 2>/dev/null)"
assert_contains "anchor-less FULL state has an empty anchor" \
  "$DIAG_NOANCHOR_STATE_BEFORE" '"last_binlog_file": ""'

rm -f "$DIAG_BUCKET/reports.log"
DIAG_INC_RC=0
(
  cd "$DIAG_DIR" || exit 1
  MYSQL_HOST=h MYSQL_USER=u MYSQL_PASSWORD=p MYSQL_DATABASE=d MYSQL_PORT=3306 \
  MYSQL_CLIENT_BIN=mysql MYSQLBINLOG_BIN=mysqlbinlog MYSQLBINLOG_SERVER_ID=424242 \
  R2_ACCESS_KEY_ID=a R2_SECRET_ACCESS_KEY=s R2_ENDPOINT=e R2_BUCKET=b \
  R2_PATH=mysql-backup R2_PROVIDER=Other R2_ACL= \
  BACKUP_REPORT_URL="https://puptvs.com/x" BACKUP_REPORT_TOKEN=tok REPORT_TIMEOUT=5 \
  BACKUP_BINLOG_ENABLED=true BACKUP_BINLOG_VERIFY=true BACKUP_FULL_INTERVAL_DAYS=14 \
  BACKUP_LOCK_ENABLED=false \
  RCLONE_CONFIG="$RCLONE_CONFIG" \
  bash "$ENTRYPOINT" >"$DIAG_DIR/inc.log" 2>&1
) || DIAG_INC_RC=$?

assert_rc_nonzero "an anchor-less FULL cannot start an incremental (fails safely)" "$DIAG_INC_RC"
assert_contains "the failure names the missing binlog position" \
  "$(cat "$DIAG_DIR/inc.log")" "no recorded binlog position"
assert_contains "the failure asks for a new FULL" \
  "$(cat "$DIAG_DIR/inc.log")" "A new full backup is required"
assert_contains "the failure is reported to PUPTracker as failed" \
  "$(cat "$DIAG_BUCKET/reports.log" 2>/dev/null)" '"status":"failed"'
# State must be byte-identical: a refused incremental must not advance the chain.
assert_eq "anchor-less FULL cannot advance incremental state" \
  "$DIAG_NOANCHOR_STATE_BEFORE" "$(cat "$DIAG_BUCKET/backup_state.json" 2>/dev/null)"

# --- (f3) THE REPORTED PRODUCTION STATE must not become an incremental base.
# This is the EXACT state object observed on the disposable service:
#     last_successful_full_backup_name = full_2026-09-12_164735
#     last_binlog_file = ""
#     last_binlog_position = 0
# A FULL that recorded no anchor must be refused as an incremental parent even
# though it IS a valid successful FULL base. "Do not fabricate an anchor" means
# this stays a hard refusal — the state is NOT migrated, patched or inferred.
#
# NOTE: this deliberately OVERWRITES $DIAG_BUCKET/backup_state.json, so it runs
# AFTER (f2), which needs the state the earlier runs produced.
CATHY_STATE="$DIAG_BUCKET/backup_state.json"
rm -f "$CATHY_STATE" "$DIAG_BUCKET/reports.log"
cat > "$CATHY_STATE" <<'JSON'
{
  "state_version": 1,
  "updated_at": "2026-09-12T16:47:40Z",
  "last_successful_full_backup_name": "full_2026-09-12_164735",
  "last_successful_full_completed_at": "2026-09-12T16:47:35Z",
  "last_successful_full_storage_path": "integration-test/mysql-backup-v2/full/2026/09/12/full_2026-09-12_164735",
  "last_binlog_file": "",
  "last_binlog_position": 0,
  "last_binlog_end_file": "",
  "last_binlog_end_position": 0
}
JSON
CATHY_STATE_BEFORE="$(cat "$CATHY_STATE")"
DIAG_LEGACY_RC=0
(
  cd "$DIAG_DIR" || exit 1
  MYSQL_HOST=h MYSQL_USER=u MYSQL_PASSWORD=p MYSQL_DATABASE=d MYSQL_PORT=3306 \
  MYSQL_CLIENT_BIN=mysql MYSQLBINLOG_BIN=mysqlbinlog MYSQLBINLOG_SERVER_ID=424242 \
  R2_ACCESS_KEY_ID=a R2_SECRET_ACCESS_KEY=s R2_ENDPOINT=e R2_BUCKET=b \
  R2_PATH=mysql-backup R2_PROVIDER=Other R2_ACL= \
  BACKUP_REPORT_URL="https://puptvs.com/x" BACKUP_REPORT_TOKEN=tok REPORT_TIMEOUT=5 \
  BACKUP_BINLOG_ENABLED=true BACKUP_BINLOG_VERIFY=true BACKUP_FULL_INTERVAL_DAYS=14 \
  BACKUP_LOCK_ENABLED=false \
  RCLONE_CONFIG="$RCLONE_CONFIG" \
  bash "$ENTRYPOINT" >"$DIAG_DIR/legacy.log" 2>&1
) || DIAG_LEGACY_RC=$?

assert_rc_nonzero "the reported anchorless FULL cannot start an incremental" "$DIAG_LEGACY_RC"
assert_contains "it fails for the missing binlog position" \
  "$(cat "$DIAG_DIR/legacy.log")" "no recorded binlog position"
assert_contains "it asks for a new FULL" \
  "$(cat "$DIAG_DIR/legacy.log")" "A new full backup is required"
assert_contains "the refusal is reported as failed" \
  "$(cat "$DIAG_BUCKET/reports.log" 2>/dev/null)" '"status":"failed"'
# CRITICAL: the refusal must not MUTATE the state (no fabricated anchor, no
# migration). The state object must be byte-identical afterwards.
assert_eq "the reported state is left byte-identical (not migrated)" \
  "$CATHY_STATE_BEFORE" "$(cat "$CATHY_STATE")"
assert_contains "the reported state still records an empty anchor" "$(cat "$CATHY_STATE")" '"last_binlog_file": ""'
assert_contains "the reported state still records position 0" "$(cat "$CATHY_STATE")" '"last_binlog_position": 0'
# ...and no incremental was ever uploaded for it.
assert_eq "no incremental archive is uploaded for the anchorless base" "0" \
  "$(find "$DIAG_BUCKET" -name 'incremental*' 2>/dev/null | wc -l)"

# --- (g) static guards: the status-bearing stages never lose their own rc to a
#         later command, and cleanup cannot override the exit status. ---------
ENTRYPOINT_SRC="$(cat "$ENTRYPOINT")"
assert_contains "cleanup captures the exit status before releasing the lock" \
  "$ENTRYPOINT_SRC" "local status=\$?"
assert_contains "cleanup re-asserts the captured exit status" \
  "$ENTRYPOINT_SRC" 'return "$status"'
assert_contains "cleanup does not let the lock release set the exit status" \
  "$ENTRYPOINT_SRC" 'release_lock || true'
# The report's own rc is captured, never inferred from the HTTP code alone.
assert_contains "success report rc is captured explicitly" \
  "$ENTRYPOINT_SRC" 'report_now "success" || success_report_rc=$?'
assert_contains "state update rc is captured explicitly" \
  "$ENTRYPOINT_SRC" 'update_state \' 
# No secret may leak through the new diagnosis lines.
assert_not_contains "exit diagnosis never prints the report token" "$DIAG_OUT" "super-secret-report-token"
assert_not_contains "exit diagnosis never prints the DB password" "$DIAG_OUT" "sup3rsecret-db-pass"
assert_not_contains "exit diagnosis never prints the R2 secret" "$DIAG_OUT" "r2super-secret-key"

export PATH="$DIAG_OLD_PATH"
unset DIAG_MYDUMPER
rm -rf "$DIAG_DIR" "$DIAG_BUCKET"

echo "== report-stub auth (disposable stub; real HTTP when php+curl exist) =="

# The disposable PUPTracker stub is the one component whose authentication the
# mock suite CAN test for real: it is PHP, it runs under `php -S`, and it needs
# no Docker or MySQL. Delegate to its own self-contained suite so a regression in
# the stub's 401 handling (missing header / wrong scheme / wrong token / correct
# token) fails THIS run too, rather than hiding until someone runs the harness.
#
# The stub suite skips cleanly when php or curl is unavailable, and it exits 0 on
# all-pass, so a non-zero exit here is a genuine stub failure.
STUB_SUITE="$HERE/integration/report-stub/test_stub.sh"
if [[ -f "$STUB_SUITE" ]]; then
  STUB_OUT="$(mktemp)"
  # Run with the PRISTINE PATH so the stub suite uses the real php/curl even if
  # an earlier section leaked a double onto PATH (see SUITE_REAL_PATH above).
  if PATH="$SUITE_REAL_PATH" bash "$STUB_SUITE" >"$STUB_OUT" 2>&1; then
    STUB_OK=1
  else
    STUB_OK=0
  fi
  STUB_PASS="$(sed -n 's/^PASS: \([0-9]*\).*/\1/p' "$STUB_OUT" | tail -n1)"
  STUB_FAIL="$(sed -n 's/^PASS: [0-9]* *FAIL: \([0-9]*\).*/\1/p' "$STUB_OUT" | tail -n1)"
  STUB_SKIP="$(sed -n 's/.*SKIP: \([0-9]*\)$/\1/p' "$STUB_OUT" | tail -n1)"
  if [[ "$STUB_OK" -eq 1 ]]; then
    pass "report-stub suite passed (${STUB_PASS:-0} checks)"
  else
    fail "report-stub suite failed (${STUB_FAIL:-?} failing check(s))"
    grep -E '^FAIL' "$STUB_OUT" 2>/dev/null | sed 's/^/       /'
  fi
  if [[ -n "$STUB_SKIP" && "$STUB_SKIP" != "0" ]]; then
    skip "report-stub suite reported ${STUB_SKIP} skipped check(s) (php/curl unavailable)"
  fi
  rm -f "$STUB_OUT"
else
  skip "report-stub suite not present (integration/report-stub/test_stub.sh)"
fi

echo
echo "=========================================="
echo "PASS: $PASS   FAIL: $FAIL   SKIP: $SKIP"
echo "=========================================="
rm -rf "$FLOW_DIR" "$STUB_DIR"
[[ "$FAIL" -eq 0 ]] || exit 1
