#!/usr/bin/env bash
# bin/vps-inventory.sh on a miniature server: a project checkout cloned over
# HTTPS with a token in the URL, a deployed project, a foreign database on
# the shared network, secrets in container environments. Checks that the
# report sees every problem — and leaks no secret.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
trap finish EXIT
require_docker

SECRET="topsecret-$$-valeur"
export APPS_DIR="${WORK}/app" STATE_DIR="${WORK}/state" PLATFORM_DIR="${WORK}/app/vps-platform"
export SHARED_NETWORKS="vpstest-inv-proxy" NGINX_PROXY_CONTAINER="vpstest-inv-absent"

step "Serveur en miniature"
docker network create vpstest-inv-proxy >/dev/null
docker network create vpstest-inv-private >/dev/null
# Projet sain : web sur le réseau partagé, base privée au nom propre.
docker run -d --name vpstest-inv-good-web --network vpstest-inv-proxy --network-alias good-web \
    --label com.docker.compose.project=vpstest-good-prod -e "APP_KEY=${SECRET}" busybox sleep 600 >/dev/null
docker run -d --name vpstest-inv-good-db --network vpstest-inv-private --network-alias good-db \
    --label com.docker.compose.project=vpstest-good-prod -e "POSTGRES_PASSWORD=${SECRET}" postgres:18-alpine sleep 600 >/dev/null 2>&1 \
    || docker run -d --name vpstest-inv-good-db --network vpstest-inv-private busybox sleep 600 >/dev/null
# Ancienne installation : base sur le réseau partagé, sous le nom générique « db ».
docker run -d --name vpstest-inv-old-db --network vpstest-inv-proxy --network-alias db \
    --label com.docker.compose.project=vpstest-old -e "MYSQL_ROOT_PASSWORD=${SECRET}" redis:7.2-alpine >/dev/null
docker run -d --name vpstest-inv-other-db --network vpstest-inv-proxy --network-alias db \
    --label com.docker.compose.project=vpstest-other busybox sleep 600 >/dev/null
# Dossiers de projets.
mkdir -p "${APPS_DIR}/good/prod" "${APPS_DIR}/legacy/prod"
git -C "${APPS_DIR}/good/prod" init -q && git -C "${APPS_DIR}/good/prod" remote add origin git@github-good:org/good.git
printf 'APP_NAME=vpstest-good\nCOMPOSE_FILE=compose.yaml\n' > "${APPS_DIR}/good/prod/platform.env"
echo "APP_KEY=${SECRET}" > "${APPS_DIR}/good/prod/.env"
git -C "${APPS_DIR}/good/prod" -c user.email=t@t -c user.name=t add platform.env && \
    git -C "${APPS_DIR}/good/prod" -c user.email=t@t -c user.name=t commit -qm init
mkdir -p "${STATE_DIR}/vpstest-good/prod" && echo 0123456789abcdef0123 > "${STATE_DIR}/vpstest-good/prod/current"
git -C "${APPS_DIR}/legacy/prod" init -q
git -C "${APPS_DIR}/legacy/prod" remote add origin "https://deploy:${SECRET}@github.com/org/legacy.git"
mkdir -p "${WORK}/compose-proj" && printf 'services:\n  a:\n    image: busybox\n    command: sleep 600\n' > "${WORK}/compose-proj/compose.yaml"
docker compose -p vpstest-inv-compose -f "${WORK}/compose-proj/compose.yaml" up -d >/dev/null 2>&1
ok "deux projets, une base étrangère « db » sur le réseau partagé, des secrets partout"

step "Inventaire"
"${INFRA_DIR}/bin/vps-inventory.sh" --no-audit > "${WORK}/inventaire.md" 2>"${WORK}/err"
check "l'inventaire se termine" test -s "${WORK}/inventaire.md"
check "projet compose listé avec son état" grep -q '| vpstest-inv-compose | running(1) |' "${WORK}/inventaire.md"
check "aucun secret dans le rapport (env, .env, URL git)" sh -c "! grep -q '${SECRET}' '${WORK}/inventaire.md'"
check "le jeton de l'URL HTTPS est masqué" grep -q 'https://\*\*\*@github.com/org/legacy.git' "${WORK}/inventaire.md"
check "le clone HTTPS est signalé (C9)" grep -q 'HTTPS : C9' "${WORK}/inventaire.md"
check "projet déployé : APP_NAME et version en prod" grep -q 'APP_NAME=vpstest-good.*prod=0123456789ab' "${WORK}/inventaire.md"
check "fichier .env listé par son nom seulement" grep -q '| .env |' "${WORK}/inventaire.md"
check "base/cache sur le réseau partagé signalé" grep -q 'vpstest-inv-old-db .*⚠ base/cache' "${WORK}/inventaire.md"
check "nom générique « db » publié par deux projets signalé" grep -q '⚠ « db » publié par : vpstest-old,vpstest-other' "${WORK}/inventaire.md"
check "le web du projet sain, au nom propre, n'est pas signalé" sh -c "grep 'vpstest-inv-good-web' '${WORK}/inventaire.md' | grep -qv '⚠'"
check "la base privée n'apparaît pas sur le réseau partagé" sh -c "! grep -q 'vpstest-inv-good-db' '${WORK}/inventaire.md'"
check "aucune erreur sur la sortie d'erreur" test ! -s "${WORK}/err"

step "Audit : noms génériques en conflit"
SHARED_NETWORKS=vpstest-inv-proxy "${INFRA_DIR}/bin/vps-audit.sh" > "${WORK}/audit.txt" 2>&1 || true
check "l'audit signale « db » publié par deux projets (ATTENTION)" grep -q 'ATTENTION.*nom « db ».*vpstest-old vpstest-other' "${WORK}/audit.txt"

step "Lecture seule"
before="$(docker ps -a --format '{{.Names}} {{.Status}}' | grep vpstest-inv | sed 's/Up [^)]*/Up/' | sort)"
"${INFRA_DIR}/bin/vps-inventory.sh" --no-audit >/dev/null 2>&1
after="$(docker ps -a --format '{{.Names}} {{.Status}}' | grep vpstest-inv | sed 's/Up [^)]*/Up/' | sort)"
check "aucun conteneur créé, arrêté ou redémarré" test "${before}" = "${after}"
check "aucun fichier modifié dans les dossiers de projets" sh -c "test -z \"\$(git -C '${APPS_DIR}/good/prod' status --porcelain --untracked-files=no)\""
