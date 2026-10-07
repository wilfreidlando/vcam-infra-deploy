#!/usr/bin/env bash
# Exploitation courante d'un environnement SANS le redéployer : état, journaux, arrêt, démarrage, redémarrage, shell, contrôle, sauvegarde,
# tableaux Grafana. Modèle de la plateforme vcam-infra-deploy : à copier dans le projet sous scripts/ops.sh (templates/scripts/README.md).
#
#   scripts/ops.sh <environnement> <action> [arguments]
#   environnement : un de ceux de platform.env (staging, prod…)
#
#   status                 conteneurs, santé, redémarrages cumulés, version déployée, adresse et réponse du site
#   logs [service] [opts]  journaux (100 dernières lignes ; -f pour suivre ; --since 10m ; …)
#   stop                   arrête TOUS les conteneurs (ils restent, les volumes aussi) : le site est coupé
#   start                  redémarre les conteneurs arrêtés
#   restart [service]      redémarre un service (ou tous) : NE RELIT PAS le fichier d'environnement (voir ci-dessous)
#   shell [service]        shell dans un conteneur
#   check                  contrôle préalable de la plateforme (ne change rien)
#   backup                 sauvegarde chiffrée immédiate (si l'environnement est sauvegardé)
#   obs                    publie les tableaux et alertes du projet dans Grafana
#
# Ce script ne déploie rien et ne supprime ni conteneur ni volume : déployer = `vps-deploy` ou le pipeline GitLab.
# Sur une production, stop et restart demandent une confirmation tapée (ou --yes) : ils coupent le site.
# POUR APPLIQUER UNE VALEUR MODIFIÉE dans un fichier d'environnement : `vps-deploy up <env> <version courante>` ; un restart garde l'ancienne
# valeur (Docker lit le fichier à la création du conteneur : docs/reference/modifier-une-valeur.md).
#
# À ADAPTER : APP_DEFAULT, SHORTCUTS, HEALTH_PATH ci-dessous ; les actions propres au projet (console applicative, données de départ,
# création d'un administrateur, dump de la base) s'ajoutent à la fin du « case » : voir templates/scripts/README.md.
# Variables d'environnement : PROJECT_BASE (défaut /app/APPS/<PROJET>), VPS_DEPLOY (défaut vps-deploy), STATE_DIR.
set -euo pipefail

APP_DEFAULT="<PROJET>"                 # APP_NAME de platform.env
SHORTCUTS="app web db redis"           # « scripts/ops.sh prod logs web » = le service <APP>-web
HEALTH_PATH="/up"                      # la route de santé publique du site
DEFAULT_SHELL_SERVICE="app"            # le service ouvert par « shell » sans argument

BASE="${PROJECT_BASE:-/app/APPS/<PROJET>}"
VPS_DEPLOY="${VPS_DEPLOY:-vps-deploy}"
STATE_DIR="${STATE_DIR:-/var/lib/vps-platform}"

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; }
die() { echo "ops : $*" >&2; exit 2; }

ENV_NAME="${1:-}"; ACTION="${2:-}"
case "${ENV_NAME}" in ""|help|-h|--help) usage; [[ -z "${ENV_NAME}" ]] && exit 2; exit 0 ;; esac
[[ -n "${ACTION}" ]] || { usage >&2; exit 2; }
shift 2

DIR="${BASE}/${ENV_NAME}"
[[ -f "${DIR}/platform.env" ]] || die "environnement inconnu « ${ENV_NAME} » : ${DIR}/platform.env introuvable"

pe() { grep -m1 -E "^$1=" "${DIR}/platform.env" 2>/dev/null | cut -d= -f2- | tr -d '"' || true; }
APP="$(pe APP_NAME)"; APP="${APP:-${APP_DEFAULT}}"
COMPOSE_FILE="$(pe COMPOSE_FILE)"; COMPOSE_FILE="${COMPOSE_FILE:-compose.prod.yaml}"
ENVVAR="ENV_FILE_$(tr '[:lower:]' '[:upper:]' <<< "${ENV_NAME}")"
ENV_FILE="$(pe "${ENVVAR}")"; ENV_FILE="${ENV_FILE:-.env.${ENV_NAME}}"
PROJECT="${APP}-${ENV_NAME}"
IS_PROD=0; for p in $(pe PROD_ENVIRONMENTS); do [[ "${p}" == "${ENV_NAME}" ]] && IS_PROD=1; done
[[ -f "${DIR}/${ENV_FILE}" ]] || die "fichier d'environnement ${DIR}/${ENV_FILE} introuvable"

svc() { case " ${SHORTCUTS} " in *" $1 "*) echo "${APP}-$1" ;; *) echo "$1" ;; esac; }

# La version déployée (étiquette des images) : sans elle, compose résoudrait « latest ».
TAG="$(cat "${STATE_DIR}/${APP}/${ENV_NAME}/current" 2>/dev/null || true)"
dc() { ( cd "${DIR}" && export ENV_FILE IMAGE_TAG="${TAG:-latest}" && docker compose -p "${PROJECT}" -f "${COMPOSE_FILE}" --env-file "${ENV_FILE}" "$@" ); }

confirm() {  # confirm <ce qui va se passer> <conséquence>
    if [[ "${IS_PROD}" == 1 && "${YES:-0}" != 1 ]]; then
        echo "${1} sur ${ENV_NAME} (production) : ${2:-action sur la production}." >&2
        read -r -p "Taper « ${ENV_NAME} » pour confirmer : " answer
        [[ "${answer}" == "${ENV_NAME}" ]] || die "annulé"
    fi
}

# --yes peut se placer n'importe où dans les arguments.
ARGS=(); YES=0
for a in "$@"; do if [[ "$a" == "--yes" || "$a" == "-y" ]]; then YES=1; else ARGS+=("$a"); fi; done
set -- "${ARGS[@]+"${ARGS[@]}"}"

case "${ACTION}" in
    status)
        echo "── ${ENV_NAME} : version déployée ${TAG:-inconnue}"
        dc ps --format 'table {{.Service}}\t{{.Status}}'
        total=0
        for c in $(dc ps -q 2>/dev/null); do total=$(( total + $(docker inspect -f '{{.RestartCount}}' "$c" 2>/dev/null || echo 0) )); done
        echo "redémarrages cumulés : ${total}"
        host="$(grep -m1 -E '^APP_PUBLIC_HOST=' "${DIR}/${ENV_FILE}" | cut -d= -f2-)"
        if [[ -n "${host}" ]]; then
            code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "https://${host}${HEALTH_PATH}" || true)"
            echo "https://${host}${HEALTH_PATH} → ${code:-000}"
        fi
        ;;
    logs)
        svcs=(); opts=()
        for a in "$@"; do
            case "$a" in -*) opts+=("$a") ;; [0-9]*[smhd]|[0-9]*) opts+=("$a") ;; *) svcs+=("$(svc "$a")") ;; esac
        done
        has_tail=0; for o in "${opts[@]+"${opts[@]}"}"; do [[ "$o" == --tail* || "$o" == --since* ]] && has_tail=1; done
        [[ "${has_tail}" == 1 ]] || opts=(--tail 100 "${opts[@]+"${opts[@]}"}")
        dc logs "${opts[@]}" "${svcs[@]+"${svcs[@]}"}"
        ;;
    stop)
        confirm "Arrêt de tous les conteneurs" "le site sera coupé"
        dc stop
        echo "arrêté (conteneurs et volumes conservés). Redémarrer : scripts/ops.sh ${ENV_NAME} start"
        ;;
    start)
        dc start
        echo "démarré. Vérifier : scripts/ops.sh ${ENV_NAME} status"
        ;;
    restart)
        confirm "Redémarrage" "le site sera brièvement coupé"
        if [[ $# -gt 0 ]]; then dc restart "$(svc "$1")"; else dc restart; fi
        echo "Rappel : restart ne relit PAS le fichier d'environnement. Pour appliquer une valeur modifiée : vps-deploy up ${ENV_NAME} <version courante> (vps-deploy status)." >&2
        ;;
    shell) dc exec "$(svc "${1:-${DEFAULT_SHELL_SERVICE}}")" sh ;;
    check)  ( cd "${DIR}" && "${VPS_DEPLOY}" check "${ENV_NAME}" ) ;;
    backup) ( cd "${DIR}" && "${VPS_DEPLOY}" backup "${ENV_NAME}" ) ;;
    obs)    ( cd "${DIR}" && "${VPS_DEPLOY}" obs-sync ) ;;
    # ── Actions propres au projet : à ajouter ici (voir templates/scripts/README.md), toujours avec « confirm » si elles modifient des données.
    *) die "action inconnue « ${ACTION} ». Actions : status logs stop start restart shell check backup obs (aide : scripts/ops.sh help)" ;;
esac
