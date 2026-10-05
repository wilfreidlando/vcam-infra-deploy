# Runbook : mettre en service ou mettre à jour la supervision sur le serveur

| Gravité | Qui prévient | Quand |
| --- | --- | --- |
| Aucune (opération planifiée), mais le serveur est en production | le responsable de la plateforme | Après chaque évolution de `observability/` publiée dans le dépôt |

La supervision est **la seule chose qui nous dit que le reste va mal** : on la met en service avec autant de soin qu'un projet, **par
paliers**, en vérifiant **chaque signal séparément** à chaque palier. Cette page est le déroulé qui a servi pour la première
mise en service (voir les [retours d'expérience](../retours-experience/README.md) du 5 octobre 2026) ; elle est écrite pour quelqu'un
qui n'y était pas.

Vue d'ensemble de ce qui existe : [carte complète de l'observabilité](../reference/observabilite-carte-complete.md). Dans le doute sur
un composant : [README de l'observabilité](../../observability/README.md).

## 0. Avant de commencer

| Contrôle | Pourquoi |
| --- | --- |
| La charge du serveur est stable et pas élevée ( `uptime` ) | Une mise en service ajoute de la charge ; on ne la cumule pas avec une construction d'image ou une sauvegarde |
| Aucune sauvegarde nocturne dans les 30 minutes (`BACKUP_TIME` de chaque projet, en UTC) | Pour séparer les causes si quelque chose se passe mal |
| La phase de travail autorise l'action (`.claude/PHASE`) | Règle de l'équipe : l'inventaire est en lecture seule |
| Le dépôt de la plateforme est à jour sur le serveur (`git pull --ff-only`) | Les fichiers de configuration sont lus **depuis ce dossier** |
| Les tests de la pile passent en local (`tests/test-observability.sh`) | Rien n'est essayé pour la première fois sur le serveur |

## 1. L'ordre, et pourquoi

| Palier | Ce qu'on démarre | Pourquoi dans cet ordre | Vérification avant de continuer |
| --- | --- | --- | --- |
| 1 | `node-exporter`, `blackbox-exporter`, puis Prometheus (rechargé) | Légers (quelques Mo), et sans effet sur les alertes | `up{job="node"}` vaut 1 ; la charge n'a pas bougé |
| 2 | Les **projets** à observer (leurs labels, leur `/metrics`) | Les alertes sur les sauvegardes et les sites **lisent ces signaux** : sans eux elles sonneraient à tort | Les **trois signaux** du projet (§ 3) |
| 3 | **Alloy** recréé si sa configuration a changé | Il est le seul à porter les métriques des projets | `up{app="<projet>"}` vaut 1 |
| 4 | **Grafana** recréé (tableaux et alertes) | Il charge les règles ; elles doivent trouver leurs signaux | Les alertes sont « Normal », pas « Pending » |
| 5 | `cAdvisor`, **après observation** de la charge | Le plus gourmand ; cgroup v1 non vérifié sur ce serveur | Mémoire sous sa limite ; charge sans hausse notable après 15 minutes |
| 6 | La liste des sites (`prometheus/targets/sites.yml`) | Fichier propre au serveur, jamais commité | Tableau « Sites » rempli, sondes en ligne |

**Le piège de l'ordre (palier 2 avant 4).** L'alerte « aucune sauvegarde envoyée depuis 36 h » cherche, dans Loki, une ligne
`uploaded to` sur le conteneur de sauvegarde **par ses labels**. Tant que le projet n'a pas ses labels, Loki ne la voit pas, et
l'alerte part par e-mail au bout d'une heure alors que les sauvegardes fonctionnent. On ne charge donc ces règles **qu'une fois les
projets branchés**.

## 2. Commandes, un palier à la fois

Les commandes se lancent depuis `observability/` sur le serveur. **Une à la fois**, en notant l'heure.

```bash
cd /app/vps-platform/observability
# Palier 1 : les deux exporteurs légers et Prometheus, sans toucher au reste (--no-deps)
sudo docker compose --env-file .env up -d --no-deps node-exporter blackbox-exporter prometheus
# Palier 3 : Alloy seul
sudo docker compose --env-file .env up -d --no-deps alloy
# Palier 4 : Grafana seul
sudo docker compose --env-file .env up -d --no-deps grafana
# Palier 5 : cAdvisor, quand la charge est sous contrôle
sudo docker compose --env-file .env up -d --no-deps cadvisor
```

| Pour chaque commande | Réponse |
| --- | --- |
| Effet | Le ou les services nommés sont recréés avec la configuration à jour ; **les volumes (historique) restent** |
| Coupure | Aucune pour les sites. Un trou de quelques secondes dans les courbes ; pour Grafana, les écrans se reconnectent |
| Retour arrière | `sudo docker compose --env-file .env stop <service>` (les données restent), ou `git reset --hard <commit précédent>` puis la même commande |
| Vérification | § 3 |

`--no-deps` est volontaire : il garantit qu'on ne recrée **que** ce qu'on a nommé.

## 3. Vérifier chaque signal, séparément

Voir que les journaux arrivent **ne prouve rien** sur les métriques. Pour un projet, trois vérifications indépendantes :

| Signal | Où | Résultat attendu |
| --- | --- | --- |
| Journaux | Grafana → Explore → Loki → `{app="<projet>"}` | Des lignes récentes, au format JSON si le projet l'a prévu (`level`, `msg`) |
| Métriques | Grafana → Explore → Prometheus → `up{app="<projet>"}` | La valeur **1** pour le conteneur web |
| Alertes | Grafana → Alerting | Les règles de la plateforme sont « Normal » |

Si les **métriques** manquent alors que les journaux sont là :
1. Le conteneur est-il sur le réseau `observability` ? (`docker inspect <conteneur>`, section des réseaux)
2. Porte-t-il `observability.metrics.port` ? (`docker inspect`, section des labels)
3. Alloy voit-il la cible ? Sa page de composants (réseau privé de la pile) liste les cibles de `discovery.relabel.metrics` : **zéro** signifie
   que la découverte écarte le conteneur. Cause connue : [Les métriques du pilote n'arrivaient pas](../retours-experience/2026-10-05-metriques-du-pilote-absentes-reseau-alloy.md).
4. `/metrics` répond-il depuis le réseau privé (200) et reste-t-il **fermé** depuis Internet (404) ?

## 4. Ce qu'il ne faut pas faire

- **Ne pas tout démarrer d'un coup** (`up -d` sans noms) sur un serveur déjà chargé : les paliers existent pour ça.
- **Ne pas charger les alertes avant les signaux** qu'elles lisent (§ 1).
- **Ne pas publier de port** d'un composant de la pile : seul Grafana est joignable, et seulement par `nginx-proxy`.
- **Ne pas mettre la base, Redis ou un conteneur PHP-FPM** sur le réseau `observability` (voir le README de l'observabilité).
- **Ne pas supprimer les volumes** de la pile pour « repartir propre » : on perd l'historique des journaux et des courbes.
- **Ne pas conclure** « c'est branché » sur la foi des seuls journaux.

## 5. Ce qu'on écrit après

| Quoi | Où |
| --- | --- |
| La date, les paliers faits, ce qui a surpris | Le journal privé du responsable de la plateforme |
| Tout ce qui n'a pas marché du premier coup | Un [retour d'expérience](../retours-experience/README.md) |
| Ce qui reste à faire (cAdvisor, liste des sites, sonde externe) | La section « Ce qui manque encore » de la [carte](../reference/observabilite-carte-complete.md) |
