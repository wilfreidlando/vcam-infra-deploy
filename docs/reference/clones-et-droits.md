# Les clones de projet sur le serveur : à qui ils sont, ce qu'on y fait, ce qu'on n'y fait jamais

> Chaque environnement d'un projet vit dans **un clone Git** géré par `vps-deploy`. Cette page dit comment le mettre en place, qui le possède, et ce qui le casse.
> Retour au [sommaire](../README.md). Le retour d'expérience qui l'a motivée : [`git pull` en root dans un clone](../retours-experience/2026-10-06-git-pull-en-root-dans-un-clone.md).

## 1. Ce qu'est un clone

```
/app/APPS/<projet>/staging      un clone Git, avec son .env.staging (jamais commité)
/app/APPS/<projet>/prod         un clone Git, avec son .env.prod
/var/lib/vps-platform/<projet>  l'état du déploiement : version courante, précédente, historique, journal deploy.log
```
`vps-deploy` fait lui-même `git fetch`, puis place le clone **en HEAD détaché** sur la version à déployer. C'est son travail, pas celui d'une personne : un clone n'est jamais « à jour » au sens d'un `git pull`, il est **sur la version déployée**.

## 2. Ce qu'on n'y fait jamais

| Interdit | Conséquence |
| --- | --- |
| `git pull`, `git merge`, `git commit`, `git checkout <branche>` | des fusions locales sur un HEAD détaché, ignorées au déploiement suivant ; **en root**, des fichiers appartenant à root (voir § 4) |
| Modifier un fichier suivi par git (`platform.env`, un script, un compose) | l'image construite ne correspondrait plus au commit publié : `vps-deploy check` **refuse** |
| Une commande en root dans le dossier sans vérifier ensuite les propriétaires | un `Permission denied` au prochain déploiement, par le compte de déploiement ou le pipeline |

Les fichiers **non suivis** (`.env.<env>`) ne gênent jamais le contrôle.

## 3. Mettre en place un clone (une fois par environnement)

En **root** (dossiers et droits ; `deployer` et `vpsdeploy` sont, sur ce serveur, le compte et le groupe de déploiement) :
```bash
mkdir -p /app/APPS/<projet> /var/lib/vps-platform/<projet>
chown -R deployer:vpsdeploy /app/APPS/<projet> /var/lib/vps-platform/<projet>
chmod 2775 /app/APPS/<projet> /var/lib/vps-platform/<projet>                  # setgid : tout nouveau fichier reste au groupe
setfacl -R -m g:vpsdeploy:rwX /app/APPS/<projet> /var/lib/vps-platform/<projet>
setfacl -R -d -m g:vpsdeploy:rwX /app/APPS/<projet> /var/lib/vps-platform/<projet>
for e in staging prod; do git config --system --add safe.directory /app/APPS/<projet>/$e; done     # sinon Git refuse un dossier d'un autre propriétaire
```
Puis, **avec le compte de déploiement** (qui seul a la clé du dépôt : une clé de déploiement activée sur le projet GitLab) :
```bash
sudo -u deployer -H sh -c 'cd /app/APPS/<projet> && git clone -b <branche> git@gitlab.com:<groupe>/<projet>.git staging'   # idem pour prod
```
Enfin le fichier d'environnement de chaque clone : `scripts/make-env.py` ([modèle](../../templates/scripts/README.md)) ou la copie du modèle `.env.<env>.example`, **avec des secrets différents par environnement** ; droits `660`.

## 4. Ce que fait le contrôle d'intégrité (`vps-deploy check`)

| Constat | Réaction | Pourquoi |
| --- | --- | --- |
| Un **dossier** de `.git` que le compte ne peut pas écrire | **refusé**, avec la commande de réparation | git ne peut plus y ajouter d'objets ni de références. Seuls les *dossiers* comptent : les fichiers d'objets sont en lecture seule (0444) dans tout clone sain |
| Des fichiers **suivis** modifiés à la main | **refusé** ; `ALLOW_DIRTY_CLONE=1` laisse passer, à ses risques | l'image ne correspondrait plus au commit |
| Des commits locaux absents de tout dépôt distant | **signalé** | ils seront ignorés : le déploiement replace la tête sur la version publiée |
| Des fichiers d'un autre compte que le propriétaire du dossier, `.git` compris | **signalé** | normal pour des données de conteneurs, suspect pour du code ou `.git` |

## 5. Réparer après une commande en root

Vérifier d'abord : aucun fichier hors du compte de déploiement, `.git` compris.
```bash
find /app/APPS/<projet> \( ! -user deployer -o ! -group vpsdeploy \) | wc -l       # doit répondre 0
```
Sinon, en root :
```bash
chown -R deployer:vpsdeploy /app/APPS/<projet>
find /app/APPS/<projet> -type d -exec chmod 2775 {} +
find /app/APPS/<projet> -type f -exec chmod g+rw {} +
setfacl -R -m g:vpsdeploy:rwX /app/APPS/<projet> ; setfacl -R -d -m g:vpsdeploy:rwX /app/APPS/<projet>
# annuler une modification manuelle d'un fichier suivi, et retirer les fusions locales (récupérables par « git reflog ») :
sudo -u deployer -H git -C /app/APPS/<projet>/<env> checkout -- <fichier>
sudo -u deployer -H git -C /app/APPS/<projet>/<env> checkout -q --detach origin/<branche>
```
Les fichiers d'environnement restent à `660` : le `chmod g+rw` ne les élargit pas.

## 6. Mettre à jour le code d'un environnement

**Jamais** par un `pull` : par un déploiement. `vps-deploy watch <env>` (staging), `vps-deploy promote --env <env>` (production), ou le pipeline. Voir [déployer selon la situation](deployer-selon-la-situation.md).
