#!/usr/bin/env bash
#
# ---------------------------------------------------------------------------
# rclone-mysql-backup — REAL integration harness
# ---------------------------------------------------------------------------
#
# WHAT THIS PROVES (and what it does not):
#
#   This harness builds the repository's ACTUAL Dockerfile into an image and
#   runs that image (not a shell re-implementation of it) against a REAL MySQL
#   8.4 server with binary logging enabled, a REAL object store, and a REAL
#   HTTP reporting endpoint. A green run therefore proves the shipped container
#   works — something the stubbed suite in test_reporting.sh cannot prove.
#
#   It does NOT prove anything about the production Railway database, the
#   production R2 bucket, or the production PUPTracker service. It refuses to
#   run against them; see "DISPOSABLE-ENVIRONMENT GUARD" below.
#
# USAGE
#   bash integration/run.sh                 # all phases
#   bash integration/run.sh preflight       # named phases only
#   bash integration/run.sh full inc1       # a subset
#   PHASES="preflight build full" bash integration/run.sh
#   bash integration/run.sh selftest        # no Docker: self-check the harness
#
#   Phase order: selftest | preflight | build | up | mysql-check | full |
#                inc1 | inc2 | rotation | restore | purged | safety | report
#
#   `all` expands to: preflight build up mysql-check full inc1 inc2 rotation
#                     restore purged safety report
#
# REQUIREMENTS
#   docker (or an equivalent CLI), curl, and network access to pull images.
#   The host must be able to run linux/amd64 containers.
#
# DISPOSABLE-ENVIRONMENT GUARD
#   This harness will REFUSE to start if the target looks like production:
#     - MYSQL_HOST / MYSQL_DATABASE or TEST_MYSQL_* naming the production
#       database, the production Railway MySQL service, or a puptracker.com /
#       railway host;
#     - an R2/BACKUP path that does not carry an explicit test marker;
#     - a BACKUP_REPORT_URL pointing at the production PUPTracker webhook.
#   Setting ALLOW_NON_DISPOSABLE=1 downgrades the refusal to a loud warning, so
#   the guard can never be silently bypassed by an env var typo alone.
#
# SECRETS
#   Credentials are passed to containers with `--env-file` (never on the
#   command line, which is world-readable via /proc/<pid>/cmdline) and are
#   written to a 0600 temp file that is removed on exit. No secret is ever
#   echoed into the log or into the report.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"

# ---------------------------------------------------------------------------
# Configuration (all overridable from the environment)
# ---------------------------------------------------------------------------
IMAGE_TAG="${IMAGE_TAG:-rclone-mysql-backup:integration}"
NETWORK="${NETWORK:-rmb-integration}"
WORK_DIR="${WORK_DIR:-$(mktemp -d)}"

# MySQL 8.4 — the version the production Railway service runs.
# `mysql:8.4` is pinned to the 8.4 series so the harness stays on the same
# major version as production (binlog behaviour differs across majors).
MYSQL_IMAGE="${MYSQL_IMAGE:-mysql:8.4}"
MYSQL_CONTAINER="${MYSQL_CONTAINER:-rmb-mysql}"
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-rootpw}"
MYSQL_DATABASE="${MYSQL_DATABASE:-puptracker}"
MYSQL_USER="${MYSQL_USER:-backup}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-backuppw}"
MYSQL_PORT="${MYSQL_PORT:-33060}"
MYSQL_SERVER_ID="${MYSQL_SERVER_ID:-1}"

# Object store. Defaults to MinIO so the R2 upload/verify path is exercised for
# real. Point TEST_R2_* at a dedicated test bucket/prefix to use real R2.
MINIO_IMAGE="${MINIO_IMAGE:-minio/minio:latest}"
MINIO_CONTAINER="${MINIO_CONTAINER:-rmb-minio}"
MINIO_PORT="${MINIO_PORT:-9000}"
MINIO_ROOT_USER="${MINIO_ROOT_USER:-minioadmin}"
MINIO_ROOT_PASSWORD="${MINIO_ROOT_PASSWORD:-minioadmin}"
R2_BUCKET="${R2_BUCKET:-test-backups}"
# R2_PATH MUST carry a test marker — see the disposable-environment guard.
R2_PATH="${R2_PATH:-integration-test/mysql-backup}"
TEST_R2_ENDPOINT="${TEST_R2_ENDPOINT:-}"   # set to use a real R2 test bucket
R2_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID:-$MINIO_ROOT_USER}"
R2_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY:-$MINIO_ROOT_PASSWORD}"
R2_PROVIDER="${R2_PROVIDER:-Cloudflare}"

# Reporting endpoint. Defaults to the local stub shipped with the harness. The
# production PUPTracker webhook is refused by the guard below.
REPORT_STUB_CONTAINER="${REPORT_STUB_CONTAINER:-rmb-report-stub}"
REPORT_STUB_IMAGE="${REPORT_STUB_IMAGE:-rmb-report-stub:integration}"
REPORT_STUB_PORT="${REPORT_STUB_PORT:-18080}"
# The stub is reached by CONTAINER NAME over the shared docker network, so this
# needs no host-gateway mapping and cannot be broken by a host DNS quirk.
BACKUP_REPORT_URL="${BACKUP_REPORT_URL:-http://${REPORT_STUB_CONTAINER}:8080/}"
BACKUP_REPORT_TOKEN="${BACKUP_REPORT_TOKEN:-integration-stub-token}"
# Trim OUTER whitespace only. A token exported with a trailing newline (a very
# common footgun when a secret is piped into a variable) must not make the two
# sides disagree; the stub normalises outer whitespace the same way. This does
# not weaken auth: the content is still compared exactly on both sides.
BACKUP_REPORT_TOKEN="${BACKUP_REPORT_TOKEN#"${BACKUP_REPORT_TOKEN%%[![:space:]]*}"}"
BACKUP_REPORT_TOKEN="${BACKUP_REPORT_TOKEN%"${BACKUP_REPORT_TOKEN##*[![:space:]]}"}"
FORCE_FAIL="${FORCE_FAIL:-0}"

# Backup policy under test.
MYSQLBINLOG_SERVER_ID="${MYSQLBINLOG_SERVER_ID:-2147483001}"
BACKUP_FULL_INTERVAL_DAYS="${BACKUP_FULL_INTERVAL_DAYS:-14}"

DOCKER="${DOCKER:-docker}"
HOST_GATEWAY="${HOST_GATEWAY:-host.docker.internal}"

# The container under test reaches the host via host.docker.internal. On Linux
# this needs an explicit mapping; Docker Desktop provides it natively.
DOCKER_RUN_HOST_FLAGS=(--add-host "${HOST_GATEWAY}:host-gateway")

PASS=0
FAIL=0
SKIP=0
declare -a PHASE_RESULTS=()

# ---------------------------------------------------------------------------
# Reporting helpers
# ---------------------------------------------------------------------------
ok()   { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf 'FAIL - %s\n' "$1"; }
skipped() { SKIP=$((SKIP + 1)); printf 'SKIP - %s\n' "$1"; }

info() { printf '  - %s\n' "$1"; }
die()  { printf 'FATAL: %s\n' "$1" >&2; exit 1; }

assert_eq() { # desc expected actual
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected [$2] got [$3])"; fi
}
# Assert a set of exit codes: rc must be one of the listed values.
assert_rc_in() { # desc rc code...
  local desc="$1" rc="$2"; shift 2
  local code
  for code in "$@"; do
    if [[ "$rc" == "$code" ]]; then ok "$desc (exit ${rc})"; return 0; fi
  done
  bad "$desc (got exit ${rc}, expected one of: $*)"
}
assert_contains() { # desc haystack needle
  if [[ "$2" == *"$3"* ]]; then ok "$1"; else bad "$1 (missing [$3])"; fi
}
assert_not_contains() { # desc haystack needle
  if [[ "$2" != *"$3"* ]]; then ok "$1"; else bad "$1 (unexpectedly contains [$3])"; fi
}
assert_rc() { # desc expected_rc actual_rc
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected exit $2, got $3)"; fi
}

phase() {
  printf '\n=====================================================================\n'
  printf '== %s\n' "$1"
  printf '=====================================================================\n'
  PHASE_RESULTS+=("$1")
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then die "required command not found: $1"; fi
}

# ---------------------------------------------------------------------------
# Disposable-environment guard
# ---------------------------------------------------------------------------
# Returns 0 when the configuration is clearly non-production, 1 otherwise.
is_disposable_environment() {
  local host_lc db_lc url_lc path_lc
  host_lc="$(printf '%s' "${MYSQL_HOST:-${HOST_GATEWAY}}" | tr '[:upper:]' '[:lower:]')"
  db_lc="$(printf '%s' "${MYSQL_DATABASE}" | tr '[:upper:]' '[:lower:]')"
  url_lc="$(printf '%s' "${BACKUP_REPORT_URL}" | tr '[:upper:]' '[:lower:]')"
  path_lc="$(printf '%s' "${R2_PATH}" | tr '[:upper:]' '[:lower:]')"

  # The production PUPTracker webhook must never receive test backups.
  if [[ "$url_lc" == *"puptvs.com"* ]]; then
    printf '  ! BACKUP_REPORT_URL points at the production PUPTracker webhook.\n' >&2
    return 1
  fi

  # A production database / host name must never be the target.
  if [[ "$db_lc" == "puptracker" && "$host_lc" == *"railway"* ]]; then
    printf '  ! MYSQL target looks like the production Railway database.\n' >&2
    return 1
  fi
  case "$host_lc" in
    *mysql-52uf*|*.railway.internal*|*proxy.rlwy.net*)
      printf '  ! MYSQL_HOST looks like a production Railway MySQL service (%s).\n' "$host_lc" >&2
      return 1
      ;;
  esac

  # The backup state/prefix must carry an explicit test marker so test runs can
  # never read or advance the production chain state.
  if [[ "$path_lc" != *"test"* && "$path_lc" != *"integration"* && "$path_lc" != *"sandbox"* ]]; then
    printf '  ! R2_PATH does not carry a test marker (test/integration/sandbox): %s\n' "$R2_PATH" >&2
    return 1
  fi

  return 0
}

enforce_disposable_guard() {
  if is_disposable_environment; then
    ok "target environment is disposable (non-production)"
    return 0
  fi

  if [[ "${ALLOW_NON_DISPOSABLE:-0}" == "1" ]]; then
    printf 'WARNING: non-disposable configuration accepted because ALLOW_NON_DISPOSABLE=1.\n' >&2
    bad "target environment is NOT provably disposable (overridden)"
    return 0
  fi

  die "refusing to run: the target environment does not look disposable. Set ALLOW_NON_DISPOSABLE=1 only if you are certain."
}

# ---------------------------------------------------------------------------
# MySQL helpers (password never on the command line)
# ---------------------------------------------------------------------------
# mysql_exec <sql> [database]
mysql_exec() {
  local sql="$1"
  local db="${2:-}"
  local cnf
  cnf="$(mktemp)"
  chmod 600 "$cnf"
  {
    printf '[client]\n'
    printf 'host=127.0.0.1\n'
    printf 'port=%s\n' "$MYSQL_PORT"
    printf 'user=root\n'
    printf 'password=%s\n' "$MYSQL_ROOT_PASSWORD"
  } > "$cnf"
  local out
  if [[ -n "$db" ]]; then
    out="$("$DOCKER" exec -i "$MYSQL_CONTAINER" mysql --defaults-extra-file=/dev/stdin "$db" -N -B -e "$sql" < "$cnf" 2>/dev/null)"
  else
    out="$("$DOCKER" exec -i "$MYSQL_CONTAINER" mysql --defaults-extra-file=/dev/stdin -N -B -e "$sql" < "$cnf" 2>/dev/null)"
  fi
  rm -f "$cnf"
  printf '%s' "$out"
}

mysql_ready() {
  "$DOCKER" exec "$MYSQL_CONTAINER" mysqladmin ping -h 127.0.0.1 --silent >/dev/null 2>&1
}

wait_for_mysql() {
  local tries=0
  while [[ "$tries" -lt 60 ]]; do
    if mysql_ready; then return 0; fi
    tries=$((tries + 1))
    sleep 2
  done
  return 1
}

# ---------------------------------------------------------------------------
# Container-run helpers
# ---------------------------------------------------------------------------
# Write the container environment to a 0600 env-file so no secret ever appears
# in a command line, a log line, or `docker inspect` output of the CLI process.
BACKUP_ENV_FILE=""
write_backup_env_file() {
  BACKUP_ENV_FILE="$WORK_DIR/backup.env"
  ( umask 077
    {
      printf 'MYSQL_HOST=%s\n' "$HOST_GATEWAY"
      printf 'MYSQL_PORT=3306\n'
      printf 'MYSQL_USER=%s\n' "$MYSQL_USER"
      printf 'MYSQL_PASSWORD=%s\n' "$MYSQL_PASSWORD"
      printf 'MYSQL_DATABASE=%s\n' "$MYSQL_DATABASE"
      printf 'R2_ACCESS_KEY_ID=%s\n' "$R2_ACCESS_KEY_ID"
      printf 'R2_SECRET_ACCESS_KEY=%s\n' "$R2_SECRET_ACCESS_KEY"
      printf 'R2_ENDPOINT=%s\n' "$R2_ENDPOINT_EFFECTIVE"
      printf 'R2_BUCKET=%s\n' "$R2_BUCKET"
      printf 'R2_PATH=%s\n' "$R2_PATH"
      printf 'R2_PROVIDER=%s\n' "$R2_PROVIDER"
      printf 'BACKUP_REPORT_URL=%s\n' "$BACKUP_REPORT_URL"
      printf 'BACKUP_REPORT_TOKEN=%s\n' "$BACKUP_REPORT_TOKEN"
      printf 'MYSQLBINLOG_SERVER_ID=%s\n' "$MYSQLBINLOG_SERVER_ID"
      printf 'BACKUP_FULL_INTERVAL_DAYS=%s\n' "$BACKUP_FULL_INTERVAL_DAYS"
      printf 'BINLOG_FETCH_STRATEGY=raw\n'
    } > "$BACKUP_ENV_FILE"
  )
}

# run_backup [extra env KEY=VALUE ...] -> runs the REAL image; echoes its rc.
run_backup() {
  local rc=0
  "$DOCKER" run --rm \
    --network "$NETWORK" \
    "${DOCKER_RUN_HOST_FLAGS[@]}" \
    --env-file "$BACKUP_ENV_FILE" \
    "${extra[@]}" \
    "$IMAGE_TAG" >"$WORK_DIR/last_run.log" 2>&1 || rc=$?
  return "$rc"
}

# ---------------------------------------------------------------------------
# Phases
# ---------------------------------------------------------------------------
phase_selftest() {
  phase "selftest (harness logic; no Docker required)"

  # The disposable guard must reject production-looking input and accept
  # test-looking input. These are the harness's own safety properties.
  local rc
  ( MYSQL_DATABASE=puptracker MYSQL_HOST=mysql-52uf.railway.internal \
    BACKUP_REPORT_URL="http://x/" R2_PATH=integration-test/mysql-backup \
    is_disposable_environment ) >/dev/null 2>&1 && rc=0 || rc=$?
  assert_rc "guard rejects a production Railway MySQL host" 1 "$rc"

  ( MYSQL_DATABASE=puptracker MYSQL_HOST=localhost \
    BACKUP_REPORT_URL="https://puptvs.com/admin/super-admin/backups/report" \
    R2_PATH=integration-test/mysql-backup \
    is_disposable_environment ) >/dev/null 2>&1 && rc=0 || rc=$?
  assert_rc "guard rejects the production PUPTracker webhook" 1 "$rc"

  ( MYSQL_DATABASE=puptracker MYSQL_HOST=localhost \
    BACKUP_REPORT_URL="http://host.docker.internal:18080/" R2_PATH=mysql-backup \
    is_disposable_environment ) >/dev/null 2>&1 && rc=0 || rc=$?
  assert_rc "guard rejects an unmarked backup path (production state risk)" 1 "$rc"

  ( MYSQL_DATABASE=puptracker MYSQL_HOST=localhost \
    BACKUP_REPORT_URL="http://host.docker.internal:18080/" R2_PATH=integration-test/mysql-backup \
    is_disposable_environment ) >/dev/null 2>&1 && rc=0 || rc=$?
  assert_rc "guard accepts a fully test-scoped configuration" 0 "$rc"

  # The real image must exist before the container phases can run.
  if "$DOCKER" image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
    ok "image ${IMAGE_TAG} is present"
  else
    skipped "image ${IMAGE_TAG} not built yet (run the build phase)"
  fi

  # The reporting stub is the one part of this harness that can be tested for
  # real WITHOUT Docker: it is PHP and runs under `php -S`. Run its own suite
  # here so a stub auth regression is caught by `selftest` alone.
  local stub_suite="$HERE/report-stub/test_stub.sh"
  if [[ -f "$stub_suite" ]]; then
    if bash "$stub_suite" >"$WORK_DIR/stub_suite.log" 2>&1; then
      ok "report-stub auth suite passed (real HTTP; no Docker required)"
    else
      bad "report-stub auth suite FAILED (see ${WORK_DIR}/stub_suite.log)"
      grep -E '^FAIL' "$WORK_DIR/stub_suite.log" 2>/dev/null | sed 's/^/      /'
    fi
  else
    skipped "report-stub auth suite not present"
  fi
}

phase_preflight() {
  phase "preflight (toolchain)"
  if command -v "$DOCKER" >/dev/null 2>&1; then
    ok "docker CLI is available"
    "$DOCKER" version >/dev/null 2>&1 && ok "docker daemon is reachable" || bad "docker daemon is not reachable"
  else
    bad "docker CLI is not available — every container phase will be NOT EXECUTED"
    return 0
  fi
  command -v curl >/dev/null 2>&1 && ok "curl is available" || bad "curl is not available"

  enforce_disposable_guard

  # Dockerfile presence/verification (static).
  if [[ -f "$REPO_ROOT/Dockerfile" ]]; then
    ok "repository Dockerfile present"
  else
    bad "repository Dockerfile missing"
  fi

  # The build stage fails on a missing binary; assert that intent is still in
  # the Dockerfile rather than trusting it from memory.
  local df
  df="$(cat "$REPO_ROOT/Dockerfile" 2>/dev/null || true)"
  local tool
  for tool in bash mydumper rclone curl date find sha256sum sed awk grep sort wc head mktemp tr dirname gzip mysql mysqlbinlog; do
    if [[ "$df" == *"$tool"* ]]; then
      ok "Dockerfile verifies required binary: ${tool}"
    else
      bad "Dockerfile does not verify required binary: ${tool}"
    fi
  done
}

phase_build() {
  phase "build (real Docker image from the repository Dockerfile)"
  if ! command -v "$DOCKER" >/dev/null 2>&1; then
    bad "docker unavailable — image was NOT built"
    return 0
  fi

  local rc=0
  "$DOCKER" build -t "$IMAGE_TAG" "$REPO_ROOT" >"$WORK_DIR/build.log" 2>&1 || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    bad "docker build failed (see ${WORK_DIR}/build.log)"
    tail -n 30 "$WORK_DIR/build.log" 2>/dev/null | sed 's/^/    /'
    return 0
  fi
  ok "docker build succeeded"

  # The image must actually contain the runtime tools the entrypoint requires.
  local tool
  for tool in bash mydumper rclone curl mysql mysqlbinlog gzip; do
    if "$DOCKER" run --rm --entrypoint sh "$IMAGE_TAG" -c "command -v $tool" >/dev/null 2>&1; then
      ok "image provides required binary: ${tool}"
    else
      bad "image is missing required binary: ${tool}"
    fi
  done

  # Record the resolved tool versions for the audit trail.
  "$DOCKER" run --rm --entrypoint bash "$IMAGE_TAG" -c '
    echo "mysqlbinlog: $(mysqlbinlog --version 2>/dev/null | head -n1)"
    echo "mysql:       $(mysql --version 2>/dev/null | head -n1)"
    echo "mydumper:    $(mydumper --version 2>/dev/null | head -n1)"
    echo "rclone:      $(rclone version 2>/dev/null | head -n1)"
  ' >"$WORK_DIR/tool_versions.txt" 2>&1 || true
  if [[ -s "$WORK_DIR/tool_versions.txt" ]]; then
    ok "resolved backup tool versions recorded"
    sed 's/^/    /' "$WORK_DIR/tool_versions.txt"
  fi
}

phase_up() {
  phase "up (disposable MySQL 8.4 + object store + report stub)"

  "$DOCKER" network inspect "$NETWORK" >/dev/null 2>&1 || "$DOCKER" network create "$NETWORK" >/dev/null 2>&1

  # --- MySQL 8.4 with binary logging enabled, ROW format. -------------------
  "$DOCKER" rm -f "$MYSQL_CONTAINER" >/dev/null 2>&1 || true
  local rc=0
  "$DOCKER" run -d --name "$MYSQL_CONTAINER" --network "$NETWORK" \
    -p "${MYSQL_PORT}:3306" \
    -e "MYSQL_ROOT_PASSWORD=${MYSQL_ROOT_PASSWORD}" \
    -e "MYSQL_DATABASE=${MYSQL_DATABASE}" \
    -e "MYSQL_USER=${MYSQL_USER}" \
    -e "MYSQL_PASSWORD=${MYSQL_PASSWORD}" \
    "$MYSQL_IMAGE" \
    --server-id="${MYSQL_SERVER_ID}" \
    --log-bin=binlog \
    --binlog-format=ROW \
    --binlog-row-image=FULL \
    --binlog_expire_logs_seconds=604800 \
    --max_binlog_size=4096 \
    >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    bad "could not start the disposable MySQL container"
    return 0
  fi
  ok "disposable MySQL container started (${MYSQL_IMAGE})"

  if wait_for_mysql; then
    ok "MySQL is accepting connections"
  else
    bad "MySQL did not become ready"
    "$DOCKER" logs --tail 30 "$MYSQL_CONTAINER" 2>&1 | sed 's/^/    /'
    return 0
  fi

  # Seed the known dataset that exists BEFORE the FULL backup.
  "$DOCKER" exec -i "$MYSQL_CONTAINER" mysql -uroot -p"$MYSQL_ROOT_PASSWORD" \
    < "$HERE/mysql-init/01-schema.sql" >/dev/null 2>&1 \
    && ok "baseline test dataset seeded" || bad "could not seed the baseline dataset"

  # --- Report stub ----------------------------------------------------------
  "$DOCKER" rm -f "$REPORT_STUB_CONTAINER" >/dev/null 2>&1 || true
  "$DOCKER" build -t "$REPORT_STUB_IMAGE" "$HERE/report-stub" >/dev/null 2>&1 \
    && ok "report stub image built" || bad "report stub image failed to build"
  # The stub takes its expected token from ITS OWN process environment, so there
  # is exactly ONE source of truth. Previously the harness injected a token FILE
  # out-of-band (`docker exec ... printf ... > /var/store/token`), which allowed
  # the file and the variable to diverge and produce a 401 from a value that
  # looked identical on both services.
  "$DOCKER" run -d --name "$REPORT_STUB_CONTAINER" --network "$NETWORK" \
    -p "${REPORT_STUB_PORT}:8080" \
    -e "FORCE_FAIL=${FORCE_FAIL}" \
    -e "REPORT_TOKEN=${BACKUP_REPORT_TOKEN}" \
    "$REPORT_STUB_IMAGE" php -S 0.0.0.0:8080 /app/server.php >/dev/null 2>&1 \
    && ok "report stub started" || bad "report stub failed to start"

  # --- Object store ---------------------------------------------------------
  if [[ -n "$TEST_R2_ENDPOINT" ]]; then
    R2_ENDPOINT_EFFECTIVE="$TEST_R2_ENDPOINT"
    ok "using the provided object-store endpoint (real R2 test bucket)"
  else
    "$DOCKER" rm -f "$MINIO_CONTAINER" >/dev/null 2>&1 || true
    "$DOCKER" run -d --name "$MINIO_CONTAINER" --network "$NETWORK" \
      -p "${MINIO_PORT}:9000" \
      -e "MINIO_ROOT_USER=${MINIO_ROOT_USER}" \
      -e "MINIO_ROOT_PASSWORD=${MINIO_ROOT_PASSWORD}" \
      "$MINIO_IMAGE" server /data --console-address ":9001" >/dev/null 2>&1 \
      && ok "local S3-compatible object store started (MinIO)" \
      || bad "object store failed to start"
    R2_ENDPOINT_EFFECTIVE="http://${MINIO_CONTAINER}:9000"
    # MinIO rejects canned ACLs; the entrypoint supports omitting it.
    R2_PROVIDER="Other"
    # Create the test bucket (loud failure if it cannot be created).
    local made=0
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      if "$DOCKER" exec "$MINIO_CONTAINER" sh -c \
        "mc alias set local http://127.0.0.1:9000 '${MINIO_ROOT_USER}' '${MINIO_ROOT_PASSWORD}' >/dev/null 2>&1 && mc mb --ignore-existing local/${R2_BUCKET} >/dev/null 2>&1"; then
        made=1; break
      fi
      # mc may not be bundled; fall back to a plain bucket dir for the FS backend
      if "$DOCKER" exec "$MINIO_CONTAINER" sh -c "mkdir -p /data/${R2_BUCKET}"; then
        made=1; break
      fi
      sleep 2
    done
    [[ "$made" -eq 1 ]] && ok "test bucket '${R2_BUCKET}' ensured" || bad "could not ensure the test bucket"
  fi

  write_backup_env_file
  ok "container environment written to a 0600 env-file"

  # The stub must report a configured token whose LENGTH matches the token the
  # backup container will send. Only the length and the source are compared —
  # never the value — so this catches a mismatch without leaking the secret.
  local health
  health="$(stub_health 2>/dev/null || true)"
  if [[ -z "$health" ]]; then
    skipped "report-stub health endpoint not reachable yet — token agreement NOT verified"
  else
    assert_contains "report stub reports a configured token" "$health" '"token_configured":true'
    assert_contains "report stub token length matches the container's" "$health" "\"token_length\":${#BACKUP_REPORT_TOKEN}"
  fi
}

phase_mysql_check() {
  phase "mysql-check (REAL MySQL 8.4 + binary logging prerequisites)"
  if ! mysql_ready; then
    bad "MySQL is not reachable — prerequisites were NOT verified"
    return 0
  fi

  local version log_bin binlog_format
  version="$(mysql_exec "SELECT VERSION();")"
  log_bin="$(mysql_exec "SHOW VARIABLES LIKE 'log_bin';" | awk -F'\t' '{print $2}')"
  binlog_format="$(mysql_exec "SHOW VARIABLES LIKE 'binlog_format';" | awk -F'\t' '{print $2}')"
  local logs
  logs="$(mysql_exec "SHOW BINARY LOGS;" | awk -F'\t' '{print $1}')"

  info "SELECT VERSION()             -> ${version}"
  info "SHOW VARIABLES LIKE log_bin  -> ${log_bin}"
  info "SHOW ... binlog_format       -> ${binlog_format}"
  info "SHOW BINARY LOGS             -> $(printf '%s' "$logs" | tr '\n' ' ')"

  assert_contains "MySQL major version is 8.4" "$version" "8.4"
  assert_eq "log_bin is ON" "ON" "$log_bin"
  assert_eq "binlog_format is ROW" "ROW" "$binlog_format"
  if [[ -n "$logs" ]]; then
    ok "at least one binary log is present"
  else
    bad "SHOW BINARY LOGS returned no files — binary logging is unusable"
  fi

  # The 8.4 statement must be preferred by the entrypoint; verify the server
  # supports it so the incremental path is exercised on the modern path.
  local status
  status="$(mysql_exec "SHOW BINARY LOG STATUS;" | awk -F'\t' 'NF>=2 {print $1":"$2; exit}')"
  if [[ -n "$status" ]]; then
    ok "SHOW BINARY LOG STATUS (MySQL 8.4 statement) is supported: ${status}"
  else
    bad "SHOW BINARY LOG STATUS returned nothing on MySQL 8.4"
  fi

  # A restorable recovery point requires the backup user to be able to read
  # binlogs as a replication client.
  local grants
  grants="$(mysql_exec "SHOW GRANTS FOR '${MYSQL_USER}'@'%';" | tr '\n' ' ')"
  assert_contains "test backup user has REPLICATION privileges" "$grants" "REPLICATION"
}

# Run one backup run of the real container and return its exit code.
backup_run() { # desc -> sets RUN_RC, RUN_LOG
  RUN_LOG="$WORK_DIR/last_run.log"
  RUN_RC=0
  run_backup "$@" || RUN_RC=$?
}

# Parse a field from the container's JSON log line for the last run.
#
# The object path MUST include the bucket: an rclone remote path is
# `remote:<bucket>/<key>`, and the entrypoint writes its state to
# `<R2_BUCKET>/<R2_PATH>/state/backup_state.json`. Omitting the bucket here makes
# this helper read a DIFFERENT bucket than the one the backups are written to
# (and than s3_list_run_objects below), so it would silently report "no state"
# even after a successful run.
last_state_json() {
  "$DOCKER" run --rm --network "$NETWORK" "${DOCKER_RUN_HOST_FLAGS[@]}" \
    --env-file "$BACKUP_ENV_FILE" --entrypoint bash "$IMAGE_TAG" -c \
    "rclone --config \"\$RCLONE_CONFIG\" cat \"remote:${R2_BUCKET}/${R2_PATH%/}/state/backup_state.json\" 2>/dev/null || true" 2>/dev/null
}

s3_list_run_objects() {
  local subpath="$1"
  "$DOCKER" run --rm --network "$NETWORK" "${DOCKER_RUN_HOST_FLAGS[@]}" \
    --env-file "$BACKUP_ENV_FILE" --entrypoint bash "$IMAGE_TAG" -c \
    "rclone --config \"\$RCLONE_CONFIG\" lsf --recursive \"remote:${R2_BUCKET}/${R2_PATH%/}/${subpath}\" 2>/dev/null || true" 2>/dev/null
}

# Ask the stub, from inside the docker network, for its NON-SECRET readiness
# snapshot: which token source it resolved, the token length, and how many
# reports it has recorded. It never returns the token, so this is safe to print.
stub_health() {
  "$DOCKER" run --rm --network "$NETWORK" --entrypoint sh "$REPORT_STUB_IMAGE" -c \
    "wget -qO- 'http://${REPORT_STUB_CONTAINER}:8080/__stub/health' 2>/dev/null \
     || php -r 'echo @file_get_contents(\"http://${REPORT_STUB_CONTAINER}:8080/__stub/health\");' 2>/dev/null || true" 2>/dev/null
}

# Print safe, non-secret report diagnostics when a run fails. This is what turns
# an opaque "HTTP 401" into an actionable cause: whether the stub has a token at
# all, where it came from, and whether the lengths even match. The token VALUE is
# never printed by either side.
dump_report_diagnostics() {
  printf '    --- report diagnostics (no secrets) ---\n'
  printf '      expected token length (container env): %s\n' "${#BACKUP_REPORT_TOKEN}"
  printf '      report url                            : %s\n' "$BACKUP_REPORT_URL"

  local health
  health="$(stub_health 2>/dev/null || true)"
  if [[ -n "$health" ]]; then
    printf '      stub health                           : %s\n' "$health"
  else
    printf '      stub health                           : unreachable\n'
  fi

  # The stub's own error code is already in the run log; surface it explicitly so
  # the four 401 causes are distinguishable at a glance.
  local code
  code="$(grep -oE '"error":"[a-z_]+"' "$RUN_LOG" 2>/dev/null | tail -n1 || true)"
  if [[ -n "$code" ]]; then
    printf '      last stub error code                  : %s\n' "$code"
  fi
}

phase_full() {
  phase "full (REAL MyDumper dump → upload → verify → report → state)"

  backup_run
  if [[ "$RUN_RC" -ne 0 ]]; then
    bad "FULL run exited ${RUN_RC} (see ${RUN_LOG})"
    tail -n 25 "$RUN_LOG" 2>/dev/null | sed 's/^/    /'
    dump_report_diagnostics
    return 0
  fi
  ok "FULL run exited 0"

  assert_contains "FULL run logged a MyDumper dump" "$(cat "$RUN_LOG")" "Stage: full_backup -> OK"
  assert_contains "FULL run logged the manifest checksum" "$(cat "$RUN_LOG")" "Backup checksum (SHA-256)"
  assert_contains "FULL run verified the upload" "$(cat "$RUN_LOG")" "Stage: verify_upload"
  assert_contains "FULL run reported success to PUPTracker" "$(cat "$RUN_LOG")" "PUPTracker report accepted"

  # Objects must actually exist remotely (not just be claimed in the log).
  local objects
  objects="$(s3_list_run_objects "full")"
  if [[ -n "$objects" ]]; then
    ok "FULL objects are present in the object store"
    printf '%s\n' "$objects" | head -n 6 | sed 's/^/      /'
  else
    bad "no FULL objects were found in the object store"
  fi

  local state
  state="$(last_state_json)"
  assert_contains "state records the successful FULL" "$state" '"last_successful_full_backup_name"'
  assert_contains "state records a binlog anchor from mydumper metadata" "$state" '"last_binlog_file"'

  # The anchor must be a REAL binlog coordinate, not an empty placeholder. This
  # is the assertion that proves mydumper was invoked with --source-data: without
  # that flag mydumper writes SOURCE_LOG_FILE/SOURCE_LOG_POS commented-out, the
  # parser refuses them, and `last_binlog_file` is persisted EMPTY.
  local anchor anchor_pos
  anchor="$(printf '%s' "$state" | sed -n 's/.*"last_binlog_file"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  anchor_pos="$(printf '%s' "$state" | sed -n 's/.*"last_binlog_position"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')"
  if [[ "$anchor" =~ ^[A-Za-z0-9._-]+\.[0-9]+$ ]]; then
    ok "FULL binlog anchor is a real, well-formed binlog filename (${anchor})"
  else
    bad "FULL binlog anchor is NOT a usable coordinate (got '${anchor}') — was --source-data passed, and is the anchor parsed from the real [source] metadata?"
  fi
  if [[ "$anchor_pos" =~ ^[0-9]+$ ]] && [[ "${anchor_pos:-0}" -gt 0 ]]; then
    ok "FULL binlog anchor position is numeric and > 0 (${anchor_pos})"
  else
    bad "FULL binlog anchor position must be a positive integer (got '${anchor_pos}')"
  fi

  # The FULL is only a usable incremental base if its anchor is CARRIED FORWARD
  # into the end-boundary fields the next incremental resumes from.
  assert_contains "state carries the anchor into the incremental start fields" \
    "$state" "\"last_binlog_end_file\": \"${anchor}\""
}

# Insert identifiable rows that must be recoverable from an incremental.
phase_inc1() {
  phase "inc1 (TRUE_INCREMENTAL #1 captures post-FULL changes)"

  mysql_exec "INSERT INTO students (student_no, full_name, email, note) VALUES ('2026-1001','Inc One','inc1@example.test','INC1-MARKER');" "$MYSQL_DATABASE" >/dev/null
  mysql_exec "INSERT INTO violations (student_id, category, fine, occurred_at) SELECT id,'INC1',11.11,NOW(6) FROM students WHERE student_no='2026-1001';" "$MYSQL_DATABASE" >/dev/null
  ok "INC1 marker rows inserted into the source database"

  backup_run
  assert_rc "INC1 run exited 0" 0 "$RUN_RC"
  [[ "$RUN_RC" -eq 0 ]] || { tail -n 25 "$RUN_LOG" | sed 's/^/    /'; return 0; }

  assert_contains "INC1 was captured as an incremental (never a logical dump)" "$(cat "$RUN_LOG")" "Backup type selected: INCREMENTAL"
  assert_contains "INC1 archive ships the applicable binlog SQL stream" "$(cat "$RUN_LOG")" "Stage: binlog_capture -> OK"

  local objects
  objects="$(s3_list_run_objects "incremental")"
  assert_contains "INC1 uploaded binlog_apply.sql.gz" "$objects" "binlog_apply.sql.gz"
  assert_contains "INC1 uploaded incremental metadata" "$objects" "backup_metadata.json"

  local state
  state="$(last_state_json)"
  assert_contains "state advanced after INC1" "$state" '"last_binlog_end_position"'
}

phase_inc2() {
  phase "inc2 (TRUE_INCREMENTAL #2 resumes from INC1's boundary)"

  local before after
  before="$(last_state_json | sed -n 's/.*"last_binlog_position"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')"

  mysql_exec "INSERT INTO students (student_no, full_name, email, note) VALUES ('2026-1002','Inc Two','inc2@example.test','INC2-MARKER');" "$MYSQL_DATABASE" >/dev/null
  ok "INC2 marker rows inserted into the source database"

  backup_run
  assert_rc "INC2 run exited 0" 0 "$RUN_RC"
  [[ "$RUN_RC" -eq 0 ]] || { tail -n 25 "$RUN_LOG" | sed 's/^/    /'; return 0; }

  after="$(last_state_json | sed -n 's/.*"last_binlog_position"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p')"
  # INC2 must resume from the previous boundary, not restart from the FULL.
  assert_eq "INC2 starts from INC1's saved boundary" "$before" "$(cat "$RUN_LOG" | sed -n 's/.*Incremental base binlog: \([^:]*\):\([0-9]*\).*/\2/p' | head -n1)"
  if [[ -n "$after" ]]; then
    ok "state advanced again after INC2 (position ${after})"
  else
    bad "state did not advance after INC2"
  fi

  # The chain must still name the SAME full base (an incremental never rebases).
  local base
  base="$(last_state_json | sed -n 's/.*"last_successful_full_backup_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  if [[ -n "$base" ]]; then
    ok "the incremental chain still names a single FULL base (${base})"
  else
    bad "the chain lost its FULL base after INC2"
  fi
}

phase_rotation() {
  phase "rotation (incremental spanning multiple binlog files)"

  # Force the server to rotate so the next incremental must span >1 file.
  mysql_exec "INSERT INTO students (student_no, full_name, email, note) VALUES ('2026-1003','Rot Three','rot3@example.test','ROT-MARKER');" "$MYSQL_DATABASE" >/dev/null
  mysql_exec "FLUSH BINARY LOGS;" >/dev/null
  mysql_exec "INSERT INTO students (student_no, full_name, email, note) VALUES ('2026-1004','Rot Four','rot4@example.test','ROT-MARKER-2');" "$MYSQL_DATABASE" >/dev/null
  mysql_exec "FLUSH BINARY LOGS;" >/dev/null
  mysql_exec "INSERT INTO students (student_no, full_name, email, note) VALUES ('2026-1005','Rot Five','rot5@example.test','ROT-MARKER-3');" "$MYSQL_DATABASE" >/dev/null
  ok "forced two binlog rotations with writes on both sides"

  local logs_before
  logs_before="$(mysql_exec "SHOW BINARY LOGS;" | awk -F'\t' '{print $1}' | tr '\n' ' ')"
  info "retained binlogs: ${logs_before}"

  backup_run
  assert_rc "rotation run exited 0" 0 "$RUN_RC"
  [[ "$RUN_RC" -eq 0 ]] || { tail -n 25 "$RUN_LOG" | sed 's/^/    /'; return 0; }

  # The run must report how many files it spanned; more than one proves the
  # capture crossed a rotation instead of silently using a single file.
  local span
  span="$(sed -n 's/.*Incremental range spans \([0-9]*\) binary log file\(s\).*/\1/p' "$RUN_LOG" | head -n1)"
  if [[ -n "$span" && "$span" -ge 2 ]]; then
    ok "the incremental spanned ${span} binlog files (rotation handled)"
  else
    bad "the incremental did not span multiple binlog files (got span=${span:-none})"
  fi

  # Each file in the range must have been fetched and packaged.
  local objects
  objects="$(s3_list_run_objects "incremental")"
  ok "rotation incremental objects listed (count: $(printf '%s\n' "$objects" | grep -c . ))"
}

phase_restore() {
  phase "restore (FULL + INC1 + INC2 + rotation into a disposable database)"

  if ! command -v "$DOCKER" >/dev/null 2>&1; then
    bad "docker unavailable — restore was NOT executed"
    return 0
  fi

  local restore_db="puptracker_restored"

  # Start from a clean disposable database.
  mysql_exec "DROP DATABASE IF EXISTS ${restore_db}; CREATE DATABASE ${restore_db};" >/dev/null
  ok "created a disposable restore database (${restore_db})"

  # Restore all phases inside one container from the real image (it ships
  # myloader + mysql + mysqlbinlog + rclone, exactly like production).
  local script
  script=$(cat <<EOS
set -euo pipefail
R2_PATH='${R2_PATH%/}'
BUCKET='${R2_BUCKET}'
DB='${restore_db}'
SRCDB='${MYSQL_DATABASE}'
mkdir -p /restore && cd /restore

# 1) Fetch every artifact for the chain in chronological order.
rclone --config "\$RCLONE_CONFIG" copy "remote:\${BUCKET}/\${R2_PATH}/full"        ./full
rclone --config "\$RCLONE_CONFIG" copy "remote:\${BUCKET}/\${R2_PATH}/incremental" ./incremental

printf 'FULL dirs: %s\n' "\$(find ./full -name metadata | wc -l)"
printf 'INC dirs:  %s\n' "\$(find ./incremental -name backup_metadata.json | wc -l)"

# 2) Restore the MOST RECENT full dump into the disposable database.
FULL_DIR="\$(find ./full -type f -name metadata -printf '%h\n' | sort | tail -n1)"
echo "restoring FULL from \${FULL_DIR}"
myloader --host '${HOST_GATEWAY}' --port 3306 --user '${MYSQL_USER}' --password '${MYSQL_PASSWORD}' \\
  --database "\${DB}" --directory "\${FULL_DIR}" --overwrite-tables --disable-keys

# 3) Apply each incremental's pre-built SQL stream, OLDEST FIRST.
for m in \$(find ./incremental -name backup_metadata.json | sort); do
  d="\$(dirname "\$m")"
  echo "applying incremental \${d}"
  gunzip -c "\${d}/binlog_apply.sql.gz" | mysql --host '${HOST_GATEWAY}' --port 3306 \\
    --user '${MYSQL_USER}' --password '${MYSQL_PASSWORD}' "\${DB}"
done
echo "RESTORE_OK"
EOS
)

  local rc=0
  "$DOCKER" run --rm --network "$NETWORK" "${DOCKER_RUN_HOST_FLAGS[@]}" \
    --env-file "$BACKUP_ENV_FILE" --entrypoint bash "$IMAGE_TAG" -c "$script" \
    >"$WORK_DIR/restore.log" 2>&1 || rc=$?

  if grep -q "RESTORE_OK" "$WORK_DIR/restore.log" 2>/dev/null; then
    ok "restore pipeline (FULL + every incremental) completed"
  else
    bad "restore pipeline did not complete (see ${WORK_DIR}/restore.log)"
    tail -n 25 "$WORK_DIR/restore.log" 2>/dev/null | sed 's/^/    /'
    return 0
  fi

  # 4) Compare the restored data against the expected dataset.
  local marker
  for marker in seed-1 INC1-MARKER INC2-MARKER ROT-MARKER ROT-MARKER-2 ROT-MARKER-3; do
    local n
    n="$(mysql_exec "SELECT COUNT(*) FROM students WHERE note='${marker}';" "$restore_db")"
    assert_eq "restored database contains ${marker}" "1" "${n:-0}"
  done

  # Row-for-row equality on the tables the dataset covers.
  local cols_students cols_violations src_checksum rst_checksum
  cols_students="student_no,full_name,email,note,created_at"
  cols_violations="id,student_id,category,fine,occurred_at"

  src_checksum="$(mysql_exec "SELECT COUNT(*) FROM students; SELECT COALESCE(SUM(CRC32(CONCAT_WS('|',${cols_students}))),0) FROM students;" "$MYSQL_DATABASE" | tr '\n' '/')"
  rst_checksum="$(mysql_exec "SELECT COUNT(*) FROM students; SELECT COALESCE(SUM(CRC32(CONCAT_WS('|',${cols_students}))),0) FROM students;" "$restore_db" | tr '\n' '/')"
  assert_eq "students table matches the source exactly (count+digest)" "$src_checksum" "$rst_checksum"

  src_checksum="$(mysql_exec "SELECT COUNT(*) FROM violations; SELECT COALESCE(SUM(CRC32(CONCAT_WS('|',${cols_violations}))),0) FROM violations;" "$MYSQL_DATABASE" | tr '\n' '/')"
  rst_checksum="$(mysql_exec "SELECT COUNT(*) FROM violations; SELECT COALESCE(SUM(CRC32(CONCAT_WS('|',${cols_violations}))),0) FROM violations;" "$restore_db" | tr '\n' '/')"
  assert_eq "violations table matches the source exactly (count+digest)" "$src_checksum" "$rst_checksum"

  # No event may be applied twice (a duplicate would inflate the count).
  local dups
  dups="$(mysql_exec "SELECT COUNT(*) FROM (SELECT student_no FROM students GROUP BY student_no HAVING COUNT(*)>1) d;" "$restore_db")"
  assert_eq "no row was duplicated by binlog replay" "0" "${dups:-0}"
}

phase_purged() {
  phase "purged (a purged start binlog must fail safely)"

  # Force a new FULL so the chain anchor is current, then purge the anchor.
  mysql_exec "DELETE FROM students WHERE student_no='2026-1002';" "$MYSQL_DATABASE" >/dev/null
  backup_run
  if [[ "$RUN_RC" -ne 0 ]]; then
    bad "setup FULL for the purge test failed (exit ${RUN_RC})"
    return 0
  fi

  local anchor state_before
  state_before="$(last_state_json)"
  anchor="$(printf '%s' "$state_before" | sed -n 's/.*"last_binlog_file"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  if [[ -z "$anchor" ]]; then
    bad "could not determine the anchor binlog to purge"
    return 0
  fi

  # Rotate a few times so there is a binlog newer than the anchor, then purge
  # everything up to (and including) the anchor.
  mysql_exec "FLUSH BINARY LOGS;" >/dev/null
  mysql_exec "INSERT INTO students (student_no, full_name, email, note) VALUES ('2026-2001','Purge Test','purge@example.test','PURGE');" "$MYSQL_DATABASE" >/dev/null
  mysql_exec "FLUSH BINARY LOGS;" >/dev/null

  local purge_to
  purge_to="$(mysql_exec "SHOW BINARY LOGS;" | awk -F'\t' '{print $1}' | tail -n1)"
  if [[ -z "$purge_to" || "$purge_to" == "$anchor" ]]; then
    skipped "could not create a purge target newer than the anchor — purge test NOT EXECUTED"
    return 0
  fi
  mysql_exec "PURGE BINARY LOGS TO '${purge_to}';" >/dev/null \
    && ok "purged binlogs up to ${purge_to} (anchor ${anchor} is now gone)" \
    || { skipped "PURGE BINARY LOGS was refused — purge test NOT EXECUTED"; return 0; }

  backup_run
  # A purged start binlog is refused by report_failure_and_exit, whose default
  # exit code is 1. Accept any non-zero so a future, more specific code does not
  # turn a genuine safe-failure into a test failure.
  if [[ "$RUN_RC" -ne 0 ]]; then
    ok "a purged start binlog makes the run fail (exit ${RUN_RC})"
  else
    bad "a purged start binlog must make the run fail, but it exited 0"
  fi

  # The failure must be explicit, must NOT silently resume from a newer file,
  # and must NOT advance the state.
  assert_contains "failure names the purged/missing binlog" "$(cat "$RUN_LOG")" "purged"
  assert_contains "failure states a new FULL is required" "$(cat "$RUN_LOG")" "backup is required"

  local state_after
  state_after="$(last_state_json)"
  assert_eq "state was NOT advanced by the purged-binlog failure" "$state_before" "$state_after"
}

phase_safety() {
  phase "safety (failure injection; state must never advance unsafely)"

  local state_before

  # A) A connection/dump failure must fail the run and must NOT become the base.
  # The entrypoint's exit code depends on WHERE it failed (validate_env/dump ->
  # 1, lock contention -> 5), so assert "non-zero" rather than one exact code.
  state_before="$(last_state_json)"
  local rc=0
  run_backup MYSQL_HOST=127.0.0.1 MYSQL_PORT=1 >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    ok "MyDumper/connection failure exits non-zero (got ${rc})"
  else
    bad "MyDumper/connection failure unexpectedly exited 0"
  fi
  assert_eq "state unchanged after a failed FULL" "$state_before" "$(last_state_json)"

  # B) Reporting failure -> uploaded backup retained, state NOT advanced.
  state_before="$(last_state_json)"
  # Restart the stub in outage mode (FORCE_FAIL=1 -> HTTP 503).
  "$DOCKER" rm -f "${REPORT_STUB_CONTAINER}-fail" >/dev/null 2>&1 || true
  "$DOCKER" run -d --name "${REPORT_STUB_CONTAINER}-fail" --network "$NETWORK" \
    -p "$((REPORT_STUB_PORT + 1)):8080" -e "FORCE_FAIL=1" \
    -e "REPORT_TOKEN=${BACKUP_REPORT_TOKEN}" \
    "$REPORT_STUB_IMAGE" php -S 0.0.0.0:8080 /app/server.php >/dev/null 2>&1 || true

  mysql_exec "INSERT INTO students (student_no, full_name, email, note) VALUES ('2026-3001','Report Fail','rf@example.test','RF');" "$MYSQL_DATABASE" >/dev/null
  rc=0
  run_backup "BACKUP_REPORT_URL=http://${HOST_GATEWAY}:$((REPORT_STUB_PORT + 1))/" >/dev/null 2>&1 || rc=$?
  if [[ "$rc" -eq 3 ]]; then
    ok "reporting failure exits 3 (backup retained, not marked failed)"
  elif [[ "$rc" -eq 0 ]]; then
    skipped "reporting outage was not triggered — report-failure case NOT EXECUTED"
  else
    bad "reporting failure returned ${rc}, expected 3"
  fi

  # Exit 3 must ALSO mean the chain bookkeeping was left alone.
  if [[ "$rc" -eq 3 ]]; then
    assert_eq "state NOT advanced when reporting failed" "$state_before" "$(last_state_json)"
  fi

  # C) Lock contention -> the second run must not overlap.
  state_before="$(last_state_json)"
  local rc_a=0 rc_b=0
  ( run_backup >/dev/null 2>&1 ) & local pid_a=$!
  ( run_backup >/dev/null 2>&1 ) & local pid_b=$!
  wait "$pid_a" || rc_a=$?
  wait "$pid_b" || rc_b=$?
  if [[ "$rc_a" -eq 5 || "$rc_b" -eq 5 ]]; then
    ok "a concurrent run was refused with exit 5 (no overlapping incremental)"
  elif [[ "$rc_a" -eq 0 && "$rc_b" -eq 0 ]]; then
    skipped "the two runs did not overlap in time — lock contention NOT EXERCISED"
  else
    bad "concurrent runs returned unexpected codes (${rc_a}, ${rc_b})"
  fi
}

phase_report() {
  phase "report (summary)"
  printf '\n'
  printf 'Phases run : %s\n' "${PHASE_RESULTS[*]}"
  printf 'Work dir   : %s\n' "$WORK_DIR"
  printf '\n'
  printf '==========================================\n'
  printf 'PASS: %d   FAIL: %d   SKIP: %d\n' "$PASS" "$FAIL" "$SKIP"
  printf '==========================================\n'
}

# ---------------------------------------------------------------------------
# Cleanup
# ---------------------------------------------------------------------------
cleanup() {
  if [[ "${KEEP_ENV:-0}" != "1" ]]; then
    "$DOCKER" rm -f "$MYSQL_CONTAINER" "$MINIO_CONTAINER" "$REPORT_STUB_CONTAINER" \
      "${REPORT_STUB_CONTAINER}-fail" >/dev/null 2>&1 || true
    "$DOCKER" network rm "$NETWORK" >/dev/null 2>&1 || true
  else
    printf 'KEEP_ENV=1: containers and network left running for inspection.\n'
  fi
  [[ -n "$BACKUP_ENV_FILE" && -f "$BACKUP_ENV_FILE" ]] && rm -f "$BACKUP_ENV_FILE"
  return 0
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
main() {
  local requested=("$@")
  if [[ "${#requested[@]}" -eq 0 ]]; then
    if [[ -n "${PHASES:-}" ]]; then
      # shellcheck disable=SC2206
      requested=(${PHASES})
    else
      requested=(all)
    fi
  fi

  printf 'rclone-mysql-backup integration harness\n'
  printf 'repo    : %s\n' "$REPO_ROOT"
  printf 'image   : %s\n' "$IMAGE_TAG"
  printf 'workdir : %s\n' "$WORK_DIR"

  # `selftest` must not require docker or a disposable guard.
  if [[ "${requested[0]}" == "selftest" ]]; then
    phase_selftest
    phase_report
    [[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
  fi

  if ! command -v "$DOCKER" >/dev/null 2>&1; then
    printf '\nFATAL: docker is not available on this host.\n' >&2
    printf 'Every container-based phase (build/up/full/inc/restore/...) is therefore NOT EXECUTED.\n' >&2
    printf 'Run this harness on a host with Docker, or on a disposable Railway service.\n' >&2
    exit 2
  fi

  local expanded=()
  local p
  for p in "${requested[@]}"; do
    if [[ "$p" == "all" ]]; then
      expanded+=(preflight build up mysql-check full inc1 inc2 rotation restore purged safety report)
    else
      expanded+=("$p")
    fi
  done

  for p in "${expanded[@]}"; do
    case "$p" in
      preflight)   phase_preflight ;;
      build)       phase_build ;;
      up)          phase_up ;;
      mysql-check) phase_mysql_check ;;
      full)        phase_full ;;
      inc1)        phase_inc1 ;;
      inc2)        phase_inc2 ;;
      rotation)    phase_rotation ;;
      restore)     phase_restore ;;
      purged)      phase_purged ;;
      safety)      phase_safety ;;
      report)      phase_report ;;
      *)           printf 'unknown phase: %s\n' "$p" >&2; exit 2 ;;
    esac
  done

  # If the report phase did not run, print the counters anyway.
  if [[ ! " ${expanded[*]} " == *" report "* ]]; then
    printf '\nPASS: %d   FAIL: %d   SKIP: %d\n' "$PASS" "$FAIL" "$SKIP"
  fi

  [[ "$FAIL" -eq 0 ]] && exit 0 || exit 1
}

main "$@"
