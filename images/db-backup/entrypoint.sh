#!/bin/bash
# `schedule` (default): runs backup.sh every day at BACKUP_TIME (UTC, HH:MM).
# Anything else is executed as is (backup.sh, restore.sh, sh…).
set -eu

if [ "${1:-schedule}" != "schedule" ]; then
    exec "$@"
fi

: "${BACKUP_TIME:=02:30}"
echo "db-backup: daily backup at ${BACKUP_TIME} UTC (${BACKUP_NAME:-app}, ${BACKUP_ENGINE:-postgres})"

while true; do
    now="$(date -u +%s)"
    next="$(date -u -d "today ${BACKUP_TIME}" +%s)"
    [ "${next}" -le "${now}" ] && next="$(date -u -d "tomorrow ${BACKUP_TIME}" +%s)"
    sleep "$((next - now))"
    # A failed backup is logged (and visible in Grafana) but never stops the agent.
    backup.sh || echo "db-backup: BACKUP FAILED at $(date -u +%Y-%m-%dT%H:%M:%SZ)" >&2
done
