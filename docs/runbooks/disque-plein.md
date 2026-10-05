# Runbook : disque plein

| Gravité | Qui prévenir |
| --- | --- |
| **URGENT à plus de 90 %** : quand le disque est plein, les bases cessent d'écrire et peuvent se corrompre | le responsable de la plateforme immédiatement |

## 1. Première minute

L'alerte « Disque du serveur presque plein » (Grafana, dossier Plateforme) se déclenche à 85 % depuis 10 minutes ; le tableau
**Serveur — vue d'ensemble** montre la courbe.

```bash
$ df -h /                       # quel pourcentage ?
$ docker system df              # ce que Docker occupe : images, conteneurs, volumes, cache de build
```

À plus de 90 %, **agir tout de suite** (section 3), puis comprendre (section 2).

## 2. Qui occupe l'espace

| Poste | Commande | Lecture |
| --- | --- | --- |
| Journaux des conteneurs | `sudo du -sh /var/lib/docker/containers/*/*-json.log \| sort -h \| tail -5` | Un projet bavard sans rotation : cause la plus fréquente |
| Images inutilisées, cache de build | `docker system df` (colonnes `RECLAIMABLE`) | Se récupère sans risque (section 3) |
| Volumes | `docker system df -v` | **Données** : ne jamais supprimer sans analyse ([plus bas](#ce-quil-ne-faut-pas-faire)) |
| Copies de sauvegarde en attente | dans le conteneur `backup` de chaque projet : `ls -lh /backups` | **Normalement, seulement le marqueur** `.last-upload` : les copies vivent sur S3 et sont effacées après l'envoi. Des fichiers `.dump.enc` (trois au plus par projet) signalent un **envoi vers S3 qui échoue** : voir [Sauvegardes](../reference/sauvegardes.md) |
| Autre | `sudo du -xh / --max-depth=2 \| sort -h \| tail -15` | Lecture seule, un peu longue |

## 3. Libérer de la place, du plus sûr au moins sûr

```bash
$ docker image prune -f           # images sans étiquette : sans risque
$ docker builder prune -f         # cache de build : sans risque, les builds suivants seront plus longs
```

Si un journal de conteneur est énorme et que le projet est sain, **dernier recours**
(les journaux de ce conteneur sont perdus ; le conteneur continue de tourner) :

```bash
$ sudo truncate -s 0 /var/lib/docker/containers/<id>/<id>-json.log
```

Puis **corriger la cause** : la rotation des journaux (`max-size`) dans le compose du projet
(clause C8) ou pour tout le serveur ([guide 9](../../guides/09-rotation-journaux-hote.md)).

## 4. Vérification

- `df -h /` : en dessous de 80 %.
- `vps-audit.sh` : plus de constat « journaux sans rotation » pour le projet fautif.
- Les bases tournent : `docker ps -a | grep -i db`, conteneurs « healthy ».

## Ce qu'il ne faut pas faire

- `docker system prune -a --volumes`, `docker volume prune`, `docker volume rm` : ils
  suppriment des **volumes**, donc des bases de données. Des volumes « orphelins » peuvent
  contenir les seules copies de données d'un projet arrêté.
- Supprimer des fichiers dans `/var/lib/docker` à la main.
- Supprimer une copie `.dump.enc` en attente sans avoir vérifié que l'envoi vers S3 a réussi : c'est peut-être la seule copie.

## 5. Après

Retour d'expérience : quel projet a rempli le disque, pourquoi la rotation n'était pas
active, quelle alerte aurait dû prévenir (une alerte disque dans Grafana ou la
surveillance externe).
