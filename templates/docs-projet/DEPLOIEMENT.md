<!--
MODÈLE — à copier dans le projet sous docs/DEPLOIEMENT.md, puis à remplir : remplacer chaque <…> et supprimer les lignes d'aide en italique.
Ce document est LA référence de déploiement du projet : quelqu'un qui n'a pas construit le projet doit pouvoir déployer, mettre à jour et revenir en
arrière avec lui seul. Aucune valeur secrète ici : des NOMS de variables et leur rôle, jamais leur contenu.
Les liens vers la plateforme sont absolus : ils continuent de marcher une fois le fichier copié dans le projet.
-->
# Déploiement de <projet>

> **Pour toute l'équipe.** Comment ce projet est déployé sur le VPS, environnement par environnement. À jour au **<AAAA-MM-JJ>**, version du contrat de la plateforme : **<2.x>**.
> La plateforme (outils, règles, runbooks) : <https://github.com/wilfreidlando/vcam-infra-deploy>. Profil de projet : **<A standard | B production seule | C plusieurs productions | D site simple>**
> ([profils](https://github.com/wilfreidlando/vcam-infra-deploy/blob/main/docs/reference/profils-de-projet.md)).

## 0. Démarrage rapide : vous arrivez sur ce projet

*Aide : quelques lignes, à remplir avec les vrais noms. C'est la première chose qu'une personne nouvelle lit.*

**Qui fait quoi.** <compte administrateur nominatif (groupes `docker` et de déploiement) pour lire, redémarrer, ouvrir un shell ; compte de déploiement, qui seul a la clé du dépôt et exécute `vps-deploy` ; actions réservées à root : dossiers et droits, sondes de supervision, redémarrage de Grafana, configuration du runner GitLab>.

**Où est quoi sur le serveur.** Un clone par environnement, avec son fichier de secrets : `/app/<projet>/<env>` (`.env.<env>`, droits 660) ; l'état du déploiement : `/var/lib/vps-platform/<projet>/` (`<env>/current`, `deploy.log`) ; la documentation de la plateforme, sur le serveur : `/app/vps-platform/docs/` (runbooks dans `docs/runbooks/`).

**Les commandes**, avec le **compte de déploiement**, depuis le **dossier de l'environnement** :

```bash
vps-deploy status                    # versions déployées
vps-deploy check <env>               # contrôle, ne change rien
vps-deploy watch staging             # (dossier du staging) construire et déployer la dernière version de la branche
vps-deploy promote --env <prod> -y   # (dossier de la production) mettre en production l'image DÉJÀ validée en staging
vps-deploy rollback <prod>           # revenir à la version précédente
scripts/ops.sh <env> status          # (si le projet a ce script) l'exploitation courante, avec n'importe quel compte autorisé
```
<Si le projet a un pipeline GitLab : « un push sur `<branche du staging>` déploie le staging ; le bouton `deploy-prod` met en production ».>

**Les règles qui évitent les incidents** (chacune vient d'un incident réel ; le détail dans `/app/vps-platform/docs/`) :

1. **Jamais de `git pull`, `merge` ni `commit` dans un clone** (`/app/<projet>/<env>`) : `vps-deploy` le met à jour. Après toute commande en root dans le dossier, vérifier les propriétaires : `find /app/<projet> \( ! -user <compte de déploiement> \) | wc -l` doit répondre 0.
2. **Ne jamais supprimer un volume** (`docker volume rm`, `down -v`, `system prune --volumes`) : les données y sont.
3. **Un `restart` ne relit pas un fichier d'environnement modifié** : c'est `vps-deploy up <env> <version courante>` (après une copie du fichier).
4. **Promouvoir la production seulement après la recette du staging** ; un retour automatique ne défait pas les migrations déjà jouées.
5. **Aucun secret** dans une discussion, un ticket ou un commit.
6. <règle propre au projet>

**État au <AAAA-MM-JJ>.** <ce qui est en ligne, ce qui reste à faire : sauvegarde, clés externes, DNS…>

## 1. La carte du projet : un environnement par ligne

*Une ligne par environnement. C'est le tableau qu'on regarde en premier.*

| Environnement | Adresse | Dossier sur le serveur | Fichier d'environnement | Version déployée | Qui déploie, et comment | Sauvegardée ? |
| --- | --- | --- | --- | --- | --- | --- |
| **staging** | `https://<projet>-staging.visibilitycam.com` | `/app/<projet>/staging` | `.env.staging` (600) | `<branche>`, **automatique** à chaque merge | personne : `vps-deploy watch` (planifié) | non (`BACKUP_DISABLED=1`) |
| **production** | `https://<projet>.visibilitycam.com` | `/app/<projet>/prod` | `.env` (600) | **la version validée en staging**, jamais construite en production | <le responsable du projet> : `vps-deploy promote` | oui, chaque nuit, **sur S3** |

*Projet sans staging, ou avec plusieurs productions : adapter les lignes ; noms d'environnements en minuscules et chiffres seulement (`prod`, `prodeu`).*

## 2. Ce qui tourne

| Service | Rôle | Réseaux | Santé | Données |
| --- | --- | --- | --- | --- |
| `<projet>-web` | <rôle> | `nginx-proxy` (seul service public), privé, `observability` | `<commande>` | — |
| `<projet>-db` | <PostgreSQL / MariaDB / MySQL + version> | privé **seulement** | `<commande>` | volume `<projet>-<env>_db-data` |
| `<projet>-redis` | <cache, file> | privé **seulement** | `valkey-cli ping` | volume `<projet>-<env>_redis-data` |
| `backup` | Sauvegarde chiffrée chaque nuit, envoyée sur S3 | privé | un envoi réussi il y a moins de 36 h | — |

Aucun port n'est publié sur Internet. Le nom d'un projet Docker est `<projet>-<env>` : **ne jamais le renommer** ni renommer un volume.

## 3. Les variables : leur nom et leur rôle (jamais leur valeur)

*Tout ce qui diffère entre environnements doit être listé ici. Les valeurs vivent uniquement dans les fichiers `.env` du serveur.*

| Variable | Rôle | Diffère par environnement ? | D'où elle vient |
| --- | --- | --- | --- |
| `APP_KEY` | Chiffrement de l'application | **oui, jamais la même** | générée une fois, conservée pour toujours (la changer rend illisibles les données chiffrées) |
| `DB_PASSWORD` | Mot de passe de la base | **oui** | `openssl rand -base64 32` |
| `APP_PUBLIC_HOST` | Nom public | oui | le DNS |
| `DEPLOYMENT` | `prod` ou `staging` : étiquette des journaux et des tableaux | oui | fixe |
| `BACKUP_PASSPHRASE` | Chiffrement des sauvegardes | oui | générée, **conservée aussi hors du serveur** |
| `BACKUP_S3_BUCKET`, `AWS_*` | Destination des sauvegardes | production seulement | le bucket de la plateforme |
| `<variable du projet>` | <rôle> | <oui / non> | <où la trouver> |

Modèles complets : [production](https://github.com/wilfreidlando/vcam-infra-deploy/blob/main/templates/env.platform.production.example) et
[staging](https://github.com/wilfreidlando/vcam-infra-deploy/blob/main/templates/env.platform.staging.example). Droits des `.env` : `600`, propriétaire `root`.

## 4. Premier déploiement d'un environnement

> **Commandes.** Elles s'écrivent `vps-deploy …`, ou simplement `vps-deploy …` quand les commandes courtes de la plateforme sont installées (`vps` donne l'aide, `vps where` dit où est la plateforme).

*Une seule fois par environnement. Chaque commande dit ce qu'elle fait.*

```bash
# 1. Les noms sont-ils libres ? (rien n'est modifié)
vps-hosts --free <adresse>

# 2. Le dossier de l'environnement et son fichier de secrets
sudo mkdir -p /app/<projet> && cd /app/<projet>
sudo git clone <url du dépôt> <staging|prod>
cd <staging|prod> && sudo cp .env.<staging|production>.example <.env.staging|.env> && sudo chmod 600 <.env.staging|.env>
sudo nano <.env.staging|.env>        # remplir ; jamais les secrets d'un autre environnement

# 3. Contrôle avant déploiement (ne change rien) : accès git, platform.env, compose, noms
sudo vps-deploy check <staging|prod>

# 4. Staging : construire puis déployer      |  Production : promouvoir la version du staging
sudo vps-deploy watch staging   |   sudo vps-deploy promote
```

**Vérifier** : `vps-deploy status` ; `curl -fsS https://<adresse>/<route de santé>` répond 200 ; Grafana, tableau « Application — vue d'ensemble », choisir `<projet>`.

## 5. Livrer une nouvelle version

| Étape | Qui | Commande ou action | Vérification |
| --- | --- | --- | --- |
| 1. Merger sur `<branche>` | le développeur | merge request | — |
| 2. Le staging se met à jour | automatique (≈ 2 min) ou à la main : `vps-deploy watch staging` | — | `vps-deploy status`, la recette sur le staging |
| 3. **Recette** | <le responsable> | <parcours à vérifier> | <critères> |
| 4. Si la version contient une **migration** risquée | <le responsable> | `vps-deploy backup` (une sauvegarde à la main, sur S3) | « uploaded to s3://… » |
| 5. Production | <le responsable> | `cd /app/<projet>/prod && vps-deploy promote` (confirmer) | `/health` 200, `vps-deploy status`, Grafana |

La production reçoit **exactement l'image testée en staging**. Elle n'est **jamais** déployée automatiquement.

## 6. Mettre à jour ce qui est déjà là

| Je change… | Je fais | Coupure | Retour arrière |
| --- | --- | --- | --- |
| Le **code** | § 5 | quelques secondes en production | `vps-deploy rollback <env>` |
| Une **variable** (`.env`, `.env.staging`) | éditer le fichier du serveur, puis `vps-deploy up <env> <version courante>` : les conteneurs sont recréés avec la nouvelle valeur | quelques secondes | remettre l'ancienne valeur, même commande |
| `compose.prod.yaml` ou `platform.env` | un commit, puis § 5 : le compose et `platform.env` sont lus **dans le commit déployé** | comme une livraison | `vps-deploy rollback <env>` |
| **Une dépendance** (version de base de données, d'image) | d'abord le staging, **avec une copie restaurée de la production** | selon le cas | restauration (§ 8) |
| Les **tableaux et alertes du projet** | `observability/` dans le dépôt, publié après la production ou `vps-deploy obs-sync` | aucune | republier la version précédente |

## 7. Retour arrière

- **Automatique** : si la nouvelle version ne répond pas à son contrôle de santé, l'ancienne est remise (sauf la toute première promotion d'un projet existant).
- **À la main** : `cd /app/<projet>/<env> && vps-deploy rollback <env>` remet la version précédente. **Les migrations ne sont pas annulées** : vérifier que l'ancien code les supporte, sinon restaurer la dernière sauvegarde (§ 8).

## 8. Sauvegarde et restauration

- Sauvegarde chiffrée **chaque nuit à <HH:MM UTC>**, envoyée sur **S3** puis effacée du serveur ; conservée **<30> jours**. Aucune copie ne reste sur le disque du serveur.
- À la demande : `vps-deploy backup <env>`.
- **Restaurer** : `restore.sh <env> s3://<bucket>/<préfixe>/<projet>-<env>/<fichier>` (la phrase de chiffrement de l'environnement d'origine).
- **Exercice de restauration chaque mois**, avec une table-témoin : [procédure](https://github.com/wilfreidlando/vcam-infra-deploy/blob/main/docs/runbooks/exercice-de-restauration.md). Dernier exercice : **<date, résultat>**.

## 9. Observabilité de ce projet

| Quoi | Où |
| --- | --- |
| Disponibilité et certificat | listé dans les sites sondés ; alerte si le site ne répond plus |
| Journaux | Grafana → Explore → Loki : `{app="<projet>", deployment="<env>"}` ; format <JSON> |
| État d'ensemble | Grafana → Plateforme → **Application — vue d'ensemble** → `<projet>` |
| Métriques et alertes propres | <tableaux et règles dans `observability/`, ou « aucune »> |

[Guide de l'observabilité d'un projet](https://github.com/wilfreidlando/vcam-infra-deploy/blob/main/guides/19-observabilite-de-mon-projet.md).

## 10. En cas de problème

| Symptôme | Où aller |
| --- | --- |
| Le site ne répond plus | [runbook « site en panne »](https://github.com/wilfreidlando/vcam-infra-deploy/blob/main/docs/runbooks/site-en-panne.md) |
| `deploy.sh` s'arrête avec une erreur | [runbook « déploiement en échec »](https://github.com/wilfreidlando/vcam-infra-deploy/blob/main/docs/runbooks/deploiement-en-echec.md) |
| Un conteneur redémarre sans cesse | [runbook « conteneur en boucle »](https://github.com/wilfreidlando/vcam-infra-deploy/blob/main/docs/runbooks/conteneur-en-boucle.md) |
| La base est inaccessible | [runbook « base inaccessible »](https://github.com/wilfreidlando/vcam-infra-deploy/blob/main/docs/runbooks/base-inaccessible.md) |

**Qui prévenir** : <responsable du projet, contact> ; plateforme : <responsable de la plateforme, contact>.

## 11. Écarts connus avec le standard (à résorber)

> Tout ce qui, aujourd'hui, **n'est pas conforme** au [contrat](https://github.com/wilfreidlando/vcam-infra-deploy/blob/main/docs/05-contrat-projet.md), et pourquoi. Une fiche qui affirme le standard alors que le projet s'en écarte
> est **pire** qu'une fiche qui avoue l'écart : quelqu'un s'y fierait. S'il n'y a aucun écart, écrire « aucun ».

| Écart | Pourquoi | Risque | Pour le résorber | Échéance |
| --- | --- | --- | --- | --- |
| <par exemple : production sans sauvegarde sur S3> | <décision et date> | <ce qui peut arriver> | <l'action> | <date> |

## 12. Historique de ce document

| Date | Changement | Par |
| --- | --- | --- |
| <AAAA-MM-JJ> | Création | <nom> |
