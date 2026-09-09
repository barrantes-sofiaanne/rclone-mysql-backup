[![Deploy on Railway](https://railway.app/button.svg)](https://railway.app/template/7GOA4r?referralCode=xsbY2R)

# Backup MySQL to Cloudflare R2

This Docker app runs a single time, dumping a MySQL database with [mydumper] and using [rclone] to push that data to [Cloudflare R2](https://developers.cloudflare.com/r2/).

You schedule the container to run at whatever interval you want backups to happen.

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

1. Runs `mydumper` to produce a logical snapshot.
2. Computes metadata (file count, total size, and a deterministic SHA-256
   manifest checksum) and gives the run a unique name.
3. Uploads the snapshot to a **unique** R2 path (see below).
4. Verifies the upload (object presence, count, and total size).
5. POSTs a JSON report to `BACKUP_REPORT_URL` using
   `Authorization: Bearer $BACKUP_REPORT_TOKEN`.

Each run is reported with `backup_type=daily_snapshot` — these are logical
MyDumper snapshots and are **never** labelled `incremental`.

#### Unique R2 backup paths

`R2_PATH` is treated as a base path. Every run uploads to a timestamped,
unique destination so previous backups are never overwritten:

```
$R2_BUCKET/$R2_PATH/daily_snapshot/YYYY/MM/DD/daily_snapshot_YYYY-MM-DD_HHMMSS/
```

Example with `R2_PATH=mysql-backup`:

```
mysql-backup/daily_snapshot/2026/09/10/daily_snapshot_2026-09-10_020000/
```

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
`rclone lsf --recursive -l`). This confirms the objects are present and are not
missing/truncated.

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

#### Successful backup but reporting failed

If the backup and upload **succeed** but the final HTTP report to PUPTracker
fails, the container logs
`Backup succeeded but PUPTracker reporting failed.` and exits non-zero so
Railway surfaces the reporting problem. It does **not** mark the backup as
failed. PUPTracker's endpoint is idempotent by `backup_name`, so re-running
with the same name is safe and will not create duplicate records.

#### Example payload (no real token)

```json
{
  "status": "success",
  "backup_name": "daily_snapshot_2026-09-10_020000",
  "backup_type": "daily_snapshot",
  "started_at": "2026-09-09T18:00:00Z",
  "completed_at": "2026-09-09T18:02:00Z",
  "destination": "Cloudflare R2",
  "backup_size": 123456789,
  "file_count": 42,
  "checksum": "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08",
  "checksum_algorithm": "SHA-256",
  "verified_at": "2026-09-09T18:02:01Z",
  "storage_path": "mysql-backup/daily_snapshot/2026/09/09/daily_snapshot_2026-09-09_180000"
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

1. Install [mydumper] and [rclone]
2. Create the same [rclone config file] that this container does
3. Run `rclone copy remote:$R2_BUCKET/$R2_PATH ./$LOCAL_FOLDER_TO_CREATE`
4. Run `myloader -h $MYSQL_HOST -u $MYSQL_USER -p $MYSQL_PASSWORD -d $LOCAL_FOLDER_TO_CREATE`

## FAQ

### Using something other than Cloudflare R2

You can fork this repo and modify the [rclone config file] to work for any storage destination [that rclone supports](https://rclone.org/#providers) (which is pretty much everything).

### Does this work with MariaDB?

Yes! `mydumper` and `myloader` are compatible with MariaDB as well.

[mydumper]: https://github.com/mydumper/mydumper
[rclone]: https://rclone.org
[rclone config file]: https://github.com/dbanty/rclone-mysql-backup/blob/06174cac3204c2e1e7b992d8f4ff112aa801561c/entrypoint.sh#L7-L16
