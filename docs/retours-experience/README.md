# Retours d'expérience

Un retour d'expérience (REX) par incident ou par déploiement raté. Le but n'est pas
de chercher un coupable : c'est de faire en sorte que **le même problème ne puisse
plus arriver à aucun projet**. Un REX n'est clos que lorsque la protection est
automatique : un contrôle, un test, un modèle corrigé. Voir le
[contrat, § 5](../05-contrat-projet.md#5-faire-évoluer-le-contrat).

| Date | Sujet | Protection mise en place | Statut |
| --- | --- | --- | --- |
| 2026-10-04 | [Premier déploiement de skills-devops : quatre échecs en chaîne](2026-10-04-premier-deploiement-skills-devops.md) | `deploy.sh` : contrôle avant déploiement, commande `check`, `platform.env` lu dans le commit déployé, git sans attente de mot de passe ; modèles corrigés ; contrat v2 | Clos (reste : passer le Core et centre-formation à `deploy.sh check`) |
| 2026-10-04 | [Grafana ne charge pas dans le navigateur : aucun site n'est compressé](2026-10-04-grafana-sans-compression.md) | Grafana compresse lui-même (`GF_SERVER_ENABLE_GZIP`) ; test de compression dans `test-observability.sh`. Défaut de fond (`gzip on` absent de `nginx-proxy`) à décider séparément | Partiel : correction faite, décision `nginx-proxy` ouverte |
| 2026-10-05 | [Le nettoyage des anciennes images ne fonctionnait jamais](2026-10-05-nettoyage-des-images-ne-fonctionnait-pas.md) | `prune_images` ne considère que les environnements présents dans le dossier ; scénario « disposition réelle » dans `test-deploy.sh` | Clos : correctif et test ; reste à tirer sur le serveur |
| 2026-10-05 | [La restauration ne remplaçait pas la base](2026-10-05-la-restauration-ne-remplacait-pas-la-base.md) | `restore.sh` : PostgreSQL (schéma réinitialisé, sauvegarde rejouée dans une seule transaction) et MySQL/MariaDB (objets supprimés après validation du dump) ; archive validée avant de toucher à la base, `RESTORE_MODE` ; tests sur PostgreSQL 18, MySQL 8.4, MariaDB 10.7 et 11.4 ; exercice mensuel | Partiel : code et tests faits ; mise à jour du serveur et exercice sur un projet MariaDB à faire |
| 2026-10-05 | [Les métriques du pilote n'arrivaient pas : Alloy ne regardait qu'un réseau sur trois](2026-10-05-metriques-du-pilote-absentes-reseau-alloy.md) | `match_first_network = false` ; le test met l'application sur deux réseaux dont un qui passe avant `observability` (vérifié dans les deux sens) ; vérification de chaque signal séparément | Corrigé dans le dépôt, à déployer |
| 2026-10-05 | [« No data » : la charge par processeur ne s'affichait pas, et l'alerte de charge ne pouvait jamais sonner](2026-10-05-no-data-charge-par-processeur.md) | `scalar()` ; label `level` unique (Laravel et Caddy) ; **le test exige que chaque requête renvoie des données** (vérifié dans les deux sens) | Corrigé dans le dépôt, à déployer |
| 2026-10-05 | [Le tableau « Traces » de Grafana répondait « empty ring »](2026-10-05-traces-empty-ring.md) | Générateur de métriques Tempo (`local-blocks` seul) ; le test interroge `metrics/query_range` comme Grafana | Corrigé dans le dépôt, à déployer |
| 2026-10-05 | [L'alerte de sauvegarde se taisait pour un projet qui n'était plus sauvegardé](2026-10-05-alerte-de-sauvegarde-globale.md) | Une règle **par projet** (agent qui a tourné sans envoyer de copie) en plus de la globale, rappel **quotidien** (`cadence=daily`) ; test avec trois faux agents (un qui envoie, un désactivé, un neuf) et évaluation par Grafana | Corrigé dans le dépôt, à déployer |
| 2026-10-05 | [L'alerte « un conteneur redémarre en boucle » et le panneau « Redémarrages » ne voyaient aucune relance](2026-10-05-alerte-de-boucle-aveugle-aux-relances.md) | Le signal est le compteur de processeur (`resets`), plus la date de création du conteneur ; test avec un conteneur qui est vraiment relancé par Docker, et un conteneur stable témoin | Corrigé dans le dépôt, à déployer |
| 2026-10-06 | [Le runner GitLab tombe après un redémarrage : `config.toml` invalide, puis jobs sans tag](2026-10-06-runner-gitlab-config-invalide-et-jobs-sans-tag.md) | Runbook et règles (documentaire ; contrôle automatique à décider) | Partiel |
| 2026-10-06 | [Un `git pull` en root dans un clone de projet](2026-10-06-git-pull-en-root-dans-un-clone.md) | `deploy.sh check` refuse un dossier `.git` non inscriptible et un fichier suivi modifié, signale les commits locaux ; `tests/test-clone.sh` | Clos une fois la plateforme mise à jour sur le serveur |
| 2026-10-07 | [Une requête d'alerte invalide passait la validation d'`obs-bundle` : la règle ne s'évaluait jamais](2026-10-07-requete-dalerte-invalide-validee-par-obs-bundle.md) | `obs-bundle` vérifie le contenu des requêtes (équilibre, guillemets, antislash) ; 38 contrôles | Clos |
| 2026-10-07 | [Une fusion qui n'apporte aucun contenu : l'historique dit « fusionné », six fichiers ne l'étaient pas](2026-10-07-fusion-qui-ne-change-rien.md) | Page « les branches d'un projet » (reconnaître, réparer, répéter une fusion) ; pas de contrôle automatique | Partiel |
| 2026-10-07 | [Première bascule d'une application en service : ce qui n'a pas été prévu](2026-10-07-premiere-bascule-ce-qui-na-pas-ete-prevu.md) | `check` voit la collision de nom ; guide 20 ; `vps-fingerprint` ; la lenteur du proxy reste à expliquer | Partiel |
| 2026-10-07 | [Les tests de déploiement de deux projets publiaient leurs tableaux dans l'arbre du clone de la plateforme](2026-10-07-tests-de-projet-publiaient-dans-larbre-de-la-plateforme.md) | `OBS_GRAFANA_DIR` vers un dossier jetable ; le test d'`obs-bundle` détecte les résidus | Clos |

## Modèle

Copier dans `AAAA-MM-JJ-sujet-court.md` :

```markdown
# AAAA-MM-JJ — <sujet>

**Impact** : qui a été touché, combien de temps (production ? staging ? données ?)
**Détecté par** : <personne / alerte / déploiement>

## Ce qui s'est passé
Chronologie courte, avec les messages exacts.

## Cause
La vraie cause, vérifiée (reproduite si possible), pas la première hypothèse.

## Pourquoi rien ne l'a arrêté
Quel contrôle manquait.

## Correction
Ce qui a été changé, avec les commits.

## Protection pour tous les projets
Contrôle ajouté (deploy.sh / vps-audit.sh), test qui le prouve, modèle, clause du
contrat.

## Reste à faire
Projets à mettre en conformité, avec un responsable.
```
