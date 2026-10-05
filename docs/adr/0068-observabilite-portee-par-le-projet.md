# ADR-0068 — Observabilité portée par le projet : tableaux et alertes dans le dépôt du projet, tableau générique pour tous

- **Statut** : Accepté — complète ADR-0065 (supervision) et ADR-0067 (profils de projet)
- **Date** : 2026-10-05
- **Décideurs** : responsable de la plateforme, sur demande de la direction technique

## Contexte

Le but de la plateforme est qu'**un projet s'y ajoute sans qu'on la modifie**. Pour les journaux, les métriques et la disponibilité, c'est le cas : trois labels dans le compose du projet,
et Alloy le découvre. Mais les tableaux et les alertes **propres à un projet** (ceux du Core : deux tableaux, six règles `core_*`) étaient **écrits dans le dépôt de la plateforme**, avec
`deployment="prod"` écrit en dur. Pour un nouveau projet, il aurait fallu un commit dans `vcam-infra-deploy`, un `git pull` et un redémarrage de Grafana. Le Core était une exception qui devenait
la règle.

## Décision

### 1. Un tableau générique « Application — vue d'ensemble », pour tous les projets, sans fichier à écrire

Un seul tableau, paramétré par l'application et l'environnement : disponibilité et certificat (sonde), conteneurs en marche, redémarrages, processeur, mémoire, réseau, journaux par niveau.
Pour que les **conteneurs** se rattachent à leur application, cAdvisor garde **deux** labels Docker (`observability.app`, `observability.deployment`), que Prometheus renomme `app` et `deployment` :
le même filtre vaut donc pour les journaux, les métriques d'application, les sondes et les conteneurs. Les autres labels restent ignorés (cardinalité).

### 2. Un projet qui veut ses PROPRES tableaux et alertes les livre dans SON dépôt

```
<projet>/observability/dashboards/*.json     tableaux Grafana (chacun avec un « uid »)
<projet>/observability/alerts/*.yaml         règles d'alerte (format de provisionnement Grafana)
```

`deploy.sh obs-sync` (lancé aussi automatiquement **après un déploiement de production réussi**) les dépose dans l'arbre de Grafana de la plateforme, dans des emplacements **ignorés par git** :
un dossier Grafana par projet (`projets/dashboards/<projet>/`) et des fichiers `provisioning/alerting/projet-<projet>-*.yaml`. La plateforme n'est plus jamais modifiée pour un projet.

### 3. Garde-fous (un projet ne doit jamais pouvoir casser Grafana ni toucher à ce qui n'est pas à lui)

| Garde-fou | Pourquoi |
| --- | --- |
| JSON et YAML **lus avant dépôt** ; refus sans toucher au dépôt précédent | Un fichier d'alertes invalide empêcherait Grafana de charger **toutes** les alertes |
| Un fichier d'alertes ne contient que `apiVersion` et `groups` : **ni points de contact, ni politique de notification, ni suppression de règles** | Ces éléments décident ce que **toute la plateforme** envoie et à qui |
| Le dossier d'un groupe d'alertes est **le nom du projet** | Un projet ne range pas ses règles chez un autre |
| Un tableau a un `uid` (obligatoire) et est déposé sans `id` | Sans `uid`, Grafana en invente un et les liens cassent |
| **Aucun `uid` déjà pris** (plateforme ou autre projet) : refus plutôt qu'écrasement | Deux projets ne se marchent pas dessus |
| La publication **ne bloque jamais un déploiement** : une erreur est journalisée, la livraison continue ; la commande explicite `obs-sync`, elle, échoue pour qu'on le voie | L'observabilité ne doit pas pouvoir empêcher une livraison |

## Pourquoi pas autrement

| Option écartée | Raison |
| --- | --- |
| Tout laisser dans le dépôt de la plateforme | C'est la situation de départ : chaque projet modifie la plateforme |
| Appeler l'API de Grafana avec un jeton depuis `deploy.sh` | Un secret d'administration de plus à protéger sur chaque poste de déploiement ; et rien ne vérifie le contenu avant qu'il arrive dans Grafana |
| Monter le dossier d'observabilité de chaque projet dans Grafana | Il faudrait modifier le compose de la plateforme à chaque nouveau projet : le problème d'origine |

## Conséquences

- **Les tableaux se rechargent seuls** (une dizaine de secondes). **Les alertes ne sont relues qu'au redémarrage de Grafana** : `deploy.sh` le dit quand les alertes ont changé
  (« recréer Grafana »). C'est une limite assumée : recréer Grafana depuis un déploiement de projet donnerait à chaque projet la main sur un service partagé.
- **Python 3 et PyYAML sont requis** sur le serveur (présents). Sans PyYAML, les alertes sont refusées avec le message qui dit quoi installer.
- Le tableau d'un projet est publié après **la production**, pas après le staging : il suit la version qui sert les utilisateurs.
- **Reste une limite** : la validation vérifie la forme (YAML, clés autorisées, uid), pas la **sémantique** d'une règle (une requête fausse). C'est le rôle du projet de tester ses règles, comme le fait la
  plateforme pour les siennes (`tests/test-observability.sh` exige que chaque requête renvoie des données).
- **Migration du Core** : ses deux tableaux et ses six règles passent du dépôt de la plateforme à celui du Core, et sont retirés de la plateforme.
- **Testé** : `tests/test-obs-bundle.sh` (29 vérifications : dépôt, refus, aucun écrasement, retrait, modèle du dépôt), `tests/test-deploy.sh` (publication après la production, jamais bloquante),
  `tests/test-observability.sh` (Grafana charge réellement le dossier et la règle d'un projet publié).
