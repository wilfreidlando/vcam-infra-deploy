#!/usr/bin/env bash
# infra/bin/deploy.sh on a throw-away project (busybox httpd, local git
# remote), ONE folder for every environment: staging deploy, idle watch, promotion of the SAME image, broken
# version auto-rolled back, no retry loop on a broken commit, manual
# rollback, BUILD_PER_ENV mode, concurrent-run lock, dev/staging/prod with
# one worktree per environment and the folder itself left untouched.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
trap finish EXIT
require_docker

DEPLOY="${INFRA_DIR}/bin/deploy.sh"
export STATE_DIR="${WORK}/state"
ORIGIN="${WORK}/origin"

page() { docker exec "vpstest-demo-$1-app" cat /www/index.html 2>/dev/null; }
commit_version() {  # commit_version <text> [broken]
    local health='echo ok > /www/health'
    [[ "${2:-}" == broken ]] && health='true'
    cat > "${ORIGIN}/Dockerfile" <<DOCKERFILE
FROM busybox
RUN mkdir /www && echo "$1" > /www/index.html && ${health}
CMD ["httpd", "-f", "-p", "8080", "-h", "/www"]
DOCKERFILE
    git -C "${ORIGIN}" commit -qam "$1"
}

step "Projet témoin"
mkdir -p "${ORIGIN}"
git -C "${ORIGIN}" init -q -b main
git -C "${ORIGIN}" config user.email test@example.com
git -C "${ORIGIN}" config user.name test
cat > "${ORIGIN}/compose.yaml" <<'YAML'
services:
  app:
    image: vpstest-demo:${IMAGE_TAG:-latest}
    build: { context: . }
    container_name: vpstest-demo-${ENV_NAME}-app
    environment:
      VIRTUAL_HOST: ${ENV_NAME}.demo.vpstest.test
YAML
cat > "${ORIGIN}/platform.env" <<'ENV'
APP_NAME=vpstest-demo
COMPOSE_FILE=compose.yaml
HEALTH_SERVICE=app
HEALTH_CMD="wget -qO- http://127.0.0.1:8080/health"
HEALTH_TIMEOUT=15
MIGRATE_SERVICE=app
MIGRATE_CMD="echo migration"
ENV
touch "${ORIGIN}/Dockerfile"; git -C "${ORIGIN}" add -A
commit_version v1
# Le seul dossier du projet sur le serveur : il sert à tous les environnements.
P="${WORK}/vpstest-demo"
git clone -q "${ORIGIN}" "${P}"
echo "ENV_NAME=staging" > "${P}/.env.staging"
echo "ENV_NAME=prod" > "${P}/.env"
FOLDER_HEAD="$(git -C "${P}" rev-parse HEAD)"
SRC="${STATE_DIR}/vpstest-demo/src"
ok "dépôt git, un seul dossier pour tous les environnements"

step "Staging automatique"
(cd "${P}" && "${DEPLOY}" watch >/dev/null 2>&1)
check "v1 en staging" test "$(page staging)" = v1
(cd "${P}" && "${DEPLOY}" watch >/dev/null 2>&1)
check "watch sans nouveau commit : rien à faire" test "$(wc -l < "${STATE_DIR}/vpstest-demo/staging/history")" = 1

step "Promotion en production (même image)"
(cd "${P}" && "${DEPLOY}" promote --yes >/dev/null 2>&1)
check "v1 en production" test "$(page prod)" = v1
check "même image en staging et en production" test \
    "$(docker inspect -f '{{.Image}}' vpstest-demo-staging-app)" = "$(docker inspect -f '{{.Image}}' vpstest-demo-prod-app)"
check "copie de travail prod positionnée sur le commit déployé" test \
    "$(git -C "${SRC}/prod" rev-parse HEAD)" = "$(cat "${STATE_DIR}/vpstest-demo/prod/current")"

step "Version cassée"
commit_version v2
(cd "${P}" && "${DEPLOY}" watch >/dev/null 2>&1)
check "v2 en staging" test "$(page staging)" = v2
commit_version v3 broken
check_not "déploiement de v3 refusé (santé KO)" sh -c "cd '${P}' && '${DEPLOY}' watch"
check "retour automatique : v2 toujours en staging" test "$(page staging)" = v2
(cd "${P}" && "${DEPLOY}" watch >/dev/null 2>&1)
check "pas de nouvelle tentative sur le commit cassé" test "$(cat "${STATE_DIR}/vpstest-demo/staging/failed")" = "$(git -C "${ORIGIN}" rev-parse HEAD)"

step "Promotion puis retour arrière manuel"
(cd "${P}" && "${DEPLOY}" promote --yes >/dev/null 2>&1)
check "v2 en production" test "$(page prod)" = v2
(cd "${P}" && "${DEPLOY}" rollback prod >/dev/null 2>&1)
check "rollback : v1 en production" test "$(page prod)" = v1

step "Verrou"
exec 8>"${STATE_DIR}/vpstest-demo/lock"; flock 8
check_not "un second déploiement simultané est refusé" sh -c "cd '${P}' && '${DEPLOY}' watch"
exec 8>&-

step "Collision de sous-domaine"
docker run -d --name vpstest-intrus --label com.docker.compose.project=vpstest-intrus \
    -e VIRTUAL_HOST=staging.demo.vpstest.test busybox sleep 600 >/dev/null
commit_version v5
check_not "déploiement refusé : le nom staging.demo est déjà pris par un autre projet" \
    sh -c "cd '${P}' && '${DEPLOY}' watch"
check "refus causé par la collision (journal)" grep -q "COLLISION : staging.demo.vpstest.test" "${STATE_DIR}/vpstest-demo/deploy.log"
check "rien n'a changé : v2 toujours en staging" test "$(page staging)" = v2
check "copie de travail staging remise sur la version en ligne" test \
    "$(git -C "${SRC}/staging" rev-parse HEAD)" = "$(cat "${STATE_DIR}/vpstest-demo/staging/current")"
check "commit marqué en échec : watch ne le reconstruit pas en boucle" sh -c "cd '${P}' && '${DEPLOY}' watch"
docker rm -f vpstest-intrus >/dev/null

step "nginx-proxy en erreur"
docker run -d --name vpstest-dp-proxy -v /var/run/docker.sock:/tmp/docker.sock:ro nginxproxy/nginx-proxy:1.7 >/dev/null
docker run -d --name vpstest-dp-a --label com.docker.compose.project=vpstest-a -e VIRTUAL_HOST=x.vpstest.test busybox sleep 600 >/dev/null
docker run -d --name vpstest-dp-b --label com.docker.compose.project=vpstest-b -e VIRTUAL_HOST=X.vpstest.test busybox sleep 600 >/dev/null
sleep 5
check_not "déploiement refusé tant que nginx-proxy refuse sa configuration" \
    sh -c "cd '${P}' && NGINX_PROXY_CONTAINER=vpstest-dp-proxy '${DEPLOY}' up staging '$(cat "${STATE_DIR}/vpstest-demo/staging/current")'"
check "cause expliquée dans le journal" grep -q "nginx-proxy est déjà en erreur" "${STATE_DIR}/vpstest-demo/deploy.log"
docker rm -f vpstest-dp-proxy vpstest-dp-a vpstest-dp-b >/dev/null

step "Mode BUILD_PER_ENV (Next.js)"
commit_version v4
echo "BUILD_PER_ENV=1" >> "${P}/platform.env"
(cd "${P}" && "${DEPLOY}" watch >/dev/null 2>&1)
(cd "${P}" && "${DEPLOY}" promote --yes >/dev/null 2>&1)
sha="$(git -C "${ORIGIN}" rev-parse HEAD)"
check "image <sha>-staging construite" docker image inspect "vpstest-demo:${sha}-staging"
check "image <sha>-prod construite depuis le même commit" docker image inspect "vpstest-demo:${sha}-prod"
check "v4 en production" test "$(page prod)" = v4

step "Trois environnements : dev (branche develop) → staging (main) → prod"
git -C "${ORIGIN}" checkout -q -b develop
commit_version dev-v1
git -C "${ORIGIN}" checkout -q main
printf 'ENVIRONMENTS="dev staging prod"\nBRANCH_DEV=develop\n' >> "${P}/platform.env"
echo "ENV_NAME=dev" > "${P}/.env.dev"
(cd "${P}" && "${DEPLOY}" watch dev >/dev/null 2>&1)
check "dev suit develop : dev-v1 en dev" test "$(page dev)" = dev-v1
check "le staging n'a pas bougé (v4)" test "$(page staging)" = v4
check "projets compose distincts par environnement" docker inspect vpstest-demo-dev-app --format '{{index .Config.Labels "com.docker.compose.project"}}'
check_not "la production ne se déploie jamais en watch" sh -c "cd '${P}' && '${DEPLOY}' watch prod"
check "chaque environnement a ses propres fichiers (dev sur develop, prod sur main)" sh -c \
    "grep -q dev-v1 '${SRC}/dev/Dockerfile' && grep -q v4 '${SRC}/prod/Dockerfile'"
check "le dossier du projet n'a jamais été basculé (seulement fetch)" test "$(git -C "${P}" rev-parse HEAD)" = "${FOLDER_HEAD}"
check "status liste les trois environnements" sh -c "cd '${P}' && '${DEPLOY}' status | grep -c '^── ' | grep -qx 3"

docker image ls vpstest-demo -q | xargs -r docker rmi -f >/dev/null 2>&1 || true
