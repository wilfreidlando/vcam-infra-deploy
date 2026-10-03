# 11. Sortir `infra/` dans son propre dépôt

`infra/` sert tout le serveur, pas seulement le Core. Le mettre dans son propre
dépôt (`vps-platform`) permet de le versionner, de le donner à toute l'équipe et de
le cloner sur le serveur dans `/app/vps-platform`.

## Avec l'historique (recommandé)

Depuis un poste, dans un clone du dépôt du Core :

```bash
git subtree split --prefix=infra -b vps-platform-export     # branche contenant seulement infra/, avec son historique
mkdir ../vps-platform && cd ../vps-platform
git init -b main
git pull ../<dossier du core> vps-platform-export
git remote add origin <url GitLab du nouveau dépôt vps-platform>
git push -u origin main
```

Le nouveau dépôt a `bin/`, `templates/`, `tests/`… **à la racine**. Sur le serveur,
deux options :
- le cloner dans `/app/vps-platform/infra`, pour garder les chemins
  `/app/vps-platform/infra/bin/...` de la documentation ;
- le cloner dans `/app/vps-platform`, puis remplacer `/app/vps-platform/infra/` par
  `/app/vps-platform/` dans les commandes et la ligne cron.

## Ensuite

- **Dans le dépôt du Core** :
  - garder `infra/` tant que `compose.prod.yaml` et le `Makefile` y font référence
    (sauvegarde, `deploy.sh`) ;
  - ou les faire pointer vers `/app/vps-platform` et supprimer `infra/`. Décision à
    prendre quand le dépôt plateforme vivra sa vie.
- **Tests** : `tests/run-all.sh` fonctionne aussi à la racine du nouveau dépôt.
  Seul `test-platform.sh` a besoin du code du Core, qu'il trouve dans le dépôt
  parent ; dans le dépôt séparé, le garder dans le dépôt du Core.
