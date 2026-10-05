# Runbook : un conteneur redémarre en boucle

| Gravité | Qui prévenir |
| --- | --- |
| Variable : un conteneur de dev en boucle est un bruit ; **un conteneur de production en boucle est un incident** | le responsable du projet |

Docker relance un conteneur qui s'arrête (`restart: unless-stopped`). Si la cause n'est pas corrigée, il tourne en boucle : des
dizaines de milliers de redémarrages peuvent s'accumuler sans que rien n'alerte. `vps-audit.sh` le signale en **CRITIQUE**
(`redémarre en boucle`).

## 1. Distinguer une boucle d'un redémarrage normal

Un redémarrage n'est pas forcément un problème. Exemple du projet pilote : le **worker** de file d'attente s'arrête volontairement
toutes les heures (`--max-time=3600`) et Docker le relance : `Worker STOPPED Maximum run time exceeded`, **un redémarrage par heure,
sans erreur**. C'est prévu.

| Ce que vous voyez | C'est… |
| --- | --- |
| Un redémarrage à intervalle régulier et long, journal propre | Normal (arrêt volontaire) |
| Des redémarrages toutes les quelques secondes, journal d'erreur | **Une boucle** : continuer |
| `exited` avec un code ≠ 0 et un nombre de redémarrages énorme | **Une boucle** ancienne, jamais corrigée |

## 2. Diagnostic

```bash
$ docker ps -a --format '{{.Names}} | {{.Status}}' | grep <projet>
$ docker inspect -f '{{.State.Status}} | sorti avec {{.State.ExitCode}} | OOM {{.State.OOMKilled}} | redémarrages {{.RestartCount}}' <conteneur>
$ docker logs --tail 40 <conteneur>                  # la dernière ligne avant l'arrêt dit presque toujours la cause
```

| Journal, code de sortie | Cause | Action |
| --- | --- | --- |
| `host not found in upstream "<x>"` (nginx) | Le conteneur que nginx doit joindre n'existe plus ou est arrêté | Relancer ou recréer le conteneur manquant ; sinon arrêter nginx |
| `getaddrinfo for <x> failed`, `Name does not resolve` | Le service (base, Redis) n'existe pas dans **ce** projet : nom erroné, ou projet partiel | Corriger le nom dans le compose ou le `.env` ; vérifier que le service est démarré |
| `Connection refused` vers la base | Base arrêtée, pas prête, ou **nom qui mène à un autre projet** | [Base inaccessible](base-inaccessible.md) |
| `OOM true` (sorti avec 137) | Le conteneur dépasse sa limite de mémoire | Augmenter `deploy.resources.limits.memory` après avoir mesuré (`docker stats --no-stream`), ou corriger la fuite |
| Erreur de configuration, variable manquante | `.env` incomplet | Comparer **les noms** de variables avec `.env.*.example` (jamais les valeurs dans un message) |
| Code 1 sans message | Commande de démarrage en échec | `docker run --rm --entrypoint sh <image> -c '<commande>'` pour la reproduire à la main |

## 3. Agir

1. **Production** : si le projet est en panne, [Site en panne](site-en-panne.md) d'abord ; la cause se cherche après.
2. **Corriger la cause** dans le dépôt du projet (compose, `.env`), puis redéployer avec `deploy.sh`. Pas de modification à la main sur
   le serveur.
3. **Environnement abandonné** (un `dev` que personne n'utilise) : l'arrêter plutôt que le laisser boucler. Avec l'accord du responsable
   du projet : `docker stop <conteneur>` (retour arrière : `docker start`). **Ne rien supprimer.**

## 4. Pourquoi une boucle passe inaperçue, et comment l'éviter

- Le conteneur est « en marche » à chaque instant : aucune alerte de disponibilité ne se déclenche.
- Les compteurs montent sans fin : des dizaines de milliers de redémarrages ont été observés sur des environnements de développement oubliés.
- Remède : l'alerte **« Un conteneur redémarre en boucle »** (plus de 3 redémarrages en 30 minutes) et le tableau Grafana **Plateforme → Conteneurs** (redémarrages sur 24 h),
  décrits dans la [carte de l'observabilité](../reference/observabilite-carte-complete.md), plus la lecture hebdomadaire de `vps-audit.sh`.

## 5. Ce qu'il ne faut pas faire

- Redémarrer à la main en boucle : cela efface la trace de la cause.
- Supprimer le conteneur pour « faire propre » : on perd ses journaux et le code de sortie.
- Augmenter la limite de mémoire sans mesurer.

## 6. Après

Un retour d'expérience si la cause est nouvelle ; ajouter l'alerte manquante si la boucle n'a pas été vue.
