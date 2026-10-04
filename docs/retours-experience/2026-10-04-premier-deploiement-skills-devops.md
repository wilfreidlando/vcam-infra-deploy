# 2026-10-04 — Premier déploiement de skills-devops : quatre échecs en chaîne

**Impact** : aucun site touché. Le staging de skills-devops (application
d'apprentissage) n'a pas pu être mis en ligne pendant environ une demi-heure. Rien
n'a été basculé : `deploy.sh` s'est arrêté avant chaque changement, comme prévu.
**Détecté par** : la personne qui déployait, en suivant le README du projet.

Ces échecs sont instructifs : chacun touchait **tous** les projets, existants ou à
venir, et pas seulement skills-devops.

## Ce qui s'est passé

| # | Message | Cause réelle |
| --- | --- | --- |
| 1 | `Username for 'https://github.com':` | Le clone du serveur pointait vers `https://github.com/…`. Sous cron, ce déploiement serait resté bloqué indéfiniment |
| 2 | `SQLSTATE[08006] … connection to server at "db" (172.18.0.119) … Connection refused` (1er essai) | Deux causes possibles : le healthcheck de PostgreSQL et la collision de noms (n° 3) |
| 3 | Même message, base recréée, **même adresse 172.18.0.119** | Le nom `db` menait à la base **d'une autre installation**, branchée sur le réseau partagé `nginx-proxy` |
| 4 | `no such service: app` | `deploy.sh` avait lu `platform.env` dans l'**ancien** commit (service `app`), puis déployé le nouveau (service renommé) |

## Causes, vérifiées

**Healthcheck de la base (n° 2).** Au premier démarrage, l'image `postgres` lance un
serveur temporaire qui n'écoute **que** sur son socket local, crée la base, puis
redémarre en écoutant sur le réseau. `pg_isready` sans `-h` interroge le socket : il
répondait « prêt » pendant la phase temporaire. Reproduit : socket `OK`, réseau
`refusé`, pendant environ 150 ms.

**Collision de noms (n° 3).** Un conteneur branché sur deux réseaux (le réseau privé
du projet et `nginx-proxy`) voit les noms DNS des deux. Quand un même nom existe des
deux côtés, Docker ne garantit pas lequel il choisit. Reproduit avec les vrais noms
de réseaux : `db` → la base étrangère (172.18.x, sous-réseau de `nginx-proxy`). Un nom
propre au projet (`skills-devops-db`) menait bien à la bonne base. L'adresse
identique après recréation de la base était l'indice décisif.

**`platform.env` lu trop tôt (n° 4).** `deploy.sh` chargeait `platform.env` une seule
fois, au démarrage, depuis le commit en place. Tout changement de `platform.env`
prenait effet un déploiement trop tard, et un service renommé dans le même commit
n'existait pas encore.

## Pourquoi rien ne l'a arrêté

- Aucun contrôle de cohérence entre `platform.env` et le compose avant d'agir.
- Aucun contrôle des noms sur les réseaux partagés. L'audit signale bien une base sur
  `nginx-proxy` (CRITIQUE), mais seulement si on le lance, et sans dire qu'elle
  **détourne** les connexions des autres projets.
- `git` avait le droit de demander un mot de passe.
- Les modèles utilisaient des noms génériques (`app`, `db`, `redis`) et un
  healthcheck par socket. Le banc de tests ne fait tourner qu'un projet à la fois,
  donc sans voisin pour créer une collision.

## Correction et protection pour tous les projets

| Protection | Où | Preuve |
| --- | --- | --- |
| `platform.env` relu après chaque checkout ; un `APP_NAME` qui change est refusé | `bin/deploy.sh` (`load_config`) | `tests/test-deploy.sh` : « service renommé + platform.env dans le même commit » |
| Contrôle avant déploiement, BLOQUANT : services de `platform.env` absents du compose ; nom d'un service privé publié par un autre projet sur un réseau partagé | `bin/deploy.sh` (`preflight`) | tests « platform.env incohérent », « Noms privés exposés sur un réseau partagé » |
| `deploy.sh check <env>` : le même contrôle, plus l'accès git, sans rien modifier, utilisable sur un projet déjà en production | `bin/deploy.sh` | test « check refuse », puis « check OK » après renommage |
| `git` ne demande jamais de mot de passe ; un origin en HTTPS échoue avec la commande de correction | `bin/deploy.sh` (`fetch_origin`) | test « Origin en HTTPS » (échec en moins de 30 s) |
| Renommer un service qui tient un volume : refus expliqué, avec la procédure | `bin/deploy.sh` (message du contrôle de volumes) | test « service renommé : refusé tant que l'ancien conteneur tient le volume » |
| Services nommés `<app>-…`, `DB_HOST`/`REDIS_HOST` imposés par le compose, healthcheck de base par le réseau | `templates/`, skills-devops, Core (healthcheck) | contrôle `deploy.sh check` sur skills-devops avec une base étrangère `db` sur `nginx-proxy` : la version d'avant est refusée, la nouvelle passe |
| Clauses C3, C4, C5, C6, C9 | [Contrat v2](../05-contrat-projet.md) | — |

## Reste à faire

| Quoi | Qui | Comment |
| --- | --- | --- |
| Identifier l'installation dont la base est sur `nginx-proxy` (172.18.0.119), la retirer de ce réseau ou l'arrêter | administrateur du VPS | `docker network inspect nginx-proxy --format '{{range .Containers}}{{.Name}} {{.IPv4Address}}{{"\n"}}{{end}}'` puis `vps-audit.sh` |
| Inventaire complet du serveur (feuille de route, phase 0) avec `vps-inventory.sh`, à la main ou par le [guide 13](../../guides/13-intervention-assistee.md) | administrateur du VPS | `docs/inventaire/` |
| Passer le Core et centre-formation à `deploy.sh check prod` ; corriger les écarts (services `app`, `postgres`, `valkey`… au nom générique) selon le [contrat, § 4](../05-contrat-projet.md#4-appliquer-le-contrat-à-un-projet-déjà-en-production) | responsable de chaque projet | contrat § 4 |
| Remplacer l'origin HTTPS des clones existants par l'alias SSH du projet | administrateur du VPS | `git remote -v` dans chaque `/app/<app>/<env>` |
