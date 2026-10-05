# 6. Passer le Core au standard : staging + production

**Résultat** :
- `core-system-staging.visibilitycam.com` : copie isolée du Core, mise à jour
  automatiquement (guide 7) ;
- `core-system.visibilitycam.com` : production, mise à jour **uniquement** par
  promotion manuelle de l'image validée en staging.

> **Avant de commencer : où est le standard ?** Les fichiers du standard (`platform.env`, `compose.prod.yaml`, `Makefile`, `.env.staging.example`) doivent être **sur la branche que le
> serveur peut récupérer** (publiée sur GitHub). Sinon, ni le staging ni la promotion ne peuvent les lire. Choisir aussi **quelle branche** le staging construit (`STAGING_BRANCH` dans
> `platform.env`) : `main` pour une standardisation seule, une autre branche pour valider d'abord du code non encore en production.
>
> **Le Core n'a, au départ, aucune sauvegarde** : l'étape 1 n'est donc pas une précaution de plus, c'est la **seule** copie qui existe jusqu'à ce que le service `backup` tourne.

**Coupure de la production** : quelques secondes, au moment de la promotion
(étape 6). Les noms des conteneurs, le réseau `core-system-internal` et les volumes
(donc la base) **ne changent pas**.

Remplacez `core-system.visibilitycam.com` par le nom actuel du Core s'il est
différent : c'est la valeur de `VIRTUAL_HOST` dans son `.env` actuel, à renommer
en `CORE_PUBLIC_HOST` (étape 3).

## Prérequis

- Guides 1 à 4 faits : inventaire, DNS wildcard, plateforme installée, MEGA S4 testé.
- Le nom du staging est libre :
  ```bash
  $ /app/vps-platform/bin/vps-hosts.sh --free core-system-staging.visibilitycam.com
  ```
- Retrouver le dossier actuel du Core :
  ```bash
  $ docker inspect core-system-app --format '{{index .Config.Labels "com.docker.compose.project.working_dir"}}'
  ```
  Ce chemin est appelé `<ANCIEN>` ci-dessous.

## Étape 1 — Filet de sécurité (avant toute chose)

```bash
$ docker exec core-system-postgres sh -c 'pg_dump -U "$POSTGRES_USER" -Fc "$POSTGRES_DB"' \
    > /root/core-avant-standard-$(date +%F).dump
$ chmod 600 /root/core-avant-standard-*.dump         # lisible par root seulement
$ ls -lh /root/core-avant-standard-*.dump          # non vide ; la base est petite, quelques centaines de Ko compressés suffisent
$ docker exec -i core-system-postgres pg_restore -l < /root/core-avant-standard-*.dump | head   # lisible : doit lister des tables
$ chmod 600 <ANCIEN>/.env                           # secrets de paiement : jamais lisibles par tous (clause C10)
$ cp -p <ANCIEN>/.env /root/core-env-avant-standard
```

## Étape 2 — Dossiers

```bash
$ mkdir -p /app/core-system
$ mv <ANCIEN> /app/core-system/prod                       # le checkout actuel devient « prod »
$ git -C /app/core-system/prod remote set-url origin git@github-vcam-core:wilfreidlando/vcam-core-system.git
$ git clone git@github-vcam-core:wilfreidlando/vcam-core-system.git /app/core-system/staging
$ cd /app/core-system/prod && git fetch && git status     # doit être propre (pas de fichiers modifiés)
```

Déplacer le dossier n'arrête pas les conteneurs. Le nom du projet Docker
(`core-system-prod`) est écrit dans `compose.prod.yaml`, il ne dépend pas du
dossier.

## Étape 3 — Compléter le `.env` de production

Ouvrir `/app/core-system/prod/.env` et ajouter la section « VPS standard » de
`.env.production.example` (en fin de fichier). Valeurs à générer :

```bash
$ openssl rand -hex 32          # → TRUSTED_PROXY_TOKEN
$ openssl rand -base64 32       # → BACKUP_PASSPHRASE (+ gestionnaire de mots de passe !)
```

Les variables `BACKUP_S3_*` et `AWS_*` viennent du guide 4.

Garder **inchangés** :
- `APP_KEY` : la changer rendrait illisibles les secrets chiffrés en base ;
- `DB_*` ;
- la valeur du nom public. **Renommer** seulement la ligne `VIRTUAL_HOST=…` en
  `CORE_PUBLIC_HOST=…`, même valeur. Sinon, les conteneurs app, horizon, scheduler
  et backup, qui chargent tout le `.env`, se déclareraient eux aussi à nginx-proxy.
  L'ancien nom reste lu en secours, mais l'audit le signalera.

Ne pas définir `IMAGE_TAG` : la plateforme le gère.

## Étape 4 — Créer le `.env.staging`

```bash
$ cd /app/core-system/staging
$ cp .env.staging.example .env.staging
$ nano .env.staging
```

| Variable | Valeur |
| --- | --- |
| `APP_KEY` | **nouvelle** : `echo "base64:$(openssl rand -base64 32)"` |
| `DB_PASSWORD`, `TRUSTED_PROXY_TOKEN`, `BACKUP_PASSPHRASE` | **nouvelles**, jamais celles de la production |
| `CORE_ENVIRONMENT` | `sandbox` |
| `WAHA_*` | une session WhatsApp de **test** (un numéro dédié), jamais celle des clients |
| Clés S3 | un **dossier S3 de test** (`BACKUP_S3_PREFIX` distinct), ou `BACKUP_DISABLED=1` si le staging ne doit pas être sauvegardé : sans l'un des deux, l'agent **refuse** de sauvegarder (les sauvegardes ne vivent jamais sur le disque du serveur) |

Les applications MyCoolPay ne se configurent pas ici. Elles s'enregistrent dans la
console du staging, avec les clés **sandbox** de MyCoolPay (étape 5).

## Étape 5 — Premier staging

```bash
$ cd /app/core-system/staging
$ make staging-deploy          # construit l'image du dernier commit de main, la déploie, vérifie la santé
$ make deploy-status
```

Puis préparer le staging :

```bash
$ docker exec -it core-system-staging-app php artisan identity:create-operator \
    vous@visibilitycam.com "Votre nom" platform_admin    # mot de passe affiché une fois
```

Dans `https://core-system-staging.visibilitycam.com/admin` : créer une organisation
et un projet, puis enregistrer l'application MyCoolPay **sandbox**.

**Recette** : un paiement sandbox, une notification de test, un webhook. Ne passez à
l'étape 6 que si tout est bon.

## Étape 5 bis — Répéter les migrations sur les données réelles (fortement recommandé)

Le staging part d'une base **vide** : ses migrations passent toujours. La production a **des données** qu'une migration peut transformer ou supprimer. Avant de promouvoir,
**restaurer une copie de la production dans le staging** (`restore.sh`, ou la copie de l'étape 1), puis y **appliquer les migrations de la nouvelle version** :

```bash
$ docker exec core-system-staging-app php artisan migrate:status | grep -c Pending        # combien vont passer
$ docker exec core-system-staging-app php artisan migrate --force                         # la répétition
```

Comparer ensuite le **nombre de lignes par table avant et après** : seules les tables qu'une migration est censée toucher doivent changer. Lire le code de toute migration qui
**supprime** des lignes. Où chercher les migrations ? Un projet modulaire les range **dans chaque module**, pas seulement dans `database/migrations` :

```bash
$ git diff --name-status <version en production> <nouvelle version> -- '*migrations*'
```

**Attention aux données personnelles** : une copie de la production dans le staging contient des données réelles. Mettre en pause les services qui agissent vers l'extérieur
(files d'attente, planificateur), garder l'environnement en `sandbox`, et supprimer la copie après la répétition.

## Étape 6 — Promotion en production

En heure creuse :

```bash
$ cd /app/core-system/prod
$ make prod-promote            # tape « oui » pour confirmer
```

**Avant de promouvoir**, prendre une sauvegarde à la main : `/app/vps-platform/bin/deploy.sh backup` (envoyée sur S3, aucune copie ne reste sur le serveur). `deploy.sh` n'en prend pas de lui-même
au déploiement (la nocturne est le filet), sauf si `BACKUP_BEFORE_DEPLOY=always` est dans `platform.env`.

Le script :
1. applique les migrations avec la nouvelle image ;
2. recrée les conteneurs ;
3. vérifie `/health/ready` pendant 2 minutes ;
4. revient automatiquement à la version précédente en cas d'échec.

Si le script s'arrête avec « noms d'hôte déjà utilisés par un autre projet », c'est
la protection du guide 1. Rien n'a été modifié : corriger le nom en cause, puis
relancer.

## Étape 7 — Vérifier

```bash
$ make deploy-status
$ curl -fsS https://core-system.visibilitycam.com/health/ready
$ /app/vps-platform/bin/vps-audit.sh | sed -n '/■ core-system-prod/,/^$/p'    # aucune ligne CRITIQUE ou ATTENTION
```

Puis, dans la console admin de production : connexion, liste des paiements, détail
d'un paiement.

## Ancienne observabilité

Si l'ancienne stack d'observabilité tournait dans le projet `core-system-prod`,
l'étape 6 a retiré ses conteneurs. Après vérification, **la personne qui gère le serveur** peut supprimer ses anciens
volumes (la plateforme, elle, ne supprime jamais un volume) :

```bash
$ docker volume ls | grep core-system-prod_ | grep -E 'loki|tempo|prometheus|grafana|alloy'
$ docker volume rm <ces volumes>
```

## En cas de problème

| Situation | Action |
| --- | --- |
| La promotion échoue avant la bascule (sauvegarde, migration) | Rien n'a basculé. Lire l'erreur, corriger, relancer |
| Le retour automatique a eu lieu | La production tourne sur l'ancienne version. Les migrations éventuelles sont restées |
| Il faut revenir aux données d'avant | `cd /app/core-system/prod && /app/vps-platform/bin/restore.sh prod <fichier de sauvegarde sur S3>` |
| Ultime recours | `docker exec -i core-system-postgres sh -c 'pg_restore --clean --if-exists --no-owner -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < /root/core-avant-standard-<date>.dump` (attention : `--clean` ne supprime pas ce qui a été créé **après** la copie ; l'outil `restore.sh` le fait, voir le [retour d'expérience](../docs/retours-experience/2026-10-05-la-restauration-ne-remplacait-pas-la-base.md)) |
| Quand tout est bon | Supprimer la copie `/root/core-avant-standard-*.dump` : à partir de là, les sauvegardes vivent sur S3 |
