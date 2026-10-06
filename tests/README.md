# Tests de la plateforme

Ces tests vérifient **pour de vrai** que les outils de ce dépôt fonctionnent : de
vrais conteneurs, de vraies bases, le vrai nginx-proxy 1.7, un vrai stockage S3.
Aucune simulation de code. Ce sont les tests qui ont servi à valider la plateforme
avant livraison : **432 vérifications au 2026-10-05, plus les 15 de `test-clone.sh` (2026-10-06)** (dont 27 pour `test-platform`, qui demande un clone du Core ; les autres suites rejouées le 2026-10-05 : 405). Ils tournent sur chaque pull request (CI GitHub, sauf `test-platform`, qui demande un clone du Core). Ils ont trouvé quatre défauts réels, depuis
corrigés (voir ADR-0064).

## Prérequis

- Docker et Docker Compose v2 (Docker Desktop sous Windows et macOS, Docker Engine
  sous Linux). Sous Windows, lancer les tests depuis WSL2.
- `git`, `bash`, `curl`.
- Accès à Docker Hub pour télécharger les images.
- Environ 3 Go de disque libre.

## Lancer

```bash
CORE_DIR=../vcam-core-system tests/run-all.sh   # tout (≈ 15 min la première fois : images à télécharger)
tests/run-all.sh                 # sans CORE_DIR : tout sauf test-platform (ignoré)
tests/run-all.sh hosts deploy    # seulement certains tests
KEEP=1 tests/test-deploy.sh      # garder les conteneurs après le test, pour inspecter
```

Chaque test affiche une ligne verte ✓ ou rouge ✗ par vérification, puis un résumé.
Un code de sortie différent de 0 signale un échec.

> **Un test à la fois.** Chaque test, en sortant, supprime **tous** les conteneurs, réseaux et volumes nommés `vpstest-*` (c'est ainsi qu'il ne laisse rien derrière lui). Lancer
> deux tests en même temps fait donc échouer celui qui tourne encore, sans que le code soit en cause (vécu le 2026-10-05). `tests/run-all.sh` les enchaîne.

## Les tests

| Test | Ce qu'il vérifie | Résultat à la livraison | Durée |
| --- | --- | --- | --- |
| `test-docs.sh` | La **documentation** : chaque lien relatif et chaque ancre existent, chaque guide, runbook, retour d'expérience, ADR, inventaire et page de référence est référencé dans l'index de son dossier, aucun jeton ni clé privée dans les fichiers Markdown, **cohérence interne** (tableaux bien formés, clauses citées = clauses du contrat, aucune adresse IP publique, aucune mention d'un outil d'intelligence artificielle). Sans Docker ni réseau | 13 vérifications | quelques secondes |
| `test-commands.sh` | **Les commandes courtes** (`host/install-commands.sh`), sans Docker ni root : les huit commandes (`vps`, `vps-deploy`…), `vps` qui dit comment on déploie, installation idempotente, `vps-deploy where` depuis n'importe quel dossier, **chemin raté = message clair et code 127**, appel par un **lien symbolique**, refus d'écraser un fichier qui n'est pas à lui | 31/31 | quelques secondes |
| `test-obs-bundle.sh` | **Observabilité propre à un projet** (`bin/obs-bundle.py`), sans Docker : un bundle valide est déposé dans un dossier au nom du projet ; JSON, YAML invalides, tableau sans `uid` **refusés sans toucher au dépôt précédent** ; un fichier d'alertes ne peut pas contenir de points de contact, de politique de notification ni de suppression de règles, ni ranger ses règles dans le dossier d'un autre ; aucun `uid` déjà pris (plateforme ou autre projet) n'est écrasé ; un fichier retiré du projet est retiré du dépôt ; noms dangereux refusés ; le modèle du dépôt est valide | 30/30 | 10 s |
| `test-templates.sh` | **Les modèles de projet sont déployables** : chaque modèle (Laravel PostgreSQL, Laravel MySQL/MariaDB, back end web, front SPA) est copié dans un projet factice avec ses fichiers d'environnement d'exemple et passe `deploy.sh check` pour **la production et le staging** ; sur le compose rendu : aucun port publié, un seul service sur `nginx-proxy` (le web, avec `VIRTUAL_HOST`), base et cache privés, redémarrage, limite mémoire et rotation des journaux partout, images taguées par commit ; un fichier d'environnement par environnement (staging non sauvegardé, production avec S3 obligatoire) ; la fiche de déploiement sans secret ni lien relatif | 31/31 | 1 min |
| `test-hosts.sh` | Avec un vrai nginx-proxy 1.7 : routage d'un SaaS à sous-domaines wildcard ; collision de casse qui rend la configuration invalide pour tout le serveur, puis sa réparation ; inventaire (arrêtés, certificats orphelins, wildcard) ; garde de déploiement ; audit | 24/24 | 1 min |
| `test-deploy.sh` | `deploy.sh` sur un projet témoin : staging automatique, promotion de la même image, version cassée refusée avec retour automatique, pas de boucle, retour arrière manuel, verrou, refus en cas de collision de sous-domaine ou de nginx-proxy en erreur, mode `BUILD_PER_ENV`, trois environnements dev (branche `develop`) → staging → prod, refus quand un volume est utilisé par une ancienne installation (même sous le même nom de projet), retour automatique confirmé en ligne ; **contrôle avant déploiement** ([REX 2026-10-04](../docs/retours-experience/2026-10-04-premier-deploiement-skills-devops.md)) : `platform.env` lu dans le commit déployé, service inconnu refusé, origin HTTPS refusé sans attente de mot de passe, nom privé publié par un autre projet sur un réseau partagé, service renommé qui tient un volume ; **profils de projet** (production seule, deux productions indépendantes, noms d'environnement invalides, `promote --env`) ; **sauvegarde** (aucune au déploiement par défaut, `deploy.sh backup`, mode `always`) | 83/83 | 30 min |
| `test-branches.sh` | **Les branches sont celles du projet, le passage en production est encadré** : le staging suit `develop`, une version absente de `main` est **refusée** (rien n'est déployé), fusionnée elle passe avec **la même image** sans reconstruire, l'exception `SKIP_BRANCH_CHECK=1` est consignée, chaque production a sa branche, une production **sans staging** construit la branche **déclarée** (jamais devinée) | 30/30 | 3 min |
| `test-clone.sh` | **L'intégrité du clone d'un projet** (`deploy.sh check`) : un clone propre passe, un fichier non suivi (`.env.*`) ne gêne jamais, un **dossier de `.git` non inscriptible** (suite d'un `git pull` en root) et un **fichier suivi modifié à la main** sont refusés avec la commande de réparation, `ALLOW_DIRTY_CLONE=1` laisse passer, un commit local n'est que signalé | 15/15 | 20 s |
| `test-inventory.sh` | `vps-inventory.sh` sur un serveur en miniature : projets compose, dossiers (dont un clone HTTPS avec jeton), versions déployées, base étrangère et nom générique « db » publiés sur le réseau partagé ; **aucun secret** dans le rapport (environnement, `.env`, URL git) ; lecture seule prouvée ; l'audit signale le nom en conflit | 16/16 | 1 min |
| `test-backup.sh` | Agent de sauvegarde contre de **vrais** PostgreSQL 18, MySQL 8.4, MariaDB 10.7 et 11.4, et un stockage S3 (SeaweedFS, à la place de MEGA S4) : chiffrement vu depuis S3, envoi, rétention, **aucune copie locale après l'envoi**, refus sans S3, `BACKUP_DISABLED`, S3 injoignable (trois copies au plus puis rattrapage), mauvaise phrase de passe refusée, **restauration qui remplace réellement la base** (objets créés après la sauvegarde supprimés), archive tronquée refusée, restauration depuis S3 avec les accents | 88/88 | 15 min |
| `test-observability.sh` | Stack Grafana mutualisée : journaux, métriques et traces d'un conteneur étiqueté ; un conteneur sans label est ignoré ; un conteneur privé (label seul, hors réseau partagé : cas PHP-FPM) a ses journaux, une seule fois, et n'est jamais scrapé ; dossiers, tableaux de bord et alertes provisionnés | 59/59 | 15 min |
| `test-platform.sh` | **Le VPS en miniature** : nginx-proxy 1.7 (réglages du serveur), le Core en production **et** en staging déployés par `deploy.sh` depuis un clone git, routage par nom d'hôte, isolation des bases, sauvegarde avant migration, IP falsifiée refusée, SaaS à sous-domaines, audit propre | 27/27 | 5-10 min |

## Garanties

- **Isolation.** Tout ce que les tests créent s'appelle `vpstest-*` : conteneurs,
  réseaux, volumes, images. Tout est supprimé à la fin, même en cas d'échec. Les
  tests ne touchent à rien d'autre.
- **Pas de conflit de ports.** Le seul port ouvert est `127.0.0.1:18080`
  (`test-platform.sh`). Les autres tests n'en ouvrent aucun. Un nginx-proxy déjà
  présent sur 80/443 n'est pas gêné.
- **Ne pas lancer sur le VPS de production.** C'est sans danger pour les autres
  conteneurs, mais les tests consomment du processeur et de la mémoire pendant
  plusieurs minutes. Les lancer sur un poste de développement ou une machine de test.

## Hors périmètre

- **L'obtention réelle des certificats Let's Encrypt**, wildcard DNS-01 compris :
  elle exige un domaine public pointant vers la machine. Vérification sur le
  serveur : guides 2 et 10.
- **Votre compte MEGA S4** : le protocole S3 est testé avec SeaweedFS ; l'accès réel
  se vérifie avec le guide 4, étape 2.
- **Le redémarrage de Docker sous systemd** (`host/apply-daemon-config.sh`) :
  la fusion et la validation de `daemon.json` ont été vérifiées, pas le redémarrage
  lui-même (guide 9). Le script compare les conteneurs avant et après et nomme ceux qui manquent.

## `test-platform.sh` : le Core

`test-platform.sh` déploie le vrai Core : `CORE_DIR` doit désigner un clone du
dépôt du Core (`vcam-core-system`).

### Image du Core

Par défaut, `test-platform.sh` construit **la vraie image de production** du Core
(`Dockerfile`, cible `production`) à partir du **dernier commit de `CORE_DIR`**.
Commitez avant de le lancer.

Si votre réseau bloque les dépôts de paquets (`apt`), utilisez
`CORE_TEST_IMAGE=dev`. Le test prend alors une image PHP de développement, avec le
code et le `vendor/` de `CORE_DIR` (lancer `composer install` dedans d'abord).
