#!/usr/bin/env bash
# Shared helpers for infra/tests. Everything a test creates is named
# vpstest-* (containers, networks, volumes, images) and removed at the end:
# the tests never touch anything else on the machine. Requires Docker only.
set -euo pipefail

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_DIR="$(cd "${INFRA_DIR}/.." && pwd)"
export REPO_DIR
WORK="$(mktemp -d -t vpstest-XXXXXX)"
PASS=0
FAIL=0

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red() { printf '\033[31m%s\033[0m\n' "$*"; }
step() { printf '\n\033[1m▶ %s\033[0m\n' "$*"; }

ok() { PASS=$((PASS + 1)); green "  ✓ $*"; }
ko() { FAIL=$((FAIL + 1)); red "  ✗ $*"; }

# check "<description>" <command…> — passes when the command exits 0.
check() {
    local what="$1"; shift
    if "$@" >/dev/null 2>&1; then ok "${what}"; else ko "${what}"; fi
}

# check_not "<description>" <command…> — passes when the command FAILS.
check_not() {
    local what="$1"; shift
    if "$@" >/dev/null 2>&1; then ko "${what}"; else ok "${what}"; fi
}

# wait_for <seconds> <command…>
wait_for() {
    local timeout="$1"; shift
    local deadline=$((SECONDS + timeout))
    until "$@" >/dev/null 2>&1; do
        (( SECONDS < deadline )) || return 1
        sleep 2
    done
}

cleanup_vpstest() {
    docker ps -aq --filter "name=^vpstest-" | xargs -r docker rm -f >/dev/null 2>&1 || true
    docker ps -a --filter "label=com.docker.compose.project" --format '{{.ID}} {{.Label "com.docker.compose.project"}}' \
        | awk '$2 ~ /^vpstest-/ {print $1}' | xargs -r docker rm -f >/dev/null 2>&1 || true
    docker volume ls -q | grep '^vpstest-' | xargs -r docker volume rm -f >/dev/null 2>&1 || true
    docker network ls --format '{{.Name}}' | grep '^vpstest-' | xargs -r docker network rm >/dev/null 2>&1 || true
    rm -rf "${WORK}"
}

finish() {
    local code=$?
    if [[ "${KEEP:-0}" != 1 ]]; then cleanup_vpstest; else echo "KEEP=1 — ressources vpstest-* conservées, ${WORK}"; fi
    echo
    if [[ "${FAIL}" -eq 0 && "${code}" -eq 0 ]]; then
        green "$(basename "$0") : ${PASS} vérifications réussies"
    else
        red "$(basename "$0") : ${FAIL} échec(s), ${PASS} réussite(s)"
        exit 1
    fi
}

require_docker() {
    docker info >/dev/null 2>&1 || { red "Docker ne répond pas"; exit 2; }
    docker compose version >/dev/null 2>&1 || { red "docker compose v2 requis"; exit 2; }
}
