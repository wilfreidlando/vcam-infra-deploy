# Schémas de la plateforme

Chaque schéma montre **un seul sujet**, avec en dessous ce qu'il faut en retenir.
Les mots techniques sont expliqués dans le [glossaire](03-glossaire.md).

**Où suis-je ?** Cette page est le **niveau 3** (le détail, un sujet par schéma). Pour ne pas se perdre, on part de la page
[Architecture du serveur](reference/architecture-du-serveur.md) (niveaux 1 et 2 : le serveur en une image, puis les cinq familles
de choses qu'il contient) et on descend ici quand on a besoin du détail d'un sujet.

**Comment lire les flèches** (identique dans tous les schémas) :

| Trait | Sens |
| --- | --- |
| Flèche pleine `-->` | Un flux qui existe toujours : une requête, une donnée, une dépendance |
| Flèche pointillée `-.->` | Un flux **périodique ou optionnel** : une sauvegarde nocturne, une sonde, une métrique envoyée si le projet l'a prévue |
| Cylindre | Des **données qui durent** (base, journaux, copies) |
| Cadre « réseau … » | Les conteneurs qui peuvent **se joindre** entre eux ; en dehors du cadre, ils ne se voient pas |

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
12. [Les alertes : du signal à l'e-mail](#12-les-alertes--du-signal-à-le-mail)

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

**Le cas à connaître : un conteneur web est sur TROIS réseaux.** C'est le cas normal du conteneur web d'un projet, et c'est là qu'un
outil qui ne regarde qu'un réseau se trompe (voir le
[retour d'expérience du 5 octobre](retours-experience/2026-10-05-metriques-du-pilote-absentes-reseau-alloy.md)).

```mermaid
flowchart LR
    Visitor(["Visiteur"]) --> Proxy
    subgraph NP["réseau nginx-proxy : l'entrée publique"]
        Proxy["nginx-proxy"]
    end
    subgraph WEB["Le conteneur web du projet (un seul conteneur, trois branchements)"]
        Web["skills-devops-web"]
    end
    subgraph OB["réseau observability : être observé"]
        Alloy["alloy"]
    end
    subgraph PRIV["réseau privé du projet : le travail interne"]
        DB[("base")]
        Cache[("cache")]
    end
    Proxy -->|"HTTPS vers le site"| Web
    Alloy -->|"scrute /metrics"| Web
    Web -->|"requêtes"| DB & Cache
```

| Réseau | Pourquoi le conteneur web y est | Ce qui ne doit **jamais** y être |
| --- | --- | --- |
| `nginx-proxy` | Recevoir les visites | La base, le cache, les workers |
| `observability` | Être scruté (métriques, traces) | La base, le cache, un conteneur PHP-FPM |
| `<projet>-<env>-internal` | Parler à sa base et à son cache | rien : c'est son réseau |

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
        Local[("Aucune copie gardée<br/>(3 au plus si S3 est injoignable)")]
    end
    Pass{{"Phrase de passe<br/>dans le gestionnaire de mots de passe"}}
    Remote[("MEGA S4<br/>30 jours de copies")]

    DB -->|"pg_dump / mariadb-dump"| Agent
    Agent -->|"chiffrement AES-256, envoi S3"| Remote
    Agent -. "copie locale supprimée après l'envoi" .-> Local
    Pass -.-> Agent

    Remote -->|"restore.sh"| Restore["Restauration<br/>app arrêtée → base REMPLACÉE → app relancée"]
    Local -->|"restore.sh"| Restore
    Agent -. "ligne « uploaded to » dans les journaux" .-> Watch["Alerte Grafana<br/>aucune copie envoyée depuis 36 h"]
```

**À retenir**
- MEGA ne voit **que des données chiffrées**.
- **Les sauvegardes ne vivent que sur S3** : aucune copie ne reste sur le disque du serveur après l'envoi, pour qu'il ne se remplisse jamais
  sans qu'on le sache ([sauvegardes](reference/sauvegardes.md)).
- **Sans la phrase de passe, aucune restauration n'est possible.** Elle doit être
  conservée hors du serveur.
- Une sauvegarde ne compte que si l'on a déjà réussi à la restaurer : une fois par
  mois, restaurer la production dans le staging (`README.md` § 9).

---

## 8. Observabilité : journaux, métriques, traces

Trois **sortes de signaux**, trois **chemins** : ne pas les confondre, un chemin peut marcher sans que les autres marchent.

```mermaid
flowchart LR
    subgraph Apps["Projets observés (label observability.enable=true)"]
        A1["web du projet<br/>journaux JSON, /metrics privé, traces OTLP"]
        A2["worker, scheduler, backup<br/>journaux seulement"]
        X["projet SANS label"]
    end
    subgraph Host["Le serveur et ses sites : rien à faire côté projet"]
        NodeE["node-exporter<br/>processeur, mémoire, swap, disque, charge"]
        CAd["cAdvisor<br/>consommation et redémarrages de chaque conteneur"]
        BB["blackbox-exporter<br/>site en ligne ? délai, expiration du certificat"]
    end
    subgraph OBS["observability (partagé)"]
        Alloy["Alloy<br/>découvre les conteneurs par label"]
        Loki[("Loki<br/>journaux 90 j")]
        Prom[("Prometheus<br/>métriques, 30 j par défaut")]
        Tempo[("Tempo<br/>traces 30 j")]
        Graf["Grafana<br/>tableaux et alertes"]
    end
    Sites(["Les sites publics"])
    Team(["Équipe"])

    A1 & A2 -->|"1. journaux : stdout, via le socket Docker"| Alloy
    Alloy -->|"2. scrute /metrics, réseau observability"| A1
    A1 -->|"3. traces OTLP :4318"| Alloy
    X -. "ignoré" .-x Alloy
    Alloy --> Loki & Tempo
    Alloy -->|"remote write"| Prom
    Prom -->|"scrute toutes les 30 s"| NodeE & CAd
    Prom -->|"demande une sonde"| BB
    BB -->|"HTTPS"| Sites
    Graf --> Loki & Prom & Tempo
    Team --> Graf
    Graf -->|"alertes par e-mail"| Team
```

| Chemin | Source | Passe par | Se retrouve dans | Condition |
| --- | --- | --- | --- | --- |
| **1. Journaux** | sortie standard de chaque conteneur | socket Docker → Alloy → Loki | Explore → Loki ; tableau Applications | Le label `observability.enable`. Aucun réseau requis |
| **2. Métriques du projet** | `/metrics` du conteneur web | réseau `observability` → Alloy → Prometheus | Explore → Prometheus | Le label `observability.metrics.port` **et** le réseau `observability` |
| **3. Traces** | OTLP envoyé par l'application | réseau `observability` → Alloy → Tempo | Explore → Tempo | Les variables `OTEL_*` |
| **4. Le serveur** | node-exporter | Prometheus le scrute | Tableau Serveur | Rien : automatique |
| **5. Les conteneurs** | cAdvisor | Prometheus le scrute | Tableau Conteneurs | Rien : automatique |
| **6. Les sites** | blackbox-exporter | Prometheus lui demande de sonder la liste `sites.yml` | Tableau Sites | Le site figure dans la liste du serveur |

**À retenir**
- **Rien n'est collecté chez un projet sans le label** `observability.enable=true`. Les chemins 4, 5 et 6 ne demandent **rien** au projet.
- Le minimum pour un projet Laravel : des journaux JSON sur la sortie standard, plus les labels. Les métriques et les traces sont un bonus.
- **Chaque chemin se vérifie séparément** : voir ses journaux ne prouve pas que ses métriques arrivent.
- Les frontends n'en ont pas besoin.
- La carte complète (qui prévient, quoi faire) : [observabilité, carte complète](reference/observabilite-carte-complete.md).

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
| Observabilité (Grafana, Loki, Prometheus, Alloy, Tempo) | Docker | aucun site n'est touché ; on perd juste la visibilité |
| node-exporter, cAdvisor, blackbox-exporter | Prometheus | l'alerte « le serveur n'est plus observé » sonne ; les sites ne sont pas touchés |
| `deploy.sh` / cron | git, Docker | rien ne casse ; les déploiements attendent |
| MEGA S4 | Internet | rien ne casse ; les sauvegardes restent locales, à rattraper |

---

## 12. Les alertes : du signal à l'e-mail

Une alerte est **une question posée régulièrement** à Prometheus ou à Loki : « le disque dépasse-t-il 85 % ? ». Pour éviter le bruit, elle
doit rester vraie pendant un **délai** (`for`) avant de partir.

```mermaid
flowchart LR
    subgraph Signaux["Les signaux"]
        P[("Prometheus<br/>serveur, conteneurs, sites")]
        L[("Loki<br/>journaux des sauvegardes")]
    end
    subgraph Grafana["Grafana"]
        Rules["16 règles<br/>dans le dépôt, provisionnées"]
        State{"Vrai pendant<br/>le délai « for » ?"}
        Policy["Politique de notification<br/>un seul point de contact"]
    end
    Mail(["E-mail de l'équipe"])
    Run["Runbook<br/>docs/runbooks/"]

    P --> Rules
    L --> Rules
    Rules -->|"évalue toutes les 1 à 5 minutes"| State
    State -->|"non : rien"| Rules
    State -->|"oui : Alerting"| Policy
    Policy --> Mail
    Mail -->|"« que faire ? »"| Run
```

| Étape | Ce qui se passe | Où c'est défini |
| --- | --- | --- |
| Les signaux | Les mêmes que le [schéma 8](#8-observabilité--journaux-métriques-traces) | `prometheus.yml`, journaux Alloy |
| Les règles | Une question, un seuil, un délai, une phrase qui dit quoi faire | `observability/grafana/provisioning/alerting/` |
| L'absence de données | **Pas d'alerte**, sauf pour la règle qui surveille l'observateur lui-même | champ `noDataState` de chaque règle |
| Le message | Part par e-mail vers le point de contact par défaut | `core-alerts.yaml` (nom historique : il reçoit **toutes** les alertes) |
| La suite | Chaque alerte pointe vers un runbook | [Runbooks](runbooks/README.md) |

**À retenir**
- Les règles sont **du code** : on les relit, on les teste et on les versionne comme le reste.
- **Une règle charge ses signaux avant de sonner** : charger une alerte avant que son signal existe fait sonner à tort (voir le
  [runbook de mise en service](runbooks/mise-en-service-supervision.md)).
- Si le serveur entier tombe, **rien ici ne le dit** : c'est le rôle d'une sonde externe ([guide 8](../guides/08-surveillance-externe.md)).
