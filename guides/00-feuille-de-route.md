# 0. Feuille de route : de l'état actuel au serveur standard

L'ordre complet, du début à la fin, pour mettre à jour le serveur, puis le Core,
puis l'application WILMANAGER (centres de formation). Chaque ligne renvoie au guide
détaillé. On peut s'arrêter entre deux phases : rien ne reste à moitié fait.

Le référentiel est le [contrat d'un projet](../docs/05-contrat-projet.md) : chaque
phase ci-dessous rapproche le serveur de ce contrat.

| Phase | Quoi | Coupure des sites | Durée |
| --- | --- | --- | --- |
| 0 | **Inventaire du serveur**, en lecture seule : l'état de départ, écrit dans le dépôt | aucune | 1 h |
| A | Vérifier sur un poste (facultatif, recommandé) | aucune | 1 h |
| B | Préparer le serveur | aucune | 1 h 30 |
| C | Passer le Core au standard | quelques secondes pour le Core | 1 h |
| D | Passer WILMANAGER au standard | 1 à 3 min pour la prod de WILMANAGER, au moment choisi | 2 h |
| E | Finitions | aucune | 30 min |

## 0. Inventaire du serveur (avant tout changement)

On ne corrige bien que ce que l'on a mesuré. L'inventaire décrit le serveur tel
qu'il est : projets, dossiers, versions déployées, réseaux partagés et noms publiés,
crons, audit, sous-domaines. **Il n'affiche aucun secret et ne modifie rien.**

| # | Action | Guide |
| --- | --- | --- |
| 0.1 | Sur le serveur : `cd /app/vps-platform && git pull` (si la plateforme est déjà installée ; sinon guide 3 d'abord) | [11](11-depot-plateforme.md) |
| 0.2 | Inventaire : `/app/vps-platform/bin/vps-inventory.sh > /root/inventaire-$(date +%F).md`, à la main, **ou** assisté par Claude Code avec garde-fous | [13](13-intervention-assistee.md) |
| 0.3 | Ranger l'inventaire dans `docs/inventaire/` (pull request), avec le plan de mise en conformité, un responsable par écart | [inventaires](../docs/inventaire/README.md) |

À refaire à la fin de chaque phase, et une fois par trimestre : la comparaison avec
le précédent montre ce qui a dérivé.

## A. Vérifier sur un poste (facultatif : sauter si vous appliquez directement sur le serveur)

```bash
git clone https://github.com/wilfreidlando/vcam-infra-deploy.git vps-platform
git clone -b claude/zen-gates-lewzx5 https://github.com/wilfreidlando/vcam-core-system.git core
git clone -b vps-standard <dépôt de WILMANAGER> app

cd vps-platform && CORE_DIR=../core tests/run-all.sh       # ≈ 200 vérifications de la plateforme (Core déployé compris)
cd ../app && tests/Infra/stack-test.sh                    # 28 vérifications : la pile de production de l'app
PLATFORM_DIR=../vps-platform tests/Infra/deploy-test.sh   # 44 vérifications : dev/staging/prod, migration de la base, restauration
```

Tout doit finir en vert. Un échec dit précisément ce qui ne va pas. Si c'est un
« 429 Too Many Requests » de Docker Hub, relancer un peu plus tard.

## B. Serveur (une fois)

| # | Action | Guide |
| --- | --- | --- |
| B1 | Inventorier les sous-domaines existants | [1](01-inventaire-sous-domaines.md) |
| B2 | DNS wildcard `*.visibilitycam.com` | [2](02-dns-wildcard.md) |
| B2 bis | Sous-domaines **créés à la volée par les apps** (certificat wildcard) : passer le DNS de `visibilitycam.com` chez Cloudflare. Le domaine reste chez LWS ; recopier tous les `MX`/`TXT` (e-mails) | [2, annexe](02-dns-wildcard.md#annexe--déplacer-le-dns-de-visibilitycamcom-chez-cloudflare-plus-tard-si-besoin) |
| B3 | Cloner ce dépôt dans `/app/vps-platform` et installer l'observabilité | [3](03-installer-plateforme.md) |
| B4 | Sauvegardes vers MEGA S4 | [4](04-sauvegardes-mega-s4.md) |
| B5 | Rotation des journaux Docker (en heure creuse) | [9](09-rotation-journaux-hote.md) |
| B6 | Surveillance externe | [8](08-surveillance-externe.md) |
| B7 | **Préparer la reprise après sinistre** (partie « à faire avant ») | [12](12-reprise-apres-sinistre.md) |

## C. Core

| # | Action | Guide |
| --- | --- | --- |
| C1 | Fusionner la PR du Core (`claude/zen-gates-lewzx5` → `main`). Le Core n'embarque plus la plateforme : ses commandes `make` utilisent `/app/vps-platform` | — |
| C2 | Staging + production au standard | [6](06-core-au-standard.md) |
| C3 | Staging automatique (cron, ou GitLab plus tard) | [7](07-staging-automatique.md) |

## D. WILMANAGER (dépôt de l'app, branche `vps-standard`)

Tout est dans **`docs/MIGRATION-VPS.md` du dépôt de l'app**, dans cet ordre :

| # | Étape de la migration | Coupure |
| --- | --- | --- |
| D1 | 1-2 : relever l'existant, sauvegardes de sécurité | aucune |
| D2 | 3-4 : `/app/cpf/{dev,staging,prod}` et leurs `.env` (garder `APP_KEY` et les accès base de la prod) | aucune |
| D3 | 5 : staging (nouveau nom `cpf-staging`, tester avec une copie des données) | aucune |
| D4 | 6 : dev (arrêter l'ancien dev d'abord) | dev, quelques minutes |
| D5 | 7 : prod, **au moment d'une livraison prévue de `develop`** | prod, 1 à 3 min |
| D6 | 8 : fusionner `vps-standard`, brancher le pipeline GitLab, un seul propriétaire des dossiers | aucune |
| D7 | 9 : nettoyage, après une à deux semaines | aucune |

Filets de sécurité déjà en place : `deploy.sh` refuse si un nom d'hôte est pris, si
nginx-proxy est en erreur ou si l'ancienne base tourne encore sur le volume. Il
prend une sauvegarde avant la migration et revient seul en arrière si la nouvelle
version ne répond pas. Chaque étape a son retour arrière décrit dans le guide.

## E. Finitions

| # | Action |
| --- | --- |
| E0 | Chaque projet : `deploy.sh check prod` dans son dossier, puis mise en conformité selon le [contrat, § 4](../docs/05-contrat-projet.md#4-appliquer-le-contrat-à-un-projet-déjà-en-production) |
| E1 | `/app/vps-platform/bin/vps-audit.sh` : traiter les CRITIQUE des autres projets ([5](05-audit-et-conformite.md)) |
| E2 | Planifier la montée de WILMANAGER en Laravel 12 et la mise à jour des paquets vulnérables (README de l'app, « Points connus ») |
| E3 | Les autres apps (React, Next.js, Angular, Laravel) : [démarrage rapide](../docs/04-demarrage-rapide-dev.md), au fil de l'eau |
| E4 | Nouvel inventaire (phase 0), comparé au premier : il ne doit plus rester d'écart sans responsable |

## Qui fait quoi, une fois la plateforme en place

| Rôle | Fait | Ne fait pas |
| --- | --- | --- |
| **Développeur** | merge sur `main` → staging automatique en 2 minutes ; vérifie son staging ; demande la mise en production | ne se connecte pas au serveur pour déployer ; ne modifie rien à la main sur le serveur |
| **Responsable d'un projet** | tient son projet conforme au [contrat](../docs/05-contrat-projet.md) (`deploy.sh check`) ; décide et lance `deploy.sh promote` ; tient les `.env` du serveur | ne touche pas aux autres projets ni à la plateforme |
| **Responsable de la plateforme** | relit et merge les PR de `vcam-infra-deploy` (CI verte obligatoire) ; met à jour `/app/vps-platform` ; audit et inventaire réguliers ; tient les retours d'expérience | ne déploie pas les projets à la place de leurs responsables |
| **Tous** | un incident ou une surprise = un [retour d'expérience](../docs/retours-experience/README.md) ; il n'est clos que lorsqu'un contrôle automatique empêche que cela se reproduise | ne contournent pas un refus de `deploy.sh` : il dit quoi corriger |

**Rendez-vous réguliers :**

| Quand | Quoi | Qui |
| --- | --- | --- |
| Chaque jour (automatique) | Surveillance externe, alertes Grafana, sauvegardes | — |
| Chaque semaine | `vps-audit.sh` : aucune ligne CRITIQUE | plateforme |
| Chaque mois | Restaurer une sauvegarde de production dans un staging ([sauvegardes](../docs/reference/sauvegardes.md)) | chaque projet |
| Chaque trimestre | Inventaire (phase 0) comparé au précédent ; relecture du contrat | plateforme |
