# Runbook : la base de données est inaccessible

| Gravité | Qui prévenir |
| --- | --- |
| **Production : critique.** Une base inaccessible coupe le site ; une base corrompue peut perdre des données | le responsable du projet et le responsable de la plateforme |

## 1. Première minute

```bash
$ docker ps -a --format '{{.Names}} | {{.Status}}' | grep -i <projet>      # la base tourne-t-elle ? « healthy » ?
$ docker logs --tail 80 <conteneur-base>                                    # démarrage, erreurs, espace disque
$ df -h / ; free -m                                                         # disque plein ? mémoire ?
```

**Avant toute action sur une base : ne pas la supprimer, ne pas supprimer son volume.**

## 2. Les cas, du plus fréquent au plus rare

| Symptôme | Cause probable | Action |
| --- | --- | --- |
| `Connection refused` pendant les **migrations d'un déploiement**, toujours la même adresse IP | Le nom de la base mène à **un autre projet** (nom générique `db` publié aussi sur `nginx-proxy`) | `cd /app/<projet>/<env> && /app/vps-platform/bin/deploy.sh check <env>` le confirme ; nommer les services `<app>-db`, `<app>-redis` (contrat C3), voir [REX 2026-10-04](../retours-experience/2026-10-04-premier-deploiement-skills-devops.md) |
| La base est `Exited` | Disque plein, mémoire, erreur d'initialisation | Journal du conteneur ; [Disque plein](disque-plein.md) ; mémoire : `dmesg \| grep -i 'out of memory'` |
| La base démarre mais l'application ne s'y connecte pas | Mauvais `DB_HOST` ou mot de passe dans le `.env` | Comparer **les noms** de variables avec `.env.example` (jamais les valeurs dans un message) |
| La base paraît prête puis refuse (premier démarrage) | Healthcheck par le socket local au lieu du réseau (clause C4) | Healthcheck `pg_isready -h 127.0.0.1` ; ne pas relancer en boucle |
| Erreurs de lecture, fichiers corrompus | Arrêt brutal, disque plein, panne matérielle | Section 3 : restaurer |

## 3. Restaurer une sauvegarde

Une sauvegarde chiffrée est prise chaque nuit et avant chaque migration en production
(`pre-deploy-*`). **Restaurer dans le staging d'abord**, pour vérifier le fichier, puis en
production dans un créneau annoncé.

```bash
$ cd /app/<projet>/staging
$ read -rs RESTORE_PASSPHRASE && export RESTORE_PASSPHRASE       # saisie à la main, jamais écrite dans un fichier
$ /app/vps-platform/bin/restore.sh staging <fichier>.dump.enc    # vérifier l'application dans le staging
```

Pour la production : `restore.sh prod <fichier>` après vérification et accord du responsable
du projet. Si l'incident a suivi un déploiement, prendre la dernière sauvegarde `pre-deploy-*`.
Détails : [README § 9](../../README.md#9-sauvegardes) et [guide 12](../../guides/12-reprise-apres-sinistre.md).

> Si aucune sauvegarde n'existe pour ce projet, **le dire tout de suite** au responsable :
> c'est un écart à la clause C11 qui devient une perte de données.

## 4. Vérification

- `docker ps` : la base est « healthy ».
- `deploy.sh status` et le site répondent ; une opération de lecture et d'écriture réussit.
- Une nouvelle sauvegarde a été prise.

## 5. Ce qu'il ne faut pas faire

- `docker volume rm`, `docker compose down -v`, `docker system prune --volumes` : suppriment
  les données.
- Deux conteneurs de base sur le **même volume** : corruption garantie. `deploy.sh` le refuse
  volontairement ; supprimer nommément l'ancien conteneur (`docker rm -f <nom>`, les volumes
  restent), jamais en contournant le contrôle.
- Restaurer en production sans avoir testé le fichier en staging.
- Coller un mot de passe dans un message, un ticket ou un journal.

## 6. Après

Retour d'expérience : la cause vérifiée, la durée de coupure, la dernière sauvegarde
utilisable, et le contrôle automatique ajouté.
