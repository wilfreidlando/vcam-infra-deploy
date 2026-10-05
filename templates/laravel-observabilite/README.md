# Modèle : observabilité d'une application Laravel

> Ce que **le projet** fournit pour être pleinement observé : des journaux en JSON, une route `/metrics` réservée au réseau
> privé, les labels du compose, une sauvegarde dont la santé se voit. Le projet pilote
> [`skills-devops`](../../guides/18-le-projet-pilote-skills-devops.md) est l'exemple vivant de ces fichiers.
> Retour au [catalogue des besoins](../../docs/reference/catalogue-des-besoins.md).

## Ce que ce dossier contient

| Fichier | Où le copier | Rôle |
| --- | --- | --- |
| [`OnlyFromPrivateNetwork.php`](OnlyFromPrivateNetwork.php) | `app/Http/Middleware/` | Refuse (404) toute requête venue d'Internet : elle porte `X-Forwarded-For`, ajouté par `nginx-proxy` |
| [`MetricsController.php`](MetricsController.php) | `app/Http/Controllers/` | Écrit les métriques au format Prometheus. **À adapter** : le préfixe `PREFIX`, puis vos chiffres métier |
| [`bootstrap-app.snippet.php`](bootstrap-app.snippet.php) | à fusionner dans `bootstrap/app.php` | Déclare la route `/metrics`, **hors** du groupe `web` (ni session, ni cookie à chaque collecte) |
| [`MetricsTest.php`](MetricsTest.php) | `tests/Feature/` | Garde les deux garanties : servi au réseau privé, **introuvable** depuis Internet |

## Les cinq étapes

| # | Quoi | Où | Comment vérifier |
| --- | --- | --- | --- |
| 1 | **Journaux en JSON** : `LOG_STDERR_FORMATTER=Monolog\Formatter\JsonFormatter` (avec `LOG_CHANNEL=stderr`) | `.env` et `.env.staging` du serveur, et les exemples du dépôt | Grafana → Explore → Loki : l'étiquette `level` a des valeurs |
| 2 | **Labels** `observability.enable`, `observability.app`, `observability.deployment` sur chaque service à observer | `compose.prod.yaml` ([modèle](../compose.laravel.yaml)) | `{app="<projet>"}` dans Loki |
| 3 | **Métriques** : les quatre fichiers ci-dessus, le label `observability.metrics.port: "8000"` et le réseau `observability` sur le **web seul** | le dépôt du projet | `up{app="<projet>"}` vaut 1 dans Prometheus |
| 4 | **Sauvegarde observée** : labels et `healthcheck` sur le service `backup` ([modèle](../compose.laravel.yaml)) | `compose.prod.yaml` | `docker ps` : `healthy` ; alerte « aucune sauvegarde depuis 36 h » |
| 5 | **Le site dans la liste des sondes** | `observability/prometheus/targets/sites.yml`, **sur le serveur** (responsable de la plateforme) | Tableau « Sites » |

**Vérifier chaque signal séparément** (journaux, métriques, alertes) : voir les journaux ne prouve pas que les métriques arrivent
([retour d'expérience](../../docs/retours-experience/2026-10-05-metriques-du-pilote-absentes-reseau-alloy.md)).

## Règles de sécurité (non négociables)

- **Jamais de `/metrics` public.** Le middleware est la protection : ne pas le retirer, et garder `MetricsTest`.
- **Jamais la base, Redis ni un conteneur PHP-FPM sur le réseau `observability`** : seul le conteneur web y est.
- Ne mettre dans les métriques **aucun secret ni donnée personnelle** : ce sont des nombres, pas des enregistrements.
- Des métriques **utiles** : ce qu'on voudrait voir en courbe ou sur quoi on veut être prévenu (paiements en attente, file bloquée),
  pas tout ce qui peut se compter.

## Adapter pour un autre framework

Le principe est identique : une route `/metrics` qui répond en `text/plain; version=0.0.4`, **refusée si `X-Forwarded-For` est présent**.
Le reste (labels, réseau, sauvegarde) ne dépend pas du langage.
