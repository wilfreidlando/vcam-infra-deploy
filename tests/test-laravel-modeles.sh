#!/usr/bin/env bash
# Les modèles PHP de templates/laravel-observabilite/ dans une VRAIE application Laravel (squelette installé par Composer) : la route /metrics,
# le middleware, le test fourni passent ; le contrôleur rend les bonnes étiquettes une fois la configuration MISE EN CACHE (php artisan
# config:cache, lancé au démarrage des conteneurs) ; et les étiquettes viennent de config() : le test fourni les fixe par config(), ce qu'une
# valeur lue par env() ne permettrait pas. Contrôle négatif : le contrôleur réécrit avec env() DOIT faire échouer le test fourni.
# Demande Docker et le réseau (Packagist) ; une à deux minutes.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
trap finish EXIT
require_docker
T="${INFRA_DIR}/templates/laravel-observabilite"; APP="${WORK}/app"; mkdir -p "${APP}"
U="$(id -u):$(id -g)"
dphp() { docker run --rm --user "${U}" -e HOME=/tmp -e COMPOSER_HOME=/tmp/composer -v "${APP}:/app" -w /app "$@"; }

step "Un vrai squelette Laravel (Composer)"
check "installation du squelette" dphp composer:2 composer create-project laravel/laravel . --prefer-dist --no-interaction --no-progress --quiet --ignore-platform-reqs
check "le squelette contient bootstrap/app.php et config/app.php" test -f "${APP}/bootstrap/app.php" -a -f "${APP}/config/app.php"

step "Le modèle copié comme le dit son README"
mkdir -p "${APP}/app/Http/Middleware"
cp "${T}/MetricsController.php" "${APP}/app/Http/Controllers/MetricsController.php"
cp "${T}/OnlyFromPrivateNetwork.php" "${APP}/app/Http/Middleware/OnlyFromPrivateNetwork.php"
cp "${T}/MetricsTest.php" "${APP}/tests/Feature/MetricsTest.php"
python3 - "${APP}" <<'PY'
import re, sys
app = sys.argv[1]
p = app + "/bootstrap/app.php"; s = open(p).read()
route = """        then: function (): void {
            \\Illuminate\\Support\\Facades\\Route::get('/metrics', \\App\\Http\\Controllers\\MetricsController::class)
                ->middleware(\\App\\Http\\Middleware\\OnlyFromPrivateNetwork::class)->name('metrics');
        },
"""
assert "health: '/up'," in s, "squelette Laravel inattendu : health: '/up' absent"
open(p, "w").write(s.replace("health: '/up',\n", "health: '/up',\n" + route, 1))
p = app + "/config/app.php"; s = open(p).read()
cle = "    'name' => env('APP_NAME', 'Laravel'),\n"
assert cle in s, "squelette Laravel inattendu : 'name' absent de config/app.php"
open(p, "w").write(s.replace(cle, cle + "\n    'deployment' => env('DEPLOYMENT', 'prod'),\n    'version' => env('APP_VERSION', 'inconnue'),\n", 1))
PY
check "le PHP du modèle est valide" dphp php:8.4-cli-alpine sh -c 'for f in app/Http/Controllers/MetricsController.php app/Http/Middleware/OnlyFromPrivateNetwork.php tests/Feature/MetricsTest.php; do php -l $f || exit 1; done'

step "Le test fourni avec le modèle passe dans l'application"
dphp php:8.4-cli-alpine php artisan test --filter=MetricsTest > "${WORK}/phpunit.txt" 2>&1 && ok "MetricsTest : servi au réseau privé, introuvable depuis Internet, étiquettes lues dans la configuration" || { ko "MetricsTest"; sed 's/^/      /' "${WORK}/phpunit.txt" | tail -25; }

step "Configuration en CACHE (comme au démarrage d'un conteneur) : les étiquettes viennent de config(), pas de env()"
metriques() { dphp -e DEPLOYMENT=staging -e APP_VERSION=v9 php:8.4-cli-alpine sh -c 'php artisan config:clear >/dev/null && php artisan config:cache >/dev/null && php artisan tinker --execute="echo app(App\\Http\\Controllers\\MetricsController::class)()->getContent();"'; }
metriques > "${WORK}/cache.txt" 2>&1 || true
check "avec le cache de configuration : deployment=\"staging\"" grep -q 'deployment="staging"' "${WORK}/cache.txt"
check "avec le cache de configuration : version=\"v9\"" grep -q 'version="v9"' "${WORK}/cache.txt"
sed -i "s/(string) config('app.deployment', 'prod')/(string) env('DEPLOYMENT', 'prod')/; s/(string) config('app.version', 'inconnue')/(string) env('APP_VERSION', 'inconnue')/" "${APP}/app/Http/Controllers/MetricsController.php"
grep -q "env('DEPLOYMENT'" "${APP}/app/Http/Controllers/MetricsController.php" && ok "contrôle négatif préparé : le contrôleur lit maintenant env()" || ko "le contrôle négatif n'a pas pu être préparé"
dphp php:8.4-cli-alpine php artisan test --filter=MetricsTest > "${WORK}/phpunit-env.txt" 2>&1 \
    && ko "contrôle négatif : le test fourni PASSE avec env() : il ne protège pas la règle « les étiquettes viennent de la configuration »" \
    || { grep -qE "labels come from the configuration not from env|test_labels_come_from_the_configuration_not_from_env" "${WORK}/phpunit-env.txt" && ok "contrôle négatif : avec env(), c'est bien le test des étiquettes qui échoue" || { ko "contrôle négatif : échec, mais pas pour la bonne raison"; tail -15 "${WORK}/phpunit-env.txt"; }; }
