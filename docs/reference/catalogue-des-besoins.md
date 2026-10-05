# Catalogue des besoins : ce que la plateforme offre, ce que le projet doit fournir

> La plateforme ne fait rien « par magie » : chaque service qu'elle rend demande **quelque chose au projet**. Cette page est la
> carte de ces échanges. Pour chaque service : ce qu'on obtient, ce que le projet doit fournir, comment vérifier, et où le voir
> dans le [projet pilote](../../guides/18-le-projet-pilote-skills-devops.md). Retour au [sommaire](../README.md).

Légende : ✅ disponible aujourd'hui · 🟡 disponible mais à brancher · 🔜 prévu (chantier en préparation).

## 1. Mise en ligne

| Service | Ce qu'on obtient | Ce que le projet doit fournir | Comment vérifier | Dans le pilote |
| --- | --- | --- | --- | --- |
| ✅ **HTTPS et nom public** | Certificat Let's Encrypt automatique, routage par `nginx-proxy` | `VIRTUAL_HOST`, `LETSENCRYPT_HOST`, `VIRTUAL_PORT` **sur le seul conteneur web**, qui rejoint le réseau `nginx-proxy`. Jamais de `ports:` | `curl -sI https://<nom>/` ; `deploy.sh check` | `skills-devops-web` |
| ✅ **Déploiement avec retour arrière** | Build par commit, migrations, santé, retour automatique | `compose.prod.yaml` avec `image: <app>:${IMAGE_TAG}`, `platform.env` (`HEALTH_SERVICE`, `HEALTH_CMD`, `MIGRATE_SERVICE`, `MIGRATE_CMD`), une route de santé qui répond 200 | `deploy.sh check <env>` | `platform.env` |
| ✅ **Staging puis production** | La production reçoit **exactement** l'image testée en staging | Un `.env.staging` et un `.env` **distincts** (secrets différents), même compose | `deploy.sh status` | `.env.*.example` |
| 🟡 **Staging automatique** | `main` se déploie en staging tout seul | Une branche `STAGING_BRANCH` ; une ligne de cron `deploy.sh watch` posée par le responsable de la plateforme | `crontab -l` de `root` | à poser |
| ✅ **Noms sans collision** | Aucun projet ne peut en détourner un autre | Services nommés `<app>-web`, `<app>-db`, `<app>-redis` (au minimum ceux publiés sur un réseau partagé) | `deploy.sh check` (bloquant) | compose |

## 2. Données

| Service | Ce qu'on obtient | Ce que le projet doit fournir | Comment vérifier | Dans le pilote |
| --- | --- | --- | --- | --- |
| ✅ **Sauvegarde chiffrée** | Dump chaque nuit et avant chaque promotion, chiffré AES-256, 7 copies locales | Un service `backup` (image de l'agent) avec les variables du moteur (`PGHOST`… ou `MYSQL_*`), `BACKUP_PASSPHRASE`, `BACKUP_NAME` | `docker exec <projet>-<env>-backup-1 ls -l /backups` | service `backup` |
| ✅ **Copie hors serveur** | La même sauvegarde sur S3 | `BACKUP_S3_ENDPOINT` (avec `https://`), `BACKUP_S3_BUCKET`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_DEFAULT_REGION` dans le `.env` | Le message `uploaded to s3://…` ; liste du bucket | `.env` de production |
| ✅ **Restauration prouvée** | La base revient à l'état exact de la sauvegarde (PostgreSQL, MySQL, MariaDB) | La phrase de chiffrement **conservée hors du serveur** ; un exercice mensuel | [Exercice de restauration](../runbooks/exercice-de-restauration.md) | premier exercice du 2026-10-04 |
| ✅ **Santé du conteneur de sauvegarde** | `docker ps` et l'audit signalent une sauvegarde qui cesse de tourner | Un healthcheck « une copie de moins de 36 h existe » sur `backup` | `docker ps` | service `backup` |

## 3. Voir ce qui se passe

| Service | Ce qu'on obtient | Ce que le projet doit fournir | Comment vérifier | Dans le pilote |
| --- | --- | --- | --- | --- |
| ✅ **Journaux dans Grafana** | Recherche dans les journaux de tous les projets, par application, déploiement, service | Trois labels sur chaque service à observer : `observability.enable`, `observability.app`, `observability.deployment` | Grafana, Explore, `{app="<app>"}` | `x-app` |
| 🟡 **Niveau des journaux** (erreurs, avertissements) | Panneaux « Erreurs » et « Avertissements », filtre par `level` | Écrire les journaux en **JSON** (Laravel : `LOG_STDERR_FORMATTER=Monolog\Formatter\JsonFormatter`, sans code) | L'étiquette `level` a des valeurs dans Loki | dans le dépôt du pilote |
| 🟡 **Métriques de l'application** | Courbes, calculs, alertes | `/metrics` au format Prometheus, **réservé au réseau privé** (refuser tout ce qui porte `X-Forwarded-For`) ; `observability.metrics.port` ; le web seul sur le réseau `observability`. **Fichiers prêts à copier : [modèle Laravel](../../templates/laravel-observabilite/README.md)** | `up{app="<app>"}` vaut 1 | `MetricsController` et `OnlyFromPrivateNetwork` du pilote |
| 🟡 **Traces** | Le trajet d'une requête | Variables `OTEL_*` vers `http://observability-alloy:4318` ; le web sur le réseau `observability` | Explore, source Tempo | non prévu |
| ✅ **Métriques du serveur** | Processeur, mémoire, swap, disque, charge, **sans toucher aux projets** | Rien : c'est la plateforme qui le collecte (`node-exporter`) | Grafana, Plateforme, « Serveur — vue d'ensemble » | plateforme |
| ✅ **Alertes génériques du serveur** (disque, mémoire, swap, charge, serveur plus observé) | E-mail quand un seuil est franchi | Rien côté projet | Alerting, dossier Plateforme | plateforme |
| ✅ **Métriques par conteneur** (consommation, redémarrages en boucle) | Voir quel projet consomme, être prévenu d'une boucle | Rien côté projet (cAdvisor, [ADR-0065](../adr/0065-supervision-du-serveur-node-exporter.md)) | Grafana, Plateforme, « Conteneurs » | plateforme |
| ✅ **Disponibilité et certificats des sites** (vus du serveur) | Prévenu quand un site ne répond plus ou qu'un certificat va expirer | Le **site doit figurer dans la liste** `prometheus/targets/sites.yml` (par le responsable de la plateforme) et avoir une route de santé | Grafana, Plateforme, « Sites » | `/up` |
| ✅ **Alerte « sauvegarde absente »** | Prévenu si plus aucune copie n'est envoyée sur S3 | Les labels `observability.*` sur le conteneur `backup` | Alerting, groupe `sauvegardes` | service `backup` |
| 🟡 **Alerte de disponibilité vue de l'extérieur** | Prévenu si le serveur entier tombe | Une URL publique de santé (`/up`) ; une sonde chez un service externe | Le service externe | [guide 8](../../guides/08-surveillance-externe.md) |

Règle : **ne jamais** mettre la base, Redis ni un conteneur PHP-FPM sur le réseau `observability`.

## 4. Conformité et exploitation

| Service | Ce qu'on obtient | Ce que le projet doit fournir | Comment vérifier |
| --- | --- | --- | --- |
| ✅ **Audit** | Un rapport CRITIQUE / ATTENTION / INFO de tout le serveur | `restart: unless-stopped`, limite mémoire, rotation des journaux, healthcheck, image taguée, pas de `ports:` | `vps-audit.sh` |
| ✅ **Inventaire** | L'état réel du serveur, sans secret | Un `platform.env` commité | `vps-inventory.sh` |
| ✅ **Accès git sans mot de passe** | `deploy.sh` ne s'arrête jamais sur un identifiant | Une clé de déploiement SSH en lecture seule par dépôt, alias `<forge>-<app>` | `deploy.sh check` |
| ✅ **Secrets hors du dépôt** | Aucune fuite par `git add` | `.env` et `.env.staging` ignorés par git, mode `600` sur le serveur | `ls -l`, `git status` |

## 5. Comment lire cette page pour un nouveau projet

1. Cocher ce qu'on veut : tout ce qui est ✅ est **demandé par le contrat** ; les 🟡 sont des **options à décider**.
2. Pour chaque ligne cochée, relire la colonne « Ce que le projet doit fournir » : c'est la liste du travail.
3. Partir du [modèle](../../templates) et du [pilote](../../guides/18-le-projet-pilote-skills-devops.md), pas d'une page blanche.
4. Faire valider par `deploy.sh check`, puis `vps-audit.sh`.
