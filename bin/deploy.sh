#!/usr/bin/env bash
# VPS standard deployment tool (infra/README.md, ADR-0064) — the same
# protocol for every Docker project on the server, whatever its stack:
#
#   build an image once per commit (tag = commit SHA)
#     → staging, automatically
#     → production, manually, with the EXACT image staging validated
#     → automatic rollback if the health check fails
#
# The project describes itself in a committed `platform.env` at its root
# (see infra/templates/platform.env). Secrets stay in the per-environment
# env files (.env, .env.staging), never committed.
#
# Usage, from the project's checkout (staging checkout for build/watch,
# production checkout for promote):
#
#   deploy.sh build [ref] [env]    build images for ref (default origin/<branch of env>, env default staging)
#   deploy.sh up <env> <sha>       deploy an already-built SHA to an environment
#   deploy.sh watch [env]          cron-friendly: build + deploy env (default staging) if its branch moved
#   deploy.sh promote [sha] [-y]   deploy to prod the SHA currently on staging (or the given one)
#
# Environments: ENVIRONMENTS in platform.env (default "staging prod"), e.g.
# "dev staging prod". Each has its env file (ENV_FILE_<ENV>, default .env for
# prod, .env.<env> otherwise) and, for watch, its branch (BRANCH_<ENV>;
# staging defaults to STAGING_BRANCH). Only prod is never watched: it is
# reached by promotion only.
#   deploy.sh rollback <env>       redeploy the previous SHA of that environment
#   deploy.sh status               current/previous SHA and containers of each environment
#
# Every action is logged to $STATE_DIR/<app>/deploy.log; one lock per app
# means a build, a staging deploy and a promotion never overlap.
set -euo pipefail

# ── Configuration ───────────────────────────────────────────────────────
PROJECT_DIR="$(pwd)"
if [[ ! -f "${PROJECT_DIR}/platform.env" ]]; then
    echo "deploy: no platform.env in ${PROJECT_DIR} — run from the project's root (infra/templates/platform.env)" >&2
    exit 2
fi
# shellcheck disable=SC1091
source "${PROJECT_DIR}/platform.env"

: "${APP_NAME:?platform.env must set APP_NAME}"
: "${COMPOSE_FILE:=compose.yaml}"
: "${ENV_FILE_PROD:=.env}"
: "${ENV_FILE_STAGING:=.env.staging}"
: "${ENVIRONMENTS:=staging prod}"
: "${STAGING_BRANCH:=main}"
: "${HEALTH_SERVICE:=app}"
: "${HEALTH_CMD:=}"
: "${HEALTH_TIMEOUT:=120}"
: "${MIGRATE_SERVICE:=}"
: "${MIGRATE_CMD:=}"
: "${BACKUP_SERVICE:=}"
: "${BACKUP_CMD:=backup.sh}"
: "${KEEP_IMAGES:=5}"
: "${STATE_DIR:=/var/lib/vps-platform}"
# 1 when the image bakes environment-specific values at build time (e.g.
# Next.js NEXT_PUBLIC_*): each environment then gets its own image built
# from the same commit, tagged <sha>-<env>. Default 0: one image, promoted.
: "${BUILD_PER_ENV:=0}"
: "${NGINX_PROXY_CONTAINER:=nginx-proxy}"

APP_STATE="${STATE_DIR}/${APP_NAME}"
for _env in ${ENVIRONMENTS}; do mkdir -p "${APP_STATE}/${_env}"; done
LOG="${APP_STATE}/deploy.log"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] ${APP_NAME}: $*" | tee -a "${LOG}" >&2; }
die() {
    log "ERREUR — $*"
    # Failure before the switch: put the checkout back on the version that runs.
    if [[ -n "${REVERT_CHECKOUT:-}" ]]; then
        local back="${REVERT_CHECKOUT}"; REVERT_CHECKOUT=""
        git -C "${PROJECT_DIR}" checkout --quiet --detach "${back}" 2>/dev/null || true
    fi
    exit 1
}

is_env() { [[ " ${ENVIRONMENTS} " == *" $1 "* ]]; }

env_file_for() {
    is_env "$1" || die "environnement inconnu « $1 » (${ENVIRONMENTS})"
    local var="ENV_FILE_${1^^}"
    case "$1" in
        prod) echo "${ENV_FILE_PROD}" ;;
        staging) echo "${ENV_FILE_STAGING}" ;;
        *) echo "${!var:-.env.$1}" ;;
    esac
}

branch_for() {
    local var="BRANCH_${1^^}"
    if [[ -n "${!var:-}" ]]; then echo "${!var}"
    elif [[ "$1" == staging ]]; then echo "${STAGING_BRANCH}"
    else die "aucune branche pour « $1 » : définir ${var} dans platform.env"
    fi
}

# docker compose for one environment, images pinned to IMAGE_TAG.
dc() {
    local env="$1"; shift
    local envfile; envfile="$(env_file_for "${env}")"
    [[ -f "${envfile}" ]] || die "fichier ${envfile} absent (copier l'exemple et le remplir)"
    # COMPOSE_FILE may list several files separated by ':' (base + override),
    # like Docker's own COMPOSE_FILE variable.
    local files=() f
    IFS=':' read -ra parts <<< "${COMPOSE_FILE}"
    for f in "${parts[@]}"; do files+=(-f "${f}"); done
    IMAGE_TAG="${IMAGE_TAG:-latest}" docker compose -p "${APP_NAME}-${env}" "${files[@]}" --env-file "${envfile}" "$@"
}

state_get() { cat "${APP_STATE}/$1/$2" 2>/dev/null || true; }
state_set() { echo "$3" > "${APP_STATE}/$1/$2"; }

is_git() { git -C "${PROJECT_DIR}" rev-parse --git-dir >/dev/null 2>&1; }

lock() {
    exec 9>"${APP_STATE}/lock"
    flock -n 9 || die "un autre déploiement de ${APP_NAME} est en cours"
}

tag_for() {
    if [[ "${BUILD_PER_ENV}" == 1 ]]; then echo "$2-$1"; else echo "$2"; fi
}

# Images of this project built for a SHA (only those carrying the tag).
images_for() {
    local env="$1" tag; tag="$(tag_for "$1" "$2")"
    IMAGE_TAG="${tag}" dc "${env}" config --images 2>/dev/null | grep -E ":${tag}$" | sort -u || true
}

missing_images() {
    local env="$1" sha="$2" img found=0 missing=0
    while read -r img; do
        [[ -z "${img}" ]] && continue
        found=1
        docker image inspect "${img}" >/dev/null 2>&1 || { log "image absente : ${img}"; missing=1; }
    done < <(images_for "${env}" "${sha}")
    [[ "${found}" == 1 ]] || die "aucune image du compose n'utilise \${IMAGE_TAG} — voir infra/templates"
    [[ "${missing}" == 1 ]]
}

build_for() {
    local env="$1" sha="$2"
    log "build ${env} ${sha}"
    # --pull refreshes base images; when the registry refuses (Docker Hub rate
    # limit, outage), the base images already on the server are used instead.
    if ! IMAGE_TAG="$(tag_for "${env}" "${sha}")" dc "${env}" build --pull >&2; then
        log "build avec --pull en échec (registre indisponible ou quota ?) — nouvel essai avec les images de base locales"
        IMAGE_TAG="$(tag_for "${env}" "${sha}")" dc "${env}" build >&2 || die "build ${sha} (${env}) en échec"
    fi
}

ensure_images() {
    local env="$1" sha="$2"
    missing_images "${env}" "${sha}" || return 0
    if [[ "${BUILD_PER_ENV}" == 1 ]]; then
        build_for "${env}" "${sha}"
    else
        die "images de ${sha} absentes — lancer d'abord « deploy.sh build ${sha} » (dans le checkout de staging)"
    fi
}

checkout() {
    local sha="$1"
    is_git || { log "pas un dépôt git — fichiers du projet laissés tels quels"; return 0; }
    git -C "${PROJECT_DIR}" fetch --quiet origin || log "git fetch impossible — on continue avec les objets locaux"
    git -C "${PROJECT_DIR}" checkout --quiet --detach "${sha}" || die "commit ${sha} introuvable dans ${PROJECT_DIR}"
}

# Refuses to deploy when a host name of this project is already claimed by
# another project (exactly or through its wildcard): nginx-proxy would not
# complain, it would split the traffic between the two applications.
check_hosts() {
    local env="$1" tag="$2" names
    names="$(IMAGE_TAG="${tag}" dc "${env}" config --format json 2>/dev/null \
        | grep -o '"VIRTUAL_HOST": *"[^"]*"' | cut -d'"' -f4 | paste -sd, - || true)"
    [[ -z "${names}" ]] && return 0
    local out
    out="$("$(dirname "${BASH_SOURCE[0]}")/vps-hosts.sh" --check "${names}" --project "${APP_NAME}-${env}" 2>&1)" && return 0
    log "${out}"
    return 1
}

# Refuses to deploy while a volume of this environment is used by a
# container that is not part of it — typically the previous installation of
# the project, still running: two databases on the same data directory
# corrupt it. A container is part of the environment when it carries its
# compose project AND is one of the current services (an old stack may reuse
# the project name with other service names, e.g. cpf_dev_db vs db).
volumes_in_use_elsewhere() {
    local env="$1" tag="$2" vol c project service found="" services
    services=" $(IMAGE_TAG="${tag}" dc "${env}" config --services 2>/dev/null | tr '\n' ' ') "
    while read -r vol; do
        [[ -z "${vol}" ]] && continue
        while read -r c; do
            [[ -z "${c}" ]] && continue
            project="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "${c}")"
            service="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.service"}}' "${c}")"
            [[ "${project}" == "${APP_NAME}-${env}" && "${services}" == *" ${service} "* ]] && continue
            found+=" ${vol} (utilisé par $(docker inspect -f '{{.Name}}' "${c}" | sed 's#^/##'))"
        done < <(docker ps -q --filter "volume=${vol}")
    done < <(IMAGE_TAG="${tag}" dc "${env}" config 2>/dev/null \
        | awk '/^volumes:/ {v = 1; next} /^[^ ]/ {v = 0} v && $1 == "name:" {print $2}')
    [[ -z "${found}" ]] && return 1
    log "volume(s) en cours d'utilisation hors de ${APP_NAME}-${env} :${found}"
    return 0
}

# nginx-proxy regenerates its config at every container change. If the
# result is invalid, nginx keeps the OLD config and ignores every later
# change on the whole VPS — refuse to deploy into that state, and treat a
# deploy that causes it as a failed deploy. No-op without that container.
proxy_config_ok() {
    docker container inspect "${NGINX_PROXY_CONTAINER}" >/dev/null 2>&1 || return 0
    local out
    out="$(docker exec "${NGINX_PROXY_CONTAINER}" nginx -t 2>&1)" && return 0
    log "nginx-proxy refuse sa configuration : $(grep -m1 emerg <<< "${out}")"
    return 1
}

health() {
    local env="$1" deadline=$((SECONDS + HEALTH_TIMEOUT))
    [[ -z "${HEALTH_CMD}" ]] && { log "pas de HEALTH_CMD — santé non vérifiée"; return 0; }
    while (( SECONDS < deadline )); do
        if dc "${env}" exec -T "${HEALTH_SERVICE}" sh -c "${HEALTH_CMD}" >/dev/null 2>&1; then
            return 0
        fi
        sleep 3
    done
    return 1
}

prune_images() {
    local keep=() img repo s
    local e
    for env in ${ENVIRONMENTS}; do
        for s in "$(state_get "${env}" current)" "$(state_get "${env}" previous)"; do
            keep+=("${s}")
            for e in ${ENVIRONMENTS}; do keep+=("${s}-${e}"); done
        done
    done
    # Repositories of this project's own images (those tagged with a SHA).
    local sha="" e
    for e in ${ENVIRONMENTS}; do [[ -z "${sha}" ]] && sha="$(state_get "${e}" current)"; done
    [[ -z "${sha}" ]] && return 0
    while read -r img; do
        repo="${img%:*}"
        docker image ls "${repo}" --format '{{.Tag}} {{.CreatedAt}}' \
            | grep -E '^[0-9a-f]{40}(-[a-z0-9]+)? ' | sort -k2 -r | awk '{print $1}' \
            | tail -n +"$((KEEP_IMAGES + 1))" | while read -r tag; do
                [[ " ${keep[*]} " == *" ${tag} "* ]] && continue
                docker image rm "${repo}:${tag}" >/dev/null 2>&1 && log "image supprimée ${repo}:${tag}"
            done
    done < <(for e in ${ENVIRONMENTS}; do images_for "${e}" "${sha}"; done | sort -u)
}

# ── Commands ────────────────────────────────────────────────────────────
cmd_build() {
    local env="${2:-staging}"
    local ref="${1:-origin/$(branch_for "${env}")}" sha
    if is_git; then
        git -C "${PROJECT_DIR}" fetch --quiet origin
        sha="$(git -C "${PROJECT_DIR}" rev-parse "${ref}^{commit}")"
        git -C "${PROJECT_DIR}" checkout --quiet --detach "${sha}"
    else
        [[ "${ref}" =~ ^[0-9a-f]{40}$ ]] || die "hors git, build exige un SHA explicite"
        sha="${ref}"
    fi
    build_for "${env}" "${sha}"
    echo "${sha}"
}

cmd_up() {
    local env="${1:?env}" sha="${2:?sha}" previous
    previous="$(state_get "${env}" current)"
    checkout "${sha}"
    is_git && REVERT_CHECKOUT="${previous}"
    ensure_images "${env}" "${sha}"
    local tag; tag="$(tag_for "${env}" "${sha}")"
    proxy_config_ok || die "nginx-proxy est déjà en erreur — aucun déploiement ne serait pris en compte. Corriger d'abord (infra/bin/vps-audit.sh, infra/bin/vps-hosts.sh)"
    if ! check_hosts "${env}" "${tag}"; then
        state_set "${env}" failed "${sha}"
        die "noms d'hôte déjà utilisés par un autre projet (voir ci-dessus) — rien n'a été modifié. Inventaire : infra/bin/vps-hosts.sh"
    fi

    if volumes_in_use_elsewhere "${env}" "${tag}"; then
        die "arrêter d'abord l'ancienne installation qui utilise ces volumes (deux bases sur les mêmes données les corrompent) — rien n'a été modifié"
    fi

    log "déploiement ${env} ${sha} (précédent : ${previous:-aucun})"

    if [[ "${env}" == prod && -n "${BACKUP_SERVICE}" && "${SKIP_BACKUP:-0}" != 1 ]]; then
        log "sauvegarde avant migration"
        IMAGE_TAG="${tag}" dc "${env}" run --rm -T -e BACKUP_LABEL="pre-deploy-${sha:0:12}" "${BACKUP_SERVICE}" sh -c "${BACKUP_CMD}" \
            || die "sauvegarde en échec — déploiement annulé (SKIP_BACKUP=1 pour forcer)"
    fi

    if [[ -n "${MIGRATE_CMD}" ]]; then
        log "migrations"
        if ! IMAGE_TAG="${tag}" dc "${env}" run --rm -T "${MIGRATE_SERVICE:-${HEALTH_SERVICE}}" sh -c "${MIGRATE_CMD}"; then
            die "migrations en échec — la version ${previous:-précédente} tourne toujours, rien n'a été basculé"
        fi
    fi

    REVERT_CHECKOUT=""   # switching now: from here on, the rollback below handles the checkout
    IMAGE_TAG="${tag}" dc "${env}" up -d --no-build --remove-orphans

    if IMAGE_TAG="${tag}" health "${env}" && { sleep 3; proxy_config_ok; }; then
        state_set "${env}" previous "${previous}"
        state_set "${env}" current "${sha}"
        echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) ${sha}" >> "${APP_STATE}/${env}/history"
        rm -f "${APP_STATE}/${env}/failed"
        log "OK ${env} = ${sha}"
        prune_images || true
        return 0
    fi

    state_set "${env}" failed "${sha}"
    if [[ -n "${previous}" ]]; then
        log "santé KO — retour automatique à ${previous}"
        checkout "${previous}"
        IMAGE_TAG="$(tag_for "${env}" "${previous}")" dc "${env}" up -d --no-build --remove-orphans || true
        if IMAGE_TAG="$(tag_for "${env}" "${previous}")" health "${env}"; then
            log "retour automatique réussi : ${env} = ${previous}, en ligne"
        else
            log "ATTENTION : la version précédente ${previous} ne répond pas non plus — intervention requise (deploy.sh status, docker compose logs)"
        fi
        log "les migrations éventuelles de ${sha} ne sont PAS annulées ; si nécessaire : infra/bin/restore.sh (dernière sauvegarde pre-deploy)"
    fi
    die "${env} ${sha} ne répond pas à « ${HEALTH_CMD} » après ${HEALTH_TIMEOUT}s"
}

cmd_watch() {
    # watch [env] — or, for compatibility, watch [branch] (staging).
    local env=staging branch target
    if [[ -n "${1:-}" ]] && is_env "$1"; then env="$1"; branch="$(branch_for "${env}")"
    else branch="${1:-$(branch_for staging)}"
    fi
    [[ "${env}" == prod ]] && die "la production n'est jamais déployée automatiquement : deploy.sh promote"
    is_git || die "watch exige un checkout git"
    git -C "${PROJECT_DIR}" fetch --quiet origin
    target="$(git -C "${PROJECT_DIR}" rev-parse "origin/${branch}^{commit}")"
    [[ "${target}" == "$(state_get "${env}" current)" ]] && exit 0
    [[ "${target}" == "$(state_get "${env}" failed)" ]] && exit 0   # pas de boucle sur un commit cassé
    log "nouvelle version sur ${branch} (${env}) : ${target}"
    cmd_build "${target}" "${env}" >/dev/null
    cmd_up "${env}" "${target}"
}

cmd_promote() {
    local sha="" yes=0 arg
    for arg in "$@"; do
        case "${arg}" in
            -y|--yes) yes=1 ;;
            *) sha="${arg}" ;;
        esac
    done
    sha="${sha:-$(state_get staging current)}"
    [[ -n "${sha}" ]] || die "aucune version en staging à promouvoir"
    if [[ "${sha}" != "$(state_get staging current)" ]]; then
        log "ATTENTION : ${sha} n'est pas la version actuellement en staging ($(state_get staging current))"
    fi
    echo "Production : $(state_get prod current || true) → ${sha}"
    if [[ "${yes}" != 1 ]]; then
        read -r -p "Déployer en PRODUCTION ? Tapez « oui » : " answer
        [[ "${answer}" == "oui" ]] || die "promotion annulée"
    fi
    cmd_up prod "${sha}"
}

cmd_rollback() {
    local env="${1:?env}" previous
    previous="$(state_get "${env}" previous)"
    [[ -n "${previous}" ]] || die "aucune version précédente connue pour ${env}"
    MIGRATE_CMD="" SKIP_BACKUP=1 cmd_up "${env}" "${previous}"
}

cmd_status() {
    for env in ${ENVIRONMENTS}; do
        echo "── ${env} : $(state_get "${env}" current || true)  (précédent : $(state_get "${env}" previous || true))"
        [[ -n "$(state_get "${env}" failed)" ]] && echo "   dernier échec : $(state_get "${env}" failed)"
        [[ -f "$(env_file_for "${env}")" ]] && dc "${env}" ps --format 'table {{.Name}}\t{{.Status}}' 2>/dev/null || true
    done
}

main() {
    local cmd="${1:-}"; shift || true
    case "${cmd}" in
        build) lock; cmd_build "$@" ;;
        up) lock; cmd_up "$@" ;;
        watch) lock; cmd_watch "$@" ;;
        promote) lock; cmd_promote "$@" ;;
        rollback) lock; cmd_rollback "$@" ;;
        status) cmd_status ;;
        *) sed -n '2,25p' "$0"; exit 2 ;;
    esac
}

main "$@"
