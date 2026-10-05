#!/bin/bash
# One encrypted backup of the database (ADR-0064).
#
#   BACKUP_ENGINE=postgres (default) — PGHOST/PGDATABASE/PGUSER/PGPASSWORD
#   BACKUP_ENGINE=mysql              — MYSQL_HOST/MYSQL_DATABASE/MYSQL_USER/MYSQL_PASSWORD
#
#   1. dump (pg_dump --format=custom, or mariadb-dump --single-transaction, gzip)
#   2. encrypted with BACKUP_PASSPHRASE (openssl AES-256-CBC, PBKDF2 600k
#      iterations, random salt) — the S3 provider never sees the data in
#      clear. openssl rather than gpg: gpg needs a gpg-agent that some
#      base images lack (found by tests/test-backup.sh).
#   3. copied to s3://BACKUP_S3_BUCKET/BACKUP_S3_PREFIX/BACKUP_NAME/ ; remote
#      copies older than BACKUP_RETENTION_DAYS are deleted
#   4. DELETED from the server once uploaded: backups live on S3, not on the
#      server's disk (a disk that fills up silently takes every site down).
#      Only a copy whose upload FAILED stays, waiting for the next run (at most
#      BACKUP_PENDING_MAX of them). BACKUP_LOCAL_KEEP=N keeps N copies after
#      upload: an explicit, documented exception.
#
# No S3 configured = no backup (exit 1), unless BACKUP_DISABLED=1 says the
# environment is deliberately not backed up (a throw-away staging, for example).
#
# Exit code ≠ 0 on any failure: deploy/promote-production.sh relies on it to
# refuse a migration without a fresh backup.
set -eu
# A failing dump must fail the backup, not upload an empty file.
set -o pipefail

: "${BACKUP_NAME:=app}"
: "${BACKUP_ENGINE:=postgres}"
: "${BACKUP_LOCAL_KEEP:=0}"
: "${BACKUP_PENDING_MAX:=3}"
: "${BACKUP_RETENTION_DAYS:=30}"
: "${BACKUP_S3_PREFIX:=backups}"
: "${BACKUP_LABEL:=scheduled}"

if [ "${BACKUP_DISABLED:-0}" = 1 ]; then
    echo "backup: BACKUP_DISABLED=1 — this environment is deliberately not backed up, nothing written"
    # The container health check reads this marker: a deliberately disabled agent is healthy, not "stopped".
    mkdir -p /backups && date -u +%s > /backups/.last-upload
    exit 0
fi

if [ -z "${BACKUP_S3_BUCKET:-}" ]; then
    echo "backup: BACKUP_S3_BUCKET is empty — refusing to back up onto the server's own disk (backups live on S3 only; BACKUP_DISABLED=1 if this environment must not be backed up)" >&2
    exit 1
fi

if [ -z "${BACKUP_PASSPHRASE:-}" ]; then
    echo "backup: BACKUP_PASSPHRASE is empty — refusing to write an unencrypted backup" >&2
    exit 1
fi

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
file="/backups/${BACKUP_NAME}-${stamp}-${BACKUP_LABEL}.dump.enc"
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
        echo "backup: mariadb-dump ${MYSQL_DATABASE} → ${file}"
        MYSQL_PWD="${MYSQL_PASSWORD}" mariadb-dump --host="${MYSQL_HOST}" --port="${MYSQL_PORT:-3306}" \
            --user="${MYSQL_USER}" --single-transaction --routines --triggers --events \
            --no-tablespaces --skip-ssl-verify-server-cert \
            "${MYSQL_DATABASE}" | gzip > "${file}.tmp"
        ;;
    *)
        echo "backup: unknown BACKUP_ENGINE '${BACKUP_ENGINE}' (postgres|mysql)" >&2
        exit 1
        ;;
esac
openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt -pass "file:${passfile}" \
    -in "${file}.tmp" -out "${file}"
rm -f "${file}.tmp"

size="$(wc -c < "${file}")"
if [ "${size}" -lt 100 ]; then
    echo "backup: ${file} is suspiciously small (${size} bytes)" >&2
    exit 1
fi
echo "backup: ${size} bytes written"

aws configure set default.s3.addressing_style path
endpoint=""
[ -n "${BACKUP_S3_ENDPOINT:-}" ] && endpoint="--endpoint-url ${BACKUP_S3_ENDPOINT}"
remote="s3://${BACKUP_S3_BUCKET}/${BACKUP_S3_PREFIX}/${BACKUP_NAME}"

upload() {  # upload <local file>
    # shellcheck disable=SC2086
    aws ${endpoint} s3 cp --only-show-errors "$1" "${remote}/$(basename "$1")" && echo "backup: uploaded to ${remote}/$(basename "$1")"
}

if ! upload "${file}"; then
    echo "backup: UPLOAD FAILED — the encrypted copy stays on the server and is retried at the next run (at most ${BACKUP_PENDING_MAX} kept)" >&2
    # shellcheck disable=SC2012
    ls -1t /backups/"${BACKUP_NAME}"-*.dump.enc 2>/dev/null | tail -n +"$((BACKUP_PENDING_MAX + 1))" | xargs -r rm -f
    exit 1
fi
date -u +%s > /backups/.last-upload

if [ "${BACKUP_LOCAL_KEEP}" -gt 0 ]; then
    # Explicit exception: keep the newest N copies on the server.
    # shellcheck disable=SC2012 # names are generated above (no spaces); ls -t gives the age order
    ls -1t /backups/"${BACKUP_NAME}"-*.dump.enc 2>/dev/null | tail -n +"$((BACKUP_LOCAL_KEEP + 1))" | xargs -r rm -f
else
    rm -f "${file}"
    # Copies left by earlier failed uploads: retry, oldest first, and free the disk on success.
    # shellcheck disable=SC2012
    for pending in $(ls -1tr /backups/"${BACKUP_NAME}"-*.dump.enc 2>/dev/null); do
        if upload "${pending}"; then rm -f "${pending}"; else echo "backup: ${pending} still pending" >&2; fi
    done
fi

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
