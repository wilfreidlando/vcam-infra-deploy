# 20. Migrer une application déjà en service vers la plateforme (la bascule)

Faire passer une application **utilisée en continu** d'une ancienne installation vers un projet de la plateforme, **sans perdre une donnée** et en pouvant revenir en arrière. La méthode a été
appliquée pour de vrai : une base de 100 tables, 4 700 lignes et plusieurs centaines de fichiers, environ **15 minutes de coupure**, copie prouvée identique avant l'ouverture.
Elle complète le [guide 16](16-mettre-un-projet-au-standard.md) (mettre un projet au standard) pour le cas où l'application **remplace** une installation existante, avec le même nom de domaine.

| Risque pour les sites | Coupure | Durée |
| --- | --- | --- |
| L'application migrée est **coupée** ; les autres ne sont pas touchés (le proxy se recharge : quelques minutes de lenteur possibles) | **10 à 15 minutes** (mesuré : 15) | 1 h de préparation, puis la fenêtre |

**Le principe.** L'application est utilisée jusqu'à la dernière minute : on **fige** son état, on en prend une copie **exacte**, on **prouve** que la copie est identique par des empreintes, et seulement alors on **ouvre** la nouvelle installation. **L'ancienne n'est jamais modifiée ni supprimée** : c'est le retour arrière.

## 1. Avant de commencer (sans coupure)

| À faire | Comment | Pourquoi |
| --- | --- | --- |
| Décider **ce qui change pour les utilisateurs** | typiquement : reconnexion obligatoire (les sessions étaient dans l'ancien cache, qu'on ne reprend pas) ; un service nouveau (temps réel…) | l'annoncer **avant** |
| La **nouvelle** installation prête et déployée en staging | [guide 16](16-mettre-un-projet-au-standard.md) ; la même version que celle qui partira en production | une nouveauté qui n'a jamais tourné ne se découvre pas pendant la fenêtre |
| Le fichier d'environnement de la production, avec **la même clé d'application** que l'ancienne | `scripts/make-env.py … --copy-from <ancien .env>` ([modèle](../templates/scripts/README.md)) : la clé, le courrier et les clés de fournisseurs sont repris, **jamais** les accès à la base ni au cache ; tout secret est neuf | sans la même clé, les données chiffrées deviennent illisibles |
| Le contrôle préalable, **et la collision de nom connue d'avance** | `vps-deploy check <env>` | il signale aussi `COLLISION … (ancien-nginx, running)` tant que l'ancienne installation sert le nom : **attendu avant B5**, et c'est ce qui fera **refuser** le déploiement tant que l'ancien conteneur web existe. (Avant le 2026-10-07, `check` répondait « OK » et la collision n'était vue qu'au déploiement.) `vps-hosts --check <nom> --project <projet>-<env>` donne la même réponse : `NOM LIBRE` après B5 |
| **Répéter l'import** sur le staging avec une copie fraîche | dump de la source → `import` dans staging | la durée réelle, et la preuve que l'import passe, **avant** la coupure (non faite lors de la première bascule : ça a marché, mais un échec aurait rallongé la coupure) |
| La sauvegarde **après** la bascule | décider qui prend le dump quotidien et où il est copié **hors du serveur**, tant qu'aucun bucket S3 n'existe | une production sans sauvegarde automatique n'a que cela |
| Organisation | créneau de faible usage, utilisateurs prévenus, **root disponible**, **deux terminaux** ouverts | — |

> **Coller les commandes une par une** (ou les mettre dans un script). Des blocs collés d'un coup se sont mélangés dans le terminal à deux reprises : sortie incomplète, impossible de savoir si une étape avait fini.

## 2. La fenêtre (l'application est coupée de B1 à B8)

Variables, à poser dans chaque terminal : `OLD=<dossier de l'ancienne installation>`, `NEW=<dossier du clone de production>`, `OLD_FILES=<volume des fichiers de l'ancienne>`, `NEW_FILES=<volume des fichiers de la nouvelle>`.
Un dossier de sécurité, **conservé** après la bascule : `K=~/bascule-<date>; mkdir -m 700 $K`.

**B1. Couper le public, vider les files, figer.**
```bash
docker stop <ancien-web>                 # plus aucune nouvelle requête
sleep 60                                 # laisse finir les envois en cours
# les files d'attente doivent afficher « 0 en attente, 0 en cours » : sinon attendre 30 s et recommencer ; ne jamais figer avec des travaux en attente
docker stop <ancien-worker> <ancien-planificateur> <ancien-temps-réel> <ancienne-application>      # plus aucune écriture possible
```
**B2. La sauvegarde EXACTE de l'état figé** (la base tourne encore, personne n'écrit plus) : le dump de la base (**une transaction cohérente**, `--single-transaction` pour MariaDB/MySQL, `pg_dump` pour PostgreSQL), l'archive des fichiers (volume monté en lecture seule), le cache pour mémoire.

**B3. Les empreintes de la SOURCE** (c'est ce qui permet de **prouver** l'identité) :
```bash
vps-fingerprint db <conteneur-base-source> <base>     > $K/source.db.txt        # par table : lignes + somme de contrôle du contenu
vps-fingerprint files <volume-fichiers-source>        > $K/source.files.txt     # par fichier : sha256
sha256sum $K/* > $K/EMPREINTES.sha256
```
**B4. Point de contrôle : la sauvegarde est-elle exploitable ? Le GO se décide sur des NOMBRES, pas sur une impression :**
- le dump est lisible (`gzip -t`) et **complet** (sa dernière ligne dit « Dump completed » pour MariaDB/MySQL) ;
- **le même nombre de tables** dans le dump et dans les empreintes ; **le même nombre de fichiers** dans l'archive et dans les empreintes ;
- aucun fichier vide, `sha256sum -c EMPREINTES.sha256` sans échec.
Un seul critère manqué : **retour arrière immédiat** (§ 3). L'ancienne installation est intacte.

**B5. Libérer le nom et arrêter l'ancienne base** (les **volumes ne sont PAS touchés**) : arrêter la base et le cache de l'ancienne ; **supprimer seulement son conteneur web** (arrêté), pour que la plateforme n'y voie plus de collision (`vps-hosts --check` répond alors `NOM LIBRE`). Il se recrée au retour arrière.

**B6. Démarrer la nouvelle production** (même image que le staging, rien n'est reconstruit : base neuve, migrations, bascule, santé) : `vps-deploy promote --env <env> -y`, puis `ops.sh <env> status` : tous les conteneurs `healthy`. En cas d'échec : **ne pas insister**, retour arrière.

**B7. Importer la base et copier les fichiers, puis PROUVER l'identité** :
```bash
# la base : remplace la base neuve par l'état exact de l'ancienne (outil d'import du projet)
docker run --rm -v $OLD_FILES:/from:ro -v $NEW_FILES:/to busybox sh -c 'cp -a /from/. /to/'      # fichiers, propriétaires et droits conservés
vps-fingerprint db <conteneur-base-nouvelle> <base>   > $K/copie.db.txt
vps-fingerprint files $NEW_FILES                      > $K/copie.files.txt
diff $K/source.db.txt $K/copie.db.txt       && echo "BASE : IDENTIQUE"
diff $K/source.files.txt $K/copie.files.txt && echo "FICHIERS : IDENTIQUES"
```
**Point de contrôle bloquant** : les deux phrases, **aucune** ligne de `diff`. Une seule différence : ne pas ouvrir le site, retour arrière.

**B8. Ouvrir et contrôler.** Les pages publiques, un certificat valide, les erreurs applicatives, le temps réel s'il existe, la santé de chaque conteneur, les files. **Puis la recette par un vrai utilisateur** : connexion, une liste, un document téléversé avant la bascule (prouve que les fichiers sont servis), un paiement. N'annoncer la fin de la fenêtre qu'**après**.

> **Le point de non-retour pratique** : dès qu'un utilisateur **écrit** dans la nouvelle installation, l'ancienne base n'a plus ces données ; un retour arrière devient « tardif » (§ 3).

## 3. Retour arrière

| Quand | Que faire |
| --- | --- |
| **Avant le démarrage de la nouvelle** (B1 à B5) | redémarrer la base, le cache et l'application de l'ancienne, recréer son conteneur web (`docker compose up -d <web>` depuis son dossier) ; une minute |
| **Après le démarrage, avant l'ouverture et toute écriture** (B6 à B8) | arrêter la nouvelle (`ops.sh <env> stop --yes`), puis la ligne précédente. Aucune donnée perdue : l'ancienne base n'a rien reçu |
| **Après des écritures dans la nouvelle** (retour « tardif ») | à décider **avec** le responsable : les écritures faites dans la nouvelle doivent être **reportées** dans l'ancienne (dump de la nouvelle, import dans l'ancienne après un dump de sécurité de celle-ci, copie des fichiers ajoutés). À éviter |

## 4. Après la bascule

- **Copier le dossier `$K` hors du serveur** (dump exact, fichiers, empreintes) : c'est la seule copie de l'état d'avant. **Prendre un dump quotidien** tant qu'il n'y a pas de sauvegarde automatique.
- Rattacher la sonde de disponibilité au bon projet (`sites.yml`, en root) ; vérifier le tableau du projet dans Grafana.
- **Ne plus rien faire dans l'ancienne installation** : ni `git pull`, ni déploiement. Elle reste **arrêtée et intacte 1 à 2 semaines**.
- La supprimer (conteneurs, puis **volumes seulement sur décision écrite du responsable**, après une dernière sauvegarde) clôt la bascule.

## 5. Ce que la première bascule a appris

| Observation | À retenir |
| --- | --- |
| `vps-deploy check` répondait OK alors que le nom d'hôte était encore pris | la collision n'était contrôlée qu'au déploiement ; **corrigé** : `check` la voit désormais (retour d'expérience du 2026-10-07) |
| Une dizaine de minutes de **lenteur de tout le proxy** après le démarrage de huit conteneurs (le proxy et son générateur de configuration à 78 % et 55 % de CPU, charge de 15 sur 6 cœurs) ; l'application migrée échouait 3 fois sur 10 avec un délai de 12 s | attendre quelques minutes avant de juger d'une indisponibilité ; **mesurer avec un délai large** (45 s) ; cause probable : rechargements du proxy, non établie |
| La connexion SSH au serveur a été refusée un moment, sous cette charge | ne pas multiplier les connexions |
| Les 100 redémarrages du worker de l'ancienne installation, code de sortie 0 | normal (`--max-time`) : lire le code de sortie avant de s'inquiéter |
| Le dump (160 Ko) paraissait petit à côté des fichiers (47 Mo) | vérifier par les **chiffres** (tables, lignes), pas à l'œil |
| Le **premier critère de GO** est un nombre | c'est ce qui a permis de décider sans hésiter |

Le retour d'expérience correspondant : [première bascule, ce qui n'a pas été prévu](../docs/retours-experience/2026-10-07-premiere-bascule-ce-qui-na-pas-ete-prevu.md).
