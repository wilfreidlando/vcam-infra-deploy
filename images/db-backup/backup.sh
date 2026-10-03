#!/bin/sh
# One encrypted backup of the database (ADR-0064).
#
#   BACKUP_ENGINE=postgres (default) — PGHOST/PGDATABASE/PGUSER/PGPASSWORD
#   BACKUP_ENGINE=mysql              — MYSQL_HOST/MYSQL_DATABASE/MYSQL_USER/MYSQL_PASSWORD
#
#   1. dump (pg_dump --format=custom, or mysqldump --single-transaction)
#   2. encrypted with BACKUP_PASSPHRASE (gpg, AES-256) — the S3 provider
#      never sees the data in clear
#   3. kept in /backups (last BACKUP_LOCAL_KEEP files)
#   4. copied to s3://BACKUP_S3_BUCKET/BACKUP_S3_PREFIX/BACKUP_NAME/ when
#      BACKUP_S3_BUCKET is set; remote copies older than
#      BACKUP_RETENTION_DAYS are deleted
#
# Exit code ≠ 0 on any failure: deploy/promote-production.sh relies on it to
# refuse a migration without a fresh backup.
set -eu
# busybox ash supports it: a failing mysqldump must fail the backup.
set -o pipefail

: "${BACKUP_NAME:=app}"
: "${BACKUP_ENGINE:=postgres}"
: "${BACKUP_LOCAL_KEEP:=7}"
: "${BACKUP_RETENTION_DAYS:=30}"
: "${BACKUP_S3_PREFIX:=backups}"
: "${BACKUP_LABEL:=scheduled}"

if [ -z "${BACKUP_PASSPHRASE:-}" ]; then
    echo "backup: BACKUP_PASSPHRASE is empty — refusing to write an unencrypted backup" >&2
    exit 1
fi

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
file="/backups/${BACKUP_NAME}-${stamp}-${BACKUP_LABEL}.dump.gpg"
mkdir -p /backups

# Passphrase through a private temp file, never on a command line.
umask 077
passfile="$(mktemp)"
trap 'rm -f "${passfile}" "${file}.tmp"' EXIT
printf '%s' "${BACKUP_PASSPHRASE}" > "${passfile}"

case "${BACKUP_ENGINE}" in
    postgres)
        echo "backup: pg_dump ${PGDATABASE} → ${file}"
        pg_dump --format=custom --no-owner --no-privileges > "${file}.tmp"
        ;;
    mysql)
        echo "backup: mysqldump ${MYSQL_DATABASE} → ${file}"
        MYSQL_PWD="${MYSQL_PASSWORD}" mysqldump --host="${MYSQL_HOST}" --port="${MYSQL_PORT:-3306}" \
            --user="${MYSQL_USER}" --single-transaction --routines --triggers --events \
            "${MYSQL_DATABASE}" | gzip > "${file}.tmp"
        ;;
    *)
        echo "backup: unknown BACKUP_ENGINE '${BACKUP_ENGINE}' (postgres|mysql)" >&2
        exit 1
        ;;
esac
gpg --batch --yes --symmetric --cipher-algo AES256 --passphrase-file "${passfile}" \
    --output "${file}" "${file}.tmp"
rm -f "${file}.tmp"

size="$(wc -c < "${file}")"
if [ "${size}" -lt 100 ]; then
    echo "backup: ${file} is suspiciously small (${size} bytes)" >&2
    exit 1
fi
echo "backup: ${size} bytes written"

# Local rotation: keep the newest BACKUP_LOCAL_KEEP files of this stack.
ls -1t /backups/"${BACKUP_NAME}"-*.dump.gpg 2>/dev/null | tail -n +"$((BACKUP_LOCAL_KEEP + 1))" | xargs -r rm -f

if [ -z "${BACKUP_S3_BUCKET:-}" ]; then
    echo "backup: BACKUP_S3_BUCKET not set — local copy only"
    exit 0
fi

aws configure set default.s3.addressing_style path
endpoint=""
[ -n "${BACKUP_S3_ENDPOINT:-}" ] && endpoint="--endpoint-url ${BACKUP_S3_ENDPOINT}"
remote="s3://${BACKUP_S3_BUCKET}/${BACKUP_S3_PREFIX}/${BACKUP_NAME}"

# shellcheck disable=SC2086
aws ${endpoint} s3 cp --only-show-errors "${file}" "${remote}/$(basename "${file}")"
echo "backup: uploaded to ${remote}/$(basename "${file}")"

# Remote retention, by the timestamp in the file name (not provider metadata).
cutoff="$(date -u -d "@$(( $(date -u +%s) - BACKUP_RETENTION_DAYS * 86400 ))" +%Y%m%d%H%M%S)"
# shellcheck disable=SC2086
aws ${endpoint} s3 ls "${remote}/" | awk '{print $4}' | while read -r name; do
    ts="$(echo "${name}" | sed -n "s/^${BACKUP_NAME}-\([0-9]\{8\}\)T\([0-9]\{6\}\)Z-.*/\1\2/p")"
    if [ -n "${ts}" ] && [ "${ts}" -lt "${cutoff}" ]; then
        # shellcheck disable=SC2086
        aws ${endpoint} s3 rm --only-show-errors "${remote}/${name}" && echo "backup: expired ${name}"
    fi
done
