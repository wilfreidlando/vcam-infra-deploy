# Exercice de restauration (à faire chaque mois, sans incident)

**Une sauvegarde jamais restaurée n'est pas une sauvegarde.** Cet exercice prouve, avant qu'un
incident ne l'exige, que la chaîne complète fonctionne : sauvegarde, chiffrement, copie hors du
serveur, déchiffrement, restauration. Il se fait **sans incident**, à intervalle régulier
([clause C11 du contrat](../05-contrat-projet.md)).

| Gravité | Fréquence | Durée | Coupure |
| --- | --- | --- | --- |
| Aucune (exercice) | Chaque mois, par projet | 15 minutes | Staging : environ 1 minute. Production : le site est arrêté 1 à 2 minutes, voir la variante B |

## Ce que l'exercice prouve

| Maillon | Preuve |
| --- | --- |
| La sauvegarde se fait | `backup.sh` affiche `uploaded to s3://…` (la copie **n'est pas** gardée sur le serveur) |
| Elle est copiée hors du serveur | Le message `uploaded to s3://…` apparaît et l'objet est listé dans le bucket |
| Elle est lisible | La restauration déchiffre le fichier avec la phrase du projet (« bad decrypt » sinon, avant de toucher à la base) |
| Elle **remplace réellement** les données | Une table-témoin créée **après** la sauvegarde **a disparu** après la restauration |
| L'application repart | Le site répond HTTP 200 après la restauration |

## Avant de commencer

- [ ] Les variables `BACKUP_PASSPHRASE`, `BACKUP_S3_ENDPOINT` (avec `https://`), `BACKUP_S3_BUCKET`, `AWS_ACCESS_KEY_ID`,
      `AWS_SECRET_ACCESS_KEY`, `AWS_DEFAULT_REGION` sont renseignées dans le `.env` de l'environnement
      ([agent `db-backup`](../../images/db-backup/README.md)). **Sans bucket, l'agent refuse de sauvegarder** : les sauvegardes ne vivent que sur S3 ([Sauvegardes](../reference/sauvegardes.md)).
- [ ] La **phrase de chiffrement est conservée hors du serveur** (gestionnaire de mots de passe). Sans elle, une copie
      sur S3 reste indéchiffrable si le serveur est perdu.
- [ ] Le fichier `.env` est en mode `600` (`ls -l`), jamais lisible par tous.
- [ ] Personne n'écrit dans l'application pendant l'exercice : ce qui serait écrit entre la sauvegarde et la fin de la
      restauration serait perdu.

## Variante A — dans le staging (la règle)

Les données de staging sont jetables : aucun risque pour la production.

```bash
$ cd /app/<projet>/staging
# 1. Sauvegarde immédiate de la base de staging (si le staging est en BACKUP_DISABLED=1, passer au scénario suivant)
$ docker exec <projet>-staging-backup-1 backup.sh
#    note l'adresse affichée : « uploaded to s3://<bucket>/<préfixe>/<projet>-staging/<fichier> »
#    (la copie n'est pas gardée sur le serveur : elle est sur S3)

# 2. Table-témoin, créée APRÈS la sauvegarde (identifiants lus dans le conteneur, jamais affichés)
$ docker exec <projet>-staging-<projet>-db-1 sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "CREATE TABLE restore_test_marker (id int);"'

# 3. Restauration depuis S3 (la confirmation demandée est le nom <projet>-staging)
$ echo <projet>-staging | vps-restore staging s3://<bucket>/<préfixe>/<projet>-staging/<fichier>

# 4. Vérification : la table-témoin n'existe plus, le site répond
$ docker exec <projet>-staging-<projet>-db-1 sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "\dt restore_test_marker"'
#    attendu : « Did not find any relation named "restore_test_marker" »
$ cd /app/<projet>/staging && vps-deploy status
```

`restore.sh` arrête les services applicatifs (tout sauf la base et la sauvegarde), restaure avec l'image `db-backup`,
puis les redémarre. **La restauration se fait toujours depuis S3** : les sauvegardes ne sont pas gardées sur le serveur (c'est
ce qui l'empêche de se remplir). L'adresse `s3://<bucket>/<préfixe>/<projet>-<env>/<fichier>` est celle affichée par `backup.sh`,
ou listée par `aws s3 ls`. Seule exception : une copie dont l'envoi a **échoué** reste dans `/backups` (trois au plus).

### Le scénario le plus réaliste : la copie de production dans le staging

C'est ce qu'on ferait après un incident. La **phrase de production est différente** de celle du staging (clause C10) :
la saisir à la main, jamais dans un fichier.

```bash
$ cd /app/<projet>/staging
$ read -rs RESTORE_PASSPHRASE && export RESTORE_PASSPHRASE
$ vps-restore staging s3://<bucket>/<préfixe>/<projet>-prod/<fichier>
```

Cela met des données réelles dans le staging : le réinitialiser ensuite si besoin (README, [sauvegardes](../reference/sauvegardes.md)).

## Variante B — en production (exceptionnelle, dans un créneau annoncé)

À réserver aux cas où la production elle-même doit être prouvée (premier exercice d'un projet, avant une migration lourde).
Elle **arrête le site** 1 à 2 minutes et **remplace les données** : à n'envisager qu'avec l'accord du responsable du projet.

1. Prendre une sauvegarde fraîche (étape 1 ci-dessus, sur la production), pour que tout ce qui existe soit restauré.
2. Relever l'état avant : nombre de tables, nombre de migrations, empreinte de la table `migrations`.
3. Créer la table-témoin, **après** la sauvegarde.
4. `restore.sh prod s3://…` (la confirmation demandée est `<projet>-prod`).
5. Relever l'état après et comparer : mêmes tables, mêmes migrations, table-témoin disparue, site en HTTP 200.

Un script qui enchaîne ces cinq étapes avec une confirmation explicite et un rapport sans secret a été utilisé pour le
premier exercice de `skills-devops` : voir l'[inventaire](../inventaire/README.md).

## Critères de réussite

- [ ] La table-témoin a disparu.
- [ ] Mêmes tables et mêmes migrations qu'avant (même empreinte).
- [ ] Le site répond HTTP 200.
- [ ] L'objet est listé dans le bucket.

Si un critère échoue : **ne pas écrire dans l'application**, relancer `restore.sh` depuis la même copie, puis écrire un
[retour d'expérience](../retours-experience/README.md).

## Pièges connus

| Symptôme | Cause | Quoi faire |
| --- | --- | --- |
| `uploaded to s3://…` n'apparaît pas, `backup: BACKUP_S3_BUCKET is empty — refusing to back up onto the server's own disk` | Variables S3 vides, ou conteneur non recréé après modification du `.env` (un conteneur ne relit son `.env` qu'à sa création) | Renseigner le `.env`, recréer **seulement** le service : `docker compose -p <projet>-<env> -f compose.prod.yaml --env-file <fichier> up -d --no-deps --no-build backup` |
| Erreur de connexion S3 | `BACKUP_S3_ENDPOINT` sans `https://` : `aws --endpoint-url` exige une URL complète | Ajouter le schéma |
| `bad decrypt` | Mauvaise phrase de chiffrement (staging et production en ont deux) | Saisir la phrase de l'environnement d'origine de la copie |
| La table-témoin existe toujours après la restauration | **L'image de l'agent est antérieure au 2026-10-05** : l'ancien `restore.sh` ne supprimait pas ce qui avait été créé après la sauvegarde (voir le [retour d'expérience](../retours-experience/2026-10-05-la-restauration-ne-remplacait-pas-la-base.md)) | Mettre la plateforme à jour, puis **reconstruire l'image** de l'agent (`vps-deploy build`) et recréer le service `backup` ; un `git pull` seul ne suffit pas |
| Même après mise à jour, la table-témoin existe | `RESTORE_MODE=merge` est défini | Retirer `RESTORE_MODE` |

## Après

Noter la date, le fichier restauré et le résultat dans le dernier fichier de [`docs/inventaire/`](../inventaire/README.md) :
un exercice sans trace n'a pas eu lieu. Aucun secret dans cette note.
