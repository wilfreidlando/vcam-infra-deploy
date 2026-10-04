# Schémas de la plateforme

Chaque schéma montre **un seul sujet**, avec en dessous ce qu'il faut en retenir.
Les mots techniques sont expliqués dans le [glossaire](03-glossaire.md).

Sommaire :
1. [Le serveur, vu d'en haut](#1-le-serveur-vu-den-haut)
2. [Qui peut parler à qui (réseaux)](#2-qui-peut-parler-à-qui-réseaux)
3. [Le trajet d'une visite](#3-le-trajet-dune-visite)
4. [Anatomie d'un projet](#4-anatomie-dun-projet)
5. [Du commit à la production](#5-du-commit-à-la-production)
6. [Ce que fait un déploiement, pas à pas](#6-ce-que-fait-un-déploiement-pas-à-pas)
7. [Sauvegardes et restauration](#7-sauvegardes-et-restauration)
8. [Observabilité : journaux, métriques, traces](#8-observabilité--journaux-métriques-traces)
9. [Un SaaS à sous-domaines automatiques](#9-un-saas-à-sous-domaines-automatiques)
10. [Les fichiers sur le serveur](#10-les-fichiers-sur-le-serveur)
11. [Les relations entre tous les éléments](#11-les-relations-entre-tous-les-éléments)

---

## 1. Le serveur, vu d'en haut

```mermaid
flowchart TB
    User(["Visiteurs et clients"])
    Providers(["Fournisseurs<br/>MyCoolPay, WhatsApp…"])
    Uptime(["Surveillance externe"])
    DNS[("DNS<br/>*.visibilitycam.com")]

    subgraph VPS["Le VPS — un seul serveur"]
        Proxy["nginx-proxy + acme-companion<br/>porte d'entrée unique, HTTPS"]
        subgraph Projects["Projets — chacun dans sa boîte"]
            CoreP["core-system-prod"]
            CoreS["core-system-staging"]
            SaasP["autre-saas-prod"]
            Front["front-prod"]
        end
        Obs["Observabilité partagée<br/>Grafana · Loki · Tempo · Prometheus · Alloy"]
    end

    S3[("MEGA S4<br/>sauvegardes hors serveur")]

    User --> DNS --> Proxy
    Providers --> Proxy
    Uptime -. "toutes les 5 min" .-> Proxy
    Proxy --> Projects
    Proxy --> Obs
    Projects -. "journaux, métriques" .-> Obs
    Projects -. "sauvegarde chiffrée chaque nuit" .-> S3
```

**À retenir**
- **Une seule porte d'entrée** : nginx-proxy, ports 80 et 443. Aucun projet n'ouvre
  de port sur Internet.
- **Deux sortes de choses** sur le serveur : les **services partagés**, installés une
  fois pour tous, et les **projets**, chacun dans sa boîte. Un projet en
  production et son staging sont deux boîtes séparées.
- Les sauvegardes partent **hors du serveur**. La surveillance vient **de
  l'extérieur**. Si le serveur meurt, on le sait, et on ne perd pas les données.

---

## 2. Qui peut parler à qui (réseaux)

Un **réseau Docker** est un câble virtuel : seuls les conteneurs branchés dessus
peuvent se joindre.

```mermaid
flowchart LR
    subgraph NP["réseau nginx-proxy (partagé)"]
        Proxy["nginx-proxy"]
        WebA["web du projet A"]
        WebB["web du projet B"]
        Graf["grafana"]
    end

    subgraph IA["réseau privé du projet A"]
        WebA2["web du projet A"]
        AppA["app A"]
        WorkerA["workers A"]
        DBA[("base A")]
        CacheA[("cache A")]
    end

    subgraph IB["réseau privé du projet B"]
        WebB2["web du projet B"]
        AppB["app B"]
        DBB[("base B")]
    end

    subgraph OB["réseau observability (partagé)"]
        Alloy["alloy"]
        AppA2["app A"]
        AppB2["app B"]
    end

    Proxy --> WebA & WebB & Graf
    WebA2 --> AppA --> DBA & CacheA
    WorkerA --> DBA
    WebB2 --> AppB --> DBB
    Alloy --> AppA2 & AppB2
```

Un même conteneur peut être branché sur plusieurs réseaux. « web du projet A »
apparaît deux fois sur le schéma pour cette raison : il est à la fois sur
`nginx-proxy` et sur le réseau privé de son projet.

**À retenir**
- **Une base de données n'est branchée que sur le réseau privé de son projet.**
  Le projet B ne peut pas joindre la base A, même s'il est piraté.
- Sur `nginx-proxy`, seulement le conteneur **web** de chaque projet.
- Sur `observability`, seulement les conteneurs applicatifs qu'on veut observer.
  Jamais les bases.
- L'audit (`bin/vps-audit.sh`) vérifie ces règles.

---

## 3. Le trajet d'une visite

```mermaid
sequenceDiagram
    autonumber
    actor V as Visiteur
    participant D as DNS
    participant P as nginx-proxy
    participant W as web du projet<br/>(nginx ou FrankenPHP)
    participant A as app (Laravel…)
    participant B as base

    V->>D: core-system.visibilitycam.com ?
    D-->>V: IP du VPS (enregistrement wildcard)
    V->>P: HTTPS GET /v1/payments
    Note over P: certificat Let's Encrypt du nom<br/>choix du projet par VIRTUAL_HOST
    P->>W: HTTP + X-Forwarded-For / -Proto
    Note over W: (Core) ajoute X-Core-Proxy-Token<br/>= « je suis le vrai proxy »
    W->>A: requête
    A->>B: lecture / écriture
    B-->>A: résultat
    A-->>W: réponse
    W-->>P: réponse
    P-->>V: HTTPS 200
```

**À retenir**
- Le **nom** demandé (`Host`) décide du projet. D'où l'importance de ne jamais avoir
  deux projets qui déclarent le même nom (voir guide 1).
- Le HTTPS s'arrête à nginx-proxy. À l'intérieur du serveur, tout circule en HTTP sur
  des réseaux privés.
- L'app connaît la vraie IP du visiteur par `X-Forwarded-For`. Le Core n'y croit que
  si le jeton du sidecar est présent : un conteneur voisin ne peut pas se faire
  passer pour MyCoolPay.

---

## 4. Anatomie d'un projet

Ce que contient un projet au standard, ici un backend Laravel. Un frontend n'a que
le conteneur web.

```mermaid
flowchart TB
    subgraph Projet["projet « mon-saas-prod » (docker compose -p mon-saas-prod)"]
        direction TB
        Web["web<br/>VIRTUAL_HOST=mon-saas.visibilitycam.com<br/>healthcheck"]
        App["app<br/>image mon-saas:&lt;sha du commit&gt;"]
        Queue["queue / horizon"]
        Sched["scheduler"]
        DB[("db<br/>volume db-data")]
        Cache[("redis / valkey<br/>volume redis-data")]
        Backup["backup<br/>dump chiffré chaque nuit<br/>volume backups"]
    end

    Web --> App
    App --> DB & Cache
    Queue --> DB & Cache
    Sched --> DB
    Backup --> DB
    Backup -. "vers MEGA S4" .-> S3[("S3")]

    Files["Dans le dépôt :<br/>compose.prod.yaml · platform.env<br/>.env (prod) · .env.staging"] -.- Projet
```

| Élément | Rôle | Règle |
| --- | --- | --- |
| `compose.prod.yaml` | Décrit les conteneurs. **Le même fichier** pour staging et production | modèle dans `templates/` |
| `platform.env` | Dit à `deploy.sh` comment déployer : nom, contrôle de santé, migrations, sauvegarde | commité |
| `.env` / `.env.staging` | Secrets et réglages de chaque environnement | **jamais commités** ; jamais les mêmes secrets en staging et en production |
| Image `<projet>:<sha>` | Le code figé d'un commit précis | construite une fois, en staging |
| Volumes | Les données (base, cache, sauvegardes locales) | survivent aux déploiements |
| Limites mémoire, rotation des journaux, healthcheck | Empêchent un projet de gêner les autres | vérifiés par l'audit |

---

## 5. Du commit à la production

```mermaid
flowchart LR
    Dev(["Développeur"]) -->|"merge sur main"| Git[("Dépôt git")]
    Git -->|"automatique<br/>≤ 2 min"| Build["Build de l'image<br/>tag = SHA du commit"]
    Build --> Staging["STAGING<br/>projet-staging.visibilitycam.com"]
    Staging -->|"tests manuels, recette"| QA{"OK ?"}
    QA -->|"non : corriger,<br/>nouveau commit"| Dev
    QA -->|"oui : bouton manuel<br/>make prod-promote"| Prod["PRODUCTION<br/>projet.visibilitycam.com<br/>MÊME image"]
    Prod -->|"si problème"| Back["make rollback ENV=prod<br/>version précédente en 1 commande"]
```

**À retenir**
- **On ne reconstruit jamais pour la production** : elle reçoit l'image exacte
  testée en staging.
- Le staging se met à jour **tout seul**. La production, **seulement à la main**.
- Revenir en arrière est **une commande**.

---

## 6. Ce que fait un déploiement, pas à pas

```mermaid
sequenceDiagram
    autonumber
    actor Ops as Personne qui déploie<br/>(ou cron / GitLab)
    participant D as deploy.sh
    participant H as vps-hosts.sh
    participant P as nginx-proxy
    participant K as Backup
    participant C as Conteneurs du projet

    Ops->>D: promote (production)
    D->>D: verrou (un seul déploiement à la fois)
    D->>D: checkout du commit, l'image existe ?
    D->>P: configuration valide ? (nginx -t)
    D->>H: mes noms sont-ils déjà pris par un autre projet ?
    D->>D: mes volumes sont-ils utilisés par un autre conteneur ?
    alt nom pris, proxy en erreur ou volume occupé
        D-->>Ops: REFUS — rien n'a été modifié
    end
    D->>K: sauvegarde chiffrée (pre-deploy)
    alt sauvegarde en échec
        D-->>Ops: REFUS — rien n'a été modifié
    end
    D->>C: migrations avec la nouvelle image
    D->>C: bascule des conteneurs
    D->>C: contrôle de santé (jusqu'à 2 min)
    alt santé KO
        D->>C: retour automatique à la version précédente
        D->>C: contrôle de santé de la version précédente
        D-->>Ops: ÉCHEC — ancienne version en ligne (confirmé)
    else santé OK
        D-->>Ops: OK — version enregistrée
    end
```

**À retenir**
- Tout ce qui peut échouer **avant** la bascule (nom pris, proxy cassé, volume
  encore utilisé par une ancienne installation, sauvegarde ratée, migration ratée)
  laisse la production **intacte**.
- Après la bascule, si l'application ne répond pas, **retour automatique**.
- Seule limite : une migration déjà appliquée n'est pas annulée. D'où la sauvegarde
  prise juste avant.

---

## 7. Sauvegardes et restauration

```mermaid
flowchart LR
    subgraph Serveur["VPS"]
        DB[("Base du projet")]
        Agent["Conteneur backup<br/>chaque nuit à BACKUP_TIME<br/>+ avant chaque promotion"]
        Local[("7 dernières copies<br/>sur le serveur")]
    end
    Pass{{"Phrase de passe<br/>dans le gestionnaire de mots de passe"}}
    Remote[("MEGA S4<br/>30 jours de copies")]

    DB -->|"pg_dump / mariadb-dump"| Agent
    Agent -->|"chiffrement AES-256"| Local
    Agent -->|"envoi S3"| Remote
    Pass -.-> Agent

    Remote -->|"restore.sh"| Restore["Restauration<br/>app arrêtée → données remplacées → app relancée"]
    Local -->|"restore.sh"| Restore
```

**À retenir**
- MEGA ne voit **que des données chiffrées**.
- **Sans la phrase de passe, aucune restauration n'est possible.** Elle doit être
  conservée hors du serveur.
- Une sauvegarde ne compte que si l'on a déjà réussi à la restaurer : une fois par
  mois, restaurer la production dans le staging (`README.md` § 9).

---

## 8. Observabilité : journaux, métriques, traces

```mermaid
flowchart LR
    subgraph Apps["Projets observés (label observability.enable=true)"]
        A1["app Laravel<br/>journaux JSON sur stdout<br/>/metrics<br/>traces OTLP"]
        A2["autre backend"]
        X["projet SANS label"]
    end
    subgraph OBS["observability (partagé)"]
        Alloy["Alloy<br/>découvre les conteneurs par label"]
        Loki[("Loki<br/>journaux 90 j")]
        Prom[("Prometheus<br/>métriques 30 j")]
        Tempo[("Tempo<br/>traces 30 j")]
        Graf["Grafana<br/>grafana.visibilitycam.com"]
    end
    Team(["Équipe"])

    A1 & A2 -->|"stdout"| Alloy
    Alloy -->|"lit /metrics"| A1
    A1 -->|"OTLP :4318"| Alloy
    X -. "ignoré" .-x Alloy
    Alloy --> Loki & Prom & Tempo
    Graf --> Loki & Prom & Tempo
    Team --> Graf
    Graf -->|"alertes e-mail<br/>(production du Core)"| Team
```

**À retenir**
- **Rien n'est collecté sans le label** `observability.enable=true`.
- Le minimum pour un projet Laravel : des journaux JSON sur la sortie standard,
  plus deux labels. Les métriques et les traces sont un bonus.
- Les frontends n'en ont pas besoin.

---

## 9. Un SaaS à sous-domaines automatiques

```mermaid
sequenceDiagram
    autonumber
    actor C as Nouveau client
    participant S as App SaaS
    participant B as Base du SaaS
    participant D as DNS (Cloudflare)
    participant A as acme-companion
    participant P as nginx-proxy

    Note over D,A: Une seule fois, au premier déploiement
    A->>D: crée l'enregistrement TXT _acme-challenge (API)
    A->>A: Let's Encrypt délivre *.monsaas.com
    A->>P: certificat monsaas.com.crt (couvre tous les sous-domaines)

    Note over C,B: À chaque nouveau client — rien à faire sur le serveur
    C->>S: inscription « client42 »
    S->>B: INSERT tenant client42
    C->>P: https://client42.monsaas.com
    Note over P: *.monsaas.com → conteneur du SaaS<br/>certificat wildcard déjà présent
    P->>S: Host: client42.monsaas.com
    S->>B: quel tenant pour « client42 » ?
    S-->>C: espace du client42
```

**À retenir**
- Le DNS wildcard et le certificat wildcard couvrent **tous** les clients, présents
  et futurs.
- **Créer un client = une ligne en base.** Aucune action sur le serveur.
- Détails et configuration : [guide 10](../guides/10-sous-domaines-automatiques.md).

---

## 10. Les fichiers sur le serveur

```mermaid
flowchart TB
    Root["/app"]
    Root --> NPC["nginx-proxy-conf/<br/>porte d'entrée (existant)"]
    Root --> VPS["vps-platform/<br/>outils + observabilité"]
    Root --> Core["core-system/"]
    Root --> Other["&lt;autre-projet&gt;/"]
    Core --> CP["prod/<br/>checkout git + .env"]
    Core --> CS["staging/<br/>checkout git + .env.staging"]
    Other --> OP["prod/"]
    Other --> OS["staging/"]
    State["/var/lib/vps-platform/&lt;projet&gt;/<br/>versions en ligne, historique, journal"]
    VPS -.-> State
```

| Où | Quoi | Qui y touche |
| --- | --- | --- |
| `/app/nginx-proxy-conf` | Le proxy partagé | personne (sauf incident) |
| `/app/vps-platform` | Outils et observabilité | mise à jour par `git pull` |
| `/app/<projet>/staging` | Le checkout qui **construit** les images | `deploy.sh` (automatique) |
| `/app/<projet>/prod` | Le checkout de **production** : ne construit jamais | `make prod-promote` |
| `/var/lib/vps-platform` | La mémoire des déploiements (`current`, `previous`, journal) | `deploy.sh` |

---

## 11. Les relations entre tous les éléments

```mermaid
flowchart TB
    DNS[("DNS wildcard")] --> Proxy["nginx-proxy<br/>+ acme-companion"]
    Proxy -->|"VIRTUAL_HOST"| Webs["Conteneurs web des projets"]
    Webs --> Apps["Apps"]
    Apps --> DBs[("Bases<br/>réseaux privés")]
    Apps -->|"labels + réseau observability"| Obs["Observabilité"]
    Backups["Agents backup"] --> DBs
    Backups --> S3[("MEGA S4")]

    Deploy["deploy.sh"] -->|"build, migre, bascule, vérifie"| Webs
    Deploy -->|"sauvegarde avant migration"| Backups
    Deploy -->|"noms libres ?"| Hosts["vps-hosts.sh"]
    Deploy -->|"configuration valide ?"| Proxy
    Hosts -->|"lit VIRTUAL_HOST + certificats"| Proxy
    Audit["vps-audit.sh<br/>(lecture seule)"] -->|"contrôle le contrat"| Webs & Apps & DBs & Proxy
    Cron["cron / GitLab CI"] -->|"watch (staging)"| Deploy
    Human(["Personne"]) -->|"promote (production)"| Deploy
    Uptime(["Surveillance externe"]) --> Proxy
```

| Élément | Dépend de | Si il tombe… |
| --- | --- | --- |
| nginx-proxy | DNS, Docker | plus aucun site ne répond. Priorité absolue (guide 12) |
| acme-companion | nginx-proxy, DNS | les sites restent servis ; les renouvellements sont en retard (les certificats durent 90 jours) |
| Un projet | nginx-proxy, sa base | seul ce projet est touché |
| Observabilité | Docker | aucun site n'est touché ; on perd juste la visibilité |
| `deploy.sh` / cron | git, Docker | rien ne casse ; les déploiements attendent |
| MEGA S4 | Internet | rien ne casse ; les sauvegardes restent locales, à rattraper |
