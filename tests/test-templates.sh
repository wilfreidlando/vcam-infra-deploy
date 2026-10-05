#!/usr/bin/env bash
# templates/ : chaque modèle de projet est DÉPLOYABLE et applique les règles du contrat.
# Pour chaque modèle (Laravel PostgreSQL, Laravel MySQL/MariaDB, back end web générique, front SPA), on le copie dans un projet factice avec ses
# fichiers d'environnement d'exemple (production ET staging) et on lance le contrôle avant déploiement de la plateforme (`deploy.sh check`), puis
# on vérifie, sur le compose rendu par Docker, les règles que le modèle promet : aucun port publié, un seul service sur nginx-proxy (le web, avec
# VIRTUAL_HOST), base et cache privés, redémarrage, limite mémoire et rotation des journaux partout, image taguée par commit.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
trap finish EXIT
require_docker

DEPLOY="${INFRA_DIR}/bin/deploy.sh"
TPL="${INFRA_DIR}/templates"
export STATE_DIR="${WORK}/state"

# make_project <nom> <compose> <platform.env> <lignes d'env supplémentaires>  → ${WORK}/<nom> prêt pour deploy.sh
make_project() {
    local name="$1" compose="$2" pe="$3" extra="$4" d="${WORK}/$1"
    mkdir -p "${d}"
    cp "${compose}" "${d}/compose.prod.yaml"
    cp "${pe}" "${d}/platform.env"
    { cat "${TPL}/env.platform.production.example"; printf '%s\n' "${extra}"; } > "${d}/.env"
    { cat "${TPL}/env.platform.staging.example"; printf '%s\n' "${extra}"; } > "${d}/.env.staging"
}

# Règles du contrat lues sur le compose RENDU (après fusion des ancres), pas sur le texte du fichier.
rules() {  # rules <projet> <web> <db|-> <redis|->
    local d="${WORK}/$1"
    (cd "${d}" && IMAGE_TAG=test DEPLOYMENT=prod ENV_FILE=.env docker compose -p "tpl-$1" -f compose.prod.yaml --env-file .env config --format json 2>/dev/null) \
        | python3 -c '
import json, sys
d = json.load(sys.stdin); web, db, redis = sys.argv[1:4]
svc = d["services"]; bad = []
for n, s in svc.items():
    if s.get("ports"): bad.append(f"{n}: ports publiés")
    if s.get("restart") != "unless-stopped": bad.append(f"{n}: pas de restart: unless-stopped")
    if not (s.get("deploy", {}).get("resources", {}).get("limits", {}).get("memory")): bad.append(f"{n}: pas de limite mémoire")
    if not (s.get("logging", {}).get("options", {}).get("max-size")): bad.append(f"{n}: pas de rotation des journaux")
    img = s.get("image", "")
    # Agent de sauvegarde (vps/db-backup:1) = image de la PLATEFORME, etiquette fixe par construction ; celles du projet suivent le commit.
    if s.get("build") and not img.startswith("vps/") and not img.endswith(":test"): bad.append(f"{n}: image non taguée par commit ({img})")
public = [n for n, s in svc.items() if "nginx-proxy" in (s.get("networks") or {})]
if public != [web]: bad.append(f"services sur nginx-proxy : {public} (attendu seulement {web})")
env = svc[web].get("environment", {})
if not env.get("VIRTUAL_HOST"): bad.append(f"{web}: pas de VIRTUAL_HOST")
for n in (db, redis):
    if n != "-" and "nginx-proxy" in (svc[n].get("networks") or {}): bad.append(f"{n}: sur le réseau public nginx-proxy")
for n, s in svc.items():
    if n != web and (s.get("environment") or {}).get("VIRTUAL_HOST"): bad.append(f"{n}: déclare VIRTUAL_HOST (seul le web le doit)")
if db != "-" and not svc[db].get("healthcheck"): bad.append(f"{db}: pas de contrôle de santé")
print("\n".join(bad)); sys.exit(1 if bad else 0)' "$2" "$3" "$4"
}

DB='DB_DATABASE=app
DB_USERNAME=app
DB_PASSWORD=pw'

step "Laravel avec PostgreSQL"
make_project laravel "${TPL}/compose.laravel.yaml" "${TPL}/platform.env" "${DB}"
check "deploy.sh check prod passe" sh -c "cd '${WORK}/laravel' && '${DEPLOY}' check prod >/dev/null 2>&1"
check "deploy.sh check staging passe" sh -c "cd '${WORK}/laravel' && '${DEPLOY}' check staging >/dev/null 2>&1"
check "les règles du contrat sont appliquées (compose rendu)" rules laravel mon-saas-web mon-saas-db mon-saas-redis
check "l'agent de sauvegarde est PostgreSQL (BACKUP_ENGINE=postgres, variables PG*)" \
    grep -q 'BACKUP_ENGINE: postgres' "${WORK}/laravel/compose.prod.yaml"

step "Laravel avec MySQL ou MariaDB"
make_project laravel-mysql "${TPL}/compose.laravel-mysql.yaml" "${TPL}/platform.env" "${DB}"
check "deploy.sh check prod passe" sh -c "cd '${WORK}/laravel-mysql' && '${DEPLOY}' check prod >/dev/null 2>&1"
check "deploy.sh check staging passe" sh -c "cd '${WORK}/laravel-mysql' && '${DEPLOY}' check staging >/dev/null 2>&1"
check "les règles du contrat sont appliquées (compose rendu)" rules laravel-mysql mon-saas-web mon-saas-db mon-saas-redis
check "l'agent de sauvegarde est MySQL/MariaDB (BACKUP_ENGINE=mysql, variables MYSQL_*)" \
    sh -c "grep -q 'BACKUP_ENGINE: mysql' '${WORK}/laravel-mysql/compose.prod.yaml' && grep -q 'MYSQL_HOST: mon-saas-db' '${WORK}/laravel-mysql/compose.prod.yaml'"
check_not "aucune trace de PostgreSQL dans la variante MySQL" grep -q -i -E 'PGHOST|pg_isready|postgres:' "${WORK}/laravel-mysql/compose.prod.yaml"
check "le contrôle de santé de la base passe par le réseau (127.0.0.1), pas par le socket" grep -q 'ping -h 127.0.0.1' "${WORK}/laravel-mysql/compose.prod.yaml"

step "Back end web générique (Node, Python, Go…)"
sed -e 's/mon-saas/mon-site/g' -e '/^BACKUP_SERVICE=/d' -e '/^DB_SERVICE=/d' -e '/^MIGRATE_SERVICE=/d' -e '/^MIGRATE_CMD=/d' "${TPL}/platform.env" > "${WORK}/web.platform.env"
make_project web "${TPL}/compose.web.yaml" "${WORK}/web.platform.env" ""
check "deploy.sh check prod passe" sh -c "cd '${WORK}/web' && '${DEPLOY}' check prod >/dev/null 2>&1"
check "deploy.sh check staging passe" sh -c "cd '${WORK}/web' && '${DEPLOY}' check staging >/dev/null 2>&1"
check "les règles du contrat sont appliquées (compose rendu)" rules web mon-site-web - -

step "Front SPA (React, Angular, Vue)"
make_project front "${TPL}/frontend/compose.frontend.yaml" "${TPL}/frontend/platform.env" "PUBLIC_API_URL=https://api.example.test"
check "deploy.sh check prod passe" sh -c "cd '${WORK}/front' && '${DEPLOY}' check prod >/dev/null 2>&1"
check "deploy.sh check staging passe" sh -c "cd '${WORK}/front' && '${DEPLOY}' check staging >/dev/null 2>&1"
check "les règles du contrat sont appliquées (compose rendu)" rules front mon-front-web - -
check "le Dockerfile de la SPA porte le contrôle de santé (le compose n'en met pas)" grep -q '^HEALTHCHECK' "${TPL}/frontend/Dockerfile.spa"
check "le Dockerfile Next.js porte le contrôle de santé" grep -q '^HEALTHCHECK' "${TPL}/frontend/Dockerfile.nextjs"

step "Les fichiers d'environnement : un par environnement, différents"
P="${TPL}/env.platform.production.example"; S="${TPL}/env.platform.staging.example"
check "production : DEPLOYMENT=prod et ENV_FILE=.env" sh -c "grep -q '^DEPLOYMENT=prod' '${P}' && grep -q '^ENV_FILE=.env$' '${P}'"
check "staging : DEPLOYMENT=staging et ENV_FILE=.env.staging" sh -c "grep -q '^DEPLOYMENT=staging' '${S}' && grep -q '^ENV_FILE=.env.staging$' '${S}'"
check "les noms publics diffèrent (staging a son propre nom)" test "$(grep '^APP_PUBLIC_HOST=' "${P}")" != "$(grep '^APP_PUBLIC_HOST=' "${S}")"
check "staging : BACKUP_DISABLED=1 (les sauvegardes ne vivent que sur S3, le staging n'en a pas)" grep -q '^BACKUP_DISABLED=1' "${S}"
check_not "production : jamais BACKUP_DISABLED" grep -q '^BACKUP_DISABLED' "${P}"
check "production : le bucket S3 est une variable à renseigner (obligatoire)" grep -q '^BACKUP_S3_BUCKET=' "${P}"
check_not "aucune copie locale (BACKUP_LOCAL_KEEP) dans les modèles : exception à décider, pas un défaut" grep -q '^BACKUP_LOCAL_KEEP' "${P}" "${S}"

step "La fiche de déploiement : un modèle à remplir, sans valeur secrète"
D="${TPL}/docs-projet/DEPLOIEMENT.md"
check "elle décrit chaque environnement (carte, premier déploiement, livraison, mise à jour, retour arrière, sauvegarde, observabilité)" \
    sh -c "for s in 'La carte du projet' 'Premier déploiement' 'Livrer une nouvelle version' 'Mettre à jour ce qui est déjà là' 'Retour arrière' 'Sauvegarde et restauration' 'Observabilité de ce projet' 'En cas de problème'; do grep -q \"\$s\" '${D}' || exit 1; done"
check_not "aucun lien relatif vers la plateforme (les liens doivent survivre à la copie dans un projet)" grep -q -E '\]\((\.\./|\.\./\.\./)' "${D}"
check_not "aucun secret : ni mot de passe, ni jeton, ni clé privée" grep -q -i -E 'password=[^ ]|token=[A-Za-z0-9]{12}|BEGIN [A-Z ]*PRIVATE KEY' "${D}"

step "La fiche de déploiement est demandée par le contrat (C14) : deploy.sh check la signale sans bloquer"
check "sans docs/DEPLOIEMENT.md : un avertissement INFO est écrit dans le journal" \
    sh -c "cd '${WORK}/laravel' && '${DEPLOY}' check prod 2>&1 | grep -q 'INFO — pas de docs/DEPLOIEMENT.md'"
check "et le contrôle réussit quand même (non bloquant)" sh -c "cd '${WORK}/laravel' && '${DEPLOY}' check prod >/dev/null 2>&1"
mkdir -p "${WORK}/laravel/docs" && cp "${TPL}/docs-projet/DEPLOIEMENT.md" "${WORK}/laravel/docs/DEPLOIEMENT.md"
check_not "avec la fiche, plus d'avertissement" sh -c "cd '${WORK}/laravel' && '${DEPLOY}' check prod 2>&1 | grep -q 'pas de docs/DEPLOIEMENT.md'"
