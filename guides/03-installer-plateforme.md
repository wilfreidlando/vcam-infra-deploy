# 3. Installer la plateforme sur le serveur

Ce guide installe :
- **l'outillage** : `deploy.sh`, `vps-audit.sh`, `vps-hosts.sh`, `restore.sh` ;
- **l'observabilité mutualisée** : Grafana, Loki, Tempo, Prometheus et Alloy.

Il ne modifie ni nginx-proxy, ni les projets existants.

## Étape 1 — Cloner la plateforme

```bash
$ git clone https://github.com/wilfreidlando/vcam-infra-deployment.git /app/vps-platform
```

Tous les chemins de la documentation partent de là : `/app/vps-platform/bin/deploy.sh`,
`/app/vps-platform/observability/`… Mettre à jour plus tard : guide 11.

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
| `GRAFANA_HOST` | `grafana.visibilitycam.com` (vérifier d'abord : `../bin/vps-hosts.sh --free grafana.visibilitycam.com`) |
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
3. *Dashboards* doit montrer deux dossiers : **Applications** et **Core System**.
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
$ docker compose --env-file .env down -v     # + suppression des données
```
