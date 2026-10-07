#!/usr/bin/env bash
# vps-overview : « quelle version tourne où » en lecture seule. Sans Docker réel ni root : un faux « docker » (dans le PATH du test) rend des
# réponses fixes, un faux dossier d'état reproduit celui de deploy.sh. On vérifie ce qui est affiché, l'ordre, la santé, la branche, que RIEN
# de secret ne sort (le faux docker en plante un dans l'environnement d'un conteneur), l'échappement HTML, l'écriture atomique, et le
# comportement quand Docker ou le dossier d'état manquent. Deux régressions simulées prouvent que les contrôles mordent.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
trap finish EXIT
command -v python3 >/dev/null || { red "python3 requis"; exit 2; }

TOOL="${INFRA_DIR}/bin/vps-overview.py"
ST="${WORK}/etat"; FAKE="${WORK}/fakebin"; PRJ="${WORK}/apps/alpha-staging"
SHA1="$(printf '1%.0s' {1..40})"; SHA0="$(printf '0%.0s' {1..40})"; SHAX="$(printf 'e%.0s' {1..40})"; SHAB="$(printf 'b%.0s' {1..40})"
mkdir -p "${FAKE}" "${PRJ}" "${ST}/alpha/staging" "${ST}/alpha/prod" "${ST}/beta/prod" "${ST}/gamma/staging" "${ST}/delta/prod" "${ST}/evil<b>x/staging"
printf '%s\n' "${SHA1}" > "${ST}/alpha/staging/current"; printf '%s\n' "${SHA0}" > "${ST}/alpha/staging/previous"
printf '%s\n' "${SHA0}" > "${ST}/alpha/prod/current"; printf '%s\n' "${SHAX}" > "${ST}/alpha/prod/failed"
printf '%s\n' "${SHAB}" > "${ST}/beta/prod/current"
printf '%s\n' "${SHA1}" > "${ST}/gamma/staging/current"
printf 'pas-un-sha\n' > "${ST}/delta/prod/current"
printf '%s\n' "${SHA1}" > "${ST}/evil<b>x/staging/current"
printf 'APP_NAME=alpha\nBRANCH_STAGING=develop\nBRANCH_PROD=main\nDB_PASSWORD=SECRET-DU-PLATFORM-ENV\n' > "${PRJ}/platform.env"

# Faux docker : « ps -a » et « inspect », avec un secret planté dans l'environnement d'un conteneur.
cat > "${FAKE}/docker" <<DOCKER
#!/usr/bin/env bash
[[ "\${FAKE_DOCKER_DOWN:-0}" == 1 ]] && { echo "Cannot connect to the Docker daemon" >&2; exit 1; }
case "\$1" in
ps)
  printf 'alpha-staging-web-1\talpha-staging\tweb\t${PRJ}\tUp 3 hours (healthy)\n'
  printf 'alpha-staging-worker-1\talpha-staging\tworker\t${PRJ}\tUp 3 hours (unhealthy)\n'
  printf 'alpha-prod-web-1\talpha-prod\tweb\t/dossier/inexistant\tUp 2 days (healthy)\n'
  printf 'beta-prod-web-1\tbeta-prod\tweb\t\tUp 5 hours\n'
  printf 'beta-prod-db-1\tbeta-prod\tdb\t\tExited (0) 1 hour ago\n'
  printf 'evil<b>x-staging-web-1\tevil<b>x-staging\tweb\t\tUp 1 hour (healthy)\n'
  printf 'sans-compose\t\t\t\tUp 1 hour\n'
  ;;
inspect)
  printf '@@/alpha-staging-web-1\nVIRTUAL_HOST=dev.alpha.exemple.cm,www.dev.alpha.exemple.cm\nDB_PASSWORD=SUPERSECRET-123\nAPP_KEY=base64:CLEF-SECRETE\n'
  printf '@@/alpha-staging-worker-1\nREDIS_PASSWORD=SUPERSECRET-456\n'
  printf '@@/alpha-prod-web-1\nVIRTUAL_HOST=alpha.exemple.cm\nAPI_TOKEN=SUPERSECRET-789\n'
  printf '@@/beta-prod-web-1\nVIRTUAL_HOST=beta.exemple.cm\n'
  ;;
esac
DOCKER
chmod +x "${FAKE}/docker"
run() { PATH="${FAKE}:${PATH}" STATE_DIR="${ST}" python3 "${TOOL}" "$@"; }

step "Le tableau"
run > "${WORK}/texte.txt" 2>&1 || true
check "il liste chaque projet et chaque environnement" sh -c "for p in alpha beta gamma delta; do grep -q \"^\$p\" '${WORK}/texte.txt' || exit 1; done"
check "la version déployée et la précédente sont affichées (12 caractères)" sh -c "grep '^alpha *staging' '${WORK}/texte.txt' | grep -q '${SHA1:0:12} *${SHA0:0:12}'"
check "dans un projet, le staging vient avant la production" sh -c "[ \$(grep -n '^alpha *staging' '${WORK}/texte.txt' | cut -d: -f1) -lt \$(grep -n '^alpha *prod' '${WORK}/texte.txt' | cut -d: -f1) ]"
check "la branche suivie par le staging vient de platform.env (develop)" sh -c "grep '^alpha *staging' '${WORK}/texte.txt' | grep -q develop"
check "un conteneur en défaut est nommé (worker), l'état est « à vérifier »" sh -c "grep '^alpha *staging' '${WORK}/texte.txt' | grep -q 'à vérifier (worker)'"
check "conteneurs sains / total (1/2)" sh -c "grep '^alpha *staging' '${WORK}/texte.txt' | grep -q ' 1/2 '"
check "un conteneur arrêté est un défaut (beta : db)" sh -c "grep '^beta' '${WORK}/texte.txt' | grep -q 'à vérifier (db)'"
check "un environnement sans conteneur est dit « aucun conteneur »" sh -c "grep '^gamma' '${WORK}/texte.txt' | grep -q 'aucun conteneur'"
check "un dernier échec est signalé (alpha prod)" sh -c "grep '^alpha *prod' '${WORK}/texte.txt' | grep -q 'dernier échec ${SHAX:0:12}'"
check "un fichier d'état invalide s'affiche « ? », sans planter" sh -c "grep '^delta' '${WORK}/texte.txt' | grep -q ' ? '"
check "les noms publics du conteneur web figurent" sh -c "grep '^alpha *staging' '${WORK}/texte.txt' | grep -q 'dev.alpha.exemple.cm'"
check "un projet dont platform.env est introuvable n'a pas de branche, sans erreur" sh -c "grep '^alpha *prod' '${WORK}/texte.txt' | grep -q ' - '"

printf 'APP_NAME=alpha\nBRANCH_STAGING=une-branche-vraiment-tres-longue-de-travail\n' > "${PRJ}/platform.env.long"
check "une branche très longue ne colle pas à la colonne suivante (au moins deux espaces avant « 1/2 »)" sh -c "cp '${PRJ}/platform.env' '${PRJ}/platform.env.bak' && cp '${PRJ}/platform.env.long' '${PRJ}/platform.env' && PATH='${FAKE}':\$PATH STATE_DIR='${ST}' python3 '${TOOL}' | grep '^alpha *staging' | grep -qE 'une-branche-vraiment-tres-longue-de-travail  +1/2'; r=\$?; cp '${PRJ}/platform.env.bak' '${PRJ}/platform.env'; exit \$r"

step "Aucun secret ne sort"
run --json > "${WORK}/etat.json" 2>&1 || true
run --html "${WORK}/pub" >/dev/null 2>&1 || true
leaks() { cat "${WORK}/texte.txt" "${WORK}/etat.json" "${WORK}/pub/index.html" "${WORK}/pub/status.json" 2>/dev/null | grep -iE 'SUPERSECRET|CLEF-SECRETE|SECRET-DU-PLATFORM-ENV|DB_PASSWORD|API_TOKEN|APP_KEY' || true; }
check "ni les variables d'environnement des conteneurs, ni platform.env (texte, JSON, page)" test -z "$(leaks)"
check "le JSON est valide et porte les champs attendus" python3 -c "
import json; m=json.load(open('${WORK}/etat.json')); e=m['environnements'][0]
assert {'projet','env','courant','precedent','branche','conteneurs','domaines','statut','deploye_le'} <= set(e)"

step "La page"
check "index.html et status.json sont écrits, sans fichier temporaire oublié" sh -c "[ -s '${WORK}/pub/index.html' ] && [ -s '${WORK}/pub/status.json' ] && [ -z \"\$(ls -A '${WORK}/pub' | grep '^.tmp-')\" ]"
check "la page est en consultation seule et refuse l'indexation" sh -c "grep -q 'Consultation seule' '${WORK}/pub/index.html' && grep -q 'noindex' '${WORK}/pub/index.html'"
check "aucun script, aucun formulaire dans la page" sh -c "! grep -qiE '<script|<form|<input' '${WORK}/pub/index.html'"
check "un nom de projet hostile est échappé (&lt;b&gt;), jamais écrit en HTML brut" sh -c "grep -q 'evil&lt;b&gt;x' '${WORK}/pub/index.html' && ! grep -q 'evil<b>x' '${WORK}/pub/index.html'"
check "chaque version du tableau est dans la page" sh -c "grep -q '${SHA1:0:12}' '${WORK}/pub/index.html' && grep -q '${SHAB:0:12}' '${WORK}/pub/index.html'"
check "un domaine devient un lien" sh -c "grep -q \"href='https://beta.exemple.cm'\" '${WORK}/pub/index.html'"
check "écrite deux fois de suite, la page reste valable (écriture atomique)" sh -c "PATH='${FAKE}':\$PATH STATE_DIR='${ST}' python3 '${TOOL}' --html '${WORK}/pub' && [ -s '${WORK}/pub/index.html' ]"

step "Quand quelque chose manque"
FAKE_DOCKER_DOWN=1 run > "${WORK}/down.txt" 2>&1 || true
check "Docker injoignable : le tableau reste affiché avec les versions, l'état dit « Docker injoignable »" sh -c "grep -q 'Docker injoignable' '${WORK}/down.txt' && grep -q '${SHA1:0:12}' '${WORK}/down.txt'"
FAKE_DOCKER_DOWN=1 run --html "${WORK}/pub-down" >/dev/null 2>&1 || true
check "… et la page l'annonce en tête" sh -c "grep -q \"Docker n'a pas répondu\" '${WORK}/pub-down/index.html'"
check_not "dossier d'état absent : refus clair (code 1)" sh -c "PATH='${FAKE}':\$PATH STATE_DIR='${WORK}/nulle-part' python3 '${TOOL}'"
check "… et le message dit quoi vérifier" sh -c "PATH='${FAKE}':\$PATH STATE_DIR='${WORK}/nulle-part' python3 '${TOOL}' 2>&1 | grep -q 'dossier d.état introuvable'"
check_not "option inconnue : refusée (code 2)" run --nope
check "--help dit ce que fait l'outil" sh -c "python3 '${TOOL}' --help | grep -q 'quelle version tourne'"

step "Le service web : le vrai nginx, la vraie configuration (overview/)"
if ! command -v docker >/dev/null; then echo "  (Docker absent : étape ignorée)"; else
check "le compose est valide avec un nom public" sh -c "OVERVIEW_HOST=plateforme.exemple.cm docker compose -f '${INFRA_DIR}/overview/compose.yaml' config -q"
check_not "… et refusé sans nom public (pas de page publiée par défaut)" sh -c "env -u OVERVIEW_HOST docker compose -f '${INFRA_DIR}/overview/compose.yaml' config -q"
check "le compose ne publie aucun port et monte la page en lecture seule, conteneur en lecture seule sans aucune capacité" sh -c "OVERVIEW_HOST=x.exemple.cm docker compose -f '${INFRA_DIR}/overview/compose.yaml' config | python3 -c \"
import sys,re; t=sys.stdin.read()
assert 'published:' not in t and not re.search(r'^\\s+ports:', t, re.M)
assert 'read_only: true' in t and 'cap_drop' in t and 'ALL' in t and 'no-new-privileges' in t
assert re.search(r'target: /usr/share/nginx/html\\s+read_only: true', t)\""
PORT=18899; N=vpstest-overview
docker run -d --name "${N}" -p 127.0.0.1:${PORT}:8080 --read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges:true \
    -v "${WORK}/pub:/usr/share/nginx/html:ro" -v "${INFRA_DIR}/overview/nginx.conf:/etc/nginx/conf.d/default.conf:ro" nginxinc/nginx-unprivileged:1.27-alpine >/dev/null
check "le conteneur répond (sain, lecture seule, sans capacité)" wait_for 30 sh -c "curl -sf http://127.0.0.1:${PORT}/healthz >/dev/null"
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
check "la page est servie à la racine" sh -c "curl -s http://127.0.0.1:${PORT}/ | grep -q 'État de la plateforme'"
check "status.json est servi en JSON" sh -c "curl -sI http://127.0.0.1:${PORT}/status.json | grep -qi 'content-type: application/json'"
check "en-têtes : pas d'indexation, pas de cache, pas d'iframe, CSP sans script" sh -c "h=\$(curl -sI http://127.0.0.1:${PORT}/); echo \"\$h\" | grep -qi 'x-robots-tag: noindex' && echo \"\$h\" | grep -qi 'cache-control: no-store' && echo \"\$h\" | grep -qi 'x-frame-options: DENY' && echo \"\$h\" | grep -qi \"content-security-policy: default-src 'none'\""
check "toute écriture est refusée (POST, PUT, DELETE)" sh -c "for m in POST PUT DELETE; do c=\$(curl -s -o /dev/null -w '%{http_code}' -X \$m http://127.0.0.1:${PORT}/); [ \"\$c\" = 403 ] || exit 1; done"
check "aucun autre fichier n'est exposé (404) : dossier caché, chemin inconnu, liste de dossier" sh -c "for u in /.tmp-x /nope /../etc/passwd /pub/; do c=\$(curl -s --path-as-is -o /dev/null -w '%{http_code}' http://127.0.0.1:${PORT}\$u); [ \"\$c\" = 404 ] || [ \"\$c\" = 400 ] || exit 1; done"
check "le conteneur ne peut rien écrire dans la page (volume en lecture seule)" sh -c "! docker exec ${N} sh -c 'echo x > /usr/share/nginx/html/index.html' 2>/dev/null"
check "la commande du contrôle de santé du compose (wget /healthz) fonctionne dans l'image" sh -c "docker exec ${N} wget -qO- http://127.0.0.1:8080/healthz | grep -q ok"
docker rm -f "${N}" >/dev/null 2>&1 || true
fi

step "Régressions simulées : les contrôles mordent"
cp "${TOOL}" "${WORK}/mut1.py"; sed -i 's/e_ = html.escape/e_ = str/' "${WORK}/mut1.py"
PATH="${FAKE}:${PATH}" STATE_DIR="${ST}" python3 "${WORK}/mut1.py" --html "${WORK}/pub-m1" >/dev/null 2>&1 || true
check "sans échappement, le nom hostile apparaît en HTML brut (le contrôle le verrait)" grep -q 'evil<b>x' "${WORK}/pub-m1/index.html"
cp "${TOOL}" "${WORK}/mut2.py"; sed -i 's/elif courant and ligne.startswith("VIRTUAL_HOST="):/elif courant and ligne.startswith("DB_PASSWORD="):/' "${WORK}/mut2.py"
PATH="${FAKE}:${PATH}" STATE_DIR="${ST}" python3 "${WORK}/mut2.py" > "${WORK}/m2.txt" 2>&1 || true
check "si l'outil lisait une autre variable que VIRTUAL_HOST, le secret sortirait (le contrôle le verrait)" grep -qi 'supersecret' "${WORK}/m2.txt"
