#!/usr/bin/env bash
# Garde-fou de Claude Code pour les interventions sur le VPS (guide 13).
# Appelé avant chaque commande Bash (hook PreToolUse) ; reçoit la demande en
# JSON sur l'entrée standard. Code 2 = commande refusée, le message est
# renvoyé à Claude, qui doit l'expliquer à l'humain au lieu de contourner.
#
# Phase lue dans .claude/PHASE (absent = inventaire) :
#   inventaire   lecture seule sur le serveur
#   application  modifications permises (chacune reste soumise à l'accord de
#                l'humain), sauf la liste « jamais »
#
# Ce n'est pas un bac à sable : une commande déguisée peut passer. Il arrête
# les erreurs ; l'accord de l'humain sur chaque modification reste la
# vraie barrière.
set -uo pipefail

ALIAS="${VPS_SSH_ALIAS:-vps-contabo}"
cmd="$(jq -r '.tool_input.command // empty' 2>/dev/null)"
[[ -z "${cmd}" ]] && exit 0
# Seules les commandes qui parlent au serveur sont concernées.
grep -qE "(ssh|scp|rsync|sftp)[^|;&]*[[:space:]@]${ALIAS}([[:space:]:]|$)" <<< "${cmd}" || exit 0

phase="$(tr -d '[:space:]' < "${CLAUDE_PROJECT_DIR:-.}/.claude/PHASE" 2>/dev/null || true)"
phase="${phase:-inventaire}"

# Toujours interdit : perte de données, de l'accès au serveur, ou de tous les sites.
jamais='down[[:space:]].*-v|down -v|--volumes|volume[[:space:]]+(rm|prune)|system[[:space:]]+prune|image[[:space:]]+prune[[:space:]]+-a|rm[[:space:]]+-[a-zA-Z]*[rR][a-zA-Z]*[[:space:]]+/(app|etc|root|home|var/lib/docker|var/lib/vps-platform)?/?([^a-zA-Z0-9_./-]|$)|mkfs|dd[[:space:]]+if=|reboot|shutdown|poweroff|init[[:space:]]+[06]|ufw[[:space:]]+(disable|reset|delete)|iptables[[:space:]]+-(F|X|P)|passwd|authorized_keys|sshd_config|userdel|DROP[[:space:]]+(DATABASE|TABLE|SCHEMA)|TRUNCATE|systemctl[[:space:]]+(stop|disable|mask)[[:space:]]+(docker|ssh|sshd)'
if grep -qiE "${jamais}" <<< "${cmd}"; then
    echo "BLOQUÉ (toujours interdit, quelle que soit la phase) : ${cmd}" >&2
    echo "Ne pas contourner. Expliquer à l'humain pourquoi c'est nécessaire ; c'est lui qui le fera." >&2
    exit 2
fi

if [[ "${phase}" == inventaire ]]; then
    ecriture='docker[[:space:]]+(rm|rmi|kill|stop|start|restart|run|exec|create|pull|build|update|rename|cp|commit|tag|network[[:space:]]+(rm|connect|disconnect|create)|compose[[:space:]].*(up|down|rm|stop|start|restart|run|exec|pull|build|create))|deploy\.sh[[:space:]]+(watch|up|build|promote|rollback)|restore\.sh|git[[:space:]]+(-C[[:space:]]+[^[:space:]]+[[:space:]]+)?(pull|fetch|checkout|switch|reset|clean|remote[[:space:]]+set-url|clone|commit|push|stash|merge|rebase)|systemctl[[:space:]]+(stop|start|restart|reload|disable|enable)|service[[:space:]]+[^[:space:]]+[[:space:]]+(stop|start|restart)|crontab[[:space:]]+-(e|r)|crontab[[:space:]]+[^-l]|apt(-get)?[[:space:]]|snap[[:space:]]|pip[[:space:]]|npm[[:space:]]|(^|[[:space:];|&])(rm|mv|cp|ln|mkdir|rmdir|touch|chmod|chown|truncate|install)[[:space:]]|sed[[:space:]]+-i|tee[[:space:]]|>|kill[[:space:]]|scp[[:space:]]+[^[:space:]]+[[:space:]]+[^[:space:]]*'"${ALIAS}"':|rsync[[:space:]]'
    # « deploy.sh check » fait un git fetch (lecture) : autorisé, sous l'accord de l'humain.
    # Redirections sans effet sur un fichier (2>/dev/null, 2>&1) : retirées avant le contrôle.
    sans_null="$(sed -E 's#[0-9&]*>>?[[:space:]]*/dev/null##g; s#[0-9]*>&[0-9]##g' <<< "${cmd}")"
    if grep -qiE "${ecriture}" <<< "${sans_null}" && ! grep -qE 'deploy\.sh[[:space:]]+check' <<< "${cmd}"; then
        echo "BLOQUÉ (phase inventaire : lecture seule sur le serveur) : ${cmd}" >&2
        echo "Noter l'action dans le plan proposé à l'humain ; elle se fera en phase application." >&2
        echo "Pour garder une sortie : récupérer la sortie de la commande, puis l'écrire en local avec l'outil d'écriture de fichiers." >&2
        exit 2
    fi
fi
exit 0
