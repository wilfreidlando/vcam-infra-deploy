# Observabilité mutualisée du VPS

Une seule pile pour tous les projets du serveur, comme `nginx-proxy` :

- **Grafana** : l'interface, publiée via nginx-proxy sur `GRAFANA_HOST` ;
- **Loki** : les journaux ;
- **Tempo** : les traces ;
- **Prometheus** : les métriques ;
- **Alloy** : le seul collecteur, qui découvre les conteneurs par leurs labels Docker.

Décision : [ADR-0064](../docs/adr/0064-infrastructure-vps-staging-observabilite-mutualisee.md).

**Nouveau dans l'observabilité ?** Lire d'abord le [guide 17](../guides/17-comprendre-et-lire-grafana.md) : le rôle de
chaque service, ce qu'on voit dans Grafana et comment le lire.

```mermaid
graph LR
    subgraph P1["Projet A (ex. core-system prod)"]
        A1["app<br/>labels observability.*"]
        A2["horizon / scheduler"]
    end
    subgraph P2["Projet B (autre Laravel)"]
        B1["app<br/>labels observability.*"]
    end
    subgraph OBS["projet compose « observability »"]
        Alloy["observability-alloy<br/>découverte Docker (lecture seule)"]
        Loki[(Loki)]
        Tempo[(Tempo)]
        Prom[(Prometheus)]
        Graf["Grafana"]
    end
    A1 & A2 & B1 -. "stdout (socket Docker)" .-> Alloy
    Alloy -- "scrape /metrics<br/>(réseau observability)" --> A1 & B1
    A1 & B1 -- "OTLP :4318<br/>(réseau observability)" --> Alloy
    Alloy --> Loki & Tempo & Prom
    Graf --> Loki & Tempo & Prom
    NP["nginx-proxy (existant)"] --> Graf
```

**Rien n'est collecté sans consentement explicite** : un conteneur sans le label
`observability.enable=true` est ignoré, même s'il tourne sur le même serveur.

## Installation (une fois par serveur)

```bash
docker network create observability          # idempotent : ignorer « already exists »
cp observability/.env.example observability/.env   # puis le remplir
docker compose -f observability/compose.yaml --env-file observability/.env up -d
```

Aucune modification de nginx-proxy ni des autres projets : Grafana s'y déclare comme
n'importe quel site (`VIRTUAL_HOST` / `LETSENCRYPT_HOST`).

Ressources plafonnées : Loki 1 Go (`LOKI_MEMORY_LIMIT`), `cadvisor` 512 Mo (`CADVISOR_MEMORY_LIMIT`), `node-exporter` et `blackbox-exporter` 64 Mo, les autres
services 512 Mo chacun. Ce sont des plafonds, pas des réservations.

## Brancher un projet Laravel

### 1. Docker Compose du projet

Ajoutez le réseau `observability` et les labels **aux services à observer** :

```yaml
services:
  app:
    # …
    labels:
      observability.enable: "true"
      observability.app: "mon-saas"          # nom affiché dans Grafana
      observability.deployment: "prod"       # prod | staging | …
      observability.metrics.port: "8000"     # seulement si l'app expose /metrics
      # observability.metrics.path: "/metrics"   (défaut)
    networks: [default, observability]

  worker:
    # …
    labels:
      observability.enable: "true"
      observability.app: "mon-saas"
      observability.deployment: "prod"
    networks: [default, observability]

networks:
  observability:
    external: true
```

Les **journaux** sont lus par le socket Docker : le label suffit, aucun réseau
n'est requis (un conteneur sur plusieurs réseaux n'est collecté qu'une fois —
vérifié). Les **métriques** et les **traces** exigent le réseau `observability`.
Un projet est en général sur **plusieurs** réseaux (`nginx-proxy`, `observability`, son réseau privé) : Alloy les examine
tous (`match_first_network = false`) et ne scrute que celui qui s'appelle `observability`
([retour d'expérience](../docs/retours-experience/2026-10-05-metriques-du-pilote-absentes-reseau-alloy.md)).
Ne branchez jamais la base de données, Redis ni un conteneur **PHP-FPM** (FastCGI
sur le port 9000, sans authentification : quiconque le joint exécute du PHP) sur
ce réseau partagé : mettez-leur le label seul.

### 2. Journaux : JSON sur la sortie standard (aucune dépendance)

**Sans une ligne de code (Laravel récent)** : le canal `stderr` fourni par Laravel accepte un format par variable d'environnement.
Dans le `.env` du projet (c'est ce que fait le [projet pilote](../guides/18-le-projet-pilote-skills-devops.md)) :

```
LOG_CHANNEL=stderr
LOG_STDERR_FORMATTER=Monolog\Formatter\JsonFormatter
```

**Avec du code**, si vous voulez un canal à vous, dans `config/logging.php` :

```php
'stdout_json' => [
    'driver' => 'monolog',
    'handler' => Monolog\Handler\StreamHandler::class,
    'with' => ['stream' => 'php://stdout'],
    'formatter' => Monolog\Formatter\JsonFormatter::class,
    'level' => env('LOG_LEVEL', 'info'),
],
```

Puis `LOG_CHANNEL=stdout_json` dans le `.env` du projet.

Alloy lit le niveau (`level_name`) et en fait un label. Il conserve
`extra.correlation_id`, `extra.trace_id` et `extra.project_id` en métadonnées
cherchables. Une ligne non JSON passe telle quelle.

Pour retrouver une requête de bout en bout, ajoutez un identifiant de corrélation
dans `extra` (un processor Monolog qui lit `Context::get('correlation_id')`). C'est
exactement ce que fait le Core, voir `packages/support/src/Observability`.

### 3. Métriques (optionnel)

Exposez `/metrics` au format Prometheus. Par exemple avec un paquet comme
`spatie/laravel-prometheus`, ou une route maison sur le modèle de
`app/Http/Controllers/Observability/MetricsController.php`. Indiquez le port avec
`observability.metrics.port`.

Ne publiez pas `/metrics` sur Internet : refusez-le dans votre nginx, comme
`docker/nginx/prod/app.conf.template` le fait.

### 4. Traces (optionnel)

Envoyez l'OTLP/HTTP à `http://observability-alloy:4318`. Avec le SDK OpenTelemetry
PHP :

```dotenv
OTEL_SERVICE_NAME=mon-saas
OTEL_EXPORTER_OTLP_ENDPOINT=http://observability-alloy:4318
OTEL_EXPORTER_OTLP_PROTOCOL=http/json
```

### 5. Tableaux de bord

- **Applications → Applications — journaux (tous projets)** : filtres par
  application, déploiement et service, volume par niveau, recherche plein texte.
  Fonctionne pour tout projet branché, sans rien configurer.
- Un projet peut livrer ses propres tableaux de bord : déposez les JSON dans
  `grafana/dashboards/<Nom du projet>/`, puis redémarrez Grafana
  (`docker restart observability-grafana`). Ils apparaissent dans ce dossier.

## Le serveur lui-même (aucun projet à modifier)

La plateforme observe aussi **le VPS**, sans opt-in : `node-exporter` (un conteneur de 64 Mo) lit le système en
lecture seule (`/` monté en `/host:ro`), et Prometheus le scrute toutes les 30 s (`prometheus.yml`, job `node`). Il n'est
joignable que depuis le réseau privé de la pile.

| Ce qu'on voit | Où |
| --- | --- |
| Processeur, mémoire, swap, disque « / », charge | Grafana, dossier **Plateforme**, tableau **Serveur — vue d'ensemble** |
| Cinq alertes génériques : serveur plus observé, disque > 85 %, mémoire disponible < 10 %, swap > 50 %, charge > 2,5 par processeur | Grafana, **Alerting**, dossier **Plateforme** ([`generic-alerts.yaml`](grafana/provisioning/alerting/generic-alerts.yaml)) |

Ces alertes partent vers le point de contact par défaut (`core-oncall`, nom historique : il reçoit **toutes** les alertes). Chacune
a un délai (`for`) pour éviter le bruit. Les métriques **par conteneur** (consommation, redémarrages) viennent de cAdvisor, voir la section suivante et
l'[ADR-0065](../docs/adr/0065-supervision-du-serveur-node-exporter.md). Guide de lecture : [guide 17](../guides/17-comprendre-et-lire-grafana.md).

Vérifier : `up{job="node"}` vaut 1 dans Prometheus, et `node_load5` renvoie une valeur.

## Les conteneurs et les sites (aucun projet à modifier)

| Composant | Ce qu'il apporte | Où |
| --- | --- | --- |
| **cAdvisor** | Consommation (processeur, mémoire et sa limite, réseau) et **redémarrages de chaque conteneur Docker** du serveur | Tableau **Plateforme → Conteneurs** ; alertes « conteneur en boucle » et « proche de sa limite de mémoire » |
| **blackbox-exporter** | Les **sites publics** sondés depuis le serveur : en ligne ou non, délai, **expiration du certificat** | Tableau **Plateforme → Sites** ; alertes « site qui ne répond plus » et « certificat qui expire » |

**Déclarer les sites à sonder** : copier `prometheus/targets/sites.yml.example` en `prometheus/targets/sites.yml` **sur le serveur** (le fichier n'est pas commité :
c'est la liste des sites hébergés), y mettre l'adresse de santé de chaque site, avec ses étiquettes `app` et `deployment`. Prometheus relit le dossier toutes les
minutes, sans redémarrage. Une sonde ne remplace pas une [surveillance externe](../guides/08-surveillance-externe.md) : si le serveur entier tombe, rien ici ne le dit.

**Sauvegardes** : une alerte vérifie que les journaux des agents de production contiennent une ligne `uploaded to s3://…` au moins toutes les 36 h. Elle suppose que
le conteneur `backup` du projet porte les labels `observability.*` (le [pilote](../guides/18-le-projet-pilote-skills-devops.md) le fait).

**Mise en service progressive** (la charge du serveur est déjà élevée) : d'abord `node-exporter` et `blackbox-exporter`, puis `cadvisor` après avoir observé la charge. Voir
la [carte complète](../docs/reference/observabilite-carte-complete.md).

## Vérifier qu'un projet est bien branché

```bash
docker exec observability-grafana wget -qO- http://loki:3100/loki/api/v1/label/app/values
# → la liste doit contenir la valeur de observability.app
```

Dans Grafana → Explore → Prometheus : `up{app="mon-saas"}` vaut `1` si le scrape
fonctionne.

## Rétention

| Donnée | Durée | Réglage |
| --- | --- | --- |
| Journaux | 90 jours | `loki/config.yaml` (`retention_period`) |
| Traces | 30 jours | `tempo/config.yaml` (`block_retention`) |
| Métriques | 30 jours | `PROMETHEUS_RETENTION` |
