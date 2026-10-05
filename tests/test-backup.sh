#!/usr/bin/env bash
# Backup agent (images/db-backup), against REAL servers:
# PostgreSQL 18, MySQL 8.4, MariaDB 10.7 and 11.4 (the versions running on the VPS, 10.7 being the
# most common) and an S3-compatible store
# (SeaweedFS, standing in for MEGA S4). For each engine: backup → file is
# encrypted → uploaded → retention deletes only expired backups → data
# destroyed → restored from S3 → data back; a wrong passphrase is refused.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
trap finish EXIT
require_docker

NET=vpstest-backup
S3=http://vpstest-s3:8333
docker network create "${NET}" >/dev/null

step "Images"
check "image PostgreSQL construite (images officielles uniquement)" \
    docker build -q -t vpstest-db-backup:pg "${INFRA_DIR}/images/db-backup"
check "image MySQL/MariaDB construite" \
    docker build -q --build-arg BASE=mariadb:11.4 -t vpstest-db-backup:mysql "${INFRA_DIR}/images/db-backup"

step "Serveurs"
docker run -d --name vpstest-s3 --network "${NET}" chrislusf/seaweedfs server -s3 -dir=/data >/dev/null
docker run -d --name vpstest-pg --network "${NET}" -e POSTGRES_USER=app -e POSTGRES_PASSWORD=pgpass -e POSTGRES_DB=app postgres:18-alpine >/dev/null
docker run -d --name vpstest-mysql --network "${NET}" -e MYSQL_ROOT_PASSWORD=root -e MYSQL_DATABASE=app -e MYSQL_USER=app -e MYSQL_PASSWORD=mypass mysql:8.4 >/dev/null
docker run -d --name vpstest-mariadb107 --network "${NET}" -e MARIADB_ROOT_PASSWORD=root -e MARIADB_DATABASE=app -e MARIADB_USER=app -e MARIADB_PASSWORD=mypass mariadb:10.7 >/dev/null
docker run -d --name vpstest-mariadb114 --network "${NET}" -e MARIADB_ROOT_PASSWORD=root -e MARIADB_DATABASE=app -e MARIADB_USER=app -e MARIADB_PASSWORD=mypass mariadb:11.4 >/dev/null

aws() { docker run --rm --network "${NET}" -e AWS_ACCESS_KEY_ID=k -e AWS_SECRET_ACCESS_KEY=s -e AWS_DEFAULT_REGION=us-east-1 amazon/aws-cli:2.37.9 --endpoint-url "${S3}" "$@"; }

check "PostgreSQL prêt" wait_for 90 docker exec vpstest-pg pg_isready -U app -d app
check "MySQL 8.4 prêt" wait_for 180 docker exec vpstest-mysql mysql -uapp -pmypass app -e "select 1"
check "MariaDB 10.7 prêt" wait_for 120 docker exec vpstest-mariadb107 mariadb -uapp -pmypass app -e "select 1"
check "MariaDB 11.4 prêt" wait_for 120 docker exec vpstest-mariadb114 mariadb -uapp -pmypass app -e "select 1"
check "stockage S3 prêt" wait_for 90 aws s3 mb s3://vps-backups

cat > "${WORK}/backup.env" <<ENV
BACKUP_PASSPHRASE=une phrase de passe longue et secrète
BACKUP_S3_ENDPOINT=${S3}
BACKUP_S3_BUCKET=vps-backups
BACKUP_S3_PREFIX=backups
AWS_ACCESS_KEY_ID=k
AWS_SECRET_ACCESS_KEY=s
AWS_DEFAULT_REGION=us-east-1
BACKUP_RETENTION_DAYS=30
BACKUP_LOCAL_KEEP=2
ENV

pg_sql() { docker exec vpstest-pg psql -U app -d app -tAc "$1"; }
my_sql() { docker exec "$1" sh -c "MYSQL_PWD=mypass \$(command -v mariadb || command -v mysql) -uapp app -N -e \"$2\""; }

run_agent() {  # run_agent <image> <name> <engine env…> -- <cmd…>
    local image="$1" name="$2"; shift 2
    local envs=()
    while [[ "$1" != "--" ]]; do envs+=(-e "$1"); shift; done
    shift
    docker run --rm --network "${NET}" --env-file "${WORK}/backup.env" -e "BACKUP_NAME=${name}" \
        "${envs[@]}" -v "vpstest-${name}:/backups" "${image}" "$@"
}

test_engine() {  # test_engine <label> <image> <name> <ENGINE env…>
    local label="$1" image="$2" name="$3"; shift 3
    local engine_env=("$@")

    step "${label} — sauvegarde"
    # An expired remote backup (by its name) and an unrelated file.
    aws s3 cp --quiet - "s3://vps-backups/backups/${name}/${name}-20200101T000000Z-scheduled.dump.enc" <<< old >/dev/null
    aws s3 cp --quiet - "s3://vps-backups/backups/${name}/notes.txt" <<< keep >/dev/null

    check "backup.sh réussit" run_agent "${image}" "${name}" "${engine_env[@]}" -- backup.sh
    local listing; listing="$(aws s3 ls "s3://vps-backups/backups/${name}/" || true)"
    check "copie envoyée sur S3" grep -q "${name}-.*-scheduled.dump.enc" <<< "${listing}"
    check_not "sauvegarde expirée supprimée" grep -q "20200101T000000Z" <<< "${listing}"
    check "fichier étranger conservé" grep -q "notes.txt" <<< "${listing}"
    check_not "contenu chiffré (aucune donnée en clair)" \
        run_agent "${image}" "${name}" "${engine_env[@]}" -- sh -c 'grep -a "commande-secrete" /backups/*.enc'

    for _ in 1 2; do run_agent "${image}" "${name}" "${engine_env[@]}" -- backup.sh >/dev/null 2>&1 || true; sleep 1; done
    check "rotation locale (BACKUP_LOCAL_KEEP=2)" \
        test "$(run_agent "${image}" "${name}" "${engine_env[@]}" -- sh -c 'ls /backups/*.enc | wc -l' | tr -d ' ')" = 2

    step "${label} — restauration"
    local key; key="$(aws s3 ls "s3://vps-backups/backups/${name}/" | awk '{print $4}' | grep scheduled | sort | tail -1 || true)"
    check_not "mauvaise phrase de passe refusée" \
        run_agent "${image}" "${name}" "${engine_env[@]}" BACKUP_PASSPHRASE=mauvaise -- restore.sh "s3://vps-backups/backups/${name}/${key}"
    check "restauration depuis S3" \
        run_agent "${image}" "${name}" "${engine_env[@]}" -- restore.sh "s3://vps-backups/backups/${name}/${key}"
}

# ── PostgreSQL ──────────────────────────────────────────────────────────
pg_sql "create table orders(id int primary key, label text); insert into orders values (1, 'commande-secrete é'), (2, 'deux');" >/dev/null
PG_ENV=(BACKUP_ENGINE=postgres PGHOST=vpstest-pg PGDATABASE=app PGUSER=app PGPASSWORD=pgpass)
test_engine "PostgreSQL 18" vpstest-db-backup:pg pgapp "${PG_ENV[@]}"
# data was overwritten in between? restore must bring back the original rows
pg_sql "delete from orders; insert into orders values (99, 'après la sauvegarde'); create table creee_apres_la_sauvegarde(id int); create view vue_creee_apres as select 1 as x;" >/dev/null
key="$(aws s3 ls s3://vps-backups/backups/pgapp/ | awk '{print $4}' | grep scheduled | sort | tail -1 || true)"
objets_apres() { pg_sql "select count(*) from information_schema.tables where table_name in ('creee_apres_la_sauvegarde','vue_creee_apres')"; }
run_agent vpstest-db-backup:pg pgapp "${PG_ENV[@]}" -- restore.sh "s3://vps-backups/backups/pgapp/${key}" >/dev/null 2>&1
check "PostgreSQL : données d'origine restaurées (accents compris)" test "$(pg_sql "select string_agg(label, '|' order by id) from orders")" = "commande-secrete é|deux"
# Une restauration REMPLACE la base (exercice de restauration du 2026-10-04) : pg_restore --clean ne supprime
# que ce que la sauvegarde contient ; une table créée par une migration ratée survivait et faisait échouer la suivante.
check "PostgreSQL : table et vue créées après la sauvegarde ont disparu (état exact de la sauvegarde)" test "$(objets_apres)" = 0
# RESTORE_MODE=merge : ancien comportement, toujours disponible.
pg_sql "create table creee_apres_la_sauvegarde(id int);" >/dev/null
run_agent vpstest-db-backup:pg pgapp "${PG_ENV[@]}" RESTORE_MODE=merge -- restore.sh "s3://vps-backups/backups/pgapp/${key}" >/dev/null 2>&1
check "PostgreSQL, RESTORE_MODE=merge : l'objet créé après la sauvegarde est conservé" test "$(objets_apres)" = 1
# Un refus ne coûte aucune donnée : la base n'est touchée qu'après déchiffrement et lecture de l'archive.
check_not "PostgreSQL : mauvaise phrase de passe refusée" \
    run_agent vpstest-db-backup:pg pgapp "${PG_ENV[@]}" BACKUP_PASSPHRASE=mauvaise -- restore.sh "s3://vps-backups/backups/pgapp/${key}"
check "PostgreSQL : base intacte après une restauration refusée" test "$(objets_apres)" = 1
check_not "PostgreSQL : RESTORE_MODE invalide refusé" \
    run_agent vpstest-db-backup:pg pgapp "${PG_ENV[@]}" RESTORE_MODE=nimporte -- restore.sh "s3://vps-backups/backups/pgapp/${key}"
pg_sql "drop table creee_apres_la_sauvegarde" >/dev/null

# ── MySQL 8.4, MariaDB 10.7 and MariaDB 11.4 ────────────────────────────
for server in mysql mariadb107 mariadb114; do
    my_sql "vpstest-${server}" "create table orders(id int primary key, label varchar(50)); insert into orders values (1, 'commande-secrete é'), (2, 'deux');"
    MY_ENV=(BACKUP_ENGINE=mysql "MYSQL_HOST=vpstest-${server}" MYSQL_DATABASE=app MYSQL_USER=app MYSQL_PASSWORD=mypass)
    test_engine "${server}" vpstest-db-backup:mysql "${server}app" "${MY_ENV[@]}"
    my_sql "vpstest-${server}" "delete from orders; insert into orders values (99, 'après'); create table creee_apres (id int); create view vue_apres as select 1 as x; create procedure p_apres() select 1; create event e_apres on schedule every 1 day do select 1;"
    key="$(aws s3 ls "s3://vps-backups/backups/${server}app/" | awk '{print $4}' | grep scheduled | sort | tail -1 || true)"
    uri="s3://vps-backups/backups/${server}app/${key}"
    # Table, vue, procédure ou événement créés APRÈS la sauvegarde (une migration, un test).
    apres() { my_sql "vpstest-${server}" "select (select count(*) from information_schema.tables where table_schema=database() and table_name in ('creee_apres','vue_apres')) + (select count(*) from information_schema.routines where routine_schema=database() and routine_name='p_apres') + (select count(*) from information_schema.events where event_schema=database() and event_name='e_apres')"; }
    check "${server} : objets créés après la sauvegarde présents avant la restauration" test "$(apres)" = 4
    run_agent vpstest-db-backup:mysql "${server}app" "${MY_ENV[@]}" -- restore.sh "${uri}" >/dev/null 2>&1
    check "${server} : données d'origine restaurées (accents compris)" \
        test "$(my_sql "vpstest-${server}" "select group_concat(label order by id separator '|') from orders")" = "commande-secrete é|deux"
    # Même promesse que PostgreSQL : la base revient à l'état exact de la sauvegarde.
    check "${server} : table, vue, procédure et événement créés après la sauvegarde ont disparu" test "$(apres)" = 0
    # Mode merge : ancien comportement, les objets créés depuis restent.
    my_sql "vpstest-${server}" "create table creee_apres (id int);"
    run_agent vpstest-db-backup:mysql "${server}app" "${MY_ENV[@]}" RESTORE_MODE=merge -- restore.sh "${uri}" >/dev/null 2>&1
    check "${server}, RESTORE_MODE=merge : la table créée après la sauvegarde est conservée" test "$(apres)" = 1
    # Les refus ne coûtent aucune donnée : la base n'est touchée qu'après déchiffrement et vérification du dump.
    check_not "${server} : mauvaise phrase de passe refusée" \
        run_agent vpstest-db-backup:mysql "${server}app" "${MY_ENV[@]}" BACKUP_PASSPHRASE=mauvaise -- restore.sh "${uri}"
    check "${server} : base intacte après une restauration refusée" test "$(apres)" = 1
    check_not "${server} : dump incomplet (sans « Dump completed ») refusé" \
        run_agent vpstest-db-backup:mysql "${server}app" "${MY_ENV[@]}" -- sh -c 'printf "CREATE TABLE x (i int);\n" | gzip | openssl enc -aes-256-cbc -pbkdf2 -iter 600000 -salt -pass env:BACKUP_PASSPHRASE -out /backups/incomplet.dump.enc && restore.sh incomplet.dump.enc'
    check "${server} : base intacte après un dump incomplet refusé" test "$(apres)" = 1
    my_sql "vpstest-${server}" "drop table creee_apres;"
done

step "Planificateur"
check "l'agent démarre en mode planifié et annonce l'heure" sh -c \
    "docker run -d --name vpstest-sched -e BACKUP_TIME=03:15 -e BACKUP_NAME=x vpstest-db-backup:pg >/dev/null && sleep 3 && docker logs vpstest-sched 2>&1 | grep -q 'daily backup at 03:15 UTC'"
docker rmi -f vpstest-db-backup:pg vpstest-db-backup:mysql >/dev/null 2>&1 || true
