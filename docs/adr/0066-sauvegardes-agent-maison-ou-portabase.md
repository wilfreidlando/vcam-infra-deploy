# ADR-0066 — Sauvegardes : notre agent, Portabase, ou les deux ?

- **Statut** : **Proposé** — une décision est attendue après l'essai décrit en bas de page
- **Date** : 2026-10-05
- **Décideurs** : responsable de la plateforme
- **Complète** : [ADR-0064](0064-infrastructure-vps-staging-observabilite-mutualisee.md) (sauvegardes mutualisées), [contrat](../05-contrat-projet.md) clause C11

> **Mise à jour du 2026-10-05 :** [ADR-0067](0067-profils-de-projet-et-sauvegardes-sur-s3-seulement.md) fixe une contrainte pour **tout** outil de sauvegarde, le nôtre
> comme Portabase : **les sauvegardes ne vivent que sur S3**, aucune copie ne reste sur le disque du serveur. Le critère est à ajouter à l'essai.

## Contexte

La plateforme fournit un agent de sauvegarde ([`images/db-backup`](../../images/db-backup/README.md)) : un petit service par projet, dans
son `compose.prod.yaml`, qui fait un dump chiffré chaque nuit et **avant chaque mise en production**, le copie sur S3, et sait le restaurer.
Il est testé sur PostgreSQL 18, MySQL 8.4, MariaDB 10.7 et 11.4.

Mais l'inventaire du serveur montre où est le vrai risque : **la grande majorité des bases du serveur n'a aucune sauvegarde visible**, et la plupart
sont des **MariaDB 10.7**, le reste se partageant entre MariaDB 11.4 et PostgreSQL. Seuls les projets mis au standard (le pilote d'abord) ont notre
agent.

Le goulot n'est donc pas la qualité de notre agent : c'est **qu'il faut le brancher projet par projet** (modifier le compose, redéployer, renseigner les
variables), pour des dizaines de projets que le contrat n'a pas encore atteints. Un outil central qui sauvegarde sans toucher aux projets mérite d'être étudié,
d'autant qu'une question légitime se pose : **pourquoi refaire de zéro ce qu'un projet ouvert sait déjà faire ?**

**Portabase** est un tel outil. Cette ADR l'évalue **sur des faits sourcés**, sépare ce qui est établi de ce qui ne l'est pas, et propose un essai à
critères de réussite explicites.

## Ce qu'est Portabase (sources officielles)

| Élément | Ce qui est établi | Source |
| --- | --- | --- |
| Licence | Apache-2.0, auto-hébergé | [dev.co](https://dev.co/devops/open-source/portabase), [dépôt](https://github.com/Portabase/portabase) |
| Architecture | Tableau de bord web (Next.js) + **agents en Rust** posés près des bases. L'ancien agent en Python est **archivé** depuis le 2026-02-15 | [dépôt](https://github.com/Portabase/portabase), [agent archivé](https://github.com/Portabase/agent-portabase) |
| Communication | **Le serveur ne contacte jamais l'agent** : l'agent l'interroge toutes les 5 s (`POLLING`), donc aucun port entrant à ouvrir | [guide d'installation](https://dev.to/soluce_technologies/self-hosting-portabase-a-comprehensive-guide-to-effortless-database-backup-and-restore-4e5b) |
| Bases prises en charge | PostgreSQL 12 à 18, MySQL 5.7/8/9, **MariaDB 10 et 11**, MongoDB 4 à 8, SQLite, Firebird, MSSQL ; Redis et Valkey : **sauvegarde seulement** | [dépôt](https://github.com/Portabase/portabase), [documentation](https://portabase.io/docs) |
| Planification et conservation | Cron ou déclenchement manuel ; conservation par nombre, par durée ou **GFS** (grand-père, père, fils) | [documentation](https://portabase.io/docs), [IT-Connect](https://www.it-connect.tech/portabase-how-to-centralize-database-backups-with-an-open-source-platform/) |
| Chiffrement | AES-GCM (confidentialité et intégrité) | [documentation](https://portabase.io/docs) |
| Stockages | Disque local, compatibles S3, Google Drive, Google Cloud Storage, SFTP, Rclone ; **plusieurs destinations pour une même sauvegarde** | [documentation](https://portabase.io/docs), [guide](https://dev.to/soluce_technologies/self-hosting-portabase-a-comprehensive-guide-to-effortless-database-backup-and-restore-4e5b) |
| Notifications | E-mail, Slack, Discord, Telegram, Ntfy, Gotify, Teams, Pushover, webhooks ; règles succès/échec par base | idem |
| Accès | Équipes et organisations, authentification OIDC/OAuth2 | [comparaisons](https://portabase.io/docs/comparisons/overview) |
| Déploiement | Tableau de bord (`portabase/portabase`, port 8887) + sa propre base PostgreSQL 17 ; agent par Docker ou CLI, déclarant ses bases dans un `databases.json` (hôte, port, identifiant, mot de passe) | [guide](https://dev.to/soluce_technologies/self-hosting-portabase-a-comprehensive-guide-to-effortless-database-backup-and-restore-4e5b) |
| Exigences annoncées | Docker 20.10+, Compose 2+, Linux « Ubuntu 22.04+, Debian 11+ » | [exigences](https://portabase.io/docs/requirements) |

## Ce qui n'est **pas** établi (à prouver par l'essai)

Chaque ligne est un point où une mauvaise surprise coûterait cher : on ne la décide pas sur une documentation muette.

| # | Question | Pourquoi elle compte pour nous |
| --- | --- | --- |
| Q1 | **La restauration remplace-t-elle la base, ou fusionne-t-elle ?** (« restauration en un clic », sémantique non documentée) | Notre exercice du 2026-10-04 a justement montré qu'une restauration qui fusionne laisse les objets créés après la sauvegarde ([retour d'expérience](../retours-experience/2026-10-05-la-restauration-ne-remplacait-pas-la-base.md)) |
| Q2 | **Qui détient la clé de chiffrement ?** Si elle n'est que dans le tableau de bord, perdre le serveur = perdre l'accès aux sauvegardes (le but de la copie hors serveur) | Reprise après sinistre ([guide 12](../../guides/12-reprise-apres-sinistre.md)) ; notre agent garde la phrase **hors** de l'application |
| Q3 | **Que fait l'agent si le tableau de bord est arrêté ?** Les sauvegardes planifiées partent-elles quand même ? | Le tableau de bord devient un point unique de défaillance pour **toutes** les sauvegardes |
| Q4 | **Peut-on déclencher une sauvegarde depuis un script ?** (une API REST et un serveur MCP sont annoncés **à venir**) | Notre protection « sauvegarde juste avant chaque migration en production, et refus de déployer si elle échoue » (`deploy.sh promote`) en dépend |
| Q5 | **Compatibilité réelle** avec MariaDB 10.7 et 11.4, MySQL 8.4, PostgreSQL 18 (la documentation donne des fourchettes) | La plupart des bases du serveur sont en MariaDB 10.7 |
| Q6 | **Compatibilité avec MEGA S4** (S3 : adressage par chemin, point de terminaison) | Notre stockage hors serveur |
| Q7 | Consommation (processeur, mémoire, disque temporaire pour l'archive) sur un serveur déjà chargé | Un serveur déjà chargé |
| Q8 | **Serveur en Ubuntu 20.04** alors que la documentation annonce Ubuntu 22.04+ | Support non garanti |
| Q9 | Mises à jour et stabilité : l'ancien agent Python est archivé au profit d'un agent Rust, ce qui montre un projet qui évolue vite | Dépendance à un projet jeune : prévoir de figer la version testée |

## Options

| Option | Pour | Contre |
| --- | --- | --- |
| **A. Garder notre agent, le brancher projet par projet** | Déjà écrit et testé sur nos versions ; protection avant migration intégrée à `deploy.sh` ; phrase de chiffrement hors de l'application ; aucune dépendance externe ; restauration vérifiée « état exact » | **Le goulot reste** : des dizaines de projets à modifier et redéployer ; pas d'interface, pas de notifications natives, conservation simple (7 copies locales, 30 jours distants) |
| **B. Tout confier à Portabase** | Couvre les bases héritées **sans toucher aux projets** ; interface, historique, notifications, conservation GFS, plusieurs destinations | Q1 à Q9 ouvertes ; un composant central de plus (tableau de bord, sa base, son authentification, son certificat) ; **perd la sauvegarde atomique avant migration** tant que Q4 n'est pas résolue ; un agent qui joint toutes les bases concentre les identifiants (voir ci-dessous) |
| **C. Hybride** : notre agent pour les projets au standard (pilote, Core), Portabase pour rattraper les projets hérités | Chacun là où il est le plus fort ; le risque principal (les bases héritées sans sauvegarde) est traité vite ; la protection avant migration reste sur les projets qui déploient par `deploy.sh` | Deux mécanismes à connaître ; à rationaliser quand les projets passeront au standard |

### Une remarque de sécurité qui s'applique à toute solution centrale

Pour sauvegarder toutes les bases sans modifier leurs projets, **un seul service doit pouvoir les joindre toutes et connaître leurs identifiants**. C'est
exactement l'inverse de l'isolation de la clause C2 (une base ne doit pas être joignable par les autres projets). Aujourd'hui les bases héritées sont
sur le réseau partagé `nginx-proxy`, donc un agent unique les atteindrait ; une fois la clause C2 appliquée, l'agent devrait rejoindre chaque réseau privé, ou
chaque projet garder son propre agent. **Ce compromis est une décision, pas un détail** : il se documente, il se mesure.

## Recommandation (provisoire)

**Option C, après un essai.** Elle traite d'abord ce qui compte le plus (les bases héritées sans aucune sauvegarde) sans bloquer les projets, et ne renonce pas à la
protection avant migration, qui est la raison d'être de l'agent maison. Elle n'est confirmée que si l'essai répond positivement à Q1 à Q4.

Si Q1 (remplacement) ou Q2 (garde de la clé) échouent, Portabase n'est **pas** adapté comme outil de **restauration** de ce serveur, et on revient à
l'option A avec un plan de branchement accéléré.

## Protocole d'essai (une demi-journée, sur un poste, jamais en production)

Aucune donnée réelle, aucun secret du serveur. Tout est jetable (`vpstest-*`).

| Étape | Action | Critère de réussite |
| --- | --- | --- |
| 1 | Installer le tableau de bord (Docker Compose) et **un agent** | Les deux démarrent ; l'agent apparaît dans le tableau de bord |
| 2 | Déclarer **trois bases** : PostgreSQL 18, **MariaDB 10.7**, MariaDB 11.4 | Les trois sont sauvegardées (Q5) |
| 3 | Sauvegarder vers un S3 local (SeaweedFS, comme dans `tests/test-backup.sh`) | Fichier présent et chiffré (Q6 en partie) |
| 4 | Créer une table-témoin **après** la sauvegarde, restaurer | **La table-témoin a disparu** pour les trois bases (**Q1**) ; sinon, noter lesquelles |
| 5 | Chercher où est la clé de chiffrement ; restaurer **sur une autre instance** du tableau de bord vierge | La restauration est possible sans l'ancien tableau de bord, ou la limite est écrite (**Q2**) |
| 6 | Arrêter le tableau de bord ; attendre une échéance de cron | La sauvegarde part-elle ? (**Q3**) |
| 7 | Chercher un moyen de déclenchement en ligne de commande | Existe-t-il ? (**Q4**) |
| 8 | Mesurer processeur et mémoire de l'agent et du tableau de bord pendant une sauvegarde | Consommation notée (**Q7**) |
| 9 | Corrompre une sauvegarde (tronquer le fichier), tenter de restaurer | Refusée **avant** de toucher à la base |
| 10 | Rédiger le résultat dans cette ADR : statut **Accepté**, **Rejeté** ou **Remplacé** | Une décision, datée, avec les preuves |

## Conséquences si l'option C est retenue

- Une page « Quel mécanisme pour quel projet ? » dans les [sauvegardes](../reference/sauvegardes.md), avec la règle : **un projet qui déploie par
  `deploy.sh` garde son agent** (protection avant migration) ; un projet hérité est couvert par l'outil central **jusqu'à sa mise au standard**.
- Les exercices de restauration mensuels s'appliquent aux **deux** mécanismes.
- La phrase de chiffrement, ou la clé de l'outil central, est conservée **hors du serveur** (gestionnaire de mots de passe).
- Le contrat (clause C11) n'impose pas un outil : il impose un **résultat** (sauvegarde chiffrée hors serveur, restaurée chaque mois, état exact).

## Sources

- [Portabase, dépôt principal](https://github.com/Portabase/portabase) · [documentation](https://portabase.io/docs) · [exigences](https://portabase.io/docs/requirements) · [comparaisons](https://portabase.io/docs/comparisons/overview)
- [Guide d'installation (DEV)](https://dev.to/soluce_technologies/self-hosting-portabase-a-comprehensive-guide-to-effortless-database-backup-and-restore-4e5b) · [IT-Connect](https://www.it-connect.tech/portabase-how-to-centralize-database-backups-with-an-open-source-platform/)
- [Agent Python archivé](https://github.com/Portabase/agent-portabase)

Faits consultés le 2026-10-05. Ils évoluent : l'essai doit être fait avec la version courante, et cette ADR mise à jour avec la version testée.
