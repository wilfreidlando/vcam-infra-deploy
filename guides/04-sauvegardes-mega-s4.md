# 4. Sauvegardes vers MEGA S4

L'agent `images/db-backup` envoie chaque nuit une copie **chiffrée** de chaque
base vers un stockage compatible S3. MEGA S4 en est un. Ce guide prépare MEGA S4 et
vérifie qu'un envoi réel fonctionne depuis le serveur, avant de brancher les
projets.

## Étape 1 — Côté MEGA S4 (console web)

1. Créer un **bucket** dédié, par exemple `visibilitycam-backups`. Un seul bucket
   suffit pour tous les projets : chacun écrit dans son propre dossier.
2. Créer une **clé d'accès** (Access key ID + Secret access key) réservée aux
   sauvegardes. Si MEGA le permet, la limiter à ce bucket.
3. Noter l'**endpoint S3** et la **région** affichés par la console, par exemple
   `https://s3.eu-central-1.s4.mega.io` et `eu-central-1`. **Recopiez exactement**
   ce qu'affiche votre console : la région dépend de votre compte.

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
