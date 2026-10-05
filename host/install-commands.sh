#!/usr/bin/env bash
# Installs SHORT COMMANDS in the PATH, so nobody types (or mistypes) /app/vps-platform/bin/... from any folder:
#
#   vps                = bin/vps.sh : with no argument it SAYS how to deploy; `vps deploy …` = `vps-deploy …`
#   vps-deploy         = bin/deploy.sh            vps-restore = bin/restore.sh        vps-audit   = bin/vps-audit.sh
#   vps-inventory      = bin/vps-inventory.sh     vps-hosts   = bin/vps-hosts.sh      vps-obs-bundle = bin/obs-bundle.py
#   vps-daemon-config  = host/apply-daemon-config.sh
#
#   host/install-commands.sh              install (root)
#   host/install-commands.sh --check      show the state of each command, change nothing (exit 1 if something is off)
#   host/install-commands.sh --uninstall  remove ONLY the commands this script wrote
#
# Each command is a tiny wrapper, not a symlink: when the platform is not where it should be, it says so in plain words
# (and how to fix it) instead of "No such file or directory". The platform folder is the one this script lives in; at run time
# VPS_PLATFORM_DIR=<folder> overrides it (a platform moved or cloned elsewhere), and re-running this script from the new folder rewrites the wrappers.
# It never overwrites a file it did not write.
#
# COMMANDS_DIR (default /usr/local/bin) is where the commands go; root is required unless COMMANDS_DIR is set (tests do that).
set -euo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
ROOT="$(cd "$(dirname "${SELF}")/.." && pwd)"
DIR="${COMMANDS_DIR:-/usr/local/bin}"
MARK="# vps-platform command wrapper"
NAMES=(vps vps-deploy vps-restore vps-audit vps-inventory vps-hosts vps-obs-bundle vps-daemon-config)
# name → script, relative to the platform folder
declare -A SCRIPT=(
    [vps]=bin/vps.sh [vps-deploy]=bin/deploy.sh [vps-restore]=bin/restore.sh [vps-audit]=bin/vps-audit.sh
    [vps-inventory]=bin/vps-inventory.sh [vps-hosts]=bin/vps-hosts.sh [vps-obs-bundle]=bin/obs-bundle.py
    [vps-daemon-config]=host/apply-daemon-config.sh
)

mode="install"
case "${1:-}" in
    "") ;;
    --check) mode="check" ;;
    --uninstall) mode="uninstall" ;;
    *) sed -n '2,/^set -euo/p' "${SELF}" | sed '$d'; exit 2 ;;
esac

ours() { [[ -f "$1" ]] && grep -q -F "${MARK}" "$1"; }
wrapper() {  # wrapper <name> → the text of the command
    local name="$1" script="${SCRIPT[$1]}"
    cat <<WRAP
#!/bin/sh
${MARK} — written by host/install-commands.sh; do not edit, re-run the installer.
root="\${VPS_PLATFORM_DIR:-${ROOT}}"
script="\${root}/${script}"
if [ ! -x "\${script}" ]; then
    echo "${name} : plateforme introuvable (\${script})." >&2
    echo "  Dossier attendu : \${root}. S'il a changé : VPS_PLATFORM_DIR=<dossier> ${name} ..., ou relancer host/install-commands.sh depuis la plateforme." >&2
    exit 127
fi
exec "\${script}" "\$@"
WRAP
}

case "${mode}" in
    check)
        bad=0
        for n in "${NAMES[@]}"; do
            f="${DIR}/${n}"
            if [[ ! -e "${f}" ]]; then echo "  ${n} : absente"; bad=1
            elif ! ours "${f}"; then echo "  ${n} : un autre fichier occupe ce nom (non touché)"; bad=1
            elif ! diff -q <(wrapper "${n}") "${f}" >/dev/null 2>&1; then echo "  ${n} : installée pour une autre plateforme ou périmée (relancer l'installation)"; bad=1
            elif [[ ! -x "${ROOT}/${SCRIPT[$n]}" ]]; then echo "  ${n} : le script ${ROOT}/${SCRIPT[$n]} est introuvable"; bad=1
            else echo "  ${n} : ok → ${ROOT}/${SCRIPT[$n]}"; fi
        done
        exit "${bad}" ;;
    uninstall)
        [[ -n "${COMMANDS_DIR:-}" || $EUID -eq 0 ]] || { echo "à lancer en root" >&2; exit 1; }
        for n in "${NAMES[@]}"; do
            if ours "${DIR}/${n}"; then rm -f "${DIR:?}/${n}"; echo "  ${n} : retirée"
            elif [[ -e "${DIR}/${n}" ]]; then echo "  ${n} : un autre fichier occupe ce nom, laissé en place"
            else echo "  ${n} : absente"; fi
        done ;;
    install)
        [[ -n "${COMMANDS_DIR:-}" || $EUID -eq 0 ]] || { echo "à lancer en root (ou définir COMMANDS_DIR)" >&2; exit 1; }
        for n in "${NAMES[@]}"; do
            [[ -x "${ROOT}/${SCRIPT[$n]}" ]] || { echo "script introuvable : ${ROOT}/${SCRIPT[$n]}" >&2; exit 1; }
        done
        conflicts=()
        for n in "${NAMES[@]}"; do
            [[ -e "${DIR}/${n}" ]] && ! ours "${DIR}/${n}" && conflicts+=("${DIR}/${n}")
        done
        if [[ ${#conflicts[@]} -gt 0 ]]; then
            echo "refus : ces fichiers existent et ne sont pas les nôtres, rien n'a été installé :" >&2
            printf '  %s\n' "${conflicts[@]}" >&2
            exit 1
        fi
        mkdir -p "${DIR}"
        for n in "${NAMES[@]}"; do
            tmp="$(mktemp)"; wrapper "${n}" > "${tmp}"
            install -m 0755 "${tmp}" "${DIR}/${n}"; rm -f "${tmp}"
            echo "  ${n} → ${ROOT}/${SCRIPT[$n]}"
        done
        echo "Essayer : vps   (l'aide, avec le parcours de déploiement)   ou   vps where" ;;
esac
