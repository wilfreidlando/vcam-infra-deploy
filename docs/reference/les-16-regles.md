# Les 16 règles du standard

> Résumé du [contrat d'un projet](../05-contrat-projet.md) : les 16 règles, pourquoi elles existent et qui les vérifie.
> Retour au [sommaire de la documentation](../README.md).


Résumé du [contrat d'un projet](../05-contrat-projet.md), qui détaille chaque règle.
Colonne « Vérifié par » : un niveau d'audit (`vps-audit.sh`, lecture seule) ou
**BLOQUANT** (`deploy.sh` refuse avant de modifier quoi que ce soit).

| # | Règle | Pourquoi | Vérifié par |
| --- | --- | --- | --- |
| 1 | Tout passe par **nginx-proxy** (`VIRTUAL_HOST` + `LETSENCRYPT_HOST`), jamais `ports:` | HTTPS automatique ; rien d'autre n'est exposé | CRITIQUE |
| 2 | Base, cache, file : **réseau privé du projet uniquement** | Isolation entre projets | CRITIQUE |
| 3 | Pas de `privileged`, pas de socket Docker monté (sauf plateforme) | Monter le socket Docker donne les droits root sur tout le VPS | CRITIQUE |
| 4 | `restart: unless-stopped` partout | Les sites reviennent seuls après un redémarrage | ATTENTION |
| 5 | **Limite mémoire** sur chaque conteneur | Une fuite mémoire ne fait pas tomber les autres projets | ATTENTION |
| 6 | **Rotation des journaux** (`max-size`) | Un projet bavard ne remplit pas le disque de tout le monde | ATTENTION |
| 7 | **Healthcheck** sur le conteneur web | Le déploiement sait si la nouvelle version fonctionne | INFO |
| 8 | Images taguées par **commit** (`${IMAGE_TAG}`), jamais `latest` | Savoir ce qui tourne, revenir en arrière en une commande | INFO |
| 9 | **Staging et production** = même compose, fichier d'environnement différent | Staging teste exactement ce qui partira en production | — |
| 10 | Secrets dans `.env` / `.env.staging`, **jamais commités** ; staging n'a jamais les secrets de production | Une fuite de staging ne compromet pas la production | — |
| 11 | Toute base a sa **sauvegarde chiffrée hors serveur**, restaurée une fois par mois | Le VPS est un point unique de défaillance | — |
| 12 | Backends : **labels d'observabilité** | Journaux et erreurs de tous les projets au même endroit | INFO |
| 13 | **Noms de services propres au projet** (`<app>-web`, `<app>-db`, `<app>-redis`), jamais `app`, `db`, `redis` | Le conteneur web voit les noms de tous les projets sur `nginx-proxy` : un `db` étranger peut répondre à la place du vôtre | **BLOQUANT** en cas de conflit réel |
| 14 | Healthcheck de la base **par le réseau** (`pg_isready -h 127.0.0.1`) | Au premier démarrage, le socket local répond avant le réseau : migrations lancées trop tôt | Modèles |
| 15 | `platform.env` **commité**, cohérent avec le compose, **jamais modifié sur le serveur** | Il est relu dans le commit déployé | **BLOQUANT** |
| 16 | Le serveur lit le dépôt par sa **clé de déploiement SSH** (`github-<app>`), jamais en HTTPS | Sous cron, personne ne tape de mot de passe | **BLOQUANT** |

Règles 13 à 16 : ajoutées le 2026-10-04 après le
[premier déploiement de skills-devops](../retours-experience/2026-10-04-premier-deploiement-skills-devops.md).
