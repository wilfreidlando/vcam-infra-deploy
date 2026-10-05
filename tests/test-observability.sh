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
# Observabilité PROPRE À UN PROJET : déposée par `deploy.sh obs-sync` dans l'arbre de Grafana du dépôt (ignoré par git), puis retirée.
obs_cleanup() { (cd "${WORK}/projet-obs" 2>/dev/null && STATE_DIR="${WORK}/state" "${INFRA_DIR}/bin/deploy.sh" obs-sync --remove >/dev/null 2>&1) || true; }
trap 'obs_cleanup; finish' EXIT
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

step "Observabilité d'un projet, publiée par le projet lui-même (avant le démarrage de Grafana)"
mkdir -p "${WORK}/projet-obs/observability/dashboards" "${WORK}/projet-obs/observability/alerts" "${WORK}/state"
printf 'APP_NAME=probe-app\nCOMPOSE_FILE=compose.yaml\n' > "${WORK}/projet-obs/platform.env"
printf '{"uid":"probe-app-vue","title":"Vue du projet de test","panels":[]}\n' > "${WORK}/projet-obs/observability/dashboards/vue.json"
cat > "${WORK}/projet-obs/observability/alerts/regles.yaml" <<'YAML'
apiVersion: 1
groups:
  - orgId: 1
    name: probe-app
    folder: probe-app
    interval: 1m
    rules:
      - uid: probe-app-r1
        title: Règle du projet de test
        condition: C
        for: 5m
        noDataState: OK
        execErrState: OK
        annotations:
          summary: "Le projet de test dit : {{ .Labels.instance }}"
        data:
          - refId: A
            datasourceUid: prometheus
            relativeTimeRange: { from: 300, to: 0 }
            model: { refId: A, expr: 'min(up)', instant: true }
          - refId: C
            datasourceUid: __expr__
            model: { refId: C, type: threshold, expression: A, conditions: [{ evaluator: { type: lt, params: [1] } }] }
YAML
check "deploy.sh obs-sync publie le bundle du projet" sh -c "cd '${WORK}/projet-obs' && STATE_DIR='${WORK}/state' '${INFRA_DIR}/bin/deploy.sh' obs-sync >/dev/null 2>&1"
check "le tableau est dans le dossier Grafana du projet (dans l'arbre ignoré par git)" test -f "${INFRA_DIR}/observability/grafana/projets/dashboards/probe-app/vue.json"
check "les fichiers déposés sont ignorés par git : le dépôt de la plateforme n'est PAS modifié" sh -c "cd '${INFRA_DIR}' && git check-ignore -q observability/grafana/projets/dashboards/probe-app/vue.json && git check-ignore -q observability/grafana/provisioning/alerting/projet-probe-app-regles.yaml"

step "Démarrage de la stack"
check "stack démarrée" docker compose -p vpstest-obs -f "${INFRA_DIR}/observability/compose.yaml" up -d

graf() { docker exec vpstest-obs-grafana wget -qO- "$@"; }
check "Grafana répond" wait_for 120 graf "http://admin:vpstest-pass@localhost:3000/api/health"

step "Projets observés"
# Le projet est sur DEUX réseaux et le réseau partagé n'est PAS le premier par ordre alphabétique (cas réel : nginx-proxy,
# observability, <projet>-internal). Alloy ne retient par défaut que le premier réseau : sans match_first_network = false, la
# cible de métriques disparaît (incident constaté sur le serveur au premier déploiement du pilote).
docker network create vpstest-a-first >/dev/null
docker run -d --name vpstest-obs-demo --network vpstest-a-first \
    -l observability.enable=true -l observability.app=demo-laravel -l observability.deployment=staging \
    -l observability.metrics.port=8080 -l com.docker.compose.service=app \
    busybox sh -c 'mkdir -p /www && printf "# TYPE demo_up gauge\ndemo_up 1\n" > /www/metrics && httpd -p 8080 -h /www && while true; do echo "{\"message\":\"hello\",\"level_name\":\"ERROR\",\"extra\":{\"correlation_id\":\"corr-123\"}}"; echo "{\"level\":\"warn\",\"msg\":\"caddy-line-xyz\"}"; sleep 2; done' >/dev/null
docker network connect "${OBS_NETWORK}" vpstest-obs-demo
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
# Caddy et FrankenPHP écrivent « level » en minuscules (« warn »), Laravel « level_name » en majuscules : un seul label « level »,
# écrit comme les tableaux et les alertes l'attendent (« WARNING »).
check "niveau « warn » de Caddy devenu le label level=WARNING" wait_for 120 sh -c \
    "docker exec vpstest-obs-grafana wget -qO- 'http://loki:3100/loki/api/v1/query_range?query=%7Bapp%3D%22demo-laravel%22%2Clevel%3D%22WARNING%22%7D&limit=1' | grep -q caddy-line-xyz"
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

step "Le serveur lui-même (node-exporter)"
# La plateforme observe le serveur sans qu'aucun projet n'ait rien à faire : processeur, mémoire, swap,
# disque, charge. Les alertes génériques et le tableau « Serveur » s'appuient sur ces séries.
check "node-exporter démarré" docker ps --filter name=vpstest-obs-node-exporter --filter status=running -q
for serie in node_load5 node_memory_MemAvailable_bytes node_cpu_seconds_total; do
    check "série ${serie} dans Prometheus" wait_for 120 sh -c "docker exec vpstest-obs-grafana wget -qO- 'http://prometheus:9090/api/v1/query?query=${serie}' | grep -q '\"value\"'"
done
check "disque « / » mesuré (les alertes et le tableau le cherchent)" wait_for 60 sh -c "docker exec vpstest-obs-grafana wget -qO- 'http://prometheus:9090/api/v1/query?query=node_filesystem_size_bytes%7Bmountpoint%3D%22%2F%22%7D' | grep -q '\"value\"'"
check "node-exporter est un job scruté et en bonne santé" wait_for 60 sh -c "docker exec vpstest-obs-grafana wget -qO- 'http://prometheus:9090/api/v1/query?query=up%7Bjob%3D%22node%22%7D' | grep -q '\"1\"\]'"

step "Les conteneurs (cAdvisor) et les sondes de sites (blackbox)"
# cAdvisor : consommation et redémarrages de chaque conteneur Docker, sans que le projet fasse rien.
check "cAdvisor démarré" docker ps --filter name=vpstest-obs-cadvisor --filter status=running -q
check "blackbox-exporter démarré" docker ps --filter name=vpstest-obs-blackbox-exporter --filter status=running -q
for serie in container_memory_working_set_bytes container_start_time_seconds container_cpu_usage_seconds_total; do
    check "série ${serie} dans Prometheus (cAdvisor)" wait_for 240 sh -c "docker exec vpstest-obs-grafana wget -qO- 'http://prometheus:9090/api/v1/query?query=${serie}%7Bname%21%3D%22%22%7D' | grep -q '\"value\"'"
done
check "cAdvisor est un job scruté et en bonne santé" wait_for 120 sh -c "docker exec vpstest-obs-grafana wget -qO- 'http://prometheus:9090/api/v1/query?query=up%7Bjob%3D%22cadvisor%22%7D' | grep -q '\"1\"\]'"
# Chaque conteneur est rattaché à son application : cAdvisor ne garde que observability.app et observability.deployment, que Prometheus
# renomme en app et deployment, comme pour les journaux. C'est ce qui permet UN tableau « Application » pour tous les projets.
check "les séries de cAdvisor portent les étiquettes app et deployment du conteneur" wait_for 240 sh -c "docker exec vpstest-obs-grafana wget -qO- 'http://prometheus:9090/api/v1/query?query=container_memory_working_set_bytes%7Bapp%3D%22demo-laravel%22%2Cdeployment%3D%22staging%22%7D' | grep -q '\"value\"'"
check_not "aucune étiquette brute container_label_* ne subsiste (cardinalité)" sh -c "docker exec vpstest-obs-grafana wget -qO- 'http://prometheus:9090/api/v1/query?query=container_memory_working_set_bytes%7Bcontainer_label_observability_app%3D~%22.%2B%22%7D' | grep -q '\"value\"'"
# Sonde : le blackbox-exporter sait sonder une adresse et la déclarer en ligne.
check "une sonde HTTP réussit (probe_success 1)" wait_for 60 sh -c "docker exec vpstest-obs-grafana wget -qO- 'http://blackbox-exporter:9115/probe?target=http://prometheus:9090/-/healthy&module=http_2xx' | grep -q '^probe_success 1'"
check_not "une sonde vers une adresse morte échoue (probe_success 0)" sh -c "docker exec vpstest-obs-grafana wget -qO- 'http://blackbox-exporter:9115/probe?target=http://loki:1/&module=http_2xx' | grep -q '^probe_success 1'"

step "Aucun « No data » : chaque requête des tableaux et des alertes du serveur renvoie des données"
# Incident du 2026-10-05 : « Charge par processeur » affichait « No data » (et l'alerte de charge ne pouvait jamais sonner) parce que
# l'expression divisait une série étiquetée par un nombre sans étiquette. Le test vérifiait que les règles étaient CHARGÉES, jamais
# qu'elles RENVOIENT quelque chose. Toute requête de ces fichiers doit donner au moins une série sur la pile de test.
cat > "${WORK}/exprs.py" <<'PY'
import json, sys, glob, subprocess, urllib.parse, yaml
base = sys.argv[1]
rows = []
for f in ["Plateforme/serveur.json", "Plateforme/conteneurs.json", "Plateforme/application.json"]:
    d = json.load(open(f"{base}/grafana/dashboards/{f}"))
    for p in d["panels"]:
        if (p.get("datasource") or {}).get("uid") == "loki":
            continue   # les panneaux de journaux (LogQL) ne s'interrogent pas dans Prometheus
        for t in p.get("targets", []):
            if t.get("expr"):
                rows.append((f, p.get("title", "?"), t["expr"].replace("$__rate_interval", "5m").replace("$__interval", "5m").replace("$app", "demo-laravel").replace("$deployment", ".+")))
y = yaml.safe_load(open(f"{base}/grafana/provisioning/alerting/generic-alerts.yaml"))
for g in y["groups"]:
    for r in g["rules"]:
        for dd in r["data"]:
            if dd.get("model", {}).get("expr"):
                rows.append(("alerte", r["title"], dd["model"]["expr"]))
# Légitimement vides tant qu'aucun conteneur ne redémarre : on le dit ici, avec la raison.
# Les panneaux « par application » qui dépendent d'une SONDE de site restent vides tant que le site n'est pas dans sites.yml (absent du banc d'essai).
OK_EMPTY = ("Redémarrages sur 24 h", "Conteneurs en boucle", "Site en ligne", "Certificat HTTPS", "Disponibilité", "Temps de réponse")
bad = []
for src, title, q in rows:
    if title.startswith(OK_EMPTY):
        continue
    if "container_spec_memory_limit_bytes" in q:
        continue   # la « limite » n'existe que pour un conteneur qui en a une : vide pour le conteneur de démonstration, légitimement
    url = "http://prometheus:9090/api/v1/query?query=" + urllib.parse.quote(q)
    out = subprocess.run(["docker", "exec", "vpstest-obs-grafana", "wget", "-qO-", url], capture_output=True, text=True).stdout
    try:
        res = json.loads(out)["data"]["result"]
    except Exception:
        res = None
    if not res:
        bad.append(f"{src} | {title}")
print("\n".join(bad))
sys.exit(1 if bad else 0)
PY
check "chaque requête des tableaux Serveur, Conteneurs, Application et des alertes du serveur renvoie des données" \
    wait_for 240 python3 "${WORK}/exprs.py" "${INFRA_DIR}/observability"
python3 "${WORK}/exprs.py" "${INFRA_DIR}/observability" >&2 || true   # en cas d'échec, le journal nomme les requêtes vides

step "Grafana"
search="$(graf "http://admin:vpstest-pass@localhost:3000/api/search?query=")"
check_not "plus aucun tableau du Core dans la plateforme (il les livre dans son dépôt)" grep -q '"Core System"' <<< "${search}"
check "tableau Applications — journaux" grep -q 'Applications' <<< "${search}"
check "dossier Plateforme et tableau Serveur provisionnés" grep -q 'Serveur' <<< "${search}"
check "tableau Conteneurs provisionné" grep -q 'Conteneurs' <<< "${search}"
check "tableau Sites (disponibilité) provisionné" grep -q 'Sites' <<< "${search}"
check "tableau « Application — vue d'ensemble » provisionné" grep -q "Application — vue" <<< "${search}"
check "le dossier du projet (probe-app) existe dans Grafana" grep -q 'probe-app' <<< "${search}"
check "le tableau publié par le projet y est" grep -q 'Vue du projet de test' <<< "${search}"
check "11 règles d'alerte provisionnées (5 du serveur, 5 conteneurs, sites et sauvegardes, 1 publiée par le projet de test)" test "$(graf "http://admin:vpstest-pass@localhost:3000/api/v1/provisioning/alert-rules" | grep -o '"uid"' | wc -l)" -ge 11
check "le point de contact core-oncall vient de notifications.yaml (plateforme)" grep -q core-oncall <<< "$(graf "http://admin:vpstest-pass@localhost:3000/api/v1/provisioning/contact-points")"
check "la politique de notification l'applique à toutes les alertes" grep -q core-oncall <<< "$(graf "http://admin:vpstest-pass@localhost:3000/api/v1/provisioning/policies")"
# Incident du 2026-10-05 : « {{ $$labels.name }} » chargeait sans erreur mais ne s'évaluait pas (« bad character U+0024 »), 585 erreurs en quelques minutes
# sur le serveur. Charger une règle ne prouve pas que son message s'évalue : on attend la première évaluation, puis on cherche l'erreur.
check "les règles de conteneurs ont été évaluées par Grafana" wait_for 240 sh -c \
    "docker exec vpstest-obs-grafana wget -qO- 'http://admin:vpstest-pass@localhost:3000/api/prometheus/grafana/api/v1/rules' | python3 -c 'import sys,json; d=json.load(sys.stdin); ok=[r for g in d[\"data\"][\"groups\"] for r in g[\"rules\"] if r[\"name\"].startswith(\"Un conteneur red\") and not r[\"lastEvaluation\"].startswith(\"0001\")]; sys.exit(0 if ok else 1)'"
check_not "aucun message d'alerte ne signale « Error in expanding template »" sh -c "docker logs vpstest-obs-grafana 2>&1 | grep -q 'Error in expanding template'"

# Les fichiers de l'application pèsent jusqu'à 3,5 Mo (≈ 9 Mo au total) et
# nginx-proxy ne compresse pas (pas de « gzip on ») : Grafana doit le faire
# lui-même, sinon le chargement échoue sur une connexion lente
# (« Grafana has failed to load its application files »).
step "Compression des fichiers de Grafana"
asset="$(graf "http://localhost:3000/login" | grep -o 'public/build/runtime[^"]*\.js' | head -1)"
check "un fichier de l'application est référencé par la page de connexion" test -n "${asset}"
# « head -c 2 » ferme le tube : wget reçoit SIGPIPE, et sous « set -e -o pipefail » cela avorterait le test.
magic="$(docker exec vpstest-obs-grafana wget -qO- --header 'Accept-Encoding: gzip' "http://localhost:3000/${asset}" | head -c 2 | od -An -tx1 | tr -d ' \n' || true)"
check "fichiers de Grafana servis compressés (en-tête gzip 1f8b)" test "${magic}" = "1f8b"

docker compose -p vpstest-obs -f "${INFRA_DIR}/observability/compose.yaml" down -v >/dev/null 2>&1 || true
