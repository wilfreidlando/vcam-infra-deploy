#!/usr/bin/env bash
# VPS inventory (contrat § 4) — READ-ONLY, secret-free.
#
# One command that describes the whole server as it is, in Markdown, so that
# the state can be kept in the repository (docs/inventaire/), compared over
# time, and used as the starting point of any change:
#
#   host · Docker · platform checkout · crons · compose projects · every
#   project checkout under /app (git remote, commit, platform.env, deploy
#   state) · shared networks with the DNS names each container publishes ·
#   audit (vps-audit.sh) · host names (vps-hosts.sh)
#
# Never prints a secret: no environment VALUES, no file contents of .env,
# credentials in git URLs and secret-looking cron arguments are masked.
# Changes nothing, starts nothing, fetches nothing.
#
#   vps-inventory.sh                > inventaire.md
#   vps-inventory.sh --no-audit       skip vps-audit.sh / vps-hosts.sh sections
#
# Settings (environment): APPS_DIR (/app), STATE_DIR (/var/lib/vps-platform),
# PLATFORM_DIR (/app/vps-platform), SHARED_NETWORKS ("nginx-proxy observability"),
# NGINX_PROXY_CONTAINER (nginx-proxy).
set -uo pipefail

APPS_DIR="${APPS_DIR:-/app}"
STATE_DIR="${STATE_DIR:-/var/lib/vps-platform}"
PLATFORM_DIR="${PLATFORM_DIR:-/app/vps-platform}"
SHARED_NETWORKS="${SHARED_NETWORKS:-nginx-proxy observability}"
NGINX_PROXY_CONTAINER="${NGINX_PROXY_CONTAINER:-nginx-proxy}"
BIN_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
audit=1
[[ "${1:-}" == "--no-audit" ]] && audit=0

DB_IMAGES='(^|/)(postgres|postgis|mysql|mariadb|mongo|redis|valkey|memcached|elasticsearch|opensearch|rabbitmq)(:|$)'
GENERIC_NAMES='^(app|web|db|database|postgres|postgresql|mysql|mariadb|redis|valkey|cache|queue|worker|scheduler|nginx|php|api)$'

# Masks credentials: https://user:token@host → https://***@host ; KEY=value → KEY=***
mask() {
    sed -E -e 's#(https?://)[^/@ ]+@#\1***@#g' \
           -e 's#(([A-Za-z_]*(TOKEN|PASS|PASSWORD|SECRET|KEY|PASSPHRASE)[A-Za-z_]*)=)[^ ]+#\1***#g'
}
cell() { tr '|\n' '/ ' <<< "$*" | sed 's/ *$//'; }   # safe inside a Markdown table cell
code() { echo '```'; cat; echo '```'; }

echo "# Inventaire du VPS — $(hostname) — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo
echo "Produit par \`bin/vps-inventory.sh\` (lecture seule, aucun secret). Référentiel :"
echo "\`docs/05-contrat-projet.md\`."

# ── 1. Host ─────────────────────────────────────────────────────────────
echo
echo "## 1. Hôte"
echo
os="$( (. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-?}") || uname -sr)"
mem="$(free -m 2>/dev/null | awk '/^Mem:/ {printf "%s Mo, dont %s disponibles", $2, $7}')"
echo "| Élément | Valeur |"
echo "| --- | --- |"
echo "| Système | $(cell "${os}") — noyau $(uname -r) |"
echo "| Processeurs / mémoire | $(nproc 2>/dev/null || echo '?') / $(cell "${mem:-?}") |"
echo "| Allumé depuis | $(cell "$(uptime -p 2>/dev/null || uptime)") |"
echo "| Docker / Compose | $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?') / $(docker compose version --short 2>/dev/null || echo '?') |"
echo "| Racine Docker | $(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo '?') |"
echo "| Rotation des journaux par défaut | $( [[ -r /etc/docker/daemon.json ]] && grep -q '"max-size"' /etc/docker/daemon.json && echo oui || echo '**non** (guide 9)') |"
echo "| live-restore | $(docker info --format '{{.LiveRestoreEnabled}}' 2>/dev/null || echo '?') |"
echo "| Pare-feu (ufw) | $(cell "$(ufw status 2>/dev/null | head -1 || echo 'non lisible')") |"
echo
echo "Disques :"
echo
df -hP / "$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo /)" 2>/dev/null | awk 'NR == 1 || !seen[$0]++' | code
echo
echo "Espace Docker :"
echo
docker system df 2>/dev/null | code

# ── 2. Platform ─────────────────────────────────────────────────────────
echo
echo "## 2. Plateforme"
echo
if git -C "${PLATFORM_DIR}" rev-parse --git-dir >/dev/null 2>&1; then
    dirty="$(git -C "${PLATFORM_DIR}" status --porcelain 2>/dev/null | wc -l)"
    echo "- \`${PLATFORM_DIR}\` : commit \`$(git -C "${PLATFORM_DIR}" log -1 --format='%h %ad %s' --date=short | cell)\`, origin \`$(git -C "${PLATFORM_DIR}" remote get-url origin 2>/dev/null | mask)\`, fichiers modifiés localement : ${dirty}"
else
    echo "- \`${PLATFORM_DIR}\` : **absent** (guide 3)"
fi
if docker container inspect "${NGINX_PROXY_CONTAINER}" >/dev/null 2>&1; then
    if docker exec "${NGINX_PROXY_CONTAINER}" nginx -t >/dev/null 2>&1; then
        echo "- nginx-proxy (\`${NGINX_PROXY_CONTAINER}\`) : configuration **valide**"
    else
        echo "- nginx-proxy (\`${NGINX_PROXY_CONTAINER}\`) : configuration **REFUSÉE** — plus aucun changement de site n'est appliqué (README § 11)"
    fi
else
    echo "- nginx-proxy (\`${NGINX_PROXY_CONTAINER}\`) : **absent**"
fi
echo
echo "Tâches planifiées de root (arguments sensibles masqués) :"
echo
{ crontab -l 2>/dev/null | grep -vE '^\s*(#|$)' || echo "(aucune)"; } | mask | code

# ── 3. Compose projects ─────────────────────────────────────────────────
echo
echo "## 3. Projets Docker"
echo
echo "| Projet | État | Fichiers compose |"
echo "| --- | --- | --- |"
docker compose ls -a --format json 2>/dev/null \
    | grep -oE '"Name":"[^"]*","Status":"[^"]*","ConfigFiles":"[^"]*"' \
    | sed -E 's/"Name":"([^"]*)","Status":"([^"]*)","ConfigFiles":"([^"]*)"/| \1 | \2 | \3 |/' \
    || true
others="$(docker ps -a --format '{{.Names}} {{.Label "com.docker.compose.project"}}' | awk '$2 == "" {print $1}' | paste -sd' ' -)"
[[ -n "${others}" ]] && { echo; echo "Conteneurs hors compose : ${others}"; }

# ── 4. Project checkouts ────────────────────────────────────────────────
echo
echo "## 4. Dossiers de projets (\`${APPS_DIR}\`)"
echo
echo "| Dossier | Origin | Commit | Local modifié | platform.env | Fichiers d'environnement | Déployé (deploy.sh) |"
echo "| --- | --- | --- | --- | --- | --- | --- |"
while IFS= read -r gitdir; do
    dir="$(dirname "${gitdir}")"
    [[ "${dir}" == "${PLATFORM_DIR}" ]] && continue
    url="$(git -C "${dir}" remote get-url origin 2>/dev/null | mask || echo '?')"
    [[ "${url}" == http* ]] && url="${url} **(HTTPS : C9)**"
    commit="$(git -C "${dir}" log -1 --format='%h %ad' --date=short 2>/dev/null || echo '?')"
    dirty="$(git -C "${dir}" status --porcelain 2>/dev/null | grep -vc '^??' || true)"
    pe="—"; state="—"
    if [[ -f "${dir}/platform.env" ]]; then
        app="$(grep -E '^APP_NAME=' "${dir}/platform.env" | head -1 | cut -d= -f2 | tr -d '"')"
        pe="APP_NAME=${app:-?}"
        if [[ -n "${app}" && -d "${STATE_DIR}/${app}" ]]; then
            state=""
            for envdir in "${STATE_DIR}/${app}"/*/; do
                [[ -d "${envdir}" ]] || continue
                env="$(basename "${envdir}")"
                cur="$(cut -c1-12 "${envdir}/current" 2>/dev/null || true)"
                failed="$(cut -c1-12 "${envdir}/failed" 2>/dev/null || true)"
                state+="${env}=${cur:-aucun}${failed:+ (échec ${failed})} "
            done
        fi
    fi
    envs=""
    for f in "${dir}"/.env "${dir}"/.env.*; do
        [[ -f "${f}" && "${f}" != *.example ]] && envs+="$(basename "${f}") "
    done
    envs="${envs% }"
    echo "| \`${dir}\` | $(cell "${url}") | $(cell "${commit}") | ${dirty} | ${pe} | ${envs:-—} | $(cell "${state:-—}") |"
done < <(find "${APPS_DIR}" -mindepth 2 -maxdepth 3 -name .git -type d 2>/dev/null | sort)

# ── 5. Shared networks ──────────────────────────────────────────────────
echo
echo "## 5. Réseaux partagés et noms publiés"
echo
echo "Un nom publié sur un réseau partagé est visible de **tous** les projets qui y"
echo "sont branchés (contrat, clause C3). ⚠ = base ou cache sur un réseau partagé (C2),"
echo "ou nom générique publié par plusieurs projets."
for net in ${SHARED_NETWORKS}; do
    echo
    if ! docker network inspect "${net}" >/dev/null 2>&1; then
        echo "### ${net} : absent"
        continue
    fi
    echo "### ${net}"
    echo
    echo "| Conteneur | Projet | Image | Noms DNS sur ce réseau | |"
    echo "| --- | --- | --- | --- | --- |"
    declare -A owners=()
    rows=()
    for c in $(docker network inspect -f '{{range .Containers}}{{.Name}} {{end}}' "${net}"); do
        project="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "${c}" 2>/dev/null)"
        image="$(docker inspect -f '{{.Config.Image}}' "${c}" 2>/dev/null)"
        names="$(docker inspect -f "{{json (index .NetworkSettings.Networks \"${net}\")}}" "${c}" 2>/dev/null \
            | grep -oE '"(Aliases|DNSNames)":\[[^]]*\]' | grep -oE '"[^"]*"' | tr -d '"' \
            | grep -vxE 'Aliases|DNSNames' | grep -vxE '[0-9a-f]{12}' | grep -vx "${c}" | sort -u | paste -sd' ' - || true)"
        flag=""
        [[ "${image}" =~ ${DB_IMAGES} ]] && flag="⚠ base/cache"
        for n in ${names}; do owners["${n}"]+="${project:-${c}} "; done
        rows+=("| ${c} | ${project:-hors compose} | ${image} | ${names:-—} | ${flag} |")
    done
    printf '%s\n' "${rows[@]}"
    dup=""
    for n in "${!owners[@]}"; do
        count="$(tr ' ' '\n' <<< "${owners[${n}]}" | grep -v '^$' | sort -u | wc -l)"
        if [[ "${count}" -gt 1 ]] && grep -qxE "${GENERIC_NAMES}" <<< "${n}"; then
            dup+="- ⚠ « ${n} » publié par : $(tr ' ' '\n' <<< "${owners[${n}]}" | grep -v '^$' | sort -u | paste -sd, -)"$'\n'
        fi
    done
    if [[ -n "${dup}" ]]; then echo; echo "Noms génériques publiés par plusieurs projets :"; echo; printf '%s' "${dup}" | sort; fi
    unset owners
done

# ── 6. Audit and host names ─────────────────────────────────────────────
if [[ "${audit}" == 1 ]]; then
    echo
    echo "## 6. Audit (vps-audit.sh)"
    echo
    "${BIN_DIR}/vps-audit.sh" 2>&1 | code
    echo
    echo "## 7. Sous-domaines (vps-hosts.sh)"
    echo
    "${BIN_DIR}/vps-hosts.sh" 2>&1 | code
fi
