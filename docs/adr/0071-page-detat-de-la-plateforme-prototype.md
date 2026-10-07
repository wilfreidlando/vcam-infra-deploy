# ADR-0071 — Une page d'état de la plateforme, en consultation seule (prototype sans authentification)

- **Statut** : **Proposé (prototype)** — à encadrer avant d'être gardée.
- **Date** : 2026-10-07
- **Décideurs** : responsable de la plateforme

## Contexte

Savoir « quelle version tourne où » demande aujourd'hui un terminal sur le serveur (`vps-deploy status` dans chaque projet) ou de lire les pipelines. Les développeurs et le responsable veulent **une page** de consultation, rien de plus. Une console qui agit (déployer, restaurer) a été écartée : plus d'effort, et la page deviendrait une porte d'entrée vers le serveur.

## Décision

1. **Une page statique en lecture seule**, générée par `vps-overview` (`bin/vps-overview.py`, commande courte, aussi utilisable en terminal) à partir de l'état de `deploy.sh` et de Docker, servie par un nginx sans privilège (`overview/`). Aucun code applicatif ne tourne côté serveur web, aucun accès à Docker depuis le conteneur.
2. **Aucun secret n'en sort** : l'outil ne publie que des champs choisis (projet, environnement, version, branche, santé, noms publics, dates). Les variables d'un conteneur sont lues en mémoire pour y prendre la seule `VIRTUAL_HOST` ; un test plante des secrets et vérifie qu'ils n'apparaissent nulle part.
3. **Régénérée chaque minute** par une minuterie systemd (compte `deployer`). La page dit quand elle a été générée.
4. **PROTOTYPE SANS AUTHENTIFICATION** : décision du responsable (2026-10-07) pour voir avant de cadrer. Les mesures prises : `noindex`, pas de cache, méthodes GET/HEAD seulement, CSP sans script, conteneur en lecture seule sans capacité.

## Conséquences

- **Exposition** : toute personne qui connaît l'adresse voit les noms de projets et de domaines, les versions déployées et la santé des conteneurs. Pas de secret, mais une carte de l'infrastructure. **À trancher avant de la garder** : mot de passe d'équipe (authentification de base de nginx-proxy), compte Grafana, ou accès restreint par adresse.
- **Périmètre** : seuls les projets déployés par `deploy.sh` apparaissent (l'état en vient). Pas d'alertes en cours dans cette version.
- **Coût** : un conteneur de 64 Mo, une minuterie, une commande de plus (la dixième).
- **Non vérifié** : la minuterie sur le vrai serveur (durcissement systemd, accès à la socket Docker) et le passage derrière le vrai nginx-proxy ; la page et son service web sont testés ici sur de vrais conteneurs, la minuterie non.
- **Suite possible** : authentification, alertes en cours, historique des déploiements. Aucune action (déployer, restaurer) n'est prévue : ce serait une autre décision.
