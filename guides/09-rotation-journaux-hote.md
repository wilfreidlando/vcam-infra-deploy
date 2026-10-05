# 9. Rotation des journaux Docker (tout le serveur)

Par défaut, Docker garde **tous** les journaux de chaque conteneur, sans limite. Un
projet bavard finit par remplir le disque, et **tous** les sites tombent. Les
projets au standard ont leur propre rotation (bloc `logging`). Ce réglage la donne
aussi à tous les autres.

## Pourquoi c'est à faire (constat du 2026-10-05)

Sur le serveur, **aucun réglage global n'existe** : seule une petite minorité de conteneurs a une rotation (ceux des projets au standard). Les journaux de tous les autres
**grossissent sans limite**, et celui du proxy (qui journalise chaque requête de tous les sites) pèse déjà **plusieurs Go**, plus de la moitié du total. Ce n'est pas urgent tant que le disque est loin d'être plein,
mais c'est exactement le scénario du disque qui se remplit **sans que personne ne le voie**. Voir aussi [Serveur chargé](../docs/runbooks/serveur-charge.md).

**Regarder, sans rien changer :**

```bash
$ cat /etc/docker/daemon.json                      # absent ou sans log-opts : pas de rotation globale
$ du -sh /var/lib/docker/containers                # le total
$ docker inspect -f '{{.Name}} {{.LogPath}}' nginx-proxy | cut -d' ' -f2 | xargs ls -lh   # le journal du proxy
```

## Ce que fait le script

`host/apply-daemon-config.sh` :
1. sauvegarde `/etc/docker/daemon.json` ;
2. y **ajoute** la rotation (20 Mo × 5 fichiers par conteneur) et `live-restore`,
   sans rien supprimer de l'existant ;
3. valide le résultat avec Docker lui-même, et n'écrit rien s'il est invalide ;
4. recharge Docker pour activer `live-restore`, **sans redémarrer** les conteneurs ;
5. seulement ensuite, redémarre le démon Docker. Grâce à `live-restore`, **les
   conteneurs continuent de tourner** pendant ce redémarrage.

Si `live-restore` ne s'active pas au rechargement, le script **s'arrête** et ne
redémarre pas Docker.

## Quand et comment

En heure creuse : une interruption réseau de quelques secondes reste possible
pendant le redémarrage du démon.

```bash
$ apt install -y jq
$ /app/vps-platform/host/apply-daemon-config.sh       # affiche la nouvelle config, demande « oui »
$ docker info --format 'log-driver={{.LoggingDriver}} live-restore={{.LiveRestoreEnabled}}'
log-driver=json-file live-restore=true
$ curl -sI https://<un site> | head -1                       # les sites répondent toujours
```

## Ce qui change, et quand

- La rotation s'applique aux conteneurs **créés après** le réglage, c'est-à-dire au
  prochain `docker compose up -d` qui recrée chaque conteneur. Les conteneurs
  existants gardent leurs anciens journaux jusque-là.
- Libérer tout de suite l'espace d'un conteneur bavard, sans le redémarrer :
  `truncate -s 0 $(docker inspect -f '{{.LogPath}}' <conteneur>)`. **Cela efface l'historique de ce conteneur** : pour le proxy, ce sont les journaux d'accès de tous les sites,
  qui ne sont collectés nulle part. S'assurer qu'on n'en a pas besoin, ou les copier avant.
- **Lire un gros journal : `docker logs --tail N`, jamais `--since`.** `--since` relit tout le fichier depuis le début (des minutes pour plusieurs Go) et ajoute de la charge.

## Retour arrière

```bash
$ ls /etc/docker/daemon.json.bak.*
$ cp /etc/docker/daemon.json.bak.<date> /etc/docker/daemon.json && systemctl restart docker
```
