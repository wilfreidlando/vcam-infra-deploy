# 9. Rotation des journaux Docker (tout le serveur)

Par défaut, Docker garde **tous** les journaux de chaque conteneur, sans limite. Un
projet bavard finit par remplir le disque, et **tous** les sites tombent. Les
projets au standard ont leur propre rotation (bloc `logging`). Ce réglage la donne
aussi à tous les autres.

## Pourquoi c'est à faire (constat du 2026-10-05)

Sur le serveur, **aucun réglage global n'existe** : 269 des 296 conteneurs en marche n'ont pas de limite de taille (seuls ceux des projets au standard en ont une). Leurs journaux
**grossissent sans limite**. Mesure du 2026-10-05, après la troncature du journal du proxy (qui journalise chaque requête de tous les sites) : **2,2 Go au total**, le plus gros journal fait 323 Mo,
sur un disque utilisé à 21 % (1,1 To libres). **Ce n'est donc pas urgent** : le risque est le scénario du disque qui se remplit **sans que personne ne le voie**, pas un incident en cours.
Avant la troncature, le journal du proxy à lui seul pesait plusieurs Go : il peut y revenir, et c'est ce qui justifie la règle globale. Voir aussi [Serveur chargé](../docs/runbooks/serveur-charge.md).

**Regarder, sans rien changer :**

```bash
$ cat /etc/docker/daemon.json                      # absent ou sans log-opts : pas de rotation globale
$ du -sh /var/lib/docker/containers                # le total
$ docker inspect -f '{{.Name}} {{.LogPath}}' nginx-proxy | cut -d' ' -f2 | xargs ls -lh   # le journal du proxy
$ for f in $(ls -S /var/lib/docker/containers/*/*-json.log | head -10); do id=$(basename $(dirname $f) | cut -c1-12); echo "$(du -m $f | cut -f1) Mo  $(docker ps -a --filter id=$id --format '{{.Names}}')"; done   # les 10 plus gros
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

**Heure** : la plus creuse du serveur (la nuit, vers 02 h-04 h). Pendant que le démon est absent, un conteneur qui écrit beaucoup sur sa sortie standard (le proxy, qui journalise chaque requête) peut
remplir son tampon de 64 Ko et **se bloquer** jusqu'au retour du démon : plus le démon est absent longtemps et plus le trafic est élevé, plus le risque est réel. Le script **mesure** cette durée.
Le redémarrage de Docker n'a **jamais été testé** avec plusieurs centaines de conteneurs (voir [les tests](../tests/README.md#hors-périmètre)) : c'est pourquoi le script compare les conteneurs avant et après.

**Avant** (lecture seule, 1 minute) :

```bash
$ command -v jq || apt install -y jq                         # requis par le script ; absent sur ce serveur au 2026-10-05
$ docker info --format 'conteneurs={{.ContainersRunning}} live-restore={{.LiveRestoreEnabled}}'   # noter le nombre
$ cat /etc/docker/daemon.json 2>&1                           # absent = rien à fusionner
```

**Appliquer** :

```bash
$ vps-daemon-config       # affiche la nouvelle config, demande « oui »
```

Le script écrit ce qu'il fait : le nombre de conteneurs en marche **avant**, le temps pendant lequel Docker n'a pas répondu, le nombre **après**, et **nomme tout conteneur manquant** (sortie en erreur : il
ne relance rien tout seul). Résultat attendu : `Aucun conteneur perdu.`

**Après** :

```bash
$ docker info --format 'log-driver={{.LoggingDriver}} live-restore={{.LiveRestoreEnabled}}'
log-driver=json-file live-restore=true
$ curl -sI https://<un site> | head -1                       # les sites répondent toujours
```

## Pourquoi `live-restore` vaut la peine **même sans** la rotation

Sans `live-restore`, **tout redémarrage du démon Docker arrête tous les conteneurs**. Constat du 2026-10-05 : `live-restore` est à `false`, et `unattended-upgrades` est actif sans que `docker-ce` ni `containerd.io` soient bloqués. Aucune mise à jour de ces paquets n'était en attente (version installée = version candidate),
et **je n'ai pas vérifié** si le dépôt Docker fait partie des origines que les mises à jour automatiques ont le droit d'installer (`/etc/apt/apt.conf.d/50unattended-upgrades`, bloc `Allowed-Origins`). Quoi qu'il en soit,
une mise à jour de ces paquets, ou un simple `systemctl restart docker`, couperait **tous les sites** d'un coup tant que `live-restore` est à `false`. Avec `live-restore`, le démon peut redémarrer sans toucher aux conteneurs.

## Ce qui change, et quand

- La rotation s'applique aux conteneurs **créés après** le réglage, c'est-à-dire au
  prochain `docker compose up -d` qui recrée chaque conteneur. Les conteneurs
  existants gardent leurs anciens journaux jusque-là.
- Libérer tout de suite l'espace d'un conteneur bavard, sans le redémarrer :
  `truncate -s 0 $(docker inspect -f '{{.LogPath}}' <conteneur>)`. **Cela efface l'historique de ce conteneur** : pour le proxy, ce sont les journaux d'accès de tous les sites,
  qui ne sont collectés nulle part. S'assurer qu'on n'en a pas besoin, ou les copier avant.
- **Effet de bord observé : après une troncature en place, `docker logs <conteneur>` peut ne plus répondre** (la commande reste bloquée) jusqu'à ce que le conteneur soit recréé. Le fichier, lui, reste sain
  et continue de se remplir : on le lit **directement** (`tail -n 50 $(docker inspect -f '{{.LogPath}}' <conteneur>)`, chaque ligne est un JSON `{"log": …}`). La voie propre est donc de **recréer le conteneur**
  (ce qui lui applique aussi la rotation), en heure creuse ; pour le proxy, cela coupe brièvement **tous** les sites.
- **Lire un gros journal : `docker logs --tail N`, jamais `--since`.** `--since` relit tout le fichier depuis le début (des minutes pour plusieurs Go) et ajoute de la charge.

## Retour arrière

```bash
$ ls /etc/docker/daemon.json.bak.*
$ cp /etc/docker/daemon.json.bak.<date> /etc/docker/daemon.json && systemctl restart docker
```
