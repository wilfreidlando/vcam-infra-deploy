#!/usr/bin/env bash
# VPS standard deployment tool (README.md, ADR-0064) — the same
# protocol for every Docker project on the server, whatever its stack:
#
#   build an image once per commit (tag = commit SHA)
#     → staging, automatically
#     → production, manually, with the EXACT image staging validated
#     → automatic rollback if the health check fails
#
# The project describes itself in a committed `platform.env` at its root
# (see templates/platform.env). Secrets stay in the per-environment
# env files (.env, .env.staging), never committed.
#
# Usage, from the project's checkout (staging checkout for build/watch,
# production checkout for promote):
#
#   deploy.sh build [ref] [env]    build images for ref (default origin/<branch of env>, env default staging)
#   deploy.sh up <env> <sha>       deploy an already-built SHA to an environment
#   deploy.sh watch [env]          cron-friendly: build + deploy env (default staging) if its branch moved
#   deploy.sh promote [sha|ref] [-y] [--env <prod>]
#                                  deploy to a production the SHA currently on staging (or the given one;
#                                  required when the project has no staging). --env: which production,
#                                  when the project has several (PROD_ENVIRONMENTS)
#
# Branches: each project says which branch each environment follows, and nothing is imposed (develop for staging and main for
# production is one choice; main for both, or a production without staging, are others):
#   BRANCH_<ENV>      the branch `watch` follows for a non-production environment (STAGING_BRANCH is the older name of BRANCH_STAGING)
#   BRANCH_<PROD>     OPTIONAL guard on a production (e.g. BRANCH_PROD=main): `promote` refuses a version that is not already in
#                     origin/<branch> — merge what staging validated, then promote. Without it, no constraint. A project WITHOUT staging
#                     (ENVIRONMENTS=prod) builds origin/<branch> when `promote` is given no version.
#
# Environments: ENVIRONMENTS in platform.env (default "staging prod"), e.g.
# "dev staging prod". Each has its env file (ENV_FILE_<ENV>, default .env for
# prod, .env.<env> otherwise) and, for watch, its branch (BRANCH_<ENV>;
# staging defaults to STAGING_BRANCH). A production is never watched: it is
# reached by promotion only. Productions are the environments of PROD_ENVIRONMENTS
# (default "prod"): a project may have no staging (ENVIRONMENTS="prod") or several
# productions (ENVIRONMENTS="staging prod prodeu", PROD_ENVIRONMENTS="prod prodeu").
#                                  deploy.sh takes NO backup of its own by default: the nightly one is the safety
#                                  net (BACKUP_BEFORE_DEPLOY=always to take one before every deploy)
#   deploy.sh backup [env]         one backup now (a manual backup before a risky migration)
#   deploy.sh obs-sync [--remove]  publish the project's OWN Grafana dashboards and alert rules (OBS_BUNDLE, default
#                                  observability/) into the platform's Grafana tree, without touching the platform
#                                  repo. Run automatically after a successful production deploy. See bin/obs-bundle.py.
#   deploy.sh rollback <env>       redeploy the previous SHA of that environment
#   deploy.sh status               current/previous SHA and containers of each environment
#   deploy.sh check [env]          pre-flight only (git access, platform.env ↔ compose,
#                                  name collisions on shared networks) — changes nothing
#   deploy.sh where                where the platform is and which version (no project needed) — changes nothing
#
# Short commands: host/install-commands.sh installs `vps-deploy` (= this script) and friends in the PATH, so nobody types the path.
#
# platform.env is read from the commit being deployed (re-read after every
# checkout): a change to it takes effect with the commit that carries it.
# Every deploy runs the pre-flight first and changes nothing if it fails.
#
# Every action is logged to $STATE_DIR/<app>/deploy.log; one lock per app
# means a build, a staging deploy and a promotion never overlap.
set -euo pipefail

# ── Configuration ───────────────────────────────────────────────────────
PROJECT_DIR="$(pwd)"
# The platform clone this script lives in (/app/vps-platform on the server). The script is resolved through any symlink first: a link in
# the PATH (or anywhere else) must still find the REAL platform, never the folder holding the link.
SELF="$(readlink -f "${BASH_SOURCE[0]}")"
PLATFORM_ROOT="$(cd "$(dirname "${SELF}")/.." && pwd)"
# `deploy.sh where` : where the platform is and which version. Needs no project, no platform.env, and changes nothing.
# The usage is shown from anywhere (no project needed): empty argument = exit 2 as before, explicit help = exit 0.
case "${1:-}" in
    ""|help|-h|--help) sed -n '2,/^set -euo/p' "${SELF}" | sed '$d'; [[ -z "${1:-}" ]] && exit 2; exit 0 ;;
esac
if [[ "${1:-}" == where ]]; then
    echo "plateforme : ${PLATFORM_ROOT}"
    echo "version    : $(git --git-dir="${PLATFORM_ROOT}/.git" rev-parse --short HEAD 2>/dev/null || echo inconnue) ($(git --git-dir="${PLATFORM_ROOT}/.git" log -1 --format=%cs 2>/dev/null || echo '?'))"
    echo "script     : ${SELF}"
    exit 0
fi
# Never wait for a password: under cron nobody types it (an HTTPS remote
# would hang the deploy). Failures are explained by fetch_origin.
export GIT_TERMINAL_PROMPT=0
export GIT_SSH_COMMAND="${GIT_SSH_COMMAND:-ssh -o BatchMode=yes}"

# Keys a project sets in platform.env. Forgotten before every (re)load, so a
# key removed from platform.env in the deployed commit does not survive from
# the previous one. Host-level settings (STATE_DIR, NGINX_PROXY_*,
# KEEP_IMAGES, SKIP_BACKUP) are not project keys and keep their value.
PROJECT_KEYS="APP_NAME COMPOSE_FILE ENV_FILE_PROD ENV_FILE_STAGING ENVIRONMENTS STAGING_BRANCH
    HEALTH_SERVICE HEALTH_CMD HEALTH_TIMEOUT MIGRATE_SERVICE MIGRATE_CMD
    BACKUP_SERVICE BACKUP_CMD DB_SERVICE BUILD_PER_ENV PROD_ENVIRONMENTS
    BACKUP_BEFORE_DEPLOY OBS_BUNDLE"

# Reads platform.env from the working tree: at start-up, then again after
# each checkout (checkout()), so the services, commands and environments
# used are always those of the commit being deployed — not those of the
# commit that happened to be checked out before.
load_config() {
    if [[ ! -f "${PROJECT_DIR}/platform.env" ]]; then
        echo "deploy: no platform.env in ${PROJECT_DIR} — run from the project's root (templates/platform.env)" >&2
        exit 2
    fi
    local v previous_app="${APP_NAME:-}"
    # shellcheck disable=SC2086
    for v in ${PROJECT_KEYS} $(compgen -v | grep -E '^(BRANCH|ENV_FILE)_' || true); do unset "${v}"; done
    # shellcheck disable=SC1091
    source "${PROJECT_DIR}/platform.env"
    load_defaults
    if [[ -n "${previous_app}" && "${APP_NAME}" != "${previous_app}" ]]; then
        echo "deploy: APP_NAME passe de ${previous_app} à ${APP_NAME} — un renommage n'est pas un déploiement (nouveaux projets Docker, nouveaux volumes). Voir README, « Renommer un projet »." >&2
        exit 2
    fi
}

load_defaults() {
: "${APP_NAME:?platform.env must set APP_NAME}"
: "${COMPOSE_FILE:=compose.yaml}"
: "${ENV_FILE_PROD:=.env}"
: "${ENV_FILE_STAGING:=.env.staging}"
: "${ENVIRONMENTS:=staging prod}"
# Environments that are production: never auto-deployed, backed up before each deploy, promoted by hand.
: "${PROD_ENVIRONMENTS:=prod}"
: "${STAGING_BRANCH:=main}"
: "${HEALTH_SERVICE:=app}"
: "${HEALTH_CMD:=}"
: "${HEALTH_TIMEOUT:=120}"
: "${MIGRATE_SERVICE:=}"
: "${MIGRATE_CMD:=}"
: "${BACKUP_SERVICE:=}"
: "${BACKUP_CMD:=backup.sh}"
# Backup taken by deploy.sh before a production deploy: « never » (default: the nightly backup is the safety net,
# and a manual one is one command away: deploy.sh backup) or « always » (every deploy, a minute each).
: "${BACKUP_BEFORE_DEPLOY:=never}"
# Folder of the project holding its own Grafana dashboards (dashboards/*.json) and alert rules (alerts/*.yaml).
: "${OBS_BUNDLE:=observability}"
: "${KEEP_IMAGES:=5}"
: "${STATE_DIR:=/var/lib/vps-platform}"
# 1 when the image bakes environment-specific values at build time (e.g.
# Next.js NEXT_PUBLIC_*): each environment then gets its own image built
# from the same commit, tagged <sha>-<env>. Default 0: one image, promoted.
: "${BUILD_PER_ENV:=0}"
: "${NGINX_PROXY_CONTAINER:=nginx-proxy}"
APP_STATE="${STATE_DIR}/${APP_NAME}"
local _env
for _env in ${ENVIRONMENTS}; do
    # Names end up in Docker project names, image tags and variable names (ENV_FILE_<ENV>).
    [[ "${_env}" =~ ^[a-z][a-z0-9]*$ ]] || { echo "deploy: nom d'environnement « ${_env} » invalide : lettres minuscules et chiffres seulement (prod, prodeu, staging)" >&2; exit 2; }
    mkdir -p "${APP_STATE}/${_env}"
done
for _env in ${PROD_ENVIRONMENTS}; do
    [[ " ${ENVIRONMENTS} " == *" ${_env} "* ]] || { echo "deploy: PROD_ENVIRONMENTS contient « ${_env} », absent de ENVIRONMENTS (${ENVIRONMENTS})" >&2; exit 2; }
done
LOG="${APP_STATE}/deploy.log"
}

load_config

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
is_prod() { [[ " ${PROD_ENVIRONMENTS} " == *" $1 "* ]]; }

# First environment that is not a production (staging, dev…): where builds and watch happen. Empty when
# the project has none.
preprod_env() {
    local e
    if [[ " ${ENVIRONMENTS} " == *" staging "* ]]; then echo staging; return; fi
    for e in ${ENVIRONMENTS}; do is_prod "${e}" || { echo "${e}"; return; }; done
}

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
    elif is_prod "$1" && [[ -z "$(preprod_env)" ]]; then echo "${STAGING_BRANCH}"   # no staging: the production follows the main branch
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
    [[ "${found}" == 1 ]] || die "aucune image du compose n'utilise \${IMAGE_TAG} — voir templates"
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
    if [[ "${BUILD_PER_ENV}" == 1 || -z "$(preprod_env)" ]]; then
        # Per-environment images, or a project without staging: nobody built it before, build here.
        build_for "${env}" "${sha}"
    else
        die "images de ${sha} absentes — lancer d'abord « deploy.sh build ${sha} » (dans le checkout de staging)"
    fi
}

# git fetch, without ever prompting; on failure, says why and how to fix.
fetch_origin() {
    local err url
    err="$(git -C "${PROJECT_DIR}" fetch --quiet origin 2>&1)" && return 0
    url="$(git -C "${PROJECT_DIR}" remote get-url origin 2>/dev/null || echo '?')"
    if [[ "${url}" == http* ]]; then
        log "git fetch impossible : origin est en HTTPS (${url}) et GitHub demande un identifiant — personne ne le tape sous cron. Passer par la clé de déploiement du projet (guide 3, « clés de déploiement ») : git remote set-url origin git@github-${APP_NAME}:<compte>/<dépôt>.git"
    else
        log "git fetch impossible (${url}) : $(head -1 <<< "${err}") — clé de déploiement absente ou refusée, ou hôte inconnu (ssh -T git@<alias> une première fois, guide 3)"
    fi
    return 1
}

checkout() {
    local sha="$1"
    is_git || { log "pas un dépôt git — fichiers du projet laissés tels quels"; return 0; }
    fetch_origin || log "on continue avec les commits déjà présents localement"
    git -C "${PROJECT_DIR}" checkout --quiet --detach "${sha}" || die "commit ${sha} introuvable dans ${PROJECT_DIR}"
    load_config
}

# Pre-flight: everything that can be known to fail BEFORE touching anything.
# Prints one line per problem; returns 1 if there is any.
preflight() {
    local env="$1" tag="$2" problems=0 services var val cfg
    cfg="$(IMAGE_TAG="${tag}" dc "${env}" config 2>&1)" || { log "compose invalide : $(tail -1 <<< "${cfg}")"; return 1; }
    services=" $(IMAGE_TAG="${tag}" dc "${env}" config --services 2>/dev/null | tr '\n' ' ') "

    # 1. platform.env names services that exist in this commit's compose.
    for var in HEALTH_SERVICE MIGRATE_SERVICE BACKUP_SERVICE DB_SERVICE; do
        val="${!var:-}"
        [[ -z "${val}" ]] && continue
        [[ "${var}" == HEALTH_SERVICE && -z "${HEALTH_CMD}" ]] && continue
        [[ "${var}" == MIGRATE_SERVICE && -z "${MIGRATE_CMD}" ]] && continue
        if [[ "${services}" != *" ${val} "* ]]; then
            log "platform.env : ${var}=${val}, mais le compose n'a pas de service « ${val} » (services :${services% })"
            problems=1
        fi
    done

    # 2. Names of this project's PRIVATE services (base, cache, php-fpm…)
    #    also published on a shared network (nginx-proxy, observability) by
    #    another project: from a container on both networks, Docker may
    #    resolve the name to the other project's container.
    local line
    while IFS= read -r line; do
        [[ -z "${line}" ]] && continue
        log "${line}"
        problems=1
    done < <(shared_name_conflicts "${env}" <<< "${cfg}")

    return "${problems}"
}

# Reads `docker compose config` (normalised YAML) on stdin.
shared_name_conflicts() {
    local env="$1" parsed
    parsed="$(awk '
        /^[a-z]/ { top = $1; next }
        top == "services:" && /^  [^ ]/ { svc = $1; sub(/:$/, "", svc); innet = 0; next }
        top == "services:" && /^    [^ ]/ { innet = ($1 == "networks:"); next }
        top == "services:" && innet && /^      [^ ]/ { net = $1; sub(/:$/, "", net); print "N", svc, net, svc; next }
        top == "services:" && innet && /^          - / { print "N", svc, net, $2; next }
        top == "networks:" && /^  [^ ]/ { k = $1; sub(/:$/, "", k); real[k] = k; next }
        top == "networks:" && /^    name:/ { real[k] = $2 }
        top == "networks:" && /^    external: true/ { ext[k] = 1 }
        END { for (k in ext) print "X", k, real[k] }')"
    local -A shared=() on_shared=() private_names=()
    local kind a b c
    while read -r kind a b c; do [[ "${kind}" == X ]] && shared["${a}"]="${b}"; done <<< "${parsed}"
    [[ ${#shared[@]} -eq 0 ]] && return 0
    while read -r kind a b c; do [[ "${kind}" == N && -n "${shared[${b}]:-}" ]] && on_shared["${a}"]=1; done <<< "${parsed}"
    while read -r kind a b c; do
        [[ "${kind}" == N && -z "${on_shared[${a}]:-}" ]] && private_names["${c}"]="${a}"
    done <<< "${parsed}"
    [[ ${#private_names[@]} -eq 0 ]] && return 0

    local net container project names name
    for net in $(printf '%s\n' "${shared[@]}" | sort -u); do
        docker network inspect "${net}" >/dev/null 2>&1 || continue
        for container in $(docker network inspect -f '{{range .Containers}}{{.Name}} {{end}}' "${net}"); do
            project="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "${container}" 2>/dev/null || true)"
            [[ "${project}" == "${APP_NAME}-${env}" ]] && continue
            names="$(docker inspect -f "{{json (index .NetworkSettings.Networks \"${net}\")}}" "${container}" 2>/dev/null \
                | grep -oE '"(Aliases|DNSNames)":\[[^]]*\]' | grep -oE '"[^"]*"' | tr -d '"' | grep -vxE 'Aliases|DNSNames' || true)"
            for name in ${container} ${names}; do
                [[ -n "${private_names[${name}]:-}" ]] || continue
                echo "nom « ${name} » (service privé ${private_names[${name}]}) aussi publié sur le réseau partagé ${net} par ${container} (projet ${project:-hors compose}) : Docker peut y résoudre « ${name} » vers ce conteneur-là. Donner au service un nom propre au projet (ex. ${APP_NAME}-${name}), ou retirer ${container} de ${net}"
            done
        done
    done | sort -u
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
    out="$("$(dirname "${SELF}")/vps-hosts.sh" --check "${names}" --project "${APP_NAME}-${env}" 2>&1)" && return 0
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
    # Only environments whose env file is in THIS checkout: /app/<project>/prod has .env only and
    # /app/<project>/staging .env.staging only. Asking for the other one used to die here
    # ("fichier … absent") and nothing was ever pruned. Image names are the same in every environment.
    done < <(for e in ${ENVIRONMENTS}; do [[ -f "$(env_file_for "${e}")" ]] || continue; images_for "${e}" "${sha}"; done | sort -u)
}

# ── Commands ────────────────────────────────────────────────────────────
# The project's own rule on a production: only a version already contained in BRANCH_<ENV> can be promoted. No variable, no rule.
guard_branch() {  # guard_branch <env> <sha>
    local env="$1" sha="$2" var="BRANCH_${1^^}" br
    br="${!var:-}"
    [[ -n "${br}" ]] || return 0
    if [[ "${SKIP_BRANCH_CHECK:-0}" == 1 ]]; then
        log "SKIP_BRANCH_CHECK=1 : ${sha:0:12} non vérifié contre origin/${br} (exception, avec l'accord du responsable)"
        return 0
    fi
    is_git || { log "hors git : la branche ${br} n'est pas vérifiée"; return 0; }
    fetch_origin || die "impossible de vérifier la branche ${br} (voir ci-dessus)"
    git -C "${PROJECT_DIR}" rev-parse --verify --quiet "origin/${br}^{commit}" >/dev/null \
        || die "la branche de production « ${br} » (${var} dans platform.env) n'existe pas sur origin"
    git -C "${PROJECT_DIR}" merge-base --is-ancestor "${sha}" "origin/${br}" \
        || die "${sha:0:12} n'est pas dans origin/${br} (${var} dans platform.env) : fusionner d'abord dans ${br} la version validée. Exception, avec l'accord du responsable : SKIP_BRANCH_CHECK=1"
}

# One line saying which branch an environment follows, or checks against (used by status and check).
describe_branch() {  # describe_branch <env>
    local env="$1" var="BRANCH_${1^^}"
    if is_prod "${env}"; then
        if [[ -z "$(preprod_env)" ]]; then
            if [[ -n "${!var:-}" ]]; then echo "production sans staging : construit origin/${!var} quand on la promeut (${var})"
            else echo "production sans staging, branche non déclarée : donner la version à promouvoir, ou définir ${var} dans platform.env"; fi
        elif [[ -n "${!var:-}" ]]; then echo "production : ne reçoit que ce qui est déjà dans origin/${!var} (${var})"
        else echo "production : aucune contrainte de branche (${var} non défini)"; fi
    else
        echo "suit origin/$(branch_for "${env}" 2>/dev/null || echo "?  (définir ${var} dans platform.env)")"
    fi
}

cmd_build() {
    local env="${2:-$(preprod_env)}"
    [[ -n "${env}" ]] || env="${PROD_ENVIRONMENTS%% *}"
    local ref="${1:-origin/$(branch_for "${env}")}" sha
    if is_git; then
        fetch_origin || die "impossible de récupérer ${ref} (voir ci-dessus)"
        sha="$(git -C "${PROJECT_DIR}" rev-parse "${ref}^{commit}")"
        git -C "${PROJECT_DIR}" checkout --quiet --detach "${sha}"
        load_config
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
    proxy_config_ok || die "nginx-proxy est déjà en erreur — aucun déploiement ne serait pris en compte. Corriger d'abord (bin/vps-audit.sh, bin/vps-hosts.sh)"
    if ! preflight "${env}" "${tag}"; then
        state_set "${env}" failed "${sha}"
        die "contrôle avant déploiement en échec (ci-dessus) — rien n'a été modifié. Corriger, vérifier avec « deploy.sh check ${env} », puis pousser un commit ou relancer « deploy.sh up ${env} ${sha} »"
    fi
    if ! check_hosts "${env}" "${tag}"; then
        state_set "${env}" failed "${sha}"
        die "noms d'hôte déjà utilisés par un autre projet (voir ci-dessus) — rien n'a été modifié. Inventaire : bin/vps-hosts.sh"
    fi

    if volumes_in_use_elsewhere "${env}" "${tag}"; then
        die "arrêter d'abord l'ancienne installation qui utilise ces volumes (deux bases sur les mêmes données les corrompent) — rien n'a été modifié. Cas d'un service renommé dans ce commit : l'ancien conteneur tient encore le volume ; l'arrêter (docker rm -f <conteneur> — les volumes restent) puis relancer"
    fi

    log "déploiement ${env} ${sha} (précédent : ${previous:-aucun})"

    if is_prod "${env}" && [[ -n "${BACKUP_SERVICE}" && "${SKIP_BACKUP:-0}" != 1 && "${BACKUP_BEFORE_DEPLOY}" == always ]]; then
        log "sauvegarde avant déploiement (BACKUP_BEFORE_DEPLOY=always)"
        IMAGE_TAG="${tag}" dc "${env}" run --rm -T -e BACKUP_LABEL="pre-deploy-${sha:0:12}" "${BACKUP_SERVICE}" sh -c "${BACKUP_CMD}" \
            || die "sauvegarde en échec — déploiement annulé (SKIP_BACKUP=1 pour forcer)"
    fi

    if [[ -n "${MIGRATE_CMD}" && "${SKIP_MIGRATIONS:-0}" != 1 ]]; then
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
        is_prod "${env}" && { obs_publish || true; }
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
        log "les migrations éventuelles de ${sha} ne sont PAS annulées ; si nécessaire : bin/restore.sh (dernière sauvegarde pre-deploy)"
    fi
    die "${env} ${sha} ne répond pas à « ${HEALTH_CMD} » après ${HEALTH_TIMEOUT}s"
}

cmd_watch() {
    # watch [env] — or, for compatibility, watch [branch] (staging).
    local env branch target
    env="$(preprod_env)"
    [[ -n "${env}" ]] || die "ce projet n'a que des productions (${PROD_ENVIRONMENTS}) : rien ne se déploie automatiquement, voir « deploy.sh promote"
    if [[ -n "${1:-}" ]] && is_env "$1"; then env="$1"; branch="$(branch_for "${env}")"
    else branch="${1:-$(branch_for "${env}")}"
    fi
    is_prod "${env}" && die "la production n'est jamais déployée automatiquement : deploy.sh promote"
    is_git || die "watch exige un checkout git"
    fetch_origin || die "impossible de savoir si ${branch} a bougé (voir ci-dessus)"
    target="$(git -C "${PROJECT_DIR}" rev-parse "origin/${branch}^{commit}")"
    [[ "${target}" == "$(state_get "${env}" current)" ]] && exit 0
    [[ "${target}" == "$(state_get "${env}" failed)" ]] && exit 0   # pas de boucle sur un commit cassé
    log "nouvelle version sur ${branch} (${env}) : ${target}"
    cmd_build "${target}" "${env}" >/dev/null
    cmd_up "${env}" "${target}"
}

cmd_promote() {
    local sha="" yes=0 env="" arg prev=""
    for arg in "$@"; do
        if [[ "${prev}" == --env ]]; then env="${arg}"; prev=""; continue; fi
        case "${arg}" in
            -y|--yes) yes=1 ;;
            --env) prev=--env ;;
            --env=*) env="${arg#--env=}" ;;
            -e) prev=--env ;;
            *) sha="${arg}" ;;
        esac
    done
    [[ "${prev}" == --env ]] && die "--env demande un nom d'environnement (${PROD_ENVIRONMENTS})"
    if [[ -z "${env}" ]]; then
        # shellcheck disable=SC2086
        set -- ${PROD_ENVIRONMENTS}
        [[ $# -eq 1 ]] || die "ce projet a plusieurs productions (${PROD_ENVIRONMENTS}) : préciser laquelle avec --env <nom>"
        env="$1"
    fi
    is_env "${env}" || die "environnement inconnu « ${env} » (${ENVIRONMENTS})"
    is_prod "${env}" || die "« ${env} » n'est pas une production (${PROD_ENVIRONMENTS}) : elle se déploie par « deploy.sh watch »"
    local pre; pre="$(preprod_env)"
    if [[ -z "${sha}" ]]; then
        if [[ -n "${pre}" ]]; then
            sha="$(state_get "${pre}" current)"
            [[ -n "${sha}" ]] || die "aucune version en ${pre} à promouvoir"
        else
            # No staging: nothing was validated before, so the production follows the branch the project DECLARED (BRANCH_<ENV>).
            # We never guess one (a default « main » would deploy something nobody chose): no declaration, no guess.
            local bvar="BRANCH_${env^^}" branch
            [[ -n "${!bvar:-}" ]] || die "ce projet n'a pas de staging et ne déclare pas la branche de ${env} : donner la version (deploy.sh promote <sha ou origin/<branche>>) ou déclarer ${bvar}=<branche> dans platform.env"
            branch="${!bvar}"
            is_git || die "ce projet n'a pas de staging et n'est pas un checkout git : donner la version (deploy.sh promote <sha>)"
            fetch_origin || die "impossible de récupérer origin/${branch} (voir ci-dessus)"
            sha="$(git -C "${PROJECT_DIR}" rev-parse "origin/${branch}^{commit}")" || die "la branche origin/${branch} n'existe pas"
            log "pas de staging : la production ${env} suit origin/${branch} (${sha:0:12})"
        fi
    elif [[ ! "${sha}" =~ ^[0-9a-f]{40}$ ]] && is_git; then
        fetch_origin || die "impossible de résoudre ${sha} (voir ci-dessus)"
        sha="$(git -C "${PROJECT_DIR}" rev-parse "${sha}^{commit}")" || die "version inconnue"
    fi
    if [[ -n "${pre}" && "${sha}" != "$(state_get "${pre}" current)" ]]; then
        log "ATTENTION : ${sha} n'est pas la version actuellement en ${pre} ($(state_get "${pre}" current))"
    fi
    guard_branch "${env}" "${sha}"
    if [[ -z "${pre}" ]]; then log "pas de staging : l'image de ${sha:0:12} est construite ici, rien n'a été validé avant"
    elif [[ "${BUILD_PER_ENV}" == 1 ]]; then log "BUILD_PER_ENV=1 : l'image de ${env} est construite pour cet environnement (sa configuration est intégrée à l'image)"
    elif [[ "${sha}" == "$(state_get "${pre}" current)" ]]; then log "même image que ${pre} (${sha:0:12}) : rien n'est reconstruit"
    fi
    echo "Production ${env} : $(state_get "${env}" current || true) → ${sha}"
    if [[ "${yes}" != 1 ]]; then
        read -r -p "Déployer en PRODUCTION (${env}) ? Tapez « oui » : " answer
        [[ "${answer}" == "oui" ]] || die "promotion annulée"
    fi
    cmd_up "${env}" "${sha}"
}

# backup [env] — one backup now, uploaded to S3 like the nightly one. Before a risky migration, take it yourself.
cmd_backup() {
    local env="${1:-}"
    if [[ -z "${env}" ]]; then
        # shellcheck disable=SC2086
        set -- ${PROD_ENVIRONMENTS}
        [[ $# -eq 1 ]] || die "plusieurs productions (${PROD_ENVIRONMENTS}) : préciser l'environnement (deploy.sh backup <env>)"
        env="$1"
    fi
    is_env "${env}" || die "environnement inconnu « ${env} » (${ENVIRONMENTS})"
    [[ -n "${BACKUP_SERVICE}" ]] || die "ce projet n'a pas de BACKUP_SERVICE dans platform.env"
    local sha; sha="$(state_get "${env}" current)"
    log "sauvegarde manuelle ${env}"
    IMAGE_TAG="$(tag_for "${env}" "${sha:-latest}")" dc "${env}" run --rm -T -e BACKUP_LABEL="manual" "${BACKUP_SERVICE}" sh -c "${BACKUP_CMD}" \
        || die "sauvegarde manuelle en échec"
    log "sauvegarde manuelle ${env} : OK"
}

# obs_publish — put the project's own dashboards and alert rules into the platform's Grafana tree. Never fails a
# deploy: observability must not be able to block a delivery. A refusal is logged with its reason.
obs_publish() {
    local src="${PROJECT_DIR}/${OBS_BUNDLE}" gdir="${OBS_GRAFANA_DIR:-${PLATFORM_ROOT}/observability/grafana}" out rc=0
    [[ -d "${src}/dashboards" || -d "${src}/alerts" ]] || return 0
    command -v python3 >/dev/null || { log "observabilité du projet : python3 absent, rien publié"; return 1; }
    out="$(python3 "${PLATFORM_ROOT}/bin/obs-bundle.py" sync --app "${APP_NAME}" --src "${src}" --grafana-dir "${gdir}" 2>&1)" || rc=$?
    if [[ "${rc}" -ne 0 ]]; then
        log "observabilité du projet NON publiée : ${out}"
        return 1
    fi
    log "observabilité du projet publiée (${out})"
    if [[ "${out}" == *"alerts_changed=1"* ]]; then
        log "ses alertes ont changé : Grafana ne les relit qu'à son redémarrage (cd observability && docker compose --env-file .env up -d --no-deps --force-recreate grafana) ; les tableaux se rechargent seuls"
    fi
}

# obs-sync [--remove] — publish (or withdraw) the project's own Grafana dashboards and alert rules on demand.
cmd_obs_sync() {
    local gdir="${OBS_GRAFANA_DIR:-${PLATFORM_ROOT}/observability/grafana}" src="${PROJECT_DIR}/${OBS_BUNDLE}" out
    if [[ "${1:-}" == "--remove" ]]; then
        python3 "${PLATFORM_ROOT}/bin/obs-bundle.py" remove --app "${APP_NAME}" --grafana-dir "${gdir}" && log "observabilité du projet retirée"
        return
    fi
    [[ -d "${src}/dashboards" || -d "${src}/alerts" ]] || die "le projet n'a pas de ${OBS_BUNDLE}/dashboards ni de ${OBS_BUNDLE}/alerts : rien à publier"
    out="$(python3 "${PLATFORM_ROOT}/bin/obs-bundle.py" sync --app "${APP_NAME}" --src "${src}" --grafana-dir "${gdir}" 2>&1)" \
        || die "observabilité refusée : ${out}"
    log "observabilité du projet publiée (${out})"
    [[ "${out}" == *"alerts_changed=1"* ]] && log "ses alertes ont changé : recréer Grafana pour les charger (cd observability && docker compose --env-file .env up -d --no-deps --force-recreate grafana)"
    return 0
}

cmd_rollback() {
    local env="${1:?env}" previous
    previous="$(state_get "${env}" previous)"
    [[ -n "${previous}" ]] || die "aucune version précédente connue pour ${env}"
    SKIP_MIGRATIONS=1 SKIP_BACKUP=1 cmd_up "${env}" "${previous}"
}

# check [env] — the pre-flight of a deploy, on the current checkout, plus
# git access. Changes nothing: safe on a project already in production,
# which is how an existing project is brought to the standard.
# Integrity of the project's clone. The clone belongs to vps-deploy: nobody edits, pulls, merges or commits in it
# (deploy.sh fetches, then checks out the SHA to deploy, detached). Two things make a deploy fail or lie, and are blocking:
#   - a DIRECTORY of .git the deploying account cannot write (typically after a « git pull » or any command run as root in the
#     clone): git can no longer add objects or update references there (« insufficient permission for adding an object »).
#     Only directories count: the object files themselves are read-only (0444) in every healthy clone;
#   - tracked files modified by hand: the image would be built from something that is not the commit it is tagged with.
# Two things are only reported: local commits that are in no remote branch (a pull/merge made in the clone: ignored by the next
# deploy, which re-detaches on the published SHA), and files owned by another account than the folder's owner (.git included).
# ALLOW_DIRTY_CLONE=1 lets a deliberate modification through (at the operator's own risk).
clone_integrity() {
    is_git || return 0
    local dir="${PROJECT_DIR}" bad=0 n sample owner
    n="$(find "${dir}/.git" -type d -not -writable 2>/dev/null | wc -l)"
    if [[ "${n}" -gt 0 ]]; then
        sample="$(find "${dir}/.git" -type d -not -writable 2>/dev/null | head -1 || true)"
        log "clone : ${n} dossier(s) de .git que $(id -un) ne peut pas écrire (ex. ${sample#"${dir}"/}) — suite d'un « git pull » ou d'une commande lancée en root dans le clone ; git ne pourra plus y ajouter d'objets ni de références. Réparer en root : chown -R $(stat -c %U "${dir}"):$(stat -c %G "${dir}") ${dir} ; find ${dir} -type d -exec chmod 2775 {} + ; find ${dir} -type f -exec chmod g+rw {} + (docs/retours-experience/2026-10-06-git-pull-en-root-dans-un-clone.md)"
        bad=1
    fi
    n="$(git -C "${dir}" status --porcelain --untracked-files=no 2>/dev/null | wc -l)"
    if [[ "${n}" -gt 0 ]]; then
        sample="$(git -C "${dir}" status --porcelain --untracked-files=no 2>/dev/null | head -1 | cut -c4- || true)"
        if [[ "${ALLOW_DIRTY_CLONE:-0}" == 1 ]]; then
            log "clone : INFO — ${n} fichier(s) suivis par git modifiés à la main (ex. ${sample}), toléré par ALLOW_DIRTY_CLONE=1 : l'image ne correspondra pas exactement au commit"
        else
            log "clone : ${n} fichier(s) suivis par git ont été modifiés à la main (ex. ${sample}) — l'image construite ne correspondrait plus au commit publié. Annuler : git -C ${dir} checkout -- . (ou ALLOW_DIRTY_CLONE=1 pour passer outre, à vos risques)"
            bad=1
        fi
    fi
    n="$(git -C "${dir}" rev-list --count HEAD --not --remotes 2>/dev/null || echo 0)"
    if [[ "${n}" -gt 0 ]]; then
        log "clone : INFO — ${n} commit(s) local(aux) absent(s) de tout dépôt distant (un pull, merge ou commit fait dans le clone) : ignoré(s) au prochain déploiement, qui replace la tête sur la version publiée. Ne rien faire de git à la main dans ce dossier."
    fi
    owner="$(stat -c %U "${dir}")"
    n="$(find "${dir}" -not -user "${owner}" 2>/dev/null | wc -l)"
    if [[ "${n}" -gt 0 ]]; then
        log "clone : INFO — ${n} fichier(s) n'appartiennent pas à ${owner}, propriétaire du dossier (ex. $(find "${dir}" -not -user "${owner}" 2>/dev/null | head -1 | sed "s#^${dir}/##" || true)) : normal pour des données de conteneurs, suspect pour du code ou pour .git (commande lancée en root ?)"
    fi
    return "${bad}"
}

cmd_check() {
    local env="${1:-$(preprod_env)}" ok=1
    [[ -n "${env}" ]] || env="${PROD_ENVIRONMENTS%% *}"
    is_env "${env}" || die "environnement inconnu « ${env} » (${ENVIRONMENTS})"
    if is_git; then
        fetch_origin && log "check : accès git OK ($(git -C "${PROJECT_DIR}" remote get-url origin))" || ok=0
        clone_integrity || ok=0
    fi
    if preflight "${env}" "$(git -C "${PROJECT_DIR}" rev-parse HEAD 2>/dev/null || echo latest)"; then
        log "check : platform.env et compose cohérents, aucun nom privé exposé sur un réseau partagé (${env})"
    else
        ok=0
    fi
    # Not blocking: a missing deployment sheet is a gap in the project's documentation, not a reason to refuse a deploy.
    [[ -f "${PROJECT_DIR}/docs/DEPLOIEMENT.md" ]] \
        || log "check : INFO — pas de docs/DEPLOIEMENT.md : la fiche de déploiement du projet, environnement par environnement (modèle : templates/docs-projet/DEPLOIEMENT.md, clause C14)"
    [[ "${ok}" == 1 ]] || die "check ${env} : problème(s) ci-dessus"
    for e in ${ENVIRONMENTS}; do log "check : branche de ${e} — $(describe_branch "${e}")"; done
    log "check ${env} : OK"
}

cmd_status() {
    for env in ${ENVIRONMENTS}; do
        echo "── ${env} : $(state_get "${env}" current || true)  (précédent : $(state_get "${env}" previous || true))"
        echo "   $(describe_branch "${env}")"
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
        backup) lock; cmd_backup "$@" ;;
        obs-sync) cmd_obs_sync "$@" ;;
        status) cmd_status ;;
        check) cmd_check "$@" ;;
        *) sed -n '2,/^set -euo/p' "${SELF}" | sed '$d'; exit 2 ;;
    esac
}

main "$@"
