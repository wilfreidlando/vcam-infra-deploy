#!/bin/sh
# Installs the cron schedule, then runs the given command (crond by default).
set -eu

: "${BACKUP_CRON:=30 2 * * *}"

mkdir -p /etc/crontabs
# Environment is not inherited by crond jobs: snapshot it for backup.sh.
export -p | grep -E ' (PG|MYSQL_|BACKUP_|AWS_|TZ)' > /etc/backup.env || true
echo "${BACKUP_CRON} . /etc/backup.env && /usr/local/bin/backup.sh >> /proc/1/fd/1 2>&1" > /etc/crontabs/root

exec "$@"
