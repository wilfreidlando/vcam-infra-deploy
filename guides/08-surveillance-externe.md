# 8. Surveillance externe

Grafana tourne **sur** le serveur : si le serveur tombe, il ne peut prévenir
personne. Il faut un œil extérieur. Les offres gratuites suffisent.

## Avec UptimeRobot (gratuit, 50 sondes, contrôle toutes les 5 minutes)

1. Créer un compte sur uptimerobot.com.
2. *My Settings → Alert Contacts* : ajouter vos e-mails et, si possible, l'appli
   mobile, pour les notifications push.
3. *Add New Monitor*, une sonde par site de **production** :

| Type | URL | Mot-clé attendu |
| --- | --- | --- |
| HTTP(s) – Keyword | `https://core-system.visibilitycam.com/health/ready` | `ready` |
| HTTP(s) | `https://grafana.visibilitycam.com/api/health` | — |
| HTTP(s) | `https://<chaque autre site>/` (ou sa route de santé) | — |

4. Activer l'alerte d'**expiration de certificat SSL**, si l'offre la propose.

Le mot-clé `ready` est important. `/health/ready` répond `degraded` (code 503) quand
la base ou Valkey ne répondent plus : on est alerté même si le serveur web tourne
encore.

## Alternative : Better Stack (betterstack.com)

Même principe. Les sondes sont plus fréquentes dans l'offre gratuite, et une page de
statut publique est possible.

## Ne pas surveiller

Les **staging** : leurs coupures pendant les déploiements génèreraient des alertes
inutiles.
