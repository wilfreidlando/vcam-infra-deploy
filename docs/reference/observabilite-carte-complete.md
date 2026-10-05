# Carte complète de l'observabilité

> Tout ce que la plateforme observe, **où on le voit**, **qui prévient** et **quoi faire** : une seule page pour savoir ce qui existe vraiment.
> Pour apprendre à lire Grafana : [guide 17](../../guides/17-comprendre-et-lire-grafana.md). Pour installer et brancher un projet :
> [README de l'observabilité](../../observability/README.md). Retour au [sommaire](../README.md).

> **Tous les projets n'ont pas besoin de tout.** Un site simple se contente de la sonde de disponibilité ; les journaux, les métriques et les traces
> s'ajoutent selon le projet : voir les [quatre niveaux](profils-de-projet.md#6-lobservabilité-proportionnée-au-projet).

## 1. Les neuf composants

Une seule pile pour tout le serveur, dans son propre projet Docker `observability`. **Un seul composant est joignable depuis Internet : Grafana**, et
seulement par `nginx-proxy`. Aucun autre ne publie de port.

| Composant | Rôle | Qui l'alimente / qui le lit | Limite | Données conservées |
| --- | --- | --- | --- | --- |
| **Alloy** | Collecteur : lit les journaux, scrute les métriques d'applications, reçoit les traces des projets qui l'ont demandé (labels `observability.*`) | Docker (socket en lecture seule) → Loki, Prometheus, Tempo | 512 Mo | presque rien |
| **Loki** | Stocke les **journaux** | Alloy → Loki → Grafana | `LOKI_MEMORY_LIMIT` (1 Go par défaut) | 90 jours |
| **Prometheus** | Stocke les **métriques** | Alloy (applications), lui-même (job `node`, `cadvisor`, `sites`) → Grafana | 512 Mo | `PROMETHEUS_RETENTION` (30 jours par défaut) |
| **Tempo** | Stocke les **traces** | Alloy → Tempo → Grafana | 512 Mo | 30 jours |
| **node-exporter** | **Le serveur** : processeur, mémoire, swap, disque, charge | Prometheus le scrute | 64 Mo | — |
| **cAdvisor** | **Chaque conteneur** : processeur, mémoire (et limite), réseau, redémarrages | Prometheus le scrute | `CADVISOR_MEMORY_LIMIT` (512 Mo) | — |
| **blackbox-exporter** | **Les sites publics** : en ligne ou non, délai, expiration du certificat | Prometheus lui demande de sonder la liste `prometheus/targets/sites.yml` | 64 Mo | — |
| **Grafana** | Affiche, évalue les alertes, envoie les e-mails | Interroge Loki, Prometheus, Tempo | 512 Mo | comptes, réglages |
| **(Alertes)** | Règles dans Grafana, fournies **comme du code** | `observability/grafana/provisioning/alerting/` | — | — |

Les limites sont des **plafonds**, pas des réservations : l'usage réel est bien plus bas (mesuré à la mise en service de la première version :
environ 230 Mo pour les cinq composants d'origine).

## 2. Les signaux : quoi, où, qui prévient

| Signal | Source | Où le voir | Alerte | Si ça sonne |
| --- | --- | --- | --- | --- |
| **Journaux** des projets branchés | Labels `observability.*` + sortie des conteneurs | Tableau **Applications**, **Explore → Loki** | — | [Guide 17](../../guides/17-comprendre-et-lire-grafana.md) |
| **Niveau** des journaux (erreurs, avertissements) | Journaux **en JSON** (`level_name`) | Panneaux « Erreurs » et « Avertissements » | — | idem |
| **Santé du serveur** : processeur, mémoire, swap, disque, charge | node-exporter | Tableau **Plateforme → Serveur — vue d'ensemble** | 5 règles (§ 3) | [Disque plein](../runbooks/disque-plein.md), [Site en panne](../runbooks/site-en-panne.md) |
| **Consommation et redémarrages par conteneur** | cAdvisor | Tableau **Plateforme → Conteneurs** | 2 règles | [Conteneur en boucle](../runbooks/conteneur-en-boucle.md) |
| **Disponibilité et certificats des sites** | blackbox-exporter | Tableau **Plateforme → Sites** | 2 règles | [Site en panne](../runbooks/site-en-panne.md), [Certificat non émis](../runbooks/certificat-non-emis.md) |
| **Sauvegardes** : une copie part-elle sur S3 ? | Journaux de l'agent (`uploaded to s3://…`) | **Explore → Loki**, `{service="backup"}` | 1 règle | [Exercice de restauration](../runbooks/exercice-de-restauration.md) |
| **Métriques de l'application** | `/metrics` du projet (si exposé) | **Explore → Prometheus**, `up{app="…"}` | selon le projet | [README de l'observabilité](../../observability/README.md) |
| **Traces** | OTLP vers Alloy (si configuré) | **Explore → Tempo** | — | idem |
| **Le Core** | Ses métriques et tableaux dédiés | Dossier **Core System** | 6 règles propres au Core | voir ci-dessous |

## 3. Les alertes (16)

Toutes partent vers le même point de contact (`core-oncall`, nom historique : il reçoit **toutes** les alertes) par e-mail. Chacune a un **délai** (`for`)
contre le bruit. Une **absence de données ne déclenche pas d'alerte**, sauf pour celle qui surveille l'observateur lui-même.

| Alerte | Seuil | Délai | Runbook |
| --- | --- | --- | --- |
| Le serveur n'est plus observé | `node-exporter` injoignable | 5 min | [Site en panne](../runbooks/site-en-panne.md) |
| Disque du serveur presque plein | « / » à plus de 85 % | 10 min | [Disque plein](../runbooks/disque-plein.md) |
| Mémoire du serveur presque épuisée | moins de 10 % disponibles | 10 min | [Site en panne](../runbooks/site-en-panne.md) |
| Le serveur utilise beaucoup son swap | plus de 50 % du swap | 15 min | idem |
| Charge du serveur très élevée | plus de 2,5 par processeur (5 min) | 20 min | [Conteneur en boucle](../runbooks/conteneur-en-boucle.md) |
| Un conteneur redémarre en boucle | plus de 3 redémarrages en 30 min | 5 min | [Conteneur en boucle](../runbooks/conteneur-en-boucle.md) |
| Un conteneur approche de sa limite de mémoire | plus de 90 % de sa limite | 10 min | idem |
| Un site ne répond plus | sonde en échec (autre chose que 2xx) | 3 min | [Site en panne](../runbooks/site-en-panne.md) |
| Un certificat HTTPS expire bientôt | moins de 14 jours | 1 h | [Certificat non émis](../runbooks/certificat-non-emis.md) |
| Aucune sauvegarde envoyée hors du serveur depuis 36 heures | aucune ligne « uploaded to » en production | 1 h | [Exercice de restauration](../runbooks/exercice-de-restauration.md) |
| 6 règles du Core | propres au Core (injoignable, file bloquée, erreurs 5xx…) | variable | **Fausses alertes si le Core n'est pas branché** |

## 4. Les tableaux de bord

| Dossier | Tableau | Il répond à |
| --- | --- | --- |
| **Plateforme** | **Serveur — vue d'ensemble** | « Le serveur va-t-il bien ? » (processeur, mémoire, disque, charge) |
| **Plateforme** | **Conteneurs — consommation et redémarrages** | « Qui consomme ? Quel conteneur boucle ? » |
| **Plateforme** | **Sites — disponibilité et certificats** | « Les sites répondent-ils ? Un certificat va-t-il expirer ? » |
| **Applications** | **Applications — journaux (tous projets)** | « Que se passe-t-il dans les projets ? » |
| **Core System** | Vue d'ensemble, Parcours d'une requête | Le Core |

## 5. Sécurité : ce que la pile voit et ce qu'elle expose

| Composant | Accès au système | Pourquoi | Risque et garde-fou |
| --- | --- | --- | --- |
| Alloy | **Socket Docker en lecture seule** | Découvrir les conteneurs et lire leurs journaux | Un accès en lecture au socket permet d'inspecter tous les conteneurs (variables d'environnement comprises) : c'est l'**exception assumée** de la plateforme |
| node-exporter | `/` en lecture seule | Mesurer disque et mémoire du serveur | Réseau privé de la pile, aucun port publié |
| cAdvisor | `/`, `/sys`, `/var/run`, `/var/lib/docker` en lecture seule | Lire la consommation de chaque conteneur | Réseau privé de la pile, aucun port publié ; l'image vient de `gcr.io` (hors Docker Hub) |
| blackbox-exporter | Sortie réseau seulement | Sonder les sites | La liste des sites est un fichier du serveur, non commité |
| Grafana | Aucun | Afficher | **Seul composant public** : HTTPS, connexion obligatoire, inscription et accès anonyme désactivés |

Les secrets (mot de passe de Grafana, SMTP) sont dans `observability/.env` (mode `600`, ignoré par git). Les métriques d'application ne doivent **jamais** être
publiques ([README de l'observabilité](../../observability/README.md)).

## 6. Mise en service progressive

La charge du serveur est déjà élevée : on n'ajoute pas tout d'un coup.

| Ordre | Composants | Vérification avant de continuer |
| --- | --- | --- |
| 1 | `node-exporter`, `blackbox-exporter` (légers) | `up{job="node"}` vaut 1 ; charge du serveur stable |
| 2 | `cAdvisor` | Mémoire de `observability-cadvisor` sous sa limite ; charge du serveur sans hausse notable après 15 minutes |
| 3 | La liste des sites (`prometheus/targets/sites.yml`) | Tableau « Sites » rempli ; sondes « en ligne » |

Retour arrière à chaque étape : `docker compose … stop <composant>` (les données restent). Le déroulé complet, avec les commandes, les
vérifications et les pièges : [runbook de mise en service](../runbooks/mise-en-service-supervision.md).

## 7. Exploitation

| Besoin | Comment |
| --- | --- |
| Voir l'état de la pile | `docker compose -f observability/compose.yaml --env-file observability/.env ps` |
| Un composant consomme trop | Régler sa limite par variable du `.env` (`LOKI_MEMORY_LIMIT`, `CADVISOR_MEMORY_LIMIT`) puis `up -d` |
| Ajouter un site sondé | Éditer `prometheus/targets/sites.yml` sur le serveur : relu toutes les minutes, sans redémarrage |
| Changer une règle d'alerte | Fichier dans `grafana/provisioning/alerting/`, par commit, puis `git pull` et `up -d` |
| Mettre à jour une image | Changer le tag figé dans `compose.yaml`, tester (`tests/test-observability.sh`), puis `up -d` |

**Les données d'observabilité ne sont pas sauvegardées** : Loki, Prometheus et Tempo sont de l'historique, pas des données métier. Les tableaux et les règles sont
**dans le dépôt** (provisionnés) : rien de précieux n'est perdu si les volumes disparaissent, sauf les comptes Grafana à recréer.

## 8. Ce qui manque encore

| Manque | Conséquence | Piste |
| --- | --- | --- |
| Métriques et traces **des projets** | Seuls les journaux des projets branchés sont visibles ; un seul projet expose des métriques applicatives : le pilote (`/metrics`, dans son dépôt, à déployer) | [Catalogue des besoins](catalogue-des-besoins.md) |
| Alertes **par projet** (taux d'erreur, latence) | Une application lente mais « en ligne » passe inaperçue | Après les métriques applicatives |
| **Sonde externe** | Si le serveur entier tombe, rien ici ne le dit | [Guide 8](../../guides/08-surveillance-externe.md) |
| Alertes du Core | Fausses alertes tant que le Core n'est pas branché | Brancher le Core, ou les mettre en sourdine |
| Arrêts par manque de mémoire (OOM) | cAdvisor ne peut pas lire `/dev/kmsg` dans ce conteneur : le compteur d'événements OOM n'existe pas. L'alerte « approche de sa limite de mémoire » ne dépend pas de lui | Lire `dmesg` sur le serveur, ou surveiller la mémoire par conteneur |
| Alerte vers un second canal | Un seul e-mail : s'il est mal configuré, personne n'est prévenu | Un canal de plus dans Grafana |
