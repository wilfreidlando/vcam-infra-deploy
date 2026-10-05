# VPS standard database backup agent (README.md, ADR-0064), usable by
# every project on the server: dump → encrypted (openssl AES-256) → kept on
# a local volume + copied to any S3-compatible storage (MEGA S4, R2, B2…).
#
# Built ONLY from official images — no apt/apk at build time, so it builds
# identically anywhere and never breaks on a package mirror:
#   ENGINE=postgres (default)  base postgres:18  → pg_dump/pg_restore (reads servers ≤ 18), openssl
#   ENGINE=mysql               base mariadb:11.4 → mariadb-dump/mariadb (MariaDB 10.7 → 11.4 and MySQL 8.4), openssl
# plus the AWS CLI v2 copied from the official amazon/aws-cli image.
#
#   docker build -t vps/db-backup:1 .                              (PostgreSQL)
#   docker build --build-arg BASE=mariadb:11.4 -t vps/db-backup-mysql:1 .
ARG BASE=postgres:18
ARG AWS_CLI=amazon/aws-cli:2.37.9

FROM ${AWS_CLI} AS aws

FROM ${BASE}
COPY --from=aws /usr/local/aws-cli /usr/local/aws-cli
RUN ln -sf /usr/local/aws-cli/v2/current/bin/aws /usr/local/bin/aws \
    && aws --version

COPY backup.sh restore.sh entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/backup.sh /usr/local/bin/restore.sh /usr/local/bin/entrypoint.sh \
    && mkdir -p /backups

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["schedule"]
