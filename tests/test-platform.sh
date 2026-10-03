#!/usr/bin/env bash
# The whole platform, as on the VPS, in an isolated copy:
#
#   nginx-proxy 1.7 (same settings as the VPS: TRUST_DOWNSTREAM_PROXY=true)
#   └─ the Core in production AND staging, deployed by infra/bin/deploy.sh
#      from a git clone of this repository (compose.prod.yaml, real
#      migrations against PostgreSQL 18, Valkey, the backup agent)
#   └─ a multi-tenant SaaS answering any *.monsaas.test sub-domain
#
# Checks: routing by host name, staging/prod isolation, backup taken before
# the production migration, forged X-Forwarded-For refused from a neighbour
# container, wildcard sub-domains, audit clean for the Core.
#
#   CORE_TEST_IMAGE=build (default)  build the real production image (Dockerfile)
#   CORE_TEST_IMAGE=dev              use a PHP dev image with this checkout's
#                                    code + vendor — for machines whose
#                                    network blocks apt (as in the agent
#                                    environment where these tests were first run)
#
# The proxy listens on 127.0.0.1:18080 only; Let's Encrypt is not exercised
# (it needs a public DNS name), everything else is real.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
trap finish EXIT
require_docker

export NGINX_PROXY_NETWORK=vpstest-nginx-proxy OBS_NETWORK=vpstest-observability
export STATE_DIR="${WORK}/state"
DEPLOY="${INFRA_DIR}/bin/deploy.sh"
PROXY=http://127.0.0.1:18080
PROD_HOST=core-system.visibilitycam.com
STAGING_HOST=core-system-staging.visibilitycam.com

docker network create "${NGINX_PROXY_NETWORK}" >/dev/null
docker network create "${OBS_NETWORK}" >/dev/null

step "nginx-proxy (réglages du VPS)"
docker run -d --name vpstest-nginx-proxy --network "${NGINX_PROXY_NETWORK}" -p 127.0.0.1:18080:80 \
    -e TRUST_DOWNSTREAM_PROXY=true -v /var/run/docker.sock:/tmp/docker.sock:ro \
    nginxproxy/nginx-proxy:1.7 >/dev/null
check "nginx-proxy démarré" wait_for 30 curl -s -o /dev/null "${PROXY}/"

step "Checkouts staging et prod (clone git de ce dépôt, HEAD = $(git -C "${REPO_DIR}" rev-parse --short HEAD))"
SHA="$(git -C "${REPO_DIR}" rev-parse HEAD)"
if [[ -n "$(git -C "${REPO_DIR}" status --porcelain -- compose.prod.yaml docker infra platform.env)" ]]; then
    red "  ! fichiers d'infra modifiés non commités : le test utilise le dernier commit"
fi
for env in staging prod; do
    git clone -q "${REPO_DIR}" "${WORK}/${env}"
    sed -i 's/^APP_NAME=.*/APP_NAME=vpstest-core/' "${WORK}/${env}/platform.env"
done

app_key="base64:$(head -c 32 /dev/urandom | base64)"
make_env() {  # make_env <example> <target> <prefix> <host> <deployment>
    sed -e "s#^APP_KEY=.*#APP_KEY=${app_key}#" \
        -e "s#^APP_URL=.*#APP_URL=https://$4#" \
        -e "s#^DB_PASSWORD=.*#DB_PASSWORD=dbpass-$5#" \
        -e "s#^TRUSTED_PROXY_TOKEN=.*#TRUSTED_PROXY_TOKEN=token-$5#" \
        -e "s#^BACKUP_PASSPHRASE=.*#BACKUP_PASSPHRASE=passphrase-$5#" \
        -e "s#^STACK_PREFIX=.*#STACK_PREFIX=$3#" \
        -e "s#^CORE_PUBLIC_HOST=.*#CORE_PUBLIC_HOST=$4#" \
        -e "s#^OTEL_EXPORTER_OTLP_ENDPOINT=.*#OTEL_EXPORTER_OTLP_ENDPOINT=#" \
        -e "s#^SESSION_SECURE_COOKIE=.*#SESSION_SECURE_COOKIE=false#" \
        "$1" > "$2"
    printf 'CORE_IMAGE=vpstest-core\nNGINX_PROXY_NETWORK=%s\nOBS_NETWORK=%s\n' "${NGINX_PROXY_NETWORK}" "${OBS_NETWORK}" >> "$2"
}
make_env "${WORK}/staging/.env.staging.example" "${WORK}/staging/.env.staging" vpstest-core-staging "${STAGING_HOST}" staging
make_env "${WORK}/prod/.env.production.example" "${WORK}/prod/.env" vpstest-core "${PROD_HOST}" prod
# CORE_ENV_FILE is relative to each checkout — already correct in the examples.
ok "fichiers d'environnement générés depuis .env.production.example / .env.staging.example"

step "Image du Core (${CORE_TEST_IMAGE:-build})"
if [[ "${CORE_TEST_IMAGE:-build}" == dev ]]; then
    # No copy of the code into an image: the checkout's code is mounted and
    # this working copy's vendor/ added read-only, through a compose override
    # (COMPOSE_FILE=base:override, supported by deploy.sh).
    docker tag thecodingmachine/php:8.4-v5-cli "vpstest-core:${SHA}"
    for env in staging prod; do
        cat > "${WORK}/${env}/compose.vpstest-dev.yaml" <<YAML
x-dev: &dev
  user: root
  working_dir: /var/www/html
  volumes:
    - ${WORK}/${env}:/var/www/html
    - ${REPO_DIR}/vendor:/var/www/html/vendor:ro
  environment:
    PHP_EXTENSION_BCMATH: "1"
    PHP_EXTENSION_GMP: "1"
    PHP_EXTENSION_INTL: "1"
    PHP_EXTENSION_PGSQL: "1"
    PHP_EXTENSION_PDO_PGSQL: "1"
    PHP_EXTENSION_REDIS: "1"
    PHP_EXTENSION_PCNTL: "1"
    PHP_INI_VARIABLES_ORDER: EGPCS
services:
  app:
    <<: *dev
    command: ["php", "artisan", "serve", "--host=0.0.0.0", "--port=8000", "--no-reload"]
  horizon:
    <<: *dev
  scheduler:
    <<: *dev
YAML
        sed -i 's/^COMPOSE_FILE=.*/COMPOSE_FILE=compose.prod.yaml:compose.vpstest-dev.yaml/' "${WORK}/${env}/platform.env"
        mkdir -p "${WORK}/${env}/storage/framework/"{cache,sessions,views} "${WORK}/${env}/storage/logs" "${WORK}/${env}/bootstrap/cache"
    done
    docker build -q -t vps/db-backup:1 "${INFRA_DIR}/images/db-backup" >/dev/null
    check "image dev du Core taguée ${SHA:0:12} (code monté, vendor en lecture seule)" docker image inspect "vpstest-core:${SHA}"
else
    check "build de la vraie image de production" sh -c "cd '${WORK}/staging' && '${DEPLOY}' build '${SHA}'"
fi

step "Déploiement staging puis promotion en production"
check "deploy.sh up staging (migrations + /health/ready)" sh -c "cd '${WORK}/staging' && '${DEPLOY}' up staging '${SHA}'"
check "deploy.sh promote --yes (sauvegarde + migrations + santé)" sh -c "cd '${WORK}/prod' && '${DEPLOY}' promote '${SHA}' --yes"
check "sauvegarde pre-deploy présente dans le volume de prod" sh -c \
    "docker run --rm -v vpstest-core-prod_backups:/b busybox ls /b | grep -q 'vpstest-core-.*-pre-deploy-${SHA:0:12}.dump.enc'"
check "même image en staging et en production" test \
    "$(docker inspect -f '{{.Image}}' vpstest-core-staging-app)" = "$(docker inspect -f '{{.Image}}' vpstest-core-app)"

step "Routage par nom d'hôte (nginx-proxy → sidecar → app)"
check "production répond sur ${PROD_HOST}" wait_for 30 curl -fsS -H "Host: ${PROD_HOST}" "${PROXY}/up"
check "staging répond sur ${STAGING_HOST}" curl -fsS -H "Host: ${STAGING_HOST}" "${PROXY}/up"
curl -s -o /dev/null -H "Host: ${PROD_HOST}" "${PROXY}/v1/whoami?probe=prod-only"
curl -s -o /dev/null -H "Host: ${STAGING_HOST}" "${PROXY}/v1/whoami?probe=staging-only"
sleep 2
check "la requête prod arrive dans le conteneur prod" sh -c "docker logs vpstest-core-app 2>&1 | grep -q prod-only"
check_not "…et pas dans le staging" sh -c "docker logs vpstest-core-staging-app 2>&1 | grep -q prod-only"
check "/metrics refusé depuis Internet" test "$(curl -s -o /dev/null -w '%{http_code}' -H "Host: ${PROD_HOST}" "${PROXY}/metrics")" = 404
check "hôte inconnu : 503 de nginx-proxy" test "$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: inconnu.visibilitycam.com' "${PROXY}/")" = 503

step "Isolation"
check_not "le staging ne voit pas la base de production" docker exec vpstest-core-staging-app getent hosts vpstest-core-postgres
check_not "nginx-proxy ne voit pas la base de production" docker exec vpstest-nginx-proxy getent hosts vpstest-core-postgres
check "la prod voit sa propre base" docker exec vpstest-core-app getent hosts postgres
check_not "aucun port publié par le Core" sh -c "docker ps --filter name=^vpstest-core --format '{{.Ports}}' | grep -q '0.0.0.0'"

step "Anti-usurpation d'IP (réseau partagé observability)"
docker run --rm --network "${OBS_NETWORK}" curlimages/curl:8.11.1 -s -o /dev/null \
    -H 'X-Forwarded-For: 102.244.0.1' -H 'X-Core-Proxy-Token: faux' "http://vpstest-core-app:8000/v1/whoami?probe=spoof-direct" || true
sleep 2
spoof_line="$(docker logs vpstest-core-app 2>&1 | grep 'spoof-direct' | grep 'http.request' | tail -1)"
check "requête directe du voisin journalisée" test -n "${spoof_line}"
check_not "l'IP falsifiée (102.244.0.1) n'est pas crue" grep -q '"client_ip":"102.244.0.1"' <<< "${spoof_line}"
curl -s -o /dev/null -H "Host: ${PROD_HOST}" "${PROXY}/v1/whoami?probe=via-proxy"
sleep 2
gateway="$(docker network inspect -f '{{(index .IPAM.Config 0).Gateway}}' "${NGINX_PROXY_NETWORK}")"
check "via nginx-proxy + sidecar : jeton accepté, IP du client (${gateway}) transmise" sh -c \
    "docker logs vpstest-core-app 2>&1 | grep via-proxy | grep http.request | grep -q '\"client_ip\":\"${gateway}\"'"

step "SaaS à sous-domaines automatiques (VIRTUAL_HOST wildcard)"
docker run -d --name vpstest-saas --network "${NGINX_PROXY_NETWORK}" \
    -e 'VIRTUAL_HOST=monsaas.test,*.monsaas.test' -e VIRTUAL_PORT=8080 \
    busybox sh -c 'mkdir /www && echo saas > /www/index.html && httpd -f -p 8080 -h /www' >/dev/null
check "client1.monsaas.test routé vers le SaaS" wait_for 20 sh -c "curl -fsS -H 'Host: client1.monsaas.test' '${PROXY}/' | grep -q saas"
check "nouveau-client.monsaas.test aussi, sans rien reconfigurer" sh -c "curl -fsS -H 'Host: nouveau-client.monsaas.test' '${PROXY}/' | grep -q saas"
check "monsaas.test (apex) routé" sh -c "curl -fsS -H 'Host: monsaas.test' '${PROXY}/' | grep -q saas"
check "le Core n'est pas touché par le wildcard" curl -fsS -H "Host: ${PROD_HOST}" "${PROXY}/up"

step "Retour arrière et audit"
check "rollback sans version précédente refusé proprement" sh -c "! (cd '${WORK}/prod' && '${DEPLOY}' rollback prod)"
audit="$(bash "${INFRA_DIR}/bin/vps-audit.sh" | sed -n '/^■ vpstest-core-prod$/,/^$/p')"
check_not "audit : aucune ligne CRITIQUE pour le Core" grep -q CRITIQUE <<< "${audit}"
check_not "audit : aucune ligne ATTENTION pour le Core" grep -q ATTENTION <<< "${audit}"
grep -E 'CRITIQUE|ATTENTION' <<< "${audit}" | sed 's/^/      /' || true

docker compose -p vpstest-core-prod -f "${WORK}/prod/compose.prod.yaml" --env-file "${WORK}/prod/.env" down -v >/dev/null 2>&1 || true
docker compose -p vpstest-core-staging -f "${WORK}/staging/compose.prod.yaml" --env-file "${WORK}/staging/.env.staging" down -v >/dev/null 2>&1 || true
docker image ls vpstest-core --format '{{.Repository}}:{{.Tag}}' | xargs -r docker rmi >/dev/null 2>&1 || true  # by tag: in dev mode the tag shares its ID with the base image
