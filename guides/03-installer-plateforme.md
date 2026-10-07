# 3. Installer la plateforme sur le serveur

Ce guide installe :
- **l'outillage** : `deploy.sh`, `vps-audit.sh`, `vps-hosts.sh`, `restore.sh` ;
- **l'observabilité mutualisée** : Grafana, Loki, Tempo, Prometheus et Alloy.

Il ne modifie ni nginx-proxy, ni les projets existants.

## Étape 0 — Donner au serveur l'accès aux dépôts GitHub privés

`vcam-infra-deploy` et `vcam-core-system` sont privés : sans clé, `git clone` échoue
sur le serveur. On crée une **clé de déploiement en lecture seule par dépôt** (GitHub
refuse d'utiliser la même clé sur deux dépôts). À faire en root, une seule fois.

**0.1 Créer les deux clés**

```bash
$ ssh-keygen -t ed25519 -N "" -C "vps-contabo vcam-infra-deploy" -f /root/.ssh/deploy_vcam_infra
$ ssh-keygen -t ed25519 -N "" -C "vps-contabo vcam-core-system"  -f /root/.ssh/deploy_vcam_core
```

**0.2 Dire à SSH quelle clé utiliser pour quel dépôt**

Ouvrir le fichier de configuration SSH de root :

```bash
$ nano /root/.ssh/config
```

Ajouter à la fin ces lignes, telles quelles, puis enregistrer (Ctrl+O, Entrée,
Ctrl+X) :

```
Host github-vcam-infra
  HostName github.com
  User git
  IdentityFile /root/.ssh/deploy_vcam_infra
  IdentitiesOnly yes

Host github-vcam-core
  HostName github.com
  User git
  IdentityFile /root/.ssh/deploy_vcam_core
  IdentitiesOnly yes
```

```bash
$ chmod 600 /root/.ssh/config
```

**0.3 Déclarer chaque clé sur GitHub**

```bash
$ cat /root/.ssh/deploy_vcam_infra.pub      # copier toute la ligne (ssh-ed25519 AAAA… vps-contabo vcam-infra-deploy)
```

Sur https://github.com/wilfreidlando/vcam-infra-deploy : **Settings** (onglet en haut
du dépôt) → **Deploy keys** (menu de gauche) → **Add deploy key** :
- *Title* : `VPS Contabo` ;
- *Key* : coller la ligne ;
- **ne pas** cocher *Allow write access* ;
- **Add key**.

Même chose pour le Core : `cat /root/.ssh/deploy_vcam_core.pub`, à coller dans
https://github.com/wilfreidlando/vcam-core-system → *Settings* → *Deploy keys*.

**0.4 Vérifier**

```bash
$ ssh -T git@github-vcam-infra
Are you sure you want to continue connecting (yes/no)?    # ← 1re fois seulement : taper yes
Hi wilfreidlando/vcam-infra-deploy! You've successfully authenticated, but GitHub does not provide shell access.
$ ssh -T git@github-vcam-core
Hi wilfreidlando/vcam-core-system! You've successfully authenticated, …
```

Le message « does not provide shell access » est **normal** : c'est la réussite.
`Permission denied (publickey)` signifie que la clé n'est pas (ou mal) collée dans
*Deploy keys* du bon dépôt.

## Étape 1 — Cloner la plateforme

```bash
$ git clone git@github-vcam-infra:wilfreidlando/vcam-infra-deploy.git /app/vps-platform
$ ls /app/vps-platform        # → bin  docs  guides  host  images  observability  templates  tests  README.md
```

La documentation écrit les commandes sous leur forme courte (`vps-deploy`, `vps-audit`…, installées ci-dessous) ; sans elles,
`vps-deploy` se lit `/app/vps-platform/bin/deploy.sh`. Les dossiers partent de là : `/app/vps-platform/observability/`… Mettre à jour plus tard : guide 11.

**Installer les commandes courtes (recommandé, une fois, en root).** Pour ne plus jamais taper ni rater un chemin :

```bash
$ /app/vps-platform/host/install-commands.sh        # écrit 9 commandes dans /usr/local/bin : vps, vps-deploy, vps-restore, vps-audit,
                                                    #   vps-inventory, vps-hosts, vps-obs-bundle, vps-fingerprint, vps-daemon-config
$ vps                                               # l'aide : comment on déploie sur cette plateforme, et la liste des commandes
$ vps where                                         # où est la plateforme, quelle version : fonctionne depuis n'importe quel dossier
plateforme : /app/vps-platform
version    : 9c656e3 (2026-10-05)
```

Ensuite `vps-deploy check prod` (ou `vps deploy check prod`) remplace `/app/vps-platform/bin/deploy.sh check prod`, partout dans la documentation. Si la plateforme est introuvable, la commande le **dit** (code 127, avec le dossier cherché et comment corriger) au lieu d'un
« No such file or directory ». Si la plateforme change de dossier : relancer l'installateur depuis le nouveau dossier, ou `VPS_PLATFORM_DIR=<dossier> vps-deploy …` en attendant. `install-commands.sh --check` montre l'état,
`--uninstall` ne retire que ses propres commandes, et il n'écrase jamais un fichier qui n'est pas à lui.

Vérifier les prérequis :

```bash
$ docker compose version          # v2 requis
$ docker network ls | grep nginx-proxy
$ apt install -y jq curl git      # jq : seulement pour le guide 9
```

## Étape 2 — Réseau partagé de l'observabilité

```bash
$ docker network create observability
```

Sans effet sur les autres projets : c'est un réseau vide de plus.

## Étape 3 — Configuration

```bash
$ cd /app/vps-platform/observability
$ cp .env.example .env
$ nano .env
```

| Variable | Valeur |
| --- | --- |
| `GRAFANA_HOST` | `grafana.visibilitycam.com` (vérifier d'abord : `vps-hosts --free grafana.visibilitycam.com`) |
| `LETSENCRYPT_EMAIL` | une adresse qui reçoit les alertes d'expiration |
| `GRAFANA_ADMIN_PASSWORD` | `openssl rand -base64 24` — à ranger dans votre gestionnaire de mots de passe |
| `GRAFANA_ALERT_EMAIL` | l'adresse qui reçoit les alertes du Core |
| `GF_SMTP_*` | un compte SMTP pour l'envoi des alertes (sans lui, pas d'e-mail ; Grafana fonctionne quand même) |
| `LOKI_MEMORY_LIMIT` | `1G` par défaut ; `512M` si le serveur a moins de 8 Go de RAM |

## Étape 4 — Démarrer

```bash
$ docker compose -f /app/vps-platform/observability/compose.yaml \
    --env-file /app/vps-platform/observability/.env up -d
$ docker ps --filter name=observability- --format 'table {{.Names}}\t{{.Status}}'
```

Les 5 conteneurs doivent être `Up`.

## Étape 5 — Vérifier

1. Ouvrir `https://grafana.visibilitycam.com`. Le certificat arrive en une ou deux
   minutes ; en attendant, le navigateur peut afficher une alerte de sécurité.
2. Se connecter avec `admin` et `GRAFANA_ADMIN_PASSWORD`.
3. *Dashboards* doit montrer deux dossiers : **Plateforme** et **Applications** (plus un dossier par projet qui a publié ses propres tableaux).
4. Le tableau *Applications — journaux* est vide tant qu'aucun projet n'est
   branché : c'est normal (guide 5 et `observability/README.md`).

## Consommation

Avec ses limites : environ 2,5 Go de RAM au maximum, en pratique 1 à 1,5 Go. Le
disque grandit avec la rétention : 90 jours de journaux, 30 jours de traces et de
métriques. Suivre avec `docker system df -v | grep observability`.

## Arrêter ou désinstaller

```bash
$ cd /app/vps-platform/observability
$ docker compose --env-file .env down        # arrêt (données gardées)
$ docker compose --env-file .env down -v     # DÉSINSTALLATION seulement : supprime journaux, métriques, traces et tableaux ajoutés à la main (jamais sur un projet)
```
