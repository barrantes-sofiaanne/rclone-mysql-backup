# syntax=docker/dockerfile:1

FROM rclone/rclone:1.74.3 as rclone

FROM mydumper/mydumper:v0.21.3-2

COPY --from=rclone /usr/local/bin/rclone /usr/local/bin/rclone

# The reporting step needs curl (HTTP client), coreutils (sha256sum), and
# findutils (find). Add only the minimal tools, supporting both apt-get
# (Debian/Ubuntu) and apk (Alpine) base images.
RUN set -eux; \
    if command -v apt-get >/dev/null 2>&1; then \
      apt-get update \
      && apt-get install -y --no-install-recommends \
         curl ca-certificates coreutils findutils \
      && rm -rf /var/lib/apt/lists/*; \
    elif command -v apk >/dev/null 2>&1; then \
      apk add --no-cache \
         curl ca-certificates coreutils findutils; \
    else \
      echo "No supported package manager (apt-get/apk) found." >&2; \
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
