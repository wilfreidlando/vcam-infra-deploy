# Tests de la plateforme

Ces tests vérifient **pour de vrai** que les outils de ce dépôt fonctionnent : de
vrais conteneurs, de vraies bases, le vrai nginx-proxy 1.7, un vrai stockage S3.
Aucune simulation de code. Ce sont les tests qui ont servi à valider la plateforme
avant livraison : **129 vérifications**. Ils ont trouvé quatre défauts réels, depuis
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

## Les tests

| Test | Ce qu'il vérifie | Résultat à la livraison | Durée |
| --- | --- | --- | --- |
| `test-hosts.sh` | Avec un vrai nginx-proxy 1.7 : routage d'un SaaS à sous-domaines wildcard ; collision de casse qui rend la configuration invalide pour tout le serveur, puis sa réparation ; inventaire (arrêtés, certificats orphelins, wildcard) ; garde de déploiement ; audit | 24/24 | 1 min |
| `test-deploy.sh` | `deploy.sh` sur un projet témoin : staging automatique, promotion de la même image, version cassée refusée avec retour automatique, pas de boucle, retour arrière manuel, verrou, refus en cas de collision de sous-domaine ou de nginx-proxy en erreur, mode `BUILD_PER_ENV`, trois environnements dev (branche `develop`) → staging → prod, refus quand un volume est utilisé par une ancienne installation (même sous le même nom de projet), retour automatique confirmé en ligne | 33/33 | 3 min |
| `test-backup.sh` | Agent de sauvegarde contre de **vrais** PostgreSQL 18, MySQL 8.4 et MariaDB 11, et un stockage S3 (SeaweedFS, à la place de MEGA S4) : chiffrement, envoi, rétention, rotation, mauvaise phrase de passe refusée, restauration depuis S3 avec les accents | 34/34 | 5 min |
| `test-observability.sh` | Stack Grafana mutualisée : journaux, métriques et traces d'un conteneur étiqueté ; un conteneur sans label est ignoré ; un conteneur privé (label seul, hors réseau partagé : cas PHP-FPM) a ses journaux, une seule fois, et n'est jamais scrapé ; dossiers, tableaux de bord et alertes provisionnés | 11/11 | 3 min |
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
  lui-même (guide 9).

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
