# Démarrage rapide : mettre mon projet sur le serveur

Pour un développeur qui n'a jamais touché au serveur. Compter environ une heure la
première fois. Les commandes sont écrites sous leur forme courte (`vps-deploy`, `vps-hosts`…), installée par la plateforme
(guide 3) ; la forme longue, `/app/vps-platform/bin/deploy.sh`, fait exactement la même chose. Les mots inconnus sont dans le [glossaire](03-glossaire.md) ;
l'image d'ensemble est dans les [schémas](01-schemas.md).

## Ce que vous allez obtenir

- `https://mon-projet-staging.visibilitycam.com`, mis à jour **tout seul** à chaque
  push sur la branche du staging (celle que le projet déclare dans `platform.env` :
  `main` par défaut ; `develop` pour Chantal et Wilmanager) ;
- `https://mon-projet.visibilitycam.com`, mis à jour **quand vous le décidez**, avec
  la version testée en staging ;
- le HTTPS, des sauvegardes chiffrées, un retour arrière en une commande, et les
  journaux dans Grafana (pour un backend).

## 1. Choisir un nom libre

Sur le serveur :

```bash
vps-hosts --free mon-projet.visibilitycam.com
vps-hosts --free mon-projet-staging.visibilitycam.com
```

Les deux doivent répondre `libre`. Sinon, choisir un autre nom : en minuscules,
sans point.

## 2. Ajouter 3 fichiers à votre dépôt

Selon votre projet, copier depuis `templates/` (le [README des modèles](../templates/README.md) dit lequel choisir) :

| Mon projet est… | Fichiers à copier | Renommer en |
| --- | --- | --- |
| Laravel avec **PostgreSQL** | `compose.laravel.yaml`, `platform.env`, `env.platform.production.example` et `env.platform.staging.example` | `compose.prod.yaml`, `platform.env`, à fusionner dans le `.env` de chaque environnement |
| Laravel avec **MySQL ou MariaDB** | `compose.laravel-mysql.yaml` (le reste comme ci-dessus) | `compose.prod.yaml` |
| React, Vite, Angular, Vue (site statique) | `frontend/Dockerfile.spa`, `frontend/nginx-spa.conf`, `frontend/40-runtime-env.sh`, `frontend/compose.frontend.yaml`, `frontend/platform.env` | `compose.frontend.yaml` → `compose.prod.yaml` |
| Next.js | `frontend/Dockerfile.nextjs`, `frontend/compose.frontend.yaml` (variante B), `frontend/platform.env` avec `BUILD_PER_ENV=1` | idem |
| Autre backend web (Node, Python, Go…) | `compose.web.yaml`, `platform.env` | `compose.prod.yaml` |

Dans ces fichiers, remplacer `mon-saas` / `mon-site` / `mon-front` par le nom de
votre projet, **partout**, y compris dans les noms de services (`mon-saas-db` →
`mon-projet-db`). Jamais de service nommé `app`, `db` ou `redis` : le
[contrat](05-contrat-projet.md) explique pourquoi (clause C3). Chaque fichier explique
ses réglages en commentaire.

Votre projet a déjà un `Dockerfile` ? Gardez-le. Il suffit que :
- le conteneur web écoute sur un port HTTP (`VIRTUAL_PORT`) ;
- l'image contienne `curl` ou `wget`, pour le contrôle de santé.

À vérifier sur votre poste :

```bash
docker compose -f compose.prod.yaml --env-file .env.example config -q    # pas d'erreur = OK
```

Puis commit et push.

## 3. Préparer le serveur (une fois par projet)

```bash
# 1. Accès en lecture au dépôt, avec le compte qui déploie (`deployer`) :
#    - GitHub : clé de déploiement + alias SSH « github-mon-projet » (guide 3, étape 0) ;
#    - GitLab : clé de déploiement du dépôt, lue par le compte `deployer` (exemple de Chantal : `docs/DEPLOIEMENT.md` du projet).
#    Jamais d'URL https:// : sous cron ou en pipeline, personne ne tape de mot de passe.
# 2. Un dossier par environnement, chacun clone de la branche qu'il suit. Le dossier est libre ; nos projets
#    utilisent /app/APPS/<PROJET>/{staging,prod} (les exemples de cette page disent /app/mon-projet).
mkdir -p /app/mon-projet && cd /app/mon-projet
git clone -b <branche-du-staging> git@github-mon-projet:<compte>/mon-projet.git staging     # GitLab : git@gitlab.com:<groupe>/mon-projet.git
git clone -b <branche-du-staging> git@github-mon-projet:<compte>/mon-projet.git prod
# Le nom du fichier de chaque environnement est celui de platform.env (ENV_FILE_STAGING, ENV_FILE_PROD ; défauts : .env.staging et .env).
# Chantal et Wilmanager ont choisi .env.staging et .env.prod.
cp staging/.env.example staging/.env.staging     # puis le remplir (valeurs de TEST)
cp prod/.env.example prod/.env                   # puis le remplir (valeurs de PRODUCTION)
```

**Règle d'or** : jamais les mêmes secrets en staging et en production. Les
variables propres à la plateforme (`DEPLOYMENT`, `APP_PUBLIC_HOST`, `BACKUP_*`…) sont
expliquées dans `templates/env.platform.production.example` (production) et `templates/env.platform.staging.example` (staging).

## 4. Premier déploiement

```bash
cd /app/mon-projet/staging && vps-deploy check staging   # contrôle seul, rien n'est modifié
cd /app/mon-projet/staging && vps-deploy watch    # build + staging
# vérifier https://mon-projet-staging.visibilitycam.com
cd /app/mon-projet/prod && vps-deploy promote     # production (taper « oui »). Si platform.env déclare BRANCH_PROD, la version doit déjà être fusionnée dans cette branche
```

Si `deploy.sh` refuse, il dit pourquoi : nom déjà pris, service inconnu, nom en
conflit avec un autre projet, image absente, contrôle de santé en échec… **Rien n'a
été cassé** : corriger dans le dépôt, vérifier avec `vps-deploy check staging`,
pousser.

## 5. Staging automatique

Deux voies, **une seule à la fois** (jamais les deux) :

- **le pipeline GitLab** (recommandé) : copier un [modèle de pipeline](../templates/gitlab-ci/README.md) ; chaque push sur la branche du staging la déploie, un bouton met en production ;
- **une ligne cron** ([guide 7](../guides/07-staging-automatique.md)) : chaque merge sur la branche du staging arrive en staging en moins de 2 minutes.

Quelle branche pour quel environnement : le projet le déclare dans `platform.env` ([les branches](reference/branches-et-fusions.md)).

## Au quotidien

| Je veux… | Commande (sur le serveur) |
| --- | --- |
| Voir ce qui tourne | `cd /app/mon-projet/prod && vps-deploy status` |
| Mettre en production | `cd /app/mon-projet/prod && vps-deploy promote` |
| Annuler la dernière mise en production | `cd /app/mon-projet/prod && vps-deploy rollback prod` |
| Voir les journaux | Grafana → *Applications*, ou `docker logs <conteneur> --tail 100` |
| Déployer une autre branche en staging | `cd /app/mon-projet/staging && vps-deploy build origin/ma-branche`, puis `vps-deploy up staging <sha affiché>` |
| Sauvegarder maintenant | `cd /app/mon-projet/prod && vps-deploy backup prod` (envoyée sur S3 comme la nocturne ; à faire avant une migration risquée) |
| Vérifier mon projet | `vps-deploy check prod` (lecture seule), puis `vps-audit` et la section de mon projet |
| Changer une valeur d'un fichier d'environnement | éditer le `.env` de l'environnement (après une copie), puis `vps-deploy up <env> <version courante>` : **un `restart` ne la relit pas** ([détail](reference/modifier-une-valeur.md)) |
| Prouver qu'une copie (base, fichiers) est exacte | `vps-fingerprint db <conteneur> <base>` et `vps-fingerprint files <volume>`, source puis copie, comparés avec `diff` ([guide 20](../guides/20-migrer-une-application-existante.md)) |

## Ce qu'il ne faut jamais faire

- `docker compose up` à la main **sans** `-p <projet>-<env>` et `--env-file <le fichier de cet environnement>` : vous
  créeriez un second projet vide à côté du vrai. Passez par `deploy.sh`, ou par `scripts/ops.sh` du projet quand il en a un.
- Ajouter `ports:` à un service. Tout passe par nginx-proxy.
- Écrire `VIRTUAL_HOST=` dans un fichier `.env` : il serait chargé dans **tous** les
  conteneurs du projet, et chacun se déclarerait comme site. Écrire
  `APP_PUBLIC_HOST=` dans le `.env`, et `VIRTUAL_HOST: ${APP_PUBLIC_HOST}`
  seulement sur le conteneur web du compose (c'est ce que font les modèles).
- Mettre une base de données sur le réseau `nginx-proxy` ou `observability`.
- Réutiliser un sous-domaine sans `vps-hosts.sh --free`.
- Committer un `.env`.
- Modifier `platform.env` sur le serveur : il se change par un commit.
- Faire `git pull`, `git merge` ou `git commit` dans un clone de `/app/<projet>/<env>`, ou y modifier un fichier suivi par git : le clone appartient à `deploy.sh`, `vps-deploy check` le
  refuse ([clones et droits](reference/clones-et-droits.md)).
- Appliquer une valeur modifiée par un simple `restart` : le conteneur garde son ancien environnement ; c'est `vps-deploy up`.
- Laisser le runner GitLab du serveur prendre les jobs sans tag : du code de merge request s'exécuterait sur le serveur ([pipeline GitLab](reference/pipeline-gitlab.md)).
- Supprimer un volume (`docker volume rm`, `down -v`) en production. C'est là que
  sont les données.
