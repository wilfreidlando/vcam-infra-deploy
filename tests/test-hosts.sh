#!/usr/bin/env bash
# Host-name inventory and collision guard (bin/vps-hosts.sh), on
# simulated projects: duplicate name across projects, case differences,
# stopped container still holding a name, orphan certificate, SaaS wildcard.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
trap finish EXIT
require_docker

HOSTS="${INFRA_DIR}/bin/vps-hosts.sh"
export NGINX_PROXY_CONTAINER=vpstest-np
docker network create vpstest-np >/dev/null

step "Routage nginx-proxy 1.7 d'un SaaS à sous-domaines (VIRTUAL_HOST wildcard)"
docker run -d --name vpstest-np --network vpstest-np -v /var/run/docker.sock:/tmp/docker.sock:ro nginxproxy/nginx-proxy:1.7 >/dev/null
docker run -d --name vpstest-saas --network vpstest-np --label com.docker.compose.project=vpstest-saas-prod \
    -e 'VIRTUAL_HOST=saas.vpstest.test,*.saas.vpstest.test' -e VIRTUAL_PORT=8080 \
    busybox sh -c 'mkdir /www && echo saas-app > /www/index.html && httpd -f -p 8080 -h /www' >/dev/null
docker run -d --name vpstest-site --network vpstest-np --label com.docker.compose.project=vpstest-site-prod \
    -e VIRTUAL_HOST=site.vpstest.test -e VIRTUAL_PORT=8080 \
    busybox sh -c 'mkdir /www && echo autre-site > /www/index.html && httpd -f -p 8080 -h /www' >/dev/null
via_proxy() { docker run --rm --network vpstest-np curlimages/curl:8.11.1 -s -H "Host: $1" http://vpstest-np/; }
routes_to() { via_proxy "$1" | grep -q "$2"; }
check "client1.saas.vpstest.test → SaaS" wait_for 30 routes_to client1.saas.vpstest.test saas-app
check "nouveau-client.saas.vpstest.test → SaaS, sans reconfiguration" routes_to nouveau-client.saas.vpstest.test saas-app
check "saas.vpstest.test (apex) → SaaS" routes_to saas.vpstest.test saas-app
check "site.vpstest.test → l'autre site, intact" routes_to site.vpstest.test autre-site
check "nom inconnu → 503" routes_to inconnu.vpstest.test 503

step "Collisions"
docker exec vpstest-np sh -c 'touch /etc/nginx/certs/ancien-site.vpstest.test.crt'
docker run -d --name vpstest-blog --label com.docker.compose.project=vpstest-blog-prod -e VIRTUAL_HOST=blog.vpstest.test busybox sleep 600 >/dev/null
docker run -d --name vpstest-blog2 --label com.docker.compose.project=vpstest-nouveau-prod -e VIRTUAL_HOST=Blog.vpstest.test,shop.vpstest.test busybox sleep 600 >/dev/null
docker create --name vpstest-crm --label com.docker.compose.project=vpstest-crm -e VIRTUAL_HOST=crm.vpstest.test busybox >/dev/null
ok "collision de casse (blog/Blog), conteneur arrêté, certificat orphelin"
sleep 3
check_not "constat réel : nginx-proxy génère une configuration invalide (duplicate upstream)" docker exec vpstest-np nginx -t
docker run -d --name vpstest-new --network vpstest-np -e VIRTUAL_HOST=new.vpstest.test -e VIRTUAL_PORT=8080 \
    busybox sh -c 'mkdir /www && echo new > /www/index.html && httpd -f -p 8080 -h /www' >/dev/null
sleep 5
check "…et un nouveau site n'est plus pris en compte (503) tant que la collision existe" routes_to new.vpstest.test 503
check "…les sites existants continuent (ancienne configuration)" routes_to site.vpstest.test autre-site
check "l'audit le signale en CRITIQUE" sh -c "'${INFRA_DIR}/bin/vps-audit.sh' | grep -q 'CRITIQUE.*vpstest-np.*configuration refusée.*duplicate upstream'"

step "Inventaire"
inventory="$("${HOSTS}")"
section_has() { grep -A3 "$1" <<< "${inventory}" | grep -q "$2"; }
check "collision blog détectée malgré la casse (Blog/blog)" section_has COLLISIONS blog.vpstest.test
check "nom tenu par un conteneur arrêté signalé" section_has 'ARRÊTÉS' crm.vpstest.test
check "certificat orphelin signalé" section_has 'Certificats sans conteneur' ancien-site.vpstest.test
check "export CSV" sh -c "'${HOSTS}' --csv | head -1 | grep -q '^nom,projet,conteneur,etat,certificat$'"

step "Disponibilité d'un nom"
check "nom libre" "${HOSTS}" --free libre.vpstest.test
check_not "nom tenu par un conteneur arrêté : pris" "${HOSTS}" --free crm.vpstest.test
check_not "nom couvert par le wildcard d'un SaaS : pris" "${HOSTS}" --free client42.saas.vpstest.test
check_not "nom avec un ancien certificat : pris" "${HOSTS}" --free ancien-site.vpstest.test

step "Garde de déploiement (--check)"
check "le SaaS peut redéployer ses propres noms" "${HOSTS}" --check saas.vpstest.test,client1.saas.vpstest.test --project vpstest-saas-prod
check_not "un autre projet ne peut pas prendre shop" "${HOSTS}" --check shop.vpstest.test --project vpstest-autre
check_not "un autre projet ne peut pas voler un sous-domaine du SaaS" "${HOSTS}" --check client1.saas.vpstest.test --project vpstest-autre

step "Audit et réparation"
check "collision remontée en CRITIQUE par vps-audit.sh" sh -c "'${INFRA_DIR}/bin/vps-audit.sh' | grep -A2 '(sous-domaines)' | grep -q 'CRITIQUE.*blog.vpstest.test'"
docker rm -f vpstest-blog2 >/dev/null
sleep 5
check "collision retirée : nginx-proxy accepte à nouveau sa configuration" docker exec vpstest-np nginx -t
check "…et le nouveau site est enfin servi" wait_for 20 routes_to new.vpstest.test new
