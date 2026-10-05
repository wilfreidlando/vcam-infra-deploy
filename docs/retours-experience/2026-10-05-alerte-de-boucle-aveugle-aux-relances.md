# 2026-10-05 — L'alerte « un conteneur redémarre en boucle » et le panneau « Redémarrages » ne pouvaient rien voir

**Impact** : **une alerte et trois panneaux inopérants** depuis leur mise en service. Un conteneur en boucle (plusieurs centaines de milliers de redémarrages cumulés sur le serveur) n'aurait **jamais** déclenché l'alerte, et le panneau « Aucun redémarrage sur 24 h » affichait **un faux bon état**. Aucun site touché : les trois boucles réelles avaient été arrêtées à la main le matin même.
**Détecté par** : l'examen de deux conteneurs signalés comme « en boucle » (`cpf_worker_2`, `e_tourisme_queue`), **pas par un test**. Le « top des démarrages » de Prometheus affichait 0 partout alors que `cpf_worker_2` venait de redémarrer.

## Ce qui s'est passé

| Constat | Détail |
| --- | --- |
| Les deux conteneurs signalés | **Normaux** : des `queue:work --max-time=3600` Laravel qui s'arrêtent volontairement (code 0) toutes les heures et que Docker relance. 1655 redémarrages ≈ 69 jours × 24 h ; 237 ≈ 9,9 jours × 24 h |
| Les trois vraies boucles du serveur | `cpf_dev_worker` (105 067), `cpf_dev_app` (39 059), `nginx_ifphnt` (192 064) : **déjà arrêtées** ce matin (`exited`, politique `no`). Causes : service Redis/base ou amont nginx qui n'existe plus |
| `changes(container_start_time_seconds)` pour `cpf_worker_2` sur 6 h | **0**, alors que le conteneur a redémarré 5 fois |
| `container_start_time_seconds` de `cpf_worker_2` | « il y a 69 jours » : la date de **création** du conteneur, pas de son dernier démarrage |
| `resets(container_cpu_usage_seconds_total)` sur 6 h | **5** pour `cpf_worker_2`, **4** pour `e_tourisme_queue`, **0** pour un conteneur stable |

## Cause

**Un signal qui ne change pas quand on le croit.** cAdvisor exporte pour un conteneur Docker la date de création de **ce conteneur**. Quand Docker relance le **même** conteneur (cas d'une boucle, d'un worker `--max-time`), la date ne bouge pas : `changes()` reste à 0. (Sous Kubernetes, un redémarrage crée un nouveau conteneur : c'est ce qui rend la recette « `changes(container_start_time_seconds)` » courante sur Internet, et trompeuse ici.)

**Pourquoi le test ne l'a pas vu** : il vérifiait que la série `container_start_time_seconds` **existe** et porte les bons labels. Une série qui existe n'est pas une série qui **détecte**. C'est la troisième occurrence du même défaut dans la journée : « No data » de la charge, alerte de swap sur le niveau, et celle-ci. Voir [la charge par processeur](2026-10-05-no-data-charge-par-processeur.md).

## Correction

| Quoi | Avant | Après |
| --- | --- | --- |
| Alerte « Un conteneur redémarre en boucle » | `changes(container_start_time_seconds[30m])` > 3 | `resets(container_cpu_usage_seconds_total[30m])` > 3 |
| Panneaux « Redémarrages » (Conteneurs : compteur et barres ; Application) | idem | idem |
| Test | la série existe | **un conteneur qui s'arrête et est relancé par Docker toutes les ~10 s** est compté (≥ 2 en 5 min) ; un conteneur stable ne l'est pas ; plus aucun fichier ne cite `container_start_time_seconds` |

Le compteur de processeur d'un conteneur repart de zéro à chaque relance : `resets()` le compte.

## Limites à connaître (honnêtement)

- **Une recréation n'est pas une relance** : un déploiement qui recrée le conteneur donne un nouvel identifiant, donc une nouvelle série, et n'est pas compté. C'est voulu : un déploiement n'est pas une boucle.
- **Détection probabiliste pour une boucle très serrée** (un redémarrage par seconde) : le compteur est échantillonné toutes les 15 s ; entre deux échantillons, la valeur peut être plus haute ou plus basse qu'avant. Sur 30 minutes, des dizaines de baisses sont observées : le seuil de 3 est atteint avec une très grande probabilité, **sans garantie arithmétique**.
- Un conteneur qui n'a **consommé aucun processeur** avant de s'arrêter ne serait pas vu : cas théorique, un démarrage coûte toujours du processeur.

## Ce qu'il faut retenir

1. **Un test doit provoquer l'événement qu'il prétend détecter** : ici, de vraies relances, pas la présence d'une série.
2. **Lire un compteur de redémarrages avec l'âge du conteneur** : `redémarrages ÷ jours de vie`. 24 par jour = un par heure = un worker réglé ainsi ; des centaines par jour = une boucle ([runbook](../runbooks/conteneur-en-boucle.md)).
3. **Valider une règle de supervision contre un cas réel connu** (ici : les heures de relance des deux workers) avant de la déclarer fonctionnelle.
4. **Un test qui échoue au hasard est un défaut du test, pas de la règle.** La première version du conteneur d'essai ne consommait du processeur que 2 s sur un cycle de 11 s : le compteur restait à son plateau d'un échantillon (15 s) à l'autre, et la relance
   n'était vue qu'une fois sur deux (réussite le matin, échec l'après-midi). Le conteneur d'essai consomme maintenant du processeur pendant **tout** son cycle, donc la baisse est visible quelle que soit la phase de l'échantillon.
5. **Ne jamais lancer un test pendant qu'un autre tourne.** Chaque test se termine en supprimant tous les conteneurs `vpstest-*` : lancer le test des documents pendant le test `deploy` a détruit ses conteneurs et l'a fait échouer à tort.
