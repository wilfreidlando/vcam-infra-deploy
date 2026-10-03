# VPS standard database backup agent (infra/README.md, ADR-0064), usable by
# every project on the server: PostgreSQL (any version ≤ 18 — pg_dump reads
# older servers) or MySQL/MariaDB, dumped → encrypted with gpg (AES-256) →
# kept on a local volume + copied to any S3-compatible storage (MEGA S4,
# Cloudflare R2, Backblaze B2…). Configuration: environment only (README).
FROM postgres:18-alpine

RUN apk add --no-cache aws-cli gnupg tzdata mariadb-client

COPY backup.sh restore.sh entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/backup.sh /usr/local/bin/restore.sh /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["crond", "-f", "-l", "8"]
