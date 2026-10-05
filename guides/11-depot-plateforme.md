# 11. Mettre à jour la plateforme sur le serveur

La plateforme (ce dépôt, `https://github.com/wilfreidlando/vcam-infra-deploy`) est clonée sur le
serveur dans `/app/vps-platform`. Les projets s'en servent ainsi :

| Ce qu'un projet utilise | Comment |
| --- | --- |
| `deploy.sh`, `restore.sh`, `vps-hosts.sh`, `vps-audit.sh`… | appelés par chemin (`/app/vps-platform/bin/…`) ou par leurs [commandes courtes](03-installer-plateforme.md#étape-1--cloner-la-plateforme) (`vps-deploy`…) |
| l'image de sauvegarde | construite depuis `${PLATFORM_DIR:-/app/vps-platform}/images/db-backup` (le `compose.prod.yaml` de chaque projet) |
| l'observabilité | projet Docker à part, démarré depuis `/app/vps-platform/observability` |

Les projets (Core, WILMANAGER…) n'embarquent plus aucune copie de la plateforme.

## Peut-on mettre les scripts à jour sans rien casser ?

Oui, à condition de respecter ce qui suit. Ce qui rend la mise à jour sûre :

| Ce qui protège | Pourquoi |
| --- | --- |
| **Un script en cours d'exécution n'est pas coupé** par un `git pull` | Git remplace le fichier (nouvel exemplaire) : le script qui tournait va au bout avec sa version, le suivant démarre avec la nouvelle. Vérifié par une expérience (un `pull` en pleine exécution) |
| **Les nouveautés sont optionnelles** | Une clé nouvelle de `platform.env` a un défaut (le comportement d'avant) ; les anciens noms restent valables (`STAGING_BRANCH`) ; les chemins complets (`/app/vps-platform/bin/…`) marchent toujours |
| **Les commandes courtes ne contiennent aucune logique** | Elles ne font que retrouver le script : une mise à jour des scripts n'oblige pas à les réinstaller. Seul un **nouvel** outil (une nouvelle commande) le demande : `host/install-commands.sh --check` le dit |
| **Les tests rejouent les cas réels** | Staging automatique, promotion de la même image, retour arrière, collisions de noms, branches, sauvegarde : si l'un casse, `tests/run-all.sh` le voit avant le serveur |
| **Le retour arrière est immédiat** | Voir plus bas : revenir au commit précédent suffit pour les outils |

Ce qui reste un risque, à connaître :

- **Un déploiement en cours pendant la mise à jour.** Le script démarré garde sa version, mais s'il appelle un script voisin (`vps-hosts.sh`) il peut obtenir la nouvelle : deux versions dans un même déploiement. Mettre à jour **quand aucun déploiement ne tourne**
  (`pgrep -af 'deploy.sh (build|up|watch|promote|rollback)'` ne doit rien renvoyer).
- **Aucun épinglage** : tous les projets reçoivent la nouvelle version en même temps, et un projet ne déclare pas avec quelle version de la plateforme il est compatible ([ADR-0069](../docs/adr/0069-commandes-courtes-et-branches-declarees-par-le-projet.md)). Un changement de comportement touche donc tout le serveur : lire `git log` avant.
- **Une règle nouvelle peut refuser ce qui passait** : par exemple la garde de branche (`BRANCH_PROD`) refuse une version non fusionnée, mais **seulement si le projet l'a déclarée**.

## Avant de mettre à jour

Sur un poste, depuis un clone de ce dépôt :

```bash
tests/run-all.sh          # tout doit être vert
```

Sur le serveur : aucun déploiement en cours (voir plus haut), et noter le commit actuel (`vps where`) pour pouvoir revenir.

## Mettre à jour

```bash
$ cd /app/vps-platform
$ git fetch && git log --oneline HEAD..origin/main     # ce qui va changer
$ git pull --ff-only
```

**Voir d'abord ce qui change** : `git diff --stat HEAD origin/main` (après le `fetch`). Selon les dossiers touchés :

| Ce qui a changé | Après le `pull`, il faut… |
| --- | --- |
| **`bin/`** (`deploy.sh`, `restore.sh`, `vps-*.sh`) | **Rien.** Pris en compte à la prochaine commande. Vérifier : `vps where`, puis `vps-deploy check <env>` sur un projet (ne change rien) |
| **Une nouvelle commande** (`bin/vps.sh`, un script ajouté à la liste de `host/install-commands.sh`) | Relancer `host/install-commands.sh` (en root). `host/install-commands.sh --check` dit si c'est nécessaire |
| **`host/`** (réglage de Docker) | Rien tant qu'on ne le lance pas : `vps-daemon-config` applique, de nuit |
| **`images/db-backup`** (agent de sauvegarde) | **Le `pull` ne suffit pas.** Chaque projet reçoit la nouvelle image à son **prochain déploiement** ; les agents qui tournent gardent l'ancienne jusque-là |
| **`observability/`** : tableaux | Rien : Grafana les recharge seul en une minute |
| **`observability/`** : règles d'alerte ou notifications | **Recréer Grafana** (`cd /app/vps-platform/observability && docker compose --env-file .env up -d --no-deps --force-recreate grafana`) |
| **`observability/`** : autre composant (Tempo, Alloy, Prometheus…) | Recréer **ce** composant seulement, jamais tout d'un coup |
| **`templates/`, `docs/`, `guides/`, `tests/`** | Rien : rien ne s'exécute sur le serveur. Les projets copient les modèles à la main |

Deux conditions pour que le `pull` passe : le clone du serveur ne doit avoir **aucune modification locale** (les fichiers propres au serveur, comme `sites.yml` ou `.env`, sont ignorés par git), et il se fait en root avec `--ff-only`.

## Revenir en arrière

```bash
$ cd /app/vps-platform && git log --oneline -5
$ git checkout <commit précédent>          # puis, si l'observabilité avait changé, la relancer comme ci-dessus
```

Revenir sur `main` ensuite avec `git checkout main && git pull --ff-only`.
