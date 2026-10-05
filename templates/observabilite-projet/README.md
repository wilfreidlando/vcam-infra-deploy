# Modèle : l'observabilité propre à mon projet

> Un tableau Grafana et une alerte **qui vivent dans le dépôt du projet**, et que la plateforme publie toute seule après un déploiement de production.
> La plateforme n'est **jamais** modifiée. Guide complet : [guide 19](../../guides/19-observabilite-de-mon-projet.md). Décision : [ADR-0068](../../docs/adr/0068-observabilite-portee-par-le-projet.md).

## Ce que contient ce dossier

| Fichier | Où le copier | Rôle |
| --- | --- | --- |
| [`observability/dashboards/exemple.json`](observability/dashboards/exemple.json) | `<projet>/observability/dashboards/` | Un tableau Grafana minimal (à enrichir avec les chiffres de **votre** métier) |
| [`observability/alerts/exemple.yaml`](observability/alerts/exemple.yaml) | `<projet>/observability/alerts/` | Une règle d'alerte (« mon projet n'expose plus ses métriques ») |

## En trois étapes

1. **Copier** le dossier `observability/` à la racine du projet, remplacer `mon-projet` par le nom de l'application (la valeur de `observability.app`), et adapter.
2. **Vérifier** sans rien publier : `python3 /app/vps-platform/bin/obs-bundle.py validate --app <projet> --src observability --grafana-dir /app/vps-platform/observability/grafana`.
3. **Déployer** : après un déploiement de production réussi, la publication est automatique. À la demande : `deploy.sh obs-sync`.

## Les règles (sinon la publication est refusée, avec le motif)

| Règle | Pourquoi |
| --- | --- |
| Chaque tableau a un `uid` (40 caractères au plus) | Sans lui, les liens cassent |
| Un `uid` n'existe qu'une fois sur la plateforme : le **préfixer par le nom du projet** | Aucun projet n'en écrase un autre |
| Un fichier d'alertes ne contient que `apiVersion` et `groups` | Les points de contact et la politique de notification sont ceux de la plateforme |
| Le `folder` d'un groupe d'alertes est **le nom du projet** | Un projet ne range pas ses règles chez un autre |
| Dans un message : `{{ .Labels.nom }}`, jamais `{{ $labels.nom }}` | Grafana remplace `$nom` dans ces fichiers |

## Ce qu'on obtient sans rien écrire

Le tableau [**Application — vue d'ensemble**](../../guides/17-comprendre-et-lire-grafana.md) couvre déjà tout projet qui a les labels `observability.*` : disponibilité, conteneurs, mémoire, redémarrages, journaux.
Ce modèle sert aux **chiffres de votre métier** (paiements en attente, file bloquée…), que seul le projet connaît.
