#!/usr/bin/env bash
# Host-name inventory of the VPS (infra/README.md § Sous-domaines) — READ-ONLY.
#
# nginx-proxy routes by the VIRTUAL_HOST variable of each container. Two
# containers of different projects declaring the same name are NOT an
# error for nginx-proxy: it load-balances between them, silently sending
# visitors to the wrong application. This script makes every claimed name
# visible and refuses collisions.
#
#   vps-hosts.sh                         inventory: name → project, container, state, certificate
#   vps-hosts.sh --csv                   same, CSV (to keep as a register)
#   vps-hosts.sh --ct <domain>           + names that ever had a public certificate
#                                        (Certificate Transparency, crt.sh) but no container
#                                        here — forgotten or hosted elsewhere
#   vps-hosts.sh --free <name>           is this name available? (exit 1 if taken)
#   vps-hosts.sh --check <names> --project <compose project>
#                                        exit 1 if a name (comma-separated) is already
#                                        claimed by ANOTHER project — used by deploy.sh
#
# Sources: every container, running OR stopped (a stopped container
# reclaims its names when restarted), and the certificates nginx-proxy holds.
set -euo pipefail

NGINX_PROXY_CONTAINER="${NGINX_PROXY_CONTAINER:-nginx-proxy}"

# One line per claimed name: name|project|container|state|variable
claims() {
    local id name project state env
    while read -r id; do
        IFS='|' read -r name project state < <(docker inspect --format \
            '{{.Name}}|{{index .Config.Labels "com.docker.compose.project"}}|{{.State.Status}}' "${id}")
        name="${name#/}"
        [[ "${project}" == "<no value>" || -z "${project}" ]] && project="(hors compose:${name})"
        # Only the two routing variables are read — never other environment values.
        env="$(docker inspect --format '{{range .Config.Env}}{{println .}}{{end}}' "${id}" | grep -E '^(VIRTUAL_HOST|LETSENCRYPT_HOST)=' || true)"
        while IFS='=' read -r var value; do
            [[ -z "${var}" ]] && continue
            tr ',' '\n' <<< "${value}" | while read -r host; do
                host="$(tr -d ' ' <<< "${host}" | tr '[:upper:]' '[:lower:]')"
                [[ -n "${host}" ]] && echo "${host}|${project}|${name}|${state}|${var}"
            done
        done <<< "${env}"
    done < <(docker ps -aq)
}

certificates() {
    docker exec "${NGINX_PROXY_CONTAINER}" sh -c 'ls /etc/nginx/certs/*.crt 2>/dev/null' 2>/dev/null \
        | sed 's#.*/##; s#\.crt$##' | grep -vE '^(default|dhparam)$' || true
}

# A name is "taken" by a project when one of its containers declares it in VIRTUAL_HOST.
routing_claims() { claims | awk -F'|' '$5 == "VIRTUAL_HOST"'; }

cmd_inventory() {
    local csv="${1:-0}" all certs
    all="$(routing_claims | sort -u)"
    certs="$(certificates)"

    if [[ "${csv}" == 1 ]]; then
        echo "nom,projet,conteneur,etat,certificat"
        while IFS='|' read -r host project container state _; do
            [[ -z "${host}" ]] && continue
            cert=non; grep -qx "${host}" <<< "${certs}" && cert=oui
            echo "${host},${project},${container},${state},${cert}"
        done <<< "${all}"
        return 0
    fi

    printf '%-48s %-28s %-34s %-10s %s\n' "NOM" "PROJET" "CONTENEUR" "ÉTAT" "CERTIFICAT"
    while IFS='|' read -r host project container state _; do
        [[ -z "${host}" ]] && continue
        cert="—"; grep -qx "${host#\*.}" <<< "${certs}" && cert="oui"
        printf '%-48s %-28s %-34s %-10s %s\n' "${host}" "${project:0:28}" "${container:0:34}" "${state}" "${cert}"
    done <<< "${all}"

    echo
    echo "Noms déclarés : $(cut -d'|' -f1 <<< "${all}" | sort -u | grep -c . || true) · conteneurs : $(cut -d'|' -f3 <<< "${all}" | sort -u | grep -c . || true)"

    local dups
    dups="$(cut -d'|' -f1,2 <<< "${all}" | sort -u | cut -d'|' -f1 | sort | uniq -d)"
    if [[ -n "${dups}" ]]; then
        echo
        echo "COLLISIONS — même nom revendiqué par plusieurs projets (nginx-proxy répartit le trafic entre eux) :"
        while read -r host; do
            echo "  ${host}"
            grep "^${host}|" <<< "${all}" | awk -F'|' '{printf "      %-28s %-34s %s\n", $2, $3, $4}'
        done <<< "${dups}"
    else
        echo "Aucune collision."
    fi

    local stopped
    stopped="$(awk -F'|' '$4 != "running"' <<< "${all}")"
    if [[ -n "${stopped}" ]]; then
        echo
        echo "Noms tenus par des conteneurs ARRÊTÉS (ils reprendront ces noms s'ils redémarrent) :"
        awk -F'|' '{printf "  %-48s %-28s %s\n", $1, $2, $3}' <<< "${stopped}"
    fi

    local orphan_certs
    orphan_certs="$(comm -23 <(sort -u <<< "${certs}") <(cut -d'|' -f1 <<< "${all}" | sed 's/^\*\.//' | sort -u) | grep . || true)"
    if [[ -n "${orphan_certs}" ]]; then
        echo
        echo "Certificats sans conteneur actuel (anciens sites — noms à considérer comme pris) :"
        awk '{print "  " $0}' <<< "${orphan_certs}"
    fi
}

cmd_ct() {
    local domain="$1" here
    command -v curl >/dev/null || { echo "curl requis" >&2; exit 2; }
    here="$(routing_claims | cut -d'|' -f1 | sort -u)"
    echo
    echo "Certificate Transparency (crt.sh) — noms de ${domain} ayant déjà eu un certificat public :"
    local json
    if ! json="$(curl -fsS --max-time 90 "https://crt.sh/?q=%25.${domain}&output=json")"; then
        echo "  crt.sh injoignable ou surchargé — réessayer plus tard, ou ouvrir https://crt.sh/?q=%25.${domain} dans un navigateur" >&2
        return 1
    fi
    printf '%s' "${json}" \
        | grep -o '"name_value":"[^"]*"' | cut -d'"' -f4 | sed 's/\\n/\n/g' | tr '[:upper:]' '[:lower:]' | sort -u \
        | while read -r host; do
            if grep -qx "${host}" <<< "${here}"; then status="sur ce VPS"; else status="ABSENT d'ici (ancien, ou hébergé ailleurs ?)"; fi
            printf '  %-48s %s\n' "${host}" "${status}"
        done
}

# exit 1 when a name is claimed by another project — exactly, or through a
# wildcard (*.saas.example.com) of another project: an explicit name always
# wins in nginx-proxy, so it would silently steal that SaaS's sub-domain.
cmd_check() {
    local names="$1" project="$2" taken=0 host owner wild all
    all="$(routing_claims)"
    while read -r host; do
        host="$(tr -d ' ' <<< "${host}" | tr '[:upper:]' '[:lower:]')"
        [[ -z "${host}" ]] && continue
        owner="$(awk -F'|' -v h="${host}" -v p="${project}" '$1 == h && $2 != p {print $2 " (" $3 ", " $4 ")"}' <<< "${all}" | sort -u)"
        if [[ -n "${owner}" ]]; then
            echo "COLLISION : ${host} est déjà revendiqué par ${owner//$'\n'/, }" >&2
            taken=1
        fi
        wild="$(awk -F'|' -v h="${host}" -v p="${project}" '
            $2 != p && substr($1, 1, 2) == "*." {
                suffix = substr($1, 2)
                if (length(h) > length(suffix) && substr(h, length(h) - length(suffix) + 1) == suffix) print $1 " de " $2
            }' <<< "${all}" | sort -u)"
        if [[ -n "${wild}" ]]; then
            echo "COLLISION : ${host} est couvert par le wildcard ${wild//$'\n'/, } — le déclarer ici volerait ce sous-domaine à ce SaaS" >&2
            taken=1
        fi
    done < <(tr ',' '\n' <<< "${names}")
    return "${taken}"
}

# Names that hold a certificate in nginx-proxy but no container: probably an
# old site. Not blocking for deploy.sh (it may be this project's own), but
# --free reports it.
cert_only() {
    local host="$1"
    certificates | grep -qx "${host}" && ! routing_claims | cut -d'|' -f1 | grep -qx "${host}"
}

case "${1:-}" in
    "") cmd_inventory 0 ;;
    --csv) cmd_inventory 1 ;;
    --ct) cmd_inventory 0; cmd_ct "${2:?--ct <domaine>}" ;;
    --free)
        name="$(tr '[:upper:]' '[:lower:]' <<< "${2:?--free <nom>}")"
        if ! cmd_check "${name}" "__none__" 2>/dev/null; then
            echo "PRIS : ${name}"; cmd_check "${name}" "__none__" || true; exit 1
        elif cert_only "${name}"; then
            echo "PRIS (probablement) : ${name} a un certificat dans nginx-proxy mais aucun conteneur — ancien site ? vérifier avant de le réutiliser"; exit 1
        else
            echo "libre : ${name}"
        fi
        ;;
    --check)
        [[ "${3:-}" == "--project" ]] || { echo "usage: --check <noms> --project <projet compose>" >&2; exit 2; }
        cmd_check "${2}" "${4:?}"
        ;;
    *) sed -n '2,24p' "$0"; exit 2 ;;
esac
