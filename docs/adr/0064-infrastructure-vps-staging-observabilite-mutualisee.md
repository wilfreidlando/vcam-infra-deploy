# ADR-0064 — Standard d'hébergement du VPS : staging, déploiement par promotion d'image, observabilité et sauvegardes mutualisées

> **Copie de référence.** Décision prise dans le dépôt du Core (`docs/adr/0064`), où
> la plateforme vivait dans `infra/`. Depuis le 2026-10-03, elle vit dans ce dépôt,
> à la racine : `infra/README.md` est devenu `README.md`, `infra/bin/` est devenu
> `bin/`, et ainsi de suite. Sur le serveur, le dépôt est cloné dans `/app/vps-platform`.

- **Statut** : Accepté — amende ADR-0053 (déploiement) et ADR-0059 (topologie de l'observabilité)
- **Date** : 2026-10-03
- **Décideurs** : utilisateur
- **Dérives concernées** : D7 exploitabilité

## Contexte

L'utilisateur a précisé ses contraintes au fil de l'échange :
- un seul VPS, sur lequel tournent déjà de nombreux projets **qui ne doivent pas
  casser** ;
- `nginx-proxy` et `acme-companion` sont partagés (configuration fournie,
  inchangée) ;
- un DNS wildcard, pour accueillir les futurs SaaS sans manipulation ;
- un staging déployé automatiquement, une production déployée manuellement ;
- la CI arrivera plus tard via GitLab (un runner existe déjà sur le serveur) ;
- les sauvegardes vont sur MEGA S4 ;
- l'observabilité doit servir aux autres projets Laravel ;
- les projets React, Next.js et Angular doivent pouvoir se déployer, sans
  observabilité ;
- l'entreprise n'avait ni schéma, ni protocole de déploiement : il faut un standard
  qui s'applique à tout projet Docker, quelle que soit sa stack.

Avant cette décision :
- `compose.prod.yaml` fixait les noms, ce qui interdisait un deuxième environnement
  sur le serveur ;
- l'observabilité était collée au projet Core ;
- aucune sauvegarde ne quittait le serveur ;
- le déploiement consistait en `git pull` puis `docker compose up`, sans retour
  arrière.

## Décision

1. **Un standard d'hébergement**, documenté dans `infra/README.md` (12 règles), avec
   ses outils dans `infra/` :
   - `vps-audit.sh` : audit **en lecture seule** de tous les conteneurs ;
   - `deploy.sh` : déploiement générique ;
   - `restore.sh` : restauration d'une sauvegarde ;
   - des modèles Laravel, web générique et frontend (SPA, Next.js) ;
   - l'image `db-backup` (PostgreSQL et MySQL, vers S3) ;
   - la configuration de l'hôte.

   `infra/` est conçu pour être extrait dans un dépôt plateforme : rien n'y dépend
   du Core.
2. **Protocole de livraison.**
   - Une image par commit, taguée avec le SHA, construite dans le checkout de staging.
   - Le staging est déployé automatiquement (`deploy.sh watch` en cron, puis un job
     GitLab).
   - La production est déployée manuellement, avec **la même image**.
   - Avant chaque migration de production, une sauvegarde est obligatoire.
   - Un healthcheck décide : en cas d'échec, retour automatique à la version
     précédente.
   - Exception explicite, `BUILD_PER_ENV=1` : pour les frameworks qui figent leur
     configuration au build (Next.js), chaque environnement a son image, construite
     depuis le même commit.
3. **Le Core comme premier projet conforme.**
   - `compose.prod.yaml` est paramétré par le fichier d'environnement : noms, hôte,
     image, limites. Les valeurs par défaut sont **identiques** à l'existant
     (conteneurs `core-system-*`, réseau `core-system-internal`, volumes du projet
     `core-system-prod`), donc la production n'est ni renommée ni migrée.
   - Le staging tourne dans `core-system-staging`, avec base, volumes et clés
     propres.
   - Limites de ressources et rotation des journaux partout.
4. **Observabilité mutualisée.**
   - Projet `observability` autonome (`infra/observability/`), sur le réseau externe
     `observability`.
   - Découverte **opt-in** par labels Docker (`observability.enable=true`) : aucun
     conteneur n'est lu sans consentement.
   - Alloy est le seul à lire le socket Docker, en lecture seule. Prometheus reçoit
     les métriques en *remote write*.
   - Tableaux de bord par dossier : Core avec le sélecteur prod/staging, plus un
     tableau générique « Applications » ; les alertes ne portent que sur la
     production.
5. **Confiance dans les proxys.**
   - Problème : brancher l'app sur un réseau partagé avec d'autres projets aurait
     permis à leurs conteneurs d'usurper une IP cliente (`X-Forwarded-For`), car les
     plages privées sont de confiance.
   - Solution : `TrustProxiesFromSidecar` n'accepte les en-têtes de proxy que
     s'ils portent `TRUSTED_PROXY_TOKEN`, ajouté par le sidecar nginx du projet
     (gabarit `app.conf.template`). Sinon, l'appelant est traité comme le client
     lui-même.
   - Le jeton est retiré de la requête avant toute autre lecture. Sans jeton
     configuré, le comportement précédent est conservé.
6. **DNS et Cloudflare.**
   - Un DNS wildcard, avec des noms « plats » (`<projet>-staging.<domaine>`).
   - nginx-proxy et acme-companion restent inchangés.
   - Cloudflare est recommandé comme DNS seulement (proxy désactivé). Le proxy est
     à activer projet par projet, et seulement après avoir ajouté la restauration
     de l'IP réelle.
7. **Aucune modification de l'infrastructure partagée existante.** Les seuls ajouts
   sur l'hôte :
   - le réseau `observability` ;
   - une ligne cron par projet ;
   - le dossier d'état `/var/lib/vps-platform` ;
   - optionnellement, la fusion de `daemon.json`, par un script qui active
     live-restore avant tout redémarrage de Docker.

8. **Sous-domaines.**
   - `vps-hosts.sh` fait l'inventaire de tous les noms revendiqués (conteneurs
     arrêtés compris, certificats, Certificate Transparency).
   - `deploy.sh` refuse un nom déjà pris par un autre projet, exactement ou via un
     wildcard, ainsi qu'un nginx-proxy dont la configuration est déjà invalide. Un
     déploiement qui rend cette configuration invalide est traité comme un échec.
   - L'audit signale les collisions et `nginx -t` en échec.
   - Les apps à sous-domaines automatiques utilisent `VIRTUAL_HOST` wildcard et un
     certificat wildcard par DNS-01, que acme-companion 2.5.2 prend en charge
     (vérifié dans son code source) ([guide 10](../../guides/10-sous-domaines-automatiques.md)).
9. **Tests réels rejouables (`infra/tests/`)**, exécutés avant livraison : de vrais
   conteneurs, de vraies bases et le vrai nginx-proxy 1.7. Ils ont révélé et fait
   corriger trois défauts que l'analyse statique ne voyait pas :
   - le chiffrement `gpg` exige un `gpg-agent`, absent de l'image MariaDB ; il est
     remplacé par `openssl` AES-256 + PBKDF2 ;
   - `mariadb-dump` sans `--no-tablespaces` échoue avec un utilisateur MySQL
     applicatif ;
   - une collision de nom ne différant que par la casse rend la configuration de
     nginx-proxy invalide pour tout le serveur. Les protections du point 8 en
     découlent.

   Par ailleurs, l'image de sauvegarde n'est plus construite qu'à partir d'images
   officielles (`postgres:18`, `mariadb:11`, `amazon/aws-cli`), sans gestionnaire de
   paquets : la même construction marche partout.

10. **Documentation pour toute l'équipe**, développeurs compris :
    - `infra/docs/` : un schéma par élément (serveur, réseaux, trajet d'une visite,
      anatomie d'un projet, livraison, déploiement pas à pas, sauvegardes,
      observabilité, SaaS, fichiers, relations), la résilience (panne → parade) et
      l'évolutivité par paliers, un glossaire et un démarrage rapide ;
    - le guide 12, reprise après sinistre ;
    - les 28 schémas Mermaid ont été rendus par mermaid-cli pour valider leur
      syntaxe.
11. **Seul le conteneur web déclare `VIRTUAL_HOST`.**
    - Défaut trouvé par `test-platform.sh` : le `.env`, chargé en entier dans
      app, horizon, scheduler et backup, leur faisait aussi déclarer le nom à
      nginx-proxy.
    - Le nom public s'appelle désormais `CORE_PUBLIC_HOST` (Core) ou
      `APP_PUBLIC_HOST` (modèles), et il est mappé sur le seul conteneur web.
      L'ancien `VIRTUAL_HOST` reste lu en secours.

## Conséquences

- **Plusieurs projets, un seul serveur** : les limites mémoire et la rotation des
  journaux empêchent un projet de faire tomber les autres. L'audit montre les écarts
  des projets existants, et chaque correction s'applique au prochain déploiement du
  projet.
- **Ce qui n'est pas couvert** :
  - **la haute disponibilité**, impossible avec un seul serveur. Les sauvegardes
    hors serveur et la surveillance externe sont le minimum.
  - **l'annulation des migrations** lors d'un retour arrière : la sauvegarde
    préalable et des migrations rétrocompatibles en tiennent lieu.
- **Validé par les tests réels (`infra/tests/`)** :
  - sauvegardes : 34 vérifications contre PostgreSQL 18, MySQL 8.4, MariaDB 11 et
    un stockage S3 ;
  - déploiement : 33 vérifications (dont trois environnements dev → staging → prod,
    et le refus d'un volume encore utilisé par une ancienne installation) ;
  - sous-domaines et nginx-proxy : 24 vérifications ;
  - observabilité : 11 vérifications (dont journaux d'un conteneur privé, hors
    réseau partagé — cas PHP-FPM) ;
  - plateforme complète (Core en production et en staging déployés par
    `deploy.sh` derrière nginx-proxy 1.7, vraies migrations, sauvegarde avant
    migration, routage, isolation des bases, anti-usurpation d'IP, SaaS wildcard,
    audit) : 27 vérifications, soit **129 au total** ;
  - shellcheck sur tous les scripts.
- **Non vérifiable hors du serveur** :
  - l'émission réelle des certificats Let's Encrypt, dont le wildcard DNS-01 ;
  - l'accès au compte MEGA S4 ;
  - le redémarrage de dockerd sous systemd (`apply-daemon-config.sh`) ;
  - la requête crt.sh (bloquée dans l'environnement de développement).

  Chaque guide inclut l'étape de vérification correspondante, à faire sur le
  serveur.
