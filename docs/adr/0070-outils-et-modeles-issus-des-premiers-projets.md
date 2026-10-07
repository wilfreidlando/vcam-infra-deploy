# ADR-0070 — Ce que les deux premiers projets en production ont appris : contrôles, outils et modèles

- **Statut** : **Proposé** — complète ADR-0064 (standard d'hébergement), ADR-0067 (profils de projet), ADR-0068 (observabilité portée par le projet) et ADR-0069 (commandes courtes et branches). **Ce qui dépasse le contrat est à valider** (§ 3).
- **Date** : 2026-10-07
- **Décideurs** : responsable de la plateforme (à valider)

## Contexte

Deux projets (une application multi-centres sur MariaDB et une plateforme touristique sur PostgreSQL) ont été mis en production sur la plateforme, dont **la migration d'une application en service** (même nom de domaine), avec un pipeline GitLab. Ils ont montré ce que la plateforme laissait passer, et ce qu'elle ne donnait pas
clés en main. Chaque point ci-dessous est né d'un incident ou d'un manque réel ; les retours d'expérience correspondants sont dans `docs/retours-experience/`.

## Décision

### 1. Les contrôles de `deploy.sh check` s'étendent

| Contrôle | Pourquoi | Comportement |
| --- | --- | --- |
| **Intégrité du clone** | un `git pull` en root dans un clone a laissé des fichiers de root et des fusions locales ; un fichier modifié à la main construit une image qui n'est pas son commit | **refuse** un dossier de `.git` non inscriptible et des fichiers suivis modifiés (`ALLOW_DIRTY_CLONE=1` pour passer outre) ; **signale** les commits locaux et les fichiers d'un autre compte |
| **Collision de nom d'hôte** | elle n'était vue qu'au déploiement : une bascule ne la voyait qu'au dernier moment | `check` la voit aussi (sans rien déployer) |

### 2. Un outil et des modèles de plus

- **`vps-fingerprint`** (`bin/vps-fingerprint.sh`, commande courte) : empreintes de tables (MariaDB, MySQL, PostgreSQL) et de fichiers pour **prouver qu'une copie est exacte**. Testé sur de vraies bases, avec la détection d'un caractère, d'un centime, d'une ligne, d'un octet, d'un fichier.
- **Modèles de pipeline GitLab** (`templates/gitlab-ci/`, profils A et B) : annulation automatique, déploiement jamais interruptible, délais, verrous, production sur bouton. Testés, avec chaque garantie cassée exprès.
- **Scripts modèles** (`templates/scripts/` : `ops.sh`, `make-env.py`) et **modèles PHP d'observabilité** vérifiés dans une **vraie application Laravel**.
- **`obs-bundle` valide le contenu des requêtes** (PromQL, LogQL) : une règle d'alerte dont la requête est invalide ne s'évalue jamais, et personne n'est prévenu ; la forme du fichier, elle, était correcte.

### 3. Les modèles Laravel deviennent plus stricts que le contrat — **à valider**

| Changement | Pourquoi | Écart au contrat |
| --- | --- | --- |
| **Mot de passe du cache obligatoire** (`--requirepass ${REDIS_PASSWORD:?…}`) | un cache sans mot de passe est joignable par tout conteneur qui partage un réseau avec lui ; relevé lors de l'audit d'une application | **le contrat n'a aucune clause là-dessus** : proposition d'une clause « le cache n'est jamais joignable sans mot de passe » |
| **Contrôle de santé réel du worker et du planificateur** | un processus figé reste « Up » ; personne ne le voit | le contrat (C4) exige un contrôle de santé du web et de la base ; proposition d'étendre à tout processus de fond |

Tant que ces deux points ne sont pas dans le contrat, `vps-audit` ne les signale pas : seuls les **modèles** les appliquent, et `test-templates.sh` les vérifie sur eux.

### 4. La documentation se range par situation

Pages de référence ajoutées : modifier une valeur, les branches et les fusions, le pipeline GitLab, clones et droits, le démarrage robuste d'un conteneur ; le guide 20 (migrer une application en service) ; le runbook du runner GitLab. Le tableau
[« déployer selon la situation »](../reference/deployer-selon-la-situation.md) et le [sommaire](../README.md) y renvoient depuis la situation vécue.

## Conséquences

- **Un nouveau refus possible après la mise à jour de la plateforme** : un projet dont le clone a été modifié à la main verra `check` le refuser, avec la commande de réparation. Avant de mettre à jour : `vps-deploy check <env>` sur chaque projet (guide 11).
- **Une nouvelle commande** (`vps-fingerprint`) : relancer `host/install-commands.sh` en root.
- Les projets existants **ne reçoivent pas** les corrections des modèles automatiquement : un modèle se **copie**. Ceux de l'application multi-centres et de la plateforme touristique les ont déjà ou les ont adoptées chacun de leur côté.
- **Manques connus**, écrits plutôt que cachés : pas d'`entrypoint` modèle testé (le motif est décrit et ses cinq scénarios listés, [démarrage robuste](../reference/demarrage-robuste.md)) ; pas de contrôle automatique du `config.toml` du runner (propriété de root, hors périmètre de `deploy.sh`) ;
  la lenteur du proxy après le démarrage d'un nouveau projet n'est qu'observée, sa cause n'est pas établie.

## Alternatives écartées

- **Laisser chaque projet réinventer** son pipeline, son script d'exploitation et sa preuve de copie : c'est ce qui s'est passé, avec des défauts différents à chaque fois.
- **Modifier le contrat tout de suite** pour le mot de passe du cache et les contrôles de santé : décision de gouvernance, laissée à la validation (§ 3).
- **Un modèle de pipeline unique** pour tous les profils : un projet sans staging n'a ni le même flux ni les mêmes risques.
