#!/usr/bin/env bash
#
# ---------------------------------------------------------------------------
# integration/report-stub/test_stub.sh
# ---------------------------------------------------------------------------
# Tests for the disposable PUPTracker reporting STUB only.
#
# These tests run the REAL stub (integration/report-stub/server.php) under PHP's
# built-in server and drive it with REAL HTTP requests, so they verify the
# actual authentication behaviour rather than a re-implementation of it.
#
# Covered:
#   - authenticated POST returns 200
#   - missing Authorization header      -> 401 {"error":"missing_authorization"}
#   - non-Bearer scheme                 -> 401 {"error":"invalid_authorization_scheme"}
#   - wrong Bearer token                -> 401 {"error":"invalid_token"}
#   - correct Bearer token              -> 200
#   - token accepted when the EXPECTED side has outer whitespace (trailing \n)
#   - token accepted when the PRESENTED side has outer whitespace (trailing space)
#   - missing/empty store token         -> 401 {"error":"token_not_configured"}
#   - GET returns 405
#   - FORCE_FAIL=1 returns 503
#   - no response body or recorded report ever contains the token
#   - the health endpoint never contains the token
#
# Requires: php (>= 8.0) and curl. Skips cleanly when either is unavailable.
#
# Usage:  bash integration/report-stub/test_stub.sh
# ---------------------------------------------------------------------------

set -uo pipefail

# NOTE: the directory variable is deliberately NOT called STUB_DIR. The parent
# suite (test_reporting.sh) EXPORTS STUB_DIR as its own curl-double temp dir; if
# this suite reused that name it would inherit the parent's value (or clobber
# it), and any artifact written relative to it would land in the repository.
STUB_SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_PHP="$STUB_SRC_DIR/server.php"

PASS=0
FAIL=0
SKIP=0

pass() { PASS=$((PASS + 1)); printf 'ok   - %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL - %s\n' "$1"; }
skip() { SKIP=$((SKIP + 1)); printf 'SKIP - %s\n' "$1"; }

assert_eq() { # desc expected actual
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (expected [$2] got [$3])"; fi
}
assert_contains() { # desc haystack needle
  if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1 (missing [$3])"; fi
}
assert_not_contains() { # desc haystack needle
  if [[ "$2" != *"$3"* ]]; then pass "$1"; else fail "$1 (unexpectedly contains [$3])"; fi
}

echo "== report-stub tests =="

if ! command -v php >/dev/null 2>&1; then
  skip "php is not installed; the stub tests cannot run"
  echo
  echo "PASS: $PASS   FAIL: $FAIL   SKIP: $SKIP"
  exit 0
fi
if ! command -v curl >/dev/null 2>&1; then
  skip "curl is not installed; the stub tests cannot run"
  echo
  echo "PASS: $PASS   FAIL: $FAIL   SKIP: $SKIP"
  exit 0
fi

# The stub must at least be syntactically valid before we try to serve it.
if ! php -l "$SERVER_PHP" >/dev/null 2>&1; then
  fail "server.php has a PHP syntax error"
  php -l "$SERVER_PHP" 2>&1 | sed 's/^/    /'
  echo
  echo "PASS: $PASS   FAIL: $FAIL   SKIP: $SKIP"
  exit 1
fi
pass "server.php passes php -l"

# ---------------------------------------------------------------------------
# Test isolation: clear any inherited token variables.
#
# This suite may be invoked FROM another suite (test_reporting.sh) that exports
# BACKUP_REPORT_TOKEN. The stub deliberately prefers its process environment over
# the token file, so an inherited variable would override the per-case value and
# make the cases non-deterministic. Each case sets exactly the variable it means
# to test.
# ---------------------------------------------------------------------------
unset REPORT_TOKEN BACKUP_REPORT_TOKEN REPORT_TOKEN_FILE

# ---------------------------------------------------------------------------
# Test fixtures. The token is a TEST-ONLY literal; it is never a real secret and
# it deliberately looks distinctive so a leak into a response is obvious.
# ---------------------------------------------------------------------------
TOKEN='stub-test-token-9b7c4e21'
WRONG_TOKEN='stub-test-token-WRONG-0000'

WORK="$(mktemp -d)"
STORE="$WORK/store"
mkdir -p "$STORE"
PORT="${STUB_TEST_PORT:-18091}"

cleanup() {
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  if [[ -n "${SECOND_PID:-}" ]]; then
    kill "$SECOND_PID" 2>/dev/null || true
    wait "$SECOND_PID" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# serve <port> <env assignment>... -> starts the stub and waits for readiness.
# The parent environment is scrubbed of every token variable so ONLY the
# assignments passed here (plus the store dir) reach the stub.
start_stub() {
  local port="$1"; shift
  local log="$WORK/server-$port.log"
  env -u REPORT_TOKEN -u BACKUP_REPORT_TOKEN -u REPORT_TOKEN_FILE \
    "$@" REPORT_STORE_DIR="$STORE" \
    php -S "127.0.0.1:${port}" "$SERVER_PHP" >"$log" 2>&1 &
  SERVER_PID=$!

  # Wait for readiness by polling a non-POST route (405 = server is up).
  local i
  for i in $(seq 1 40); do
    if curl -s -o /dev/null -m 2 "http://127.0.0.1:${port}/__stub/health" 2>/dev/null; then
      return 0
    fi
    sleep 0.25
  done
  return 1
}

# post <port> [curl args...] -> prints "<http_code>|<body>"
http_post() {
  local port="$1"; shift
  local out
  out="$(curl -s -m 5 -o "$WORK/body" -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' \
    --data-binary '{"backup_name":"b1","backup_type":"full","checksum":"abc"}' \
    "$@" "http://127.0.0.1:${port}/" 2>/dev/null || echo "000")"
  printf '%s|%s' "$out" "$(cat "$WORK/body" 2>/dev/null || true)"
}

# ---------------------------------------------------------------------------
# Case 1: the token arrives in the stub's OWN environment (the Railway-style
# wiring) and the caller presents it correctly.
# ---------------------------------------------------------------------------
if start_stub "$PORT" REPORT_TOKEN="$TOKEN"; then
  pass "stub started with REPORT_TOKEN in its environment"
else
  fail "stub did not become ready"
  echo
  echo "PASS: $PASS   FAIL: $FAIL   SKIP: $SKIP"
  exit 1
fi

resp="$(http_post "$PORT" -H "Authorization: Bearer $TOKEN")"
assert_eq "authenticated POST returns 200" "200" "${resp%%|*}"
assert_contains "200 body confirms success" "${resp#*|}" '"success":true'

# ---------------------------------------------------------------------------
# Case 2: missing Authorization header.
# ---------------------------------------------------------------------------
resp="$(http_post "$PORT")"
assert_eq "missing Authorization returns 401" "401" "${resp%%|*}"
assert_contains "missing header reports missing_authorization" "${resp#*|}" '"error":"missing_authorization"'

# ---------------------------------------------------------------------------
# Case 3: Authorization header that is not a Bearer scheme.
# ---------------------------------------------------------------------------
resp="$(http_post "$PORT" -H "Authorization: Basic $TOKEN")"
assert_eq "non-Bearer scheme returns 401" "401" "${resp%%|*}"
assert_contains "wrong scheme reports invalid_authorization_scheme" "${resp#*|}" '"error":"invalid_authorization_scheme"'

# A bare token with no scheme at all must also be rejected (not treated as Bearer).
resp="$(http_post "$PORT" -H "Authorization: $TOKEN")"
assert_eq "scheme-less token returns 401" "401" "${resp%%|*}"
assert_contains "scheme-less token reports invalid_authorization_scheme" "${resp#*|}" '"error":"invalid_authorization_scheme"'

# ---------------------------------------------------------------------------
# Case 4: correct scheme, WRONG token.
# ---------------------------------------------------------------------------
resp="$(http_post "$PORT" -H "Authorization: Bearer $WRONG_TOKEN")"
assert_eq "wrong Bearer token returns 401" "401" "${resp%%|*}"
assert_contains "wrong token reports invalid_token" "${resp#*|}" '"error":"invalid_token"'
# The diagnostic must stay non-secret: length yes, value no.
assert_contains "wrong token response includes the expected token LENGTH" "${resp#*|}" "\"expected_token_length\":${#TOKEN}"
assert_not_contains "wrong token response does not echo the expected token" "${resp#*|}" "$TOKEN"
assert_not_contains "wrong token response does not echo the presented token" "${resp#*|}" "$WRONG_TOKEN"

# ---------------------------------------------------------------------------
# Case 5: correct scheme, correct token, lowercase "bearer" and mixed case must
# all be accepted (scheme comparison is case-insensitive by RFC 7235).
# ---------------------------------------------------------------------------
resp="$(http_post "$PORT" -H "Authorization: bearer $TOKEN")"
assert_eq "lowercase 'bearer' scheme is accepted" "200" "${resp%%|*}"
resp="$(http_post "$PORT" -H "Authorization: BeArEr $TOKEN")"
assert_eq "mixed-case 'BeArEr' scheme is accepted" "200" "${resp%%|*}"

# ---------------------------------------------------------------------------
# Case 6: OUTER-WHITESPACE tolerance on BOTH sides.
# This is the regression test for the observed symptom: a token that carried a
# trailing newline / space made two identical-looking values compare unequal.
# ---------------------------------------------------------------------------
kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true

EOL_PORT=$((PORT + 1))
# The EXPECTED token (in the stub's own environment) has a trailing newline.
if start_stub "$EOL_PORT" REPORT_TOKEN="$(printf '%s\n' "$TOKEN")"; then
  resp="$(http_post "$EOL_PORT" -H "Authorization: Bearer $TOKEN")"
  assert_eq "expected token with a trailing newline still matches" "200" "${resp%%|*}"
  resp="$(http_post "$EOL_PORT" -H "Authorization: Bearer $WRONG_TOKEN")"
  assert_eq "a WRONG token is still rejected when the expected side has whitespace" "401" "${resp%%|*}"
else
  skip "could not start the stub with a newline-bearing token"
fi
kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true

# The PRESENTED token has trailing spaces. (curl does not strip a trailing
# space from a header value, only CR/LF, so the stub must normalise it itself.)
sp_port=$((PORT + 2))
if start_stub "$sp_port" REPORT_TOKEN="$TOKEN"; then
  resp="$(http_post "$sp_port" -H "Authorization: Bearer ${TOKEN}   ")"
  assert_eq "presented token with trailing spaces still matches" "200" "${resp%%|*}"
  # Only OUTER whitespace is ignored: an internal difference must still fail.
  resp="$(http_post "$sp_port" -H "Authorization: Bearer ${TOKEN}-x")"
  assert_eq "a token with extra non-space characters is still rejected" "401" "${resp%%|*}"
else
  skip "could not start the stub for the presented-whitespace case"
fi
kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Case 7: legacy token FILE support (older harness wiring) still works, and an
# EMPTY token must fail closed with token_not_configured.
# ---------------------------------------------------------------------------
printf '%s' "$TOKEN" > "$STORE/token"
file_port=$((PORT + 3))
if start_stub "$file_port"; then
  resp="$(http_post "$file_port" -H "Authorization: Bearer $TOKEN")"
  assert_eq "legacy token file is still honoured" "200" "${resp%%|*}"
else
  skip "could not start the stub for the legacy token-file case"
fi
kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true

: > "$STORE/token"
empty_port=$((PORT + 4))
if start_stub "$empty_port"; then
  resp="$(http_post "$empty_port" -H "Authorization: Bearer $TOKEN")"
  assert_eq "an empty configured token returns 401" "401" "${resp%%|*}"
  assert_contains "empty token reports token_not_configured" "${resp#*|}" '"error":"token_not_configured"'
else
  skip "could not start the stub for the empty-token case"
fi
kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true
rm -f "$STORE/token"

# ---------------------------------------------------------------------------
# Case 8: method + outage behaviour, and the health endpoint.
# ---------------------------------------------------------------------------
method_port=$((PORT + 5))
if start_stub "$method_port" REPORT_TOKEN="$TOKEN"; then
  # GET (and a non-POST method generally) is 405. Note this is intentionally
  # checked before auth: a method error is not a credential error.
  code="$(curl -s -o "$WORK/body" -w '%{http_code}' "http://127.0.0.1:${method_port}/" 2>/dev/null || echo 000)"
  assert_eq "GET returns 405" "405" "$code"
  assert_contains "405 body reports method_not_allowed" "$(cat "$WORK/body" 2>/dev/null || true)" '"error":"method_not_allowed"'

  health="$(curl -s -m 5 "http://127.0.0.1:${method_port}/__stub/health" 2>/dev/null || true)"
  assert_contains "health endpoint reports the token as configured" "$health" '"token_configured":true'
  assert_contains "health endpoint reports the token length" "$health" "\"token_length\":${#TOKEN}"
  assert_not_contains "health endpoint never returns the token" "$health" "$TOKEN"
  assert_contains "health endpoint reports the token source" "$health" '"token_source":"env:REPORT_TOKEN"'
else
  skip "could not start the stub for the method/health cases"
fi
kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true

fail_port=$((PORT + 6))
if start_stub "$fail_port" REPORT_TOKEN="$TOKEN" FORCE_FAIL=1; then
  resp="$(http_post "$fail_port" -H "Authorization: Bearer $TOKEN")"
  assert_eq "FORCE_FAIL=1 returns 503 even with a valid token" "503" "${resp%%|*}"
  assert_contains "outage body reports simulated_reporting_outage" "${resp#*|}" '"error":"simulated_reporting_outage"'
else
  skip "could not start the stub in outage mode"
fi
kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Case 9: payload contract still enforced (unchanged behaviour, guarded so a
# future edit cannot silently drop these responses).
# ---------------------------------------------------------------------------
payload_port=$((PORT + 7))
if start_stub "$payload_port" REPORT_TOKEN="$TOKEN"; then
  code="$(curl -s -o "$WORK/body" -w '%{http_code}' -X POST \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    --data-binary 'not-json' "http://127.0.0.1:${payload_port}/" 2>/dev/null || echo 000)"
  assert_eq "malformed JSON returns 400" "400" "$code"

  code="$(curl -s -o "$WORK/body" -w '%{http_code}' -X POST \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    --data-binary '{"checksum":"abc"}' "http://127.0.0.1:${payload_port}/" 2>/dev/null || echo 000)"
  assert_eq "missing backup_name returns 422" "422" "$code"

  # Idempotency: same name + same checksum is a no-op 200.
  curl -s -o /dev/null -X POST -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' \
    --data-binary '{"backup_name":"dup","checksum":"abc"}' \
    "http://127.0.0.1:${payload_port}/" >/dev/null 2>&1 || true
  resp="$(http_post "$payload_port" -H "Authorization: Bearer $TOKEN")"
  assert_eq "repeat report for the same backup is idempotent (200)" "200" "${resp%%|*}"

  # A DIFFERENT checksum for the same name is an integrity conflict.
  code="$(curl -s -o "$WORK/body" -w '%{http_code}' -X POST \
    -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
    --data-binary '{"backup_name":"b1","checksum":"DIFFERENT"}' \
    "http://127.0.0.1:${payload_port}/" 2>/dev/null || echo 000)"
  assert_eq "conflicting checksum returns 409" "409" "$code"
else
  skip "could not start the stub for the payload-contract cases"
fi
kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Case 10: the token must never appear in a response body or a recorded report.
# ---------------------------------------------------------------------------
BODIES="$(cat "$WORK"/body 2>/dev/null || true)"
assert_not_contains "no response body ever contains the token" "$BODIES" "$TOKEN"

RECORDED="$(cat "$STORE/reports.jsonl" 2>/dev/null || true)"
assert_not_contains "recorded reports never contain the token" "$RECORDED" "$TOKEN"
assert_not_contains "recorded reports never contain the Authorization header" "$RECORDED" "Bearer"
# The recorded report must still contain the real payload fields.
assert_contains "recorded reports contain the payload" "$RECORDED" '"backup_name"'

LOGS="$(cat "$WORK"/server-*.log 2>/dev/null || true)"
assert_not_contains "stub server logs never contain the token" "$LOGS" "$TOKEN"

echo
echo "=========================================="
echo "PASS: $PASS   FAIL: $FAIL   SKIP: $SKIP"
echo "=========================================="
[[ "$FAIL" -eq 0 ]] || exit 1
