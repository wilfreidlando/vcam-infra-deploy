# 11. Mettre à jour la plateforme sur le serveur

La plateforme (ce dépôt, `https://github.com/wilfreidlando/vcam-infra-deployment`) est clonée sur le
serveur dans `/app/vps-platform`. Les projets s'en servent ainsi :

| Ce qu'un projet utilise | Comment |
| --- | --- |
| `deploy.sh`, `restore.sh`, `vps-hosts.sh`, `vps-audit.sh` | appelés par chemin : `/app/vps-platform/bin/…` |
| l'image de sauvegarde | construite depuis `${PLATFORM_DIR:-/app/vps-platform}/images/db-backup` (le `compose.prod.yaml` de chaque projet) |
| l'observabilité | projet Docker à part, démarré depuis `/app/vps-platform/observability` |

Les projets (Core, WILMANAGER…) n'embarquent plus aucune copie de la plateforme.

## Avant de mettre à jour

Sur un poste, depuis un clone de ce dépôt :

```bash
tests/run-all.sh          # tout doit être vert
```

## Mettre à jour

```bash
$ cd /app/vps-platform
$ git fetch && git log --oneline HEAD..origin/main     # ce qui va changer
$ git pull --ff-only
```

- **Outils** (`bin/`) : pris en compte au prochain déploiement. Rien à redémarrer.
- **Image de sauvegarde** (`images/db-backup`) : reconstruite au prochain build de
  chaque projet.
- **Observabilité** (`observability/`) : seulement si ce dossier a changé
  (quelques secondes sans collecte, aucun effet sur les sites) :
  ```bash
  $ cd /app/vps-platform/observability && docker compose --env-file .env up -d
  ```

## Revenir en arrière

```bash
$ cd /app/vps-platform && git log --oneline -5
$ git checkout <commit précédent>          # puis, si l'observabilité avait changé, la relancer comme ci-dessus
```

Revenir sur `main` ensuite avec `git checkout main && git pull --ff-only`.
