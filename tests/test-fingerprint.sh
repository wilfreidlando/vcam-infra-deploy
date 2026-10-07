#!/usr/bin/env bash
# bin/vps-fingerprint.sh : une copie fidèle donne des empreintes identiques, et la moindre différence (une ligne modifiée ou supprimée, un octet changé,
# un fichier manquant) est détectée, sur de VRAIES bases MariaDB et PostgreSQL et de vrais volumes. Sans la partie « détectée », le test ne prouverait rien.
# Isolé : conteneurs et volumes « vpstest-fp-* », tous supprimés à la fin.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
trap finish EXIT
require_docker
FP="${INFRA_DIR}/bin/vps-fingerprint.sh"
same() { diff -q "$1" "$2" >/dev/null; }
detecte() { same "$1" "$2" && ko "$3 : NON détecté" || ok "$3 : détecté"; }

step "MariaDB : une copie fidèle a la même empreinte"
start_maria() { docker run -d --name "$1" --tmpfs /var/lib/mysql -e MARIADB_ALLOW_EMPTY_ROOT_PASSWORD=1 -e MARIADB_DATABASE=ma_base mariadb:11.4 >/dev/null; }
# Les images officielles démarrent d'abord un serveur TEMPORAIRE d'initialisation (il répond déjà aux sondes), puis redémarrent : on attend la
# SECONDE annonce « prêt » dans les journaux, sinon la première requête tombe pendant le redémarrage.
deux_fois() { [[ "$(docker logs "$1" 2>&1 | grep -c "$2")" -ge 2 ]]; }
ready_maria() { wait_for 180 deux_fois "$1" "ready for connections" && wait_for 60 docker exec "$1" mariadb-admin ping -h 127.0.0.1 --silent; }
start_maria vpstest-fp-ms; start_maria vpstest-fp-mt; ready_maria vpstest-fp-ms; ready_maria vpstest-fp-mt
docker exec -i vpstest-fp-ms mariadb -uroot ma_base -e "
CREATE TABLE tenants (id INT PRIMARY KEY, slug VARCHAR(50), name VARCHAR(100)) DEFAULT CHARSET=utf8mb4;
INSERT INTO tenants VALUES (1,'alpha','Institut Panafricain'),(2,'beta','Éçôle d’été 日本');
CREATE TABLE etudiants (id INT PRIMARY KEY AUTO_INCREMENT, tenant_id INT, nom VARCHAR(100), photo BLOB) DEFAULT CHARSET=utf8mb4;
INSERT INTO etudiants (tenant_id, nom, photo) VALUES (1,'Ngo Bétina',0x89504E470D0A),(1,'O''Brien',NULL),(2,'Zoé',0xFF00FF);
CREATE TABLE gros (id INT PRIMARY KEY AUTO_INCREMENT, texte VARCHAR(200)) DEFAULT CHARSET=utf8mb4;
INSERT INTO gros (texte) SELECT REPEAT('x', 150) FROM seq_1_to_5000;"
docker exec vpstest-fp-ms mariadb-dump -uroot --single-transaction --hex-blob --databases ma_base | docker exec -i vpstest-fp-mt mariadb -uroot
"${FP}" db vpstest-fp-ms ma_base > "${WORK}/ms.txt"; "${FP}" db vpstest-fp-mt ma_base > "${WORK}/mt.txt"
check "3 tables relevées (une ligne chacune)" test "$(wc -l < "${WORK}/ms.txt")" -eq 3
check "nombre de lignes relevé (5000)" grep -q "^gros	5000	" "${WORK}/ms.txt"
check "source et copie : empreintes IDENTIQUES" same "${WORK}/ms.txt" "${WORK}/mt.txt"
check "la base est reprise du conteneur quand on ne la nomme pas" sh -c "'${FP}' db vpstest-fp-ms | diff -q - '${WORK}/ms.txt'"
docker exec vpstest-fp-mt mariadb -uroot ma_base -e "UPDATE etudiants SET nom='Zoe' WHERE id=3"
"${FP}" db vpstest-fp-mt ma_base > "${WORK}/mt2.txt"; detecte "${WORK}/ms.txt" "${WORK}/mt2.txt" "MariaDB : un caractère modifié (accent retiré)"
docker exec vpstest-fp-mt mariadb -uroot ma_base -e "UPDATE etudiants SET nom='Zoé' WHERE id=3; DELETE FROM gros WHERE id=1"
"${FP}" db vpstest-fp-mt ma_base > "${WORK}/mt3.txt"; detecte "${WORK}/ms.txt" "${WORK}/mt3.txt" "MariaDB : une ligne supprimée"

step "PostgreSQL : une copie fidèle a la même empreinte"
start_pg() { docker run -d --name "$1" --tmpfs /var/lib/postgresql -e POSTGRES_USER=fp -e POSTGRES_PASSWORD=fp-test -e POSTGRES_DB=ma_base postgres:18-alpine >/dev/null; }
ready_pg() { wait_for 180 deux_fois "$1" "database system is ready to accept connections" && wait_for 60 docker exec "$1" psql -U fp -d ma_base -c 'select 1'; }
start_pg vpstest-fp-ps; start_pg vpstest-fp-pt; ready_pg vpstest-fp-ps; ready_pg vpstest-fp-pt
docker exec -i vpstest-fp-ps psql -U fp -d ma_base -q <<'SQL'
CREATE TABLE tenants (id int PRIMARY KEY, slug text, name text);
INSERT INTO tenants VALUES (1,'alpha','Institut Panafricain'),(2,'beta','Éçôle d’été 日本');
CREATE SCHEMA compta;
CREATE TABLE compta.pieces (id serial PRIMARY KEY, nom text, contenu bytea, meta jsonb, montant numeric(12,2));
INSERT INTO compta.pieces (nom, contenu, meta, montant) VALUES ('Reçu Bétina','\x89504e470d0a','{"a":1,"b":[1,2]}',1500.50),('O''Brien',NULL,'{}',0),('Zoé','\xff00ff','{"é":"x"}',99999.99);
CREATE TABLE gros (id serial PRIMARY KEY, texte text);
INSERT INTO gros (texte) SELECT repeat('x',150) FROM generate_series(1,5000);
SQL
docker exec vpstest-fp-ps pg_dump -U fp -d ma_base --no-owner | docker exec -i vpstest-fp-pt psql -U fp -d ma_base -q >/dev/null
"${FP}" db vpstest-fp-ps ma_base > "${WORK}/ps.txt"; "${FP}" db vpstest-fp-pt ma_base > "${WORK}/pt.txt"
check "3 tables relevées, schéma « compta » compris" test "$(wc -l < "${WORK}/ps.txt")" -eq 3
check "nombre de lignes relevé (5000)" grep -q "^public.gros	5000	" "${WORK}/ps.txt"
check "source et copie : empreintes IDENTIQUES" same "${WORK}/ps.txt" "${WORK}/pt.txt"
check "la base est reprise du conteneur quand on ne la nomme pas" sh -c "'${FP}' db vpstest-fp-ps | diff -q - '${WORK}/ps.txt'"
docker exec vpstest-fp-pt psql -U fp -d ma_base -qc "UPDATE compta.pieces SET nom='Recu Betina' WHERE id=1"
"${FP}" db vpstest-fp-pt ma_base > "${WORK}/pt2.txt"; detecte "${WORK}/ps.txt" "${WORK}/pt2.txt" "PostgreSQL : un texte modifié"
docker exec vpstest-fp-pt psql -U fp -d ma_base -qc "UPDATE compta.pieces SET nom='Reçu Bétina' WHERE id=1; UPDATE compta.pieces SET montant=1500.51 WHERE id=1"
"${FP}" db vpstest-fp-pt ma_base > "${WORK}/pt3.txt"; detecte "${WORK}/ps.txt" "${WORK}/pt3.txt" "PostgreSQL : un montant modifié d'un centime"
docker exec vpstest-fp-pt psql -U fp -d ma_base -qc "UPDATE compta.pieces SET montant=1500.50 WHERE id=1; DELETE FROM gros WHERE id=1"
"${FP}" db vpstest-fp-pt ma_base > "${WORK}/pt4.txt"; detecte "${WORK}/ps.txt" "${WORK}/pt4.txt" "PostgreSQL : une ligne supprimée"

step "Fichiers : une copie fidèle a la même empreinte"
docker volume create vpstest-fp-vs >/dev/null; docker volume create vpstest-fp-vt >/dev/null
docker run --rm -v vpstest-fp-vs:/v busybox sh -c '
    mkdir -p "/v/public/docs/dossier 2026" /v/framework
    echo "contenu A" > "/v/public/docs/dossier 2026/reçu étudiant.txt"
    head -c 20000 /dev/urandom > /v/public/photo.bin
    echo "x" > /v/framework/.gitignore
    chown -R 33:33 /v; chmod 640 /v/public/photo.bin'
docker run --rm -v vpstest-fp-vs:/from:ro -v vpstest-fp-vt:/to busybox sh -c 'cp -a /from/. /to/'
"${FP}" files vpstest-fp-vs > "${WORK}/fs.txt"; "${FP}" files vpstest-fp-vt > "${WORK}/ft.txt"
check "3 fichiers relevés (espaces, accents, fichier caché)" test "$(wc -l < "${WORK}/fs.txt")" -eq 3
check "source et copie : empreintes IDENTIQUES" same "${WORK}/fs.txt" "${WORK}/ft.txt"
docker run --rm -v vpstest-fp-vt:/v busybox sh -c 'printf "Z" | dd of=/v/public/photo.bin bs=1 seek=100 conv=notrunc 2>/dev/null'
"${FP}" files vpstest-fp-vt > "${WORK}/ft2.txt"; detecte "${WORK}/fs.txt" "${WORK}/ft2.txt" "fichiers : un seul octet modifié"
docker run --rm -v vpstest-fp-vs:/from:ro -v vpstest-fp-vt:/to busybox sh -c 'cp -a /from/public/photo.bin /to/public/photo.bin; rm "/to/public/docs/dossier 2026/reçu étudiant.txt"'
"${FP}" files vpstest-fp-vt > "${WORK}/ft3.txt"; detecte "${WORK}/fs.txt" "${WORK}/ft3.txt" "fichiers : un fichier manquant"

step "Erreurs d'usage : jamais un résultat trompeur"
set +e
"${FP}" >/dev/null 2>&1; rc=$?;                                  [[ $rc -eq 2 ]] && ok "sans argument : usage (code 2)" || ko "sans argument (code ${rc})"
"${FP}" nimporte vpstest-fp-ms >/dev/null 2>&1; rc=$?;           [[ $rc -eq 2 ]] && ok "type inconnu refusé (code 2)" || ko "type inconnu (code ${rc})"
"${FP}" db vpstest-fp-ms "ma_base; DROP TABLE x" >/dev/null 2>&1; rc=$?;  [[ $rc -eq 2 ]] && ok "nom de base avec caractères dangereux refusé (code 2)" || ko "nom de base dangereux (code ${rc})"
docker run -d --name vpstest-fp-rien busybox sleep 300 >/dev/null
"${FP}" db vpstest-fp-rien >/dev/null 2>&1; rc=$?;                [[ $rc -eq 2 ]] && ok "conteneur sans moteur de base reconnu : refusé (code 2)" || ko "moteur inconnu (code ${rc})"
"${FP}" db vpstest-fp-introuvable ma_base >/dev/null 2>&1; rc=$?;  [[ $rc -ne 0 ]] && ok "conteneur introuvable : échec, pas une empreinte vide" || ko "conteneur introuvable accepté"
set -e
