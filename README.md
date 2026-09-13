[![Deploy on Railway](https://railway.app/button.svg)](https://railway.app/template/7GOA4r?referralCode=xsbY2R)

# Backup MySQL to Cloudflare R2

This Docker app runs a single time, dumping a MySQL database with [mydumper] and using [rclone] to push that data to [Cloudflare R2](https://developers.cloudflare.com/r2/).

You schedule the container to run at whatever interval you want backups to happen.

## Architecture: two independent recovery mechanisms

This repository is the **independent** backup system for the PUPTracker
Violation System database. It deliberately runs **alongside** — and never
replaces or interferes with — Railway's managed PITR:

| Mechanism                                        | What it produces                                                                      | Where it lives              |
| ------------------------------------------------ | ------------------------------------------------------------------------------------- | --------------------------- |
| **Railway PITR** (managed, separate)             | A continuous server-side binary-log archive                                           | Railway `MySQL-PITR` bucket |
| **This container** (independent R2 backup chain) | `mydumper` FULL dumps **plus** true `mysqlbinlog` incrementals, verified and reported | Cloudflare R2               |

They are **separate recovery paths**:

- This container does **not** read, modify, disable, or delete anything owned by
  Railway PITR. It never changes MySQL server configuration, never touches
  `BINLOG_ARCHIVE_*` variables, and never reads Railway's archive to decide what
  to do.
- This container needs `log_bin=ON` on the server (which Railway PITR also
  requires), but it consumes the binary logs **independently** by reading the
  binlog status/listing itself and pulling the files it needs.
- Restoring from the R2 chain (see [Restoring from a backup](#restoring-from-a-backup))
  does **not** require Railway PITR, and vice-versa.

## Backup policy: FULL + TRUE binary-log incremental

The container implements a full/incremental policy (default: a **FULL every 14
days**, a **TRUE binlog incremental on every other run**):

| Run             | What it does                                                  | `backup_type` |
| --------------- | ------------------------------------------------------------- | ------------- |
| Full-backup day | Complete `mydumper` logical dump                              | `full`        |
| Any other day   | MySQL **binary-log** archive since the last recorded position | `incremental` |

The decision is made from the state object stored in R2
(`<R2_BUCKET>/<R2_PATH>/state/backup_state.json`), which records only the most recent
**successful, verified, reported and persisted** FULL:

- **No valid FULL base at all** → the run is a **FULL**.
- The latest successful FULL is **`BACKUP_FULL_INTERVAL_DAYS` (default `14`) or
  more days old** → the run is a **FULL**.
- **Otherwise** → the run is a **TRUE_INCREMENTAL**.
- A FULL-backup day runs **only** the FULL — there is no code path that runs both
  a FULL and an incremental in a single execution.

Two rules are absolute:

- **A FULL only becomes the incremental base after the whole chain succeeds**:
  dump → metadata/checksum → upload → remote verification → PUPTracker success
  report → state persisted. A failed, unverified, unreported or unpersisted FULL
  **never** becomes the base and does **not** disturb the previous valid base.
- **An INCREMENTAL only advances the saved binlog position after the whole chain
  succeeds.** If any stage fails, the previous state is left **byte-identical**,
  so the same range is safely re-captured next time. State is never partially
  updated.

A **logical `mydumper` snapshot is never labelled `incremental`**. "TRUE
incremental" in this document always means _captured MySQL binary-log events_.
The container **never** silently substitutes a logical dump for an incremental:
if binary logging is unavailable, the required binlog was purged, or there is a
gap in the retained range, the run **fails safely** and reports the failure.

### Important: MySQL binary logging must be enabled

TRUE incrementals require the MySQL server to have binary logging enabled:

```sql
-- MySQL 8.4+: SHOW BINARY LOG STATUS is the modern statement.
SHOW BINARY LOG STATUS;              -- current binlog file + position
SHOW BINARY LOGS;                    -- the retained binlog files
SHOW VARIABLES LIKE 'log_bin';       -- must return ON
SHOW VARIABLES LIKE 'binlog_format'; -- ROW, STATEMENT, or MIXED
```

`SHOW MASTER STATUS` is **deprecated in MySQL 8.4** in favour of
`SHOW BINARY LOG STATUS`. The container **prefers the 8.4 statement** and
**safely falls back** to `SHOW MASTER STATUS` on older servers; both are
normalized into the same internal representation, and a statement that is
accepted but returns no usable row also falls back.

If the server reports `log_bin = OFF`, this container **cannot** produce a true
incremental. It will **not** fabricate one — it reports `status=failed` with a
clear message and exits non-zero. **This container never changes the database
server configuration.** Binary logging must be enabled on the MySQL/Railway
service itself.

If a scheduled incremental day arrives and binary logging is unavailable, the
run fails until either (a) binlog is enabled server-side, or (b) the next
full-backup day, which always succeeds with a logical dump.

### Binlog boundary safety (how the range is captured)

An incremental is defined by two coordinates: a **start** (from the persisted
state) and an **end** (read from the server at capture time).

- **The start comes only from persisted state.** For an incremental it is the
  `last_binlog_file` / `last_binlog_position` written by the previous successful
  run. For a FULL, the anchor is the **consistent snapshot position mydumper
  recorded in its `metadata` file** — the dump and the binlog coordinate
  describe the same instant, which is what makes the chain gap-free. (Using a
  _post-dump_ boundary instead would silently lose everything written during the
  dump.)
- **The end is read with no table lock.** The container reads the current write
  point via `SHOW BINARY LOG STATUS` (falls back to `SHOW MASTER STATUS`). It
  deliberately does **not** use `FLUSH TABLES WITH READ LOCK`: binlog positions
  are monotonic, so recording the current position and later reading
  `[start, end]` is gap-free and duplicate-free even while writes continue —
  later events have positions beyond `end` and are picked up by the next
  incremental. Avoiding FTWRL also avoids requiring `RELOAD` and avoids
  unnecessary locking on a managed database.
- **Every file in the range is captured, in order.** The container walks the
  contiguous run of retained binlog files from `start` to `end`, so **binlog
  rotation is handled** — one incremental may legitimately span
  `binlog.000070 … binlog.000072`.
- **A gap is a hard failure, never a silent skip.** If the retained files are
  **not contiguous** (a file was purged mid-range), or the end file is no longer
  retained, the run aborts. Skipping a file would produce an incremental that
  _looks_ complete but is missing events — a silent data-loss bug — so it is
  refused outright.
- **A purged start also fails.** If the `start` binlog is gone, the chain is
  broken. The container **never** silently restarts from a newer file; it
  reports `status=failed` explaining that the chain is broken and that **a new
  FULL is required**.
- **A failed capture never advances state.** The packaged archive is re-read
  locally with `mysqlbinlog` before upload, so a truncated capture cannot be
  uploaded as if valid, and the saved position only moves after the whole chain
  (upload → verify → report → persist) succeeds.

### MySQL 8.4: how the FULL anchor is obtained

MySQL **8.4 removed `SHOW MASTER STATUS`** in favour of `SHOW BINARY LOG STATUS`.
That makes the snapshot anchor dependent on *which statement the dumper issues*,
and the pinned `mydumper/mydumper:v0.21.3-2` picks between them by classifying
the server from `@@version_comment` / `@@version`:

- If the classification succeeds (the text contains `mysql`, `percona`,
  `mariadb`, `tidb`, `dolt` or `google`), mydumper recognises 8.4 and uses
  `SHOW BINARY LOG STATUS`.
- If **no** product token matches (e.g. a distro build reporting
  `@@version_comment = (Ubuntu)`), it falls back to the removed
  `SHOW MASTER STATUS`, gets
  `ERROR 1064 ... near 'MASTER STATUS'`, logs
  `Couldn't get master position`, and writes its `metadata` file with **no
  `[source]` section at all** — so the FULL records **no anchor** and every later
  incremental correctly refuses to run.

The container therefore passes mydumper an explicit
`--server-version <product>-<major>.<minor>.<patch>`, **derived from the live
server** rather than hard-coded:

1. If `@@version_comment`/`@@version` contains a known product token, that product
   is used with the server's own `major.minor.patch`.
2. Otherwise the server is probed **behaviourally**: only MySQL 8.4+ answers
   `SHOW BINARY LOG STATUS`, so a successful probe confirms the MySQL family
   without guessing from strings.
3. If neither establishes the server family, no override is passed and mydumper
   auto-detects exactly as before.

Because the value comes from the server, it keeps working across upgrades and for
MariaDB/Percona builds instead of pinning one vendor's version into the image.

> **This only changes which statement mydumper uses to read the coordinate.** It
> cannot invent an anchor: if the position is still unavailable, no `[source]`
> section is written and the safety rule applies unchanged (empty anchor ⇒
> incremental refuses to run).

The `raw` capture path likewise uses the **MySQL** client's portable form. The
`--result-dir` option is *MariaDB-only* — MySQL's `mysqlbinlog` rejects it with
`unknown option '--result-dir'` — so the container runs `mysqlbinlog` with the
destination directory as its working directory and lets it create a file named
after the binlog.

### Diagnosing a missing anchor

When an anchor cannot be read, the log shows exactly why (never a secret):

```text
[backup] mydumper version: mydumper v0.21.3-2, built against MySQL 8.4.8 ...
[backup] mydumper server-version override: mysql-8.4.10
[backup] mydumper command: mydumper --defaults-file=/tmp/tmp.XXXX --host ... --source-data --server-version mysql-8.4.10 -C -c --clear -o backup
...
[backup] DIAG anchor: mydumper_version='mydumper v0.21.3-2, ...'
[backup] DIAG anchor: metadata_path='backup/metadata' exists=yes
[backup] DIAG anchor: source_section_present=no
[backup] DIAG anchor: parsed_SOURCE_LOG_FILE='<none>' parsed_SOURCE_LOG_POS='<none>'
[backup] DIAG anchor: active_metadata_keys=[config] quote-character=BACKTICK
[backup] DIAG mysql: version='8.4.10-...' version_comment='(Ubuntu)' log_bin='1' binlog_format='ROW'
[backup] DIAG mysql: gtid_mode='OFF'
```

`source_section_present=no` points at the **server-side** statement (a dumper
version/classification problem); `yes` with an empty `parsed_*` points at the
**parser**. The override line shows whether a `--server-version` was derived.

### Environment variables (backup policy)

| Variable                    | Default      | Purpose                                                                                                                        |
| --------------------------- | ------------ | ------------------------------------------------------------------------------------------------------------------------------ |
| `BACKUP_FULL_INTERVAL_DAYS` | `14`         | Days after the last successful FULL before a new FULL is forced.                                                               |
| `BACKUP_BINLOG_ENABLED`     | `true`       | When `false`, FULL backups still work but a due incremental **fails safely** instead of pretending.                            |
| `BACKUP_BINLOG_VERIFY`      | `true`       | When `true`, verify `log_bin=ON` (and a usable format) before any incremental.                                                 |
| `BACKUP_TIMEZONE`           | `UTC`        | Display timezone only; all stored timestamps are UTC.                                                                          |
| `MYSQLBINLOG_SERVER_ID`     | `2147483000` | Replication-client id for `mysqlbinlog --read-from-remote-server`. **Must be unique per consumer** (see below).                |
| `BINLOG_FETCH_STRATEGY`     | `raw`        | `raw` = pull binlogs with `mysqlbinlog --raw` (needs `REPLICATION SLAVE`); `copy` = read them from a mounted binlog directory. |
| `BINLOG_LOCAL_DIR`          | _(empty)_    | Directory holding the server's binlog files; **required** when `BINLOG_FETCH_STRATEGY=copy`.                                   |
| `BACKUP_LOCK_ENABLED`       | `true`       | Enable the distributed lock that prevents two runs from modifying the chain concurrently.                                      |
| `BACKUP_LOCK_TTL_SECONDS`   | `21600` (6h) | Lock expiry. An **expired lock is taken over automatically**, so a crashed run can never wedge the chain.                      |

#### `MYSQLBINLOG_SERVER_ID` must be unique

`mysqlbinlog --read-from-remote-server` makes this process act as a
**replication client**, which requires a `server_id` that is unique among
**every** other binlog consumer on the server: a real replica, Railway's own
binlog archiving, and any concurrent backup. If two consumers use the same id,
the server disconnects one of them — which can **silently truncate** a capture.

Do **not** leave the default in place across multiple deployments. Give every
distinct consumer its own value in `1..4294967295`. An invalid (missing, zero,
non-numeric or out-of-range) value is rejected before any backup starts. The
server id is never a secret and is safe to log.

### Concurrent-execution protection

Two overlapping runs must never read the same state, capture **overlapping**
binlog ranges, and then both advance the state. Because the state lives in R2, a
container-local lock would not help — two _scheduled_ container runs can overlap
across different machines — so the lock is itself an **object in R2**, next to
the state:

```
$R2_BUCKET/$R2_PATH/state/backup.lock
```

How it behaves:

- **Acquired before the state is read or modified** — the lock is taken before
  `backup_state.json` is loaded, so the decision, the captured range and the
  write-back are all protected.
- **Created with `rclone copyto`**, which does **not** overwrite an existing
  object. That makes acquisition an atomic _create-if-absent_ (test-and-set) in
  R2; losing the race is a clean failure, not a partial write.
- **Carries an expiry** (`BACKUP_LOCK_TTL_SECONDS`, default 6h) and a random
  token identifying the holder.
- **Fails safely if another run is active:** the run exits `5` without touching
  the backup chain at all.
- **Stale locks are taken over automatically.** If the recorded expiry has
  passed, the holder is assumed dead, the lock is replaced and the run proceeds.
  A crashed container therefore **cannot permanently block future backups**.
- **Ownership is re-checked immediately before the state is written.** If
  another run took over an expired lock, this run aborts rather than writing
  state — so a stale take-over can never interleave two writers.
- **Released on exit** via an `EXIT` trap (covering success, failure and
  unexpected termination), and only deleted if this run still owns it — a run
  that lost ownership never deletes the new owner's lock.

Set `BACKUP_LOCK_ENABLED=false` only if you have an external guarantee that runs
cannot overlap.

## Setup

The container needs the environment variables related to MySQL:

- `MYSQL_HOST`: The host to connect to, for example `localhost` or `127.0.0.1`.
- `MYSQL_DATABASE`: The name of the database to dump.
- `MYSQL_PORT`: The port to connect to, defaults to `3306`
- `MYSQL_USER`: Username for MySQL
- `MYSQL_PASSWORD`: Password for MySQL

And these variables related to Cloudflare R2:

- `R2_ACCESS_KEY_ID` and `R2_SECRET_ACCESS_KEY`: An [S3-compatible access key](https://developers.cloudflare.com/r2/api/s3/tokens/)
- `R2_ENDPOINT`: The S3 API URL for your R2 account
- `R2_BUCKET`: The name of the bucket to upload to
- `R2_PATH`: A folder within the R2 bucket to upload to, defaults to `"mysql-backup"`

### PUPTracker reporting (required)

Every backup run is recorded in the PUPTracker Super Admin **Backup History**.
These two variables are **required**; the container refuses to run (exits
non-zero, no backup taken) if either is missing:

- `BACKUP_REPORT_URL`: The PUPTracker backup-report webhook, normally
  `https://puptvs.com/admin/super-admin/backups/report`
- `BACKUP_REPORT_TOKEN`: A shared secret that MUST equal the value PUPTracker
  has configured as its `BACKUP_REPORT_TOKEN`.

> **Security warning:** `BACKUP_REPORT_TOKEN` is a secret. Never commit it,
> never print it, and never add it to filenames, command-line arguments, URLs,
> or logs. Provide it only through the environment. The container never logs the
> token or the `Authorization` header it sends.

When reporting is configured, the container:

1. Loads the backup policy state from R2
   (`<R2_BUCKET>/<R2_PATH>/state/backup_state.json`).
2. Decides FULL vs INCREMENTAL from the most recent **successful, verified**
   FULL (never from a merely-attempted FULL).
3. Produces the backup:
   - **FULL** → `mydumper` logical dump.
   - **INCREMENTAL** → the binlog events since the last recorded position
     (via `mysqlbinlog`).
4. Computes metadata (file count, total size, and a deterministic SHA-256
   manifest checksum) and gives the run a unique name.
5. Uploads to a **unique** R2 path (see below).
6. Verifies the upload (object presence, count, and total size).
7. POSTs a JSON report to `BACKUP_REPORT_URL` using
   `Authorization: Bearer $BACKUP_REPORT_TOKEN`.
8. **Only after all of the above succeed** does it advance the saved backup
   state.

`backup_type` is `full` or `incremental` (legacy `daily_snapshot` records remain
readable and are still accepted by the reporter). A logical snapshot is **never**
reported as `incremental`.

#### Unique R2 backup paths

`R2_PATH` is treated as a base path. Every run uploads to a timestamped,
unique destination so previous backups are never overwritten:

```
$R2_BUCKET/$R2_PATH/full/YYYY/MM/DD/full_YYYY-MM-DD_HHMMSS/
$R2_BUCKET/$R2_PATH/incremental/YYYY/MM/DD/incremental_YYYY-MM-DD_HHMMSS/
$R2_BUCKET/$R2_PATH/state/backup_state.json
```

Example with `R2_PATH=mysql-backup`:

```
mysql-backup/full/2026/09/10/full_2026-09-10_020000/
mysql-backup/incremental/2026/09/11/incremental_2026-09-11_020000/
mysql-backup/state/backup_state.json
```

> Existing `daily_snapshot/…` objects are historical and are left untouched.

Each **incremental** directory also contains a machine-readable
`backup_metadata.json`:

```json
{
  "backup_type": "incremental",
  "backup_name": "incremental_2026-09-11_020000",
  "base_full_backup_name": "full_2026-09-10_020000",
  "base_full_storage_path": "mysql-backup/full/2026/09/10/full_2026-09-10_020000",
  "start_binlog_file": "binlog.000123",
  "start_binlog_position": 456789,
  "end_binlog_file": "binlog.000124",
  "end_binlog_position": 123456,
  "started_at": "2026-09-11T02:00:00Z",
  "completed_at": "2026-09-11T02:01:00Z"
}
```

It never contains credentials or tokens. Alongside the raw binlog files, each
incremental also ships `binlog_apply.sql.gz`, a validated SQL stream produced by
`mysqlbinlog` with the exact start/stop boundary.

#### Checksum / integrity reporting

The container builds a deterministic manifest of every generated file:

```
<SHA-256 of file>  <relative/path/file>
```

sorted by relative path, then reports the SHA-256 of that whole manifest as the
backup `checksum` (`checksum_algorithm=SHA-256`). This is a meaningful,
reproducible digest of the backup contents — never a random value.

#### R2 upload verification (honest scope)

After `rclone sync`, the container verifies the remote destination reports the
same **file count** and **total bytes** as the local backup directory (via
`rclone size --json`, which returns the authoritative remote object count and
total byte size as JSON: `{"count":N,"bytes":M,"sizeless":K}`). This confirms
the objects are present and are not missing/truncated.

This is **not** claimed to be full cryptographic verification of the remote
copy: rclone's R2 listing does not expose a trustworthy remote SHA-256 of every
object without an extra HEAD/GET round trip, and R2 does not surface the same
ETag guarantees as other S3 providers for multipart uploads. The authoritative
integrity digest is the local manifest SHA-256 reported as `checksum`; it is not
re-derived from the remote bytes in this step.

#### Failure reporting

- If `mydumper` or the R2 upload fails, the container attempts to POST a
  `status=failed` report (with a safe `error_message`) before exiting non-zero.
- Credentials are never included in the error message or logs.

> **HTTP 200 does not mean the backup succeeded.** PUPTracker (and the
> integration stub) answer **200 for both** a success report and a failure
> report — a 200 only means the report was _delivered_. The backup's outcome is
> the payload's `status` field, which is why the log line names it:
> `PUPTracker report (backup status 'failed') accepted (HTTP 200) for full_...`.

Every run also ends with a per-stage diagnosis so the failing stage is never
ambiguous:

```
[backup][warn] EXIT-DIAGNOSIS: final_status=failed stage=full_backup last_stage_status=none
[backup][warn] EXIT-DIAGNOSIS: full_backup_rc=1 upload_rc=n/a verify_rc=n/a report_rc=0 state_update_rc=n/a lock_release_rc=0
[backup][warn] EXIT-DIAGNOSIS: binlog_anchor_usable=no anchor_file='<empty>' anchor_position='<empty>'
[backup][warn] EXIT-DIAGNOSIS: reason=exit_status=1 error='mydumper failed to produce a logical database snapshot.'
```

`stage=full_backup` means the **dump** failed (MyDumper failed, or produced a
directory with zero files — an empty dump is not a restorable baseline). No
stage's return code silently becomes the job's exit status, and lock release
(cleanup) can never override it.

A **missing binlog anchor is not a failure**: the FULL is still reported and
persisted as a valid logical baseline (`binlog_anchor_usable=no`), but it cannot
serve as the base for a TRUE_INCREMENTAL — the next incremental refuses to run
and requires a new FULL. See
[docs/INTEGRATION_TESTING.md §4b](docs/INTEGRATION_TESTING.md) for the full
diagnosis table.

#### Successful backup but reporting failed

If the backup and upload **succeed** but the final HTTP report to PUPTracker
fails, the container logs
`Backup succeeded and was verified, but PUPTracker reporting failed` and exits
non-zero so Railway surfaces the reporting problem. It does **not** mark the
backup as failed and does **not** delete the uploaded backup — the objects are
retained so the run can be reconciled later. Because PUPTracker's endpoint is
idempotent by `backup_name`, re-running with the same name is safe and will not
create duplicate records. State is **not** advanced, so the next run takes a
fresh FULL rather than resuming from an unreported base.

#### Exit codes

| Code | Meaning                                                                                                                                                  |
| ---- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `0`  | The whole chain succeeded: backup + upload + verification + PUPTracker report + state persisted.                                                         |
| `1`  | A general failure (configuration, missing tool, dump, upload, verification, **state persistence**, …).                                                   |
| `3`  | The backup succeeded and was verified, but the PUPTracker **success report** failed. State was not advanced.                                             |
| `4`  | PUPTracker returned **HTTP 409**: a backup with this name already exists with a **different checksum** (an integrity conflict, not a transport problem). |
| `5`  | Another backup run currently holds the distributed lock. Nothing was touched; the next scheduled run retries.                                            |

> **State persistence is part of the success condition.** If the backup is
> uploaded, verified and reported but `backup_state.json` cannot be written, the
> job exits `1`. The backup itself is kept, but the chain bookkeeping is no
> longer trustworthy, so the next run deliberately starts from a new FULL
> instead of guessing. A failure to record the chain is never reported as a
> success.

#### Example payload (no real token)

```json
{
  "status": "success",
  "backup_name": "full_2026-09-10_020000",
  "backup_type": "full",
  "started_at": "2026-09-09T18:00:00Z",
  "completed_at": "2026-09-09T18:02:00Z",
  "destination": "Cloudflare R2",
  "backup_size": 123456789,
  "file_count": 42,
  "checksum": "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
  "checksum_algorithm": "SHA-256",
  "verified_at": "2026-09-09T18:02:01Z",
  "storage_path": "mysql-backup/full/2026/09/10/full_2026-09-10_020000"
}
```

An **incremental** payload additionally carries the recovery-chain metadata
(only when `backup_type=incremental`):

```json
{
  "status": "success",
  "backup_name": "incremental_2026-09-11_020000",
  "backup_type": "incremental",
  "base_backup_name": "full_2026-09-10_020000",
  "storage_path": "mysql-backup/incremental/2026/09/11/incremental_2026-09-11_020000",
  "binlog_file_start": "binlog.000123",
  "binlog_position_start": 456789,
  "binlog_file_end": "binlog.000124",
  "binlog_position_end": 123456
}
```

`BACKUP_REPORT_URL` and `BACKUP_REPORT_TOKEN` are **required**: if either is
missing the job fails fast with a clear, non-secret message and exits non-zero
rather than silently running a backup that cannot be reported.

### Railway-specific guide

> [!TIP]
> You can also [deploy MySQL with these backups enabled](https://railway.app/template/xNTYS8?referralCode=xsbY2R) if you don't have a database yet.

If you're running this container in Railway, you can use shared variables for all the MySQL variables (replace `MySQL` in each expression with the name of your database service):

- `MYSQL_HOST`: `${{MySQL.MYSQLHOST}}`
- `MYSQL_DATABASE`: `${{MySQL.MYSQL_DATABASE}}`
- `MYSQL_PORT`: `${{MySQL.MYSQLPORT}}`
- `MYSQL_USER`: `${{MySQL.MYSQLUSER}}`
- `MYSQL_PASSWORD`: `${{MySQL.MYSQLPASSWORD}}`

Then, in settings, set restart to never and input a cron schedule to backup as often as you'd like.

For PUPTracker reporting on Railway, add the shared/plain variables
`BACKUP_REPORT_URL` and `BACKUP_REPORT_TOKEN` (token must match PUPTracker's).

## Restoring from a backup

A restore always starts from a **FULL** backup and then applies the incremental
binlog archives **in order**:

```
latest FULL
   +
incremental / binlog archive 1
   +
incremental / binlog archive 2
   +
...
   ↓
restored database
```

1. Install [mydumper]/[myloader], [rclone], and the MySQL client
   (`mysql` + `mysqlbinlog`).
2. Create the same [rclone config file] that this container does.
3. Identify the correct FULL base:
   - Each incremental's `backup_metadata.json` records
     `base_full_backup_name` and `base_full_storage_path`.
   - The current chain head is in `state/backup_state.json`
     (`last_successful_full_backup_name`).
4. Download and restore the FULL with `myloader`:
   ```bash
   rclone copy remote:$R2_BUCKET/$R2_PATH/full/YYYY/MM/DD/full_YYYY-MM-DD_HHMMSS ./full_restore
   myloader -h $MYSQL_HOST -u $MYSQL_USER -p -d ./full_restore
   ```
5. Apply each incremental **in order** (oldest → newest). Use the pre-built,
   boundary-correct SQL stream:
   ```bash
   rclone copy remote:$R2_BUCKET/$R2_PATH/incremental/YYYY/MM/DD/incremental_YYYY-MM-DD_HHMMSS ./inc_N
   gunzip -c ./inc_N/binlog_apply.sql.gz | mysql -h $MYSQL_HOST -u $MYSQL_USER -p
   ```
   (If you prefer raw binlog files, they are in the same directory: run
   `mysqlbinlog <files...> | mysql …`, applying the recorded
   `start_binlog_position`/`end_binlog_position`.)

A **FULL backup is required before an incremental chain can be restored.** You
cannot restore from an incremental alone. Identify the full base via
`base_full_backup_name` in the incremental's `backup_metadata.json`.

### Ordering and boundary rules (read before restoring)

These are the rules that make the chain correct. Breaking any one of them
produces either **lost** or **duplicated** events:

1. **Always start from the FULL that the incrementals name.** Every
   `backup_metadata.json` records `base_full_backup_name` /
   `base_full_storage_path`. Never mix incrementals from two different FULL
   bases — the binlog positions are only meaningful relative to their own base.
2. **Apply incrementals oldest → newest, without gaps.** Sort by the
   `started_at` field (or by the binlog sequence in `start_binlog_file`). If any
   incremental in the middle of the chain is missing from R2, **stop** — the
   chain is broken and you need a newer FULL.
3. **Take the positions from the metadata, not from memory.** Each archive was
   built with `--start-position` applied to its **first** file and
   `--stop-position` applied to its **last** file (see the next point).
4. **`binlog_apply.sql.gz` is already boundary-correct.** Each incremental ships
   a `mysqlbinlog`-generated SQL stream whose boundaries were fixed at capture
   time. Use it as-is; do not re-derive positions by hand.
5. **Never apply the same archive twice.** `binlog_apply.sql.gz` is **not**
   idempotent — replaying it duplicates every event it contains. If a restore is
   interrupted, restart from the FULL rather than guessing where you stopped.
   Each incremental's range is `[start, end)` relative to its predecessor, so a
   correctly ordered full pass applies each event exactly once.
6. **The `end` position of one incremental is the `start` of the next.** You can
   assert this before restoring:
   `incremental N . end_binlog_file == incremental N+1 . start_binlog_file` and
   `incremental N . end_binlog_position == incremental N+1 . start_binlog_position`.
   A mismatch means the chain is not contiguous.
7. **Rotation is already handled.** One incremental can span several binlog
   files (`start_binlog_file` … `end_binlog_file`), and the raw rotated files are
   all stored in the same directory alongside the SQL stream. Applying the SQL
   stream covers the whole span in the right order.

### Restore procedure (compressed SQL, the recommended path)

```bash
BASE=full_2026-09-10_020000     # from each incremental's base_full_backup_name

# 1) FULL base
rclone copy "remote:$R2_BUCKET/$R2_PATH/full/2026/09/10/$BASE" ./full_restore
myloader -h "$MYSQL_HOST" -u "$MYSQL_USER" -p -d ./full_restore

# 2) incrementals, OLDEST FIRST (repeat for each, in order)
rclone copy "remote:$R2_BUCKET/$R2_PATH/incremental/2026/09/11/incremental_2026-09-11_020000" ./inc_1
gunzip -c ./inc_1/binlog_apply.sql.gz | mysql -h "$MYSQL_HOST" -u "$MYSQL_USER" -p
```

### Restore procedure (raw binlog files)

Each incremental directory also contains the byte-exact raw binlog files, which
is the authoritative recovery source if you need to filter events yourself:

```bash
# Apply the exact recorded range across one or more rotated files.
mysqlbinlog \
  --start-position="$BINLOG_POSITION_START" \
  --stop-position="$BINLOG_POSITION_END" \
  ./inc_1/binlog.000123 ./inc_1/binlog.000124 | mysql -h "$MYSQL_HOST" -u "$MYSQL_USER" -p
```

`--start-position` is applied to the **first** file and `--stop-position` to the
**last** file, which is exactly how the archive was produced.

> **Note on point-in-time recovery:** the stored binlog data and positions let
> you replay every recorded change up to each incremental's
> `end_binlog_position`. What this chain **proves** is _event-range_ recovery to
> a captured boundary — every change is accounted for between the FULL base and
> the last verified incremental. It is **not** claimed to be arbitrary
> timestamp-based PITR; for a timestamp target you must additionally filter
> yourself (e.g. `mysqlbinlog --stop-datetime=…`). Railway PITR, if enabled, is a
> **separate** mechanism and is not required by — and does not affect — this
> procedure.

## FAQ

### What binaries does the image require?

The image is built from the `mydumper/mydumper` base (AlmaLinux 9, `dnf`) with
`rclone` copied in from the official image. The build **verifies every command
the entrypoint needs** and fails the build if any is missing, so a mis-built
image cannot start and then silently behave incorrectly:

| Command                                                           | Needed for                                       |
| ----------------------------------------------------------------- | ------------------------------------------------ |
| `mydumper`                                                        | FULL logical dump                                |
| `mysql`, `mysqlbinlog`                                            | boundary read, binlog capture, local validation  |
| `rclone`                                                          | upload, `size --json` verification, state object |
| `gzip`                                                            | compressing the incremental SQL stream           |
| `curl`                                                            | PUPTracker reporting                             |
| `bash`                                                            | the entrypoint is a bash script                  |
| `date find sha256sum sed awk grep sort wc head mktemp tr dirname` | metadata, checksum, JSON parsing                 |

The build also prints the resolved versions of `mysqlbinlog`, `mysql`, `mydumper`
and `rclone` so an image can be audited against the server it backs up.

### Using something other than Cloudflare R2

You can fork this repo and modify the [rclone config file] to work for any storage destination [that rclone supports](https://rclone.org/#providers) (which is pretty much everything).

### Does this work with MariaDB?

Yes! `mydumper` and `myloader` are compatible with MariaDB as well. Note that
MariaDB has no `SHOW BINARY LOG STATUS`; the container falls back to
`SHOW MASTER STATUS` automatically.

### What is _not_ covered by this repository's own tests?

The repository's test suite (`bash test_reporting.sh`) is a **shell-level** test
suite. Every external tool that would touch the real world — `rclone`, `curl`,
`mysql`, `mysqlbinlog`, `mydumper` — is replaced by a controlled test double
that emits realistic output for the exact commands the entrypoint issues. That
exercises the production control flow, boundary logic, state machine and
reporting contract, but it does **not** prove:

- that a real MySQL 8.4 server returns exactly these shapes for
  `SHOW BINARY LOG STATUS` / `SHOW BINARY LOGS`;
- that a real Cloudflare R2 bucket enforces create-if-absent on `rclone copyto`
  the way the lock assumes;
- that the real PUPTracker endpoint accepts the payloads;
- that the Docker image builds (no Docker daemon is required to run the tests).

Validate those in a staging environment before relying on the chain in
production. For the real-image harness that does cover them, see
[docs/INTEGRATION_TESTING.md](docs/INTEGRATION_TESTING.md).

> **A test double must be faithful to the real tool, or it hides bugs.** The
> `mysqlbinlog` double in `test_reporting.sh` once accepted _any_ filename, so it
> silently passed a capture that handed the real tool bare relative paths for
> files that only exist in `mysql_binlogs/`. The real `mysqlbinlog` would have
> failed to open them. The double now **requires the file to exist**, and the
> suite asserts the paths passed to it are absolute — the same class of bug
> cannot return unnoticed.

[mydumper]: https://github.com/mydumper/mydumper
[rclone]: https://rclone.org
[rclone config file]: https://github.com/dbanty/rclone-mysql-backup/blob/06174cac3204c2e1e7b992d8f4ff112aa801561c/entrypoint.sh#L7-L16
