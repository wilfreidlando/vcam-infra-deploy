# 2026-10-05 — Les métriques du pilote n'arrivaient pas : Alloy ne regardait qu'un réseau sur trois

**Impact** : aucun site touché, aucune donnée en danger. Les **journaux** du pilote arrivaient dans Grafana, ses **métriques** jamais.
Sans cette découverte, le projet pilote aurait été déclaré « observé » alors que la moitié du travail manquait.
**Détecté par** : la vérification faite **juste après** le premier déploiement réel du pilote avec ses métriques (Prometheus ne
contenait aucune série du pilote). Le test local de la pile était pourtant au vert.

## Ce qui s'est passé

| Étape | Résultat |
| --- | --- |
| Déploiement du pilote en staging avec les labels `observability.*` et `observability.metrics.port` | réussi, site et contrôle de santé en ordre |
| `/metrics` du pilote | **404 depuis Internet**, **200 depuis le réseau privé** : la protection fonctionne |
| Journaux du pilote dans Loki, en JSON, avec `app`, `deployment`, `service` | présents |
| Métriques du pilote dans Prometheus (`skills_devops_up`) | **absentes** |
| Composant de scrutation d'Alloy | **0 cible** |

## Cause

Le conteneur web d'un projet de la plateforme est sur **trois réseaux** : `nginx-proxy` (accès public), `observability` (pour
être scruté) et son réseau privé. Pour chaque conteneur, la découverte Docker d'Alloy a une option, `match_first_network`, qui vaut
**vrai par défaut** : elle ne retient que **le premier réseau, par ordre alphabétique**. Ici, `nginx-proxy` passe avant
`observability` : la seule cible conservée était donc sur `nginx-proxy`, que la règle de scrutation écarte (elle ne garde que le réseau
`observability`). Résultat : zéro cible, aucune erreur, aucun message.

Les **journaux** n'étaient pas touchés : ils sont lus par le socket Docker et n'ont pas besoin du réseau, ce qui a masqué le
problème.

## Pourquoi rien ne l'a arrêté

- **Le test n'avait pas la disposition réelle.** L'application de démonstration du test n'était que sur le réseau partagé : un
  seul réseau, donc « premier réseau » = le bon. C'est exactement la même famille d'erreur que pour le nettoyage des images et la
  restauration : **le test ne reproduisait pas la disposition du serveur**.
- **Un commentaire de la configuration affirmait une vérification** (« un conteneur sur deux réseaux n'est listé qu'une fois »)
  faite avec **deux réseaux privés**, pas avec le réseau partagé en second.
- **Aucune alerte ne sonne** quand une cible n'existe pas : une cible absente ne produit pas de série « en panne », elle ne produit
  rien du tout.

## Correction

| Quoi | Où |
| --- | --- |
| `match_first_network = false` : tous les réseaux du conteneur sont examinés, la règle existante retient `observability` | `observability/alloy/config.alloy` |
| Le test place l'application de démonstration sur **deux réseaux**, dont un qui passe **avant** `observability` dans l'ordre alphabétique | `tests/test-observability.sh` |
| Règle écrite pour les projets : un projet est sur plusieurs réseaux, c'est normal | [README de l'observabilité](../../observability/README.md) |
| Étape de vérification ajoutée à la mise en service : « les métriques du projet existent dans Prometheus » | [Runbook de mise en service](../runbooks/mise-en-service-supervision.md) |

Vérifié **dans les deux sens** : avec la correction, le test complet réussit (32 vérifications) ; **sans** elle, il échoue sur une
seule vérification, « métriques scrapées avec labels », et sur aucune autre.

## Protection pour tous les projets

- Le test échoue si la correction est retirée : tout retour en arrière est détecté avant publication.
- **Règle générale** : un test d'infrastructure se joue sur **la disposition réelle** (nombre de réseaux, ordre des noms, volumes
  présents), pas sur une version simplifiée. Troisième REX du même type : à relire avant d'écrire un nouveau test.
- **Règle de vérification** : après chaque branchement d'un projet, on vérifie **chaque signal séparément** (journaux, métriques,
  traces). Voir que les journaux arrivent ne prouve rien sur les métriques.

## Reste à faire

| Quoi | Qui |
| --- | --- |
| Publier ce correctif, mettre à jour le dépôt sur le serveur, recréer Alloy, vérifier `up{app="skills-devops"}` | responsable de la plateforme |
| Au prochain projet branché : appliquer le runbook et vérifier les trois signaux | responsable du projet |
