# 2026-10-07 — Les tests de déploiement de deux projets publiaient leurs tableaux dans l'arbre du clone de la plateforme

**Impact** : aucun site. Le test d'`obs-bundle` de la plateforme échouait (« le test ne laisse rien dans l'arbre de Grafana réel du dépôt ») sans qu'aucun changement de la plateforme en soit la cause.
**Détecté par** : l'échec de ce test, en ajoutant des vérifications à `obs-bundle`.

## Ce qui s'est passé

Le test de déploiement d'un projet utilise un clone de la plateforme (`PLATFORM_DIR`) et exerce un vrai `deploy.sh promote`, qui **publie les tableaux et alertes du projet** (`obs-sync`) dans `${PLATFORM_ROOT}/observability/grafana`. Trois projets avaient ainsi laissé leurs fichiers dans l'arbre du clone (ignoré par git, donc invisible).

## Cause

La publication d'observabilité va par défaut dans l'arbre de la plateforme ; un test de projet ne la redirigeait pas. La variable `OBS_GRAFANA_DIR` le permet depuis le départ, mais rien ne disait de l'utiliser dans un test.

## Correction et protection

- Les tests de déploiement des deux projets exportent `OBS_GRAFANA_DIR` vers un **dossier jetable**.
- **Règle** : un test de projet qui appelle `deploy.sh` redirige la publication d'observabilité (`OBS_GRAFANA_DIR=<dossier jetable>`) et l'état (`STATE_DIR`) : il ne doit **rien** laisser dans le clone de la plateforme.
- Le test d'`obs-bundle` de la plateforme **détecte** ces résidus, comme avant : c'est lui qui a révélé le problème.
