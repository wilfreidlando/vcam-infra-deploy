# 16. Mettre un projet au standard (fiche de conformité)

Fiche pratique pour amener **un projet** (nouveau ou déjà en production) au
[contrat](../docs/05-contrat-projet.md). Elle complète le contrat § 4 et les guides
[5](05-audit-et-conformite.md) et [6](06-core-au-standard.md) avec une liste de contrôle et
un exemple complet.

| Risque pour les sites | Coupure | Durée |
| --- | --- | --- |
| Celui du projet traité, jamais celui des autres | nulle en staging ; en production, 1 à 3 minutes si la base change de nom | 2 h environ par projet |

**Règle d'or : un projet à la fois, staging avant production, une sauvegarde vérifiée avant
toute migration en production.** Ne jamais renommer `APP_NAME` ni un volume.

## 1. Avant de commencer

| Il faut | Pourquoi |
| --- | --- |
| Le nom du projet Docker actuel : `docker compose ls` | `APP_NAME` doit être choisi pour que `<APP_NAME>-prod` soit ce nom : les volumes (les données) y sont rattachés |
| L'accord de la personne responsable du projet, et un créneau pour la production | Contrat § 4, étape 5 |
| Une sauvegarde récente **et restaurée au moins une fois** | Contrat C11 |
| L'accès git par clé de déploiement ([guide 3](03-installer-plateforme.md), étape 0) | Contrat C9 |

## 2. Mesurer, sans rien modifier

```bash
$ vps-audit                          # tout le serveur, lecture seule
$ cd /app/<projet>/prod && vps-deploy check prod
```

Noter chaque ligne **BLOQUANT**, **CRITIQUE** et **ATTENTION** : ce sont les écarts à corriger.

## 3. Liste de contrôle par clause

| Clause | À vérifier dans le dépôt du projet | Correction type |
| --- | --- | --- |
| **C1** Trafic par `nginx-proxy` seulement | Aucun `ports:` ; `VIRTUAL_HOST` et `LETSENCRYPT_HOST` sur le seul conteneur web | Supprimer `ports:` ; pour l'administration : `127.0.0.1:5432:5432` + tunnel SSH |
| **C2** Base, cache, file en réseau privé | La base n'est pas sur `nginx-proxy` | Réseau `<app>-<env>-internal` ; seul le web rejoint `nginx-proxy` |
| **C3** Noms propres au projet | Services `<app>-web`, `<app>-db`, `<app>-redis`, jamais `app`, `db`, `redis` ; `DB_HOST`, `REDIS_HOST` reprennent ces noms | Renommer, voir l'exemple § 5 |
| **C4** Healthcheck web et base | Celui de la base passe **par le réseau** : `pg_isready -h 127.0.0.1` | Bloc `healthcheck` des modèles |
| **C5** `platform.env` cohérent | `HEALTH_SERVICE`, `MIGRATE_SERVICE`, `BACKUP_SERVICE`, `DB_SERVICE` existent dans le compose du **même commit** | Aligner les deux dans un seul commit |
| **C6** `platform.env` jamais modifié sur le serveur | `git status` propre dans `/app/<app>/<env>` | Faire le changement par commit |
| **C7** Images taguées | `image: <app>:${IMAGE_TAG:-latest}` | Voir `templates/` |
| **C8** `restart`, mémoire, journaux | `restart: unless-stopped`, `deploy.resources.limits.memory`, bloc `logging` | Partir de 2 fois la consommation observée (`docker stats --no-stream`) |
| **C9** Accès au dépôt | **Dépôt privé** : `git remote -v` en `git@github-<app>:…`, jamais en HTTPS avec un identifiant. **Dépôt public** : HTTPS sans identifiant | privé : `git remote set-url origin git@github-<app>:<compte>/<dépôt>.git` |
| **C10** Secrets séparés | `.env` et `.env.staging` différents ; jamais commités | — |
| **C11** Sauvegarde chiffrée hors serveur | Service `backup` (agent `images/db-backup`) et restauration mensuelle | [Guide 4](04-sauvegardes-mega-s4.md) |
| **C12** Observabilité (backends) | Labels `observability.*` sur les services à observer ; ses propres tableaux et alertes dans `observability/` | [Guide 19](19-observabilite-de-mon-projet.md) |
| **C14** Fiche de déploiement | `docs/DEPLOIEMENT.md` à jour : environnements, variables (noms et rôles), livraison, retour arrière | [modèle](../templates/docs-projet/DEPLOIEMENT.md) ; [déployer selon la situation](../docs/reference/deployer-selon-la-situation.md) |

Le contrôle `vps-deploy check` couvre C3, C5 et C9 de façon bloquante, signale l'absence de la fiche C14 (INFO), et une modification
locale de `platform.env` (C6) fait échouer le changement de commit. L'audit couvre les
autres clauses en niveaux CRITIQUE, ATTENTION ou INFO.

## 4. La procédure

1. **Corriger dans le dépôt du projet**, en partant des modèles de `templates/`. Un seul
   commit peut tout corriger. Vérifier à chaque étape : `vps-deploy check staging`.
2. **Staging d'abord** : `vps-deploy build origin/main staging`, puis `vps-deploy up staging <sha>`
   (ou laisser `vps-deploy watch` le faire). Vérifier : `vps-deploy status`, les conteneurs sont
   « healthy », le site répond.
3. **Si des services ont été renommés** : `vps-deploy up` refuse tant que l'ancien conteneur tient
   un volume. C'est voulu : deux bases sur les mêmes fichiers les corrompent. Supprimer **nommément**
   l'ancien conteneur (`docker rm -f <conteneur>`, les volumes restent), puis relancer. Jamais de
   `down -v`, jamais de `prune`.
4. **Production, dans le créneau annoncé** : **prendre une sauvegarde à la main** (`vps-deploy backup`), puis `vps-deploy promote`.
   `deploy.sh` ne prend pas de sauvegarde de lui-même (la nocturne est le filet) ; `BACKUP_BEFORE_DEPLOY=always` pour en avoir une avant chaque déploiement.
5. **Vérifier** : `vps-deploy status`, `vps-deploy check prod`, puis `vps-audit.sh` : plus aucune
   ligne BLOQUANT, CRITIQUE ni ATTENTION pour ce projet.
6. **Brancher l'observabilité** si le projet est un backend (labels, puis la vérification du
   [README de l'observabilité](../observability/README.md)).

## 5. Exemple complet : `skills-devops` (projet pilote, 2026-10-04)

| Étape | Ce qui a été fait | Résultat |
| --- | --- | --- |
| Mesure | `vps-deploy check staging` sur le commit en place : **échec** C3, services `db` et `redis` aussi publiés sur `nginx-proxy` par d'autres projets | rien modifié |
| Correction | Dépôt : services renommés `skills-devops-db` et `skills-devops-redis`, `platform.env` aligné (`DB_SERVICE=skills-devops-db`), `DB_HOST`/`REDIS_HOST` repris | commit sur `main` |
| Construire | `vps-deploy build origin/main staging` | image `skills-devops:<sha>`, aucun conteneur touché |
| Libérer les volumes | `docker rm -f` des **deux** anciens conteneurs de staging, nommément | volumes conservés |
| Staging | `vps-deploy up staging <sha>` | migrations réussies, `OK staging = <sha>` |
| Vérifier | `vps-deploy status`, site de staging en HTTP 200, `vps-deploy check staging` : OK | conforme |
| Production | `vps-deploy promote <sha> -y` | migrations, `OK prod = <sha>`, HTTP 200 (une sauvegarde à la main avant : `vps-deploy backup`) |

Le raisonnement complet de ce cas est dans le
[retour d'expérience](../docs/retours-experience/2026-10-04-premier-deploiement-skills-devops.md).

## 6. Critères de fin

- [ ] `vps-deploy check prod` : OK.
- [ ] `vps-audit.sh` : aucune ligne BLOQUANT, CRITIQUE ni ATTENTION pour le projet.
- [ ] Sauvegarde automatique active et **restaurée au moins une fois** dans un staging.
- [ ] `git remote -v` en SSH (`github-<app>`).
- [ ] Labels `observability.*` posés si backend.
- [ ] Un responsable nommé, et la date de la prochaine restauration test, notés dans l'inventaire.
- [ ] Les écarts restants, avec responsable et échéance, notés dans le dernier fichier de
      [`docs/inventaire/`](../docs/inventaire/README.md).
