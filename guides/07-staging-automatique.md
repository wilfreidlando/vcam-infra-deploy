# 7. Staging automatique

**Objectif** : chaque commit poussé sur `main` est construit et déployé en staging
dans les 2 minutes, sans intervention. La production reste **manuelle** (guide 6,
`make prod-promote`).

## En attendant GitLab CI : une ligne cron par projet

```bash
$ crontab -e
```

Ajouter, pour le Core (une ligne par projet suivant le standard) :

```cron
*/2 * * * * cd /app/core-system/staging && /app/vps-platform/bin/deploy.sh watch >> /var/log/vps-deploy.log 2>&1
```

Ce que fait `watch` à chaque passage :
- **`main` n'a pas bougé** : il s'arrête aussitôt.
- **Nouveau commit** : build de l'image, contrôle des sous-domaines, migrations,
  démarrage, contrôle de santé. En cas d'échec, retour automatique à la version
  précédente.
- **Commit déjà en échec** (santé KO, collision de nom) : il n'insiste pas et
  attend le commit suivant.
- **Un déploiement est déjà en cours** : il sort sans rien faire (verrou).

## Un environnement `dev` en plus (facultatif)

Un projet peut avoir plus que staging et prod, par exemple un `dev` qui suit la
branche `develop`. Dans son `platform.env` :

```bash
ENVIRONMENTS="dev staging prod"
BRANCH_DEV=develop          # branche suivie par « watch dev »
ENV_FILE_DEV=.env.dev       # valeur par défaut
```

Puis un clone de plus (`/app/mon-projet/dev`) et une ligne cron de plus :

```cron
*/2 * * * * cd /app/mon-projet/dev && /app/vps-platform/bin/deploy.sh watch dev >> /var/log/vps-deploy.log 2>&1
```

`vps-deploy watch prod` est refusé : la production ne se déploie que par
`vps-deploy promote`, avec l'image déjà validée en staging.

## Vérifier

```bash
$ tail -f /var/log/vps-deploy.log                         # le journal des passages
$ cat /var/lib/vps-platform/core-system/deploy.log        # l'historique détaillé des déploiements
$ cd /app/core-system/staging && make deploy-status
```

Faire un commit de test sur `main`, puis attendre 2 minutes : `make deploy-status`
doit montrer le nouveau SHA en staging.

## Rotation du journal cron

```bash
$ cat > /etc/logrotate.d/vps-deploy <<'CONF'
/var/log/vps-deploy.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
}
CONF
```

## Avec GitLab CI (recommandé quand le projet est sur GitLab)

Le pipeline remplace la ligne cron : un push sur la branche du staging construit et déploie le staging, un **bouton** met en production (jamais automatique). **Supprimer alors la
ligne cron**, pour ne pas avoir deux déclencheurs.

- **Le modèle** : [`templates/gitlab-ci/`](../templates/gitlab-ci/README.md) (profil A : staging puis production ; profil B : production seule), testé.
- **Le runner** : un runner à exécuteur **SSH** qui se connecte au serveur avec le compte de déploiement, **sans** les jobs sans tag, avec le tag du projet. Ce n'est pas un runner « shell » de `gitlab-runner`
  ni un compte `gitlab-runner` ajouté au groupe `docker` : c'est le compte de déploiement qui exécute `vps-deploy`, avec son accès au dépôt. La procédure, les pièges et ce qui le bloque :
  [le pipeline GitLab d'un projet](../docs/reference/pipeline-gitlab.md), et le [runbook](../docs/runbooks/runner-gitlab-hors-service.md) quand un job reste « pending ».
- **Les clones** de chaque environnement, leurs droits et ce qu'on n'y fait jamais : [clones et droits](../docs/reference/clones-et-droits.md).
