# Minimal PHP image for the PUPTracker reporting STUB used by the integration
# harness only. This is NOT shipped as part of the backup image.
FROM php:8.3-cli-alpine

WORKDIR /app
COPY server.php /app/server.php

# The harness mounts a writable store directory here (token + recorded reports).
RUN mkdir -p /var/store

EXPOSE 8080
CMD ["php", "-S", "0.0.0.0:8080", "/app/server.php"]
