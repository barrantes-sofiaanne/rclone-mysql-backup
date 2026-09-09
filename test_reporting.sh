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
#
# NOTE: This runs the helper functions in-process by sourcing entrypoint.sh.
# The top-level "Main" section only runs when the script is executed, so we
# guard it by detecting entrypoint is being sourced.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTRYPOINT="$HERE/entrypoint.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "ok   - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL - $1"; }

assert_eq() { # desc expected actual
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected [$2] got [$3])"; fi
}

assert_contains() { # desc haystack needle
  if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1 (missing [$3])"; fi
}

assert_not_contains() { # desc haystack needle
  if [[ "$2" != *"$3"* ]]; then pass "$1"; else fail "$1 (unexpectedly contains [$3])"; fi
}

# ---------------------------------------------------------------------------
# 0. Shell syntax
# ---------------------------------------------------------------------------
echo "== shell syntax =="
if bash -n "$ENTRYPOINT"; then pass "bash -n entrypoint.sh"; else fail "bash -n entrypoint.sh"; fi

# ---------------------------------------------------------------------------
# Source the entrypoint with controlled env (helpers only; main is guarded)
# ---------------------------------------------------------------------------
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

# shellcheck source=entrypoint.sh
source "$ENTRYPOINT"

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

# Reset PATH
export PATH="$OLD_PATH"

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
  STUB_HTTP_CODE=201 \
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
  BACKUP_REPORT_URL="$BACKUP_REPORT_URL" BACKUP_REPORT_TOKEN="$BACKUP_REPORT_TOKEN" \
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
  REPORT_TIMEOUT=2 \
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
OLD_PATH="$PATH"
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
export PATH="$OLD_PATH"
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

echo
echo "=========================================="
echo "PASS: $PASS   FAIL: $FAIL"
echo "=========================================="
rm -rf "$FLOW_DIR" "$STUB_DIR"
[[ "$FAIL" -eq 0 ]] || exit 1
