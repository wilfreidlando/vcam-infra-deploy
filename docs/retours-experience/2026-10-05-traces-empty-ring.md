# 2026-10-05 — Le tableau « Traces » de Grafana répondait « empty ring »

**Impact** : aucun site touché, aucune trace perdue. Le tableau **Traces** de Grafana (la vue qui trace des courbes à partir des traces) affichait une erreur 500
(« failed to execute TraceQL query … error finding generators in Querier.queryRangeRecent: empty ring »). Les traces, elles, étaient bien reçues et consultables une par une.
**Détecté par** : un membre de l'équipe qui ouvrait l'onglet Traces. **Pas par un test.**

## Cause

Le tableau Traces de Grafana n'affiche pas seulement des traces : il calcule des **courbes à partir d'elles** avec les requêtes de métriques de TraceQL (`rate()`, `count_over_time()`…).
Tempo ne sait les répondre que s'il a un **générateur de métriques** (processeur `local-blocks`). Notre configuration n'en avait pas : Tempo cherche un générateur dans son anneau, n'en trouve aucun
(« empty ring ») et répond 500.

## Pourquoi rien ne l'a arrêté

- Le test d'observabilité vérifiait qu'**une trace envoyée est reçue et relue** (`/api/traces/<id>`), pas que **les requêtes que Grafana fait réellement** aboutissent.
- Même famille que les REX précédents (« No data », alerte qui se charge sans s'évaluer) : **un composant qui se charge n'est pas un composant qui répond à ce qu'on lui demande.**

## Correction

| Quoi | Où |
| --- | --- |
| Générateur de métriques avec **le seul processeur `local-blocks`** : il répond aux requêtes TraceQL de métriques depuis les traces récentes, **sans produire de séries Prometheus** (aucune charge de plus pour Prometheus) | `observability/tempo/config.yaml` |
| Le test envoie une trace, puis interroge **`/api/metrics/query_range?q={} | rate()`** : il doit répondre 200 avec des séries | `tests/test-observability.sh` |

## Protection pour tous les projets

- Règle : un test d'observabilité interroge **comme Grafana le fait**, pas seulement la voie d'entrée des données.
- Pour qui ajoute un jour un autre composant que Grafana interroge (profils, par exemple) : vérifier **la requête de l'interface**, pas seulement l'ingestion.

## Reste à faire

| Quoi | Qui |
| --- | --- |
| Mettre à jour le serveur et **recréer Tempo** (la configuration n'est lue qu'au démarrage) | responsable de la plateforme |
