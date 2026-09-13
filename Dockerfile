# syntax=docker/dockerfile:1

FROM rclone/rclone:1.74.3 as rclone

# The published mydumper/mydumper image is built from mydumper/mydumper's
# docker/Dockerfile which is `FROM almalinux:9` (RHEL-family). Its package
# manager is dnf (yum); it has NO apt-get and NO apk.
FROM mydumper/mydumper:v0.21.3-2

COPY --from=rclone /usr/local/bin/rclone /usr/local/bin/rclone

# Install ONLY the runtime commands the entrypoint needs that are not already
# present in the AlmaLinux-9-based mydumper image.
#
# The base image already ships curl-minimal and coreutils-single, which provide
# the `curl` command and the coreutils commands (date/sha256sum/sort/wc/head/
# tr/mktemp). Requesting the full `curl` or `coreutils` packages would CONFLICT
# with those variants. Installing by absolute binary path (/usr/bin/curl, ...)
# makes dnf resolve to whatever package already provides the file (the minimal/
# single variant) and does nothing when the command already exists, so we never
# force a package replacement.
#
# Required commands: curl date find sha256sum sed awk grep sort wc head mktemp tr
#   - /usr/bin/curl      -> curl-minimal (already present) or curl
#   - /usr/bin/find      -> findutils
#   - /usr/bin/sha256sum,/usr/bin/date,/usr/bin/sort,/usr/bin/wc,/usr/bin/head,
#     /usr/bin/tr,/usr/bin/mktemp -> coreutils-single (already present)
#   - /usr/bin/sed,/usr/bin/awk,/usr/bin/grep -> sed, gawk, grep
#   - ca-certificates    -> TLS trust store for HTTPS reporting
#
# TRUE incremental (binary-log) support additionally needs:
#   - mysqlbinlog + mysql -> provided by the MySQL *client*. We install the
#     client PACKAGE (mysql) which supplies BOTH binaries and does NOT pull in
#     the full server. On AlmaLinux 9 this is provided by the `mysql` package
#     (MySQL 8.x client) or `mariadb` client; the absolute-path probe below
#     resolves whichever provides /usr/bin/mysqlbinlog.
#   - gzip -> compresses the archived binlog stream (package: gzip).
RUN set -eux; \
    PKG="dnf"; \
    if command -v microdnf >/dev/null 2>&1; then PKG="microdnf"; \
    elif command -v dnf >/dev/null 2>&1; then PKG="dnf"; \
    elif command -v yum >/dev/null 2>&1; then PKG="yum"; \
    else echo "No package manager (dnf/yum/microdnf) found." >&2; exit 1; fi; \
    \
    # Build an install list of absolute paths ONLY for commands that are missing.
    install_list=""; \
    for cmd in /usr/bin/curl /usr/bin/find /usr/bin/sha256sum /usr/bin/date \
               /usr/bin/sort /usr/bin/wc /usr/bin/head /usr/bin/tr \
               /usr/bin/mktemp /usr/bin/sed /usr/bin/awk /usr/bin/grep \
               /usr/bin/gzip; do \
      if [ ! -e "$cmd" ]; then install_list="$install_list $cmd"; fi; \
    done; \
    # ca-certificates is only needed when curl is being added or TLS is absent.
    if ! rpm -q ca-certificates >/dev/null 2>&1; then \
      install_list="$install_list ca-certificates"; \
    fi; \
    # MySQL client (mysqlbinlog + mysql) for binary-log incremental backups.
    # Provide it by package NAME because these are NOT supplied by an already
    # present variant (unlike curl-minimal/coreutils-single). Prefer a client-
    # only package so the server is never installed. Availability is probed
    # with rpm/dnf metadata rather than assuming a specific distro variant.
    if ! command -v mysqlbinlog >/dev/null 2>&1; then \
      if dnf -q list --available mysql >/dev/null 2>&1 || rpm -q mysql >/dev/null 2>&1; then \
        install_list="$install_list mysql"; \
      elif dnf -q list --available mysql-community-client >/dev/null 2>&1 || rpm -q mysql-community-client >/dev/null 2>&1; then \
        install_list="$install_list mysql-community-client"; \
      elif dnf -q list --available mariadb >/dev/null 2>&1 || rpm -q mariadb >/dev/null 2>&1; then \
        install_list="$install_list mariadb"; \
      else \
        echo "WARNING: no MySQL client package (mysql/mariadb) was found in the configured repositories." >&2; \
      fi; \
    fi; \
    if [ -n "$install_list" ]; then \
      "$PKG" -y install $install_list; \
      "$PKG" clean all; \
    else \
      echo "All required runtime commands are already present in the base image."; \
    fi; \
    \
    # Fail the BUILD if any command the entrypoint needs is still missing,
    # rather than producing an image that fails (or silently fabricates an
    # "incremental") at run time.
    #
    # `bash` is included because /entrypoint.sh declares a bash shebang and uses
    # bash-only features (arrays, `[[ ]]`, `BASH_SOURCE`); on a base image where
    # /bin/sh is not bash the container would not start.
    for cmd in bash mydumper rclone curl date find sha256sum sed awk grep sort \
               wc head mktemp tr dirname gzip mysql mysqlbinlog; do \
      if ! command -v "$cmd" >/dev/null 2>&1; then \
        echo "BUILD FAILURE: required command not present after install: $cmd" >&2; \
        exit 1; \
      fi; \
    done; \
    \
    # The FULL backup MUST be able to record a CONSISTENT-SNAPSHOT binlog anchor:
    # `run_full_backup` passes --source-data and `read_mydumper_binlog_anchor`
    # then reads SOURCE_LOG_FILE / SOURCE_LOG_POS from the metadata file. If the
    # pinned mydumper does not accept the flag, every FULL would silently be
    # written WITHOUT an anchor (mydumper writes those keys commented-out by
    # default), so no TRUE_INCREMENTAL could ever start from it. Fail the BUILD
    # instead of shipping an image that can never produce a usable chain base.
    #
    # The help output is a side-effect-free capability check (it needs no server
    # connection). mydumper exits non-zero for --help on some builds, so the exit
    # status is ignored and only the option text is asserted.
    #
    # LIMITATION -- this check is NECESSARY BUT NOT SUFFICIENT. Accepting
    # --source-data does not prove that the binary can actually READ the snapshot
    # position: a mydumper that only implements the pre-8.4 `SHOW MASTER STATUS`
    # statement will accept the flag, fail that query against a MySQL 8.4+ server
    # ("Couldn't get master position - ERROR 1064"), and write a metadata file
    # with NO `[source]` section at all. That cannot be detected at build time
    # because no server is reachable here. The authoritative check is therefore
    # the RUNTIME `DIAG anchor:` evidence that `log_binlog_anchor_diagnostics`
    # emits whenever an anchor is missing.
    if ! mydumper --help 2>&1 | grep -q -- '--source-data'; then \
      echo "BUILD FAILURE: this mydumper does not support --source-data; the FULL backup could not record a binlog anchor." >&2; \
      mydumper --version >&2 || true; \
      exit 1; \
    fi; \
    \
    # `--server-version` is what makes the anchor obtainable ON MySQL 8.4+: it
    # lets the entrypoint declare the server family/version so mydumper issues
    # `SHOW BINARY LOG STATUS` instead of the statement MySQL 8.4 REMOVED
    # (`SHOW MASTER STATUS`). Without the flag the entrypoint cannot derive an
    # override and a token-less `@@version_comment` (e.g. `(Ubuntu)`) yields no
    # anchor at all. Fail the build rather than ship an image with no remedy.
    if ! mydumper --help 2>&1 | grep -q -- '--server-version'; then \
      echo "BUILD FAILURE: this mydumper does not support --server-version; the FULL backup could not obtain a binlog anchor on MySQL 8.4+." >&2; \
      mydumper --version >&2 || true; \
      exit 1; \
    fi; \
    \
    # The mysqlbinlog client must be the MySQL (not MariaDB) one, and it must
    # NOT be expected to accept --result-dir (a MariaDB-only option). Assert the
    # MySQL client's own `--result-file` long form so a MariaDB client slipping
    # in is caught here instead of at 03:00 during an incremental.
    if ! mysqlbinlog --help 2>&1 | grep -q -- '--result-file'; then \
      echo "BUILD FAILURE: mysqlbinlog does not support --result-file; is this the MySQL client?" >&2; \
      mysqlbinlog --version >&2 || true; \
      exit 1; \
    fi; \
    if mysqlbinlog --help 2>&1 | grep -q -- '--result-dir'; then \
      echo "BUILD FAILURE: mysqlbinlog advertises --result-dir, which means it is a MariaDB client; the entrypoint uses the MySQL form." >&2; \
      mysqlbinlog --version >&2 || true; \
      exit 1; \
    fi; \
    \
    # Record the resolved versions so an image can be audited against the server
    # it will back up (the binlog tooling must not be older than the server's
    # binlog format expectations).
    echo "--- resolved backup tool versions ---"; \
    mysqlbinlog --version || true; \
    mysql --version || true; \
    mydumper --version || true; \
    rclone version | head -n1 || true; \
    bash --version | head -n1; \
    echo "--- verified: mydumper supports --source-data (binlog anchor) ---"

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENV MYSQL_HOST=""
ENV MYSQL_USER=""
ENV MYSQL_PASSWORD=""
ENV MYSQL_PORT="3306"
ENV MYSQL_DATABASE=""
ENV R2_ACCESS_KEY_ID=""
ENV R2_SECRET_ACCESS_KEY=""
ENV R2_ENDPOINT=""
ENV R2_BUCKET=""
ENV R2_PATH="mysql-backup"
ENV BACKUP_REPORT_URL=""
ENV BACKUP_REPORT_TOKEN=""
ENV REPORT_TIMEOUT="20"
# Backup policy (full / true binary-log incremental).
ENV BACKUP_FULL_INTERVAL_DAYS="14"
ENV BACKUP_BINLOG_ENABLED="true"
ENV BACKUP_BINLOG_VERIFY="true"
ENV BACKUP_TIMEZONE="UTC"
# Unique replication-client identity for `mysqlbinlog --read-from-remote-server`.
# MUST be unique among every binlog consumer on the server (a real replica,
# Railway's own binlog archiving, another backup run, ...). A duplicate id makes
# the server drop one of the connections and can silently truncate a capture.
ENV MYSQLBINLOG_SERVER_ID="2147483000"
# How binlog files are obtained: `raw` (mysqlbinlog --raw, needs REPLICATION
# SLAVE) or `copy` (read files from a mounted binlog directory).
ENV BINLOG_FETCH_STRATEGY="raw"
ENV BINLOG_LOCAL_DIR=""
# Distributed lock protecting the backup chain state from concurrent runs.
ENV BACKUP_LOCK_ENABLED="true"
ENV BACKUP_LOCK_TTL_SECONDS="21600"

CMD ["/entrypoint.sh"]
