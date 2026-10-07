# 2026-10-07 — Une requête d'alerte invalide passait la validation d'`obs-bundle` : la règle ne s'évaluait jamais

**Impact** : une règle d'alerte d'un projet (« beaucoup d'erreurs applicatives ») n'a jamais été évaluée : Grafana répondait « parse error » à chaque évaluation. Elle était en `execErrState: OK` (une erreur d'évaluation n'alerte pas) : **elle n'aurait jamais sonné**. Aucun site touché.
**Détecté par** : la lecture des journaux de Grafana après son redémarrage, une dizaine de minutes après la publication.

## Ce qui s'est passé

Le fichier d'alertes du projet disait `expr: 'sum(count_over_time({app=\"chantal\", …}[10m]))'`. Dans une chaîne YAML **entre apostrophes**, `\"` reste un antislash **littéral** : la requête LogQL commençait par `{app=\"…` et Grafana la refusait
(`unexpected IDENTIFIER, expecting STRING`). `obs-bundle validate` répondait « valide » : il vérifiait la **forme du fichier** (uid, dossier, clés) mais jamais le **contenu** des requêtes.

## Cause

- **La validation s'arrêtait à la structure.** Un YAML correct peut porter une requête fausse.
- **Le défaut est silencieux par conception** : `execErrState: OK` évite les fausses alertes quand une source est indisponible, et rend aussi muette une règle qui ne s'évalue jamais.

## Correction

| Quoi | Où |
| --- | --- |
| `obs-bundle` vérifie chaque requête (règles et panneaux de tableaux) : parenthèses, accolades et crochets **équilibrés**, valeur de sélecteur **entre guillemets**, aucun antislash hors d'une chaîne, chaînes fermées. Un refus **nomme la règle ou le panneau** et montre le début de la requête | `bin/obs-bundle.py` (`query_problem`) |
| Tests : quatre formes fautives refusées (dont celle de l'incident), une requête **légitime et complexe** acceptée (guillemets échappés dans une chaîne, intervalle, comparaison), le dépôt précédent intact après les refus, le panneau fautif nommé | `tests/test-obs-bundle.sh` (38 contrôles) |

## Protection pour tous les projets

- Tout projet qui publie ses alertes (`vps-deploy obs-sync`, `vps-obs-bundle validate`) passe par ce contrôle : **une requête invalide est refusée avant d'atteindre Grafana**.
- **Règle** : après la publication d'une règle, **vérifier qu'elle s'évalue** (journaux de Grafana, ligne `Failed to evaluate rule`), pas seulement qu'elle est chargée.
- **Limite connue** : le contrôle est syntaxique ; il ne sait pas qu'un nom de métrique ou un label n'existe pas. Une règle bien formée sur une métrique absente reste « sans donnée » (`noDataState`).
