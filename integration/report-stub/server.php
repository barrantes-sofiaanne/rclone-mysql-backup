<?php
/**
 * Minimal PUPTracker backup-report webhook STUB for the integration harness.
 *
 * This is NOT the production PUPTracker endpoint. It mimics only the parts of
 * the reporting contract the backup container depends on:
 *
 *   POST /
 *     Authorization: Bearer <BACKUP_REPORT_TOKEN>
 *     Content-Type: application/json
 *     { status, backup_name, backup_type, checksum, storage_path, ... }
 *
 * Behaviour:
 *   - 401 with a specific, non-secret `error` code when authentication fails:
 *       missing_authorization         no Authorization header was received
 *       invalid_authorization_scheme  the header was not `Bearer <token>`
 *       invalid_token                 the Bearer token did not match
 *       token_not_configured          the stub has no expected token at all
 *   - 409 when a DIFFERENT checksum was already recorded for the same
 *     backup_name (an integrity conflict, mirroring the documented contract).
 *   - 200 with the stored record otherwise (idempotent by backup_name).
 *   - 503 when FORCE_FAIL=1, to simulate a reporting outage.
 *   - 405 for a non-POST request to `/`.
 *
 * TOKEN SOURCE (this is the fix for the "401 with a correct token" symptom):
 * the stub resolves the expected token from its OWN process environment first,
 * then from a file:
 *   1. `REPORT_TOKEN_FILE`   optional explicit path to a token file
 *   2. `REPORT_TOKEN`        preferred environment variable
 *   3. `BACKUP_REPORT_TOKEN` accepted alias (what the backup container uses)
 *   4. `/var/store/token`    legacy file used by older harness versions
 * Reading the environment matters: when the token is handed to the stub as a
 * deployment variable it is ALREADY in the process environment. The old stub
 * read ONLY the file, so the harness had to inject the file out-of-band
 * (`docker exec ... printf ... > /var/store/token`), giving TWO independent
 * token sources that could silently disagree and produce 401s even though both
 * services had been given the same value.
 *
 * OUTER-WHITESPACE NORMALISATION: both the expected and the presented token are
 * stripped of leading/trailing INVISIBLE characters (space, tab, CR, LF, VT, FF,
 * NUL) before comparison. A secret piped or pasted into a service variable very
 * commonly carries a trailing `\n` (e.g. `echo "$TOKEN" | railway variable set
 * --stdin ...`). curl drops a trailing CR/LF from a header itself but NOT a
 * trailing space, so normalising BOTH sides is what makes them comparable. Only
 * OUTER whitespace is normalised: the content is still compared exactly with
 * `hash_equals`, so authentication is NOT weakened and a wrong token is still
 * rejected.
 *
 * SECRETS: the token is never logged, never echoed, and never written into a
 * response body. The only token-derived values reported are non-reversible
 * diagnostics: LENGTH, SOURCE, and whether outer whitespace was present.
 *
 * ENDPOINTS:
 *   POST /              the reporting webhook
 *   GET  /__stub/health safe, non-secret readiness snapshot (never returns the
 *                       token); reports the resolved token source, token length,
 *                       and how many reports have been recorded.
 *
 * Every accepted request is appended to <store>/reports.jsonl so the harness
 * can assert on what the container actually reported.
 *
 * Run with PHP's built-in server:
 *   php -S 0.0.0.0:8080 server.php
 */

declare(strict_types=1);

/**
 * Characters that are invisible and are only ever present by accident when a
 * secret is piped or pasted. Used for OUTER-whitespace normalisation only.
 */
function invisible_mask(): string
{
    // space, tab, CR, LF, vertical tab, form feed, NUL
    return " \t\r\n\x0b\x0c\0";
}

/**
 * The directory holding the token file and the recorded reports.
 *
 * Overridable with REPORT_STORE_DIR so the harness can run several isolated stub
 * instances side by side, and so the stub is testable without root privileges.
 */
function store_dir(): string
{
    $dir = env_token('REPORT_STORE_DIR');
    if ($dir === '') {
        $dir = '/var/store';
    }
    $trimmed = rtrim($dir, '/');

    return $trimmed === '' ? '/' : $trimmed;
}

/** Absolute path of the recorded-reports file. */
function reports_file(): string
{
    return store_dir() . '/reports.jsonl';
}

/** Resolve the request path (without query string), always starting with "/". */
function request_path(): string
{
    $uri = (string) ($_SERVER['REQUEST_URI'] ?? '/');
    $path = parse_url($uri, PHP_URL_PATH);
    if (!is_string($path) || $path === '') {
        return '/';
    }

    return $path;
}

/** Emit a JSON response and stop. Never include a secret in $body. */
function json_out(int $status, array $body): void
{
    if (!headers_sent()) {
        header('Content-Type: application/json');
    }
    http_response_code($status);
    echo json_encode($body, JSON_UNESCAPED_SLASHES);
    exit;
}

/** Read a token from an environment variable, returning '' when unset/empty. */
function env_token(string $name): string
{
    $value = getenv($name);
    if ($value === false || $value === '') {
        return '';
    }

    return (string) $value;
}

/** Read a token from a file, returning '' when missing/unreadable/empty. */
function file_token(string $path): string
{
    if ($path === '' || !is_readable($path)) {
        return '';
    }
    $raw = @file_get_contents($path);
    if ($raw === false) {
        return '';
    }

    return (string) $raw;
}

/**
 * Resolve the expected token and where it came from.
 *
 * The returned `raw` value MUST NOT be emitted in a response or a log line.
 *
 * @return array{raw: string, source: string}
 */
function resolve_expected_token(): array
{
    $explicitFile = trim(env_token('REPORT_TOKEN_FILE'));
    if ($explicitFile !== '') {
        $token = file_token($explicitFile);
        if ($token !== '') {
            return ['raw' => $token, 'source' => 'env:REPORT_TOKEN_FILE'];
        }
    }

    // The environment is authoritative: it is what a deployment variable
    // actually becomes inside the container.
    foreach (['REPORT_TOKEN', 'BACKUP_REPORT_TOKEN'] as $name) {
        $token = env_token($name);
        if ($token !== '') {
            return ['raw' => $token, 'source' => 'env:' . $name];
        }
    }

    $defaultFile = store_dir() . '/token';
    $token = file_token($defaultFile);
    if ($token !== '') {
        return ['raw' => $token, 'source' => 'file:' . $defaultFile];
    }

    return ['raw' => '', 'source' => 'none'];
}

/**
 * The raw Authorization header as received, or null when it was not sent.
 *
 * PHP's built-in server populates HTTP_AUTHORIZATION directly; Apache/CGI often
 * needs the getallheaders() fallback, and some proxies populate
 * REDIRECT_HTTP_AUTHORIZATION.
 */
function authorization_header(): ?string
{
    foreach (['HTTP_AUTHORIZATION', 'REDIRECT_HTTP_AUTHORIZATION'] as $key) {
        if (isset($_SERVER[$key]) && $_SERVER[$key] !== '') {
            return (string) $_SERVER[$key];
        }
    }

    foreach (['getallheaders', 'apache_request_headers'] as $fn) {
        if (!function_exists($fn)) {
            continue;
        }
        foreach ((array) $fn() as $name => $value) {
            if (strcasecmp((string) $name, 'Authorization') === 0 && $value !== '') {
                return (string) $value;
            }
        }
    }

    return null;
}

/**
 * Split an Authorization header into scheme + credential.
 *
 * @return array{scheme: string, credential: string}
 */
function split_authorization(string $header): array
{
    $trimmed = trim($header, invisible_mask());
    if ($trimmed === '') {
        return ['scheme' => '', 'credential' => ''];
    }

    $parts = preg_split('/\s+/', $trimmed, 2);

    return [
        'scheme' => (string) ($parts[0] ?? ''),
        'credential' => (string) ($parts[1] ?? ''),
    ];
}

/**
 * Non-secret diagnostics for a rejected token.
 *
 * Deliberately limited to which source the expected token came from, the LENGTH
 * of each side, and whether either side carried outer whitespace. None of these
 * reveals the token content, and together they are exactly what distinguishes
 * "wrong value" from "right value with a trailing newline".
 *
 * @return array<string, mixed>
 */
function token_diagnostics(string $expectedNorm, string $presentedNorm): array
{
    return [
        'expected_token_source' => (string) ($GLOBALS['STUB_TOKEN_SOURCE'] ?? 'unknown'),
        'expected_token_length' => strlen($expectedNorm),
        'presented_token_length' => strlen($presentedNorm),
        'expected_had_outer_whitespace' => (bool) ($GLOBALS['STUB_EXPECTED_HAD_WS'] ?? false),
        'presented_had_outer_whitespace' => (bool) ($GLOBALS['STUB_PRESENTED_HAD_WS'] ?? false),
    ];
}

header('Content-Type: application/json');

$path = request_path();
$method = (string) ($_SERVER['REQUEST_METHOD'] ?? 'GET');

// ---------------------------------------------------------------------------
// Safe readiness/diagnostic endpoint. Never returns the token.
// ---------------------------------------------------------------------------
if ($path === '/__stub/health') {
    $resolved = resolve_expected_token();
    $expectedRaw = (string) $resolved['raw'];
    $expectedNorm = trim($expectedRaw, invisible_mask());

    json_out(200, [
        'ok' => true,
        'stub' => 'puptracker-report-stub',
        'php_version' => PHP_VERSION,
        'token_configured' => $expectedNorm !== '',
        'token_source' => (string) $resolved['source'],
        'token_length' => strlen($expectedNorm),
        'token_had_outer_whitespace' => $expectedRaw !== $expectedNorm,
        'store_dir' => store_dir(),
        'store_writable' => is_dir(store_dir()) ? is_writable(store_dir()) : false,
        'reports_recorded' => is_readable(reports_file())
            ? count(file(reports_file(), FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [])
            : 0,
        'force_fail' => getenv('FORCE_FAIL') === '1',
    ]);
}

// ---------------------------------------------------------------------------
// The reporting webhook is POST-only.
// ---------------------------------------------------------------------------
if ($method !== 'POST') {
    json_out(405, ['error' => 'method_not_allowed']);
}

// Optional artificial outage. Checked BEFORE auth so an outage is reported as
// an outage rather than as a credential problem.
if (getenv('FORCE_FAIL') === '1') {
    json_out(503, ['error' => 'simulated_reporting_outage']);
}

// ---------------------------------------------------------------------------
// Authentication. Each failure mode gets its own non-secret error code so a 401
// is directly diagnosable from the backup container's logs.
// ---------------------------------------------------------------------------
$resolved = resolve_expected_token();
$expectedRaw = (string) $resolved['raw'];
$expectedNorm = trim($expectedRaw, invisible_mask());
$GLOBALS['STUB_TOKEN_SOURCE'] = (string) $resolved['source'];
$GLOBALS['STUB_EXPECTED_HAD_WS'] = $expectedRaw !== $expectedNorm;

$auth = authorization_header();

if ($auth === null || trim($auth, invisible_mask()) === '') {
    json_out(401, ['error' => 'missing_authorization']);
}

$parsed = split_authorization($auth);
$presentedRaw = $parsed['credential'];
$presentedNorm = trim($presentedRaw, invisible_mask());
$GLOBALS['STUB_PRESENTED_HAD_WS'] = $presentedRaw !== $presentedNorm;

if (strcasecmp($parsed['scheme'], 'Bearer') !== 0) {
    json_out(401, ['error' => 'invalid_authorization_scheme']);
}

if ($expectedNorm === '') {
    // The stub itself has no expected token, so nothing can ever authenticate.
    json_out(401, ['error' => 'token_not_configured']);
}

if (!hash_equals($expectedNorm, $presentedNorm)) {
    json_out(401, ['error' => 'invalid_token'] + token_diagnostics($expectedNorm, $presentedNorm));
}

// ---------------------------------------------------------------------------
// Payload validation.
// ---------------------------------------------------------------------------
$raw = (string) file_get_contents('php://input');
$payload = json_decode($raw, true);
if (!is_array($payload)) {
    json_out(400, ['error' => 'invalid_json']);
}

$name = (string) ($payload['backup_name'] ?? '');
$checksum = (string) ($payload['checksum'] ?? '');
if ($name === '') {
    json_out(422, ['error' => 'backup_name_required']);
}

if (!is_dir(store_dir())) {
    @mkdir(store_dir(), 0777, true);
}

// Idempotency check: same name + same checksum is a no-op; same name + a
// DIFFERENT checksum is a conflict.
$reports = reports_file();
if (is_readable($reports)) {
    $lines = file($reports, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [];
    foreach ($lines as $line) {
        $existing = json_decode($line, true);
        if (!is_array($existing) || ($existing['backup_name'] ?? null) !== $name) {
            continue;
        }
        $existingChecksum = (string) ($existing['checksum'] ?? '');
        if ($checksum !== '' && $existingChecksum !== '' && $existingChecksum !== $checksum) {
            json_out(409, ['error' => 'checksum_conflict_for_backup_name']);
        }
        json_out(200, ['success' => true, 'idempotent' => true]);
    }
}

// NOTE: the Authorization header is deliberately NOT recorded.
$record = $payload + [
    'received_at' => gmdate('Y-m-d\TH:i:s\Z'),
    'remote_addr' => $_SERVER['REMOTE_ADDR'] ?? 'unknown',
];
file_put_contents($reports, json_encode($record, JSON_UNESCAPED_SLASHES) . "\n", FILE_APPEND | LOCK_EX);

json_out(200, ['success' => true, 'backup_name' => $name]);
