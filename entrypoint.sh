#!/usr/bin/env bash

# rclone-mysql-backup entrypoint
#
# Runs a logical MySQL snapshot with mydumper, uploads it to Cloudflare R2 with
# rclone, then reports the outcome to the PUPTracker Backup History webhook.
#
# Report contract (PUPTracker):
#   POST $BACKUP_REPORT_URL
#   Authorization: Bearer $BACKUP_REPORT_TOKEN
#   Content-Type: application/json
#
# The PUPTracker endpoint is CSRF-exempt for this machine-to-machine webhook
# and is authenticated by BACKUP_REPORT_TOKEN. Reporting is idempotent by
# backup_name, so a later retry with the same name is safe.

set -euo pipefail

# ---------------------------------------------------------------------------
# Runtime diagnostics (non-secret)
# ---------------------------------------------------------------------------
# CURRENT_STAGE is updated before every major operation and reported by the
# EXIT/ERR traps so a runtime failure is immediately locatable in the logs.
CURRENT_STAGE="startup"

set_stage() {
  CURRENT_STAGE="$1"
}

# Report the current stage + the shell's exit status on exit. Never prints
# secrets (it only reports the numeric status and the stage label).
report_exit() {
  local status=$?
  if [[ -n "${CURRENT_STAGE:-}" ]]; then
    echo "[backup] EXIT: stage=${CURRENT_STAGE}, status=${status}" >&2
  else
    echo "[backup] EXIT: status=${status}" >&2
  fi
}

# Report a runtime error with stage + line + exit status + safe command
# context. The command text is truncated and never includes secrets (the
# BASH_COMMAND of a failing credential-bearing invocation is not echoed; we
# only report the numeric status and the stage/line).
report_err() {
  local status=$?
  echo "[backup][error] stage=${CURRENT_STAGE:-?}, line=${BASH_LINENO[0]:-?}, status=${status}" >&2
}

# Only install the traps when the script is run directly (not when sourced by
# tests). Sourcing must not hijack the sourcing shell's EXIT/ERR traps.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  trap report_exit EXIT
  trap report_err ERR
fi

# ---------------------------------------------------------------------------
# Configuration / environment
# ---------------------------------------------------------------------------
# Values are read here as plain assignments (no hard failure at load time) so
# the file can also be sourced for function-level testing. Actual required-ness
# is validated in validate_env() at the start of the run.
MYSQL_HOST="${MYSQL_HOST:-}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-}"
MYSQL_DATABASE="${MYSQL_DATABASE:-}"

R2_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID:-}"
R2_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY:-}"
R2_ENDPOINT="${R2_ENDPOINT:-}"
R2_BUCKET="${R2_BUCKET:-}"
R2_PATH="${R2_PATH:-mysql-backup}"

# PUPTracker reporting (REQUIRED). The job fails fast (non-zero, no backup) in
# validate_env() if either variable is missing — we never run a backup that
# cannot be reported.
BACKUP_REPORT_URL="${BACKUP_REPORT_URL:-}"
# BACKUP_REPORT_TOKEN is intentionally NOT defaulted. It is only read from the
# environment and must never be printed or embedded anywhere.
BACKUP_REPORT_TOKEN="${BACKUP_REPORT_TOKEN:-}"

# Seconds to wait for the HTTP report call (kept short; no aggressive retries).
REPORT_TIMEOUT="${REPORT_TIMEOUT:-20}"

# Where mydumper writes locally.
BACKUP_DIR="backup"

# ---------------------------------------------------------------------------
# rclone config location
# ---------------------------------------------------------------------------
# We deliberately use an EXPLICIT config path (never relying on ~ / $HOME /
# rclone's own home resolution, which can differ in minimal containers).
# HOME may be unset or resolve differently inside the container, so default to
# /root when unset and always mkdir -p the directory before writing.
set_stage "load_config"
if [[ -z "${HOME:-}" ]]; then
  export HOME="/root"
fi
RCLONE_CONFIG="${RCLONE_CONFIG:-${HOME}/.config/rclone/rclone.conf}"
export RCLONE_CONFIG
# Tell rclone to always use our explicit file (belt-and-braces; RCLONE_CONFIG
# env var is also honoured by rclone).
RCLONE_CONFIG_DIR="$(dirname "$RCLONE_CONFIG")"
export RCLONE_CONFIG_DIR
set_stage "loaded_config"

# ---------------------------------------------------------------------------
# State for reporting (set as the run progresses)
# ---------------------------------------------------------------------------
BACKUP_NAME=""
BACKUP_TYPE="daily_snapshot"
DESTINATION="Cloudflare R2"
STARTED_AT=""
COMPLETED_AT=""
BACKUP_SIZE=0
FILE_COUNT=0
CHECKSUM=""
CHECKSUM_ALGORITHM="SHA-256"
VERIFIED_AT=""
STORAGE_PATH=""
ERROR_MESSAGE=""

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() {
  echo "[backup] $*"
}

warn() {
  echo "[backup][warn] $*" >&2
}

# Validate that all required configuration is present. Exits non-zero (without
# attempting a backup) when a required variable is missing.
validate_env() {
  local missing=0

  for var in MYSQL_HOST MYSQL_USER MYSQL_PASSWORD MYSQL_DATABASE \
             R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ENDPOINT R2_BUCKET \
             BACKUP_REPORT_URL BACKUP_REPORT_TOKEN; do
    if [[ -z "${!var:-}" ]]; then
      warn "Required environment variable ${var} is not set."
      missing=1
    fi
  done

  if [[ "$missing" -ne 0 ]]; then
    warn "Refusing to run: required configuration is missing. The job will not run a backup without PUPTracker reporting configured."
    exit 1
  fi
}

# Verify every external command this script relies on is actually present in
# the image. Fail fast (before touching MySQL/R2) with a clear, non-secret
# message naming the missing command.
check_tools() {
  local missing=0
  local tool

  for tool in mydumper rclone curl date find sha256sum sed awk grep sort \
               wc head mktemp tr; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      warn "Required command not found in image: ${tool}"
      missing=1
    fi
  done

  if [[ "$missing" -ne 0 ]]; then
    warn "Refusing to run: required command(s) are missing from the container image."
    exit 1
  fi
}

# An ISO-8601-ish UTC timestamp (second precision). GNU date is assumed.
now_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# Escape a string for safe inclusion inside a double-quoted JSON string value.
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  # Strip control characters (other than the ones escaped above).
  s="$(printf '%s' "$s" | tr -d '\000-\010\013\014\016-\037')"
  printf '%s' "$s"
}

# Log a "safe" failure: never include credentials/tokens/passwords.
safe_log_error() {
  local raw="$1"
  warn "$raw"
}

# Send the current report state to PUPTracker. Returns 0 on an accepted
# (2xx) response, non-zero otherwise. Never prints the token or headers.
#
#   report_now <status>   e.g. report_now success | report_now failed
#
report_now() {
  local status="$1"
  local http_code
  local payload
  local resp_file
  resp_file="$(mktemp)"

  if [[ -z "$BACKUP_REPORT_URL" ]]; then
    warn "BACKUP_REPORT_URL is not set; skipping PUPTracker report."
    rm -f "$resp_file"
    return 2
  fi

  if [[ -z "$BACKUP_REPORT_TOKEN" ]]; then
    warn "BACKUP_REPORT_TOKEN is not set; skipping PUPTracker report."
    rm -f "$resp_file"
    return 2
  fi

  payload="$(build_payload "$status")"

  # Do NOT log $BACKUP_REPORT_TOKEN or the Authorization header.
  http_code="$(
    curl -sS -o "$resp_file" -w "%{http_code}" \
      --max-time "$REPORT_TIMEOUT" \
      -X POST "$BACKUP_REPORT_URL" \
      -H "Authorization: Bearer ${BACKUP_REPORT_TOKEN}" \
      -H "Content-Type: application/json" \
      --data-binary "$payload" || true
  )"

  if [[ "$http_code" =~ ^[0-9]+$ ]] && [[ "$http_code" -ge 200 ]] && [[ "$http_code" -lt 300 ]]; then
    log "PUPTracker report accepted (HTTP ${http_code}) for ${BACKUP_NAME}."
    rm -f "$resp_file"
    return 0
  fi

  # 401/403 means the token is wrong/missing; surface a generic hint only.
  if [[ "$http_code" == "401" || "$http_code" == "403" ]]; then
    warn "PUPTracker report rejected (HTTP ${http_code}) - check BACKUP_REPORT_TOKEN."
  else
    warn "PUPTracker report failed (HTTP ${http_code:-timeout/no-response}) for ${BACKUP_NAME}."
  fi

  rm -f "$resp_file"
  return 1
}

# Build the JSON payload for the current state.
build_payload() {
  local status="$1"
  local json

  json="{"
  json+="\"status\":\"$(json_escape "$status")\","
  json+="\"backup_name\":\"$(json_escape "$BACKUP_NAME")\","
  json+="\"backup_type\":\"$(json_escape "$BACKUP_TYPE")\","
  json+="\"started_at\":\"$(json_escape "$STARTED_AT")\","
  json+="\"completed_at\":\"$(json_escape "$COMPLETED_AT")\","
  json+="\"destination\":\"$(json_escape "$DESTINATION")\""

  if [[ "$status" == "failed" ]]; then
    if [[ -n "$ERROR_MESSAGE" ]]; then
      json+=",\"error_message\":\"$(json_escape "$ERROR_MESSAGE")\""
    fi
  else
    json+=",\"backup_size\":${BACKUP_SIZE:-0}"
    json+=",\"file_count\":${FILE_COUNT:-0}"
    json+=",\"checksum\":\"$(json_escape "$CHECKSUM")\""
    json+=",\"checksum_algorithm\":\"$(json_escape "$CHECKSUM_ALGORITHM")\""
    if [[ -n "$VERIFIED_AT" ]]; then
      json+=",\"verified_at\":\"$(json_escape "$VERIFIED_AT")\""
    fi
    if [[ -n "$STORAGE_PATH" ]]; then
      json+=",\"storage_path\":\"$(json_escape "$STORAGE_PATH")\""
    fi
  fi

  json+="}"
  printf '%s' "$json"
}

# ---------------------------------------------------------------------------
# Metadata helpers
# ---------------------------------------------------------------------------

# Count files (not directories) under the backup dir.
count_files() {
  find "$BACKUP_DIR" -type f 2>/dev/null | wc -l
}

# Total size in bytes of all files under the backup dir.
total_size() {
  find "$BACKUP_DIR" -type f -printf "%s\n" 2>/dev/null | awk '{ s += $1 } END { print s+0 }'
}

# Deterministic aggregate SHA-256 over a sorted manifest of every backup file.
#
#   MANIFEST LINE FORMAT:  <sha256 of file>  <relative path>
#
# The manifest is sorted by relative path so the result is reproducible.
compute_manifest_checksum() {
  local manifest
  local aggregate
  manifest="$(mktemp)"

  # Build the manifest: hash + two-space separator + relative path.
  (
    cd "$BACKUP_DIR"
    find . -type f -print0 2>/dev/null | sort -z \
      | while IFS= read -r -d '' f; do
          rel="${f#./}"
          printf '%s  %s\n' "$(sha256sum "$f" | awk '{print $1}')" "$rel"
        done
  ) > "$manifest"

  aggregate="$(sha256sum "$manifest" | awk '{print $1}')"
  rm -f "$manifest"
  printf '%s' "$aggregate"
}

# Verify that the R2 upload is present and complete by comparing the LOCAL
# object count and TOTAL BYTES against what rclone reports at the destination.
#
# Scope / honesty:
#   - rclone's `lsf -l` returns remote file sizes for the S3/R2 backend but
#     does NOT expose a cryptographically trustworthy remote hash of every
#     object without an extra HEAD/GET round trip (R2 does not surface the same
#     ETag guarantees as other S3 providers for multipart uploads).
#   - This check therefore verifies OBJECT PRESENCE + COUNT + TOTAL SIZE
#     (i.e. nothing is missing or truncated), NOT full cryptographic
#     verification of the remote copy.
#   - The authoritative integrity digest remains the LOCAL manifest SHA-256
#     (reported to PUPTracker as `checksum`). It is NOT claimed here to have
#     been independently re-derived from the remote bytes.
#
# Returns 0 when the remote count and total size both match the local values.
verify_upload() {
  local local_count
  local remote_count
  local local_bytes
  local remote_bytes
  local listing

  local_count="$(count_files)"
  local_bytes="$(total_size)"

  # lsf -l prints "<size> <path>" lines. Capture the raw listing once. The
  # --config flag guarantees rclone reads OUR config regardless of HOME.
  listing="$(rclone --config "$RCLONE_CONFIG" lsf --recursive -l "remote:${R2_BUCKET}/${STORAGE_PATH}" 2>/dev/null || true)"

  remote_count="$(printf '%s\n' "$listing" | sed '/^[[:space:]]*$/d' | wc -l)"
  remote_bytes="$(printf '%s\n' "$listing" | awk '{ s += $1 } END { print s+0 }')"

  if [[ -z "$remote_bytes" || -z "$remote_count" ]]; then
    warn "R2 presence/size verification could not read the remote listing at remote:${R2_BUCKET}/${STORAGE_PATH}."
    return 1
  fi

  if [[ "$local_count" -ne "$remote_count" ]]; then
    warn "R2 presence/size verification failed: expected ${local_count} file(s), found ${remote_count} at remote:${R2_BUCKET}/${STORAGE_PATH}."
    return 1
  fi

  if [[ "$local_bytes" -ne "$remote_bytes" ]]; then
    warn "R2 presence/size verification failed: expected ${local_bytes} bytes, found ${remote_bytes} at remote:${R2_BUCKET}/${STORAGE_PATH}."
    return 1
  fi

  log "R2 presence/size verification passed: ${remote_count} file(s), ${remote_bytes} bytes at remote:${R2_BUCKET}/${STORAGE_PATH}."
  return 0
}

# ---------------------------------------------------------------------------
# Reporting on failure
# ---------------------------------------------------------------------------
# Attempt to send a failure report when a stage fails. We deliberately do NOT
# use `trap ... EXIT` for the success path because success reporting must only
# happen after verification and must be explicit.
report_failure_and_exit() {
  local message="$1"
  local code="${2:-1}"

  COMPLETED_AT="$(now_utc)"
  ERROR_MESSAGE="$(printf '%s' "$message" | head -c 1900)"

  safe_log_error "$message"
  log "Attempting to report backup failure to PUPTracker..."

  report_now "failed" || warn "Could not deliver failure report to PUPTracker (backup already failed)."

  exit "$code"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  # BACKUP_REPORT_URL and BACKUP_REPORT_TOKEN are REQUIRED. validate_env() has
  # already exited non-zero if either is missing, so reporting is always enabled
  # by the time we reach this point.
  set_stage "validate_env"
  log "Stage: validate_env"
  validate_env
  log "Stage: validate_env -> OK"

  set_stage "check_tools"
  log "Stage: check_tools"
  check_tools
  log "Stage: check_tools -> OK"

  REPORTING_ENABLED=1

  set_stage "init"
  STARTED_AT="$(now_utc)"
  BACKUP_NAME="daily_snapshot_$(date -u +"%Y-%m-%d_%H%M%S")"

  # Unique destination: <R2_PATH>/daily_snapshot/YYYY/MM/DD/<backup_name>/
  DATE_PATH="$(date -u +"%Y/%m/%d")"
  STORAGE_PATH="${R2_PATH%/}/daily_snapshot/${DATE_PATH}/${BACKUP_NAME}"

  log "Starting ${BACKUP_TYPE} backup: ${BACKUP_NAME}"
  log "R2 destination: ${R2_BUCKET}/${STORAGE_PATH}"

  # 1) Logical dump with mydumper into a fresh local directory.
  set_stage "mydumper"
  log "Stage: mydumper (started)"
  rm -rf "$BACKUP_DIR"
  if ! mydumper \
    --host "$MYSQL_HOST" \
    --user "$MYSQL_USER" \
    --password "$MYSQL_PASSWORD" \
    --port "$MYSQL_PORT" \
    --database "$MYSQL_DATABASE" \
    -C -c --clear -o "$BACKUP_DIR"; then
    report_failure_and_exit "mydumper failed to produce a logical database snapshot."
  fi
  log "Stage: mydumper -> OK"

  set_stage "metadata"
  log "Stage: metadata (started)"
  if [[ ! -d "$BACKUP_DIR" ]]; then
    report_failure_and_exit "mydumper exited successfully but produced no backup directory."
  fi

  FILE_COUNT="$(count_files)"
  BACKUP_SIZE="$(total_size)"
  if [[ "$FILE_COUNT" -eq 0 ]]; then
    report_failure_and_exit "mydumper produced an empty backup directory (0 files)."
  fi

  CHECKSUM="$(compute_manifest_checksum)"
  VERIFIED_AT="$(now_utc)"

  log "Backup metadata calculated."
  log "Backup files: ${FILE_COUNT}, total bytes: ${BACKUP_SIZE}"
  log "Backup checksum (SHA-256): ${CHECKSUM}"
  log "Stage: metadata -> OK"

  # 3) Configure rclone (existing behavior preserved, hardened):
  #    - mkdir -p the config directory FIRST so the write can never fail.
  #    - write an explicit, deterministic config file.
  #    - validate it by listing remotes with --config before uploading.
  set_stage "rclone_config"
  log "Stage: rclone_config (started) -> ${RCLONE_CONFIG}"
  mkdir -p "$RCLONE_CONFIG_DIR"
  cat > "$RCLONE_CONFIG" <<EOF
[remote]
type = s3
provider = Cloudflare
access_key_id = $R2_ACCESS_KEY_ID
secret_access_key = $R2_SECRET_ACCESS_KEY
endpoint = $R2_ENDPOINT
acl = private
EOF
  log "Stage: rclone_config -> written"

  # Validate the config parses and exposes the [remote] before we attempt an
  # upload. Fail fast with a clear (non-secret) diagnostic if it does not.
  if ! rclone --config "$RCLONE_CONFIG" listremotes >/dev/null 2>&1; then
    report_failure_and_exit "rclone configuration could not be read/validated (config: ${RCLONE_CONFIG})."
  fi
  if ! rclone --config "$RCLONE_CONFIG" listremotes 2>/dev/null | grep -q '^remote:$'; then
    report_failure_and_exit "rclone configuration is missing the [remote] destination."
  fi
  log "Stage: rclone_config -> validated ([remote] present)"

  # 4) Upload to the unique destination.
  set_stage "rclone_upload"
  log "Stage: rclone_upload (started) -> remote:${R2_BUCKET}/${STORAGE_PATH}"
  if ! rclone --config "$RCLONE_CONFIG" sync "$BACKUP_DIR" "remote:${R2_BUCKET}/${STORAGE_PATH}"; then
    report_failure_and_exit "rclone upload to Cloudflare R2 failed."
  fi
  log "Stage: rclone_upload -> OK"

  # 5) Verify the upload (do not report success on local success alone).
  set_stage "rclone_verify"
  log "Stage: rclone_verify (started)"
  if ! verify_upload; then
    report_failure_and_exit "R2 upload verification failed."
  fi
  log "Stage: rclone_verify -> OK"

  COMPLETED_AT="$(now_utc)"

  log "Backup uploaded and verified successfully: ${BACKUP_NAME}"

  # 6) Report success.
  set_stage "report_success"
  log "Stage: report_success (started)"
  if ! report_now "success"; then
    # The backup itself succeeded and is safe in R2. Only the report failed.
    # Do NOT change the backup's status to failed. Log clearly and exit
    # non-zero so Railway surfaces the reporting problem. A later retry with the
    # same backup_name is safe (PUPTracker is idempotent by backup_name).
    warn "Backup succeeded but PUPTracker reporting failed."
    exit 3
  fi
  log "Stage: report_success -> OK"

  set_stage "done"
  log "Backup completed and reported to PUPTracker."
  exit 0
}

# Run main() only when executed directly (not when sourced for testing).
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
