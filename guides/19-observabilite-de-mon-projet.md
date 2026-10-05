# 19. Donner à mon projet son observabilité : journaux, métriques, tableaux, alertes

Comment un projet se fait voir dans Grafana **sans qu'on modifie la plateforme**, des trois labels du premier jour jusqu'à ses propres tableaux et alertes.

| Risque pour les sites | Coupure | Durée |
| --- | --- | --- |
| Aucun : on ajoute des labels, des fichiers de lecture, jamais de port | aucune | 20 minutes pour le niveau de base, 1 h pour des tableaux propres |

**Le principe : le projet porte tout ce qui le concerne.** La plateforme découvre, collecte et affiche ; elle n'a pas à être modifiée pour un nouveau projet.
Vue d'ensemble de ce que la plateforme observe : [carte complète](../docs/reference/observabilite-carte-complete.md). Lire Grafana : [guide 17](17-comprendre-et-lire-grafana.md).

## 1. Ce qu'on obtient, et ce que ça demande

| Niveau | Ce qu'on obtient | Ce que le projet fournit | Fichier à écrire |
| --- | --- | --- | --- |
| **0. Disponibilité** | Alerte si le site ne répond plus, alerte avant l'expiration du certificat | Le site est dans la liste des sites sondés (par le responsable de la plateforme : un fichier local au serveur) | aucun |
| **1. Journaux** | Chercher dans les journaux, voir erreurs et avertissements | 3 labels `observability.*` sur chaque service ; journaux en JSON | le compose |
| **2. Métriques** | Courbes et alertes sur l'application | `/metrics` privé, port et réseau sur le **web seul** ([modèle](../templates/laravel-observabilite/README.md)) | le compose, une route |
| **3. Son tableau « Application »** | **Déjà là**, pour tout projet des niveaux 1 et 2 : disponibilité, conteneurs, mémoire, redémarrages, journaux | rien de plus | aucun |
| **4. Ses propres tableaux et alertes** | Les chiffres de **son métier** (paiements en attente, file bloquée…) et ses règles | des fichiers dans **son dépôt** (§ 4) | `observability/` |

## 2. Les labels (niveaux 1 et 2)

Dans le `compose.prod.yaml` du projet, sur chaque service à observer :

```yaml
labels:
  observability.enable: "true"
  observability.app: mon-projet            # le nom de l'application : le même partout
  observability.deployment: ${DEPLOYMENT:-prod}   # prod, staging…
  observability.metrics.port: "8000"       # seulement si le service expose /metrics (le web)
networks: [ default, nginx-proxy, observability ]   # observability seulement pour le web
```

Le même nom `app` et le même `deployment` se retrouvent sur **les journaux, les métriques d'application, les sondes de sites et les conteneurs** : c'est ce qui permet un seul filtre dans Grafana.

## 3. Le tableau « Application — vue d'ensemble »

Grafana → **Dashboards → Plateforme → Application — vue d'ensemble**. En haut, choisir l'**application** (celle de `observability.app`) et l'**environnement**.

| Panneau | Ce qu'il dit | Vide si… |
| --- | --- | --- |
| Site en ligne, délai, certificat | Ce que voit la sonde du serveur | le site n'est pas dans la liste des sites sondés (« non sondé ») |
| Conteneurs en marche, redémarrages sur 24 h | L'état de la pile ; plus de 3 redémarrages en peu de temps : une boucle ([runbook](../docs/runbooks/conteneur-en-boucle.md)) | les conteneurs n'ont pas les labels |
| Processeur, mémoire (avec la limite), réseau | La consommation de **cette** application | idem |
| Métriques de l'application joignables | Alloy lit bien `/metrics` | l'application n'expose pas de métriques : normal |
| Journaux par niveau, journaux | Ce que l'application écrit | pas de label `observability.enable` |

Si l'application n'apparaît pas dans la liste en haut : ses conteneurs n'ont pas les labels, ou ils viennent d'être déployés (attendre une minute).

## 4. Ses propres tableaux et alertes (niveau 4)

Pour les chiffres que **seul le projet connaît**. Tout vit dans le dépôt du projet :

```
<projet>/observability/dashboards/*.json     tableaux Grafana, chacun avec un « uid »
<projet>/observability/alerts/*.yaml         règles d'alerte
```

### Étapes

1. **Partir du modèle** : copier [`templates/observabilite-projet/observability/`](../templates/observabilite-projet/README.md) à la racine du projet, remplacer `mon-projet`, écrire ses panneaux et ses règles.
2. **Vérifier sans rien publier** (ne change rien) :
   ```bash
   python3 /app/vps-platform/bin/obs-bundle.py validate --app <projet> --src observability \
       --grafana-dir /app/vps-platform/observability/grafana
   ```
3. **Livrer** : le bundle voyage avec le code. Après un **déploiement de production réussi**, `deploy.sh` le publie tout seul. À la demande : `cd /app/<projet>/prod && deploy.sh obs-sync`.
4. **Les tableaux** apparaissent dans un **dossier Grafana au nom du projet** en une dizaine de secondes. **Les alertes** ne sont relues qu'au redémarrage de Grafana : `deploy.sh` l'écrit dans son journal quand elles ont changé, et le responsable de la plateforme recrée Grafana
   (`cd /app/vps-platform/observability && docker compose --env-file .env up -d --no-deps --force-recreate grafana`).

### Les règles (sinon la publication est **refusée**, avec le motif)

| Règle | Pourquoi |
| --- | --- |
| Chaque tableau a un `uid`, 40 caractères au plus ; le **préfixer par le nom du projet** | Sans `uid` les liens cassent ; un `uid` pris par la plateforme ou un autre projet est refusé, jamais écrasé |
| Un fichier d'alertes ne contient que `apiVersion` et `groups` | Les **points de contact** et la **politique de notification** décident ce que toute la plateforme envoie : ils restent à la plateforme |
| Le `folder` de chaque groupe d'alertes est **le nom du projet** | Un projet ne range pas ses règles chez un autre |
| Dans un message d'alerte : `{{ .Labels.nom }}`, **jamais** `{{ $labels.nom }}` | Grafana remplace `$nom` dans ces fichiers : la règle se charge mais son message ne s'évalue pas |
| Noms de fichiers simples : lettres, chiffres, `.`, `_`, `-` | Aucun chemin ne sort du dossier du projet |

**Une publication refusée ne bloque jamais un déploiement** : l'erreur est écrite dans le journal (`/var/lib/vps-platform/<projet>/deploy.log`) et **le dépôt précédent reste intact**. La commande explicite `deploy.sh obs-sync`, elle, échoue pour qu'on le voie.

### Écrire un bon tableau

| Bonne pratique | Pourquoi |
| --- | --- |
| **Un chiffre mène toujours à ses lignes** : un lien (clic sur le chiffre → Explore) et un panneau de lignes **juste dessous** | Un nombre sans détail oblige à chercher ; voir [du chiffre à la ligne](17-comprendre-et-lire-grafana.md#4-bis-du-chiffre-à-la-ligne--où-voir-le-détail-dun-nombre) |
| Un compteur d'**exceptions** (erreurs, échecs) ajoute `or vector(0)` à sa requête | Sans cela, un état sain affiche « No data » au lieu de **0** |
| Un panneau qui peut légitimement être vide a un **`noValue` explicite** (« Aucun paiement sur 24 h ») | « No data » ressemble à une panne |
| Une `description` dit **ce qu'est le bon état** et **où agir** | Quelqu'un qui n'était pas là doit comprendre sans demander |

### Écrire une bonne alerte

| Bonne pratique | Pourquoi |
| --- | --- |
| Un délai (`for`), au moins 5 minutes | Contre le bruit : un pic bref ne réveille personne |
| `noDataState: OK` | Une absence de données n'est pas une panne ; l'alerte « le projet n'expose plus ses métriques » en est une à part |
| Une phrase qui dit **quoi faire** dans `summary`, avec le runbook | Quelqu'un qui n'était pas là doit pouvoir agir |
| **Exécuter la requête** avant de la publier (Explore → Prometheus) | Une règle chargée peut renvoyer **rien** sans jamais le dire : un panneau « No data » et une alerte qui ne sonne pas sont le même défaut ([retour d'expérience](../docs/retours-experience/2026-10-05-no-data-charge-par-processeur.md)) |

### Retirer l'observabilité d'un projet

`deploy.sh obs-sync --remove` : le dossier Grafana et les fichiers d'alertes du projet disparaissent (les alertes au prochain redémarrage de Grafana). Retirer un fichier du dépôt puis republier retire aussi **ce fichier** du dépôt de Grafana.

## 5. Si ça ne marche pas

| Message ou constat | Cause | Quoi faire |
| --- | --- | --- |
| `REFUSÉ — … n'est pas un JSON valide` / `un YAML valide` | Fichier mal formé | Corriger ; `obs-bundle.py validate` le dit sans rien publier |
| `REFUSÉ — l'uid « … » existe déjà (la plateforme / le projet X)` | Un autre élément porte déjà cet `uid` | Préfixer par le nom du projet |
| `REFUSÉ — clé(s) interdite(s) ['contactPoints']` | Le fichier d'alertes touche aux contacts ou à la politique | Ne garder que `apiVersion` et `groups` |
| `REFUSÉ — le dossier du groupe … doit être « <projet> »` | `folder` ne porte pas le nom du projet | Mettre le nom du projet |
| `REFUSÉ — PyYAML est requis` | Le serveur n'a pas PyYAML | `apt install python3-yaml` |
| Le dossier du projet n'apparaît pas dans Grafana | Le bundle n'a pas été publié (déploiement de production pas fait, ou refus) | Lire le journal du déploiement ; `deploy.sh obs-sync` |
| Les tableaux sont là, les alertes non | Grafana n'a pas été recréé depuis la publication | Le responsable de la plateforme recrée Grafana |
| Une alerte se charge mais son message est une erreur | `{{ $labels… }}` | `{{ .Labels… }}` |

## 6. Ce qu'il ne faut pas faire

- **Modifier la plateforme** (`vcam-infra-deploy`) pour un tableau ou une alerte propre à un projet : c'est ce que ce guide évite.
- **Mettre des secrets** dans un tableau ou une règle : ce sont des fichiers de lecture, versionnés avec le code.
- **Publier des métriques publiques** : `/metrics` n'est jamais joignable depuis Internet ([modèle Laravel](../templates/laravel-observabilite/README.md)).
- **Ranger la base ou Redis sur le réseau `observability`** : seul le conteneur web y est.
