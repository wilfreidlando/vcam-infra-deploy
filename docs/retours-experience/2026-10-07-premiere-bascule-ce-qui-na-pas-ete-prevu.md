# 2026-10-07 — Première bascule d'une application en service : ce qui n'était pas prévu

**Impact** : l'application migrée a été coupée environ **15 minutes** (estimation : 10 à 12). Copie prouvée identique avant l'ouverture, aucune donnée perdue. Pendant une dizaine de minutes ensuite, le proxy a été lent pour **tous** les sites.
**Détecté par** : les mesures prises pendant la fenêtre (empreintes, délais de réponse, charge du serveur).

## Ce qui s'est passé

La bascule a suivi la méthode du [guide 20](../../guides/20-migrer-une-application-existante.md). Quatre choses n'étaient pas prévues :

1. **`vps-deploy check` répondait « OK » alors que le nom d'hôte était encore pris** par l'ancien serveur web : la collision n'était contrôlée qu'au déploiement. Le mode opératoire promettait le contraire, et c'était faux.
2. **Une lenteur de tout le proxy** après le démarrage de huit conteneurs : `nginx-proxy` à 78 % de CPU, son générateur de configuration à 55 %, charge de 15 sur 6 cœurs. L'application migrée échouait 3 fois sur 10 avec un délai de 12 s, les autres sites répondaient en 3 s ; retour à la normale seul en une dizaine de minutes. **Cause probable** : rechargements du proxy après l'arrivée du projet et d'un certificat ; **non établie**. La connexion SSH au serveur a été refusée un moment, sous cette charge.
3. **Des commandes collées en bloc se sont mélangées** dans le terminal, à deux reprises : sortie incomplète, impossible de dire si une étape avait fini.
4. **L'étape de mise à jour du clone demandait un `git pull`** : contraire à la règle des clones.

## Correction

| Quoi | Où |
| --- | --- |
| `check` voit la collision de nom d'hôte, sans rien déployer ; test dans le scénario de collision existant | `bin/deploy.sh` (`check_hosts` dans `cmd_check`), `tests/test-deploy.sh` |
| La méthode, avec ses critères de GO **chiffrés** et ses observations | [guide 20](../../guides/20-migrer-une-application-existante.md) |
| L'outil de preuve de copie, sur MariaDB, MySQL et PostgreSQL | `vps-fingerprint`, `tests/test-fingerprint.sh` |
| Règle : coller les commandes une par une | guide 20 |
| Règle : jamais de `git pull` dans un clone | [clones et droits](../reference/clones-et-droits.md) |

## Protection pour tous les projets

- 1 et 4 sont **automatiques** (`check` refuse, `check` signale un clone modifié).
- 3 est une **règle écrite**.
- 2 reste une **observation** : rien ne l'empêche, et sa cause n'est pas établie.

## Reste à faire

- [ ] Établir la cause de la lenteur du proxy (journaux de `docker-gen` et du compagnon de certificats pendant un déploiement) et décider si un déploiement doit **attendre** le retour au calme avant de rendre la main.
