# Scripts modèles d'un projet

> Deux scripts que presque chaque projet finit par écrire, **testés** (`tests/test-scripts-modeles.sh`) : l'exploitation courante d'un environnement (`ops.sh`) et la création de
> ses fichiers d'environnement sans jamais afficher un secret (`make-env.py`). Retour aux [modèles](../README.md).

## 1. Lesquels, et où les copier

| Fichier | Où le copier | Rôle |
| --- | --- | --- |
| [`ops.sh`](ops.sh) | `scripts/ops.sh` du projet | état, journaux, arrêt, démarrage, redémarrage, shell, contrôle, sauvegarde, tableaux Grafana d'**un environnement**, sans le redéployer |
| [`make-env.py`](make-env.py) | `scripts/make-env.py` du projet | crée `.env.<env>` depuis `.env.<env>.example` : un secret **aléatoire et distinct** pour chaque variable secrète vide, **jamais affiché** ; reprend d'un ancien `.env` une **liste blanche** de réglages |

## 2. `ops.sh`

```bash
scripts/ops.sh <environnement> <action>      # status, logs, stop, start, restart, shell, check, backup, obs
```

**À adapter**, en tête du fichier (un seul jeton à remplacer : `<PROJET>`) :

| Réglage | Rôle |
| --- | --- |
| `<PROJET>` | le nom du projet (`APP_NAME` de `platform.env`) : sert au dossier par défaut (`/app/APPS/<PROJET>`) |
| `SHORTCUTS` | les raccourcis de services : `scripts/ops.sh prod logs web` = le service `<PROJET>-web` |
| `HEALTH_PATH` | la route de santé publique que `status` interroge (`/up` par défaut) |
| `DEFAULT_SHELL_SERVICE` | le service que `shell` ouvre sans argument |

**Ce qu'il garantit** (vérifié) : il lit le projet compose, le fichier compose, le fichier d'environnement et la **version déployée** dans `platform.env` et l'état de la plateforme ; il ne supprime
**jamais** un conteneur ni un volume (pas de `down`, de `rm`, de `-v`, de `prune`) ; sur une production, `stop` et `restart` demandent une confirmation tapée (ou `--yes`) ; il n'affiche aucun
secret. `restart` rappelle qu'il **ne relit pas** le fichier d'environnement : pour appliquer une valeur modifiée, c'est `vps-deploy up` ([détail](../../docs/reference/modifier-une-valeur.md)).

**Ajouter une action propre au projet** (console applicative, données de départ, création d'un administrateur, dump de la base…) : un cas de plus dans le `case`, **avec** `confirm` si elle
modifie des données, jamais un `docker compose down`, et **un test de plus** dans votre copie du test. Exemple pour Laravel :
```bash
    artisan)
        [[ $# -gt 0 ]] || die "artisan : indiquer la commande (ex. scripts/ops.sh ${ENV_NAME} artisan about)"
        dc exec "${APP}-app" php artisan "$@"
        ;;
```

## 3. `make-env.py`

```bash
scripts/make-env.py <dossier-du-clone> <env> [--copy-from <ancien .env>]
```
Il lit `.env.<env>.example` dans le dossier, **refuse d'écraser** un `.env.<env>` existant, et écrit le fichier en `660`. Il n'affiche que des **noms** de variables.

**À adapter**, en tête du fichier :

| Liste | Rôle |
| --- | --- |
| `SECRET_KEYS` | les variables secrètes que le modèle laisse **vides** (règle : aucun secret, même factice, dans un dépôt) ; chacune reçoit une valeur aléatoire distincte. Les modèles de la plateforme laissent vides `DB_PASSWORD`, `REDIS_PASSWORD`, `BACKUP_PASSPHRASE`… |
| `COPIED` | ce qu'on reprend d'un ancien `.env` avec `--copy-from` : la clé d'application (sans elle, les données chiffrées sont illisibles), le courrier, les clés des fournisseurs externes. **Jamais** les accès à la base ni au cache, ni `APP_DEBUG`, ni les journaux |

## 4. Les tests

`tests/test-scripts-modeles.sh` : `ops.sh` contre de **faux** `docker`, `curl` et `vps-deploy` qui enregistrent ce qu'on leur demande (la commande exacte, le dossier, ce qui ne doit jamais arriver) ;
`make-env.py` sur de vrais fichiers. Pour votre copie : reprendre le test, remplacer `monprojet`, y ajouter vos actions.
