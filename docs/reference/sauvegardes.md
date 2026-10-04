# Sauvegardes

> L'agent de sauvegarde, sa fréquence, et le test de restauration mensuel. Pas à pas : [guide 4](../../guides/04-sauvegardes-mega-s4.md) et [agent `db-backup`](../../images/db-backup/README.md).
> Retour au [sommaire de la documentation](../README.md).


L'agent [`images/db-backup`](../../images/db-backup/README.md) tourne dans chaque projet
qui a une base de données :
- dump chaque nuit, chiffré AES-256 avec une phrase de passe propre au projet ;
- 7 copies sur le serveur ;
- copie sur MEGA S4, gardée 30 jours.

`deploy.sh promote` en prend une juste avant les migrations, et **refuse de
déployer** si elle échoue.

**Test de restauration mensuel**, obligatoire pour qu'une sauvegarde compte :

```bash
# 1. télécharger la dernière sauvegarde de production depuis MEGA, puis :
docker cp <fichier>.dump.enc "$(docker ps -q -f label=com.docker.compose.project=<projet>-staging -f label=com.docker.compose.service=backup)":/backups/
# 2. restaurer dans le staging, avec la phrase de passe de PRODUCTION donnée
#    ponctuellement (jamais écrite dans .env.staging) :
cd /app/<projet>/staging
read -rs RESTORE_PASSPHRASE && export RESTORE_PASSPHRASE
/app/vps-platform/bin/restore.sh staging <fichier>.dump.enc
```

Cela restaure la production dans le staging. Attention aux données personnelles : le
staging contient alors des données réelles. Le réinitialiser ensuite si besoin.
