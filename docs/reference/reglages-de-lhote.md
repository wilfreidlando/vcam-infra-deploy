# Réglages de l'hôte

> Ce qui se règle une fois sur le serveur lui-même (journaux Docker, pare-feu, mises à jour, SSH).
> Retour au [sommaire de la documentation](../README.md).


- **Rotation des journaux et live-restore pour tous les conteneurs** :
  `host/apply-daemon-config.sh`. Le script :
  1. fusionne avec la configuration existante, sans rien écraser ;
  2. la valide ;
  3. active live-restore **avant** de redémarrer Docker, pour que les conteneurs
     continuent de tourner pendant le redémarrage.

  À lancer de préférence en heure creuse : une interruption réseau de quelques
  secondes reste possible. La rotation s'applique aux conteneurs recréés ensuite.
- **Commandes courtes** : `host/install-commands.sh` installe dans le `PATH` `vps` (l'aide : comment on déploie), `vps-deploy`, `vps-restore`, `vps-audit`, `vps-inventory`, `vps-hosts`, `vps-obs-bundle`, `vps-fingerprint`, `vps-overview` (quelle version tourne où) et `vps-daemon-config`, pour ne plus taper le chemin de la plateforme
  ([ADR-0069](../adr/0069-commandes-courtes-et-branches-declarees-par-le-projet.md)). Un chemin raté donne un message clair (code 127) ; `vps where` dit où est la plateforme et quelle version ([guide 3](../../guides/03-installer-plateforme.md#étape-1--cloner-la-plateforme)).
- **Pare-feu** : `ufw` n'ouvre que 22, 80 et 443. Rappel : il ne protège pas les
  ports publiés par Docker (règle 1).
- **Mises à jour de sécurité automatiques** : `apt install unattended-upgrades`.
- **SSH** : connexion par clé uniquement (`PasswordAuthentication no`), `fail2ban`.
- **Nettoyage** : `docker image prune -f` hebdomadaire. `deploy.sh` garde déjà
  seulement les 5 dernières images de chaque projet.
