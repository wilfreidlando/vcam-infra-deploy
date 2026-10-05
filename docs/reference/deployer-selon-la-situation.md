# Déployer : quoi faire selon la situation et selon l'environnement

> Une page pour répondre à « **je suis dans telle situation, qu'est-ce que je fais, avec quelle commande, et qu'est-ce que ça change ?** ». Elle renvoie aux guides pour le détail.
> Elle s'applique à **tous** les projets. Chaque projet a en plus sa propre fiche, `docs/DEPLOIEMENT.md` ([modèle](../../templates/docs-projet/DEPLOIEMENT.md)). Retour au [sommaire](../README.md).

## 1. Les environnements en un tableau

| | **dev** (facultatif) | **staging** | **production** | **plusieurs productions** (`prod`, `prodeu`…) |
| --- | --- | --- | --- | --- |
| Rôle | Intégration d'une branche de travail | **Valider** la version exacte qui ira en production | Servir les utilisateurs | Une production par client ou région |
| Dossier sur le serveur | `/app/<projet>/dev` | `/app/<projet>/staging` | `/app/<projet>/prod` | `/app/<projet>/<nom>` |
| Fichier d'environnement | `.env.dev` | `.env.staging` | `.env` | `.env.<nom>` |
| Version qui s'y trouve | une branche (`BRANCH_DEV`) | `main` (`STAGING_BRANCH`), **suivie automatiquement** | **celle du staging**, jamais construite en production | chacune **la sienne**, indépendante |
| Qui la déploie | automatique (`deploy.sh watch dev`) | automatique (`deploy.sh watch`) | **une personne**, jamais automatique : `deploy.sh promote` | `deploy.sh promote --env <nom>` |
| Secrets | propres | **propres, jamais ceux de la production** | propres | **propres à chaque production** |
| Sauvegarde | non | **non** (`BACKUP_DISABLED=1`) | **oui, chaque nuit, sur S3** | oui, un dossier S3 chacune |
| Données | jetables | jetables (une copie de la production **seulement pour une répétition**, jamais laissée) | réelles | réelles |
| Étiquette de supervision | `deployment=dev` | `deployment=staging` | `deployment=prod` | `deployment=<nom>` |

**Sans staging** (profil B) : une seule ligne, la production ; `deploy.sh promote origin/main` construit sur place. Voir les [profils de projet](profils-de-projet.md).

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
| `deploy.sh status` | Version courante et précédente de chaque environnement, conteneurs | non |
| `deploy.sh build [ref] [env]` | Construit l'image d'un commit | construit une image |
| `deploy.sh up <env> <version>` | Déploie une version déjà construite (aussi : recréer les conteneurs après un changement de `.env`) | **oui** |
| `deploy.sh watch [env]` | Staging automatique : construit et déploie si la branche a bougé | **oui** (staging) |
| `deploy.sh promote [version] [-y] [--env <nom>]` | Production : l'image testée en staging | **oui** (production) |
| `deploy.sh rollback <env>` | Remet la version précédente | **oui** |
| `deploy.sh backup [env]` | Une sauvegarde maintenant, envoyée sur S3 | crée une copie sur S3 |
| `deploy.sh obs-sync [--remove]` | Publie (ou retire) les tableaux et alertes du projet | écrit dans l'arbre de Grafana |

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
