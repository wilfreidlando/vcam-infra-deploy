#!/bin/sh
# Restores one backup into the database (ADR-0064). Called by
# deploy/restore.sh, which stops the application first.
#
#   restore.sh <file in /backups>        local copy
#   restore.sh s3://<bucket>/<key>       downloaded first
set -eu
# busybox ash supports it: a failing mysqldump must fail the backup.
set -o pipefail

src="${1:?usage: restore.sh <file|s3://bucket/key>}"

if [ -z "${BACKUP_PASSPHRASE:-}" ]; then
    echo "restore: BACKUP_PASSPHRASE is empty" >&2
    exit 1
fi

case "${src}" in
    s3://*)
        aws configure set default.s3.addressing_style path
        endpoint=""
        [ -n "${BACKUP_S3_ENDPOINT:-}" ] && endpoint="--endpoint-url ${BACKUP_S3_ENDPOINT}"
        local_file="/backups/restore-$(basename "${src}")"
        # shellcheck disable=SC2086
        aws ${endpoint} s3 cp --only-show-errors "${src}" "${local_file}"
        ;;
    /*) local_file="${src}" ;;
    *)  local_file="/backups/${src}" ;;
esac

umask 077
passfile="$(mktemp)"
plain="$(mktemp)"
trap 'rm -f "${passfile}" "${plain}"' EXIT
printf '%s' "${BACKUP_PASSPHRASE}" > "${passfile}"

gpg --batch --quiet --yes --decrypt --passphrase-file "${passfile}" --output "${plain}" "${local_file}"

case "${BACKUP_ENGINE:-postgres}" in
    postgres)
        echo "restore: ${local_file} → ${PGDATABASE}"
        pg_restore --clean --if-exists --no-owner --no-privileges --single-transaction --dbname "${PGDATABASE}" "${plain}"
        ;;
    mysql)
        echo "restore: ${local_file} → ${MYSQL_DATABASE}"
        gunzip -c "${plain}" | MYSQL_PWD="${MYSQL_PASSWORD}" mysql --host="${MYSQL_HOST}" \
            --port="${MYSQL_PORT:-3306}" --user="${MYSQL_USER}" "${MYSQL_DATABASE}"
        ;;
    *)
        echo "restore: unknown BACKUP_ENGINE" >&2
        exit 1
        ;;
esac
echo "restore: done"
