#!/usr/bin/env bash
# templates/intervention-claude/hooks/garde-serveur.sh (guide 13): what the
# guard lets through and what it stops, in both phases. Needs jq, not Docker.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
trap finish EXIT
command -v jq >/dev/null || { red "jq requis"; exit 2; }

HOOK="${INFRA_DIR}/templates/intervention-claude/hooks/garde-serveur.sh"
export CLAUDE_PROJECT_DIR="${WORK}"
mkdir -p "${WORK}/.claude"

run_hook() { jq -n --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}' | "${HOOK}" 2>/dev/null; }
allowed() { local d="$1"; shift; for c in "$@"; do check "${d} : ${c}" run_hook "${c}"; done; }
blocked() {
    local d="$1"; shift
    for c in "$@"; do
        if run_hook "${c}"; then ko "${d} : ${c}"
        elif [[ $? -eq 2 ]]; then ok "${d} : ${c}"
        else ko "${d} (code inattendu) : ${c}"; fi
    done
}

step "Phase inventaire (fichier PHASE absent = inventaire)"
allowed "lecture autorisée" \
    "ssh vps-contabo docker ps -a" \
    "ssh vps-contabo 'docker inspect -f \"{{.Name}}\" nginx-proxy 2>/dev/null'" \
    "ssh vps-contabo /app/vps-platform/bin/vps-inventory.sh" \
    "ssh vps-contabo /app/vps-platform/bin/vps-audit.sh 2>&1" \
    "ssh vps-contabo 'cd /app/skills-devops/staging && /app/vps-platform/bin/deploy.sh check staging'" \
    "ssh vps-contabo crontab -l" \
    "ssh vps-contabo 'git -C /app/vps-platform log -1'"
blocked "écriture refusée" \
    "ssh vps-contabo docker restart nginx-proxy" \
    "ssh vps-contabo 'docker compose -p cpf-prod up -d'" \
    "ssh vps-contabo 'cd /app/x/staging && /app/vps-platform/bin/deploy.sh watch'" \
    "ssh vps-contabo 'git -C /app/vps-platform pull'" \
    "ssh vps-contabo 'echo x > /etc/cron.d/test'" \
    "ssh vps-contabo 'sed -i s/a/b/ /app/x/.env'" \
    "ssh vps-contabo rm /app/x/platform.env" \
    "ssh vps-contabo systemctl restart docker" \
    "ssh vps-contabo apt install -y jq" \
    "ssh vps-contabo docker exec -it cpf-prod-db-1 mysql" \
    "ssh vps-contabo /app/vps-platform/bin/vps-inventory.sh > docs/inventaire/x.md"

step "Commandes locales : non concernées"
allowed "poste local" "git push -u origin inventaire-vps" "rm -rf build/" "docker compose up -d"

step "Phase application"
echo application > "${WORK}/.claude/PHASE"
allowed "modification permise (sous accord humain)" \
    "ssh vps-contabo 'git -C /app/vps-platform pull'" \
    "ssh vps-contabo 'cd /app/x/staging && /app/vps-platform/bin/deploy.sh watch'" \
    "ssh vps-contabo docker rm -f skills-devops-staging-db-1" \
    "ssh vps-contabo 'rm -rf /app/skills-devops/staging/storage/framework/cache/data'"
blocked "toujours interdit" \
    "ssh vps-contabo 'docker compose -p x-prod down -v'" \
    "ssh vps-contabo docker volume rm cpf-prod_db-data" \
    "ssh vps-contabo docker system prune -af" \
    "ssh vps-contabo reboot" \
    "ssh vps-contabo 'rm -rf /app'" \
    "ssh vps-contabo rm -rf /" \
    "ssh vps-contabo 'rm -fr /var/lib/docker/'" \
    "ssh vps-contabo ufw disable" \
    "ssh vps-contabo 'echo k >> /root/.ssh/authorized_keys'" \
    "ssh vps-contabo \"docker exec db psql -c 'DROP TABLE users'\"" \
    "ssh vps-contabo systemctl stop docker"

step "Autre alias de serveur"
code=0; VPS_SSH_ALIAS=vps-test run_hook "ssh vps-test reboot" || code=$?
check "l'alias se règle par VPS_SSH_ALIAS" test "${code}" = 2
