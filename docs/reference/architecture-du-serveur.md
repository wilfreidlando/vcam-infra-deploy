# Architecture du serveur

> Vue d'ensemble du VPS : les projets, `nginx-proxy`, les réseaux Docker et qui peut parler à qui.
> Retour au [sommaire de la documentation](../README.md).


```mermaid
graph TB
    Internet((Internet)) -->|"*.visibilitycam.com<br/>(DNS wildcard)"| NP

    subgraph VPS["VPS — un seul serveur"]
        NP["nginx-proxy + acme-companion<br/>(existant, inchangé)<br/>:80 / :443 — seuls ports publics"]

        subgraph CoreProd["core-system-prod"]
            CPW["webserver"] --> CPA["app"]
            CPA --> CPDB[("postgres")]
            CPA --> CPR[("valkey")]
            CPH["horizon / scheduler"]
            CPB["backup"]
        end
        subgraph CoreStg["core-system-staging (copie isolée)"]
            CSW["webserver"] --> CSA["app"]
            CSA --> CSDB[("postgres")]
        end
        subgraph Saas["autre-saas-prod / -staging"]
            SA["app"] --> SDB[("db")]
        end
        subgraph Front["front-prod / -staging"]
            FA["nginx (SPA) ou node (Next.js)"]
        end
        subgraph OBS["observability (mutualisé)"]
            Alloy["alloy"] --> Loki[("loki")] & Tempo[("tempo")] & Prom[("prometheus")]
            Graf["grafana"]
        end

        NP --> CPW & CSW & SA & FA & Graf
        CPA & CSA & SA -. "logs, métriques, traces<br/>(réseau observability)" .-> Alloy
    end

    CPB & SDB -. "sauvegardes chiffrées<br/>chaque nuit" .-> S3[("MEGA S4<br/>(hors serveur)")]
    Uptime["Surveillance externe<br/>(UptimeRobot…)"] -. "/health toutes les minutes" .-> NP
```

## Réseaux Docker : qui peut parler à qui

```mermaid
graph LR
    subgraph shared["Réseaux partagés (externes)"]
        NPN["nginx-proxy<br/>uniquement le conteneur web de chaque projet"]
        OBN["observability<br/>uniquement les conteneurs applicatifs observés"]
    end
    subgraph internal["Réseau privé par projet et par environnement"]
        I1["<projet>-<env>-internal<br/>app, workers, base, cache"]
    end
    NPN --- I1
    OBN --- I1
```

- **Une base ou un cache ne quitte jamais le réseau privé de son projet.** Sur
  `nginx-proxy`, n'importe quel conteneur de n'importe quel projet pourrait s'y
  connecter.
- **Aucun projet ne publie de port** (`ports:`), sauf nginx-proxy (80/443). Docker
  écrit ses règles réseau **avant** le pare-feu ufw : un `ports: "5432:5432"` rend la
  base accessible depuis Internet même si ufw dit le contraire.
- **Les services d'un projet portent des noms uniques** (`mon-saas-web`,
  `mon-saas-db`, `mon-saas-redis`), jamais `app`, `db` ou `redis`. Le conteneur
  web est branché sur `nginx-proxy` et y voit les noms de **tous** les projets :
  si un autre y a laissé un `db`, Docker peut lui donner celui-là. Vécu au
  premier déploiement de skills-devops : migrations en `Connection refused`
  contre la base d'un autre projet. Les modèles de `templates/` appliquent la
  règle.
