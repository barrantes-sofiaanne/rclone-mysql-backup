# Next-stage validation: real Docker + real MySQL 8.4 integration testing

This document covers the **next stage of validation** for the independent
`rclone-mysql-backup` chain: proving the _actual_ Docker image works against a
_real_ MySQL 8.4 database with binary logging, a real S3-compatible object
store, and a real (stubbed) reporting endpoint.

It is a **test plan + runbook**, not a change to the production backup schedule.

---

## 0. Honest scope: which test runs where

There are two distinct ways to reach "the real image runs against real MySQL",
and they are **not** interchangeable. Do not blur them.

| Capability                                 | `integration/run.sh` (needs Docker) | Railway disposable project                             |
| ------------------------------------------ | ----------------------------------- | ------------------------------------------------------ |
| Build the repo `Dockerfile`                | yes (`docker build`)                | yes (Railway builds it)                                |
| Deploy the real image                      | yes (`docker run`)                  | yes (`railway up`)                                     |
| Real MySQL 8.4 + binlog                    | yes (`mysql:8.4` container)         | yes (Railway MySQL) — **only if `log_bin=ON`**, see §3 |
| Run FULL / INCREMENTAL                     | yes, all phases automated           | yes, drive `entrypoint.sh` via `railway ssh`           |
| Restore test                               | yes, automated                      | manual, inside the deployed container                  |
| Failure injection (dump/report/lock)       | yes, automated                      | partial                                                |
| **Runs inside a deployed Railway service** | **NO — no Docker daemon**           | n/a                                                    |

> **Critical:** `integration/run.sh` requires a Docker daemon. A Railway service
> container does **not** have one, so the harness itself **cannot** run inside
> Railway. On Railway you get the same real-image coverage by driving the
> deployed container's own `/entrypoint.sh` (which _is_ the image under test).

The automated shell suite (`test_reporting.sh`) is a **mock** suite. It stubs
every external tool and never builds the image. A green run from it is **not**
integration testing — see §8.

---

## 1. Absolute safety rules

Do not do any of the following while running these tests:

- Do not point the test at `MySQL-52uF`, the production PUPTracker service, the
  production R2 backup prefix, the production `backup_state.json`, or the
  production backup cron.
- Do not use production credentials for integration testing.
- Do not change `BINLOG_ARCHIVE_*`, disable binary logging, or touch the
  `MySQL-PITR` bucket / Railway PITR configuration.
- Do not deploy the backup job to the production scheduled cron.

The harness enforces most of this mechanically (§4). Use it.

---

## 2. Prerequisites

- Docker on the machine that runs `integration/run.sh` (this host has **no**
  Docker, so the harness reports the container phases as NOT EXECUTED here).
- Railway CLI for the Railway path. This host has `railway 5.52.0` installed but
  **not authenticated**:

  ```bash
  railway login          # interactive; opens a browser / device-code flow
  railway whoami
  ```

  `railway login` is interactive and **must be run by you**. It cannot be
  scripted, and no credential should ever be pasted into a chat or a file.

- The repository available to the target Docker/Railway environment (Railway
  needs a Git remote).

---

## 3. What the Dockerfile must provide (verified statically)

`Dockerfile` already installs and then **build-fails** if any required runtime
command is missing:

```
bash mydumper rclone curl date find sha256sum sed awk grep sort \
wc head mktemp tr dirname gzip mysql mysqlbinlog
```

Notes that matter for testing:

- Base image is `mydumper/mydumper:v0.21.3-2` (AlmaLinux 9, `dnf`) with
  `rclone` copied in. It is **RPM/dnf**, not apt/apk.
- `mysql` + `mysqlbinlog` come from the MySQL _client_ package; the server is
  never installed.
- `myloader` is used by the restore procedure and ships with the same package as
  `mydumper`, so it is present in the image even though it is not in the
  entrypoint's required-command list.
- `check_tools()` in `entrypoint.sh` re-verifies the same list at runtime, so a
  mis-built image fails at **start** with a named tool instead of mid-run.

---

## 4. Path A — run the harness on a Docker host (recommended)

```bash
# 1. Harness logic only (no Docker needed) — always safe:
bash integration/run.sh selftest

# 2. Full run (needs Docker):
bash integration/run.sh
```

Run a subset of phases:

```bash
bash integration/run.sh preflight build up mysql-check
bash integration/run.sh full inc1 inc2
PHASES="preflight build up mysql-check full" bash integration/run.sh
```

Phases:

| Phase         | Proves                                                                                                       |
| ------------- | ------------------------------------------------------------------------------------------------------------ |
| `selftest`    | the harness's own safety guards (no Docker)                                                                  |
| `preflight`   | Docker present, env is disposable, Dockerfile verifies every tool                                            |
| `build`       | the real image builds, and actually contains each required binary                                            |
| `up`          | disposable MySQL 8.4 + object store + report stub come up, baseline seeded                                   |
| `mysql-check` | `SELECT VERSION()`, `log_bin`, `binlog_format`, `SHOW BINARY LOGS`, 8.4 status statement, REPLICATION grants |
| `full`        | real MyDumper dump → upload → verify → report → state advances                                               |
| `inc1`        | TRUE_INCREMENTAL #1 captured from the FULL anchor                                                            |
| `inc2`        | TRUE_INCREMENTAL #2 resumes from INC1's boundary, same FULL base                                             |
| `rotation`    | an incremental spanning **multiple** binlog files                                                            |
| `restore`     | FULL + every incremental replayed into a disposable DB, row-for-row compared                                 |
| `purged`      | a purged start binlog fails safely and does **not** advance state                                            |
| `safety`      | dump failure, reporting failure, lock contention                                                             |
| `report`      | summary                                                                                                      |

Useful knobs:

```bash
KEEP_ENV=1 bash integration/run.sh            # leave containers up for inspection
TEST_R2_ENDPOINT=https://<acct>.r2.cloudflarestorage.com \
  R2_BUCKET=<test-bucket> R2_PATH=integration-test/mysql-backup \
  R2_ACCESS_KEY_ID=... R2_SECRET_ACCESS_KEY=... bash integration/run.sh full
```

### The disposable-environment guard

The harness **refuses to run** when the configuration looks like production:

- `BACKUP_REPORT_URL` contains `puptvs.com`;
- `MYSQL_HOST` looks like `mysql-52uf*`, `*.railway.internal`, or
  `proxy.rlwy.net`;
- `R2_PATH` has no test marker (`test` / `integration` / `sandbox`).

`ALLOW_NON_DISPOSABLE=1` downgrades the refusal to a recorded failure, so it can
never be silently bypassed.

### What the harness does _not_ prove

- It does not prove anything about the **production** MySQL, R2, or PUPTracker.
- `restore` compares row counts + per-row `CRC32` digests over the dataset's
  columns. That is strong evidence the chain is correct, but it is not a
  byte-level proof of every storage-engine internal.
- The reporting endpoint is a **stub** that implements the documented contract
  (200 / 401 / 409 / 5xx), not the production PUPTracker service.

---

## 4a. Troubleshooting: the report stage returns HTTP 401

The stub is the only component that can be tested for real without Docker, so it
has its own suite:

```bash
bash integration/report-stub/test_stub.sh      # real HTTP against the real stub
```

It is also run automatically by `bash test_reporting.sh` (the main suite) and by
`bash integration/run.sh selftest`.

### Ask the stub what it thinks its token is

The stub exposes a **non-secret** readiness endpoint. It never returns the token;
it returns the token _source_ and _length_, which is what makes a mismatch
diagnosable:

```bash
# from inside the docker network / deployed service:
wget -qO- http://<report-stub-host>:8080/__stub/health
```

```json
{
  "ok": true,
  "token_configured": true,
  "token_source": "env:REPORT_TOKEN",
  "token_length": 43,
  "token_had_outer_whitespace": false,
  "reports_recorded": 0,
  "force_fail": false
}
```

Compare `token_length` with the length of the token the backup service sends
(`${#BACKUP_REPORT_TOKEN}`). Equal lengths with a 401 means the _values_ differ;
different lengths means the two services were given different strings (often a
trailing newline on one side — see below).

### The four 401 causes, by error code

The stub returns a distinct, non-secret code so a 401 is self-explaining. The
entrypoint logs the HTTP status; read the stub's body for the code.

| `error`                        | Meaning                               | Fix                                                                       |
| ------------------------------ | ------------------------------------- | ------------------------------------------------------------------------- |
| `missing_authorization`        | no `Authorization` header arrived     | a proxy stripped it, or the request did not reach the stub's webhook path |
| `invalid_authorization_scheme` | header was not `Bearer <token>`       | the client sent `Basic` or a bare token                                   |
| `invalid_token`                | scheme was right, token differed      | the two services hold different values (compare `token_length`)           |
| `token_not_configured`         | the stub has no expected token at all | set the stub's `REPORT_TOKEN`/`BACKUP_REPORT_TOKEN`                       |

`invalid_token` responses also include `expected_token_source`,
`expected_token_length`, `presented_token_length`, and
`expected/presented_had_outer_whitespace`. None of these reveals the token.

### Token source and outer whitespace

The stub resolves its expected token from **its own process environment** first:

1. `REPORT_TOKEN_FILE` (path to a token file)
2. `REPORT_TOKEN` (preferred)
3. `BACKUP_REPORT_TOKEN` (alias — what the backup container uses)
4. `/var/store/token` (legacy file)

> **Root cause of the observed "both services have the same token" 401.**
>
> The stub originally read the token **only** from the file `/var/store/token`.
> Nothing in a deployed service ever writes that file — it was a harness-only
> bootstrap path. So on Railway the stub had **no expected token at all**, and
> consequently returned 401 for _every_ request, including the correct one.
> Setting `BACKUP_REPORT_TOKEN` on the stub service had **no effect**, because
> the old stub never read that variable. That is precisely why the two services
> could hold the "same" token and still fail: the stub was not reading the
> variable it had been given.
>
> The harness masked this by injecting the file out-of-band
> (`docker exec ... printf ... > /var/store/token`) — a **second, independent
> token source** that could silently disagree with the service variable. That
> injection also ended in `|| true`, so a failed write was invisible and left the
> stub tokenless again.
>
> The stub now reads its **own process environment** first
> (`REPORT_TOKEN` / `BACKUP_REPORT_TOKEN`), so there is exactly **one** source of
> truth, and the file is only a legacy fallback.
>
> A second, independent contributing cause is outer whitespace: a secret piped or
> pasted into a variable very commonly carries a trailing newline
> (`echo "$TOKEN" | railway variable set ... --stdin`). `curl` strips a trailing
> CR/LF from a header itself but **not** a trailing space, and the old stub
> trimmed only the file side. Both sides are now normalised (outer whitespace
> only). See the checklist below to confirm which of the two you hit.

Both sides now strip **outer** invisible characters (space, tab, CR, LF, VT, FF,
NUL) before comparing. This matters because a secret piped or pasted into a
service variable very commonly carries a trailing newline
(`echo "$TOKEN" | railway variable set ... --stdin`). `curl` drops a trailing
CR/LF from a header itself but **not** a trailing space, so normalising _both_
sides is required for the values to be comparable.

**Authentication is not weakened:** only outer whitespace is normalised; the
content is still compared exactly with `hash_equals`, and a wrong token is still
rejected (`invalid_token`). A token containing internal whitespace or extra
characters still fails.

### Checklist for a 401 in a disposable environment

1. `GET /__stub/health` — is `token_configured` true, and does `token_length`
   match `${#BACKUP_REPORT_TOKEN}` in the backup service?
2. Check which service holds which variable. The stub needs `REPORT_TOKEN` (or
   `BACKUP_REPORT_TOKEN`); the backup service needs `BACKUP_REPORT_TOKEN`.
3. Re-set the stub's variable **using `--stdin`** to avoid a trailing newline,
   then redeploy, then re-read `/__stub/health`.
4. Confirm the URL the backup service uses is the stub's address, not a typo:
   `http://<report-stub-host>:8080/`.
5. If the code is `missing_authorization`, check for a proxy stripping the
   header rather than a token problem.

---

## 4b. Troubleshooting: `status=1` after a successful-looking report

A log like this is **not** a reporting problem:

```
[backup] PUPTracker report accepted (HTTP 200) for full_2026-09-11_181340.
[backup] Released distributed backup lock.
[backup] EXIT: stage=full_backup, status=1
```

### The HTTP 200 does NOT mean the backup succeeded

The reporter returns **HTTP 200 for both** a success report and a failure
report. A 200 only means _the report was delivered_. The backup's own outcome is
carried in the payload's `status` field, which is why the log line now names it:

```
[backup] PUPTracker report (backup status 'failed') accepted (HTTP 200) for full_...
```

If that line says `backup status 'failed'`, the run failed and reported its
failure successfully. Do not read the 200 as success.

### Read the exit diagnosis

Every run now ends with an explicit, non-secret diagnosis naming each stage's
return code, so the failing stage never has to be inferred:

```
[backup][warn] EXIT-DIAGNOSIS: final_status=failed stage=full_backup last_stage_status=none
[backup][warn] EXIT-DIAGNOSIS: backup_type=full backup_name=full_2026-09-11_181340
[backup][warn] EXIT-DIAGNOSIS: full_backup_rc=1 upload_rc=n/a verify_rc=n/a report_rc=0 state_update_rc=n/a lock_release_rc=0
[backup][warn] EXIT-DIAGNOSIS: binlog_anchor_usable=no anchor_file='<empty>' anchor_position='<empty>'
[backup][warn] EXIT-DIAGNOSIS: reason=exit_status=1 error='mydumper failed to produce a logical database snapshot.'
```

How to read it:

| Field                     | Meaning                                                                 |
| ------------------------- | ----------------------------------------------------------------------- |
| `final_status`            | `success` or `failed` — the job's actual outcome                        |
| `stage`                   | the stage that was executing when the failure occurred                  |
| `last_stage_status`       | the last stage that recorded its own return code                        |
| `full_backup_rc`          | MyDumper dump return code (`1` = dump failed or produced nothing)       |
| `upload_rc` / `verify_rc` | R2 upload and presence/size verification                                |
| `report_rc`               | PUPTracker report (`0` = the report was delivered, whatever it carried) |
| `state_update_rc`         | `backup_state.json` persistence                                         |
| `lock_release_rc`         | lock release (cleanup — never the cause of a failure)                   |
| `binlog_anchor_usable`    | `yes` / `no` / `disabled` — see below                                   |
| `error_message`           | the sanitized failure reason (never a credential)                       |

### `status=1` at `stage=full_backup` means the DUMP failed

`stage=full_backup` is set at the start of `run_full_backup()`. The full backup
only reaches `stage=mysql_binlog_check`, and then `report_success`, **after** the
dump has produced a non-empty directory. So `stage=full_backup` with
`full_backup_rc=1` means MyDumper failed — or produced **zero files**. A dump
directory that exists but is empty is treated as a failed dump, because an empty
directory is not a restorable baseline.

### A missing binlog anchor is NOT a failure

`binlog_anchor_usable=no` is reported but **does not** fail the FULL. The dump is
still a valid logical baseline, so it is uploaded, verified, reported as
`success`, and persisted. What it _does_ mean is that this FULL **cannot serve as
the base for a TRUE_INCREMENTAL**: the persisted `last_binlog_file` is empty, so
the next incremental refuses to run and requires a new FULL.

Confirm from the state object:

```bash
rclone --config "$RCLONE_CONFIG" cat "remote:${R2_BUCKET}/${R2_PATH}/state/backup_state.json"
```

- `"last_binlog_file": "binlog.NNNNNN"` → the chain can advance by incremental.
- `"last_binlog_file": ""` → a new FULL with an anchor is required before any
  incremental can be captured.

### Troubleshooting quick table

| Symptom                                             | Cause                                    | Action                                                                              |
| --------------------------------------------------- | ---------------------------------------- | ----------------------------------------------------------------------------------- |
| `status=1`, `stage=full_backup`, `full_backup_rc=1` | MyDumper failed, or dumped 0 files       | check the MyDumper error above the diagnosis; verify the DB is reachable            |
| `status=1`, `report_rc` non-zero, exit code 3 or 4  | backup OK, report not accepted           | fix reporting; the backup is retained and state was **not** advanced                |
| `status=1`, `state_update_rc=1`                     | `backup_state.json` could not be written | fix R2 write access; the next run takes a fresh FULL                                |
| exit code 5, `stage=lock_acquire`                   | another run holds the lock               | nothing was touched; the next run retries                                           |
| `status=0`, `binlog_anchor_usable=no`               | FULL has no usable anchor                | take a FULL whose `metadata` contains a binlog position before testing incrementals |

**No stage's return code silently becomes the job's exit status.** Each stage's
own rc is captured explicitly, the EXIT trap records the status _before_ running
cleanup, and cleanup re-asserts it — so releasing the lock can never mask or
change a failure.

---

## 5. Path B — disposable Railway project

Railway is used because the target host has no Docker. This creates a
**throwaway project** that never touches production.

> Everything below operates on a **new** project. `railway link` to the
> production project is expressly forbidden for these steps.

### 5.1 Create the throwaway project (MODIFIES RAILWAY — new resources only)

```bash
# Create and enter a NEW, clearly-named throwaway project.
mkdir -p /tmp/rmb-integration && cd /tmp/rmb-integration
railway init --name rmb-integration-sandbox

# Add a DISPOSABLE MySQL (this is not MySQL-52uF).
railway add --database mysql

# Link this directory to the sandbox project's service as you create each one.
railway status
```

Add the supporting services (each is a new, disposable service):

```bash
# Reporting stub (the harness's own server.php; NOT production PUPTracker).
railway add --service report-stub --repo <owner>/<repo>
#   → set its start command to: php -S 0.0.0.0:8080 /app/server.php
#   → point its build at integration/report-stub

# Object store (disposable MinIO; exercises the real rclone S3 path).
railway add --service minio --image minio/minio:latest
#   → start command: server /data --console-address ":9001"
#   → attach a volume mounted at /data

# The service under test: the real backup image, built from the repo Dockerfile.
railway add --service rmb-test --repo <owner>/<repo>
```

### 5.2 Deploy the real image

```bash
cd <path to rclone-mysql-backup-main>
railway link --project rmb-integration-sandbox      # NEVER the production project
railway up --service rmb-test --detach              # builds the repo Dockerfile
railway logs --service rmb-test
```

`railway up` builds and runs the repository's `Dockerfile`, so the running
container **is** the artifact under test.

### 5.3 Configure test-only variables

Set the MySQL triple from the disposable database, and a **test-scoped** R2 path
and report URL. Never reuse production values.

```bash
railway variable set --service rmb-test \
  MYSQL_HOST='${{MySQL.MYSQLHOST}}' \
  MYSQL_PORT='${{MySQL.MYSQLPORT}}' \
  MYSQL_USER='${{MySQL.MYSQLUSER}}' \
  MYSQL_PASSWORD='${{MySQL.MYSQLPASSWORD}}' \
  MYSQL_DATABASE='${{MySQL.MYSQLDATABASE}}'

railway variable set --service rmb-test \
  R2_ENDPOINT='http://minio.railway.internal:9000' \
  R2_BUCKET=test-backups \
  R2_PATH=integration-test/mysql-backup \
  R2_PROVIDER=Other

railway variable set --service rmb-test \
  BACKUP_REPORT_URL='http://report-stub.railway.internal:8080/' \
  MYSQLBINLOG_SERVER_ID=424242001 \
  BACKUP_FULL_INTERVAL_DAYS=14

# Secrets: use --stdin so they never appear in the command line or shell history.
printf '%s' "$TEST_R2_ACCESS_KEY_ID"     | railway variable set --service rmb-test --stdin R2_ACCESS_KEY_ID
printf '%s' "$TEST_R2_SECRET_ACCESS_KEY" | railway variable set --service rmb-test --stdin R2_SECRET_ACCESS_KEY
printf '%s' "$TEST_REPORT_TOKEN"         | railway variable set --service rmb-test --stdin BACKUP_REPORT_TOKEN
```

> `railway variable` prints raw values with `--kv`. Never capture that output
> into a file, a log, or a chat.

### 5.4 Verify MySQL 8.4 + binary logging — STOP condition

Run this **before** any backup test:

```bash
railway connect mysql     # opens a shell on the DISPOSABLE database

SELECT VERSION();
SHOW VARIABLES LIKE 'log_bin';
SHOW VARIABLES LIKE 'binlog_format';
SHOW BINARY LOGS;
```

Required:

| Check              | Required value    |
| ------------------ | ----------------- |
| version            | `8.4.x`           |
| `log_bin`          | `ON`              |
| `binlog_format`    | `ROW`             |
| `SHOW BINARY LOGS` | at least one file |

**If binary logging is unavailable, STOP.** Do not fake it, do not substitute a
logical dump for an incremental, and do not touch `BINLOG_ARCHIVE_*` or the
MySQL configuration to "fix" it. Record `full` as runnable and
`inc1`/`inc2`/`rotation`/`purged` as **NOT EXECUTED**.

### 5.5 Run the real backup phases

The deployed container already contains the real `entrypoint.sh`, `mydumper`,
`mysql`, `mysqlbinlog`, `rclone`, `gzip`, and `bash`. Run the phases with:

```bash
railway ssh --service rmb-test

# inside the container:
#   FULL
/entrypoint.sh ; echo "rc=$?"

# ...then make identifiable changes from the MySQL shell (see below)...
```

Drive the chain deliberately:

1. **FULL**: run `/entrypoint.sh`; confirm the log shows
   `Backup type selected: FULL`, a MyDumper dump, a manifest SHA-256, upload
   verification, and `PUPTracker report accepted`.
2. **INC1**: insert an identifiable row, then run `/entrypoint.sh` again; expect
   `Backup type selected: INCREMENTAL` and `Stage: binlog_capture -> OK`.
3. **INC2**: insert another row, run again; confirm the log's
   `Incremental base binlog:` position equals the position saved by INC1.
4. **Rotation**: insert, `FLUSH BINARY LOGS;`, insert, `FLUSH BINARY LOGS;`,
   insert, then run again; confirm `Incremental range spans N binary log
file(s)` with `N >= 2`.
5. **Restore**: inside the same container (it ships `myloader`), copy the chain
   down with `rclone`, `myloader` the newest FULL into a **separate disposable
   database**, then gunzip + apply each `binlog_apply.sql.gz` oldest-first.
   Compare against the source.
6. **Purged binlog**: `PURGE BINARY LOGS TO '<newer file>';` then run again and
   confirm the run **fails**, names the purged log, says a new FULL is required,
   and leaves `state/backup_state.json` byte-identical.

Verify the chain state at any time:

```bash
railway ssh --service rmb-test
rclone --config "$RCLONE_CONFIG" cat "remote:${R2_BUCKET}/${R2_PATH}/state/backup_state.json"
```

> Keep `R2_PATH` test-scoped for every command, or the disposable environment
> could read/advance a production chain state.

### 5.6 Cleanup (DESTRUCTIVE — never run automatically)

```bash
railway delete --project rmb-integration-sandbox     # prompts; add --yes to skip
```

This deletes the throwaway project and its disposable MySQL/MinIO data. It does
**not** touch `MySQL-52uF`, `MySQL-PITR`, or the production backup service. Do
not run it until the results are recorded — it also deletes the test evidence.

---

## 6. Deliberately NOT executed

| Test                                | Why                                                                                                                            |
| ----------------------------------- | ------------------------------------------------------------------------------------------------------------------------------ |
| Real PUPTracker integration         | only the production webhook exists; sending fake backups there is forbidden by §1. Covered by the stub + mocked tests instead. |
| Production R2 verification          | production bucket/prefix must not be used for testing.                                                                         |
| Production Railway PITR interaction | read-only requirement in §1; the independent chain is validated on its own.                                                    |
| Real Railway deploy/run             | requires interactive `railway login` and creates billable resources; must be performed by you.                                 |

---

## 7. Reporting the result

Use the distinction below; never collapse them into "fully tested".

| Letter | Category                                         |
| ------ | ------------------------------------------------ |
| A      | Automated shell/unit tests (`test_reporting.sh`) |
| B      | Docker image build                               |
| C      | Real MySQL 8.4 integration                       |
| D      | Real `mysqlbinlog` execution                     |
| E      | Real binlog rotation                             |
| F      | Real object-store upload/verify                  |
| G      | Real restore                                     |
| H      | Real PUPTracker reporting                        |

Mark each **PASS / FAIL / NOT EXECUTED** individually, and give exact
`PASS / FAIL / TOTAL` counts for A.

---

## 8. Automated suite status on this host

`bash -n entrypoint.sh`, `bash -n test_reporting.sh`, and
`bash test_reporting.sh` all pass here. This host has **no Docker**, no
`mysql`/`mysqlbinlog`/`mydumper`/`rclone`, so categories **B–H are NOT
EXECUTED** from this machine; only **A** was executed.
