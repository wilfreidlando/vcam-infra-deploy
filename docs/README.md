# Documentation — sommaire

Ce dépôt a plusieurs métiers (le standard, les outils, le serveur, l'observabilité, les
sauvegardes, la qualité, la mémoire). Cette page est **le seul endroit à connaître** : de là,
on trouve tout. Retour à l'[accueil du dépôt](../README.md).

## 1. Comment la documentation est rangée

Quatre sortes de documents, chacune a une place et un but. Avant d'écrire, on choisit la sorte.

| Sorte | Elle répond à | Elle est… | Où |
| --- | --- | --- | --- |
| **Référence** | « Que dit la règle ? Comment est fait X ? » | Stable, exacte, à consulter | [`docs/`](.) (contrat, schémas, glossaire) et [`docs/reference/`](reference) |
| **Guide** | « Comment je fais Y, pas à pas ? » | Une procédure avec risque, durée, vérification et retour arrière | [`guides/`](../guides/README.md) |
| **Runbook** | « Ça ne marche plus, que faire maintenant ? » | Une page par incident, écrite pour agir vite | [`docs/runbooks/`](runbooks/README.md) |
| **Mémoire** | « Pourquoi ce choix ? Qu'est-ce qui a déjà mal tourné ? Où en est le serveur ? » | Datée, jamais réécrite : on ajoute, on ne corrige pas le passé | [`docs/adr/`](adr/README.md), [`docs/retours-experience/`](retours-experience/README.md), [`docs/inventaire/`](inventaire/README.md) |

Chaque dossier outil a aussi son propre `README.md`, à côté du code qu'il décrit :
[`observability/`](../observability/README.md), [`images/db-backup/`](../images/db-backup/README.md),
[`tests/`](../tests/README.md).

## 2. Je veux… → je lis

| Je veux… | Je lis |
| --- | --- |
| Comprendre en 10 minutes ce que fait le dépôt | [Accueil du dépôt](../README.md) |
| Savoir ce qu'un projet doit respecter | [Contrat d'un projet](05-contrat-projet.md) |
| Les 16 règles en un tableau | [Les 16 règles](reference/les-16-regles.md) |
| Comprendre comment le serveur est construit | [Architecture du serveur](reference/architecture-du-serveur.md), [schémas](01-schemas.md) |
| Un mot que je ne connais pas | [Glossaire](03-glossaire.md) |
| Mettre mon projet en ligne | [Démarrage rapide](04-demarrage-rapide-dev.md), [brancher un projet](reference/brancher-et-corriger-un-projet.md) |
| Amener un projet existant au standard | [Guide 16](../guides/16-mettre-un-projet-au-standard.md), [contrat § 4](05-contrat-projet.md#4-appliquer-le-contrat-à-un-projet-déjà-en-production) |
| Déployer, promouvoir, revenir en arrière | [Organisation et livraison](reference/organisation-et-livraison.md) |
| Installer le serveur de zéro | [Feuille de route](../guides/00-feuille-de-route.md), puis les [guides](../guides/README.md) |
| Régler le DNS, un sous-domaine | [Domaines et DNS](reference/domaines-et-dns.md), [guide 2](../guides/02-dns-wildcard.md) |
| Régler le serveur lui-même (journaux, pare-feu) | [Réglages de l'hôte](reference/reglages-de-lhote.md), [guide 9](../guides/09-rotation-journaux-hote.md) |
| Sauvegarder et restaurer une base | [Sauvegardes](reference/sauvegardes.md), [exercice de restauration](runbooks/exercice-de-restauration.md) |
| Voir ce qui se passe (journaux, métriques) | [Guide 17, lire Grafana](../guides/17-comprendre-et-lire-grafana.md) |
| Brancher un projet à Grafana | [README de l'observabilité](../observability/README.md) |
| Réagir à une panne | [Runbooks](runbooks/README.md) |
| Savoir pourquoi on a fait ce choix | [ADR](adr/README.md) |
| Savoir ce qui a déjà mal tourné | [Retours d'expérience](retours-experience/README.md) |
| Savoir l'état du serveur à une date | [Inventaires](inventaire/README.md) |
| Faire évoluer la plateforme (règle, outil) | [Guide 15](../guides/15-prise-en-main-equipe-it.md), [contrat § 5](05-contrat-projet.md#5-faire-évoluer-le-contrat), [tests](../tests/README.md) |
| Faire inventorier le serveur par un agent | [Guide 13](../guides/13-intervention-assistee.md) |
| Reprendre le serveur sans l'avoir construit | [Guide 15](../guides/15-prise-en-main-equipe-it.md) |

## 3. Catalogue complet

### Le standard (référence)

| Document | Contenu |
| --- | --- |
| [Contrat d'un projet](05-contrat-projet.md) | **Le référentiel** : clauses C1 à C12, noms, mise en conformité, évolution du contrat |
| [Les 16 règles](reference/les-16-regles.md) | Résumé du contrat en un tableau |
| [Architecture du serveur](reference/architecture-du-serveur.md) | Vue d'ensemble, réseaux Docker |
| [Schémas](01-schemas.md) | Un schéma par élément |
| [Résilience et évolutivité](02-resilience-evolutivite.md) | Ce qui tient en cas de panne, comment le serveur grandit |
| [Glossaire](03-glossaire.md) | Le vocabulaire |

### Le fonctionnement au quotidien (référence)

| Document | Contenu |
| --- | --- |
| [Démarrage rapide pour les développeurs](04-demarrage-rapide-dev.md) | Mettre son projet en ligne |
| [Organisation et livraison](reference/organisation-et-livraison.md) | Dossiers du serveur, staging, promotion, retour arrière |
| [Brancher et corriger un projet](reference/brancher-et-corriger-un-projet.md) | Liste de contrôle et table des corrections |
| [Domaines et DNS](reference/domaines-et-dns.md) | Wildcard, collisions, Cloudflare |
| [Réglages de l'hôte](reference/reglages-de-lhote.md) | Journaux Docker, pare-feu, mises à jour, SSH |
| [Sauvegardes](reference/sauvegardes.md) | Agent, fréquence, test de restauration |
| [Supervision et incidents](reference/supervision-et-incidents.md) | Ce qu'on surveille, première réponse |
| [Contenu du dépôt, outil par outil](reference/contenu-du-depot.md) | Chaque dossier et chaque outil de `bin/` |

### Guides pas à pas

Classés par thème dans l'[index des guides](../guides/README.md) : **installer le serveur**,
**mettre un projet au standard**, **surveiller et exploiter**, **comprendre et reprendre**.

### Runbooks d'incident

[Index](runbooks/README.md) : [site en panne](runbooks/site-en-panne.md),
[disque plein](runbooks/disque-plein.md), [certificat non émis](runbooks/certificat-non-emis.md),
[base inaccessible](runbooks/base-inaccessible.md),
[exercice de restauration](runbooks/exercice-de-restauration.md).

### Mémoire

| Dossier | Contenu |
| --- | --- |
| [`adr/`](adr/README.md) | Décisions d'architecture, une par fichier |
| [`retours-experience/`](retours-experience/README.md) | Un incident ou un déploiement raté par fichier, avec la protection mise en place |
| [`inventaire/`](inventaire/README.md) | L'état du serveur à une date, avec les écarts au contrat |

## 4. Où ranger un nouveau document

| Je veux écrire… | Je le mets… | Je l'ajoute à… |
| --- | --- | --- |
| Une règle ou une définition | `docs/` ou `docs/reference/` | Ce sommaire (§ 3) |
| Une procédure avec risque et retour arrière | `guides/NN-sujet.md` (numéro suivant) | L'[index des guides](../guides/README.md), dans son thème |
| Une réaction à une panne | `docs/runbooks/sujet.md` | L'[index des runbooks](runbooks/README.md) |
| Une décision, avant ou après coup | `docs/adr/NNNN-sujet.md` | L'[index des ADR](adr/README.md) |
| Un incident ou un échec | `docs/retours-experience/AAAA-MM-JJ-sujet.md` | L'[index des retours d'expérience](retours-experience/README.md) |
| L'état du serveur | `docs/inventaire/AAAA-MM-JJ-inventaire-vps.md` | L'[index des inventaires](inventaire/README.md) |
| Le mode d'emploi d'un outil | Un `README.md` **à côté de l'outil** | Ce sommaire |

Règles de forme :

- **Un sujet, un document.** Si un document répond à deux questions, on le coupe.
- **Pas de doublon** : on lie vers la source au lieu de recopier.
- **Les chemins existants ne changent pas** : des outils, des guides et des messages de
  `deploy.sh` les citent (« guide 3 », `docs/05-contrat-projet.md`).
- **Chaque lien relatif est vérifié** par `tests/test-docs.sh` : un document déplacé ou renommé
  qui casse un lien fait échouer le test.
- **Pas de secret, ni d'adresse du serveur, ni d'identifiant de connexion** dans le dépôt : un
  inventaire se relit avant d'être publié.
