#!/usr/bin/env bash
# Les branches sont CELLES DU PROJET, et le passage en production est encadré (bin/deploy.sh).
# Un projet de test : develop suivie par le staging, main = production, une seconde production (prodeu) sur la branche release ; puis un projet SANS staging.
# Ce que le test prouve : le staging suit la branche déclarée ; une version qui n'est pas dans la branche de production est REFUSÉE (rien n'est déployé) ;
# une fois fusionnée elle passe avec la MÊME image que le staging, sans rien reconstruire ; l'exception est explicite (SKIP_BRANCH_CHECK=1) ;
# plusieurs productions ont chacune leur branche ; une production sans staging construit la branche déclarée, sur demande.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
trap finish EXIT
require_docker

DEPLOY="${INFRA_DIR}/bin/deploy.sh"
export STATE_DIR="${WORK}/state"
ORIGIN="${WORK}/origin"
LOG="${STATE_DIR}/vpstest-br/deploy.log"

deploy() { local dir="$1"; shift; (cd "${dir}" && "${DEPLOY}" "$@"); }
page() { docker exec "vpstest-br-$1-app" cat /www/index.html 2>/dev/null; }
commit_version() {  # commit_version <repo> <texte> : un commit sur la branche courante du dépôt
    cat > "$1/Dockerfile" <<DOCKERFILE
FROM busybox
RUN mkdir /www && echo "$2" > /www/index.html && echo ok > /www/health
CMD ["httpd", "-f", "-p", "8080", "-h", "/www"]
DOCKERFILE
    git -C "$1" commit -qam "$2"
}
sha_of() { git -C "${ORIGIN}" rev-parse "$1"; }

step "Projet témoin : develop (staging), main (production), release (seconde production)"
mkdir -p "${ORIGIN}"
git -C "${ORIGIN}" init -q -b main
git -C "${ORIGIN}" config user.email test@example.com
git -C "${ORIGIN}" config user.name test
cat > "${ORIGIN}/compose.yaml" <<'YAML'
services:
  app:
    image: vpstest-br:${IMAGE_TAG:-latest}
    build: { context: . }
    container_name: vpstest-br-${ENV_NAME}-app
    environment:
      VIRTUAL_HOST: ${ENV_NAME}.br.vpstest.test
YAML
cat > "${ORIGIN}/platform.env" <<'ENV'
APP_NAME=vpstest-br
COMPOSE_FILE=compose.yaml
ENVIRONMENTS="staging prod prodeu"
PROD_ENVIRONMENTS="prod prodeu"
BRANCH_STAGING=develop
BRANCH_PROD=main
BRANCH_PRODEU=release
HEALTH_SERVICE=app
HEALTH_CMD="wget -qO- http://127.0.0.1:8080/health"
HEALTH_TIMEOUT=15
ENV
touch "${ORIGIN}/Dockerfile"; git -C "${ORIGIN}" add -A
commit_version "${ORIGIN}" v1
git -C "${ORIGIN}" branch release
git -C "${ORIGIN}" checkout -q -b develop
commit_version "${ORIGIN}" v2
git -C "${ORIGIN}" checkout -q main
for env in staging prod prodeu; do
    git clone -q "${ORIGIN}" "${WORK}/${env}"
    echo "ENV_NAME=${env}" > "${WORK}/${env}/.env$([[ ${env} == prod ]] || echo ".${env}")"
done
ok "dépôt avec trois branches, trois checkouts"

step "Le staging suit la branche déclarée par le projet (develop), pas main"
deploy "${WORK}/staging" watch >/dev/null 2>&1 || true
check "v2 (develop) en staging, alors que main est en v1" test "$(page staging)" = v2
status="$(deploy "${WORK}/prod" status 2>&1 || true)"
check "status dit que le staging suit origin/develop" grep -q "suit origin/develop" <<< "${status}"
check "status dit que la production ne reçoit que ce qui est dans origin/main" grep -q "ne reçoit que ce qui est déjà dans origin/main" <<< "${status}"
check "status dit que prodeu a SA branche (release)" grep -q "origin/release" <<< "${status}"

step "Une version qui n'est pas dans la branche de production est REFUSÉE"
check_not "promotion refusée : v2 est sur develop, pas dans main" deploy "${WORK}/prod" promote --yes --env prod
check "le journal dit pourquoi : pas dans origin/main, et comment faire" grep -q "n'est pas dans origin/main (BRANCH_PROD dans platform.env) : fusionner d'abord" "${LOG}"
check "rien n'a été déployé en production" test -z "$(docker ps -aq --filter name=^vpstest-br-prod-app$)"

step "Fusionnée dans main, elle passe avec la MÊME image, sans rien reconstruire"
git -C "${ORIGIN}" merge -q --ff-only develop
deploy "${WORK}/prod" promote --yes --env prod >/dev/null 2>&1 || true
check "v2 en production" test "$(page prod)" = v2
check "même image en staging et en production (même identifiant)" test \
    "$(docker inspect -f '{{.Image}}' vpstest-br-staging-app)" = "$(docker inspect -f '{{.Image}}' vpstest-br-prod-app)"
check "le journal le dit : « même image que staging : rien n'est reconstruit »" grep -q "même image que staging" "${LOG}"
check_not "aucune construction pour la production (le journal ne contient pas « build prod »)" grep -q "build prod " "${LOG}"

step "L'exception est explicite, jamais silencieuse"
git -C "${ORIGIN}" checkout -q develop
commit_version "${ORIGIN}" v3
git -C "${ORIGIN}" checkout -q main
deploy "${WORK}/staging" watch >/dev/null 2>&1 || true
check "v3 en staging" test "$(page staging)" = v3
check_not "v3 (jamais fusionnée dans main) est refusée en production" deploy "${WORK}/prod" promote --yes --env prod
check "toujours v2 en production" test "$(page prod)" = v2
SKIP_BRANCH_CHECK=1 deploy "${WORK}/prod" promote --yes --env prod >/dev/null 2>&1 || true
check "avec SKIP_BRANCH_CHECK=1 elle passe : v3 en production" test "$(page prod)" = v3
check "…et le journal le consigne comme une EXCEPTION" grep -q "SKIP_BRANCH_CHECK=1 : .* non vérifié contre origin/main (exception" "${LOG}"

step "Plusieurs productions : chacune a sa branche, et il faut dire laquelle"
check_not "sans --env, le projet a deux productions : la promotion refuse de choisir" deploy "${WORK}/prodeu" promote --yes
check_not "prodeu refuse v3 : elle n'est pas dans origin/release" deploy "${WORK}/prodeu" promote --yes --env prodeu
check "le journal nomme la branche de prodeu (BRANCH_PRODEU)" grep -q "n'est pas dans origin/release (BRANCH_PRODEU" "${LOG}"
git -C "${ORIGIN}" checkout -q release
git -C "${ORIGIN}" merge -q --ff-only develop
git -C "${ORIGIN}" checkout -q main
deploy "${WORK}/prodeu" promote --yes --env prodeu >/dev/null 2>&1 || true
check "une fois dans release, v3 passe en prodeu" test "$(page prodeu)" = v3
check "prodeu a la même image que le staging" test \
    "$(docker inspect -f '{{.Image}}' vpstest-br-staging-app)" = "$(docker inspect -f '{{.Image}}' vpstest-br-prodeu-app)"

step "Un projet SANS staging : la production suit la branche déclarée, sur demande"
SOLO="${WORK}/solo-origin"
mkdir -p "${SOLO}"
git -C "${SOLO}" init -q -b trunk
git -C "${SOLO}" config user.email test@example.com
git -C "${SOLO}" config user.name test
sed -e 's/vpstest-br/vpstest-solo/g' -e 's/\.br\./.solo./' "${ORIGIN}/compose.yaml" > "${SOLO}/compose.yaml"
cat > "${SOLO}/platform.env" <<'ENV'
APP_NAME=vpstest-solo
COMPOSE_FILE=compose.yaml
ENVIRONMENTS=prod
BRANCH_PROD=trunk
HEALTH_SERVICE=app
HEALTH_CMD="wget -qO- http://127.0.0.1:8080/health"
HEALTH_TIMEOUT=15
ENV
touch "${SOLO}/Dockerfile"; git -C "${SOLO}" add -A
commit_version "${SOLO}" solo-v1
git clone -q "${SOLO}" "${WORK}/solo"
echo "ENV_NAME=prod" > "${WORK}/solo/.env"
check "status décrit une production sans staging qui suit origin/trunk" grep -q "production sans staging : construit origin/trunk" <<< "$(deploy "${WORK}/solo" status 2>&1)"
deploy "${WORK}/solo" promote --yes >/dev/null 2>&1 || true
check "promote sans version construit origin/trunk (la branche déclarée) et déploie" test "$(docker exec vpstest-solo-prod-app cat /www/index.html 2>/dev/null)" = solo-v1
check "le journal dit que rien n'a été validé avant (pas de staging)" grep -q "pas de staging" "${STATE_DIR}/vpstest-solo/deploy.log"
commit_version "${SOLO}" solo-v2
deploy "${WORK}/solo" promote --yes >/dev/null 2>&1 || true
check "un second promote déploie la nouvelle version de trunk" test "$(docker exec vpstest-solo-prod-app cat /www/index.html 2>/dev/null)" = solo-v2

step "Sans staging ET sans branche déclarée : la plateforme ne devine rien"
# Un défaut « main » aurait déployé en silence quelque chose que personne n'a choisi : sans déclaration (BRANCH_PROD), pas de version devinée.
SOLO2="${WORK}/solo2-origin"
mkdir -p "${SOLO2}"
git -C "${SOLO2}" init -q -b trunk
git -C "${SOLO2}" config user.email test@example.com
git -C "${SOLO2}" config user.name test
sed -e 's/vpstest-br/vpstest-solo2/g' -e 's/\.br\./.solo2./' "${ORIGIN}/compose.yaml" > "${SOLO2}/compose.yaml"
grep -v '^BRANCH_PROD=' "${SOLO}/platform.env" | sed 's/vpstest-solo$/vpstest-solo2/' > "${SOLO2}/platform.env"
touch "${SOLO2}/Dockerfile"; git -C "${SOLO2}" add -A
commit_version "${SOLO2}" solo2-v1
git clone -q "${SOLO2}" "${WORK}/solo2"
echo "ENV_NAME=prod" > "${WORK}/solo2/.env"
check_not "promote sans version est refusé quand le projet n'a pas déclaré BRANCH_PROD" deploy "${WORK}/solo2" promote --yes
check "le message dit quoi faire : donner la version ou déclarer BRANCH_PROD" grep -q "ne déclare pas la branche de prod : donner la version .* ou déclarer BRANCH_PROD" "${STATE_DIR}/vpstest-solo2/deploy.log"
check "status le dit aussi (branche non déclarée)" grep -q "branche non déclarée" <<< "$(deploy "${WORK}/solo2" status 2>&1)"
deploy "${WORK}/solo2" promote origin/trunk --yes >/dev/null 2>&1 || true
check "mais une version explicite (promote origin/trunk) marche toujours" test "$(docker exec vpstest-solo2-prod-app cat /www/index.html 2>/dev/null)" = solo2-v1
