# 2026-10-06 — Un `git pull` en root dans un clone de projet : fusions locales et fichiers appartenant à root

**Impact** : aucun site touché. Les clones de deux environnements d'un projet contenaient des fichiers de root (dont des fichiers de `.git` sans droit d'écriture pour le groupe) ; un déploiement suivant par le compte du CI aurait pu échouer sur `Permission denied`.
**Détecté par** : vérification après l'opération (`find … ! -user deployer`), avant tout déploiement.

## Ce qui s'est passé

Pour « mettre le code à jour » sur le serveur, un `git pull` a été lancé **en root** dans les deux clones d'un projet. Les clones de `vps-deploy` sont en **HEAD détaché** (l'outil y place la version déployée) : le pull y a créé **trois commits de fusion locaux**, auteur `root`, et laissé 68 et 36 fichiers (dont 29 et 27 dans `.git`) appartenant à root, sans écriture pour le groupe `vpsdeploy`.

## Cause

- La mise à jour du code d'un clone est le travail de `vps-deploy` (`fetch` puis `checkout` du SHA voulu) : l'instruction « faire un pull » était fausse.
- Une commande lancée en root dans un dossier appartenant à un autre compte crée des fichiers appartenant à root ; les ACL par défaut donnent le groupe, pas la propriété ni les bits d'écriture de groupe sur les fichiers de `.git`.

## Correction

En root :

```bash
chown -R deployer:vpsdeploy /app/APPS/<projet>
find /app/APPS/<projet> -type d -exec chmod 2775 {} +
find /app/APPS/<projet> -type f -exec chmod g+rw {} +
setfacl -R -m g:vpsdeploy:rwX /app/APPS/<projet> ; setfacl -R -d -m g:vpsdeploy:rwX /app/APPS/<projet>
sudo -u deployer -H git -C /app/APPS/<projet>/<env> checkout -q --detach origin/<branche>     # retire les fusions locales (récupérables par reflog)
```

Vérifié ensuite : `find /app/APPS/<projet>/<env> \( ! -user deployer -o ! -group vpsdeploy \) | wc -l` → 0, `.git` inscriptible par le groupe, HEAD sur la version publiée.

## Protection pour tous les projets

- **Règle** : dans un clone géré par `vps-deploy`, on ne fait **jamais** `git pull`, `git merge` ni `git commit` ; on déploie (`vps-deploy watch` / `promote`) ou on laisse le pipeline le faire.
- **Règle** : une commande en root dans un dossier de projet se termine par la vérification des propriétaires ci-dessus.
- **Automatique** : `deploy.sh check` (donc `vps-deploy check` et le job de build du pipeline) **refuse** un clone dont un dossier de `.git` n'est pas inscriptible par le compte qui déploie, ou dont des fichiers suivis par git ont été modifiés à la main (`ALLOW_DIRTY_CLONE=1` pour passer outre, consigné) ; il **signale** les commits locaux absents d'origin (un pull ou un merge) et les fichiers appartenant à un autre compte, `.git` compris. Un fichier non suivi (`.env.*`) ne gêne jamais. Test : `tests/test-clone.sh` (15 contrôles ; il échoue quand le contrôle est désactivé).
- **Piège évité en l'écrivant** : les fichiers d'objets de `.git` sont en lecture seule (0444) dans tout clone sain ; un contrôle sur « fichier non inscriptible » aurait refusé **tous** les clones de **tous** les projets. Seuls les **dossiers** comptent. Le test sur un clone propre l'a révélé.

## Reste à faire

- [x] Contrôle automatique dans `check` (fait le 2026-10-06).
- [ ] Le déployer sur le serveur (mise à jour de la plateforme, guide 11) : jusque-là, la règle reste documentaire.
