# vcam-infra-deploy — le standard d'hébergement du VPS et ses outils

Ce dépôt définit **comment tout projet est hébergé sur le VPS**, quel que soit son langage
(Laravel, Node, React, Angular, Next.js…), du moment qu'il tourne dans Docker. En échange, un
projet obtient automatiquement :

- HTTPS ;
- un staging ;
- un déploiement avec retour arrière ;
- des sauvegardes chiffrées hors du serveur ;
- une supervision ;
- une protection contre les collisions de sous-domaines.

**La référence est le [contrat d'un projet](docs/05-contrat-projet.md)** : ce que tout projet
hébergé doit respecter, qui le vérifie, et comment le faire évoluer. Les modèles, les outils et
les guides en découlent. En cas de désaccord, c'est le contrat qui fait foi.

> **Toute la documentation, classée par métier et par question : [docs/README.md](docs/README.md).**

## Ce que fait ce dépôt

Le dépôt a plusieurs métiers. Chacun a un point d'entrée.

| Métier | Il répond à… | Contenu | Point d'entrée |
| --- | --- | --- | --- |
| **Le standard** | Que doit respecter un projet ? | Le contrat (clauses C1 à C14), les 16 règles, les noms | [Contrat](docs/05-contrat-projet.md) · [les 16 règles](docs/reference/les-16-regles.md) |
| **Les outils de déploiement** | Comment déploie-t-on, vérifie-t-on, restaure-t-on ? | `deploy.sh`, `vps-audit.sh`, `vps-inventory.sh`, `vps-hosts.sh`, `restore.sh` | [`bin/`](bin) · [outil par outil](docs/reference/contenu-du-depot.md) · [livraison](docs/reference/organisation-et-livraison.md) |
| **Le serveur** | Comment installer et régler le VPS ? | Installation, DNS, journaux Docker, mises à jour, reprise après sinistre | [Guides](guides/README.md) · [`host/`](host) |
| **L'observabilité** | Que se passe-t-il sur le serveur ? | Grafana, Loki, Prometheus, Tempo, Alloy | [`observability/`](observability/README.md) · [guide 17](guides/17-comprendre-et-lire-grafana.md) |
| **Les sauvegardes** | Comment ne pas perdre de données ? | L'agent chiffré vers S3, la restauration | [`images/db-backup/`](images/db-backup/README.md) · [sauvegardes](docs/reference/sauvegardes.md) |
| **Les modèles** | Par quoi partir pour un nouveau projet ? | Compose Laravel, web, frontend, `platform.env` | [`templates/`](templates) |
| **La qualité** | Comment sait-on que ça marche ? | Tests réels de toute la plateforme | [`tests/`](tests/README.md) |
| **La mémoire** | Pourquoi ce choix ? Qu'est-ce qui a déjà mal tourné ? Que faire quand ça tombe ? | Décisions, retours d'expérience, runbooks, inventaires | [ADR](docs/adr/README.md) · [retours d'expérience](docs/retours-experience/README.md) · [runbooks](docs/runbooks/README.md) · [inventaires](docs/inventaire/README.md) |

## Par où commencer

| Je suis… | Je lis |
| --- | --- |
| **Une nouvelle équipe informatique** qui reprend le serveur | [Guide 15, prise en main](guides/15-prise-en-main-equipe-it.md), puis les [runbooks d'incident](docs/runbooks/README.md) |
| **Je veux voir un projet complet au standard**, fichier par fichier | [Guide 18, le projet pilote](guides/18-le-projet-pilote-skills-devops.md) et le [catalogue des besoins](docs/reference/catalogue-des-besoins.md) |
| **Responsable d'un projet déjà en production** à mettre au standard | [Guide 16, fiche de conformité](guides/16-mettre-un-projet-au-standard.md) et le [contrat, § 4](docs/05-contrat-projet.md#4-appliquer-le-contrat-à-un-projet-déjà-en-production) |
| **Mainteneur de la plateforme** (je change une règle, un outil) | [Contrat, § 5](docs/05-contrat-projet.md#5-faire-évoluer-le-contrat), les [retours d'expérience](docs/retours-experience/README.md) et les [tests](tests/README.md) |
| **Développeur** qui veut mettre son projet en ligne | [Démarrage rapide](docs/04-demarrage-rapide-dev.md), puis les [schémas](docs/01-schemas.md) |
| **Nouveau**, je veux comprendre comment le serveur fonctionne | [Schémas](docs/01-schemas.md), [glossaire](docs/03-glossaire.md), [architecture](docs/reference/architecture-du-serveur.md) |
| **La personne qui installe** la plateforme | La [feuille de route](guides/00-feuille-de-route.md), puis les [guides](guides/README.md) |
| **Je veux voir ce qui tourne** sur le serveur | `vps-inventory.sh` et les [inventaires](docs/inventaire/README.md) |
| **Je veux déployer ou mettre à jour : que faire selon ma situation et mon environnement ?** | [Déployer selon la situation](docs/reference/deployer-selon-la-situation.md) · [modèles](templates/README.md) |
| **Je veux comprendre Grafana** | [Guide 17](guides/17-comprendre-et-lire-grafana.md) |
| **Je veux que mon projet ait ses tableaux et ses alertes** | [Guide 19](guides/19-observabilite-de-mon-projet.md) |
| **Responsable technique** | [Résilience et évolutivité](docs/02-resilience-evolutivite.md), [ADR-0064](docs/adr/0064-infrastructure-vps-staging-observabilite-mutualisee.md) |
| **En plein incident** | [Runbooks](docs/runbooks/README.md), puis la [reprise après sinistre](guides/12-reprise-apres-sinistre.md) si le serveur est perdu |

## Carte du dépôt

```
bin/                outils : deploy.sh, vps-audit.sh, vps-inventory.sh, vps-hosts.sh, restore.sh
templates/          modèles de projet (Laravel, web, frontend, observabilité Laravel)
images/db-backup/   agent de sauvegarde chiffrée vers S3
observability/      Grafana, Loki, Prometheus, Tempo, Alloy (une pile pour tout le serveur)
host/               réglages du démon Docker et procédure sans coupure
tests/              tests réels de toute la plateforme (Docker requis)
guides/             actions pas à pas, classées par thème (installer, mettre au standard, exploiter)
docs/               contrat, schémas, glossaire, référence, décisions, incidents, runbooks, inventaires
```

Le dossier `docs/` a lui-même une carte : [docs/README.md](docs/README.md).

> **Où vit ce dossier.** Il est né dans le dépôt `core-system`, mais il concerne tout le serveur.
> Il peut vivre dans son propre dépôt (`vps-platform`), cloné sur le serveur dans
> `/app/vps-platform` ([guide 11](guides/11-depot-plateforme.md)). Les exemples utilisent ce chemin.

## Démarrage en cinq minutes

```bash
# Sur un poste de développement avec Docker : vérifier un outil pour de vrai
$ tests/run-all.sh hosts

# Sur le serveur, en lecture seule : voir l'état réel
$ vps-inventory
$ vps-audit
$ cd /app/<projet>/prod && vps-deploy check prod   # ne modifie rien
```

## Où est passé le § N du README ?

Le README contenait autrefois onze sections numérotées, citées par des outils et des guides.
Elles ont été déplacées dans des pages thématiques, **sans changer leur contenu** :

| Ancienne section | Maintenant dans |
| --- | --- |
| Contenu du dépôt (outil par outil) | [contenu du dépôt](docs/reference/contenu-du-depot.md) |
| § 1 Vue d'ensemble du serveur, réseaux Docker | [architecture du serveur](docs/reference/architecture-du-serveur.md) |
| § 2 Le standard, 16 règles | [les 16 règles](docs/reference/les-16-regles.md) |
| § 3 Domaines et DNS | [domaines et DNS](docs/reference/domaines-et-dns.md) |
| § 4 Organisation sur le serveur · § 5 Protocole de livraison | [organisation et livraison](docs/reference/organisation-et-livraison.md) |
| § 6 Brancher un nouveau projet · § 7 Corriger un projet existant | [brancher et corriger un projet](docs/reference/brancher-et-corriger-un-projet.md) |
| § 8 Réglages de l'hôte | [réglages de l'hôte](docs/reference/reglages-de-lhote.md) |
| § 9 Sauvegardes | [sauvegardes](docs/reference/sauvegardes.md) |
| § 10 Supervision · § 11 Incidents | [supervision et incidents](docs/reference/supervision-et-incidents.md) |
