# 2026-10-05 — La restauration ne remplaçait pas la base

**Impact** : aucune donnée perdue, aucun site touché. Mais la restauration PostgreSQL **ne faisait pas ce
qu'elle annonçait** : elle demandait « Les données actuelles seront REMPLACÉES » alors qu'elle ne supprimait
pas ce qui avait été créé après la sauvegarde. Découvert grâce au premier exercice de restauration, **avant**
qu'un incident réel ne l'exige.
**Détecté par** : l'exercice de restauration de la production du projet pilote, un script avec table-témoin.

## Ce qui s'est passé

| Étape | Résultat |
| --- | --- |
| Sauvegarde fraîche, chiffrée, envoyée sur S3 | réussie |
| Création d'une table-témoin **après** la sauvegarde | présente |
| Restauration depuis S3 (`restore: done`, services redémarrés) | réussie, site en HTTP 200 |
| Mêmes migrations qu'avant (même empreinte) | oui |
| Table-témoin après la restauration | **toujours présente** : 11 tables au lieu de 10 |

La chaîne complète fonctionne (sauvegarde, chiffrement, copie hors serveur, téléchargement, déchiffrement,
restauration), mais la base n'est pas **revenue à l'état de la sauvegarde**.

## Cause

L'agent restaurait avec `pg_restore --clean --if-exists`. Cette option supprime puis recrée **les objets qui sont
dans la sauvegarde**, et **laisse tout le reste**. Une table, une vue ou une fonction créée après la sauvegarde
survit.

Le cas d'usage prévu est précisément celui où cela fait mal : **restaurer la sauvegarde `pre-deploy` après une
migration ratée** ([runbook base inaccessible](../runbooks/base-inaccessible.md)). Les tables que cette migration
avait créées restent, la table des migrations est revenue en arrière, et la migration rejouée échoue avec
« relation already exists ».

## Deuxième découverte, par le test sur les vraies versions : un dump MariaDB 11.4 ne se restaurait pas sur MariaDB 10.7

En ajoutant MariaDB **10.7** au test (c'est la version de la majorité des bases du serveur), la restauration a **échoué** :
`ERROR 1193 (HY000) at line 17: Unknown system variable 'NOTE_VERBOSITY'`.

Le client `mariadb-dump` 11.4 de l'agent ouvre ses dumps par `/*M!100616 SET @OLD_NOTE_VERBOSITY=@@NOTE_VERBOSITY, NOTE_VERBOSITY=0 */`.
Ce commentaire conditionnel est exécuté par tout serveur dont la version est au moins 100616 : MariaDB 10.7.8 (100708) l'exécute, mais cette variable n'y existe
pas (elle n'a été ajoutée qu'aux versions suivantes des séries 10.6 et 10.11). **Un dump pris d'un serveur 10.7 par le client 11.4 ne pouvait donc pas être
restauré sur ce même serveur.** Ces lignes ne servent qu'à masquer des avertissements : la restauration les retire désormais, ce qui rend un dump restaurable
sur toute version (10.7 à 11.4, MySQL 8.4) avec **une seule image d'agent**. Seul un test sur la version réellement déployée pouvait le montrer.

## Pourquoi rien ne l'a arrêté

- **Le test n'essayait pas la version la plus déployée** : il couvrait MySQL 8.4 et MariaDB 11, pas MariaDB 10.7.
- **Le test vérifiait les lignes, pas les objets.** `tests/test-backup.sh` détruisait des données, restaurait, et
  contrôlait que les lignes d'origine étaient revenues. Il ne créait jamais d'objet après la sauvegarde.
- **Le message de confirmation promettait plus que l'outil ne faisait.** Personne n'a comparé la promesse au
  comportement.
- **Aucun exercice de restauration n'avait jamais été fait** : le README le demande chaque mois, rien ne le
  planifiait ni ne le consignait.

## Correction

| Quoi | Où |
| --- | --- |
| Le script SQL est **généré d'abord** à partir de l'archive : une archive corrompue ou tronquée échoue avant de toucher à la base | `images/db-backup/restore.sh` |
| En mode `replace` (défaut), le schéma `public` est réinitialisé puis la sauvegarde rejouée **dans une seule transaction** : soit la base est entièrement remplacée, soit rien n'a changé | idem |
| **MySQL et MariaDB** : le dump doit être complet (`-- Dump completed`) avant tout `DROP` ; vues, tables, routines et événements créés depuis sont supprimés, puis le dump est rejoué. **Non atomique** (le DDL MySQL ne l'est pas) | `images/db-backup/restore.sh` |
| `RESTORE_MODE=merge` conserve l'ancien comportement ; toute autre valeur est refusée | idem et `bin/restore.sh` |
| Le message de confirmation dit la vérité, par moteur | `bin/restore.sh` |
| Tests : objet créé après la sauvegarde supprimé (PostgreSQL : table, vue ; MySQL/MariaDB : table, vue, procédure, événement), conservé en mode `merge` ; mauvaise phrase de passe, archive tronquée et mode invalide **laissent la base intacte**. Serveurs testés : **PostgreSQL 18, MySQL 8.4, MariaDB 10.7 (la version la plus déployée) et 11.4** ; client de l'agent figé sur `mariadb:11.4` | `tests/test-backup.sh` |
| [Exercice de restauration](../runbooks/exercice-de-restauration.md) : procédure mensuelle, avec table-témoin | `docs/runbooks/` |
| Contrat v2.1, clause C11 précisée | [contrat](../05-contrat-projet.md) |

Vérifié contre un vrai PostgreSQL 18 : sur l'ancien script, **6 contrôles sur 20 échouent** (table, vue et fonction
créées après la sauvegarde conservées, séquence décalée, mode invalide accepté) ; sur le nouveau, **les 20
réussissent**, avec accents, vue, fonction et extension (`pgcrypto`).

## Protection pour tous les projets

- Le test reproduit l'incident : tout retour au comportement `--clean` seul fait échouer `test-backup.sh`, et la restauration est essayée sur **les versions réellement déployées**.
- **Règle** : un outil de sauvegarde se teste sur **chaque version de serveur en production**, pas sur une version « représentative ».
- L'exercice mensuel (runbook) vérifie, sur un vrai projet, que la base revient à l'état exact.
- **Limites connues, écrites** : la restauration MySQL/MariaDB n'est **pas atomique** (le DDL n'est pas transactionnel) ;
  pour PostgreSQL, seul le schéma `public` est réinitialisé et les droits donnés à un autre rôle que le propriétaire ne
  sont pas restaurés.

## Reste à faire

| Quoi | Qui |
| --- | --- |
| **Mettre la plateforme à jour sur le serveur puis reconstruire l'image de l'agent** (`deploy.sh build`) : un `git pull` seul ne change pas l'image déjà construite | responsable de la plateforme |
| Refaire l'exercice de restauration de production du projet pilote, avec l'image à jour : la table-témoin doit disparaître | responsable du projet pilote |
| Faire l'exercice sur **un projet MariaDB** (la version 10.7 est la plus répandue) avant de s'appuyer sur la restauration pour ces projets | responsable de chaque projet |
| Planifier l'exercice de restauration mensuel de chaque projet, et en consigner le résultat | responsable de chaque projet |
