# ADR-0065 — Supervision du serveur : node-exporter, cAdvisor, sondes de sites et alertes génériques

- **Statut** : Accepté — complète ADR-0064 (observabilité mutualisée)
- **Date** : 2026-10-05
- **Décideurs** : responsable de la plateforme

## Contexte

La pile d'observabilité ne collectait que ce que les projets lui envoyaient (journaux, métriques, traces) et seulement pour ceux qui l'avaient
demandé. Elle **n'observait pas le serveur** : aucune courbe de processeur, de mémoire, de disque ni de charge, et les seules alertes étaient
propres au Core. Un disque qui se remplit, une mémoire épuisée ou une charge chroniquement élevée passaient inaperçus (constaté à l'inventaire :
charge élevée, mémoire libre faible, aucune alerte). Les journaux répondent à « que s'est-il passé ? », pas à « est-ce que
ça va ? ».

## Options

| Option | Pour | Contre |
| --- | --- | --- |
| **A. `node-exporter` dédié** (conteneur) | Standard, léger (≈ 20 Mo), indépendant d'Alloy, testable seul | Un conteneur de plus ; monte `/` en lecture seule |
| B. Exporteur intégré à Alloy (`prometheus.exporter.unix`) | Un conteneur de moins | Alloy a déjà le socket Docker : lui monter aussi le système de fichiers concentre trop de droits dans le collecteur de tout le serveur |
| C. cAdvisor | Métriques **par conteneur** (consommation, redémarrages) | Gourmand avec plusieurs centaines de conteneurs sur un serveur déjà chargé ; à introduire **progressivement**, avec limites et observation |
| D. Ne rien faire | Aucun coût | L'aveuglement actuel |

## Décision

**A maintenant, C ensuite.**

1. `node-exporter` (`prom/node-exporter`, version figée) dans la pile, sur son réseau privé, **sans port publié**, `/` monté en lecture seule, limité à 64 Mo
   et 0,25 processeur. Prometheus le scrute directement (`prometheus.yml`), Alloy n'est pas modifié.
2. **Cinq alertes génériques** (serveur plus observé, disque > 85 %, mémoire disponible < 10 %, swap > 50 %, charge > 2,5 par processeur), chacune avec
   un délai, une absence de données sans alerte (sauf pour l'alerte qui surveille l'observateur), et un renvoi vers le runbook concerné.
3. Un tableau **Plateforme → Serveur — vue d'ensemble**.
4. **cAdvisor**, livré dans la même version mais **mis en service dans un second temps** (après avoir observé l'effet de (1) sur la charge), avec une limite de
   mémoire (`CADVISOR_MEMORY_LIMIT`), un intervalle de collecte de 60 s, `--docker_only`, huit familles de métriques et les séries sans nom jetées par
   Prometheus. Deux alertes : conteneur en boucle (plus de 3 redémarrages en 30 min), conteneur à plus de 90 % de sa limite de mémoire. Tableau **Conteneurs**.
5. **Sondes de sites** (`blackbox-exporter`) : disponibilité et expiration des certificats, vues du serveur. La liste des sites est un **fichier du serveur** non commité
   (`prometheus/targets/sites.yml`), relu à chaud. Deux alertes et un tableau **Sites**. **Ne remplace pas une sonde externe.**
6. **Alerte « sauvegarde absente »** à partir des journaux de l'agent : aucune ligne `uploaded to` en production depuis 36 h.

## Conséquences

- Une panne lente du serveur (disque, mémoire) est signalée **avant** qu'elle ne coupe des sites.
- Les alertes partent vers le point de contact par défaut (`core-oncall`, nom historique) : elles supposent qu'un SMTP est configuré.
- **Limite connue** : cAdvisor et node-exporter montent le système de fichiers de l'hôte **en lecture seule** ; ils n'exposent aucun port. L'image de cAdvisor vient de
  `gcr.io` (hors Docker Hub) : une dépendance de plus, version figée.
- `node-exporter` voit le disque et la mémoire du **serveur** ; les interfaces réseau de l'hôte ne sont pas exposées (conteneur sur un réseau privé,
  pas en `network_mode: host`, pour ne publier aucun port).
- Un seuil de charge à 2,5 par processeur est volontairement haut : la charge normale du serveur est déjà élevée. À ajuster avec l'expérience.
