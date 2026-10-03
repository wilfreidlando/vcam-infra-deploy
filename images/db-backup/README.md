# db-backup — agent de sauvegarde standard du VPS

Une image pour tous les projets du serveur : dump de la base, chiffrement GPG
AES-256, copie locale et copie vers un stockage S3 compatible (MEGA S4, R2, B2…).
Planifiée par `crond` dans le conteneur, rien à installer sur l'hôte.

## Ajouter à un projet

```yaml
  backup:
    build: { context: <chemin vers infra/images/db-backup> }
    image: vps/db-backup:1
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
| `BACKUP_CRON` | `30 2 * * *` | Horaire (UTC). Décalez les projets entre eux (2h30, 2h45…). |
| `BACKUP_LOCAL_KEEP` | `7` | Nombre de copies gardées sur le VPS. |
| `BACKUP_S3_ENDPOINT` | — | MEGA S4 : `https://s3.<région>.s4.mega.io` (voir votre console MEGA). |
| `BACKUP_S3_BUCKET` | — | Sans bucket : copie locale seulement. |
| `BACKUP_S3_PREFIX` | `backups` | Dossier dans le bucket. |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_DEFAULT_REGION` | — | Clés S3 (MEGA S4 fournit des clés compatibles). |
| `BACKUP_RETENTION_DAYS` | `30` | Les copies distantes plus anciennes sont supprimées. |

## Utilisation

```bash
docker compose exec backup backup.sh                       # sauvegarde immédiate
docker compose exec backup ls -lh /backups                 # copies locales
docker compose exec backup restore.sh <fichier>            # restauration (arrêtez l'app avant)
docker compose exec backup restore.sh s3://bucket/backups/mon-saas-prod/<fichier>
```

**Une sauvegarde jamais restaurée n'est pas une sauvegarde** : restaurez une
copie dans le staging une fois par mois (`infra/README.md`, § Protocole).
