#!/usr/bin/env bash
# Les scripts modèles (templates/scripts/) : ops.sh (exploitation courante) et make-env.py (fichiers d'environnement sans secret affiché).
# ops.sh est vérifié contre de FAUX docker, curl et vps-deploy qui enregistrent ce qu'on leur demande : la commande exacte (projet compose, fichier
# compose, fichier d'environnement, version), le dossier, et surtout ce qui ne doit JAMAIS arriver (suppression de conteneur ou de volume, arrêt d'une
# production sans confirmation). make-env.py : secrets distincts et jamais affichés, liste blanche respectée, aucun écrasement.
# Ne demande ni Docker réel ni réseau.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
trap finish EXIT
cd "${INFRA_DIR}/templates/scripts"

# ── ops.sh rendu pour un projet d'exemple, face à un faux serveur
OPS="${WORK}/ops.sh"; sed 's#<PROJET>#monprojet#g' ops.sh > "${OPS}"; chmod +x "${OPS}"
BASE="${WORK}/apps/monprojet"; STATE="${WORK}/state"; BIN="${WORK}/bin"; LOG="${WORK}/appels.log"
mkdir -p "${BIN}" "${STATE}/monprojet/staging" "${STATE}/monprojet/prod"
for e in staging prod; do
    mkdir -p "${BASE}/${e}"
    printf 'APP_NAME=monprojet\nCOMPOSE_FILE=compose.prod.yaml\nENVIRONMENTS="staging prod"\nPROD_ENVIRONMENTS="prod"\nENV_FILE_STAGING=.env.staging\nENV_FILE_PROD=.env.prod\n' > "${BASE}/${e}/platform.env"
    printf 'APP_PUBLIC_HOST=%s.exemple.test\nSECRET=ne-doit-jamais-etre-affiche\n' "${e}" > "${BASE}/${e}/.env.${e}"
done
echo "abc123def456" > "${STATE}/monprojet/staging/current"; echo "fff999" > "${STATE}/monprojet/prod/current"
cat > "${BIN}/docker" <<'FAUX'
#!/usr/bin/env bash
echo "docker $* | cwd=$(basename "$PWD") ENV_FILE=${ENV_FILE:-} IMAGE_TAG=${IMAGE_TAG:-}" >> "$CALLS"
if [[ "$*" == *" ps -q"* ]]; then echo "c1"; echo "c2"; fi
if [[ "$1" == inspect ]]; then echo 2; fi
exit 0
FAUX
printf '#!/usr/bin/env bash\necho "curl $*" >> "$CALLS"; printf 200\n' > "${BIN}/curl"
printf '#!/usr/bin/env bash\necho "vps-deploy $* | cwd=$(basename "$PWD")" >> "$CALLS"\n' > "${BIN}/vps-deploy"
chmod +x "${BIN}"/*
export PATH="${BIN}:${PATH}" CALLS="${LOG}" PROJECT_BASE="${BASE}" STATE_DIR="${STATE}" VPS_DEPLOY=vps-deploy

run() { : > "${LOG}"; "${OPS}" "$@" </dev/null; }                 # entrée vide : pas de terminal pour confirmer
appele() { grep -qF -- "$1" "${LOG}"; }
attendu() { appele "$2" && ok "$1" || { ko "$1 (attendu : « $2 »)"; echo "    appels : $(tr '\n' ';' < "${LOG}")"; }; }
interdit() { appele "$2" && { ko "$1"; echo "    appels : $(tr '\n' ';' < "${LOG}")"; } || ok "$1"; }

step "ops.sh : aide et erreurs"
set +e
out="$("${OPS}" 2>&1 </dev/null)"; rc=$?;              [[ $rc -eq 2 && "${out}" == *"status"* ]] && ok "sans argument : aide, code 2" || ko "sans argument (code ${rc})"
out="$("${OPS}" help 2>&1 </dev/null)"; rc=$?;          [[ $rc -eq 0 && "${out}" == *"stop"* ]] && ok "help : aide, code 0" || ko "help (code ${rc})"
out="$("${OPS}" production status 2>&1 </dev/null)"; rc=$?;  [[ $rc -eq 2 && "${out}" == *"environnement inconnu"* ]] && ok "environnement inconnu refusé" || ko "environnement inconnu (code ${rc})"
out="$("${OPS}" staging detruire 2>&1 </dev/null)"; rc=$?;   [[ $rc -eq 2 && "${out}" == *"action inconnue"* ]] && ok "action inconnue refusée" || ko "action inconnue (code ${rc})"
set -e

step "ops.sh : status"
out="$(run staging status)"
attendu "projet, fichier compose et fichier d'environnement corrects" "docker compose -p monprojet-staging -f compose.prod.yaml --env-file .env.staging ps"
attendu "version déployée transmise (IMAGE_TAG)" "IMAGE_TAG=abc123def456"
attendu "exécuté dans le dossier de l'environnement" "cwd=staging"
[[ "${out}" == *"abc123def456"* && "${out}" == *"redémarrages cumulés : 4"* ]] && ok "affiche la version et la somme des redémarrages (2 conteneurs × 2)" || ko "affichage de status"
attendu "sonde l'adresse publique de santé" "https://staging.exemple.test/up"
[[ "${out}" != *"ne-doit-jamais-etre-affiche"* ]] && ok "aucun secret du fichier d'environnement affiché" || ko "un secret a été affiché"

step "ops.sh : logs, arrêt, démarrage, redémarrage, shell"
run staging logs >/dev/null;                          attendu "logs : 100 dernières lignes par défaut" "logs --tail 100"
run staging logs app >/dev/null;                      attendu "raccourci « app » → monprojet-app" "logs --tail 100 monprojet-app"
run staging logs -f web >/dev/null;                   attendu "-f pour suivre un service" "logs --tail 100 -f monprojet-web"
run staging logs --since 10m db >/dev/null;           attendu "--since respecté" "logs --since 10m monprojet-db"
interdit "--since : pas de --tail ajouté" "--tail 100"
run staging stop >/dev/null;                          attendu "stop sur staging : sans confirmation" " stop |"
interdit "stop ne supprime ni conteneur ni volume (pas de down)" " down"
run staging start >/dev/null;                         attendu "start" " start |"
set +e; run prod stop >/dev/null 2>&1; rc=$?; set -e
[[ $rc -ne 0 ]] && ok "stop d'une PRODUCTION sans confirmation : refusé" || ko "stop de prod accepté sans confirmation"
interdit "… et rien n'a été arrêté" " stop |"
run prod stop --yes >/dev/null;                       attendu "stop de la prod avec --yes" "-p monprojet-prod -f compose.prod.yaml --env-file .env.prod stop"
run prod restart app --yes >/dev/null;                attendu "restart d'un service (raccourci) en production avec --yes" "restart monprojet-app"
out="$("${OPS}" staging restart 2>&1 </dev/null)"
[[ "${out}" == *"ne relit PAS le fichier"* && "${out}" == *"vps-deploy up staging"* ]] && ok "restart rappelle qu'il ne relit pas le fichier d'environnement, et la commande à utiliser" || ko "rappel de restart absent"
run staging shell >/dev/null;                         attendu "shell par défaut : le service app" "exec monprojet-app sh"
run staging shell db >/dev/null;                      attendu "shell d'un autre service par raccourci" "exec monprojet-db sh"

step "ops.sh : plateforme et interdits"
run prod check >/dev/null;                            attendu "check → vps-deploy check prod dans le dossier de l'env" "vps-deploy check prod | cwd=prod"
run prod backup >/dev/null;                           attendu "backup → vps-deploy backup prod" "vps-deploy backup prod | cwd=prod"
run prod obs >/dev/null;                              attendu "obs → vps-deploy obs-sync" "vps-deploy obs-sync | cwd=prod"
: > "${LOG}"
for a in "staging status" "staging logs" "staging stop" "staging start" "staging restart" "prod stop --yes" "prod restart --yes" "staging shell"; do "${OPS}" ${a} </dev/null >/dev/null 2>&1 || true; done
interdit "aucune action n'appelle « down »" " down"
interdit "aucune action n'appelle « rm »" " rm "
interdit "aucune action n'utilise « -v » (volumes)" " -v"
interdit "aucune action n'appelle « prune »" "prune"

step "make-env.py : secrets sans affichage, liste blanche, aucun écrasement"
MK="make-env.py"; val() { grep -m1 "^$2=" "$1" | cut -d= -f2-; }
mkdir -p "${WORK}/prod" "${WORK}/staging"
for e in prod staging; do
    printf 'APP_ENV=%s\nAPP_KEY=\nAPP_DEBUG=false\nLOG_LEVEL=warning\nDB_PASSWORD=\nDB_ROOT_PASSWORD=\nREDIS_PASSWORD=\nBACKUP_PASSPHRASE=\nMAIL_HOST=smtp.exemple.test\nMAIL_PASSWORD=\n' "${e}" > "${WORK}/${e}/.env.${e}.example"
done
cat > "${WORK}/source.env" <<'ENV'
APP_KEY=base64:CLE-DE-LA-SOURCE-XYZ
APP_DEBUG=true
DB_PASSWORD=mot-de-passe-base-source
REDIS_PASSWORD=redis-source
MAIL_HOST=mail.source.test
MAIL_PASSWORD=mot-de-passe-courrier-source
LOG_LEVEL=debug
ENV
out="$(./${MK} "${WORK}/prod" prod --copy-from "${WORK}/source.env")"; F="${WORK}/prod/.env.prod"
[[ "$(val "$F" APP_KEY)" == "base64:CLE-DE-LA-SOURCE-XYZ" ]] && ok "APP_KEY reprise de la source (liste blanche)" || ko "APP_KEY non reprise"
[[ "$(val "$F" MAIL_PASSWORD)" == "mot-de-passe-courrier-source" && "$(val "$F" MAIL_HOST)" == "mail.source.test" ]] && ok "courrier repris (liste blanche)" || ko "courrier non repris"
for k in DB_PASSWORD REDIS_PASSWORD; do
    v="$(val "$F" $k)"; src="$(val "${WORK}/source.env" $k)"
    [[ -n "$v" && "$v" != "$src" ]] && ok "$k : valeur neuve, jamais celle de la source" || ko "$k repris ou vide"
done
[[ "$(val "$F" APP_DEBUG)" == "false" && "$(val "$F" LOG_LEVEL)" == "warning" ]] && ok "APP_DEBUG et LOG_LEVEL du modèle conservés (ceux de la source, true et debug, ne sont pas repris)" || ko "APP_DEBUG ou LOG_LEVEL repris de la source"
vides="$(grep -cE '^(DB_PASSWORD|DB_ROOT_PASSWORD|REDIS_PASSWORD|BACKUP_PASSPHRASE)=[[:space:]]*$' "$F" || true)"
[[ "${vides}" -eq 0 ]] && ok "plus aucun secret vide" || ko "${vides} secret(s) resté(s) vide(s)"
n="$(grep -E '^(DB_PASSWORD|DB_ROOT_PASSWORD|REDIS_PASSWORD|BACKUP_PASSPHRASE)=' "$F" | cut -d= -f2- | sort -u | wc -l)"
[[ "$n" -eq 4 ]] && ok "4 secrets, 4 valeurs DISTINCTES" || ko "valeurs non distinctes ($n)"
fuite=0; for s in CLE-DE-LA-SOURCE mot-de-passe-courrier-source mot-de-passe-base-source redis-source; do grep -q "$s" <<< "$out" && fuite=1; done
for k in DB_PASSWORD DB_ROOT_PASSWORD REDIS_PASSWORD BACKUP_PASSPHRASE; do grep -qF "$(val "$F" $k)" <<< "$out" && fuite=1; done
[[ $fuite -eq 0 ]] && ok "la sortie n'affiche aucune valeur secrète" || ko "une valeur secrète apparaît dans la sortie"
[[ "$(stat -c %a "$F")" == "660" ]] && ok "droits 660 (propriétaire et groupe)" || ko "droits $(stat -c %a "$F")"
set +e; ./${MK} "${WORK}/prod" prod >/dev/null 2>&1; rc=$?; set -e
[[ $rc -ne 0 && "$(val "$F" APP_KEY)" == "base64:CLE-DE-LA-SOURCE-XYZ" ]] && ok "un fichier existant n'est jamais écrasé (et reste intact)" || ko "écrasement accepté ou fichier modifié"
./${MK} "${WORK}/staging" staging >/dev/null
k="$(val "${WORK}/staging/.env.staging" APP_KEY)"
[[ "$k" == base64:* && ${#k} -gt 40 ]] && ok "sans source : APP_KEY neuve (base64, 32 octets)" || ko "APP_KEY neuve"
[[ "$(val "${WORK}/staging/.env.staging" DB_PASSWORD)" != "$(val "$F" DB_PASSWORD)" ]] && ok "deux environnements : mots de passe différents" || ko "mots de passe identiques entre environnements"
set +e; ./${MK} "${WORK}/staging" inconnu >/dev/null 2>&1; rc=$?; set -e
[[ $rc -ne 0 ]] && ok "modèle inconnu : refusé" || ko "modèle inconnu accepté"
