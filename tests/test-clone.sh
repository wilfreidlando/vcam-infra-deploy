#!/usr/bin/env bash
# L'intégrité du clone d'un projet (bin/deploy.sh check). Le clone appartient à vps-deploy : personne n'y édite, n'y « pull »,
# n'y fusionne ni n'y commit. Ce que le test prouve : un clone propre passe ; un dossier de .git que le compte ne peut pas écrire
# (la suite d'un « git pull » en root) est REFUSÉ avec la commande de réparation ; un fichier suivi par git modifié à la main est
# REFUSÉ (l'image ne serait plus celle du commit), sauf ALLOW_DIRTY_CLONE=1 ; un commit local absent d'origin n'est que SIGNALÉ ;
# un fichier non suivi (les .env.*, jamais commités) ne gêne JAMAIS.
# Aucun conteneur n'est démarré : « check » ne fait que lire (docker compose config).
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
trap finish EXIT
require_docker

DEPLOY="${INFRA_DIR}/bin/deploy.sh"
export STATE_DIR="${WORK}/state"
ORIGIN="${WORK}/origin"; CLONE="${WORK}/clone"; OUT="${WORK}/out.txt"

run_check() { (cd "${CLONE}" && "${DEPLOY}" check staging) > "${OUT}" 2>&1; }
says() { grep -qF -- "$1" "${OUT}"; }
silent_on_clone() { ! grep -q "clone :" "${OUT}"; }

step "Projet témoin et clone détaché sur la version publiée, comme après un déploiement"
mkdir -p "${ORIGIN}"
git -C "${ORIGIN}" init -q -b main
git -C "${ORIGIN}" config user.email test@example.com; git -C "${ORIGIN}" config user.name test
cat > "${ORIGIN}/compose.yaml" <<'YAML'
services:
  app:
    image: busybox
    container_name: vpstest-cl-${ENV_NAME}-app
    environment:
      VIRTUAL_HOST: ${ENV_NAME}.cl.vpstest.test
YAML
cat > "${ORIGIN}/platform.env" <<'ENV'
APP_NAME=vpstest-cl
COMPOSE_FILE=compose.yaml
ENVIRONMENTS="staging prod"
PROD_ENVIRONMENTS="prod"
BRANCH_STAGING=main
BRANCH_PROD=main
HEALTH_SERVICE=app
HEALTH_CMD="true"
ENV
echo "notes du projet" > "${ORIGIN}/README.md"
git -C "${ORIGIN}" add -A && git -C "${ORIGIN}" commit -qm v1
git clone -q "${ORIGIN}" "${CLONE}"
git -C "${CLONE}" config user.email test@example.com; git -C "${CLONE}" config user.name test
git -C "${CLONE}" checkout -q --detach origin/main
# Comme sur le serveur : le fichier d'environnement existe et n'est JAMAIS suivi par git (la plateforme l'exige, le contrôle ne doit pas s'en plaindre).
echo "SECRET=x" > "${CLONE}/.env.staging"
run_check || echo "    sortie : $(tail -5 "${OUT}" | tr '\n' ' ' | cut -c1-700)"
check "un clone propre passe le contrôle" run_check
check "… sans la moindre remarque sur le clone" silent_on_clone

step "Un fichier NON suivi (.env.staging) ne gêne jamais, même modifié"
echo "SECRET=autre" > "${CLONE}/.env.staging"
echo "SECRET=autre" > "${CLONE}/fichier-non-suivi.txt"
check "fichiers non suivis (modifiés, ajoutés) : le contrôle passe" run_check
check "… et ne dit rien du clone" silent_on_clone
rm -f "${CLONE}/fichier-non-suivi.txt"

step "Un commit local (un pull ou un merge fait dans le clone) : signalé, pas bloquant"
git -C "${CLONE}" commit -q --allow-empty -m "Merge branch 'main' into HEAD"
check "le contrôle passe malgré le commit local" run_check
check "… mais le dit, et dit qu'il sera ignoré" sh -c "grep -q 'INFO — 1 commit(s) local' '${OUT}' && grep -q 'ignoré' '${OUT}'"
git -C "${CLONE}" checkout -q --detach origin/main

step "Un fichier suivi par git modifié à la main : refusé"
echo "modifié à la main" >> "${CLONE}/README.md"
check_not "le contrôle REFUSE un fichier suivi modifié" run_check
check "… en nommant le fichier" says "README.md"
check "… et en disant comment annuler" says "checkout -- ."
check "ALLOW_DIRTY_CLONE=1 laisse passer" sh -c "cd '${CLONE}' && ALLOW_DIRTY_CLONE=1 '${DEPLOY}' check staging"
git -C "${CLONE}" checkout -q -- .
check "une fois annulé, le contrôle repasse" run_check

step "Un dossier de .git que le compte ne peut pas écrire : refusé (la suite d'un pull en root)"
if [[ "$(id -u)" == 0 ]]; then
    printf '  (test ignoré : en root, tout est « inscriptible », le cas ne peut pas se produire)\n'
else
    chmod 555 "${CLONE}/.git/refs/remotes/origin"
    check_not "le contrôle REFUSE un dossier de .git non inscriptible" run_check
    check "… en nommant le dossier" says "refs/remotes/origin"
    check "… et en donnant la commande de réparation (chown, chmod)" sh -c "grep -q 'chown -R' '${OUT}' && grep -q 'chmod 2775' '${OUT}'"
    chmod 755 "${CLONE}/.git/refs/remotes/origin"
    check "une fois les droits rendus, le contrôle repasse" run_check
fi
