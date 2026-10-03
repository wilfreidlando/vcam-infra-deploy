# 8. Surveillance externe

Grafana tourne **sur** le serveur : si le serveur tombe, il ne peut prévenir
personne. Il faut un œil extérieur. Les offres gratuites suffisent.

## Avec UptimeRobot (gratuit, 50 sondes, contrôle toutes les 5 minutes)

**1. Créer le compte**
Sur https://uptimerobot.com → **Register for FREE**, avec une adresse e-mail
d'équipe (pas personnelle), puis confirmer l'e-mail reçu.

**2. Dire qui prévenir**
Menu de gauche → **Integrations & Team** (ou *My Settings → Alert Contacts* selon la
version) :
- ajouter les e-mails des personnes d'astreinte ;
- installer l'application mobile **UptimeRobot** sur leur téléphone et s'y connecter :
  les alertes arrivent alors en notification ;
- Telegram ou Slack sont aussi proposés, si l'équipe les utilise.

**3. Créer une sonde par site de production**
Bouton **+ New monitor**, puis pour chaque ligne du tableau :

| Monitor type | URL | Mot-clé (keyword) | Friendly name |
| --- | --- | --- | --- |
| **Keyword** | `https://core-system.visibilitycam.com/health/ready` | `ready` — alerte si **absent** (*Alert when keyword does not exist*) | `Core — prod` |
| **HTTP(s)** | `https://cpf.visibilitycam.com/up` | — | `WILMANAGER — prod` |
| **HTTP(s)** | `https://grafana.visibilitycam.com/api/health` | — | `Grafana` |
| **HTTP(s)** | `https://<chaque autre site>/` (ou sa route de santé) | — | `<nom du site>` |

Pour chaque sonde :
- **Monitoring interval** : 5 minutes (offre gratuite) ;
- cocher les contacts de l'étape 2 dans *Alert contacts to notify* (ou *How will we
  notify you?*) ;
- **Create monitor**.

**4. Expiration des certificats**
Dans la sonde (*Edit* → onglet ou section **SSL**), activer les rappels d'expiration
du certificat, s'ils sont proposés dans votre offre. Sinon, acme-companion renouvelle
30 jours avant l'échéance, et une sonde HTTPS en échec vous préviendra de toute façon.

**5. Tester l'alerte une fois**
Créer une sonde temporaire vers `https://nexistepas-test.visibilitycam.com/` : elle
doit passer **Down** (503) et envoyer une alerte en moins de 10 minutes. Supprimer
ensuite cette sonde (*Edit* → **Delete**).

Le mot-clé `ready` est important. `/health/ready` répond `degraded` (code 503) quand
la base ou Valkey ne répondent plus : on est alerté même si le serveur web tourne
encore.

## Alternative : Better Stack (betterstack.com)

Même principe. Les sondes sont plus fréquentes dans l'offre gratuite, et une page de
statut publique est possible.

## Ne pas surveiller

Les **staging** : leurs coupures pendant les déploiements génèreraient des alertes
inutiles.
