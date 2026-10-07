# Supervision et incidents

> Ce qu'on surveille, et quoi faire en cas d'incident. Une page par situation : [runbooks](../runbooks/README.md).
> Retour au [sommaire de la documentation](../README.md).

## Supervision

- **Backends** : brancher l'observabilité mutualisée ([`observability/README.md`](../../observability/README.md)).
  Journaux de tous les projets dans Grafana → *Applications*.
- **Frontends** : pas d'observabilité serveur. La surveillance externe suffit.
- **Surveillance externe (indispensable)** : un service gratuit hors du serveur
  (UptimeRobot, Better Stack) appelle chaque site de production toutes les minutes et
  alerte par e-mail ou SMS. Grafana tourne sur le même serveur : il ne peut pas
  prévenir si le serveur entier tombe.

## Incidents — quoi faire

| Symptôme | Action |
| --- | --- |
| Un site ne répond plus après un déploiement | `vps-deploy rollback prod` dans son checkout prod |
| Un site ne répond plus sans déploiement | `vps-deploy status`, puis `docker compose -p <projet>-prod logs --tail 200 app` ; Grafana → Applications |
| Erreur 502 de nginx-proxy | Le conteneur web du projet est arrêté ou en échec : `docker ps -a \| grep <projet>` |
| Disque plein | `vps-audit.sh` (constats journaux), `docker system df`, `docker image prune -f`, `docker builder prune -f` |
| Données corrompues ou supprimées | `bin/restore.sh prod <sauvegarde>` (la dernière sauvegarde : nocturne, ou prise à la main avant une migration) |
| `deploy.sh` refuse avec « contrôle avant déploiement en échec » | Rien n'a été modifié. Lire les lignes au-dessus, corriger dans le dépôt, vérifier avec `vps-deploy check <env>`, pousser |
| `Connection refused` vers la base pendant les migrations, toujours la même adresse IP | Le nom de la base mène à un **autre** projet : `vps-deploy check <env>` le confirme ([REX](../retours-experience/2026-10-04-premier-deploiement-skills-devops.md)) |
| Tous les sites tombés | `systemctl status docker` ; `docker ps -a` ; redémarrer nginx-proxy en premier : `cd /app/nginx-proxy-conf && docker compose up -d` |
