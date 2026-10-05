# 2026-10-05 — « No data » : la charge par processeur ne s'affichait pas, et l'alerte de charge ne pouvait jamais sonner

**Impact** : un panneau vide dans le tableau Serveur, et surtout **une alerte inopérante** : « Charge du serveur très élevée » utilisait la même
expression et ne pouvait donc jamais se déclencher. Aucun site touché.
**Détecté par** : un membre de l'équipe qui regardait les tableaux, **pas par un test** : chaque tableau « répondait », sauf ce carré.

## Ce qui s'est passé

| Constat | Détail |
| --- | --- |
| Tableau Serveur | Tous les panneaux affichent des valeurs, **sauf « Charge par processeur »** |
| Requête | `node_load5 / count(count by (cpu) (...))` : renvoie **une liste vide** sur le serveur réel |
| Avec `scalar(...)` autour du dénominateur | Renvoie la valeur attendue (charge divisée par le nombre de processeurs) |
| Alerte « charge très élevée » | Même expression : jamais d'évaluation vraie, donc jamais d'alerte |
| Tableau Applications, panneaux Erreurs et Avertissements | « No data » au lieu de 0 ; pas de label `level` dans Loki |

## Cause

**La division entre deux séries.** Dans Prometheus, `a / b` n'apparie que des séries qui portent **les mêmes étiquettes**. `node_load5` en a (`instance`, `job`…) ; `count(...)`
les a toutes perdues par agrégation. Aucune paire, aucun résultat, et **aucune erreur** : un résultat vide est une réponse valide. La correction est de dire que le dénominateur est un
nombre : `scalar(count(...))`.

**Le niveau des journaux** : Alloy ne lisait que `level_name` (Laravel, en majuscules). Caddy et FrankenPHP écrivent `level` en minuscules (`warn`) : aucun label `level` n'existait. Et un
compteur à zéro s'affiche « No data » plutôt que 0 tant qu'on ne force pas la valeur.

## Pourquoi rien ne l'a arrêté

- **Le test vérifiait que les règles et les tableaux étaient *chargés*, jamais qu'ils *renvoient* quelque chose.** Un panneau et une règle peuvent être parfaitement provisionnés
  et vides.
- Les requêtes avaient été relues, pas exécutées contre de vraies séries.
- Un résultat vide ne produit ni erreur ni alerte : il faut aller le regarder.
- **Même famille** que les trois retours d'expérience précédents : le test ne reproduisait pas la réalité qu'il prétendait garder.

## Correction

| Quoi | Où |
| --- | --- |
| `scalar()` autour du dénominateur, dans le panneau **et** dans l'alerte | `serveur.json`, `generic-alerts.yaml` |
| Un seul label `level`, quel que soit l'émetteur (`level_name` ou `level`), en majuscules, `WARN` devenu `WARNING` | `alloy/config.alloy` |
| Les compteurs d'erreurs et d'avertissements affichent 0 | `applications-logs.json` (`or vector(0)`) |
| **Chaque requête** du tableau Serveur, du tableau Conteneurs et des alertes du serveur doit renvoyer des données sur la pile de test | `tests/test-observability.sh` |
| Un niveau Caddy (`warn`) doit devenir le label `level=WARNING` | `tests/test-observability.sh` |

Vérifié **dans les deux sens** : avec l'ancienne expression, le test échoue sur **une seule vérification** (celle des requêtes) ; avec la correction, 34 vérifications réussissent.

## Protection pour tous les projets

- **Règle** : on ne dit pas qu'une alerte ou un tableau « fonctionne » parce qu'il est chargé, mais parce qu'**on l'a vu renvoyer une valeur**. Toute nouvelle requête de tableau ou d'alerte entre dans la liste du test.
- Les « No data » qui restent sont **attendus et documentés** : Conteneurs (tant que cAdvisor n'est pas démarré), Disponibilité (tant que la liste des sites n'existe pas), Core (tant qu'il n'est pas branché). Les distinguer d'un défaut
  est précisément ce que le test fait.

## Reste à faire

| Quoi | Qui |
| --- | --- |
| Publier, mettre à jour le serveur, recréer Alloy (label `level`) et Grafana (tableau et alerte corrigés) | responsable de la plateforme |
| Démarrer cAdvisor et créer la liste des sites pour que les tableaux Conteneurs et Disponibilité se remplissent | responsable de la plateforme |
