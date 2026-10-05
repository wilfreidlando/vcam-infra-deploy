# Runbook : un site ne répond plus

| Gravité | Qui prévenir |
| --- | --- |
| Un site : le responsable du projet. Tous les sites : le responsable de la plateforme **immédiatement** | selon le tableau de rôles du [guide 0](../../guides/00-feuille-de-route.md) |

## 1. Première minute

L'alerte « Un site ne répond plus » (sonde depuis le serveur, 3 minutes) et le tableau **Plateforme → Sites — disponibilité et certificats** disent quel site est en échec et depuis quand : le panneau « Sites injoignables sur la période » ne montre que les sites tombés, et « Temps de réponse des 10 sites les plus lents » dit si un site ralentit avant de tomber.

Trois questions, dans cet ordre :

1. **Un seul site ou tous ?** Ouvrir deux autres sites. Si tous sont tombés, aller à la section 5.
2. **Un déploiement vient-il d'avoir lieu ?** `cd /app/<projet>/prod && /app/vps-platform/bin/deploy.sh status`
   et lire `/var/lib/vps-platform/<projet>/deploy.log` (dernières lignes).
3. **Quel code d'erreur ?** 502 = `nginx-proxy` ne joint pas le conteneur web ; 503 = aucun
   conteneur ne porte ce nom d'hôte ; autre = l'application.

## 2. Après un déploiement

```bash
$ cd /app/<projet>/prod && /app/vps-platform/bin/deploy.sh rollback prod
```

Redéploie la version précédente. Limite : **les migrations ne sont pas annulées**. Si la
dernière version a modifié la base de façon incompatible, voir
[Base inaccessible](base-inaccessible.md) (restauration de la dernière sauvegarde).

## 3. Sans déploiement récent

```bash
$ docker ps -a --format '{{.Names}} | {{.Status}}' | grep <projet>      # arrêté ? « unhealthy » ? redémarre en boucle ?
$ docker logs --tail 100 <conteneur>                                     # la cause est presque toujours ici
$ docker compose -p <projet>-prod logs --tail 200 <service>              # alternative par le projet
```

| Ce que vous voyez | Cause probable | Action |
| --- | --- | --- |
| Conteneur `Exited` | Plantage ou arrêt | Lire le journal ; si c'est un incident ponctuel : `docker start <conteneur>` |
| `Restarting` en boucle | Erreur de démarrage (variable manquante, base absente, service introuvable) | Lire le journal, **ne pas redémarrer en boucle** ; corriger la cause |
| `unhealthy` | Le healthcheck échoue | Journal de l'application ; vérifier la base et le cache |
| Conteneur sain mais 502 | `nginx-proxy` ne le voit pas | Le web est-il sur le réseau `nginx-proxy` ? `docker inspect <conteneur>` (réseaux) |
| 503 | Aucun conteneur ne porte `VIRTUAL_HOST` | `vps-hosts.sh` : le nom est-il porté ? un autre projet l'a-t-il pris ? |

## 4. `nginx-proxy` en erreur

Une configuration invalide **bloque tous les changements** de routage du serveur.

```bash
$ docker exec nginx-proxy nginx -t                  # « test is successful » attendu
$ /app/vps-platform/bin/vps-hosts.sh                # collisions : deux projets pour un même nom, casse différente
$ docker logs --tail 100 nginx-proxy
```

Cause fréquente : un nom d'hôte revendiqué par deux projets, ou le même nom avec une casse
différente. Retirer la revendication du projet fautif (son `VIRTUAL_HOST`), puis recréer
ce seul projet.

## 5. Tous les sites tombés

Le tableau Grafana **Plateforme → Serveur — vue d'ensemble** donne l'état du serveur d'un coup d'œil (processeur, mémoire, disque, charge),
si Grafana répond encore.

```bash
$ systemctl status docker              # Docker tourne-t-il ?
$ docker ps -a | head                  # les conteneurs existent-ils ?
$ df -h /                              # disque plein ? -> runbook « Disque plein »
$ free -m ; swapon --show              # mémoire saturée ?
$ dmesg | grep -i 'out of memory'      # le noyau a-t-il tué des conteneurs ?
```

Si Docker tourne mais `nginx-proxy` est arrêté, **le redémarrer en premier** :
`cd /app/nginx-proxy-conf && docker compose up -d`. Les projets reviennent ensuite seuls
(`restart: unless-stopped`).

## 6. Vérification

- Le site répond : `curl -s -o /dev/null -w '%{http_code}\n' https://<site>/`.
- `deploy.sh status` : conteneurs « healthy ».
- `vps-audit.sh` : pas de nouvelle ligne CRITIQUE pour ce projet.

## 7. Ce qu'il ne faut pas faire

- Redémarrer Docker ou le serveur « pour voir » : cela coupe **tous** les sites.
- `docker compose down -v` : supprime les volumes (les données).
- Modifier `platform.env` ou le compose sur le serveur : changer par commit.
- Relancer en boucle un déploiement qui échoue : lire d'abord pourquoi.

## 8. Après

Retour d'expérience ([modèle](../retours-experience/README.md)) : cause vérifiée, ce qui
n'a pas alerté plus tôt, le contrôle ajouté. Si la détection a été tardive, ajouter une
sonde externe ([guide 8](../../guides/08-surveillance-externe.md)).
