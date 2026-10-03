# 10. Apps qui gèrent leurs sous-domaines automatiquement (multi-tenant)

Exemple : un SaaS où chaque client obtient `client1.monsaas.com`, `client2.monsaas.com`…
dès sa création dans l'application, **sans toucher au serveur**.

## Ce que l'infrastructure fournit déjà (vérifié)

| Besoin | Mécanisme | Statut |
| --- | --- | --- |
| Tous les sous-domaines arrivent sur le serveur | DNS wildcard `*.monsaas.com` | standard DNS |
| nginx-proxy envoie tous les sous-domaines à l'app | `VIRTUAL_HOST=monsaas.com,*.monsaas.com` | **testé** avec nginx-proxy 1.7 (`tests/test-hosts.sh`) : `client1`, `nouveau-client` et l'apex routés vers l'app, un autre site intact, nom inconnu en 503 |
| Un seul certificat couvre tous les clients | certificat **wildcard** Let's Encrypt par challenge **DNS-01** | pris en charge par acme-companion 2.5 : vérifié dans son code source (`letsencrypt_service` v2.5.2). Le certificat est publié sous `monsaas.com.crt`, que nginx-proxy utilise aussi pour les sous-domaines |
| Un autre projet ne peut pas « voler » un sous-domaine client | `vps-hosts.sh` + `deploy.sh` | **testé** (`test-hosts.sh`, `test-deploy.sh`) |

**Non testé ici** : l'émission réelle du certificat wildcard. Elle exige un vrai
domaine et un vrai compte DNS ; elle se vérifie à l'étape 3, sur le serveur.

Un **certificat wildcard s'obtient uniquement par DNS-01**. Let's Encrypt doit voir
un enregistrement TXT créé dans la zone du domaine. acme-companion le crée lui-même,
mais il lui faut **l'API de votre hébergeur DNS**. Cloudflare (gratuit) est le plus
simple ; acme.sh, que acme-companion utilise, connaît aussi la plupart des autres.

## Étape 1 — Choisir le domaine du SaaS

**Recommandé : un domaine dédié au SaaS** (`monsaas.com`), hébergé chez
Cloudflare DNS (gratuit) :
- le jeton d'API ne donne accès qu'à ce domaine ;
- ses clients sont isolés de `visibilitycam.com`.

**Possible : `*.monsaas.visibilitycam.com`.** Il faut alors l'API DNS de
`visibilitycam.com`, donc héberger **toute** la zone `visibilitycam.com` chez
Cloudflare. C'est un déménagement à faire avec soin (encadré en fin de guide).

**Interdit : `*.visibilitycam.com` directement sur une app.** Elle avalerait tous
les noms non déclarés du domaine, y compris les futurs projets.

## Étape 2 — DNS et jeton d'API (Cloudflare)

1. Ajouter `monsaas.com` dans Cloudflare et changer ses serveurs DNS chez le
   registrar, comme Cloudflare l'indique.
2. Créer les enregistrements, **nuage gris** (DNS only) :
   - `A  monsaas.com    → IP du VPS`
   - `A  *              → IP du VPS`
3. *My Profile → API Tokens → Create Token → Edit zone DNS*. Permissions
   `Zone · DNS · Edit` et `Zone · Zone · Read`, limité à la zone `monsaas.com`.
   Noter le jeton, ainsi que le **Zone ID** affiché sur la page d'accueil du
   domaine.

## Étape 3 — Le compose de l'app

Le conteneur exposé à nginx-proxy (l'app FrankenPHP, ou le nginx de l'app) :

```yaml
    environment:
      VIRTUAL_HOST: monsaas.com,*.monsaas.com
      VIRTUAL_PORT: "8000"                    # le port HTTP interne de l'app
      LETSENCRYPT_HOST: "*.monsaas.com,monsaas.com"
      LETSENCRYPT_EMAIL: ops@visibilitycam.com
      ACME_CHALLENGE: DNS-01
      ACMESH_DNS_API_CONFIG: |-
        DNS_API: dns_cf
        CF_Token: ${CF_DNS_API_TOKEN}
        CF_Zone_ID: ${CF_ZONE_ID}
    networks: [ default, nginx-proxy ]
```

- `CF_DNS_API_TOKEN` et `CF_ZONE_ID` vont dans le `.env` du projet, jamais commité.
- Ces deux variables `ACME_*` sur le conteneur de l'app ne changent rien pour les
  autres sites : acme-companion les applique **uniquement** à ce conteneur, les
  autres continuent en HTTP-01.
- La documentation d'acme-companion montre `CF_Key` / `CF_Email` (clé globale).
  Préférez le jeton limité (`CF_Token`), que acme.sh accepte aussi.

**Vérifier, sur le serveur :**

```bash
$ docker logs -f nginx-proxy-acme 2>&1 | grep -i monsaas            # 2 à 5 min (propagation DNS)
$ curl -sv https://test123.monsaas.com -o /dev/null 2>&1 | grep -E 'subject|subjectAltName|SSL certificate verify'
#   subjectAltName attendu : *.monsaas.com et monsaas.com
```

Un certificat wildcard couvre **un seul niveau** : `client.monsaas.com`, pas
`a.client.monsaas.com`.

## Étape 4 — L'application

L'app reçoit le nom demandé dans l'en-tête `Host`, transmis tel quel par
nginx-proxy. Elle doit accepter n'importe quel sous-domaine et en déduire le client.

### Avec FrankenPHP (Caddy)

Comme le Core (`docker/frankenphp/Caddyfile`) : un site qui écoute **tous les
noms**, sans HTTPS (c'est nginx-proxy qui le gère).

```caddyfile
{
	auto_https off
	admin off
	frankenphp
}

:8000 {
	root * /app/public
	encode gzip zstd
	php_server
}
```

**Ne pas** mettre `monsaas.com` ou `*.monsaas.com` comme adresse de site Caddy :
Caddy essaierait d'obtenir lui-même des certificats, sur des ports qu'il n'a pas.

### Avec nginx + PHP-FPM

```nginx
server {
    listen 8000;
    server_name _;                       # tous les noms : le tri est fait par nginx-proxy
    root /var/www/html/public;
    index index.php;

    location / { try_files $uri $uri/ /index.php?$query_string; }

    location ~ \.php$ {
        include fastcgi_params;          # transmet HTTP_HOST (le sous-domaine) à PHP
        fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;
        fastcgi_param SERVER_NAME $host; # sinon SERVER_NAME vaut « _ »
        fastcgi_pass php:9000;
    }
}
```

### Côté Laravel

```php
// bootstrap/app.php
->withMiddleware(function (Middleware $middleware): void {
    // Refuse tout Host étranger (protection contre l'empoisonnement d'URL)
    $middleware->trustHosts(at: ['^(.+\.)?monsaas\.com$']);
    // Derrière nginx-proxy : schéma https et vraie IP depuis X-Forwarded-*
    $middleware->trustProxies(at: ['10.0.0.0/8', '172.16.0.0/12', '192.168.0.0/16']);
})
```

```php
// routes/web.php — résolution du client par sous-domaine
Route::domain('{tenant}.'.config('app.tenant_domain'))->group(function () {
    // $tenant = 'client1' pour client1.monsaas.com
});
```

`app.tenant_domain` vient d'une variable d'environnement (par exemple
`TENANT_DOMAIN=monsaas.com`). Elle permet au staging d'utiliser son propre domaine.
Avec un paquet de multi-tenancy (stancl/tenancy…), utiliser son identification par
sous-domaine.

| Réglage | Valeur |
| --- | --- |
| `APP_URL` | `https://monsaas.com` |
| `SESSION_DOMAIN` | vide (`null`) : chaque client a sa session. `.monsaas.com` seulement pour partager une connexion entre sous-domaines |
| `SANCTUM_STATEFUL_DOMAINS` (si SPA) | `monsaas.com,*.monsaas.com` |

**Créer un client = une ligne en base**, rien d'autre. Le DNS wildcard, le
certificat wildcard et `VIRTUAL_HOST` couvrent déjà tous les noms.

### Staging du SaaS

Utiliser un second domaine ou un sous-niveau couvert par son propre wildcard, par
exemple `*.monsaas-staging.com`. Même configuration, avec `TENANT_DOMAIN` différent.

## Domaines personnalisés des clients (`boutique.client.com`)

Ici, le domaine appartient au client : pas de wildcard possible. Trois options, à
choisir selon le volume :

| Option | Principe | Pour |
| --- | --- | --- |
| **1. Déclaration par client** | Le client crée un CNAME vers `monsaas.com`. On ajoute son nom à `VIRTUAL_HOST` et `LETSENCRYPT_HOST` du conteneur, puis on redéploie : certificat HTTP-01 automatique | quelques clients ; limite de 100 noms par certificat |
| **2. Cloudflare for SaaS** (« Custom Hostnames ») | Cloudflare émet et renouvelle les certificats des domaines clients à la périphérie, et envoie le trafic au serveur. Activable par API depuis l'app | volume moyen à élevé (100 premiers domaines gratuits, puis payant) |
| **3. Proxy à certificats à la demande** (Caddy `on_demand_tls`) | Un proxy qui obtient le certificat au premier accès, après accord de l'app. Demande de lui confier les ports 80/443, aujourd'hui tenus par nginx-proxy | gros volume — changement d'infrastructure à étudier à part |

L'option 1 marche dès aujourd'hui. Pour 2 ou 3, mieux vaut partir de votre app
existante (voir ci-dessous).

## Votre app existante (sur GitLab)

Pour que je l'adapte au standard, j'ai besoin de voir comment elle crée ses
sous-domaines aujourd'hui. Deux façons :

1. **Miroir vers GitHub (recommandé).** Dans GitLab : *Settings → Repository →
   Mirroring repositories*. URL `https://github.com/<vous>/<app>.git`, direction
   **Push**, mot de passe = un jeton GitHub (*Settings → Developer settings → Fine-grained
   tokens*, droit *Contents: Read and write* sur ce dépôt). Créer avant un dépôt
   **privé** vide sur GitHub. Me donner ensuite son nom : je pourrai l'ajouter à la
   session.
2. **Copier les fichiers clés** dans la conversation, secrets retirés :
   - `docker-compose*.yml` et `Dockerfile` ;
   - la configuration nginx ou Caddy ;
   - `.env.example` ;
   - le code qui crée un client (contrôleur, service, job) et celui qui le
     reconnaît (middleware, routes) ;
   - comment le DNS et les certificats sont gérés aujourd'hui.

## Encadré — déplacer `visibilitycam.com` chez Cloudflare (si nécessaire)

Un enregistrement oublié = un site qui disparaît. Dans l'ordre :

1. Exporter la zone complète chez le registrar (fichier de zone, ou capture de
   toutes les lignes).
2. Faire l'inventaire (guide 1, `--ct` compris) et le comparer à la zone exportée.
3. Ajouter le domaine dans Cloudflare. L'import automatique ne voit pas tout :
   **compléter à la main** depuis l'export (MX, TXT/SPF/DKIM, CNAME…). Tout en nuage
   gris.
4. Baisser le TTL chez le registrar à 300 s, 24 h avant.
5. Changer les serveurs DNS chez le registrar. Vérifier aussitôt chaque nom de
   l'inventaire avec `dig +short <nom> @1.1.1.1`.
6. Garder l'ancienne zone telle quelle 48 h chez le registrar, pour pouvoir revenir
   en arrière en remettant les anciens serveurs DNS.
