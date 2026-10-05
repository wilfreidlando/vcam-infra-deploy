# Le contrat d'un projet

**Ce document est la référence.** Il dit ce que tout projet hébergé sur le VPS doit
respecter, quel que soit son langage, qu'il soit nouveau ou déjà en production. Les
modèles (`templates/`), les outils (`bin/`) et les guides en découlent. En cas de
désaccord entre un de ces fichiers et ce document, c'est ce document qui fait foi,
et l'écart est un défaut à corriger.

Version du contrat : **2.4** (historique en fin de document).

## Comment lire ce document

Chaque clause dit **quoi**, **pourquoi**, et **qui le vérifie**. Une règle que
personne ne vérifie finit par être oubliée. Les niveaux de vérification :

| Niveau | Qui vérifie | Effet |
| --- | --- | --- |
| **BLOQUANT** | `deploy.sh`, avant tout changement (contrôle avant déploiement) | Le déploiement est refusé, **rien n'est modifié**, le message dit quoi corriger |
| **CRITIQUE / ATTENTION / INFO** | `vps-audit.sh`, en lecture seule (et l'inventaire `vps-inventory.sh`, qui l'inclut) | Signalé dans le rapport d'audit |
| **CI** | GitHub Actions sur chaque pull request de la plateforme | Une modification de la plateforme ne se merge pas si un test échoue |
| **MODÈLE** | Les modèles de `templates/` l'appliquent déjà | À vérifier en revue si l'on s'écarte du modèle |

Le contrôle avant déploiement se lance aussi seul, **sans rien modifier**, sur
n'importe quel projet, y compris en production :

```bash
cd /app/<projet>/prod && /app/vps-platform/bin/deploy.sh check prod
```

## 1. Ce que contient le dépôt du projet

| Fichier | Commité ? | Rôle |
| --- | --- | --- |
| `compose.prod.yaml` | oui | La pile, **identique** pour tous les environnements |
| `platform.env` | oui | Comment `deploy.sh` déploie le projet : nom, services, contrôle de santé, migrations, sauvegarde, branches |
| `Dockerfile` | oui | L'image ; la même pour tous les environnements (sauf `BUILD_PER_ENV=1`) |
| `.env.example`, `.env.staging.example`, `.env.production.example` | oui | La liste des variables, **sans aucune valeur secrète** |
| `.env`, `.env.staging` | **jamais** | Les secrets, uniquement sur le serveur, dans le dossier de chaque environnement |

## 2. Les clauses

### Exposition et réseau

| # | Clause | Pourquoi | Vérifié par |
| --- | --- | --- | --- |
| C1 | Le trafic entre **uniquement** par nginx-proxy (`VIRTUAL_HOST` + `LETSENCRYPT_HOST`, sur le seul conteneur web). Jamais de `ports:`. | Docker ouvre ses ports **avant** le pare-feu : un `ports:` publie sur Internet | Audit CRITIQUE |
| C2 | Base, cache, file : sur le réseau **privé** du projet uniquement. Seul le conteneur web rejoint `nginx-proxy`. | Sur un réseau partagé, tous les projets du VPS peuvent s'y connecter | Audit CRITIQUE |
| C3 | **Tous les services portent un nom propre au projet** : `<app>-web`, `<app>-db`, `<app>-redis`… Jamais `app`, `db`, `redis`, `web`. Les variables d'hôte (`DB_HOST`, `REDIS_HOST`…) utilisent ces noms. | Le conteneur web voit les noms de **tous** les projets branchés sur `nginx-proxy`. Si un autre y a laissé un `db`, Docker peut le choisir à la place du vôtre ([REX 2026-10-04](retours-experience/2026-10-04-premier-deploiement-skills-devops.md)) | **BLOQUANT** dès qu'un autre projet publie un de vos noms privés sur un réseau partagé · Audit ATTENTION pour un nom générique publié par plusieurs projets |

### Santé et déploiement

| # | Clause | Pourquoi | Vérifié par |
| --- | --- | --- | --- |
| C4 | Healthcheck sur le conteneur web et sur la base. Celui de la base passe **par le réseau** : `pg_isready -h 127.0.0.1`, `mariadb-admin ping -h 127.0.0.1`. | Au premier démarrage, l'image de base répond sur son socket local **avant** d'accepter les connexions réseau : la base paraît prête trop tôt et les migrations échouent ([REX](retours-experience/2026-10-04-premier-deploiement-skills-devops.md)) | Audit INFO (présence) · MODÈLE (par le réseau) |
| C5 | `platform.env` nomme des services qui **existent** dans le compose du même commit (`HEALTH_SERVICE`, `MIGRATE_SERVICE`, `BACKUP_SERVICE`, `DB_SERVICE`). | `deploy.sh` relit `platform.env` dans le commit déployé : renommer un service et `platform.env` dans le même commit est sûr ; les oublier l'un sans l'autre ne l'est pas | **BLOQUANT** |
| C6 | `platform.env` n'est **jamais modifié sur le serveur**. Tout réglage passe par un commit. | Une modification locale empêche `git checkout` du commit suivant et diverge du dépôt | **BLOQUANT** (le checkout échoue, rien n'est modifié) |
| C7 | Images taguées par commit (`image: <app>:${IMAGE_TAG:-latest}`). Staging et production utilisent le **même** compose et la **même** image. | Savoir ce qui tourne ; promouvoir exactement ce qui a été testé ; revenir en arrière | Audit INFO · `deploy.sh` (refuse un compose sans `${IMAGE_TAG}`) |
| C8 | `restart: unless-stopped`, une limite mémoire et une rotation des journaux sur chaque conteneur. | Les sites reviennent seuls ; une fuite ou un projet bavard ne fait pas tomber les autres | Audit ATTENTION |

### Accès au code et secrets

| # | Clause | Pourquoi | Vérifié par |
| --- | --- | --- | --- |
| C9 | Le serveur lit le dépôt **par sa clé de déploiement SSH** en lecture seule (alias `github-<app>`, [guide 3](../guides/03-installer-plateforme.md)). Jamais par HTTPS. | Le staging se déploie sous cron : personne n'est là pour taper un mot de passe. `deploy.sh` ne l'attend jamais, il échoue avec la correction | **BLOQUANT** (message donnant la commande `git remote set-url`) |
| C10 | Secrets dans `.env` / `.env.staging`, jamais commités ; **jamais les mêmes** en staging et en production. | Une fuite du staging ne compromet pas la production | Revue |
| C11 | Toute base a sa sauvegarde chiffrée hors serveur (`BACKUP_SERVICE`), restaurée une fois par mois ([exercice](runbooks/exercice-de-restauration.md)). Une restauration remet la base **dans l'état exact de la sauvegarde** (PostgreSQL, MySQL, MariaDB ; non atomique pour MySQL/MariaDB). **La sauvegarde nocturne est le filet** : `deploy.sh` n'en prend pas de lui-même au déploiement (`BACKUP_BEFORE_DEPLOY=always` pour en avoir une avant chaque déploiement) ; avant une migration risquée, on en prend une à la main (`deploy.sh backup`). **Les sauvegardes vivent sur S3, jamais sur le disque du serveur** : l'agent supprime la copie locale dès qu'elle est envoyée (seule une copie dont l'envoi a échoué reste, trois au plus) ; sans S3 configuré il **refuse** de sauvegarder, et un environnement volontairement non sauvegardé le déclare (`BACKUP_DISABLED=1`). Voir [Sauvegardes](reference/sauvegardes.md). | Le VPS est un point unique de défaillance ; un disque qui se remplit en silence fait tomber **tous** les sites | alerte « aucune sauvegarde envoyée depuis 36 h », alerte disque |
| C12 | **L'observabilité est proportionnée au projet** ([profils](reference/profils-de-projet.md)). Minimum de **tout** projet public : figurer dans la liste des sites sondés (disponibilité et certificat). Un backend ajoute les labels `observability.*` (journaux), puis, s'il le veut, `/metrics` privé. Un simple site web n'a besoin de rien de plus que la sonde. **Ses propres tableaux et alertes, un projet les livre dans son dépôt** (`observability/`, [guide 19](../guides/19-observabilite-de-mon-projet.md)) : la plateforme n'est jamais modifiée pour un projet. | Journaux et erreurs de tous les projets au même endroit, sans imposer à un site statique ce dont il n'a pas l'usage | Audit INFO |
| C13 | **Un projet déclare son profil dans `platform.env`** : `ENVIRONMENTS` et `PROD_ENVIRONMENTS`. Il peut n'avoir **aucun staging** (une production seule), ou **plusieurs productions**. Dans tous les cas : une production n'est **jamais** déployée automatiquement, chaque production a son dossier, son `.env` et **ses propres secrets**, et la promotion est une décision humaine. Détail : [profils de projet](reference/profils-de-projet.md). | Les projets ne sont pas tous faits pareil ; l'outil ne doit ni les forcer dans un moule ni perdre ses garde-fous | **BLOQUANT** (noms d'environnements valides, productions déclarées parmi les environnements) |

## 3. Les noms

Un seul nom, `APP_NAME` (dans `platform.env`), en minuscules, avec des tirets. Tout
le reste en dérive. Le connaître suffit pour tout retrouver.

| Élément | Nom | Exemple (`APP_NAME=skills-devops`) |
| --- | --- | --- |
| Services du compose | `<app>-web`, `<app>-db`, `<app>-redis`, `<app>-worker`… | `skills-devops-db` |
| Projet Docker d'un environnement | `<app>-<env>` (posé par `deploy.sh`) | `skills-devops-staging` |
| Réseau privé | `<app>-<env>-internal` | `skills-devops-staging-internal` |
| Conteneur | `<app>-<env>-<service>-1` | `skills-devops-prod-skills-devops-db-1` |
| Sous-domaines | `<app>.visibilitycam.com`, `<app>-staging.visibilitycam.com` | `skills-devops-staging.visibilitycam.com` |
| Dossiers sur le serveur | `/app/<app>/<env>` (un clone par environnement) | `/app/skills-devops/prod` |
| Clé de déploiement, alias SSH | `/root/.ssh/deploy_<app>`, `Host github-<app>` | `git@github-skills-devops:wilfreidlando/skills-devops.git` |
| État des déploiements, journal | `/var/lib/vps-platform/<app>/<env>/`, `…/<app>/deploy.log` | |
| Sauvegardes | `<app>-<env>-<date>-<motif>.dump.enc` | `skills-devops-prod-20261004T121553Z-pre-deploy-7e29f591a55d.dump.enc` |

`APP_NAME` ne change pas une fois en production : `deploy.sh` refuse un commit qui
le change, car ce serait un nouveau projet Docker avec de nouveaux volumes vides.

## 4. Appliquer le contrat à un projet déjà en production

Le but est de mettre le projet en conformité **sans perdre de données et sans coupure
non prévue**. Rien de ce qui suit ne touche la production avant l'étape 5.

1. **Mesurer, en lecture seule.**
   ```bash
   /app/vps-platform/bin/vps-inventory.sh > /root/inventaire.md  # tout le serveur, sans secret
   cd /app/<app>/prod && /app/vps-platform/bin/deploy.sh check prod   # ce projet
   ```
2. **Corriger dans le dépôt**, en partant des modèles : d'abord les BLOQUANT et
   CRITIQUE, puis le reste. Un seul commit peut tout corriger.
3. **Garder le nom du projet Docker.** Les volumes (les données) sont rattachés au
   projet Docker (`<app>-prod`) et au nom du volume, **pas** au nom des services.
   Choisir `APP_NAME` pour que `<APP_NAME>-prod` soit le nom actuel
   (`docker compose ls`), et ne pas renommer les volumes.
4. **Staging d'abord.** Déployer le commit en staging et vérifier. Si des services
   ont été renommés, `deploy.sh` refuse tant que l'ancien conteneur tient un volume.
   C'est voulu : deux bases sur les mêmes fichiers les corrompent. Supprimer
   l'ancien conteneur (`docker rm -f <conteneur>`, les volumes restent), puis
   relancer.
5. **Production, dans un créneau annoncé.** Même procédure. Si la base change de
   nom, la coupure dure de l'arrêt de l'ancien conteneur à la fin du contrôle de
   santé, soit une à deux minutes en général. Avant une migration risquée, prendre une sauvegarde à la main
   (`deploy.sh backup`).
6. **Vérifier** : `deploy.sh check prod`, puis `vps-audit.sh`. Le projet ne doit
   plus avoir aucune ligne BLOQUANT, CRITIQUE ni ATTENTION.

Les guides [5 (audit et conformité)](../guides/05-audit-et-conformite.md) et
[6 (le Core au standard)](../guides/06-core-au-standard.md) déroulent cette
procédure sur des cas réels.

## 5. Faire évoluer le contrat

Le contrat change quand la réalité montre un trou, en général à la suite d'un
incident. Une évolution n'est terminée que lorsque **les six points** sont faits,
dans le même ensemble de commits :

1. **Comprendre** : un retour d'expérience dans
   [`retours-experience/`](retours-experience/README.md) (pour un incident), ou une
   ADR (pour une décision sans incident).
2. **Rendre le défaut impossible ou visible** : un contrôle dans `deploy.sh`
   (BLOQUANT) quand il est certain que le déploiement échouerait ou abîmerait
   quelque chose ; sinon un constat dans `vps-audit.sh`.
3. **Le prouver** : un test dans `tests/` qui reproduit le défaut et montre qu'il est
   arrêté.
4. **Les modèles** de `templates/` appliquent la nouvelle règle.
5. **Ce document** (nouvelle clause, version du contrat) et la table des règles du
   [16 règles](reference/les-16-regles.md).
6. **Les projets existants** : lancer `deploy.sh check` et `vps-audit.sh` sur chacun,
   et noter les écarts restants dans le retour d'expérience, avec qui s'en occupe.

Un contrôle BLOQUANT ne doit jamais bloquer un projet sain. Le contrôle des noms
(C3) ne bloque donc qu'en cas de conflit **réel** sur le serveur. Un nom générique
sans conflit n'est pas bloqué, mais il reste un écart au contrat.

## Historique du contrat

| Version | Date | Changement | Origine |
| --- | --- | --- | --- |
| 1 | 2026-09 | 12 règles, audit en lecture seule, déploiement par promotion | [ADR-0064](adr/0064-infrastructure-vps-staging-observabilite-mutualisee.md) |
| 2 | 2026-10-04 | C3 (noms propres au projet, BLOQUANT), C4 (healthcheck de base par le réseau), C5-C6 (`platform.env` lu dans le commit déployé, cohérent, jamais modifié sur le serveur), C9 (clé de déploiement SSH, jamais d'attente de mot de passe) ; commande `deploy.sh check` | [REX 2026-10-04](retours-experience/2026-10-04-premier-deploiement-skills-devops.md) |
| 2.1 | 2026-10-05 | C11 précisée : la restauration remet la base dans l'état exact de la sauvegarde (PostgreSQL, MySQL, MariaDB), exercice mensuel avec table-témoin | [REX 2026-10-05](retours-experience/2026-10-05-la-restauration-ne-remplacait-pas-la-base.md) |
| 2.2 | 2026-10-05 | C11 : sauvegardes **sur S3 seulement**, plus de copies qui s'accumulent sur le disque ; C12 proportionnée au projet ; **C13** : profils de projet (sans staging, plusieurs productions, site simple) | [ADR-0067](adr/0067-profils-de-projet-et-sauvegardes-sur-s3-seulement.md) |
| 2.3 | 2026-10-05 | C11 : plus de sauvegarde automatique au déploiement (la nocturne est le filet, `deploy.sh backup` à la main avant une migration risquée) ; remplace l'obligation de l'ADR-0064 | demande de l'équipe, [ADR-0067](adr/0067-profils-de-projet-et-sauvegardes-sur-s3-seulement.md) |
| 2.4 | 2026-10-05 | C12 : un projet livre **ses propres tableaux et alertes dans son dépôt** (`observability/`), publiés par `deploy.sh` ; tableau générique « Application » pour tous | [ADR-0068](adr/0068-observabilite-portee-par-le-projet.md) |
