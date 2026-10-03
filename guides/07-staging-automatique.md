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
*/2 * * * * cd /app/core-system/staging && /app/vps-platform/infra/bin/deploy.sh watch >> /var/log/vps-deploy.log 2>&1
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
*/2 * * * * cd /app/mon-projet/dev && /app/vps-platform/infra/bin/deploy.sh watch dev >> /var/log/vps-deploy.log 2>&1
```

`deploy.sh watch prod` est refusé : la production ne se déploie que par
`deploy.sh promote`, avec l'image déjà validée en staging.

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

## Plus tard : GitLab CI

Quand le projet sera sur GitLab, le runner déjà installé sur le serveur remplace la
ligne cron. Le job est dans `infra/README.md` § 5 : un bouton manuel pour la
production, automatique pour le staging. **Supprimer alors la ligne cron**, pour ne
pas avoir deux déclencheurs.

Le runner doit être de type `shell` et tourner sur ce serveur, avec le droit
d'utiliser Docker : `usermod -aG docker gitlab-runner`. Il faut aussi que
`gitlab-runner` puisse écrire dans `/var/lib/vps-platform` et dans les dossiers
`/app/<projet>`.
