#!/usr/bin/env bash
# Les commandes courtes (host/install-commands.sh) : vps-deploy, vps-restore, vps-audit, vps-inventory, vps-hosts.
# Ce que le test prouve : on n'a plus à taper le chemin de la plateforme ; un chemin raté donne un message CLAIR (code 127) et pas « No such file » ;
# les scripts retrouvent la vraie plateforme même appelés par un lien symbolique ; l'installateur ne touche jamais à un fichier qui n'est pas à lui.
# Sans Docker et sans être root (COMMANDS_DIR pointe un dossier de test).
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
trap finish EXIT

BIN="${WORK}/bin"
REAL="$(readlink -f "${INFRA_DIR}")"
inst() { COMMANDS_DIR="${BIN}" "${INFRA_DIR}/host/install-commands.sh" "$@"; }
all_cmds() { local c; for c in vps vps-deploy vps-restore vps-audit vps-inventory vps-hosts vps-obs-bundle vps-fingerprint vps-daemon-config; do "$@" "${BIN}/${c}" || return 1; done; }

step "Installation"
check "l'installation réussit sans être root (dossier de test)" inst
check "les neuf commandes existent et sont exécutables (vps, vps-deploy, vps-restore, vps-audit, vps-inventory, vps-hosts, vps-obs-bundle, vps-fingerprint, vps-daemon-config)" all_cmds test -x
check "--check dit que tout est en place (code 0)" inst --check
before="$(cksum "${BIN}"/* | sort)"
check "réinstaller ne change rien (idempotent)" inst
check "les fichiers sont identiques après la réinstallation" test "$(cksum "${BIN}"/* | sort)" = "${before}"

step "Une commande retrouve la plateforme, d'où qu'on l'appelle"
check "vps-deploy where donne le dossier de la plateforme" test "$("${BIN}/vps-deploy" where | awk '/^plateforme/ {print $3}')" = "${REAL}"
check "…depuis un dossier sans platform.env" sh -c "cd '${WORK}' && '${BIN}/vps-deploy' where >/dev/null"
check "…et indique la version (commit) de la plateforme" sh -c "'${BIN}/vps-deploy' where | grep -q '^version'"
check "l'aide s'affiche hors d'un projet (help, code 0)" sh -c "cd '${WORK}' && '${BIN}/vps-deploy' help | grep -q 'deployment tool'"
check_not "sans argument, l'aide s'affiche et le code est 2 (comme avant)" sh -c "cd '${WORK}' && '${BIN}/vps-deploy'"
check "vps-hosts passe par sa commande courte et se comporte comme le script (option inconnue : aide, code 2)" sh -c "'${BIN}/vps-hosts' --bogus >/dev/null 2>&1; test \$? -eq 2"

step "`vps` : le moyen de voir comment on déploie sur la plateforme"
check "vps sans argument affiche l'aide, avec le parcours de déploiement" sh -c "'${BIN}/vps' | grep -q 'vps-deploy promote'"
check "…et dit que chaque projet choisit ses branches" sh -c "'${BIN}/vps' | grep -q 'SES branches'"
check "vps deploy where = vps-deploy where" test "$("${BIN}/vps" deploy where)" = "$("${BIN}/vps-deploy" where)"
check "vps where fonctionne" sh -c "'${BIN}/vps' where | grep -q '^plateforme'"
check_not "une commande inconnue est refusée (code 2) avec un message qui renvoie à l'aide" sh -c "'${BIN}/vps' nope"
check "vps-obs-bundle lance le script Python de la plateforme" sh -c "'${BIN}/vps-obs-bundle' -h | grep -q 'obs-bundle'"
check "vps-fingerprint lance l'outil d'empreintes (son usage dit comment prouver une copie exacte)" sh -c "'${BIN}/vps-fingerprint' 2>&1 | grep -q 'vps-fingerprint db'"

step "Un chemin raté donne un message clair, pas « No such file »"
rc=0; out="$(VPS_PLATFORM_DIR="${WORK}/inexistant" "${BIN}/vps-deploy" where 2>&1)" || rc=$?   # « || » : sous « set -e », un code 127 attendu ne doit pas arrêter le test
check "le code de sortie est 127" test "${rc}" -eq 127
check "le message dit « plateforme introuvable » et nomme le chemin cherché" grep -q "plateforme introuvable (${WORK}/inexistant/bin/deploy.sh)" <<< "${out}"
check "…et dit comment corriger : VPS_PLATFORM_DIR" grep -q VPS_PLATFORM_DIR <<< "${out}"
check "…ou relancer l'installateur" grep -q install-commands <<< "${out}"
check "VPS_PLATFORM_DIR permet de pointer une plateforme ailleurs" test "$(VPS_PLATFORM_DIR="${REAL}" "${BIN}/vps-deploy" where | awk '/^plateforme/ {print $3}')" = "${REAL}"

step "Un lien symbolique ne casse rien"
# Avant : la racine de la plateforme était déduite de « dirname $0 » : un lien dans le PATH la faisait pointer sur /usr/local, sans erreur claire.
mkdir -p "${WORK}/ailleurs"
ln -s "${REAL}/bin/deploy.sh" "${WORK}/ailleurs/lien-deploy"
check "deploy.sh appelé par un lien symbolique retrouve la VRAIE plateforme" test "$("${WORK}/ailleurs/lien-deploy" where | awk '/^plateforme/ {print $3}')" = "${REAL}"
ln -s "${REAL}/bin/vps-hosts.sh" "${WORK}/ailleurs/lien-hosts"
check "vps-hosts.sh appelé par un lien symbolique se comporte comme le script (option inconnue : aide, code 2)" sh -c "'${WORK}/ailleurs/lien-hosts' --bogus >/dev/null 2>&1; test \$? -eq 2"
# vps-audit.sh et vps-inventory.sh appellent leurs scripts voisins : ils doivent résoudre leur emplacement réel (lecture du code, ils demandent Docker pour tourner)
check "vps-audit.sh et vps-inventory.sh résolvent leur emplacement réel avant de chercher leurs voisins" sh -c "grep -q 'readlink -f' '${REAL}/bin/vps-audit.sh' && grep -q 'readlink -f' '${REAL}/bin/vps-inventory.sh'"

step "L'installateur ne touche pas à ce qui n'est pas à lui"
printf '#!/bin/sh\necho etranger\n' > "${BIN}/vps-audit"
check_not "il refuse d'écraser un fichier étranger" inst
check "le fichier étranger est intact" grep -q etranger "${BIN}/vps-audit"
check "--check le signale (code 1)" test "$(inst --check >/dev/null 2>&1; echo $?)" = 1
check "--uninstall retire les commandes qui sont à lui" sh -c "COMMANDS_DIR='${BIN}' '${INFRA_DIR}/host/install-commands.sh' --uninstall >/dev/null && test ! -e '${BIN}/vps-deploy'"
check "…et laisse le fichier étranger en place" grep -q etranger "${BIN}/vps-audit"
check_not "sans COMMANDS_DIR et sans être root, il refuse (pas d'écriture dans /usr/local/bin par erreur)" sh -c "[ \"\$(id -u)\" = 0 ] || '${INFRA_DIR}/host/install-commands.sh'"
