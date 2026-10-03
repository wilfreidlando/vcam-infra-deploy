# 0. Feuille de route : de l'état actuel au serveur standard

L'ordre complet, du début à la fin, pour mettre à jour le serveur, puis le Core,
puis l'application WILMANAGER (centres de formation). Chaque ligne renvoie au guide
détaillé. On peut s'arrêter entre deux phases : rien ne reste à moitié fait.

| Phase | Quoi | Coupure des sites | Durée |
| --- | --- | --- | --- |
| A | Vérifier sur un poste (facultatif, recommandé) | aucune | 1 h |
| B | Préparer le serveur | aucune | 1 h 30 |
| C | Passer le Core au standard | quelques secondes pour le Core | 1 h |
| D | Passer WILMANAGER au standard | 1 à 3 min pour la prod de WILMANAGER, au moment choisi | 2 h |
| E | Finitions | aucune | 30 min |

## A. Vérifier sur un poste (Docker, ou WSL2 sous Windows)

```bash
git clone -b claude/zen-gates-lewzx5 <dépôt core-system> core && cd core
infra/tests/run-all.sh                 # ≈ 129 vérifications de la plateforme

git clone -b vps-standard <dépôt app> app && cd app
tests/Infra/stack-test.sh              # 28 vérifications : la pile de production de l'app
PLATFORM_DIR=../core tests/Infra/deploy-test.sh   # 40 vérifications : dev/staging/prod, migration de la base
```

Tout doit finir en vert. Un échec dit précisément ce qui ne va pas. Si c'est un
« 429 Too Many Requests » de Docker Hub, relancer un peu plus tard.

## B. Serveur (une fois)

| # | Action | Guide |
| --- | --- | --- |
| B1 | Inventorier les sous-domaines existants | [1](01-inventaire-sous-domaines.md) |
| B2 | DNS wildcard `*.visibilitycam.com` | [2](02-dns-wildcard.md) |
| B3 | Installer la plateforme dans `/app/vps-platform` + l'observabilité | [3](03-installer-plateforme.md) |
| B4 | Sauvegardes vers MEGA S4 | [4](04-sauvegardes-mega-s4.md) |
| B5 | Rotation des journaux Docker (en heure creuse) | [9](09-rotation-journaux-hote.md) |
| B6 | Surveillance externe | [8](08-surveillance-externe.md) |
| B7 | **Préparer la reprise après sinistre** (partie « à faire avant ») | [12](12-reprise-apres-sinistre.md) |

## C. Core

| # | Action | Guide |
| --- | --- | --- |
| C1 | Fusionner la PR du Core (`claude/zen-gates-lewzx5` → `main`) | — |
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
| E1 | `/app/vps-platform/infra/bin/vps-audit.sh` : traiter les CRITIQUE des autres projets ([5](05-audit-et-conformite.md)) |
| E2 | Planifier la montée de WILMANAGER en Laravel 12 et la mise à jour des paquets vulnérables (README de l'app, « Points connus ») |
| E3 | Les autres apps (React, Next.js, Angular, Laravel) : [démarrage rapide](../docs/04-demarrage-rapide-dev.md), au fil de l'eau |
