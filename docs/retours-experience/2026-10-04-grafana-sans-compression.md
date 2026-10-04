# 2026-10-04 — Grafana ne charge pas dans le navigateur : aucun site n'est compressé

**Impact** : aucun site touché. Le Grafana mutualisé, mis en service le jour même, était
joignable (HTTP 200, certificat valide) mais le navigateur d'un utilisateur affichait
« Grafana has failed to load its application files » : l'interface était inutilisable pour lui.
**Détecté par** : la personne responsable, en ouvrant Grafana pour la première fois.

## Ce qui s'est passé

| Heure (UTC) | Fait |
| --- | --- |
| 21:25 | La pile d'observabilité démarre ; Grafana répond en interne et en HTTPS |
| Après la mise en service (heure non relevée) | Premier accès depuis un navigateur : page « failed to load its application files » |
| Plus tard | Nouvel essai de la personne responsable : la page de connexion finit par se charger, mais avec un temps de chargement long. C'est cohérent avec la cause ci-dessous (un seul essai, sur un réseau donné : à remesurer après la correction) |
| Ensuite | Test depuis le serveur : la page de connexion et ses neuf fichiers JavaScript et CSS répondent tous HTTP 200, avec le bon type. Le serveur est donc correct |

## Cause

Les fichiers de l'application Grafana pèsent jusqu'à **3,5 Mo chacun, environ 9 Mo au total**.
Ils partaient **sans compression** : avec ou sans `Accept-Encoding: gzip`, la taille reçue est
identique et aucun en-tête `content-encoding` n'apparaît.

`nginx-proxy` contient bien une ligne `gzip_types text/plain text/css application/javascript … text/javascript`,
mais **aucune directive `gzip on`** : la liste des types est inutile tant que la compression n'est pas
activée. Résultat : **aucun site du serveur n'est compressé**, pas seulement Grafana.

Sur une connexion lente ou mobile, 9 Mo de JavaScript non compressé dépassent les délais du
navigateur, et Grafana affiche ce message. La cause côté navigateur n'a pas pu être
reproduite depuis le serveur : c'est une hypothèse **fortement corroborée** (taille et absence de
compression mesurées), pas une certitude.

## Pourquoi rien ne l'a arrêté

- Aucun test ne vérifiait que les fichiers d'une application publiée partent compressés.
- Le test d'observabilité vérifie les journaux, les métriques, les traces et le provisionnement,
  jamais l'expérience d'un navigateur.
- L'audit (`vps-audit.sh`) ne regarde pas la configuration de compression de `nginx-proxy`.

## Correction

| Quoi | Où |
| --- | --- |
| Grafana compresse lui-même ses fichiers : `GF_SERVER_ENABLE_GZIP: "true"` | `observability/compose.yaml` |
| Test qui reproduit le défaut puis prouve la correction : la page de connexion référence un fichier, et ce fichier demandé avec `Accept-Encoding: gzip` commence par l'en-tête gzip `1f8b` | `tests/test-observability.sh` |

## Protection pour tous les projets

Cette correction ne protège que Grafana. **Le défaut de fond reste** : `nginx-proxy` ne compresse
rien. Un projet qui publie de gros fichiers statiques (frontend React, Angular, Next.js) souffre
de la même lenteur. Décision à prendre **séparément** :

| Option | Effet | Risque |
| --- | --- | --- |
| Ajouter `gzip on;` (avec `gzip_comp_level` modéré et `gzip_min_length`) dans la configuration de `nginx-proxy` | Tous les sites compressés | Moyen : le rechargement est sans coupure, mais une erreur de configuration invalide tout le serveur. À tester sur une copie avec `nginx -t` avant |
| Laisser chaque application compresser | Aucun changement du proxy | Chaque projet doit le faire ; oubli probable |

Pas de nouvelle clause du contrat à ce stade : la compression est une performance, pas une
règle de sécurité ni d'exploitation. Si l'option du proxy est retenue, ajouter un constat
dans `vps-audit.sh` (« compression désactivée dans nginx-proxy ») et un test dans `tests/test-hosts.sh`.

## Reste à faire

| Quoi | Qui |
| --- | --- |
| Mettre la correction sur le serveur : fusion sur `main`, `git pull` dans `/app/vps-platform`, `docker compose … up -d` (ne recrée que Grafana) | responsable de la plateforme |
| Décider et tester `gzip on` dans `nginx-proxy` | responsable de la plateforme |
| Mesurer : taille reçue de `public/build/9414.*.js` avant (3 515 562 octets) et après | responsable de la plateforme |
