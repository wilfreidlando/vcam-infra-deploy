#!/usr/bin/env bash
# Applies infra/host/daemon.json to the Docker daemon WITHOUT stopping the
# running sites (infra/README.md § Hôte). Safe order:
#
#   1. back up /etc/docker/daemon.json, merge our keys into it (never drop
#      existing settings), validate the result with dockerd itself;
#   2. enable live-restore with a reload (SIGHUP: containers untouched);
#   3. only then restart dockerd — with live-restore active, running
#      containers keep running during the restart.
#
# The log rotation applies to containers created AFTER this (each project's
# next deploy). Requires: root, jq.
set -euo pipefail

target=/etc/docker/daemon.json
ours="$(dirname "$0")/daemon.json"
[[ $EUID -eq 0 ]] || { echo "à lancer en root" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq requis (apt install jq)" >&2; exit 1; }

current='{}'
if [[ -s "${target}" ]]; then
    current="$(cat "${target}")"
    cp "${target}" "${target}.bak.$(date +%Y%m%d%H%M%S)"
fi

merged="$(jq -s '.[0] * .[1]' <(echo "${current}") "${ours}")"
tmp="$(mktemp)"
echo "${merged}" > "${tmp}"
dockerd --validate --config-file="${tmp}" >/dev/null || { echo "configuration invalide — rien n'a été modifié" >&2; rm -f "${tmp}"; exit 1; }

echo "Nouvelle configuration :"; cat "${tmp}"
read -r -p "Appliquer ? (oui/non) " answer
[[ "${answer}" == "oui" ]] || { rm -f "${tmp}"; echo "annulé"; exit 1; }

install -m 0644 "${tmp}" "${target}"; rm -f "${tmp}"

systemctl reload docker
for _ in $(seq 1 10); do
    [[ "$(docker info --format '{{.LiveRestoreEnabled}}')" == "true" ]] && break
    sleep 1
done
if [[ "$(docker info --format '{{.LiveRestoreEnabled}}')" != "true" ]]; then
    echo "live-restore non actif après reload — redémarrage de Docker NON effectué (il couperait les sites)." >&2
    echo "La rotation des journaux s'appliquera au prochain redémarrage planifié de Docker." >&2
    exit 1
fi

echo "live-restore actif — redémarrage de dockerd (les conteneurs continuent de tourner)"
systemctl restart docker
docker info --format 'log-driver={{.LoggingDriver}} live-restore={{.LiveRestoreEnabled}}'
