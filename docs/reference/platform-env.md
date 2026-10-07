# Référence de `platform.env`

> Chaque clé que `bin/deploy.sh` lit, avec sa valeur par défaut, son effet et qui doit la régler. Le modèle à copier est [`templates/platform.env`](../../templates/platform.env). Retour au [sommaire](../README.md).

`platform.env` est **commité à la racine du projet**, sans aucun secret (les secrets sont dans `.env` et `.env.staging`, sur le serveur seulement). Il est relu **dans le commit déployé** : changer une clé demande un commit,
jamais une modification à la main sur le serveur. Une clé retirée du fichier ne survit pas : elle reprend sa valeur par défaut.

## 1. Les clés du projet

### Identité et fichiers

| Clé | Défaut | Rôle |
| --- | --- | --- |
| `APP_NAME` | **obligatoire** | Nom du projet, unique sur le serveur. Les projets Docker deviennent `<APP_NAME>-staging`, `<APP_NAME>-prod`. **Ne jamais le changer** : `deploy.sh` refuse un changement de nom, qui créerait de nouveaux volumes et une base vide à côté de la vraie |
| `COMPOSE_FILE` | `compose.yaml` | Fichier compose du projet (les modèles utilisent `compose.prod.yaml`) |
| `ENV_FILE_PROD` | `.env` | Fichier d'environnement de la production |
| `ENV_FILE_STAGING` | `.env.staging` | Fichier d'environnement du staging |
| `ENV_FILE_<ENV>` | `.env.<env>` | Fichier d'un environnement supplémentaire (par exemple `ENV_FILE_DEV`) |

### Environnements

| Clé | Défaut | Rôle |
| --- | --- | --- |
| `ENVIRONMENTS` | `staging prod` | Les environnements du projet. Sans staging : `prod`. Plusieurs productions : `staging prod prodeu`. Noms en minuscules et chiffres seulement. [Profils](profils-de-projet.md) |
| `PROD_ENVIRONMENTS` | `prod` | Ceux de `ENVIRONMENTS` qui sont des **productions** : jamais déployées automatiquement, promues à la main (`vps-deploy promote --env <nom>`). Chacun doit figurer dans `ENVIRONMENTS` |
| `BRANCH_STAGING` (ancien nom : `STAGING_BRANCH`) | `main` | La branche que `vps-deploy watch` suit pour le staging. **Le projet choisit** : `develop`, `main`, `integration`… |
| `BRANCH_<ENV>` | — | La branche suivie par un autre environnement non production (par exemple `BRANCH_DEV=develop`) |
| `BRANCH_PROD`, `BRANCH_<PROD>` | — (aucune contrainte) | **Optionnel : une garde sur une production.** `promote` refuse une version qui n'est pas déjà dans `origin/<branche>` : on fusionne d'abord ce que le staging a validé, puis on promeut. L'image reste **celle du staging**. Chaque production a sa propre branche (`BRANCH_PRODEU=release`). **Sans staging**, c'est la branche que `promote` construit quand on ne donne pas de version (**jamais devinée** : sans cette déclaration, `promote` sans version refuse). La garde est lue dans la version **déjà déployée en production** : elle s'active à la première promotion qui la porte, et un commit ne peut pas s'en dispenser en la retirant (sa propre promotion est contrôlée par la garde en vigueur) |

### Santé et migrations

| Clé | Défaut | Rôle |
| --- | --- | --- |
| `HEALTH_SERVICE` | `app` | Le service dans lequel `HEALTH_CMD` s'exécute |
| `HEALTH_CMD` | vide | Commande qui doit sortir en succès quand l'application peut servir. **Vide : la santé n'est pas vérifiée et il n'y a donc aucun retour arrière automatique** |
| `HEALTH_TIMEOUT` | `120` | Secondes d'attente de la santé avant de conclure à l'échec (et de revenir en arrière) |
| `MIGRATE_SERVICE` | vide | Le service qui exécute les migrations, avec l'image de la nouvelle version |
| `MIGRATE_CMD` | vide | La commande de migration, lancée **avant** la bascule. Vide : aucune migration |

### Sauvegarde

| Clé | Défaut | Rôle |
| --- | --- | --- |
| `BACKUP_SERVICE` | vide | Le service de l'agent `db-backup`. Requis pour `vps-deploy backup` et pour `restore.sh` |
| `BACKUP_CMD` | `backup.sh` | La commande exécutée dans ce service pour une sauvegarde à la demande |
| `BACKUP_BEFORE_DEPLOY` | `never` | `always` : une sauvegarde **avant chaque** déploiement de production (le déploiement est annulé si elle échoue). Par défaut aucune : la sauvegarde nocturne est le filet ([sauvegardes](sauvegardes.md)) |
| `DB_SERVICE` | `postgres` (pour `restore.sh`) | Le service de la base, que `restore.sh` **ne coupe pas** pendant une restauration |

### Images et supervision

| Clé | Défaut | Rôle |
| --- | --- | --- |
| `BUILD_PER_ENV` | `0` | `1` : une image **par environnement** (pour un front dont la construction intègre la configuration de l'environnement). Sans cela, l'image testée en staging est celle qui part en production |
| `OBS_BUNDLE` | `observability` | Le dossier du dépôt qui porte les tableaux et alertes **propres au projet** ([guide 19](../../guides/19-observabilite-de-mon-projet.md)). Publié après un déploiement de production réussi, ou par `vps-deploy obs-sync` |

## 2. Les réglages de l'hôte (variables d'environnement, pas des clés de `platform.env`)

Ils valent pour tous les projets du serveur et ne se règlent pas dans un projet.

| Variable | Défaut | Rôle |
| --- | --- | --- |
| `STATE_DIR` | `/var/lib/vps-platform` | Où `deploy.sh` garde la version courante et précédente de chaque environnement, et son journal |
| `NGINX_PROXY_CONTAINER` | `nginx-proxy` | Le conteneur dont `deploy.sh` contrôle la configuration (`nginx -t`) : un déploiement qui la rendrait invalide est traité comme un échec, parce que nginx garderait l'ancienne configuration pour **tous** les sites. Sans ce conteneur, le contrôle est ignoré |
| `KEEP_IMAGES` | `5` | Combien d'images récentes `deploy.sh` garde par service |
| `SKIP_BACKUP=1` | — | Passer outre la sauvegarde d'avant déploiement (cas exceptionnel, avec l'accord du responsable) |
| `SKIP_MIGRATIONS=1` | — | Passer outre les migrations (cas exceptionnel ; le retour arrière l'utilise aussi) |
| `SKIP_BRANCH_CHECK=1` | — | Promouvoir une version qui n'est pas dans la branche de production du projet (`BRANCH_<PROD>`) : une **exception**, consignée dans le journal, avec l'accord du responsable |
| `ALLOW_DIRTY_CLONE=1` | — | Laisser passer `check` malgré des **fichiers suivis par git modifiés à la main** dans le clone (l'image ne correspondra pas exactement au commit) : une **exception**, à ses risques, avec l'accord du responsable. Ne couvre pas un dossier de `.git` non inscriptible : celui-là se répare ([clones et droits](clones-et-droits.md)) |
| `OBS_GRAFANA_DIR` | `<plateforme>/observability/grafana` | Où `deploy.sh` publie les tableaux et alertes **du projet** (`obs-sync`). **À rediriger vers un dossier jetable dans le test d'un projet** : sinon ses fichiers restent dans l'arbre du clone de la plateforme et font échouer les tests de la plateforme |

`IMAGE_TAG` est fixé par `deploy.sh` (le SHA du commit) : ne pas le régler.

## 3. Ce qui est vérifié

`vps-deploy check <env>` contrôle, **sans rien changer** : l'accès git, que `platform.env` existe et que `APP_NAME` est défini, que le compose se charge, que les services nommés (`HEALTH_SERVICE`, `MIGRATE_SERVICE`,
`BACKUP_SERVICE`, `DB_SERVICE`) existent dans le compose, et qu'aucun nom de service privé du projet n'est aussi publié sur un réseau partagé par un autre projet ; **que les noms d'hôte du projet ne sont pas déjà pris** par un autre (`vps-hosts --check`) ; et **l'intégrité du clone** : un dossier de `.git` non inscriptible ou des fichiers suivis modifiés à la main sont **refusés**, les commits locaux et les fichiers d'un autre compte sont **signalés** ([clones et droits](clones-et-droits.md)). Les tests ([`tests/test-deploy.sh`](../../tests/test-deploy.sh), [`tests/test-templates.sh`](../../tests/test-templates.sh)) l'exercent sur chaque modèle.
