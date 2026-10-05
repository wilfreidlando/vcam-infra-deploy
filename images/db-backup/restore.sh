#!/bin/bash
# Restores one backup into the database (ADR-0064). Called by
# deploy/restore.sh, which stops the application first.
#
#   restore.sh <file in /backups>        local copy
#   restore.sh s3://<bucket>/<key>       downloaded first
#
# RESTORE_MODE (PostgreSQL), default "replace":
#   replace  the database ends up EXACTLY as it was at backup time: the public schema is reset
#            and the dump replayed in ONE transaction, so a failure leaves the data untouched.
#            Whatever was created after the backup (a migration, a test table) disappears.
#   merge    previous behaviour (pg_restore --clean): objects in the dump are recreated, objects
#            created since stay. A replayed migration may then fail with "already exists".
# MySQL/MariaDB: same modes. replace drops views, tables, routines and events first, then replays the
#            dump. Not atomic (MySQL DDL is not transactional); the dump is validated before any drop.
set -eu
# A failing dump must fail the backup, not upload an empty file.
set -o pipefail

src="${1:?usage: restore.sh <file|s3://bucket/key>}"

if [ -z "${BACKUP_PASSPHRASE:-}" ]; then
    echo "restore: BACKUP_PASSPHRASE is empty" >&2
    exit 1
fi

mode="${RESTORE_MODE:-replace}"
case "${mode}" in
    replace|merge) ;;
    *) echo "restore: RESTORE_MODE must be replace or merge (got: ${mode})" >&2; exit 1 ;;
esac

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
sqlfile="$(mktemp)"
trap 'rm -f "${passfile}" "${plain}" "${sqlfile}"' EXIT
printf '%s' "${BACKUP_PASSPHRASE}" > "${passfile}"

# A wrong passphrase fails here ("bad decrypt"), before the database is touched.
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -pass "file:${passfile}" -in "${local_file}" -out "${plain}"

case "${BACKUP_ENGINE:-postgres}" in
    postgres)
        echo "restore: ${local_file} → ${PGDATABASE} (mode ${mode})"
        # The SQL script is generated first: a corrupt or truncated archive fails HERE, before the
        # database is touched. Then everything runs in ONE transaction (psql --single-transaction):
        # either the database is fully replaced, or nothing changed.
        pg_restore --clean --if-exists --no-owner --no-privileges --file "${sqlfile}" "${plain}"
        {
            if [ "${mode}" = replace ]; then
                # pg_restore --clean only drops what the dump contains. Resetting the schema removes
                # what was created after the backup too (restoring a pre-deploy backup after a failed
                # migration must not leave that migration's tables behind).
                echo 'DROP SCHEMA IF EXISTS public CASCADE;'
                echo 'CREATE SCHEMA public;'
            fi
            cat "${sqlfile}"
        } | psql --no-psqlrc --quiet --set ON_ERROR_STOP=1 --single-transaction --dbname "${PGDATABASE}" --output /dev/null
        ;;
    mysql)
        echo "restore: ${local_file} → ${MYSQL_DATABASE} (mode ${mode})"
        # The archive must be a COMPLETE dump BEFORE anything is dropped: a valid gzip stream that ends
        # with mariadb-dump's closing comment. A truncated file fails here, the database is untouched.
        gunzip -t "${plain}"
        gunzip -c "${plain}" | tail -n 5 | grep -q -- '-- Dump completed' \
            || { echo "restore: incomplete dump (no « Dump completed » line), database untouched" >&2; exit 1; }
        client() {
            MYSQL_PWD="${MYSQL_PASSWORD}" mariadb --skip-ssl-verify-server-cert --host="${MYSQL_HOST}" \
                --port="${MYSQL_PORT:-3306}" --user="${MYSQL_USER}" "$@"
        }
        if [ "${mode}" = replace ]; then
            # Same promise as PostgreSQL: the database ends up exactly as at backup time. The dump only
            # recreates its own tables (DROP TABLE IF EXISTS), so views, tables, routines and events
            # created since are dropped first. MySQL DDL is not transactional: unlike PostgreSQL this is
            # not atomic, which is why the dump is validated above and the encrypted file stays available.
            drops="$(mktemp)"
            {
                echo 'SET FOREIGN_KEY_CHECKS=0;'
                client -N -B "${MYSQL_DATABASE}" -e "SELECT CONCAT('DROP VIEW IF EXISTS \`', table_name, '\`;') FROM information_schema.views WHERE table_schema = DATABASE()"
                client -N -B "${MYSQL_DATABASE}" -e "SELECT CONCAT('DROP TABLE IF EXISTS \`', table_name, '\`;') FROM information_schema.tables WHERE table_schema = DATABASE() AND table_type = 'BASE TABLE'"
                client -N -B "${MYSQL_DATABASE}" -e "SELECT CONCAT('DROP ', routine_type, ' IF EXISTS \`', routine_name, '\`;') FROM information_schema.routines WHERE routine_schema = DATABASE()"
                client -N -B "${MYSQL_DATABASE}" -e "SELECT CONCAT('DROP EVENT IF EXISTS \`', event_name, '\`;') FROM information_schema.events WHERE event_schema = DATABASE()"
            } > "${drops}"
            client "${MYSQL_DATABASE}" < "${drops}"
            rm -f "${drops}"
        fi
        # A dump taken with a recent mariadb-dump (the agent ships 11.4) opens with
        #   /*M!100616 SET @OLD_NOTE_VERBOSITY=@@NOTE_VERBOSITY, NOTE_VERBOSITY=0 */
        # MariaDB 10.7.8 runs it (version 100708 >= 100616) but has no such variable:
        # "Unknown system variable 'NOTE_VERBOSITY'" and the restore fails. These lines only silence
        # warnings; dropping them makes a dump restorable on any server version (10.7 to 11.4, MySQL).
        gunzip -c "${plain}" | sed '/^\/\*M![0-9]* SET .*NOTE_VERBOSITY/d' | client "${MYSQL_DATABASE}"
        ;;
    *)
        echo "restore: unknown BACKUP_ENGINE" >&2
        exit 1
        ;;
esac
echo "restore: done"
