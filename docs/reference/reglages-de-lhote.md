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
- **Pare-feu** : `ufw` n'ouvre que 22, 80 et 443. Rappel : il ne protège pas les
  ports publiés par Docker (règle 1).
- **Mises à jour de sécurité automatiques** : `apt install unattended-upgrades`.
- **SSH** : connexion par clé uniquement (`PasswordAuthentication no`), `fail2ban`.
- **Nettoyage** : `docker image prune -f` hebdomadaire. `deploy.sh` garde déjà
  seulement les 5 dernières images de chaque projet.
