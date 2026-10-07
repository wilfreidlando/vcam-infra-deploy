#!/usr/bin/env bash
# `vps` : l'entrée unique de la plateforme. Sans argument, elle DIT comment on déploie ; avec le nom d'une commande, elle la lance.
#   vps                     l'aide : les commandes et le parcours de déploiement
#   vps where               où est la plateforme et quelle version
#   vps deploy …            = vps-deploy …  (idem : restore, audit, inventory, hosts, obs-bundle, daemon-config)
# Installée par host/install-commands.sh, avec chaque commande sous sa forme courte (vps-deploy, vps-audit…).
set -euo pipefail

SELF="$(readlink -f "${BASH_SOURCE[0]}")"
ROOT="$(cd "$(dirname "${SELF}")/.." && pwd)"
declare -A CMD=(
    [deploy]=bin/deploy.sh [restore]=bin/restore.sh [audit]=bin/vps-audit.sh [inventory]=bin/vps-inventory.sh
    [hosts]=bin/vps-hosts.sh [obs-bundle]=bin/obs-bundle.py [daemon-config]=host/apply-daemon-config.sh
    [overview]=bin/vps-overview.py [fingerprint]=bin/vps-fingerprint.sh
)

aide() {
    cat <<TXT
La plateforme du serveur : une seule façon de déployer, la même pour tous les projets.

DÉPLOYER, depuis le dossier d'un projet (/app/<projet>/<env>) :
  vps-deploy check <env>      contrôle avant déploiement, ne change rien
  vps-deploy watch            staging : construit et déploie si la branche du staging a bougé
  vps-deploy promote          production : l'image EXACTE validée en staging, jamais reconstruite
  vps-deploy status           versions, branches suivies et conteneurs de chaque environnement
  vps-deploy rollback <env>   revient à la version précédente
  vps-deploy backup [env]     une sauvegarde maintenant, envoyée sur S3
  vps-deploy obs-sync         publie les tableaux et alertes propres au projet

Chaque projet choisit SES branches dans son platform.env (BRANCH_STAGING, BRANCH_PROD…) ; un projet peut n'avoir
qu'une production (sans staging), ou plusieurs (« vps-deploy promote --env <nom> »).

DE N'IMPORTE QUEL DOSSIER :
  vps-audit            audit en lecture seule de tous les conteneurs du serveur
  vps-inventory        inventaire du serveur en Markdown, sans secret
  vps-hosts            noms de domaine : libres ou pris ?
  vps-restore          restaurer une sauvegarde dans un environnement
  vps-obs-bundle       valider ou publier les tableaux et alertes d'un projet
  vps-fingerprint      prouver qu'une copie (base de données, fichiers) est exacte, par empreintes
  vps-overview         quelle version tourne où, par projet et environnement (tableau, --json, --html)
  vps-daemon-config    réglage de Docker (rotation des journaux, live-restore), en root
  vps where            où est la plateforme, quelle version

Chaque commande existe sous deux formes : « vps deploy … » et « vps-deploy … ».
Quoi faire selon la situation : ${ROOT}/docs/reference/deployer-selon-la-situation.md
TXT
}

case "${1:-}" in
    ""|help|-h|--help) aide ;;
    where) exec "${ROOT}/bin/deploy.sh" where ;;
    *)
        name="$1"; shift
        rel="${CMD[${name}]:-}"
        [[ -n "${rel}" ]] || { echo "vps : commande inconnue « ${name} ». Lancer « vps » pour la liste." >&2; exit 2; }
        exec "${ROOT}/${rel}" "$@" ;;
esac
