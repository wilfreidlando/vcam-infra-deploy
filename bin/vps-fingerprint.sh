#!/usr/bin/env bash
# Empreintes pour PROUVER qu'une copie est exacte (bascule d'une installation, réplique, restauration) : on calcule l'empreinte de la
# source, celle de la copie, et on compare avec `diff`. Une seule différence = la copie n'est pas fidèle. Ne modifie RIEN.
#
#   vps-fingerprint db <conteneur-db> [base]        une ligne par table : nom, nombre de lignes, somme de contrôle du contenu
#                                                    (MariaDB, MySQL ou PostgreSQL : détecté dans le conteneur)
#   vps-fingerprint files <volume-docker>           une ligne par fichier : sha256 et chemin relatif (volume monté en lecture seule)
#
# Exemple (source figée, puis copie, à comparer) :
#   vps-fingerprint db ancien-db ma_base            > source.db.txt
#   vps-fingerprint db nouveau-db ma_base           > copie.db.txt
#   diff source.db.txt copie.db.txt && echo "base identique"
#
# Les identifiants viennent des variables du conteneur (MARIADB_*/MYSQL_*, POSTGRES_*) : jamais affichés, jamais passés en argument.
# La somme de contrôle d'une table MariaDB/MySQL est CHECKSUM TABLE ; celle d'une table PostgreSQL est le md5 des lignes (texte) triées.
# À faire sur une source FIGÉE (plus aucune écriture), sinon deux calculs successifs peuvent légitimement différer.
set -euo pipefail

KIND="${1:-}"; TARGET="${2:-}"; DB="${3:-}"
usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2; }
[[ -n "${KIND}" && -n "${TARGET}" ]] || { usage; exit 2; }

case "${KIND}" in
    db)
        [[ "${DB}" =~ ^[A-Za-z0-9_]*$ ]] || { echo "nom de base invalide : lettres, chiffres et « _ » seulement" >&2; exit 2; }
        engine="$(docker exec "${TARGET}" sh -c 'if command -v psql >/dev/null 2>&1; then echo postgres; elif command -v mariadb >/dev/null 2>&1 || command -v mysql >/dev/null 2>&1; then echo mysql; fi')"
        # Le script s'exécute DANS le conteneur, lu sur son entrée standard (pas de guillemets imbriqués) ; la base passe par la variable FP_DB.
        case "${engine}" in
            postgres)
                docker exec -i -e FP_DB="${DB}" "${TARGET}" sh -s <<'INNER'
export PGPASSWORD="${POSTGRES_PASSWORD:-}"
u="${POSTGRES_USER:-postgres}"; db="${FP_DB:-}"; [ -n "$db" ] || db="${POSTGRES_DB:-$u}"
q() { psql -U "$u" -d "$db" -At -F "$(printf '\t')" "$@"; }
for t in $(q -c "SELECT quote_ident(schemaname) || '.' || quote_ident(tablename) FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema') ORDER BY 1"); do
    rows=$(q -c "SELECT count(*) FROM $t")
    sum=$(q -c "SELECT md5(COALESCE(string_agg(md5(x::text), '' ORDER BY md5(x::text)), '-')) FROM $t x")
    printf '%s\t%s\t%s\n' "$t" "$rows" "$sum"
done
INNER
                ;;
            mysql)
                docker exec -i -e FP_DB="${DB}" "${TARGET}" sh -s <<'INNER'
pw="${MARIADB_ROOT_PASSWORD:-${MYSQL_ROOT_PASSWORD:-}}"
db="${FP_DB:-}"; [ -n "$db" ] || db="${MARIADB_DATABASE:-${MYSQL_DATABASE:-}}"
[ -n "$db" ] || { echo "base inconnue : la passer en 3e argument" >&2; exit 2; }
cli=mariadb; command -v mariadb >/dev/null 2>&1 || cli=mysql
# Mot de passe par la variable MYSQL_PWD (jamais en argument) ; vide accepté pour une base d'essai.
q() { MYSQL_PWD="$pw" "$cli" -uroot -N -B "$@"; }
for t in $(q -e "SELECT table_name FROM information_schema.tables WHERE table_schema='$db' AND table_type='BASE TABLE' ORDER BY 1"); do
    rows=$(q -e "SELECT COUNT(*) FROM \`$db\`.\`$t\`")
    sum=$(q -e "CHECKSUM TABLE \`$db\`.\`$t\`" | cut -f2)
    printf '%s\t%s\t%s\n' "$t" "$rows" "$sum"
done
INNER
                ;;
            *) echo "moteur de base non reconnu dans le conteneur « ${TARGET} » (ni psql, ni mariadb, ni mysql)" >&2; exit 2 ;;
        esac
        ;;
    files)
        docker run --rm -v "${TARGET}:/v:ro" busybox sh -c 'cd /v && find . -type f | sort | while read -r f; do sha256sum "$f"; done'
        ;;
    *) echo "type inconnu « ${KIND} » (db | files)" >&2; usage; exit 2 ;;
esac
