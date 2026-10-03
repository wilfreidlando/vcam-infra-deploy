#!/usr/bin/env bash
# VPS standard compliance audit (README.md) — READ-ONLY.
#
# Inspects every container on the host and the Docker daemon settings, and
# reports what breaks the hosting standard, by severity:
#
#   CRITIQUE  exposes something to the Internet or another project
#   ATTENTION will hurt eventually (disk full, OOM of the whole VPS, no restart)
#   INFO      good practice missing
#
# Changes nothing, restarts nothing, never prints environment values.
#
#   vps-audit.sh            full report
#   vps-audit.sh --strict   exit 1 if any CRITIQUE finding
set -euo pipefail

strict=0
[[ "${1:-}" == "--strict" ]] && strict=1

crit=0; warn=0; info=0
declare -A per_project

report() {
    local sev="$1" project="$2" container="$3" msg="$4"
    case "${sev}" in
        CRITIQUE) crit=$((crit + 1)) ;;
        ATTENTION) warn=$((warn + 1)) ;;
        INFO) info=$((info + 1)) ;;
    esac
    per_project["${project}"]+="$(printf '  %-9s %-34s %s' "${sev}" "${container}" "${msg}")"$'\n'
}

DB_IMAGES='(^|/)(postgres|postgis|mysql|mariadb|mongo|redis|valkey|memcached|elasticsearch|opensearch|rabbitmq)(:|$)'
PLATFORM_CONTAINERS='^(nginx-proxy|nginx-proxy-acme|observability-.*)$'

# ── Daemon ──────────────────────────────────────────────────────────────
daemon_json=/etc/docker/daemon.json
log_driver="$(docker info --format '{{.LoggingDriver}}' 2>/dev/null || echo unknown)"
default_max_size=""
live_restore="$(docker info --format '{{.LiveRestoreEnabled}}' 2>/dev/null || echo false)"
if [[ -r "${daemon_json}" ]] && grep -q '"max-size"' "${daemon_json}"; then
    default_max_size="set"
fi
if [[ "${log_driver}" == "json-file" && -z "${default_max_size}" ]]; then
    report ATTENTION "(hôte)" "dockerd" "journaux json-file sans rotation par défaut — le disque se remplit (host/daemon.json)"
fi
[[ "${live_restore}" == "true" ]] || report INFO "(hôte)" "dockerd" "live-restore désactivé — un redémarrage de Docker coupe tous les sites"

# ── Disk ────────────────────────────────────────────────────────────────
docker_root="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || echo /var/lib/docker)"
for mount in / "${docker_root}"; do
    usage="$(df -P "${mount}" 2>/dev/null | awk 'NR==2 {gsub("%","",$5); print $5}')"
    if [[ -n "${usage}" && "${usage}" -ge 85 ]]; then
        report CRITIQUE "(hôte)" "disque ${mount}" "${usage} % utilisé"
    elif [[ -n "${usage}" && "${usage}" -ge 70 ]]; then
        report ATTENTION "(hôte)" "disque ${mount}" "${usage} % utilisé"
    fi
done
reclaimable="$(docker system df --format '{{.Type}}: {{.Reclaimable}}' 2>/dev/null | tr '\n' ' ' || true)"

# ── Containers ──────────────────────────────────────────────────────────
# shellcheck disable=SC2016 # Go template, not shell expansion
fmt='{{.Name}}|{{index .Config.Labels "com.docker.compose.project"}}|{{.Config.Image}}|{{.HostConfig.RestartPolicy.Name}}|{{.HostConfig.Memory}}|{{if index .Config "Healthcheck"}}yes{{else}}no{{end}}|{{with index .State "Health"}}{{.Status}}{{end}}|{{.State.Status}}|{{.RestartCount}}|{{.HostConfig.Privileged}}|{{.HostConfig.LogConfig.Type}}|{{index .HostConfig.LogConfig.Config "max-size"}}|{{range $p, $b := .NetworkSettings.Ports}}{{range $b}}{{.HostIp}}:{{.HostPort}}->{{$p}} {{end}}{{end}}|{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}|{{range .Mounts}}{{if eq .Source "/var/run/docker.sock"}}{{if .RW}}rw{{else}}ro{{end}}{{end}}{{end}}|{{index .Config.Labels "observability.enable"}}'

mapfile -t ids < <(docker ps -aq)
for id in "${ids[@]}"; do
    line="$(docker inspect --format "${fmt}" "${id}")"
    IFS='|' read -r name project image restart memory hc health state restarts privileged logtype maxsize ports networks sock observed <<< "${line}"
    name="${name#/}"
    [[ "${project}" == "<no value>" ]] && project=""
    [[ "${observed}" == "<no value>" ]] && observed=""
    [[ "${maxsize}" == "<no value>" ]] && maxsize=""
    project="${project:-(hors compose)}"

    # Environment is read only to test the presence of two variable NAMES.
    envnames="$(docker inspect --format '{{range .Config.Env}}{{.}}{{"\n"}}{{end}}' "${id}" | cut -d= -f1)"

    is_db=0; [[ "${image}" =~ ${DB_IMAGES} ]] && is_db=1
    is_platform=0; [[ "${name}" =~ ${PLATFORM_CONTAINERS} ]] && is_platform=1

    # Published ports: Docker writes its own iptables rules, BEFORE ufw —
    # a port published on 0.0.0.0 is reachable from the Internet even if
    # the firewall says otherwise.
    for p in ${ports}; do
        hostip="${p%%:*}"
        if [[ "${hostip}" == "0.0.0.0" || "${hostip}" == "::" || "${hostip}" == "" ]]; then
            if [[ "${is_platform}" == 1 && "${p}" =~ :(80|443)- ]]; then continue; fi
            if [[ "${is_db}" == 1 ]]; then
                report CRITIQUE "${project}" "${name}" "base de données publiée sur Internet (${p}) — retirer « ports: » ou lier à 127.0.0.1"
            else
                report CRITIQUE "${project}" "${name}" "port publié sur Internet (${p}), contourne ufw — passer par nginx-proxy ou lier à 127.0.0.1"
            fi
        fi
    done

    if [[ "${is_db}" == 1 && " ${networks} " == *" nginx-proxy "* ]]; then
        report CRITIQUE "${project}" "${name}" "base/cache sur le réseau partagé nginx-proxy — joignable par tous les projets"
    fi
    if [[ "${is_db}" == 1 && " ${networks} " == *" observability "* ]]; then
        report CRITIQUE "${project}" "${name}" "base/cache sur le réseau partagé observability"
    fi

    [[ "${sock}" == "rw" ]] && report CRITIQUE "${project}" "${name}" "socket Docker monté en écriture = root sur le VPS"
    [[ "${sock}" == "ro" && "${is_platform}" != 1 ]] && report ATTENTION "${project}" "${name}" "socket Docker monté (lecture) — accès à tous les conteneurs et à leurs secrets"
    [[ "${privileged}" == "true" ]] && report CRITIQUE "${project}" "${name}" "conteneur --privileged"

    [[ "${restart}" == "no" || -z "${restart}" ]] && [[ "${state}" == "running" ]] && \
        report ATTENTION "${project}" "${name}" "pas de politique de redémarrage — ne revient pas après un reboot"
    [[ "${memory}" == "0" ]] && report ATTENTION "${project}" "${name}" "aucune limite mémoire — peut faire tomber tout le VPS"
    if [[ "${logtype}" == "json-file" && -z "${maxsize}" && -z "${default_max_size}" ]]; then
        report ATTENTION "${project}" "${name}" "journaux sans rotation (max-size)"
    fi

    [[ "${state}" == "restarting" ]] && report CRITIQUE "${project}" "${name}" "redémarre en boucle (${restarts} redémarrages)"
    [[ "${health}" == "unhealthy" ]] && report CRITIQUE "${project}" "${name}" "healthcheck en échec"
    [[ "${state}" == "exited" && "${restart}" != "no" && -n "${restart}" ]] && report ATTENTION "${project}" "${name}" "arrêté alors qu'il devrait tourner"
    [[ "${state}" == "exited" && ( "${restart}" == "no" || -z "${restart}" ) ]] && report INFO "${project}" "${name}" "conteneur arrêté — à supprimer s'il ne sert plus"

    if grep -qx VIRTUAL_HOST <<< "${envnames}"; then
        if [[ " ${networks} " == *" ${NGINX_PROXY_NETWORK:-nginx-proxy} "* ]]; then
            grep -qx LETSENCRYPT_HOST <<< "${envnames}" || report ATTENTION "${project}" "${name}" "VIRTUAL_HOST sans LETSENCRYPT_HOST — site servi sans HTTPS valide"
        elif [[ "${state}" == "running" ]]; then
            report ATTENTION "${project}" "${name}" "VIRTUAL_HOST hérité (env_file ?) sur un conteneur non exposé — risque de collision de casse ; le réserver au conteneur web"
        fi
    fi

    [[ "${hc}" == "no" && "${state}" == "running" ]] && report INFO "${project}" "${name}" "pas de healthcheck"
    [[ "${image}" == *":latest" || "${image}" != *":"* ]] && report INFO "${project}" "${name}" "image « latest » — version non traçable, retour arrière impossible"
    [[ "${is_db}" != 1 && "${is_platform}" != 1 && "${observed}" != "true" && "${state}" == "running" ]] && \
        report INFO "${project}" "${name}" "non branché sur l'observabilité (labels observability.*)"
done

# ── nginx-proxy configuration (read-only `nginx -t`) ─────────────────────
# A broken generated config (e.g. the same name declared twice with a
# different case → "duplicate upstream") makes every reload fail: no new
# site and no change is applied on the whole VPS until it is fixed.
proxy="${NGINX_PROXY_CONTAINER:-nginx-proxy}"
if docker container inspect "${proxy}" >/dev/null 2>&1; then
    if ! proxy_test="$(docker exec "${proxy}" nginx -t 2>&1)"; then
        report CRITIQUE "(hôte)" "${proxy}" "configuration refusée — plus aucun changement de site n'est appliqué : $(grep -m1 emerg <<< "${proxy_test}" | sed 's/.*\[emerg\] [0-9#]*: //')"
    fi
fi

# ── Host-name collisions (bin/vps-hosts.sh) ────────────────────────
hosts_script="$(dirname "${BASH_SOURCE[0]}")/vps-hosts.sh"
if [[ -x "${hosts_script}" ]]; then
    while read -r host; do
        [[ -z "${host}" ]] && continue
        owners="$("${hosts_script}" --csv | awk -F, -v h="${host}" '$1 == h {print $2}' | sort -u | paste -sd' ' -)"
        report CRITIQUE "(sous-domaines)" "${host}" "revendiqué par plusieurs projets (${owners}) — nginx-proxy répartit le trafic entre eux"
    done < <("${hosts_script}" --csv | tail -n +2 | cut -d, -f1,2 | sort -u | cut -d, -f1 | sort | uniq -d)
fi

# ── Report ──────────────────────────────────────────────────────────────
echo "Audit du VPS — $(hostname) — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "Conteneurs : ${#ids[@]} · Docker : $(docker version --format '{{.Server.Version}}' 2>/dev/null || echo '?')"
[[ -n "${reclaimable}" ]] && echo "Espace récupérable : ${reclaimable}"
echo
while IFS= read -r project; do
    [[ -z "${project}" ]] && continue
    echo "■ ${project}"
    printf '%s' "${per_project["${project}"]}" | sort -k1,1 -s
    echo
done < <(printf '%s\n' "${!per_project[@]}" | sort)
echo "Résumé : ${crit} CRITIQUE · ${warn} ATTENTION · ${info} INFO"
echo "Corrections : README.md, section « Corriger un projet existant »."

if [[ "${strict}" == 1 && "${crit}" -gt 0 ]]; then
    exit 1
fi
