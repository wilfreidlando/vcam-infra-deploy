# Contenu du dépôt, outil par outil

> Description de chaque dossier et de chaque outil. Retour au [sommaire de la documentation](../README.md).

| Dossier | Contenu |
| --- | --- |
| [`docs/`](..) | **[Contrat d'un projet](../05-contrat-projet.md)** (le référentiel), [schémas de chaque élément](../01-schemas.md), [résilience et évolutivité](../02-resilience-evolutivite.md), [glossaire](../03-glossaire.md), [démarrage rapide](../04-demarrage-rapide-dev.md), [retours d'expérience](../retours-experience/README.md) |
| [`guides/`](../../guides/README.md) | **Guides pas à pas** de mise en place, dans l'ordre |
| [`bin/deploy.sh`](../../bin/deploy.sh) | Déploiement standard : build, staging automatique, promotion manuelle en production, retour arrière automatique. **Contrôle avant déploiement** (rien n'est modifié s'il échoue) : cohérence `platform.env` ↔ compose, noms en conflit sur les réseaux partagés, accès git, sous-domaine déjà pris, volume encore utilisé ailleurs. `deploy.sh check <env>` lance ce contrôle seul |
| [`bin/vps-audit.sh`](../../bin/vps-audit.sh) | Audit **en lecture seule** de tous les conteneurs du serveur, noms en conflit sur les réseaux partagés compris |
| [`bin/vps-inventory.sh`](../../bin/vps-inventory.sh) | **Inventaire** complet du serveur en Markdown (hôte, projets, dossiers, versions déployées, réseaux partagés, crons, audit), **sans aucun secret**, en lecture seule. Rangé dans [`docs/inventaire/`](../inventaire/README.md) |
| [`bin/vps-hosts.sh`](../../bin/vps-hosts.sh) | Inventaire de tous les sous-domaines, contrôle « libre ou pris ? », garde contre les collisions |
| [`bin/restore.sh`](../../bin/restore.sh) | Restauration d'une sauvegarde dans un environnement |
| [`bin/obs-bundle.py`](../../bin/obs-bundle.py) | Publie les **tableaux et alertes propres à un projet** (depuis son dépôt) dans Grafana, avec validation et garde-fous (`deploy.sh obs-sync`) |
| [`bin/vps-fingerprint.sh`](../../bin/vps-fingerprint.sh) | **Empreintes pour prouver qu'une copie est exacte** : `db <conteneur> [base]` (MariaDB, MySQL, PostgreSQL : une ligne par table, nombre de lignes et somme de contrôle du contenu) et `files <volume>` (sha256 de chaque fichier). Ne modifie rien ; commande courte `vps-fingerprint` ([guide 20](../../guides/20-migrer-une-application-existante.md)) |
| [`templates/`](../../templates/README.md) | **Modèles prêts à copier, testés** (`test-templates.sh`, `test-gitlab-ci.sh`, `test-scripts-modeles.sh`, `test-laravel-modeles.sh`) : le **pipeline GitLab** (`gitlab-ci/`, profils A et B), les **scripts** `ops.sh` et `make-env.py` (`scripts/`), Laravel PostgreSQL et MySQL/MariaDB, web générique, frontend (SPA et Next.js), un fichier d'environnement par environnement, la fiche de déploiement d'un projet (`docs-projet/`), [observabilité d'une application Laravel](../../templates/laravel-observabilite/README.md) (journaux JSON, `/metrics` privé, sauvegarde observée), [tableaux et alertes propres à un projet](../../templates/observabilite-projet/README.md) |
| [`images/db-backup/`](../../images/db-backup) | Agent de sauvegarde PostgreSQL / MySQL / MariaDB → MEGA S4 (ou tout S3) |
| [`observability/`](../../observability) | Grafana + Loki + Tempo + Prometheus mutualisés (backends) |
| [`host/`](../../host) | Réglages du démon Docker : [`daemon.json`](../../host/daemon.json) (rotation des journaux, live-restore) et [`apply-daemon-config.sh`](../../host/apply-daemon-config.sh), qui le fusionne, le valide, redémarre Docker **sans arrêter les conteneurs** et compare les conteneurs avant et après ([guide 9](../../guides/09-rotation-journaux-hote.md)) |
| [`tests/`](../../tests/README.md) | Tests **réels** de toute la plateforme, rejouables sur un poste avec Docker, et lancés par la CI GitHub sur chaque pull request ([`.github/workflows/tests.yml`](../../.github/workflows/tests.yml)) : une modification de la plateforme ne se merge qu'avec la CI verte |

> **Où vit ce dossier.** Il est né dans le dépôt `core-system`, mais il concerne
> tout le serveur. Il peut vivre dans son propre dépôt (`vps-platform`), cloné sur
> le serveur dans `/app/vps-platform` (guide 11). Les exemples utilisent ce chemin.
