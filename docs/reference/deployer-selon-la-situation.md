# Déployer : quoi faire selon la situation et selon l'environnement

> Une page pour répondre à « **je suis dans telle situation, qu'est-ce que je fais, avec quelle commande, et qu'est-ce que ça change ?** ». Elle renvoie aux guides pour le détail.
> Elle s'applique à **tous** les projets. Chaque projet a en plus sa propre fiche, `docs/DEPLOIEMENT.md` ([modèle](../../templates/docs-projet/DEPLOIEMENT.md)). Retour au [sommaire](../README.md).

## 1. Les environnements en un tableau

| | **dev** (facultatif) | **staging** | **production** | **plusieurs productions** (`prod`, `prodeu`…) |
| --- | --- | --- | --- | --- |
| Rôle | Intégration d'une branche de travail | **Valider** la version exacte qui ira en production | Servir les utilisateurs | Une production par client ou région |
| Dossier sur le serveur | `/app/<projet>/dev` | `/app/<projet>/staging` | `/app/<projet>/prod` | `/app/<projet>/<nom>` |
| Fichier d'environnement | `.env.dev` | `.env.staging` | `.env` | `.env.<nom>` |
| Version qui s'y trouve | une branche (`BRANCH_DEV`) | la branche **choisie par le projet** (`BRANCH_STAGING`, par défaut `main`), **suivie automatiquement** | **celle du staging**, jamais construite en production ; si le projet déclare `BRANCH_PROD`, seulement ce qui est **déjà dans cette branche** | chacune **la sienne**, avec sa propre branche (`BRANCH_<NOM>`) |
| Qui la déploie | automatique (`deploy.sh watch dev`) | automatique (`deploy.sh watch`) | **une personne**, jamais automatique : `deploy.sh promote` | `deploy.sh promote --env <nom>` |
| Secrets | propres | **propres, jamais ceux de la production** | propres | **propres à chaque production** |
| Sauvegarde | non | **non** (`BACKUP_DISABLED=1`) | **oui, chaque nuit, sur S3** | oui, un dossier S3 chacune |
| Données | jetables | jetables (une copie de la production **seulement pour une répétition**, jamais laissée) | réelles | réelles |
| Étiquette de supervision | `deployment=dev` | `deployment=staging` | `deployment=prod` | `deployment=<nom>` |

**Sans staging** (profil B) : une seule ligne, la production. Le projet déclare sa branche (`BRANCH_PROD=main`) et `deploy.sh promote` construit `origin/main` sur place. Voir les [profils de projet](profils-de-projet.md).

### Les branches : le projet choisit, la plateforme n'impose rien

| Le projet veut… | Il écrit dans `platform.env` | Ce qui se passe |
| --- | --- | --- |
| `develop` pour le staging, `main` pour la production | `BRANCH_STAGING=develop` et `BRANCH_PROD=main` | Le staging suit `develop`. Pour promouvoir, la version validée doit **d'abord être fusionnée dans `main`** ; la production reçoit alors l'**image du staging**, sans rien reconstruire |
| `main` pour les deux, sans étape de fusion | `BRANCH_STAGING=main`, pas de `BRANCH_PROD` | Le staging suit `main` ; la production reçoit ce que le staging a validé, sans contrainte de branche |
| Une production **sans staging** | `ENVIRONMENTS=prod` et `BRANCH_PROD=main` | `deploy.sh promote` construit `origin/main` sur place ; l'image n'a été validée par aucun staging |
| **Plusieurs productions** | `PROD_ENVIRONMENTS="prod prodeu"`, `BRANCH_PROD=main`, `BRANCH_PRODEU=release` | Chaque production a sa branche ; `promote --env <nom>` dit laquelle |

**Le passage staging → production**, dans tous les cas : `deploy.sh promote` déploie **l'image exacte** construite pour le staging (étiquette = commit) ; si elle n'existe pas, il **refuse** au lieu de reconstruire. Il écrit « même image que staging : rien n'est reconstruit »
dans le journal. Seule exception, annoncée dans le journal : `BUILD_PER_ENV=1`, pour un front dont l'image intègre la configuration de l'environnement. `deploy.sh status` et `deploy.sh check` disent, pour chaque environnement, **quelle branche il suit**.

## 2. Selon la situation

| Je veux… | Je fais | Commande (sur le serveur) | Qui | Coupure | Retour arrière |
| --- | --- | --- | --- | --- | --- |
| **Créer un nouveau projet** | Choisir le modèle, le remplir, préparer **un `.env` par environnement**, contrôler, déployer le staging puis la production | [`templates/README.md`](../../templates/README.md), puis `deploy.sh check staging`, `deploy.sh watch`, `deploy.sh promote` | le responsable du projet | aucune (nouveau) | `docker compose -p <projet>-<env> down` (sans `-v`) |
| **Mettre au standard un projet déjà en production** | Le [guide 16](../../guides/16-mettre-un-projet-au-standard.md) et le [contrat § 4](../05-contrat-projet.md) : **ne jamais renommer** le projet Docker ni un volume, **répéter les migrations sur une copie** | `deploy.sh check prod` (ne change rien), puis le guide | le responsable du projet, avec le responsable de la plateforme | quelques secondes à 3 min | l'ancien dossier conservé ([cas du Core](../../guides/06-core-au-standard.md)) |
| **Livrer une nouvelle version du code** | Merge sur la branche du staging, recette, puis promotion | staging : automatique ou `deploy.sh watch` ; production : `deploy.sh promote` | développeur, puis responsable | quelques secondes en production | `deploy.sh rollback <env>` ; **automatique** si la santé échoue |
| **Changer une variable** d'environnement | Éditer le `.env` **de l'environnement concerné** sur le serveur, recréer les conteneurs | `deploy.sh up <env> <version courante>` (voir `deploy.sh status`) | le responsable du projet | quelques secondes | remettre l'ancienne valeur, même commande |
| **Changer `compose.prod.yaml` ou `platform.env`** | Un commit : ils sont lus **dans le commit déployé** ; jamais de modification à la main sur le serveur | comme une livraison | le responsable du projet | comme une livraison | `deploy.sh rollback <env>` |
| **Livrer une migration risquée** | Une **sauvegarde à la main avant**, puis la livraison. D'abord le staging **avec une copie de la production** | `deploy.sh backup <env>` puis `deploy.sh promote` | le responsable du projet | selon la migration | restauration depuis S3 : `restore.sh <env> s3://…` |
| **Changer de version de base de données** | Staging d'abord, avec une copie restaurée de la production ; tester la restauration **sur cette version** | [sauvegardes](sauvegardes.md) | le responsable du projet | selon le cas | restauration |
| **Ajouter une production** (client, région) | `PROD_ENVIRONMENTS` dans `platform.env`, un dossier, un `.env.<nom>`, **ses propres secrets et son nom public** | `deploy.sh promote --env <nom>` | le responsable du projet | aucune (nouvelle) | `deploy.sh rollback <nom>` |
| **Ajouter un environnement dev** | `ENVIRONMENTS="dev staging prod"`, `BRANCH_DEV` | `deploy.sh watch dev` | le responsable du projet | aucune | `docker compose -p <projet>-dev down` |
| **Mettre à jour la plateforme** (outils, supervision) | [Guide 11](../../guides/11-depot-plateforme.md) : `git pull`, puis **recréer les composants dont la configuration a changé** ; jamais tout d'un coup | `git -C /app/vps-platform pull --ff-only` | le responsable de la plateforme | aucune pour les sites | `git reset --hard <ancien commit>` |
| **Donner à un projet ses tableaux et alertes** | `observability/` dans **son** dépôt ; publié après la production | `deploy.sh obs-sync` ([guide 19](../../guides/19-observabilite-de-mon-projet.md)) | le responsable du projet | aucune | `deploy.sh obs-sync --remove` |
| **Faire surveiller un site** | L'ajouter à la liste des sites sondés (fichier local au serveur) | éditer `observability/prometheus/targets/sites.yml` | le responsable de la plateforme | aucune | retirer la ligne |
| **Changer les branches** du staging ou de la production | Le contenu **d'abord** sur la nouvelle branche, puis `platform.env` **et** `.gitlab-ci.yml` dans le même commit ; jamais sur le serveur | [les branches d'un projet](branches-et-fusions.md) | le responsable du projet | aucune | revert du commit |
| **Fusionner `develop` dans `main`** sans perdre de contenu | Répéter la fusion dans un espace de travail séparé ; méfiance de la fusion « qui garde la nôtre » | [fusionner sans rien perdre](branches-et-fusions.md#4-fusionner-sans-perdre-de-contenu) | le développeur | aucune | — |
| **Déployer en production sans passer par le staging** | Projet sans staging : `promote origin/<branche>` ; avec staging : `build <sha> staging` puis `promote <sha>` ; **dernier recours** | [déployer sans staging](branches-et-fusions.md#5-déployer-une-version-sans-passer-par-le-staging) | le responsable du projet | quelques secondes | `deploy.sh rollback <env>` |
| **Brancher le pipeline GitLab** d'un projet | Copier un modèle, ajouter le runner SSH sans les jobs sans tag, créer les clones | [modèles de pipeline](../../templates/gitlab-ci/README.md), [pipeline GitLab](pipeline-gitlab.md) | le responsable de la plateforme | aucune | retirer le fichier |
| **Un job GitLab reste « pending »** | Le runner est-il en ligne, a-t-il le tag, accepte-t-il les jobs sans tag ? | [runbook](../runbooks/runner-gitlab-hors-service.md) | le responsable de la plateforme | aucune | — |
| **`vps-deploy check` refuse un clone** (« modifiés à la main », « dossier non inscriptible ») | Lire le message : il donne la commande de réparation | [clones et droits](clones-et-droits.md) | le responsable de la plateforme | aucune | — |
| **Migrer une application en service** vers un projet de la plateforme (même nom de domaine) | Geler, copier, **prouver**, ouvrir ; l'ancienne reste intacte | [guide 20](../../guides/20-migrer-une-application-existante.md) | le responsable de la plateforme | 10 à 15 minutes | l'ancienne installation, restée intacte |
| **Prouver qu'une copie est exacte** (base, fichiers) | Les empreintes de la source, puis de la copie, comparées | `vps-fingerprint db <conteneur> <base>`, `vps-fingerprint files <volume>` | le responsable du projet | aucune | — |
| **Ajouter `www.`** (ou tout nom) à un projet | DNS d'abord, puis `APP_VIRTUAL_HOSTS` et `APP_CERT_HOSTS`, puis `up` ; redirection dans le nginx du projet | [`www` et DNS](domaines-et-dns.md#wwwdomaine--un-nom-de-plus-à-déclarer-trois-fois) | le responsable du projet | aucune | retirer le nom |
| **Revenir à la version d'avant** | Remettre la version précédente du code | `deploy.sh rollback <env>` | le responsable du projet | quelques secondes | — |
| **Revenir aux données d'avant** | Restaurer une sauvegarde ; la base est **remplacée** | `restore.sh <env> s3://<bucket>/<préfixe>/<projet>-<env>/<fichier>` ([exercice](../runbooks/exercice-de-restauration.md)) | le responsable du projet | le site est arrêté 1 à 2 min | refaire une sauvegarde avant |
| **Retirer un projet** | Arrêter sans détruire, retirer son observabilité, **garder les volumes jusqu'à la décision** | `docker compose -p <projet>-<env> down` (**sans `-v`**), `deploy.sh obs-sync --remove` | le responsable de la plateforme | le site s'arrête | `docker compose … up -d` |

## 3. Un environnement, pas à pas

### Staging

1. Le staging **suit la branche** : un merge suffit ; `deploy.sh watch` (planifié) construit l'image **une seule fois**, applique les migrations, vérifie la santé et revient seul en arrière si elle échoue.
2. Le responsable fait la **recette** sur l'adresse du staging.
3. **Le staging n'est pas sauvegardé** : ses données sont jetables. Il ne reçoit **jamais** les secrets de la production.

### Production

1. **Contrôle** : `deploy.sh check prod` (ne change rien).
2. **Migration risquée ?** Une sauvegarde à la main : `deploy.sh backup prod`.
3. **Promotion** : `cd /app/<projet>/prod && deploy.sh promote` — l'image **exacte** du staging, jamais reconstruite ; confirmer à l'invite.
4. **Vérifier** : `deploy.sh status`, la route de santé en HTTPS, Grafana → Plateforme → **Application — vue d'ensemble** → le projet.
5. **Si la santé échoue** : retour automatique à la version précédente. **Première promotion d'un projet déjà en production** : pas de version précédente connue, retour **manuel** depuis l'ancien dossier conservé.

### Plusieurs productions

Chaque production se promeut **séparément** (`--env`), a sa version, son `.env`, ses secrets, son nom public, son dossier S3 de sauvegarde. Sans `--env`, l'outil **refuse de choisir** à votre place.

## 4. Les commandes de `deploy.sh`, aide-mémoire

| Commande | Ce qu'elle fait | Change quelque chose ? |
| --- | --- | --- |
| `deploy.sh check [env]` | Contrôle avant déploiement : accès git, `platform.env`, compose, noms | **non** |
| `deploy.sh status` | Version courante et précédente de chaque environnement, **la branche qu'il suit**, conteneurs | non |
| `deploy.sh build [ref] [env]` | Construit l'image d'un commit | construit une image |
| `deploy.sh up <env> <version>` | Déploie une version déjà construite (aussi : recréer les conteneurs après un changement de `.env`) | **oui** |
| `deploy.sh watch [env]` | Staging automatique : construit et déploie si la branche a bougé | **oui** (staging) |
| `deploy.sh promote [version] [-y] [--env <nom>]` | Production : l'image testée en staging, **à condition qu'elle soit dans la branche de production** si le projet en déclare une ; sans staging, construit la branche déclarée | **oui** (production) |
| `deploy.sh rollback <env>` | Remet la version précédente | **oui** |
| `deploy.sh backup [env]` | Une sauvegarde maintenant, envoyée sur S3 | crée une copie sur S3 |
| `deploy.sh obs-sync [--remove]` | Publie (ou retire) les tableaux et alertes du projet | écrit dans l'arbre de Grafana |
| `deploy.sh where` | Où est la plateforme, quelle version (aucun projet requis) | **non** |

**Le chemin.** Partout, `deploy.sh` s'écrit `/app/vps-platform/bin/deploy.sh`, ou simplement `vps-deploy` une fois les [commandes courtes](../../guides/03-installer-plateforme.md#étape-1--cloner-la-plateforme) installées (une fois, en root).

Variables utiles : `BACKUP_BEFORE_DEPLOY=always` (dans `platform.env`) pour une sauvegarde avant **chaque** déploiement ; `SKIP_MIGRATIONS=1`, `SKIP_BACKUP=1` pour les cas exceptionnels, avec l'accord du responsable.

## 5. Les règles qui ne changent jamais

| Règle | Pourquoi |
| --- | --- |
| La production n'est **jamais** déployée automatiquement | Une erreur ne doit pas atteindre les utilisateurs toute seule |
| La production reçoit **l'image testée en staging** | On déploie ce qu'on a validé |
| **Jamais** les secrets d'un environnement dans un autre | Une fuite du staging ne compromet pas la production |
| **Jamais** `docker compose down -v`, `volume rm`, `prune` | Ce sont les données |
| **Jamais** renommer le projet Docker ni un volume d'un projet en production | Une nouvelle base vide serait créée à côté de la vraie |
| **Aucune modification à la main** de `platform.env` ou du compose sur le serveur | Elle empêcherait le déploiement suivant ; tout passe par un commit |
| Les sauvegardes **vivent sur S3**, jamais sur le serveur | Un disque qui se remplit en silence fait tomber tous les sites |

Tout ce qui précède est vérifié par les tests : [`tests/README.md`](../../tests/README.md).
