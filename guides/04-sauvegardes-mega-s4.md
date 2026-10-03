# 4. Sauvegardes vers MEGA S4

L'agent `images/db-backup` envoie chaque nuit une copie **chiffrée** de chaque
base vers un stockage compatible S3. MEGA S4 en est un. Ce guide prépare MEGA S4 et
vérifie qu'un envoi réel fonctionne depuis le serveur, avant de brancher les
projets.

## Étape 1 — Côté MEGA S4 (console web)

MEGA S4 est le stockage « objet » de MEGA, inclus dans les offres **Pro**. Les
intitulés ci-dessous sont ceux de la console MEGA au moment de la rédaction ; s'ils
ont un peu changé, cherchez les mêmes mots (*Object storage*, *Bucket*, *Access
keys*).

**1.1 Ouvrir la console S4**
1. Se connecter sur https://mega.io (bouton *Log in*), avec le compte de l'entreprise.
2. Dans le menu de gauche de l'application, cliquer sur **Object storage** (ou
   **S4**). Si la rubrique n'apparaît pas, l'offre du compte n'inclut pas S4 : il
   faut passer à une offre Pro, ou utiliser un autre stockage compatible S3
   (Backblaze B2, Wasabi, Cloudflare R2…). La suite du guide est identique.

**1.2 Créer le bucket**
1. **Create bucket**.
2. Nom : `visibilitycam-backups`. Minuscules, chiffres et tirets seulement ; le nom
   doit être unique. S'il est pris, ajoutez un suffixe (`visibilitycam-backups-01`)
   et utilisez ce nom partout ensuite.
3. **Région** : choisir la plus proche du VPS (Europe, par exemple), et la noter.
4. **Ne pas** activer d'accès public, ni « Object URL access » : les sauvegardes ne
   doivent être lisibles par personne d'autre que l'agent.
5. Valider. Un seul bucket suffit pour tous les projets : chacun écrit dans son
   propre dossier.

**1.3 Créer la clé d'accès**
1. Dans la console S4 : **Access keys** → **Manage keys** (ou *Create access key*).
2. Nom : `vps-backups`. Si la console permet de **limiter la clé à un bucket**,
   choisir `visibilitycam-backups`.
3. Valider. La console affiche :
   - **Access key ID** → c'est `AWS_ACCESS_KEY_ID` (ou `BACKUP_S3_ACCESS_KEY_ID`) ;
   - **Secret access key** → c'est `AWS_SECRET_ACCESS_KEY` (ou
     `BACKUP_S3_SECRET_ACCESS_KEY`). Le **secret n'est montré qu'une fois** : le
     copier tout de suite dans le gestionnaire de mots de passe (« MEGA S4 —
     sauvegardes VPS »).

**1.4 Relever l'endpoint et la région**
Ils sont affichés dans les réglages du bucket (*Settings*) ou dans la liste des
*Endpoints* de la console. Ils ont la forme :

| Valeur | Exemple | Variable |
| --- | --- | --- |
| Endpoint S3 | `https://s3.eu-central-1.s4.mega.io` | `BACKUP_S3_ENDPOINT` |
| Région | `eu-central-1` | `AWS_DEFAULT_REGION` (ou `BACKUP_S3_REGION`) |

**Recopiez exactement** ce qu'affiche votre console : la région dépend du choix fait
en 1.2. Endpoint et région doivent correspondre, sinon l'envoi est refusé.

## Étape 2 — Vérifier l'accès depuis le serveur (sans rien installer)

```bash
$ export AWS_ACCESS_KEY_ID='<clé>' AWS_SECRET_ACCESS_KEY='<secret>' AWS_DEFAULT_REGION='<région>'
$ S3='<endpoint>'          # ex. https://s3.eu-central-1.s4.mega.io
$ echo test > /tmp/s4-test.txt
$ docker run --rm -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_DEFAULT_REGION -v /tmp:/tmp \
    amazon/aws-cli:2.37.9 --endpoint-url "$S3" s3 cp /tmp/s4-test.txt s3://visibilitycam-backups/test/
$ docker run --rm -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_DEFAULT_REGION \
    amazon/aws-cli:2.37.9 --endpoint-url "$S3" s3 ls s3://visibilitycam-backups/test/
$ docker run --rm -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_DEFAULT_REGION \
    amazon/aws-cli:2.37.9 --endpoint-url "$S3" s3 rm s3://visibilitycam-backups/test/s4-test.txt
$ unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
```

Les trois commandes doivent réussir : upload, liste, suppression. Si l'une échoue,
corriger l'endpoint ou la région avant d'aller plus loin. L'agent utilise
exactement ces mêmes appels.

## Étape 3 — Une phrase de passe par projet et par environnement

```bash
$ openssl rand -base64 32
```

À ranger **immédiatement** dans le gestionnaire de mots de passe de l'entreprise, au
nom de « Sauvegardes \<projet\> \<environnement\> ». **Sans elle, aucune sauvegarde
n'est restaurable** : MEGA ne voit que des données chiffrées, et personne ne peut
les relire sans cette phrase.

## Étape 4 — Variables à mettre dans le `.env` de chaque projet

```dotenv
BACKUP_PASSPHRASE=<phrase de l'étape 3>
BACKUP_TIME=02:30                     # UTC — décaler de 15 min d'un projet à l'autre
BACKUP_S3_ENDPOINT=<endpoint>
BACKUP_S3_BUCKET=visibilitycam-backups
BACKUP_S3_PREFIX=backups
AWS_ACCESS_KEY_ID=<clé>
AWS_SECRET_ACCESS_KEY=<secret>
AWS_DEFAULT_REGION=<région>
BACKUP_RETENTION_DAYS=30
BACKUP_LOCAL_KEEP=7
```

**Noms des variables selon le projet** : le Core (et les projets issus de
`templates/compose.laravel.yaml`) lisent `AWS_ACCESS_KEY_ID`,
`AWS_SECRET_ACCESS_KEY` et `AWS_DEFAULT_REGION`. WILMANAGER garde ces noms pour son
propre disque S3 Laravel ; pour les sauvegardes, il lit à la place :

```dotenv
BACKUP_S3_ACCESS_KEY_ID=<clé>
BACKUP_S3_SECRET_ACCESS_KEY=<secret>
BACKUP_S3_REGION=<région>
```

Le service `backup` à ajouter au compose de chaque projet est décrit dans
`images/db-backup/README.md`. Il est déjà présent dans le Core. Pour une base
MySQL ou MariaDB, construire l'image avec `BASE=mariadb:11` et mettre
`BACKUP_ENGINE=mysql`, avec les variables `MYSQL_*`.

## Étape 5 — Première sauvegarde et vérification

Depuis le dossier du projet :

```bash
$ docker compose -p <projet>-prod -f compose.prod.yaml --env-file .env run --rm backup backup.sh
backup: pg_dump … → /backups/<projet>-…-scheduled.dump.enc
backup: uploaded to s3://visibilitycam-backups/backups/<projet>/…
```

Le fichier doit apparaître dans la console MEGA, sous `backups/<projet>/`.

## Étape 6 — Tester une restauration (puis une fois par mois)

Une sauvegarde n'est fiable qu'une fois restaurée avec succès. Restaurez la dernière
sauvegarde de production dans le **staging** du même projet : la procédure est dans
`README.md` § 9. L'heure de sauvegarde planifiée apparaît dans
`docker logs <projet>-backup`.

## Testé

`tests/test-backup.sh` passe 34 vérifications contre de vrais PostgreSQL 18,
MySQL 8.4 et MariaDB 11 et un stockage S3 (SeaweedFS) : chiffrement, envoi,
rétention, rotation, phrase de passe erronée refusée, restauration avec les accents.
L'étape 2 ci-dessus ajoute la vérification que seul le serveur peut faire : l'accès
réel à **votre** compte MEGA.
