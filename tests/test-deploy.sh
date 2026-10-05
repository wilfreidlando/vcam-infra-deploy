#!/usr/bin/env bash
# bin/deploy.sh on a throw-away project (busybox httpd, local git
# remote): staging deploy, idle watch, promotion of the SAME image, broken
# version auto-rolled back, no retry loop on a broken commit, manual
# rollback, BUILD_PER_ENV mode, concurrent-run lock, pre-flight (platform.env
# read from the deployed commit, unknown services, HTTPS remote, private
# names exposed on a shared network).
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
    volumes: [ data:/data ]
volumes:
  data:
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
for env in staging prod; do
    git clone -q "${ORIGIN}" "${WORK}/${env}"
    echo "ENV_NAME=staging" > "${WORK}/${env}/.env.staging"
    echo "ENV_NAME=prod" > "${WORK}/${env}/.env"
done
ok "dépôt git, checkouts staging et prod"

step "Staging automatique"
(cd "${WORK}/staging" && "${DEPLOY}" watch >/dev/null 2>&1)
check "v1 en staging" test "$(page staging)" = v1
(cd "${WORK}/staging" && "${DEPLOY}" watch >/dev/null 2>&1)
check "watch sans nouveau commit : rien à faire" test "$(wc -l < "${STATE_DIR}/vpstest-demo/staging/history")" = 1

step "Promotion en production (même image)"
(cd "${WORK}/prod" && "${DEPLOY}" promote --yes >/dev/null 2>&1)
check "v1 en production" test "$(page prod)" = v1
check "même image en staging et en production" test \
    "$(docker inspect -f '{{.Image}}' vpstest-demo-staging-app)" = "$(docker inspect -f '{{.Image}}' vpstest-demo-prod-app)"
check "checkout prod positionné sur le commit déployé" test \
    "$(git -C "${WORK}/prod" rev-parse HEAD)" = "$(cat "${STATE_DIR}/vpstest-demo/prod/current")"

step "Version cassée"
commit_version v2
(cd "${WORK}/staging" && "${DEPLOY}" watch >/dev/null 2>&1)
check "v2 en staging" test "$(page staging)" = v2
commit_version v3 broken
check_not "déploiement de v3 refusé (santé KO)" sh -c "cd '${WORK}/staging' && '${DEPLOY}' watch"
check "retour automatique : v2 toujours en staging" test "$(page staging)" = v2
check "retour automatique confirmé en ligne (journal)" grep -q "retour automatique réussi" "${STATE_DIR}/vpstest-demo/deploy.log"
(cd "${WORK}/staging" && "${DEPLOY}" watch >/dev/null 2>&1)
check "pas de nouvelle tentative sur le commit cassé" test "$(cat "${STATE_DIR}/vpstest-demo/staging/failed")" = "$(git -C "${ORIGIN}" rev-parse HEAD)"

step "Promotion puis retour arrière manuel"
(cd "${WORK}/prod" && "${DEPLOY}" promote --yes >/dev/null 2>&1)
check "v2 en production" test "$(page prod)" = v2
(cd "${WORK}/prod" && "${DEPLOY}" rollback prod >/dev/null 2>&1)
check "rollback : v1 en production" test "$(page prod)" = v1

step "Verrou"
exec 8>"${STATE_DIR}/vpstest-demo/lock"; flock 8
check_not "un second déploiement simultané est refusé" sh -c "cd '${WORK}/staging' && '${DEPLOY}' watch"
exec 8>&-

step "Collision de sous-domaine"
docker run -d --name vpstest-intrus --label com.docker.compose.project=vpstest-intrus \
    -e VIRTUAL_HOST=staging.demo.vpstest.test busybox sleep 600 >/dev/null
commit_version v5
check_not "déploiement refusé : le nom staging.demo est déjà pris par un autre projet" \
    sh -c "cd '${WORK}/staging' && '${DEPLOY}' watch"
check "refus causé par la collision (journal)" grep -q "COLLISION : staging.demo.vpstest.test" "${STATE_DIR}/vpstest-demo/deploy.log"
check "rien n'a changé : v2 toujours en staging" test "$(page staging)" = v2
check "checkout staging remis sur la version en ligne" test \
    "$(git -C "${WORK}/staging" rev-parse HEAD)" = "$(cat "${STATE_DIR}/vpstest-demo/staging/current")"
check "commit marqué en échec : watch ne le reconstruit pas en boucle" sh -c "cd '${WORK}/staging' && '${DEPLOY}' watch"
docker rm -f vpstest-intrus >/dev/null

step "Volume encore utilisé par une ancienne installation"
docker run -d --name vpstest-ancienne-base -v vpstest-demo-staging_data:/var/lib/data busybox sleep 600 >/dev/null
check_not "déploiement refusé : un conteneur étranger utilise un volume du projet" \
    sh -c "cd '${WORK}/staging' && '${DEPLOY}' up staging '$(cat "${STATE_DIR}/vpstest-demo/staging/current")'"
check "cause expliquée dans le journal" grep -q "vpstest-demo-staging_data (utilisé par vpstest-ancienne-base)" "${STATE_DIR}/vpstest-demo/deploy.log"
docker rm -f vpstest-ancienne-base >/dev/null
# Ancienne pile portant le MÊME nom de projet compose, avec d'autres services.
docker run -d --name vpstest-ancien-db --label com.docker.compose.project=vpstest-demo-staging \
    --label com.docker.compose.service=ancien_db -v vpstest-demo-staging_data:/var/lib/data busybox sleep 600 >/dev/null
check_not "refus aussi pour une ancienne pile du même nom de projet (autre service)" \
    sh -c "cd '${WORK}/staging' && '${DEPLOY}' up staging '$(cat "${STATE_DIR}/vpstest-demo/staging/current")'"
docker rm -f vpstest-ancien-db >/dev/null
check "ancienne installation arrêtée : le déploiement passe" sh -c "cd '${WORK}/staging' && '${DEPLOY}' up staging '$(cat "${STATE_DIR}/vpstest-demo/staging/current")'"

step "nginx-proxy en erreur"
docker run -d --name vpstest-dp-proxy -v /var/run/docker.sock:/tmp/docker.sock:ro nginxproxy/nginx-proxy:1.7 >/dev/null
docker run -d --name vpstest-dp-a --label com.docker.compose.project=vpstest-a -e VIRTUAL_HOST=x.vpstest.test busybox sleep 600 >/dev/null
docker run -d --name vpstest-dp-b --label com.docker.compose.project=vpstest-b -e VIRTUAL_HOST=X.vpstest.test busybox sleep 600 >/dev/null
sleep 5
check_not "déploiement refusé tant que nginx-proxy refuse sa configuration" \
    sh -c "cd '${WORK}/staging' && NGINX_PROXY_CONTAINER=vpstest-dp-proxy '${DEPLOY}' up staging '$(cat "${STATE_DIR}/vpstest-demo/staging/current")'"
check "cause expliquée dans le journal" grep -q "nginx-proxy est déjà en erreur" "${STATE_DIR}/vpstest-demo/deploy.log"
docker rm -f vpstest-dp-proxy vpstest-dp-a vpstest-dp-b >/dev/null

step "platform.env lu dans le commit déployé (incident skills-devops : « no such service: app »)"
# Le même commit renomme le service ET met à jour platform.env : l'ancien
# platform.env (service « app ») ne doit pas servir à déployer le nouveau.
sed -i 's/^  app:$/  web:/' "${ORIGIN}/compose.yaml"
sed -i 's/^HEALTH_SERVICE=app$/HEALTH_SERVICE=web/; s/^MIGRATE_SERVICE=app$/MIGRATE_SERVICE=web/' "${ORIGIN}/platform.env"
git -C "${ORIGIN}" commit -qam "service app renommé web"
# Le service tient un volume : l'ancien conteneur doit d'abord être arrêté
# (sinon deux conteneurs sur les mêmes données) — refus expliqué, puis on suit
# la procédure donnée par le message.
check_not "service renommé : refusé tant que l'ancien conteneur tient le volume" sh -c "cd '${WORK}/staging' && '${DEPLOY}' watch"
check "le message donne la procédure du renommage" grep -q "Cas d'un service renommé" "${STATE_DIR}/vpstest-demo/deploy.log"
docker rm -f vpstest-demo-staging-app >/dev/null
check "ancien conteneur arrêté : le commit est déployé avec le platform.env du commit" sh -c "cd '${WORK}/staging' && '${DEPLOY}' watch"
check "staging sur ce commit" test "$(cat "${STATE_DIR}/vpstest-demo/staging/current")" = "$(git -C "${ORIGIN}" rev-parse HEAD)"

step "Contrôle avant déploiement : platform.env incohérent"
sed -i 's/^MIGRATE_SERVICE=web$/MIGRATE_SERVICE=absent/' "${ORIGIN}/platform.env"
git -C "${ORIGIN}" commit -qam "MIGRATE_SERVICE pointe vers un service absent"
before="$(cat "${STATE_DIR}/vpstest-demo/staging/current")"
check_not "déploiement refusé : MIGRATE_SERVICE=absent" sh -c "cd '${WORK}/staging' && '${DEPLOY}' watch"
check "cause expliquée dans le journal" grep -q "MIGRATE_SERVICE=absent, mais le compose n'a pas de service" "${STATE_DIR}/vpstest-demo/deploy.log"
check "rien n'a changé en staging" test "$(cat "${STATE_DIR}/vpstest-demo/staging/current")" = "${before}"
sed -i 's/^MIGRATE_SERVICE=absent$/MIGRATE_SERVICE=web/' "${ORIGIN}/platform.env"
git -C "${ORIGIN}" commit -qam "MIGRATE_SERVICE corrigé"
check "commit correctif : déployé" sh -c "cd '${WORK}/staging' && '${DEPLOY}' watch"

step "Origin en HTTPS : échec expliqué, jamais d'attente d'un mot de passe"
url="$(git -C "${WORK}/staging" remote get-url origin)"
git -C "${WORK}/staging" remote set-url origin https://127.0.0.1:9/vpstest/demo.git
check_not "watch échoue sans rester bloqué" timeout 30 sh -c "cd '${WORK}/staging' && '${DEPLOY}' watch < /dev/null"
check "le journal donne la correction (clé de déploiement)" grep -q "origin est en HTTPS" "${STATE_DIR}/vpstest-demo/deploy.log"
git -C "${WORK}/staging" remote set-url origin "${url}"

step "Noms privés exposés sur un réseau partagé (incident skills-devops : « db » d'un autre projet)"
docker network create vpstest-shared >/dev/null
NAMES="${WORK}/names"; mkdir -p "${NAMES}"
cat > "${NAMES}/compose.yaml" <<'YAML'
services:
  web:
    image: busybox
    networks: [ default, shared ]
  db:
    image: busybox
networks:
  shared: { name: vpstest-shared, external: true }
YAML
printf 'APP_NAME=vpstest-names\nCOMPOSE_FILE=compose.yaml\nHEALTH_SERVICE=web\nHEALTH_CMD=true\n' > "${NAMES}/platform.env"
: > "${NAMES}/.env.staging"
check "aucun autre projet sur le réseau partagé : check OK" sh -c "cd '${NAMES}' && '${DEPLOY}' check staging"
docker run -d --name vpstest-autre-db --network vpstest-shared --network-alias db busybox sleep 600 >/dev/null
check_not "un autre projet publie « db » sur le réseau partagé : check refuse" sh -c "cd '${NAMES}' && '${DEPLOY}' check staging"
check "le journal nomme le conflit et le conteneur" grep -q "nom « db » (service privé db) aussi publié sur le réseau partagé vpstest-shared par vpstest-autre-db" "${STATE_DIR}/vpstest-names/deploy.log"
sed -i 's/^  db:$/  vpstest-names-db:/' "${NAMES}/compose.yaml"
check "service renommé (nom propre au projet) : check OK malgré l'intrus" sh -c "cd '${NAMES}' && '${DEPLOY}' check staging"
docker rm -f vpstest-autre-db >/dev/null; docker network rm vpstest-shared >/dev/null

step "Mode BUILD_PER_ENV (Next.js)"
# Réglage commité (platform.env n'est jamais modifié sur le serveur).
echo "BUILD_PER_ENV=1" >> "${ORIGIN}/platform.env"
commit_version v4
(cd "${WORK}/staging" && "${DEPLOY}" watch >/dev/null 2>&1)
# Première promotion depuis le renommage app → web : même procédure qu'en staging.
check_not "prod : refusé tant que l'ancien conteneur « app » tient le volume" sh -c "cd '${WORK}/prod' && '${DEPLOY}' promote --yes"
docker rm -f vpstest-demo-prod-app >/dev/null
(cd "${WORK}/prod" && "${DEPLOY}" promote --yes >/dev/null 2>&1)
sha="$(git -C "${ORIGIN}" rev-parse HEAD)"
check "image <sha>-staging construite" docker image inspect "vpstest-demo:${sha}-staging"
check "image <sha>-prod construite depuis le même commit" docker image inspect "vpstest-demo:${sha}-prod"
check "v4 en production" test "$(page prod)" = v4

step "Trois environnements : dev (branche develop) → staging (main) → prod"
printf 'ENVIRONMENTS="dev staging prod"\nBRANCH_DEV=develop\n' >> "${ORIGIN}/platform.env"
git -C "${ORIGIN}" commit -qam "environnement dev"
(cd "${WORK}/staging" && "${DEPLOY}" watch >/dev/null 2>&1)
(cd "${WORK}/prod" && "${DEPLOY}" promote --yes >/dev/null 2>&1)
git -C "${ORIGIN}" checkout -q -b develop
commit_version dev-v1
git -C "${ORIGIN}" checkout -q main
git clone -q "${ORIGIN}" "${WORK}/dev"
for env in dev staging prod; do echo "ENV_NAME=dev" > "${WORK}/${env}/.env.dev"; done
(cd "${WORK}/dev" && "${DEPLOY}" watch dev >/dev/null 2>&1)
check "dev suit develop : dev-v1 en dev" test "$(page dev)" = dev-v1
check "le staging n'a pas bougé (v4)" test "$(page staging)" = v4
check "projets compose distincts par environnement" docker inspect vpstest-demo-dev-app --format '{{index .Config.Labels "com.docker.compose.project"}}'
check_not "la production ne se déploie jamais en watch" sh -c "cd '${WORK}/prod' && '${DEPLOY}' watch prod"
check "status liste les trois environnements" sh -c "cd '${WORK}/prod' && '${DEPLOY}' status | grep -c '^── ' | grep -qx 3"

step "Disposition réelle : un seul fichier d'environnement par dossier"
# Sur le serveur, /app/<projet>/prod n'a que .env et /app/<projet>/staging que .env.staging
# (contrat, § 1). Le nettoyage des images après une promotion cherchait le fichier des AUTRES
# environnements, échouait (« fichier … absent ») et ne supprimait jamais rien : le défaut était
# masqué parce que ce test posait tous les fichiers dans chaque dossier.
rm -f "${WORK}/prod/.env.staging" "${WORK}/prod/.env.dev" "${WORK}/staging/.env" "${WORK}/staging/.env.dev"
commit_version v5
lines="$(wc -l < "${STATE_DIR}/vpstest-demo/deploy.log")"
(cd "${WORK}/staging" && "${DEPLOY}" watch >/dev/null 2>&1)
(cd "${WORK}/prod" && "${DEPLOY}" promote --yes >/dev/null 2>&1)
check "v5 en production, depuis un dossier qui n'a que son .env" test "$(page prod)" = v5
check_not "aucune erreur « fichier … absent » dans le journal après la promotion (nettoyage des images)" \
    sh -c "tail -n +$((lines + 1)) '${STATE_DIR}/vpstest-demo/deploy.log' | grep -q 'absent (copier'"

# Projet témoin minimal pour les scénarios ci-dessous : make_project <dossier> <app> "<lignes de platform.env>"
make_project() {
    local dir="$1" app="$2" extra="$3"
    mkdir -p "${dir}"
    git -C "${dir}" init -q -b main
    git -C "${dir}" config user.email test@example.com
    git -C "${dir}" config user.name test
    cat > "${dir}/compose.yaml" <<YAML
services:
  app:
    image: ${app}:\${IMAGE_TAG:-latest}
    build: { context: . }
    container_name: ${app}-\${ENV_NAME}-app
    environment:
      VIRTUAL_HOST: \${ENV_NAME}.${app}.vpstest.test
YAML
    cat > "${dir}/platform.env" <<ENV
APP_NAME=${app}
COMPOSE_FILE=compose.yaml
HEALTH_SERVICE=app
HEALTH_CMD="wget -qO- http://127.0.0.1:8080/health"
HEALTH_TIMEOUT=15
${extra}
ENV
    cat > "${dir}/Dockerfile" <<'DOCKERFILE'
FROM busybox
RUN mkdir /www && echo v1 > /www/index.html && echo ok > /www/health
CMD ["httpd", "-f", "-p", "8080", "-h", "/www"]
DOCKERFILE
    git -C "${dir}" add -A && git -C "${dir}" commit -qm v1
}
bump() {  # bump <dossier> <texte>
    sed -i "s/echo v[0-9]* > \/www\/index.html/echo $2 > \/www\/index.html/" "$1/Dockerfile"
    git -C "$1" commit -qam "$2"
}
solo_page() { docker exec "vpstest-solo-$1-app" cat /www/index.html 2>/dev/null; }
multi_page() { docker exec "vpstest-multi-$1-app" cat /www/index.html 2>/dev/null; }

step "Projet sans staging : il se construit et se déploie lui-même en production"
make_project "${WORK}/solo-origin" vpstest-solo 'ENVIRONMENTS=prod'
git clone -q "${WORK}/solo-origin" "${WORK}/solo"
echo "ENV_NAME=prod" > "${WORK}/solo/.env"
check_not "watch refusé : rien ne se déploie automatiquement" sh -c "cd '${WORK}/solo' && '${DEPLOY}' watch"
check_not "promote sans version refusé : on ne devine pas quoi mettre en production" sh -c "cd '${WORK}/solo' && '${DEPLOY}' promote --yes"
(cd "${WORK}/solo" && "${DEPLOY}" promote origin/main --yes >/dev/null 2>&1)
check "v1 en production, construite sur place (aucun staging)" test "$(solo_page prod)" = v1
bump "${WORK}/solo-origin" v2
(cd "${WORK}/solo" && "${DEPLOY}" promote origin/main --yes >/dev/null 2>&1)
check "v2 en production" test "$(solo_page prod)" = v2
(cd "${WORK}/solo" && "${DEPLOY}" rollback prod >/dev/null 2>&1)
check "retour arrière : v1" test "$(solo_page prod)" = v1
check "check sans staging : contrôle la production" sh -c "cd '${WORK}/solo' && '${DEPLOY}' check >/dev/null 2>&1"

step "Plusieurs productions : staging, prod et prodb"
make_project "${WORK}/multi-origin" vpstest-multi 'ENVIRONMENTS="staging prod prodb"
PROD_ENVIRONMENTS="prod prodb"'
for env in staging prod prodb; do git clone -q "${WORK}/multi-origin" "${WORK}/multi-${env}"; done
echo "ENV_NAME=staging" > "${WORK}/multi-staging/.env.staging"
echo "ENV_NAME=prod" > "${WORK}/multi-prod/.env"
echo "ENV_NAME=prodb" > "${WORK}/multi-prodb/.env.prodb"
(cd "${WORK}/multi-staging" && "${DEPLOY}" watch >/dev/null 2>&1)
check "v1 en staging" test "$(multi_page staging)" = v1
check_not "promote sans --env refusé : laquelle des deux productions ?" sh -c "cd '${WORK}/multi-prod' && '${DEPLOY}' promote --yes"
check_not "--env staging refusé : ce n'est pas une production" sh -c "cd '${WORK}/multi-staging' && '${DEPLOY}' promote --env staging --yes"
check_not "watch d'une production refusé" sh -c "cd '${WORK}/multi-prodb' && '${DEPLOY}' watch prodb"
(cd "${WORK}/multi-prod" && "${DEPLOY}" promote --env prod --yes >/dev/null 2>&1)
(cd "${WORK}/multi-prodb" && "${DEPLOY}" promote --env prodb --yes >/dev/null 2>&1)
check "v1 en prod" test "$(multi_page prod)" = v1
check "v1 en prodb" test "$(multi_page prodb)" = v1
check "même image dans les trois environnements" test \
    "$(docker inspect -f '{{.Image}}' vpstest-multi-staging-app)" = "$(docker inspect -f '{{.Image}}' vpstest-multi-prodb-app)"
bump "${WORK}/multi-origin" v2
(cd "${WORK}/multi-staging" && "${DEPLOY}" watch >/dev/null 2>&1)
(cd "${WORK}/multi-prod" && "${DEPLOY}" promote --env prod --yes >/dev/null 2>&1)
check "prod passe en v2, prodb reste en v1 : les productions sont indépendantes" \
    test "$(multi_page prod)-$(multi_page prodb)" = v2-v1
check "status liste les trois environnements" sh -c "cd '${WORK}/multi-prod' && '${DEPLOY}' status | grep -c '^── ' | grep -qx 3"
cat > "${WORK}/bad.env" <<'ENV'
APP_NAME=vpstest-bad
ENVIRONMENTS="staging prod-eu"
ENV
mkdir -p "${WORK}/bad" && cp "${WORK}/bad.env" "${WORK}/bad/platform.env"
check_not "nom d'environnement invalide (« prod-eu ») refusé avec explication" sh -c "cd '${WORK}/bad' && '${DEPLOY}' status"

docker image ls vpstest-demo -q | xargs -r docker rmi -f >/dev/null 2>&1 || true
docker image ls vpstest-solo -q | xargs -r docker rmi -f >/dev/null 2>&1 || true
docker image ls vpstest-multi -q | xargs -r docker rmi -f >/dev/null 2>&1 || true
