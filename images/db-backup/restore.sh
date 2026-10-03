#!/bin/bash
# Restores one backup into the database (ADR-0064). Called by
# deploy/restore.sh, which stops the application first.
#
#   restore.sh <file in /backups>        local copy
#   restore.sh s3://<bucket>/<key>       downloaded first
set -eu
# A failing dump must fail the backup, not upload an empty file.
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

# A wrong passphrase fails here ("bad decrypt"), before the database is touched.
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -pass "file:${passfile}" -in "${local_file}" -out "${plain}"

case "${BACKUP_ENGINE:-postgres}" in
    postgres)
        echo "restore: ${local_file} → ${PGDATABASE}"
        pg_restore --clean --if-exists --no-owner --no-privileges --single-transaction --dbname "${PGDATABASE}" "${plain}"
        ;;
    mysql)
        echo "restore: ${local_file} → ${MYSQL_DATABASE}"
        gunzip -c "${plain}" | MYSQL_PWD="${MYSQL_PASSWORD}" mariadb --skip-ssl-verify-server-cert --host="${MYSQL_HOST}" \
            --port="${MYSQL_PORT:-3306}" --user="${MYSQL_USER}" "${MYSQL_DATABASE}"
        ;;
    *)
        echo "restore: unknown BACKUP_ENGINE" >&2
        exit 1
        ;;
esac
echo "restore: done"
