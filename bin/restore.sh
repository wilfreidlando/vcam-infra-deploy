#!/usr/bin/env bash
# Restores a database backup into one environment of a project (infra/README.md).
#
#   restore.sh <staging|prod> <backup file in the backups volume | s3://bucket/key>
#
# Stops the application services (everything except DB_SERVICE and
# BACKUP_SERVICE), restores with the db-backup image, then starts them
# again. Asks for confirmation; prod requires typing the project name.
set -euo pipefail

env="${1:?usage: restore.sh <env> <backup>}"
src="${2:?usage: restore.sh <staging|prod> <backup>}"

[[ -f platform.env ]] || { echo "restore: lancer depuis la racine du projet (platform.env)" >&2; exit 2; }
# shellcheck disable=SC1091
source platform.env
: "${APP_NAME:?}" "${COMPOSE_FILE:=compose.yaml}" "${ENV_FILE_PROD:=.env}" "${ENV_FILE_STAGING:=.env.staging}"
: "${BACKUP_SERVICE:?platform.env must set BACKUP_SERVICE}" "${DB_SERVICE:=postgres}"
: "${STATE_DIR:=/var/lib/vps-platform}"

case "${env}" in
    prod) envfile="${ENV_FILE_PROD}" ;;
    staging) envfile="${ENV_FILE_STAGING}" ;;
    *) var="ENV_FILE_${env^^}"; envfile="${!var:-.env.${env}}" ;;
esac
[[ -f "${envfile}" ]] || { echo "restore: ${envfile} absent" >&2; exit 2; }

IMAGE_TAG="$(cat "${STATE_DIR}/${APP_NAME}/${env}/current" 2>/dev/null || echo latest)"
# BUILD_PER_ENV=1 (platform.env): images tagged <sha>-<env>, as deploy.sh does.
[[ "${BUILD_PER_ENV:-0}" == 1 && "${IMAGE_TAG}" != latest ]] && IMAGE_TAG="${IMAGE_TAG}-${env}"
export IMAGE_TAG
files=()
IFS=':' read -ra parts <<< "${COMPOSE_FILE}"
for f in "${parts[@]}"; do files+=(-f "${f}"); done
dc() { docker compose -p "${APP_NAME}-${env}" "${files[@]}" --env-file "${envfile}" "$@"; }

echo "Restaurer ${src} dans ${APP_NAME}-${env} ? Les données actuelles seront REMPLACÉES."
read -r -p "Tapez « ${APP_NAME}-${env} » pour confirmer : " answer
[[ "${answer}" == "${APP_NAME}-${env}" ]] || { echo "annulé"; exit 1; }

# Only the services that are running now are stopped, then restarted: on a
# fresh server (disaster recovery) nothing runs yet and nothing is started.
mapfile -t services < <(dc ps --services --status running | grep -vxE "${DB_SERVICE}|${BACKUP_SERVICE}" || true)
if [[ ${#services[@]} -gt 0 ]]; then
    echo "arrêt : ${services[*]}"
    dc stop "${services[@]}"
fi
restart() { [[ ${#services[@]} -eq 0 ]] || dc up -d --no-build "${services[@]}"; }

# RESTORE_PASSPHRASE: restore a backup encrypted with ANOTHER environment's
# passphrase (production into staging) without storing it in .env.staging.
extra=()
[[ -n "${RESTORE_PASSPHRASE:-}" ]] && extra=(-e "BACKUP_PASSPHRASE=${RESTORE_PASSPHRASE}")

if dc run --rm -T "${extra[@]}" "${BACKUP_SERVICE}" restore.sh "${src}"; then
    echo "restauration OK — redémarrage"
else
    echo "restauration en ÉCHEC — redémarrage de l'application sur les données existantes" >&2
    restart
    exit 1
fi
restart
