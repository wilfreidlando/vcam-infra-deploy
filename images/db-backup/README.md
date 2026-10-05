# db-backup — agent de sauvegarde standard du VPS

Une image pour tous les projets du serveur : dump de la base, chiffrement AES-256
(openssl, clé dérivée par PBKDF2) et envoi vers un stockage S3 compatible (MEGA S4, R2, B2…). **Les sauvegardes vivent sur S3, jamais sur le disque du serveur** : la copie locale est supprimée dès qu'elle est envoyée ([pourquoi](../../docs/reference/sauvegardes.md)).
Planifiée par `crond` dans le conteneur, rien à installer sur l'hôte.

## Ajouter à un projet

```yaml
  backup:
    build: { context: <chemin vers images/db-backup> }   # MySQL/MariaDB : ajouter args: { BASE: "mariadb:11.4" }
    image: vps/db-backup:1                                      # MySQL/MariaDB : vps/db-backup-mysql:1
    restart: unless-stopped
    environment:
      BACKUP_NAME: mon-saas-prod          # préfixe des fichiers, unique sur le VPS
      BACKUP_ENGINE: postgres             # ou mysql
      PGHOST: postgres                    # (mysql : MYSQL_HOST, MYSQL_DATABASE, MYSQL_USER, MYSQL_PASSWORD)
      PGDATABASE: ${DB_DATABASE}
      PGUSER: ${DB_USERNAME}
      PGPASSWORD: ${DB_PASSWORD}
    env_file: [.env]                      # BACKUP_PASSPHRASE, BACKUP_S3_*, AWS_*
    volumes: [backups:/backups]
    deploy: { resources: { limits: { cpus: "0.5", memory: 256M } } }
```

## Variables

| Variable | Défaut | Rôle |
| --- | --- | --- |
| `BACKUP_PASSPHRASE` | — (obligatoire) | Phrase de chiffrement. **À conserver hors du serveur** (gestionnaire de mots de passe) : sans elle, aucune restauration possible. |
| `BACKUP_TIME` | `02:30` | Heure quotidienne (UTC, HH:MM). Décalez les projets entre eux (02:30, 02:45…). |
| `BACKUP_LOCAL_KEEP` | `0` | Copies gardées sur le VPS **après** un envoi réussi. `0` = aucune (recommandé). Une valeur positive est une exception : elle occupe le disque de tous les sites. |
| `BACKUP_PENDING_MAX` | `3` | Copies **en attente** gardées quand S3 est injoignable (renvoyées au passage suivant). Borne le disque. |
| `BACKUP_DISABLED` | `0` | `1` : cet environnement n'est volontairement pas sauvegardé (un staging jetable) : l'agent ne fait rien, le dit, et reste `healthy`. |
| `BACKUP_S3_ENDPOINT` | — | MEGA S4 : `https://s3.<région>.s4.mega.io` (voir votre console MEGA). |
| `BACKUP_S3_BUCKET` | — (**obligatoire**) | Sans bucket, l'agent **refuse** de sauvegarder (sortie en erreur) : pas de sauvegarde « locale seulement ». |
| `BACKUP_S3_PREFIX` | `backups` | Dossier dans le bucket. |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_DEFAULT_REGION` | — | Clés S3 (MEGA S4 fournit des clés compatibles). |
| `BACKUP_RETENTION_DAYS` | `30` | Les copies distantes plus anciennes sont supprimées. |
| `RESTORE_MODE` | `replace` | **Restauration** (variable de `restore.sh`, pas du `.env`), PostgreSQL et MySQL/MariaDB. `replace` : la base revient **exactement** à l'état de la sauvegarde ; tout ce qui a été créé depuis (une table de migration ratée, une table de test) disparaît. `merge` : ancien comportement, les objets de la sauvegarde sont recréés, ceux créés depuis restent. |

## Utilisation

```bash
docker compose exec backup backup.sh                       # sauvegarde immédiate (sa sortie reste dans VOTRE terminal)
docker compose exec backup sh -c 'backup.sh >/proc/1/fd/1 2>&1'   # idem, mais visible dans docker logs et Grafana
docker compose exec backup ls -lh /backups                 # normalement vide : seules les copies dont l'envoi a échoué (3 au plus)
docker compose exec backup restore.sh <fichier>            # restauration (arrêtez l'app avant)
RESTORE_MODE=merge …                                       # ancien comportement, voir la variable ci-dessus
docker compose exec backup restore.sh s3://bucket/backups/mon-saas-prod/<fichier>
```

Testé contre de vrais serveurs PostgreSQL 18, MySQL 8.4 et MariaDB 11 et un
stockage S3 : `tests/test-backup.sh`.

Déchiffrer une copie à la main (hors de l'agent) :

```bash
openssl enc -d -aes-256-cbc -pbkdf2 -iter 600000 -in <fichier>.dump.enc -out dump   # demande la phrase
# PostgreSQL : pg_restore -l dump · MySQL : gunzip -c dump | less
```

**Une sauvegarde jamais restaurée n'est pas une sauvegarde** : restaurez une
copie dans le staging une fois par mois (`README.md`, § Protocole).

## Comment fonctionne la restauration

### PostgreSQL

1. Le fichier est **déchiffré** : une mauvaise phrase de passe échoue ici (« bad decrypt »), **avant** de toucher à la base.
2. Le script SQL de restauration est **généré** à partir de l'archive : une archive corrompue ou tronquée échoue ici aussi,
   avant de toucher à la base.
3. Tout s'exécute dans **une seule transaction** : en mode `replace`, le schéma `public` est réinitialisé puis la sauvegarde
   rejouée. Si une étape échoue, la transaction est annulée et **la base n'a pas bougé**.

Limites : seul le schéma `public` est réinitialisé (les autres schémas, rares, sont fusionnés) ; les droits donnés à un rôle autre
que le propriétaire ne sont pas restaurés (`--no-privileges`).

### MySQL et MariaDB

1. Le fichier est **déchiffré** (mauvaise phrase de passe : refus avant de toucher à la base).
2. Le dump doit être **complet** : flux gzip valide **et** ligne finale `-- Dump completed`. Un fichier tronqué est refusé, la base n'est
   pas touchée.
3. En mode `replace`, les **vues, tables, procédures, fonctions et événements** de la base sont supprimés (clés étrangères suspendues),
   puis le dump est rejoué.

Les lignes `/*M!… NOTE_VERBOSITY … */` des dumps récents sont retirées à la restauration : MariaDB 10.7.8 les exécute sans connaître cette variable
(sinon : `Unknown system variable 'NOTE_VERBOSITY'`).

**Limite importante : ce n'est pas atomique.** Le DDL de MySQL/MariaDB n'est pas transactionnel : si le rejeu échoue en cours de route,
la base est dans un état intermédiaire. Le fichier chiffré reste disponible : relancer la restauration. C'est la raison de la validation
avant tout `DROP`.

Versions vérifiées par `tests/test-backup.sh` : **PostgreSQL 18, MySQL 8.4, MariaDB 10.7 et MariaDB 11.4**, avec un client `mariadb:11.4`
(`mariadb-dump` lit les serveurs MySQL 8.4 et MariaDB 10.7 à 11.4).
