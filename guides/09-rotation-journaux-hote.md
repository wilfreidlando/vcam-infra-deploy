# 9. Rotation des journaux Docker (tout le serveur)

Par défaut, Docker garde **tous** les journaux de chaque conteneur, sans limite. Un
projet bavard finit par remplir le disque, et **tous** les sites tombent. Les
projets au standard ont leur propre rotation (bloc `logging`). Ce réglage la donne
aussi à tous les autres.

## Ce que fait le script

`infra/host/apply-daemon-config.sh` :
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
$ /app/vps-platform/infra/host/apply-daemon-config.sh       # affiche la nouvelle config, demande « oui »
$ docker info --format 'log-driver={{.LoggingDriver}} live-restore={{.LiveRestoreEnabled}}'
log-driver=json-file live-restore=true
$ curl -sI https://<un site> | head -1                       # les sites répondent toujours
```

## Ce qui change, et quand

- La rotation s'applique aux conteneurs **créés après** le réglage, c'est-à-dire au
  prochain `docker compose up -d` qui recrée chaque conteneur. Les conteneurs
  existants gardent leurs anciens journaux jusque-là.
- Libérer tout de suite l'espace d'un conteneur bavard, sans le redémarrer :
  `truncate -s 0 $(docker inspect -f '{{.LogPath}}' <conteneur>)`.

## Retour arrière

```bash
$ ls /etc/docker/daemon.json.bak.*
$ cp /etc/docker/daemon.json.bak.<date> /etc/docker/daemon.json && systemctl restart docker
```
