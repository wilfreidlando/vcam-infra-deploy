# Glossaire

Les mots de la plateforme, expliqués simplement. Classés par thème.

## Docker

| Mot | Explication |
| --- | --- |
| **Image** | Un paquet figé qui contient une application et tout ce qu'il lui faut (PHP, extensions, code). Comme un fichier d'installation, mais complet. Ici, chaque image porte le **SHA du commit** dont elle vient : `core-system:3f2a…` |
| **Conteneur** | Une image **en train de tourner**. On peut en lancer plusieurs à partir de la même image (app, horizon, scheduler) |
| **Volume** | Un dossier qui **survit** au conteneur : c'est là que vivent les données (base, fichiers). Supprimer un conteneur ne supprime pas son volume |
| **Réseau Docker** | Un câble virtuel. Seuls les conteneurs branchés sur le même réseau peuvent se parler |
| **Docker Compose** | Un fichier YAML (`compose.prod.yaml`) qui décrit tous les conteneurs d'un projet, et une commande qui les lance ensemble |
| **Projet Compose** (`-p`) | Le nom qui regroupe les conteneurs, réseaux et volumes d'un projet (`core-system-prod`). **Changer ce nom revient à créer un nouveau projet, vide.** |
| **Healthcheck** | Une petite commande que Docker lance régulièrement pour savoir si le conteneur va bien (ex. `curl /up`) |
| **Limite mémoire** | Le maximum de RAM qu'un conteneur peut prendre. Au-delà, seul ce conteneur est redémarré, pas le serveur |
| **Socket Docker** | La « télécommande » de Docker. Qui la possède contrôle tout le serveur : on ne la donne à aucun projet |

## Web et réseau

| Mot | Explication |
| --- | --- |
| **DNS** | L'annuaire d'Internet : il traduit `core-system.visibilitycam.com` en adresse IP |
| **Enregistrement wildcard** (`*`) | Une ligne DNS qui répond pour **tous** les sous-domaines qui n'ont pas leur propre ligne |
| **Reverse proxy** | Le portier : il reçoit toutes les visites et les envoie au bon projet selon le nom demandé. Ici : **nginx-proxy** |
| **`VIRTUAL_HOST`** | La variable qui dit à nginx-proxy « ce conteneur répond pour ce nom » |
| **Sidecar** | Un petit conteneur nginx propre à un projet, entre nginx-proxy et l'app (Core) |
| **Certificat (TLS/HTTPS)** | La preuve d'identité d'un site, qui permet le cadenas du navigateur. Délivré gratuitement par **Let's Encrypt**, demandé par **acme-companion** |
| **Certificat wildcard** | Un certificat valable pour tous les sous-domaines (`*.monsaas.com`). Il exige le challenge **DNS-01** |
| **Challenge HTTP-01 / DNS-01** | La façon de prouver à Let's Encrypt qu'on possède le domaine : par une page web (HTTP-01, automatique ici) ou par un enregistrement DNS (DNS-01, il faut l'API du DNS) |
| **Collision de sous-domaine** | Deux projets qui déclarent le même nom. nginx-proxy ne refuse pas : il mélange le trafic. La plateforme l'empêche |
| **`X-Forwarded-For`** | L'en-tête qui transporte la vraie IP du visiteur à travers les proxys. Il peut être falsifié : on ne le croit que s'il vient d'un proxy de confiance |

## Livraison

| Mot | Explication |
| --- | --- |
| **Staging** | Une copie complète et isolée d'un projet, avec ses propres données, où l'on teste avant la production |
| **Production** | La version utilisée par les vrais clients |
| **Sandbox** | Dans le Core, le mode « paiements de test » **à l'intérieur** d'un environnement. À ne pas confondre avec le staging |
| **Build** | Fabrication de l'image d'un commit |
| **Promotion** | Mettre en production l'image **déjà testée** en staging |
| **Rollback** (retour arrière) | Remettre la version précédente |
| **Migration** | Un script qui modifie la structure de la base (ajout de colonne…). Elle n'est **pas** annulée par un rollback |
| **SHA** | L'identifiant unique d'un commit git (`3f2a9c…`) |
| **Cron** | Le planificateur de tâches de Linux : « toutes les 2 minutes, lance… » |

## Sauvegardes et supervision

| Mot | Explication |
| --- | --- |
| **Dump** | Une copie de la base sous forme de fichier (`pg_dump`, `mariadb-dump`) |
| **S3 / MEGA S4** | Un stockage de fichiers en ligne. MEGA S4 parle le même langage que S3 d'Amazon |
| **Phrase de passe** | La clé qui chiffre les sauvegardes. **Perdue = sauvegardes illisibles** |
| **RPO / RTO** | Données qu'on accepte de perdre (RPO) / temps pour revenir en ligne (RTO) |
| **Journaux (logs)** | Ce que les applications écrivent au fil de l'eau. Centralisés dans **Loki** |
| **Métriques** | Des nombres suivis dans le temps (requêtes/s, erreurs…). Stockés dans **Prometheus** |
| **Trace** | Le chemin détaillé d'une requête à travers les services. Stockée dans **Tempo** |
| **Grafana** | L'écran qui affiche journaux, métriques et traces, et qui envoie les alertes |
| **Alloy** | Le collecteur qui ramasse tout cela dans les conteneurs étiquetés |
| **Audit** (`vps-audit.sh`) | Le contrôle automatique des règles du [contrat](05-contrat-projet.md), en lecture seule |
| **Contrat d'un projet** | Le [référentiel](05-contrat-projet.md) : ce que tout projet hébergé doit respecter, et qui le vérifie |
| **Contrôle avant déploiement** (`vps-deploy check`) | Ce que `deploy.sh` vérifie avant de toucher à quoi que ce soit. S'il échoue, le déploiement est refusé (BLOQUANT) et rien n'est modifié. Se lance aussi seul, sans risque, sur un projet en production |
| **Clé de déploiement** | Clé SSH en lecture seule, propre à un dépôt, qui permet au serveur de lire le code sans mot de passe (guide 3) |
| **REX** (retour d'expérience) | Analyse d'un incident, qui n'est close que lorsqu'une protection automatique empêche qu'il se reproduise ([liste](retours-experience/README.md)) |
