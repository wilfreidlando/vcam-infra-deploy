# Modèles de projet

> Par quoi partir pour un nouveau projet, ou pour mettre un projet existant au standard. **Chaque modèle est testé** : `tests/test-templates.sh` prouve qu'il passe
> le contrôle avant déploiement de la plateforme (`deploy.sh check`). Retour au [sommaire](../docs/README.md).

## 1. Quel modèle pour quelle application ?

| Mon application est… | Je copie | Base de données | Observabilité |
| --- | --- | --- | --- |
| **Laravel avec PostgreSQL** | [`compose.laravel.yaml`](compose.laravel.yaml) | PostgreSQL 18 | [modèle Laravel](laravel-observabilite/README.md) : journaux JSON, `/metrics` privé |
| **Laravel avec MySQL ou MariaDB** | [`compose.laravel-mysql.yaml`](compose.laravel-mysql.yaml) | MariaDB 11.4 (ou MySQL 8.4, ou MariaDB 10.7) | idem |
| **Un back end Node, Python, Go… qui sert du HTTP** | [`compose.web.yaml`](compose.web.yaml) | aucune (ajouter le service de base et l'agent de [`compose.laravel.yaml`](compose.laravel.yaml) si besoin) | labels, `/metrics` à écrire ([principe](laravel-observabilite/README.md#adapter-pour-un-autre-framework)) |
| **Un front React, Angular ou Vue** (fichiers statiques) | [`frontend/`](frontend) variante A (`Dockerfile.spa`) | aucune | la sonde de disponibilité suffit |
| **Un site Next.js** | [`frontend/`](frontend) variante B (`Dockerfile.nextjs`, `BUILD_PER_ENV=1`) | aucune | la sonde ; journaux facultatifs |
| **Un site vitrine, une page** | [`frontend/`](frontend) variante A | aucune | la sonde de disponibilité seulement ([profil D](../docs/reference/profils-de-projet.md)) |

Dans tous les cas on ajoute aussi : [`platform.env`](platform.env) (comment `deploy.sh` déploie le projet), les deux fichiers d'environnement ci-dessous, et la [fiche de déploiement](docs-projet/DEPLOIEMENT.md).

## 2. Les fichiers, un par un

| Fichier | Où le copier | Rôle |
| --- | --- | --- |
| `compose.laravel.yaml`, `compose.laravel-mysql.yaml`, `compose.web.yaml`, `frontend/compose.frontend.yaml` | racine du projet, sous le nom **`compose.prod.yaml`** | La pile : **identique pour tous les environnements** (le projet Docker et le fichier d'environnement changent, rien d'autre) |
| [`platform.env`](platform.env) (et [`frontend/platform.env`](frontend/platform.env)) | racine du projet | Nom, services, contrôle de santé, migrations, sauvegarde, environnements ([profils](../docs/reference/profils-de-projet.md) ; [chaque clé, son défaut, son effet](../docs/reference/platform-env.md)) |
| [`env.platform.production.example`](env.platform.production.example) | à fusionner dans le `.env` du serveur de **production** | Variables de la plateforme pour la production : sauvegarde S3 **obligatoire**, ressources de production |
| [`env.platform.staging.example`](env.platform.staging.example) | à fusionner dans le `.env.staging` du serveur de **staging** | Les mêmes pour le staging : **non sauvegardé**, plus petit, jamais les secrets de la production |
| [`docs-projet/DEPLOIEMENT.md`](docs-projet/DEPLOIEMENT.md) | `docs/DEPLOIEMENT.md` du projet | La fiche de déploiement du projet, environnement par environnement : **à remplir** |
| [`laravel-observabilite/`](laravel-observabilite/README.md) | `app/…` du projet Laravel | Journaux JSON, `/metrics` privé, sauvegarde observée |
| [`observabilite-projet/`](observabilite-projet/README.md) | `observability/` du projet | Ses propres tableaux et alertes, publiés par `deploy.sh` ([guide 19](../guides/19-observabilite-de-mon-projet.md)) |
| [`gitlab-ci/`](gitlab-ci/README.md) | racine du projet, sous le nom `.gitlab-ci.yml` | **Le pipeline** : profil A (staging automatique puis production sur bouton) ou profil B (production seule). Annule ce qui est inutile, ne laisse jamais un déploiement interruptible, jamais de production automatique. [Pourquoi cette forme](../docs/reference/pipeline-gitlab.md) |
| [`scripts/ops.sh`](scripts/README.md) | `scripts/ops.sh` du projet | L'exploitation courante d'un environnement sans le redéployer : état, journaux, arrêt, démarrage, redémarrage, shell |
| [`scripts/make-env.py`](scripts/README.md) | `scripts/make-env.py` du projet | Crée `.env.<env>` avec des secrets **aléatoires et distincts**, jamais affichés |
| `frontend/Dockerfile.spa`, `Dockerfile.nextjs`, `nginx-spa.conf`, `40-runtime-env.sh` | racine du projet | Les images d'un front ; la configuration d'exécution d'une SPA sans rebâtir l'image |

## 3. Utiliser un modèle, pas à pas

1. **Copier** les fichiers de la ligne choisie au § 1, `compose` renommé en `compose.prod.yaml`.
2. **Remplacer les noms d'exemple** par ceux du projet. Les noms de services doivent être **propres au projet** (`<projet>-web`, `<projet>-db`, `<projet>-redis`), jamais `app`, `db`, `redis` :
   ```bash
   grep -rn "mon-saas\|mon-site\|mon-front" .        # chaque occurrence est à remplacer par le nom du projet
   ```
3. **Choisir le profil** dans `platform.env` : `ENVIRONMENTS` (staging puis production, production seule, plusieurs productions) ; défaut : staging et production.
4. **Préparer un fichier d'environnement par environnement**, depuis les deux modèles du § 2 : **les valeurs diffèrent**, secrets compris (clause C10 du [contrat](../docs/05-contrat-projet.md)).
5. **Contrôler** sur le serveur, sans rien modifier : `deploy.sh check staging` puis `deploy.sh check prod`.
6. **Remplir la fiche de déploiement** (`docs/DEPLOIEMENT.md`) : elle est la référence du projet pour toute l'équipe.

## 4. Ce que les modèles appliquent déjà

| Règle du contrat | Dans le modèle |
| --- | --- |
| C1 : aucun port publié, trafic par `nginx-proxy` seulement | pas de `ports:` ; `VIRTUAL_HOST` sur le seul conteneur web |
| C2, C3 : base et cache privés, noms propres au projet | réseau privé `<projet>-<env>-internal`, services `<projet>-db`, `<projet>-redis` |
| C4 : contrôle de santé du web et de la base, **par le réseau** | présents (`127.0.0.1`, jamais le socket) |
| Contrôle de santé **réel** du worker et du planificateur | `pgrep -f 'artisan [q]ueue:work'` (le motif entre crochets évite que `pgrep` se trouve lui-même) ; `test-templates.sh` refuse un contrôle désactivé |
| Cache **jamais sans mot de passe** | `--requirepass ${REDIS_PASSWORD:?…}` : sans valeur, la composition est refusée ; `REDIS_PASSWORD` est dans les exemples d'environnement, vide, à remplir par environnement |
| C7 : images taguées par commit | `image: <projet>:${IMAGE_TAG}` |
| C8 : redémarrage, limite mémoire, rotation des journaux | présents sur chaque service |
| C11 : sauvegarde chiffrée **sur S3 seulement** | service `backup` ; `BACKUP_DISABLED=1` pour un environnement non sauvegardé |
| C12 : observabilité proportionnée | labels `observability.*` ; un front n'a besoin que de la sonde |

## 5. Les modèles sont testés

`tests/test-templates.sh` copie chaque modèle dans un projet factice avec ses fichiers d'environnement d'exemple et lance `deploy.sh check` pour **les deux environnements** : un modèle qui ne
passerait plus le contrôle de la plateforme fait échouer le test. Il vérifie aussi, sans Docker, les règles ci-dessus (pas de `ports:`, services nommés `mon-…`, image taguée, limites).
