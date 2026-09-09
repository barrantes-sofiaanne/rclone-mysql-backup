# syntax=docker/dockerfile:1

FROM rclone/rclone:1.74.3 as rclone

# The published mydumper/mydumper image is built from mydumper/mydumper's
# docker/Dockerfile which is `FROM almalinux:9` (RHEL-family). Its package
# manager is dnf (yum); it has NO apt-get and NO apk.
FROM mydumper/mydumper:v0.21.3-2

COPY --from=rclone /usr/local/bin/rclone /usr/local/bin/rclone

# Add the runtime utilities needed by the reporting/hardening steps that are
# not guaranteed in the AlmaLinux-9-based mydumper image: curl (HTTP client),
# ca-certificates (TLS), coreutils (sha256sum/date/sort/wc/head/tr/mktemp),
# findutils (find), grep, sed, and gawk. Use dnf/yum/microdnf (the correct
# manager for this RHEL-family base).
RUN set -eux; \
    if command -v dnf >/dev/null 2>&1; then \
      dnf -y install \
         curl ca-certificates coreutils findutils grep sed gawk \
      && dnf clean all; \
    elif command -v yum >/dev/null 2>&1; then \
      yum -y install \
         curl ca-certificates coreutils findutils grep sed gawk \
      && yum clean all; \
    elif command -v microdnf >/dev/null 2>&1; then \
      microdnf -y install \
         curl ca-certificates coreutils findutils grep sed gawk \
      && microdnf clean all; \
    else \
      echo "No supported package manager (dnf/yum/microdnf) found in the mydumper base image." >&2; \
      exit 1; \
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
