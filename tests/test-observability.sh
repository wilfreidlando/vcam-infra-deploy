#!/usr/bin/env bash
# Shared observability (observability), isolated copy: an opted-in
# container's logs, metrics and traces arrive with the right labels; a
# container without labels is ignored; a private container (label, no shared
# network — the PHP-FPM case) still has its logs collected, once even on two
# networks, and is never scraped; Grafana provisions its folders,
# dashboards and alert rules.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
trap finish EXIT
require_docker

export OBS_PREFIX=vpstest-obs OBS_NETWORK=vpstest-observability NGINX_PROXY_NETWORK=vpstest-nginx-proxy
export GRAFANA_ADMIN_PASSWORD=vpstest-pass GRAFANA_HOST=grafana.vpstest.localhost
docker network create "${OBS_NETWORK}" >/dev/null
docker network create "${NGINX_PROXY_NETWORK}" >/dev/null

step "Secrets de la plateforme jamais commités"
# observability/.env contient le mot de passe de Grafana et celui du SMTP : un
# « git add -A » ne doit jamais pouvoir le publier (contrat, clause C10).
check "observability/.env est ignoré par git" git -C "${INFRA_DIR}" check-ignore -q observability/.env
check_not "le modèle .env.example reste suivi" git -C "${INFRA_DIR}" check-ignore -q observability/.env.example

step "Démarrage de la stack"
check "stack démarrée" docker compose -p vpstest-obs -f "${INFRA_DIR}/observability/compose.yaml" up -d

graf() { docker exec vpstest-obs-grafana wget -qO- "$@"; }
check "Grafana répond" wait_for 120 graf "http://admin:vpstest-pass@localhost:3000/api/health"

step "Projets observés"
docker run -d --name vpstest-obs-demo --network "${OBS_NETWORK}" \
    -l observability.enable=true -l observability.app=demo-laravel -l observability.deployment=staging \
    -l observability.metrics.port=8080 -l com.docker.compose.service=app \
    busybox sh -c 'mkdir -p /www && printf "# TYPE demo_up gauge\ndemo_up 1\n" > /www/metrics && httpd -p 8080 -h /www && while true; do echo "{\"message\":\"hello\",\"level_name\":\"ERROR\",\"extra\":{\"correlation_id\":\"corr-123\"}}"; sleep 2; done' >/dev/null
docker run -d --name vpstest-obs-ignored --network "${OBS_NETWORK}" -l com.docker.compose.project=secret-project \
    busybox sh -c 'while true; do echo ignored-line; sleep 2; done' >/dev/null

# PHP-FPM case: labelled, kept OFF the shared network, on two private networks.
docker network create vpstest-obs-priv1 >/dev/null
docker network create vpstest-obs-priv2 >/dev/null
docker run -d --name vpstest-obs-private --network vpstest-obs-priv1 \
    -l observability.enable=true -l observability.app=demo-private -l observability.metrics.port=8080 \
    busybox sh -c 'for i in 1 2 3 4 5 6 7 8 9 10; do echo "private-line-$i"; done; sleep 3600' >/dev/null
docker network connect vpstest-obs-priv2 vpstest-obs-private

loki() { graf "http://loki:3100/loki/api/v1/$1"; }
prom() { graf "http://prometheus:9090/api/v1/$1"; }

check "journaux reçus, labels app et deployment" wait_for 120 sh -c \
    "docker exec vpstest-obs-grafana wget -qO- 'http://loki:3100/loki/api/v1/query_range?query=%7Bapp%3D%22demo-laravel%22%2Cdeployment%3D%22staging%22%2Clevel%3D%22ERROR%22%7D&limit=1' | grep -q corr-123"
check_not "conteneur sans label ignoré" sh -c "docker exec vpstest-obs-grafana wget -qO- 'http://loki:3100/loki/api/v1/label/app/values' | grep -q secret-project"
check "conteneur privé : journaux reçus sans réseau partagé" wait_for 120 sh -c \
    "docker exec vpstest-obs-grafana wget -qO- 'http://loki:3100/loki/api/v1/query?query=sum(count_over_time(%7Bapp%3D%22demo-private%22%7D%5B15m%5D))' | grep -q '\"10\"\]'"
check "métriques scrapées avec labels" wait_for 120 sh -c \
    "docker exec vpstest-obs-grafana wget -qO- 'http://prometheus:9090/api/v1/query?query=demo_up%7Bapp%3D%22demo-laravel%22%2Cdeployment%3D%22staging%22%7D' | grep -q '\"1\"'"

check_not "conteneur privé jamais scrapé" sh -c \
    "docker exec vpstest-obs-grafana wget -qO- 'http://prometheus:9090/api/v1/query?query=up%7Bapp%3D%22demo-private%22%7D' | grep -q demo-private"

TID=5b8efff798038103d269b633813fc60c
NOW="$(date +%s)"
docker exec vpstest-obs-demo wget -qO- --header 'Content-Type: application/json' \
    --post-data "{\"resourceSpans\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"demo\"}}]},\"scopeSpans\":[{\"spans\":[{\"traceId\":\"${TID}\",\"spanId\":\"eee19b7ec3c1b174\",\"name\":\"GET /\",\"kind\":2,\"startTimeUnixNano\":\"${NOW}000000000\",\"endTimeUnixNano\":\"${NOW}500000000\"}]}]}]}" \
    http://vpstest-obs-alloy:4318/v1/traces >/dev/null
check "trace OTLP reçue par Tempo" wait_for 60 graf "http://tempo:3200/api/traces/${TID}"

step "Grafana"
search="$(graf "http://admin:vpstest-pass@localhost:3000/api/search?query=")"
check "dossier Core System" grep -q '"Core System"' <<< "${search}"
check "tableau Applications — journaux" grep -q 'Applications' <<< "${search}"
check "6 règles d'alerte provisionnées" test "$(graf "http://admin:vpstest-pass@localhost:3000/api/v1/provisioning/alert-rules" | grep -o '"uid"' | wc -l)" -ge 6

# Les fichiers de l'application pèsent jusqu'à 3,5 Mo (≈ 9 Mo au total) et
# nginx-proxy ne compresse pas (pas de « gzip on ») : Grafana doit le faire
# lui-même, sinon le chargement échoue sur une connexion lente
# (« Grafana has failed to load its application files »).
step "Compression des fichiers de Grafana"
asset="$(graf "http://localhost:3000/login" | grep -o 'public/build/runtime[^"]*\.js' | head -1)"
check "un fichier de l'application est référencé par la page de connexion" test -n "${asset}"
magic="$(docker exec vpstest-obs-grafana wget -qO- --header 'Accept-Encoding: gzip' "http://localhost:3000/${asset}" | head -c 2 | od -An -tx1 | tr -d ' \n')"
check "fichiers de Grafana servis compressés (en-tête gzip 1f8b)" test "${magic}" = "1f8b"

docker compose -p vpstest-obs -f "${INFRA_DIR}/observability/compose.yaml" down -v >/dev/null 2>&1 || true
