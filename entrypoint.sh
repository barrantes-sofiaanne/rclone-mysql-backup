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

# Install the traps only when the script is actually being RUN (not when it is
# sourced for function-level testing). Sourcing must not hijack the sourcing
# shell's EXIT/ERR traps.
#
# NOTE: BASH_SOURCE[0] == $0 is NOT a sufficient test on its own. The common
# test idiom `bash -c 'source "$0" ...' /entrypoint.sh` ALSO makes them equal
# (because $0 is set to the file being sourced), which would make the guard at
# the bottom of this file invoke main() inside the test subprocess. Setting
# BACKUP_SOURCED=1 in the environment explicitly opts out of running main().
BACKUP_SOURCED="${BACKUP_SOURCED:-0}"
if [[ "${BASH_SOURCE[0]}" == "$0" && "$BACKUP_SOURCED" != "1" ]]; then
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
# S3 provider/ACL presented to rclone. The defaults target Cloudflare R2. They
# are overridable so the SAME image can be validated against an S3-compatible
# endpoint (e.g. MinIO in the integration harness) or pointed at another
# provider without patching the script. Set R2_ACL="" to omit the acl option
# entirely (some S3-compatible servers reject canned ACLs).
R2_PROVIDER="${R2_PROVIDER:-Cloudflare}"
R2_ACL="${R2_ACL-private}"

# PUPTracker reporting (REQUIRED). The job fails fast (non-zero, no backup) in
# validate_env() if either variable is missing — we never run a backup that
# cannot be reported.
BACKUP_REPORT_URL="${BACKUP_REPORT_URL:-}"
# BACKUP_REPORT_TOKEN is intentionally NOT defaulted. It is only read from the
# environment and must never be printed or embedded anywhere.
BACKUP_REPORT_TOKEN="${BACKUP_REPORT_TOKEN:-}"

# Seconds to wait for the HTTP report call (kept short; no aggressive retries).
REPORT_TIMEOUT="${REPORT_TIMEOUT:-20}"

# ---------------------------------------------------------------------------
# Exit codes (documented so operators/orchestrators can react correctly)
# ---------------------------------------------------------------------------
#   0 = the whole chain succeeded (backup + upload + verify + report + state)
#   1 = a general failure (configuration, tooling, dump, upload, verification,
#       STATE PERSISTENCE, ...)
#   3 = the backup succeeded but the PUPTracker success report failed
#   4 = PUPTracker returned 409: an integrity conflict with an existing,
#       differently-check-summed backup of the same name
#   5 = another backup run currently holds the distributed lock
EXIT_GENERAL_FAILURE=1
EXIT_REPORT_FAILED=3
EXIT_REPORT_CONFLICT=4
EXIT_LOCK_HELD=5

# ---------------------------------------------------------------------------
# Backup policy (full / incremental)
# ---------------------------------------------------------------------------
# A FULL logical backup is taken when the most recent SUCCESSFUL, VERIFIED full
# backup is >= BACKUP_FULL_INTERVAL_DAYS old (or when none exists). Every other
# run is a TRUE binary-log incremental. A full-backup day NEVER also runs an
# incremental (there is no code path that does both in one run).
BACKUP_FULL_INTERVAL_DAYS="${BACKUP_FULL_INTERVAL_DAYS:-14}"

# Binary-log (TRUE incremental) support. When BACKUP_BINLOG_ENABLED=false a FULL
# backup is still possible, but a run that REQUIRES an incremental will fail
# safely rather than fabricate one.
BACKUP_BINLOG_ENABLED="${BACKUP_BINLOG_ENABLED:-true}"
# When true, REQUIRE log_bin=ON (and a usable binlog_format) before any
# incremental. When false the probe is skipped and incrementals are refused.
BACKUP_BINLOG_VERIFY="${BACKUP_BINLOG_VERIFY:-true}"

# Optional display/log timezone. All timestamps remain stored in UTC.
BACKUP_TIMEZONE="${BACKUP_TIMEZONE:-UTC}"

# ---------------------------------------------------------------------------
# mysqlbinlog replication consumer identity
# ---------------------------------------------------------------------------
# mysqlbinlog --read-from-remote-server and --raw make this process act as a
# replication CLIENT, which REQUIRES a server_id that is unique among every
# other replication consumer/binlog reader on the server. Hard-coding 1 is
# dangerous: it can collide with a real replica, with Railway's own binlog
# archiving, or with a concurrent backup, and a duplicate server_id makes the
# server disconnect/terminate the older connection (silently truncating THIS
# backup's capture).
#
# Default 2147483000 sits near the top of the MySQL server_id range
# (1..4294967295) to minimise collision odds for a dedicated backup consumer.
# Override MYSQLBINLOG_SERVER_ID per deployment so every consumer is distinct.
MYSQLBINLOG_SERVER_ID="${MYSQLBINLOG_SERVER_ID:-2147483000}"

# ---------------------------------------------------------------------------
# Concurrency protection (distributed lock in object storage)
# ---------------------------------------------------------------------------
# The backup chain state lives in R2, so a container-local flock cannot prevent
# two SCHEDULED container runs from overlapping. We therefore take a distributed
# lock as an object in R2 next to the state object. It is created when absent
# (rclone copyto does not overwrite an existing object), carries an expiry
# timestamp, and is removed on exit. An expired lock is treated as stale and is
# taken over, so a crash can NEVER permanently block future backups.
BACKUP_LOCK_ENABLED="${BACKUP_LOCK_ENABLED:-true}"
BACKUP_LOCK_TTL_SECONDS="${BACKUP_LOCK_TTL_SECONDS:-21600}"  # 6h
# The object path MUST include the bucket. An rclone remote path is
# `remote:<bucket>/<key>`, so a path built from R2_PATH alone would place the
# lock in a DIFFERENT bucket than the backups it is supposed to protect. This is
# the same `<bucket>/<path>` composition the backup UPLOAD paths use (see
# upload_and_verify), so state, lock and backups always resolve to one bucket.
BACKUP_LOCK_REMOTE="${R2_BUCKET}/${R2_PATH%/}/state/backup.lock"
# Release the lock, but ONLY when we are still its owner (a stale take-over by
# another run must not have its lock deleted by us).
release_lock() {
  if [[ "${BACKUP_LOCK_HELD:-0}" != "1" ]]; then
    return 0
  fi
  local token
  token="$(lock_token)"
  if [[ -n "$token" && "$token" != "${BACKUP_LOCK_TOKEN:-}" ]]; then
    warn "Backup lock is now owned by another run; not releasing it."
    BACKUP_LOCK_HELD=0
    return 0
  fi
  rclone --config "${RCLONE_CONFIG:-}" deletefile "remote:${BACKUP_LOCK_REMOTE}" >/dev/null 2>&1 || true
  BACKUP_LOCK_HELD=0
  log "Released distributed backup lock."
  return 0
}

# Combined EXIT cleanup: always release the lock (so a crash never wedges the
# chain) and still report the stage/status the way report_exit() does.
# The exit status is captured FIRST so releasing the lock cannot mask it.
cleanup_on_exit() {
  # Capture the REAL status first. Everything below (lock release, logging) is
  # cleanup and must never be able to mask or replace it: release_lock() only
  # ever returns 0 today, but relying on that would make the job's exit status
  # depend on a cleanup helper's return value.
  local status=$?

  release_lock || true
  LOCK_RELEASE_RC=$?
  # NOTE: LOCK_RELEASE_RC is recorded but deliberately does NOT overwrite
  # LAST_STAGE_STATUS. Cleanup is not a backup stage, and letting it overwrite
  # the last recorded stage would make the exit diagnosis point at cleanup
  # instead of at the stage that actually failed.

  if [[ "$status" -ne 0 ]]; then
    log_exit_diagnosis "failed" "exit_status=${status}${ERROR_MESSAGE:+ error='${ERROR_MESSAGE}'}"
  else
    log "EXIT-DIAGNOSIS: final_status=success stage=${CURRENT_STAGE:-?} last_stage_status=${LAST_STAGE_STATUS:-none}"
    log "EXIT-DIAGNOSIS: backup_type=${BACKUP_TYPE:-n/a} backup_name=${BACKUP_NAME:-n/a}"
    log "EXIT-DIAGNOSIS: full_backup_rc=${FULL_BACKUP_RC} upload_rc=${UPLOAD_RC} verify_rc=${VERIFY_RC} report_rc=${REPORT_RC} state_update_rc=${STATE_UPDATE_RC} lock_release_rc=${LOCK_RELEASE_RC}"
    log "EXIT-DIAGNOSIS: binlog_anchor_usable=${BINLOG_ANCHOR_OK} anchor_file='${BINLOG_FILE_END:-<empty>}' anchor_position='${BINLOG_POSITION_END:-<empty>}'"
  fi

  # Explicitly re-assert the captured status so no cleanup step can change it.
  return "$status"
}

# Verify we still own the lock. Returns non-zero when it was taken over (or is
# unreadable), meaning this run must NOT advance state.
lock_still_owned() {
  if [[ "${BACKUP_LOCK_HELD:-0}" != "1" ]]; then
    return 0
  fi
  local token
  token="$(lock_token)"
  if [[ "$token" == "${BACKUP_LOCK_TOKEN:-}" ]]; then
    return 0
  fi
  warn "Backup lock ownership was lost (another run took over the expired lock)."
  return 1
}

# Load the state object from R2 into the ST_* variables. Sets STATE_PRESENT=1
# only when a syntactically usable object was retrieved. Never fails the run:
# an absent/corrupt state simply means "no known state" (=> force FULL).
load_state() {
  local state_file
  state_file="$(mktemp)"
  STATE_PRESENT=0

  # `rclone cat` streams the object to stdout; a missing object returns empty.
  local raw
  raw="$(rclone --config "${RCLONE_CONFIG:-}" cat "remote:${BACKUP_STATE_REMOTE}" 2>/dev/null || true)"
  ST_RAW_STATE="$raw"

  if [[ -z "$raw" ]]; then
    log "Backup state: none found at remote:${BACKUP_STATE_REMOTE} (first run or state absent)."
    rm -f "$state_file"
    return 0
  fi

  # Cheap structural check: must contain the full-backup key.
  if ! printf '%s' "$raw" | grep -q '"last_successful_full_backup_name"'; then
    warn "Backup state at remote:${BACKUP_STATE_REMOTE} is unreadable/foreign; ignoring it."
    rm -f "$state_file"
    return 0
  fi

  # Extract scalar string values. The sed pattern captures everything up to the
  # closing quote; values never contain quotes (they are backup names/paths).
  ST_LAST_FULL_NAME="$(printf '%s' "$raw" | sed -n 's/.*"last_successful_full_backup_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  ST_LAST_FULL_COMPLETED_AT="$(printf '%s' "$raw" | sed -n 's/.*"last_successful_full_completed_at"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  ST_LAST_FULL_STORAGE_PATH="$(printf '%s' "$raw" | sed -n 's/.*"last_successful_full_storage_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  ST_LAST_BINLOG_FILE="$(printf '%s' "$raw" | sed -n 's/.*"last_binlog_file"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  ST_LAST_BINLOG_END_FILE="$(printf '%s' "$raw" | sed -n 's/.*"last_binlog_end_file"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  # Positions are plain integers.
  ST_LAST_BINLOG_POSITION="$(printf '%s' "$raw" | sed -n 's/.*"last_binlog_position"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')"
  ST_LAST_BINLOG_END_POSITION="$(printf '%s' "$raw" | sed -n 's/.*"last_binlog_end_position"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p')"

  rm -f "$state_file"

  if [[ -n "$ST_LAST_FULL_NAME" ]]; then
    STATE_PRESENT=1
    log "Backup state loaded: last successful FULL = ${ST_LAST_FULL_NAME} (completed ${ST_LAST_FULL_COMPLETED_AT:-unknown})."
  else
    log "Backup state exists but records no successful FULL yet."
  fi

  return 0
}

# Persist the state object to R2. Called ONLY after success + upload + verify +
# PUPTracker report. Values are passed explicitly so the caller controls exactly
# which fields advance (a FULL advances the base + binlog anchor; an incremental
# advances only the binlog boundary).
#
#   update_state <full_name> <full_completed_at> <full_storage_path> \
#                <binlog_file> <binlog_position> <binlog_end_file> <binlog_end_position>
update_state() {
  local full_name="$1"
  local full_completed_at="$2"
  local full_storage_path="$3"
  local binlog_file="$4"
  local binlog_position="$5"
  local binlog_end_file="$6"
  local binlog_end_position="$7"

  local state_file
  state_file="$(mktemp)"
  printf '{\n' > "$state_file"
  printf '  "state_version": 1,\n' >> "$state_file"
  printf '  "updated_at": "%s",\n' "$(now_utc)" >> "$state_file"
  printf '  "last_successful_full_backup_name": "%s",\n' "$(json_escape "$full_name")" >> "$state_file"
  printf '  "last_successful_full_completed_at": "%s",\n' "$(json_escape "$full_completed_at")" >> "$state_file"
  printf '  "last_successful_full_storage_path": "%s",\n' "$(json_escape "$full_storage_path")" >> "$state_file"
  printf '  "last_binlog_file": "%s",\n' "$(json_escape "$binlog_file")" >> "$state_file"
  printf '  "last_binlog_position": %s,\n' "${binlog_position:-0}" >> "$state_file"
  printf '  "last_binlog_end_file": "%s",\n' "$(json_escape "$binlog_end_file")" >> "$state_file"
  printf '  "last_binlog_end_position": %s\n' "${binlog_end_position:-0}" >> "$state_file"
  printf '}\n' >> "$state_file"

  if ! rclone --config "$RCLONE_CONFIG" copyto "$state_file" "remote:${BACKUP_STATE_REMOTE}"; then
    rm -f "$state_file"
    warn "Failed to persist backup state to remote:${BACKUP_STATE_REMOTE}."
    return 1
  fi

  rm -f "$state_file"
  log "Backup state updated at remote:${BACKUP_STATE_REMOTE}."
  return 0
}

# ---------------------------------------------------------------------------
# Backup-type decision
# ---------------------------------------------------------------------------
# Determine "full" or "incremental" and store it in the global DECIDED_TYPE.
# Logs the reason (never secrets). We use a GLOBAL rather than stdout because
# the decision logic also logs, and command substitution would otherwise mix
# log lines into the returned value.
#
# Rules (absolute):
#   * No valid successful FULL known  -> FULL  ("no valid full base").
#   * Now - last_successful_full >= BACKUP_FULL_INTERVAL_DAYS -> FULL.
#   * Otherwise -> incremental.
#
# The decision is based on the MOST RECENT SUCCESSFUL, VERIFIED full (from
# state), never on a merely-attempted full. A failed full never becomes base.
DECIDED_TYPE=""
determine_backup_type() {
  local interval="${BACKUP_FULL_INTERVAL_DAYS:-14}"

  # Guard against a non-numeric / nonsensical interval.
  if ! [[ "$interval" =~ ^[0-9]+$ ]] || [[ "$interval" -lt 1 ]]; then
    warn "BACKUP_FULL_INTERVAL_DAYS='${BACKUP_FULL_INTERVAL_DAYS}' is invalid; using 14."
    interval=14
  fi

  if [[ "${STATE_PRESENT:-0}" -ne 1 || -z "$ST_LAST_FULL_NAME" ]]; then
    log "No valid successful full backup exists; forcing FULL backup."
    DECIDED_TYPE="full"
    return 0
  fi

  # An anchorless FULL cannot safely start a TRUE_INCREMENTAL chain.
  # Automatically recover by taking a new FULL now rather than waiting for
  # BACKUP_FULL_INTERVAL_DAYS. The new FULL must obtain and persist a binlog
  # anchor before incrementals can resume.
  if [[ "${BACKUP_BINLOG_ENABLED:-true}" == "true" ]] &&      [[ -z "${ST_LAST_BINLOG_FILE:-}" || -z "${ST_LAST_BINLOG_POSITION:-}" ]]; then
    warn "Last successful FULL '${ST_LAST_FULL_NAME}' has no usable binlog anchor; forcing a new FULL to establish a safe incremental base."
    DECIDED_TYPE="full"
    return 0
  fi

  local last_full_epoch now_epoch age_days
  last_full_epoch="$(ts_to_epoch "$ST_LAST_FULL_COMPLETED_AT")"
  now_epoch="$(now_epoch)"

  if [[ "$last_full_epoch" -le 0 ]]; then
    warn "Last successful full backup timestamp '${ST_LAST_FULL_COMPLETED_AT}' is unparseable; forcing FULL backup."
    DECIDED_TYPE="full"
    return 0
  fi

  age_days=$(( (now_epoch - last_full_epoch) / 86400 ))
  log "Last successful full: ${ST_LAST_FULL_NAME} (${age_days} day(s) ago). Full interval is ${interval} day(s)."

  if [[ "$age_days" -ge "$interval" ]]; then
    log "Full backup is due (>= ${interval} days since last successful full)."
    DECIDED_TYPE="full"
    return 0
  fi

  DECIDED_TYPE="incremental"
  return 0
}

# ---------------------------------------------------------------------------
# MySQL binary-log helpers (TRUE incremental prerequisite)
# ---------------------------------------------------------------------------

# Run a single SQL statement against the target database and print the result.
# Uses an option file so the password is never on the command line or in logs.
mysql_query() {
  local sql="$1"
  local cnf
  cnf="$(mktemp)"
  chmod 600 "$cnf"
  cat > "$cnf" <<EOF
[client]
host=${MYSQL_HOST}
port=${MYSQL_PORT}
user=${MYSQL_USER}
password=${MYSQL_PASSWORD}
EOF
  local out
  # -N -B => tab-separated, no column headers, no ASCII box.
  out="$("$MYSQL_CLIENT_BIN" --defaults-extra-file="$cnf" -N -B -e "$sql" "$MYSQL_DATABASE" 2>/dev/null || true)"
  rm -f "$cnf"
  printf '%s' "$out"
}

# Verify binary logging is enabled and usable. Exits non-zero (via caller) with
# a clear, non-secret message when it is not. Sets several global probe results
# in variables the caller reads.
#
# Returns 0 when binlog is confirmed usable; 1 otherwise.
check_mysql_binlog() {
  local log_bin binlog_format
  log_bin="$(mysql_query "SHOW VARIABLES LIKE 'log_bin';" | awk -F'\t' '{print $2}')"
  binlog_format="$(mysql_query "SHOW VARIABLES LIKE 'binlog_format';" | awk -F'\t' '{print $2}')"

  log_bin="$(printf '%s' "$log_bin" | tr '[:lower:]' '[:upper:]' | tr -d '[:space:]')"
  BINLOG_FORMAT_PROBED="$(printf '%s' "$binlog_format" | tr '[:lower:]' '[:upper:]' | tr -d '[:space:]')"

  if [[ "$log_bin" != "ON" && "$log_bin" != "1" ]]; then
    warn "MySQL binary logging is not enabled (log_bin='${log_bin:-unknown}')."
    warn "TRUE incremental backups require binary logging. Configure the MySQL server with log_bin=ON."
    return 1
  fi

  if [[ "$BINLOG_FORMAT_PROBED" != "ROW" && "$BINLOG_FORMAT_PROBED" != "STATEMENT" && "$BINLOG_FORMAT_PROBED" != "MIXED" ]]; then
    warn "MySQL binlog_format='${BINLOG_FORMAT_PROBED:-unknown}' is not usable for extraction."
    return 1
  fi

  log "MySQL binary logging verified: log_bin=ON, binlog_format=${BINLOG_FORMAT_PROBED}."
  return 0
}

# Acquire the current binlog END boundary and print "file<TAB>position". This is
# the current write point of the active binlog.
#
# SQL compatibility (MySQL 8.4):
#   `SHOW MASTER STATUS` is DEPRECATED in MySQL 8.4 in favour of
#   `SHOW BINARY LOG STATUS`, which returns the identical column layout
#   (File, Position, Binlog_Do_DB, Binlog_Ignore_DB, Executed_Gtid_Set).
#   MySQL <= 8.0 does not have `SHOW BINARY LOG STATUS`, so we probe the 8.4
#   statement FIRST and safely FALL BACK to the legacy one. Both results are
#   normalized into the SAME internal "file<TAB>position" representation, so
#   the rest of the chain is statement-agnostic.
#
# Why there is NO FLUSH TABLES WITH READ LOCK here: the END boundary only needs
# to be a point we will RESUME FROM next time. Binlog positions are monotonic,
# so recording the current (file,position) and later reading [start, end] with
# mysqlbinlog --stop-position is gap-free and duplicate-free even if writes
# continue after we read it (those later events have positions greater than end
# and are picked up by the NEXT incremental). Avoiding FTWRL also avoids
# requiring the RELOAD privilege and avoids unnecessary database locking.
acquire_binlog_boundary() {
  local out
  local stmt

  # Prefer the MySQL 8.4 statement; fall back to the legacy statement. Both are
  # validated through the same normalizer, so a statement that succeeds but
  # yields no usable row falls through to the other.
  #
  # NOTE: the informational note is written to STDERR. This function's STDOUT is
  # the returned "file<TAB>position" value (callers use command substitution), so
  # anything written to stdout would corrupt the result.
  for stmt in "SHOW BINARY LOG STATUS;" "SHOW MASTER STATUS;"; do
    out="$(mysql_query "$stmt")"
    if normalize_binlog_status "$out"; then
      if [[ "$stmt" == "SHOW BINARY LOG STATUS;" ]]; then
        echo "[backup] Binlog boundary read via SHOW BINARY LOG STATUS (MySQL 8.4+)." >&2
      else
        echo "[backup] Binlog boundary read via SHOW MASTER STATUS (legacy fallback)." >&2
      fi
      printf '%s\t%s' "$_BH_FILE" "$_BH_POSITION"
      return 0
    fi
  done

  printf ''
  return 1
}

# Normalize a `SHOW BINARY LOG STATUS` / `SHOW MASTER STATUS` result into the
# globals _BH_FILE and _BH_POSITION. Returns 0 when a usable pair was found.
#
# Both statements emit the same tab-separated columns under `-N -B`: the first
# row is `File <TAB> Position <TAB> Binlog_Do_DB <TAB> Binlog_Ignore_DB <TAB>
# Executed_Gtid_Set`. We deliberately scan for the first row whose first two
# fields look like (binlog filename, integer position) instead of trusting
# fixed offsets, so extra/empty trailing columns are tolerated.
#
# The filename pattern requires the standard `<basename>.<digits>` shape
# (e.g. binlog.000070, mysql-bin.000070), which rejects an unrelated numeric
# first column that would otherwise be mistaken for a binlog file.
_BH_FILE=""
_BH_POSITION=""
normalize_binlog_status() {
  local out="$1"
  _BH_FILE=""
  _BH_POSITION=""

  if [[ -z "$out" ]]; then
    return 1
  fi

  _BH_FILE="$(printf '%s\n' "$out" | awk -F'\t' 'NF>=2 && $1 ~ /^[A-Za-z0-9._-]*\.[0-9]+$/ && $2 ~ /^[0-9]+$/ {print $1; exit}')"
  _BH_POSITION="$(printf '%s\n' "$out" | awk -F'\t' 'NF>=2 && $1 ~ /^[A-Za-z0-9._-]*\.[0-9]+$/ && $2 ~ /^[0-9]+$/ {print $2; exit}')"

  if [[ -z "$_BH_FILE" || -z "$_BH_POSITION" ]]; then
    return 1
  fi

  return 0
}

# Read the binlog coordinates recorded by mydumper in its dump metadata file.
#
# TWO metadata formats are supported, in this order:
#
# 1) MyDumper v0.21.x — the CURRENT format. Coordinates live in an INI-style
#    [source] section and are only UNCOMMENTED when mydumper is run with
#    --source-data:
#
#        [source]
#        # SOURCE_LOG_FILE = "binlog.000123"     <-- DEFAULT (commented, USELESS)
#        # SOURCE_LOG_POS = 456789
#
#    With --source-data the same keys become ACTIVE:
#
#        [source]
#        SOURCE_LOG_FILE = "binlog.000123"
#        SOURCE_LOG_POS = 456789
#
#    A COMMENTED key is never an anchor: that is exactly what mydumper writes
#    when --source-data was NOT passed, so accepting it would fabricate an
#    anchor for a dump that has none.
#
# 2) Legacy mydumper — a "SHOW MASTER STATUS:" / "SHOW BINARY LOG STATUS:"
#    block with `Log:`/`File:` and `Pos:`/`Position:` labels. Retained so older
#    dumps and existing deployments keep working.
#
# Whatever the format, this is the CONSISTENT SNAPSHOT position the dump
# corresponds to, and is the ONLY correct anchor from which a subsequent
# incremental may resume. A post-dump boundary would silently lose every
# transaction written during the dump, which is why this function never queries
# the server: the anchor must come from the dump's own metadata.
#
# Prints "file<TAB>position" or nothing.
read_mydumper_binlog_anchor() {
  local dir="${1:-$BACKUP_DIR}"
  local meta="$dir/metadata"
  if [[ ! -f "$meta" ]]; then
    printf ''
    return 1
  fi

  # Strip comment lines ONCE so neither parser below can ever mistake a
  # commented-out coordinate for a real one. `#` may follow leading whitespace.
  local active
  active="$(grep -v -E '^[[:space:]]*#' "$meta" 2>/dev/null || true)"

  local file position

  # --- Format 1: MyDumper v0.21.x  [source] SOURCE_LOG_FILE / SOURCE_LOG_POS --
  # Quotes are optional and trailing content is ignored, so both the quoted
  # `SOURCE_LOG_FILE = "binlog.000123"` form and a bare value parse. The
  # position pattern only accepts digits, so a non-numeric value yields nothing.
  file="$(printf '%s\n' "$active" \
    | sed -n -E 's/^[[:space:]]*SOURCE_LOG_FILE[[:space:]]*=[[:space:]]*"?([^"[:space:]]+)"?.*$/\1/p' \
    | head -n1)"
  position="$(printf '%s\n' "$active" \
    | sed -n -E 's/^[[:space:]]*SOURCE_LOG_POS[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' \
    | head -n1)"

  if [[ -z "$file" || -z "$position" ]]; then
    # --- Format 2 (legacy): binlog-status block with Log:/File: labels --------
    # Start reading at the first binlog-status marker when one is present;
    # otherwise the whole (comment-stripped) file is scanned.
    local region="$active"
    local marker_line
    marker_line="$(printf '%s\n' "$active" | grep -n -i -m1 -E '(master|binary log) status' | cut -d: -f1 || true)"
    if [[ -n "$marker_line" ]]; then
      region="$(printf '%s\n' "$active" | tail -n "+${marker_line}")"
    fi
    file="$(printf '%s\n' "$region" | sed -n -E 's/^[[:space:]]*(Log|File):[[:space:]]*([^[:space:]]*).*/\2/p' | head -n1)"
    position="$(printf '%s\n' "$region" | sed -n -E 's/^[[:space:]]*(Pos|Position):[[:space:]]*([0-9][0-9]*).*/\2/p' | head -n1)"
  fi

  # BOTH values are required; a half-populated anchor is not usable.
  if [[ -z "$file" || -z "$position" ]]; then
    printf ''
    return 1
  fi

  # ...and they must actually LOOK like a binlog coordinate. A filename without
  # the `<base>.<digits>` shape (e.g. `binlog.current`, or a stray object name) is
  # rejected rather than persisted as a bogus anchor, and the position must be a
  # positive integer.
  if [[ ! "$file" =~ ^[A-Za-z0-9._-]+\.[0-9]+$ ]]; then
    printf ''
    return 1
  fi
  if [[ ! "$position" =~ ^[0-9]+$ ]] || [[ "$position" -le 0 ]]; then
    printf ''
    return 1
  fi

  printf '%s\t%s' "$file" "$position"
  return 0
}

# List all binary log files currently retained by the server (one per line).
list_binary_logs() {
  mysql_query "SHOW BINARY LOGS;" | awk -F'\t' 'NF>=2 {print $1}'
}

# Returns 0 when the server implements the MySQL 8.4 `SHOW BINARY LOG STATUS`
# statement, which is a BEHAVIOURAL confirmation of the server family.
#
# WHY THIS EXISTS: mydumper classifies the server purely by matching
# `@@version_comment`/`@@version` against a token list, and that fails on real
# 8.4 servers whose comment is a distro string (e.g. `(Ubuntu)` or `(Debian)`)
# with no product token. Rather than GUESSING from more strings, we ask the
# server which statement it actually accepts: only MySQL 8.4+ answers
# `SHOW BINARY LOG STATUS`, and pre-8.4/other families error on it.
mysql_supports_binary_log_status() {
  command -v "$MYSQL_CLIENT_BIN" >/dev/null 2>&1 || return 1
  local out
  out="$(mysql_query "SHOW BINARY LOG STATUS;")"
  [[ -n "$out" ]]
}

# Derive the mydumper product-version override, in mydumper's own
# `<product>-<major>.<minor>.<patch>` form (e.g. `mysql-8.4.11`).
#
# WHY THIS IS REQUIRED — the root cause of "no binlog anchor" on MySQL 8.4:
#
# mydumper chooses which statement to use for the snapshot binlog coordinate in
# server_detect.c:detect_replica(). It starts from the PRE-8.4 default
#
#     show_binary_log_status = SHOW MASTER STATUS
#
# and upgrades it to `SHOW BINARY LOG STATUS` only inside a switch whose case arm
# is guarded by `get_major()>=8 && (get_secondary()>0 || revision>=22)`.
#
# The product and version come from detect_server_version(), which issues
#     SELECT @@version_comment, @@version
# and matches the LOWERCASED text of BOTH columns against
# percona|mariadb|tidb|dolt|google|mysql|source. If NOTHING matches, the product
# stays SERVER_TYPE_UNKNOWN and the version is parsed from the literal "0.0.0",
# so major=0. The upgrade branch is therefore skipped, `SHOW MASTER STATUS` is
# issued, and MySQL 8.4 rejects it:
#     Couldn't get master position - ERROR 1064 ... near 'MASTER STATUS'
# mydumper then writes its metadata file WITHOUT any `[source]` section, so the
# FULL records no anchor and every subsequent incremental must refuse to run.
# (Reproduced against a MySQL 8.4 server whose @@version_comment hides the
# "mysql" substring.)
#
# `--server-version` makes server_detect() bypass detection entirely and take the
# product+version verbatim, so the correct 8.4 statement is selected and the
# anchor is written. The value is DERIVED from the live server — never
# hard-coded — so it stays correct across upgrades and for MariaDB/Percona/RDS
# builds rather than pinning one vendor's version into the image.
#
# SAFETY: this only changes WHICH statement mydumper uses to read the snapshot
# coordinate. It cannot invent an anchor: if the position is still unavailable,
# mydumper writes no `[source]` section and the existing rule applies (empty
# anchor -> incremental refuses to run).
#
# Prints the override, or nothing when the server could not be classified (the
# caller then passes no override and behaviour is exactly as before).
detect_mydumper_server_version() {
  # Never hard-require the client: when binlog support is disabled the MySQL
  # client may legitimately be absent, and that must not break a FULL.
  command -v "$MYSQL_CLIENT_BIN" >/dev/null 2>&1 || return 1

  local raw version comment haystack product="" ver3
  raw="$(mysql_query "SELECT @@version, @@version_comment;")"
  version="$(printf '%s' "$raw" | awk -F'\t' '{print $1}' | head -n1)"
  comment="$(printf '%s' "$raw" | awk -F'\t' '{print $2}' | head -n1)"
  [[ -n "$version" ]] || return 1

  # First three numeric version components, so both `8.4.11` and distro-suffixed
  # forms such as `8.4.10-0ubuntu0.26.04.1` / `8.4.11-1.el9` reduce correctly.
  ver3="$(printf '%s' "$version" | sed -n -E 's/^([0-9]+)\.([0-9]+)\.([0-9]+).*/\1.\2.\3/p')"
  [[ -n "$ver3" ]] || return 1

  # Mirror mydumper's own precedence ordering exactly, so the product we declare
  # matches what its own detection would have concluded.
  haystack="$(printf '%s %s' "$version" "$comment" | tr '[:upper:]' '[:lower:]')"
  case "$haystack" in
    *percona*)        product="percona" ;;
    *mariadb*)        product="mariadb" ;;
    *tidb*)           product="tidb" ;;
    *dolt*)           product="dolt" ;;
    *google*)         product="google" ;;
    *mysql*|*source*) product="mysql" ;;
  esac

  # No product token matched. mydumper would fall back to its pre-8.4 statement
  # here, so we must still produce an override when the server really is a modern
  # MySQL -- otherwise the anchor is silently unavailable (the reported bug).
  # Confirm that BEHAVIOURALLY rather than guessing from another string: only
  # MySQL 8.4+ implements `SHOW BINARY LOG STATUS`. A server that fails the probe
  # yields no override, exactly as before.
  if [[ -z "$product" ]]; then
    if mysql_supports_binary_log_status; then
      product="mysql"
    fi
  fi

  [[ -n "$product" ]] || return 1

  printf '%s-%s' "$product" "$ver3"
  return 0
}

# Emit non-secret evidence about the MySQL server's binary-logging capability.
# Used both when the anchor is missing and as a record on every FULL, so an
# operator can see the preconditions the anchor depends on.
log_mysql_binlog_diagnostics() {
  local raw version comment log_bin fmt gtid
  raw="$(mysql_query "SELECT @@version, @@version_comment, @@log_bin, @@binlog_format;" 2>/dev/null || true)"
  version="$(printf '%s' "$raw" | awk -F'\t' '{print $1}' | head -n1)"
  comment="$(printf '%s' "$raw" | awk -F'\t' '{print $2}' | head -n1)"
  log_bin="$(printf '%s' "$raw" | awk -F'\t' '{print $3}' | head -n1)"
  fmt="$(printf '%s' "$raw" | awk -F'\t' '{print $4}' | head -n1)"
  log "DIAG mysql: version='${version:-<unknown>}' version_comment='${comment:-<unknown>}' log_bin='${log_bin:-<unknown>}' binlog_format='${fmt:-<unknown>}'"

  # GTID mode decides whether a GTID coordinate is also available; it is
  # informational here because this chain resumes by file+position.
  gtid="$(mysql_query "SELECT @@gtid_mode;" 2>/dev/null | head -n1 || true)"
  log "DIAG mysql: gtid_mode='${gtid:-<unknown>}'"
}

# ---------------------------------------------------------------------------
# FULL backup (existing MyDumper flow, preserved)
# ---------------------------------------------------------------------------
run_full_backup() {
  BACKUP_TYPE="full"
  BACKUP_NAME="full_$(date -u +"%Y-%m-%d_%H%M%S")"
  local date_path
  date_path="$(date -u +"%Y/%m/%d")"
  # <R2_PATH>/full/YYYY/MM/DD/<backup_name>/
  STORAGE_PATH="${R2_PATH%/}/full/${date_path}/${BACKUP_NAME}"

  log "Backup type selected: FULL"
  log "R2 destination: ${R2_BUCKET}/${STORAGE_PATH}"

  # 1) Logical dump with mydumper into a fresh local directory.
  #
  # CREDENTIALS: the password is passed through a temporary --defaults-file
  # (mode 600) rather than the command line. A command-line --password is
  # visible to ANY process on the host via `ps`/`/proc/<pid>/cmdline`, so it
  # would leak the MySQL password into container and node process listings.
  set_stage "full_backup"
  log "Stage: full_backup (started)"
  rm -rf "$BACKUP_DIR"
  local mydumper_cnf
  mydumper_cnf="$(mktemp)"
  chmod 600 "$mydumper_cnf"
  # Both the standard [client] group and mydumper's own [mydumper] group are
  # populated so the credentials are found regardless of which group this
  # mydumper build reads; the non-secret connection parameters are ALSO passed
  # on the command line so a build that ignores the file entirely still connects.
  cat > "$mydumper_cnf" <<EOF
[client]
host=${MYSQL_HOST}
port=${MYSQL_PORT}
user=${MYSQL_USER}
password=${MYSQL_PASSWORD}

[mydumper]
host=${MYSQL_HOST}
port=${MYSQL_PORT}
user=${MYSQL_USER}
password=${MYSQL_PASSWORD}
EOF
  local mydumper_rc=0
  # --source-data makes mydumper write the CONSISTENT-SNAPSHOT binlog
  # coordinates (SOURCE_LOG_FILE / SOURCE_LOG_POS) UNCOMMENTED into the
  # metadata file. Without it those keys are written commented-out and the FULL
  # has no anchor, so no incremental can ever start from it. The coordinates
  # recorded here describe the exact instant the snapshot was taken, which is
  # what makes the FULL -> INCREMENTAL chain gap-free.
  #
  # --server-version is DERIVED FROM THE LIVE SERVER (see
  # detect_mydumper_server_version) so mydumper selects the MySQL 8.4
  # `SHOW BINARY LOG STATUS` statement instead of the removed
  # `SHOW MASTER STATUS`. It is passed ONLY when the server could be classified;
  # otherwise the option is omitted entirely so behaviour is byte-for-byte the
  # same as before on any server we cannot identify.
  local mydumper_sv=""
  mydumper_sv="$(detect_mydumper_server_version || true)"
  local -a sv_args=()
  if [[ -n "$mydumper_sv" ]]; then
    sv_args=(--server-version "$mydumper_sv")
    log "mydumper server-version override: ${mydumper_sv}"
  else
    warn "Could not classify the MySQL server for mydumper; running without --server-version (the binlog anchor may be unavailable on MySQL 8.4+)."
  fi
  # The version is logged because the binlog-anchor handshake with the server is
  # version-sensitive: a build that falls back to the pre-8.4 `SHOW MASTER STATUS`
  # statement cannot read a position from a MySQL 8.4+ server at all.
  log "mydumper version: $(mydumper --version 2>&1 | head -n1 || true)"
  # Record the EXACT command line (redacted) so an operator can see the real
  # flag set actually executed, rather than trusting the source code. The
  # password never appears here: it is supplied through --defaults-file.
  log "mydumper command: $(redact_cmd mydumper \
        --defaults-file="$mydumper_cnf" \
        --host "$MYSQL_HOST" \
        --user "$MYSQL_USER" \
        --port "$MYSQL_PORT" \
        --database "$MYSQL_DATABASE" \
        --source-data \
        "${sv_args[@]}" \
        -C -c --clear -o "$BACKUP_DIR")"
  mydumper \
    --defaults-file="$mydumper_cnf" \
    --host "$MYSQL_HOST" \
    --user "$MYSQL_USER" \
    --port "$MYSQL_PORT" \
    --database "$MYSQL_DATABASE" \
    --source-data \
    "${sv_args[@]}" \
    -C -c --clear -o "$BACKUP_DIR" || mydumper_rc=$?
  rm -f "$mydumper_cnf"
  if [[ "$mydumper_rc" -ne 0 ]]; then
    FULL_BACKUP_RC="$mydumper_rc"
    report_failure_and_exit "mydumper failed to produce a logical database snapshot."
  fi

  if [[ ! -d "$BACKUP_DIR" ]]; then
    FULL_BACKUP_RC=1
    report_failure_and_exit "mydumper exited successfully but produced no backup directory."
  fi

  FILE_COUNT="$(count_files "$BACKUP_DIR")"
  BACKUP_SIZE="$(total_size "$BACKUP_DIR")"
  if [[ "$FILE_COUNT" -eq 0 ]]; then
    FULL_BACKUP_RC=1
    report_failure_and_exit "mydumper produced an empty backup directory (0 files)."
  fi

  CHECKSUM="$(compute_manifest_checksum "$BACKUP_DIR")"
  log "Full backup metadata calculated."
  log "Backup files: ${FILE_COUNT}, total bytes: ${BACKUP_SIZE}"
  log "Backup checksum (SHA-256): ${CHECKSUM}"
  log "Stage: full_backup -> OK"

  # Record the binlog coordinate the dump corresponds to, so a later
  # incremental resumes EXACTLY from the full snapshot (no gap, no duplicates).
  # mydumper records this in its `metadata` file: MyDumper v0.21.x writes an
  # active `[source]` section (SOURCE_LOG_FILE / SOURCE_LOG_POS) when run with
  # --source-data, and older builds wrote a "SHOW MASTER STATUS:" block. If
  # binlog is unavailable/disabled, or the anchor is missing/unusable, we still
  # take the FULL (it is a valid logical baseline) but record an EMPTY anchor so
  # a later incremental refuses to run rather than mis-resume.
  set_stage "mysql_binlog_check"
  if [[ "${BACKUP_BINLOG_ENABLED:-true}" == "true" ]]; then
    local anchor
    local anchor_rc=0
    anchor="$(read_mydumper_binlog_anchor "$BACKUP_DIR")" || anchor_rc=$?
    if [[ "$anchor_rc" -eq 0 && -n "$anchor" ]]; then
      BINLOG_FILE_END="${anchor%%$'\t'*}"
      BINLOG_POSITION_END="${anchor##*$'\t'}"
      BINLOG_ANCHOR_OK="yes"
      log "Full backup binlog anchor (from mydumper metadata): ${BINLOG_FILE_END}:${BINLOG_POSITION_END}."
    else
      # NOT a failure: the FULL dump is a valid logical baseline on its own. But
      # without a usable anchor the chain cannot advance by incremental from this
      # FULL, so the state is written with an EMPTY anchor and any later
      # incremental refuses to run (rather than mis-resuming from a wrong
      # position). BINLOG_ANCHOR_OK is surfaced in the exit diagnosis.
      #
      # Emit the non-secret anchor diagnostics BEFORE the warning so the warning
      # is immediately followed by the evidence explaining it (mydumper version,
      # metadata path, presence of the [source] section, and what the parser
      # extracted). The SAFETY RULE IS UNCHANGED: an unusable anchor still
      # produces an EMPTY anchor and incrementals still refuse to run.
      BINLOG_FILE_END=""
      BINLOG_POSITION_END=""
      BINLOG_ANCHOR_OK="no"
      log_binlog_anchor_diagnostics "$BACKUP_DIR"
      # Also record the server-side preconditions and the product/version the
      # override was (or was not) derived from, so the exact reason the anchor is
      # missing is visible without reproducing the run.
      log_mysql_binlog_diagnostics
      if [[ -n "$mydumper_sv" ]]; then
        warn "Anchor missing DESPITE --server-version='${mydumper_sv}'; the metadata has no usable [source] section."
      else
        warn "Anchor missing AND no --server-version override could be derived; mydumper was left to auto-detect (this fails on MySQL 8.4+ when @@version_comment hides the MySQL identity)."
      fi
      warn "mydumper metadata did not contain a usable binlog anchor (anchor_rc=${anchor_rc}); this FULL is a valid logical baseline but CANNOT serve as a base for TRUE_INCREMENTAL until a FULL with an anchor is taken."
    fi
  else
    BINLOG_ANCHOR_OK="disabled"
    log "Binary-log backups disabled (BACKUP_BINLOG_ENABLED=false); no binlog anchor recorded for this full."
  fi
}

# ---------------------------------------------------------------------------
# TRUE INCREMENTAL backup (binary logs only)
# ---------------------------------------------------------------------------
run_incremental_backup() {
  BACKUP_TYPE="incremental"
  BACKUP_NAME="incremental_$(date -u +"%Y-%m-%d_%H%M%S")"
  local date_path
  date_path="$(date -u +"%Y/%m/%d")"
  # <R2_PATH>/incremental/YYYY/MM/DD/<backup_name>/
  STORAGE_PATH="${R2_PATH%/}/incremental/${date_path}/${BACKUP_NAME}"

  log "Backup type selected: INCREMENTAL"
  log "Incremental base full: ${ST_LAST_FULL_NAME} (${ST_LAST_FULL_STORAGE_PATH})."

  # --- Precondition 1: binary logging enabled by config. ---
  if [[ "${BACKUP_BINLOG_ENABLED:-true}" != "true" ]]; then
    report_failure_and_exit "Incremental backup is required but binary-log backups are disabled (BACKUP_BINLOG_ENABLED=false). Enable binlog backups or wait for the next full-backup day."
  fi

  # --- Precondition 2: a valid full base with a binlog anchor exists. ---
  if [[ "${STATE_PRESENT:-0}" -ne 1 || -z "$ST_LAST_FULL_NAME" ]]; then
    report_failure_and_exit "Incremental backup is required but no successful full backup base exists."
  fi
  if [[ -z "$ST_LAST_BINLOG_FILE" || -z "$ST_LAST_BINLOG_POSITION" ]]; then
    report_failure_and_exit "Incremental backup base has no recorded binlog position; cannot resume safely. A new full backup is required."
  fi

  # --- Precondition 3: MySQL binary logging is ON. ---
  set_stage "mysql_binlog_check"
  if [[ "${BACKUP_BINLOG_VERIFY:-true}" == "true" ]]; then
    if ! check_mysql_binlog; then
      report_failure_and_exit "TRUE incremental backup is impossible: MySQL binary logging is not enabled/usable (log_bin must be ON)."
    fi
  fi

  BINLOG_FILE_START="$ST_LAST_BINLOG_FILE"
  BINLOG_POSITION_START="$ST_LAST_BINLOG_POSITION"

  # Recovery-chain metadata carried in the report payload (never secrets).
  BASE_BACKUP_NAME="$ST_LAST_FULL_NAME"
  BASE_FULL_STORAGE_PATH="$ST_LAST_FULL_STORAGE_PATH"

  # --- Precondition 4: the saved start file must still exist (not purged). ---
  set_stage "binlog_capture"
  local available_logs
  available_logs="$(list_binary_logs)"
  if [[ -z "$available_logs" ]]; then
    report_failure_and_exit "Could not list MySQL binary logs (SHOW BINARY LOGS returned nothing)."
  fi
  if ! printf '%s\n' "$available_logs" | grep -qxF "$BINLOG_FILE_START"; then
    report_failure_and_exit "The required binary log '${BINLOG_FILE_START}' has already been purged on the server; safe incremental continuation is impossible. A new full backup is required."
  fi

  # --- Establish the END boundary WITHOUT any table lock. ---
  # We read the current binlog write position via SHOW BINARY LOG STATUS (MySQL
  # 8.4+) or SHOW MASTER STATUS (legacy fallback); see acquire_binlog_boundary
  # for why no FLUSH TABLES WITH READ LOCK is used or needed.
  local boundary
  if ! boundary="$(acquire_binlog_boundary)"; then
    report_failure_and_exit "Could not establish a consistent MySQL binlog boundary (neither SHOW BINARY LOG STATUS nor SHOW MASTER STATUS returned a usable position)."
  fi
  BINLOG_FILE_END="${boundary%%$'\t'*}"
  BINLOG_POSITION_END="${boundary##*$'\t'}"
  log "Incremental base binlog: ${BINLOG_FILE_START}:${BINLOG_POSITION_START}"
  log "Incremental end binlog: ${BINLOG_FILE_END}:${BINLOG_POSITION_END}"

  # The end file must be at-or-after the start file (lexical order matches the
  # binlog.000001, binlog.000002 ... numbering; the numeric suffix is
  # zero-padded so lexical == numeric for a given prefix).
  if [[ "$BINLOG_FILE_END" < "$BINLOG_FILE_START" ]]; then
    report_failure_and_exit "Inconsistent binlog boundary: end file (${BINLOG_FILE_END}) is before start file (${BINLOG_FILE_START})."
  fi

  # The END file must itself still be retained. If it is already gone the server
  # rotated and purged past our write point, so the range cannot be captured
  # completely and the chain is broken.
  if ! printf '%s\n' "$available_logs" | grep -qxF "$BINLOG_FILE_END"; then
    report_failure_and_exit "The end boundary binary log '${BINLOG_FILE_END}' is no longer retained by the server, so the range ${BINLOG_FILE_START} -> ${BINLOG_FILE_END} cannot be captured completely. The incremental chain is broken; a new FULL backup is required."
  fi

  # Build the exact ordered list of binlog files to extract: every retained file
  # from the start file THROUGH the end file. This correctly handles rotation
  # (multiple files) and the active file.
  #
  # GAP DETECTION: the files we walk MUST be a contiguous run. If the server's
  # numbering jumps (a file was purged between our start and our end while we
  # were listing) we abort instead of silently skipping it, because a skipped
  # file would produce an incremental that APPEARS complete but is missing
  # events (a silent data-loss bug).
  local files_to_read=()
  local seen_start=0 f
  local expected_next=""
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if [[ "$f" == "$BINLOG_FILE_START" ]]; then
      seen_start=1
    fi
    if [[ "$seen_start" -eq 1 ]]; then
      # Contiguity check: each file after the first must be exactly the
      # numerically-next binlog file.
      if [[ -n "$expected_next" && "$f" != "$expected_next" ]]; then
        report_failure_and_exit "Binary logs are not contiguous between ${BINLOG_FILE_START} and ${BINLOG_FILE_END}: expected '${expected_next}' next but the server lists '${f}'. A binary log was purged mid-range, so the incremental chain is broken; a new FULL backup is required."
      fi
      files_to_read+=("$f")
      expected_next="$(next_binlog_filename "$f")"
    fi
    if [[ "$f" == "$BINLOG_FILE_END" ]]; then
      break
    fi
  done <<< "$available_logs"

  if [[ "${#files_to_read[@]}" -eq 0 ]]; then
    report_failure_and_exit "No readable binary-log files were found between ${BINLOG_FILE_START} and ${BINLOG_FILE_END}."
  fi

  # Did we actually reach the end boundary? If the loop ended early (end file
  # absent from the listing) we must not proceed with a partial range.
  if [[ "${files_to_read[-1]}" != "$BINLOG_FILE_END" ]]; then
    report_failure_and_exit "Could not reach the end boundary ${BINLOG_FILE_END} while walking the retained binary logs (stopped at ${files_to_read[-1]}). A binary log in the range is missing; the incremental chain is broken and a new FULL backup is required."
  fi

  log "Incremental range spans ${#files_to_read[@]} binary log file(s): ${files_to_read[*]}"

  # Fetch a byte-exact copy of each binlog file. The strategy is configurable:
  #   copy -> read the server's own binlog directory (needs no REPLICATION
  #           privilege; default)
  #   raw  -> pull via mysqlbinlog --read-from-remote-server --raw (needs
  #           REPLICATION SLAVE)
  # Whichever is used, the package is re-validated locally with mysqlbinlog
  # below, so a truncated/uneditable copy can never be uploaded silently.
  rm -rf "$MYSQL_BINLOG_BASE_DIR"
  mkdir -p "$MYSQL_BINLOG_BASE_DIR"
  local downloaded_count=0
  for f in "${files_to_read[@]}"; do
    local rfile="$MYSQL_BINLOG_BASE_DIR/$f"
    if ! fetch_binlog_file "$f" "$rfile"; then
      report_failure_and_exit "Failed to capture binary log '${f}' from the server (strategy: ${BINLOG_FETCH_STRATEGY})."
    fi
    downloaded_count=$((downloaded_count + 1))
  done

  # Package into the incremental archive directory.
  rm -rf "$BINLOG_DIR"
  mkdir -p "$BINLOG_DIR"

  # 1) Raw binlog files (the authoritative, byte-exact recovery source).
  cp -a "$MYSQL_BINLOG_BASE_DIR/." "$BINLOG_DIR/"

  # 2) A validated, human-applicable SQL stream produced by mysqlbinlog, with
  #    the correct start/stop boundary. This is the artifact operators apply.
  #
  # IMPORTANT: mysqlbinlog is invoked with ABSOLUTE paths. The binlog files were
  # staged into MYSQL_BINLOG_BASE_DIR (a relative directory) and have NOT been
  # copied into the current working directory. compute_manifest_checksum()
  # already relies on `cd` being confined to a subshell, so the caller's CWD is
  # unchanged here; passing the bare file names would make mysqlbinlog look in
  # the CWD, fail to find the files, and abort every incremental even though the
  # capture itself succeeded. Resolve the staging directory to an absolute path
  # once and reference the same bytes that were copied into the archive.
  local apply_file="$BINLOG_DIR/binlog_apply.sql.gz"
  local apply_tmp
  apply_tmp="$(mktemp)"
  local binlog_abs_dir
  binlog_abs_dir="$(cd "$MYSQL_BINLOG_BASE_DIR" 2>/dev/null && pwd)" || binlog_abs_dir=""
  if [[ -z "$binlog_abs_dir" ]]; then
    rm -f "$apply_tmp"
    report_failure_and_exit "Internal error: could not resolve the binlog staging directory '${MYSQL_BINLOG_BASE_DIR}'."
  fi
  local apply_inputs=()
  for f in "${files_to_read[@]}"; do
    apply_inputs+=("${binlog_abs_dir}/${f}")
  done
  if ! mysqlbinlog_local_stream "$apply_tmp" "${apply_inputs[@]}"; then
    rm -f "$apply_tmp"
    report_failure_and_exit "mysqlbinlog could not validate/extract the binary-log range ${BINLOG_FILE_START}:${BINLOG_POSITION_START} - ${BINLOG_FILE_END}:${BINLOG_POSITION_END}."
  fi
  if [[ ! -s "$apply_tmp" ]]; then
    rm -f "$apply_tmp"
    report_failure_and_exit "mysqlbinlog produced an empty incremental for ${BINLOG_FILE_START}:${BINLOG_POSITION_START} - ${BINLOG_FILE_END}:${BINLOG_POSITION_END}."
  fi
  if ! gzip -c "$apply_tmp" > "$apply_file"; then
    rm -f "$apply_tmp"
    report_failure_and_exit "Failed to compress the incremental binlog stream."
  fi
  rm -f "$apply_tmp"

  # 3) Machine-readable metadata describing the chain.
  set_stage "incremental_metadata"
  write_incremental_metadata "$BINLOG_DIR/backup_metadata.json"
  log "Stage: incremental_metadata -> OK"

  FILE_COUNT="$(count_files "$BINLOG_DIR")"
  BACKUP_SIZE="$(total_size "$BINLOG_DIR")"
  if [[ "$FILE_COUNT" -eq 0 ]]; then
    report_failure_and_exit "Incremental archive is empty (0 files)."
  fi

  CHECKSUM="$(compute_manifest_checksum "$BINLOG_DIR")"
  log "Incremental backup metadata calculated."
  log "Backup files: ${FILE_COUNT}, total bytes: ${BACKUP_SIZE}"
  log "Backup checksum (SHA-256): ${CHECKSUM}"
  log "Stage: binlog_capture -> OK (${downloaded_count} binlog file(s) archived)."
}

# Compute the numerically-next binlog filename from one we have just seen, so
# the range walk can prove the listed files are CONTIGUOUS.
#
# Binlog names are `binlog.NNNNNN` (zero-padded). If any component is not
# numeric (e.g. a custom `log_bin_basename` with a different suffix) we cannot
# compute the successor and return an empty string, which DISABLES the
# contiguity assertion rather than producing a false failure.
#
#   binlog.000070 -> binlog.000071
next_binlog_filename() {
  local f="$1"
  local prefix num width next
  if [[ ! "$f" =~ ^(.*\.)([0-9]+)$ ]]; then
    printf ''
    return 0
  fi
  prefix="${BASH_REMATCH[1]}"
  num="${BASH_REMATCH[2]}"
  width="${#num}"
  next=$((10#$num + 1))
  printf '%s%0*d' "$prefix" "$width" "$next"
  return 0
}

# Fetch a byte-exact copy of one binlog file to <dest>.
#
# Strategy `raw` (default): `mysqlbinlog --read-from-remote-server --raw`, the
# standard supported mechanism for a remote binlog consumer.
# Strategy `copy`: read the file from a locally mounted binlog directory.
#
# NOTE on --server-id: a replication client MUST present a server_id that is
# unique among all other binlog consumers. It comes from MYSQLBINLOG_SERVER_ID
# (never a hard-coded 1) so it cannot collide with a real replica, with
# Railway's own binlog archiving, or with a concurrent backup.
fetch_binlog_file() {
  local file="$1"
  local dest="$2"
  local strategy="${BINLOG_FETCH_STRATEGY:-raw}"

  if [[ "$strategy" == "copy" ]]; then
    fetch_binlog_file_via_copy "$file" "$dest"
    return $?
  fi

  fetch_binlog_file_via_mysqlbinlog "$file" "$dest"
  return $?
}

# Read one binlog file straight from a locally mounted binlog directory.
fetch_binlog_file_via_copy() {
  local file="$1"
  local dest="$2"

  if [[ -z "${BINLOG_LOCAL_DIR:-}" ]]; then
    warn "BINLOG_FETCH_STRATEGY=copy requires BINLOG_LOCAL_DIR to point at the server's binlog directory."
    return 1
  fi

  local src="${BINLOG_LOCAL_DIR%/}/${file}"
  if [[ ! -f "$src" ]]; then
    warn "Binary log '${file}' was not found under BINLOG_LOCAL_DIR."
    return 1
  fi
  if [[ ! -s "$src" ]]; then
    warn "Binary log '${file}' is empty."
    return 1
  fi

  cp "$src" "$dest"
  return 0
}

# Fetch one binlog file with `mysqlbinlog --read-from-remote-server --raw`.
# Writes the raw bytes into a temp directory, then moves them to <dest>.
fetch_binlog_file_via_mysqlbinlog() {
  local file="$1"
  local dest="$2"
  local cnf
  cnf="$(mktemp)"
  chmod 600 "$cnf"
  cat > "$cnf" <<EOF
[client]
host=${MYSQL_HOST}
port=${MYSQL_PORT}
user=${MYSQL_USER}
password=${MYSQL_PASSWORD}
EOF

  local outdir
  outdir="$(mktemp -d)"
  local rc=0
  # CAPTURE FORM — this must work on the MySQL *client* (the Dockerfile installs
  # the MySQL 8.4 client, NOT MariaDB's).
  #
  # `--raw` (requires -R/--read-from-remote-server) writes the raw binlog bytes.
  # It does NOT support `--result-dir`: that option exists only in MariaDB's
  # mysqlbinlog, and the MySQL client rejects it outright with
  #     mysqlbinlog: [ERROR] unknown option '--result-dir'.
  # so every `raw` capture would fail. Instead we run with the TEMP DIRECTORY AS
  # THE CWD, where mysqlbinlog's default behaviour is to create a file named
  # after the binlog (`binlog.000001`) -- the portable, version-independent form.
  #
  # --server-id is required by --raw and comes from MYSQLBINLOG_SERVER_ID
  # (never hard-coded).
  (
    cd "$outdir" || exit 1
    "$MYSQLBINLOG_BIN" --defaults-extra-file="$cnf" \
      --read-from-remote-server \
      --server-id="${MYSQLBINLOG_SERVER_ID}" \
      --raw \
      "$file"
  ) || rc=$?
  rm -f "$cnf"

  if [[ "$rc" -ne 0 ]]; then
    rm -rf "$outdir"
    return 1
  fi

  # Prefer the file named after the source binlog; otherwise take the first
  # regular file produced (some clients append a suffix to the name).
  local produced="" candidate
  if [[ -s "$outdir/$file" ]]; then
    produced="$outdir/$file"
  else
    while IFS= read -r candidate; do
      [[ -n "$candidate" ]] && { produced="$candidate"; break; }
    done < <(find "$outdir" -type f 2>/dev/null)
  fi

  if [[ -z "$produced" || ! -s "$produced" ]]; then
    rm -rf "$outdir"
    return 1
  fi

  cp "$produced" "$dest"
  rm -rf "$outdir"
  return 0
}

# Re-read the locally captured binlog files with mysqlbinlog and verify the
# requested range is present and produces at least one event. This is the
# VALIDATION step that stops a truncated/unreadable capture from being uploaded,
# and it is also what produces the human-applicable SQL stream.
#
# The command fails (non-zero) when the capture is unusable, so a failed
# capture is a hard failure and state is never advanced for it.
#
#   mysqlbinlog_local_stream <outfile> <file1> <file2> ...
#
# POSITION SEMANTICS: mysqlbinlog applies --start-position to the FIRST file and
# --stop-position to the LAST file in the list. That is exactly what the
# persisted state + the acquired end boundary mean for a multi-file (rotated)
# range, so no position translation is needed.
mysqlbinlog_local_stream() {
  local outfile="$1"
  shift
  local files=("$@")

  "$MYSQLBINLOG_BIN" \
    --start-position="${BINLOG_POSITION_START}" \
    --stop-position="${BINLOG_POSITION_END}" \
    "${files[@]}" > "$outfile"
}

# Write the incremental metadata JSON into the archive.
write_incremental_metadata() {
  local dest="$1"
  {
    printf '{\n'
    printf '  "backup_type": "incremental",\n'
    printf '  "backup_name": "%s",\n' "$(json_escape "$BACKUP_NAME")"
    printf '  "base_full_backup_name": "%s",\n' "$(json_escape "$ST_LAST_FULL_NAME")"
    printf '  "base_full_storage_path": "%s",\n' "$(json_escape "$ST_LAST_FULL_STORAGE_PATH")"
    printf '  "start_binlog_file": "%s",\n' "$(json_escape "$BINLOG_FILE_START")"
    printf '  "start_binlog_position": %s,\n' "${BINLOG_POSITION_START:-0}"
    printf '  "end_binlog_file": "%s",\n' "$(json_escape "$BINLOG_FILE_END")"
    printf '  "end_binlog_position": %s,\n' "${BINLOG_POSITION_END:-0}"
    printf '  "started_at": "%s",\n' "$(json_escape "$STARTED_AT")"
    printf '  "completed_at": "%s"\n' "$(json_escape "$(now_utc)")"
    printf '}\n'
  } > "$dest"
}

# ---------------------------------------------------------------------------
# Shared upload + verify (used by both FULL and INCREMENTAL)
# ---------------------------------------------------------------------------
# Configures rclone, uploads <local_dir> to <storage_path>, and verifies it.
configure_rclone() {
  set_stage "rclone_config"
  log "Stage: rclone_config (started) -> ${RCLONE_CONFIG}"
  mkdir -p "$RCLONE_CONFIG_DIR"
  # The config file holds the R2 access key id and SECRET access key, so create
  # it with owner-only permissions. `umask 077` guarantees the redirect below
  # creates the file mode 600 (a plain `> file` under the default umask would be
  # world-readable, leaking the R2 credentials to any process in the container).
  (
    umask 077
    {
      printf '[remote]\n'
      printf 'type = s3\n'
      printf 'provider = %s\n' "$R2_PROVIDER"
      printf 'access_key_id = %s\n' "$R2_ACCESS_KEY_ID"
printf 'secret_access_key = %s\n' "$R2_SECRET_ACCESS_KEY"
printf 'endpoint = %s\n' "$R2_ENDPOINT"
printf 'no_check_bucket = true\n'
      # Omitted entirely when R2_ACL is empty; some S3-compatible endpoints
      # reject canned ACLs and would otherwise fail every upload.
      if [[ -n "${R2_ACL:-}" ]]; then
        printf 'acl = %s\n' "$R2_ACL"
      fi
    } > "$RCLONE_CONFIG"
  )
  # Belt-and-braces in case the file already existed with looser permissions.
  chmod 600 "$RCLONE_CONFIG" 2>/dev/null || true
  log "Stage: rclone_config -> written"

  if ! rclone --config "$RCLONE_CONFIG" listremotes >/dev/null 2>&1; then
    report_failure_and_exit "rclone configuration could not be read/validated (config: ${RCLONE_CONFIG})."
  fi
  if ! rclone --config "$RCLONE_CONFIG" listremotes 2>/dev/null | grep -q '^remote:$'; then
    report_failure_and_exit "rclone configuration is missing the [remote] destination."
  fi
  log "Stage: rclone_config -> validated ([remote] present)"
}

upload_and_verify() {
  local dir="$1"

  configure_rclone

  set_stage "rclone_upload"
  log "Stage: rclone_upload (started) -> remote:${R2_BUCKET}/${STORAGE_PATH}"
  if ! rclone --config "$RCLONE_CONFIG" sync "$dir" "remote:${R2_BUCKET}/${STORAGE_PATH}"; then
    UPLOAD_RC=1
    report_failure_and_exit "rclone upload to Cloudflare R2 failed."
  fi
  UPLOAD_RC=0
  log "Stage: rclone_upload -> OK"

  set_stage "rclone_verify"
  log "Stage: rclone_verify (started)"
  if ! verify_upload "$dir" "${R2_BUCKET}/${STORAGE_PATH}"; then
    VERIFY_RC=1
    report_failure_and_exit "R2 upload verification failed."
  fi
  VERIFY_RC=0
  log "Stage: rclone_verify -> OK"
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

  # rclone must be configured BEFORE the lock can be taken, because the lock is
  # itself an object in R2. A failure here is fatal: without a working rclone we
  # can neither back up nor report anything meaningful.
  configure_rclone

  # --- Acquire the distributed lock BEFORE reading/modifying the chain state. --
  # Two concurrent runs must never read the same state, capture overlapping
  # binlog ranges, and then both advance the state.
  log "[DEBUG] ===== R2 LOCK DIAGNOSTIC ====="
log "[DEBUG] R2_BUCKET=${R2_BUCKET}"
log "[DEBUG] R2_PATH=${R2_PATH}"
log "[DEBUG] BACKUP_LOCK_REMOTE=${BACKUP_LOCK_REMOTE}"
log "[DEBUG] BACKUP_STATE_REMOTE=${BACKUP_STATE_REMOTE}"

log "[DEBUG] Listing R2 state directory:"
rclone --config "${RCLONE_CONFIG:-}" -vv lsf \
  "remote:${R2_BUCKET}/${R2_PATH%/}/state/" \
  || warn "[DEBUG] Unable to list R2 state directory"

log "[DEBUG] Checking lock object:"
rclone --config "${RCLONE_CONFIG:-}" -vv lsjson \
  "remote:${BACKUP_LOCK_REMOTE}" \
  || warn "[DEBUG] Lock object does not exist or cannot be read"

log "[DEBUG] ===== END R2 LOCK DIAGNOSTIC ====="

set_stage "lock_acquire"
  
  set_stage "lock_acquire"
  log "Stage: lock_acquire"
  if ! acquire_lock; then
    warn "Another backup run currently holds the distributed lock (remote:${BACKUP_LOCK_REMOTE})."
    warn "Exiting without touching the backup chain; the next scheduled run will retry."
    exit "$EXIT_LOCK_HELD"
  fi
  # Release the lock on ANY exit path (success, failure, or unexpected signal).
  trap cleanup_on_exit EXIT
  log "Stage: lock_acquire -> OK"

  # Load the persisted policy state from R2 BEFORE deciding the backup type.
  set_stage "backup_state"
  log "Stage: backup_state (started)"
  load_state
  log "Stage: backup_state -> OK"

  # Decide: FULL or INCREMENTAL. There is NO path that runs both in one run.
  set_stage "backup_type_detection"
  log "Stage: backup_type_detection"
  determine_backup_type
  local decided_type="$DECIDED_TYPE"
  log "Stage: backup_type_detection -> ${decided_type}"

  if [[ "$decided_type" == "full" ]]; then
    log "Incremental backup skipped because today is a full-backup day."
    run_full_backup
    FULL_BACKUP_RC=0
    report_stage_rc "full_backup" "$FULL_BACKUP_RC"

    upload_and_verify "$BACKUP_DIR"

    COMPLETED_AT="$(now_utc)"
    VERIFIED_AT="$(now_utc)"

    set_stage "report_success"
    log "Stage: report_success (started)"
    # Capture the report's own return code so the exit diagnosis can distinguish
    # "the report was rejected" from "the report could not be delivered".
    local success_report_rc=0
    report_now "success" || success_report_rc=$?
    REPORT_RC="$success_report_rc"
    report_stage_rc "report_success" "$REPORT_RC"
    if [[ "$REPORT_RC" -ne 0 ]]; then
      # The backup EXISTS and is uploaded/verified; only the report failed, so
      # we must NOT mark the backup failed and must NOT delete it (it can be
      # reconciled later). State is NOT advanced, so the next run repeats a FULL
      # rather than resuming from an unreported base.
      warn "Backup succeeded and was verified, but PUPTracker reporting failed; the backup is retained for reconciliation."
      if [[ "${REPORT_CONFLICT:-0}" -eq 1 ]]; then
        log_exit_diagnosis "failed" "report conflict (HTTP 409); backup retained, state not advanced"
        exit "$EXIT_REPORT_CONFLICT"
      fi
      log_exit_diagnosis "failed" "success report not accepted (rc=${REPORT_RC}); backup retained, state not advanced"
      exit "$EXIT_REPORT_FAILED"
    fi
    log "Stage: report_success -> OK"

    # ONLY NOW advance state: this full becomes the new base, and it also resets
    # the incremental binlog anchor to this full's consistent boundary. If the
    # full had no binlog anchor (binlog disabled) the anchor is stored empty so
    # a later incremental cannot mis-resume.
    set_stage "state_update"
    if ! lock_still_owned; then
      warn "Refusing to persist state: this run no longer owns the backup lock."
      log_exit_diagnosis "failed" "backup lock lost before state update"
      exit 1
    fi
    local state_rc=0
    update_state \
      "$BACKUP_NAME" \
      "$COMPLETED_AT" \
      "$STORAGE_PATH" \
      "${BINLOG_FILE_END:-}" \
      "${BINLOG_POSITION_END:-0}" \
      "${BINLOG_FILE_END:-}" \
      "${BINLOG_POSITION_END:-0}" || state_rc=$?
    STATE_UPDATE_RC="$state_rc"
    report_stage_rc "state_update" "$STATE_UPDATE_RC"
    if [[ "$STATE_UPDATE_RC" -ne 0 ]]; then
      # The backup is uploaded, verified and reported, but the chain bookkeeping
      # is now untrustworthy: operators cannot know which FULL is the base.
      warn "Backup state could not be persisted; the backup chain bookkeeping is not trustworthy."
      warn "The uploaded backup was retained. The next run will detect the state problem and recover safely (by taking a new FULL)."
      log_exit_diagnosis "failed" "backup_state.json could not be persisted"
      exit 1
    fi

    set_stage "done"
    log "Backup completed (FULL) and reported to PUPTracker."
    exit 0
  fi

  # --- INCREMENTAL branch. ---
  log "Full backup not due."

  # The state anchor files: the binlog boundary values used for THIS run come
  # from the loaded state (start) and the acquired boundary (end). On success we
  # advance ONLY the binlog boundary; the full base is unchanged.
  run_incremental_backup
  report_stage_rc "incremental_backup" 0

  upload_and_verify "$BINLOG_DIR"

  COMPLETED_AT="$(now_utc)"
  VERIFIED_AT="$(now_utc)"

  set_stage "report_success"
  log "Stage: report_success (started)"
  local inc_report_rc=0
  report_now "success" || inc_report_rc=$?
  REPORT_RC="$inc_report_rc"
  report_stage_rc "report_success" "$REPORT_RC"
  if [[ "$REPORT_RC" -ne 0 ]]; then
    warn "Backup succeeded and was verified, but PUPTracker reporting failed; the backup is retained for reconciliation."
    if [[ "${REPORT_CONFLICT:-0}" -eq 1 ]]; then
      log_exit_diagnosis "failed" "report conflict (HTTP 409); backup retained, state not advanced"
      exit "$EXIT_REPORT_CONFLICT"
    fi
    log_exit_diagnosis "failed" "success report not accepted (rc=${REPORT_RC}); backup retained, state not advanced"
    exit "$EXIT_REPORT_FAILED"
  fi
  log "Stage: report_success -> OK"

  # Advance ONLY the binlog boundary. The full base is carried forward verbatim.
  set_stage "state_update"
  if ! lock_still_owned; then
    warn "Refusing to persist state: this run no longer owns the backup lock."
    log_exit_diagnosis "failed" "backup lock lost before state update"
    exit 1
  fi
  local inc_state_rc=0
  update_state \
    "$ST_LAST_FULL_NAME" \
    "$ST_LAST_FULL_COMPLETED_AT" \
    "$ST_LAST_FULL_STORAGE_PATH" \
    "$BINLOG_FILE_END" \
    "$BINLOG_POSITION_END" \
    "$BINLOG_FILE_END" \
    "$BINLOG_POSITION_END" || inc_state_rc=$?
  STATE_UPDATE_RC="$inc_state_rc"
  report_stage_rc "state_update" "$STATE_UPDATE_RC"
  if [[ "$STATE_UPDATE_RC" -ne 0 ]]; then
    warn "Backup state could not be persisted; the incremental chain position is not trustworthy."
    warn "The uploaded incremental was retained. The next run will detect the state problem and re-capture from the last known-good position."
    log_exit_diagnosis "failed" "backup_state.json could not be persisted (incremental)"
    exit 1
  fi

  set_stage "done"
  log "Backup completed (INCREMENTAL) and reported to PUPTracker."
  exit 0
}

# Run main() only when executed directly (not when sourced for testing).
# See the BACKUP_SOURCED note near the top: `BASH_SOURCE[0] == $0` alone is not
# sufficient because `bash -c 'source "$0" ...' <file>` also satisfies it, so an
# explicit opt-out is honoured here too.
if [[ "${BASH_SOURCE[0]}" == "$0" && "${BACKUP_SOURCED:-0}" != "1" ]]; then
  main "$@"
fi