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
               /usr/bin/mktemp /usr/bin/sed /usr/bin/awk /usr/bin/grep; do \
      if [ ! -e "$cmd" ]; then install_list="$install_list $cmd"; fi; \
    done; \
    # ca-certificates is only needed when curl is being added or TLS is absent.
    if ! rpm -q ca-certificates >/dev/null 2>&1; then \
      install_list="$install_list ca-certificates"; \
    fi; \
    if [ -n "$install_list" ]; then \
      "$PKG" -y install $install_list; \
      "$PKG" clean all; \
    else \
      echo "All required runtime commands are already present in the base image."; \
    fi

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

CMD ["/entrypoint.sh"]
