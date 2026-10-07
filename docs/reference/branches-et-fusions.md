# Les branches d'un projet : les choisir, les changer, fusionner sans rien perdre

> Le projet **choisit** ses branches ; la plateforme n'en impose aucune. Cette page dit comment les déclarer, comment les changer **sans casser un déploiement**, et comment fusionner
> sans perdre de contenu : un piège de fusion est silencieux, et dure. Retour au [sommaire](../README.md) ; le tableau des environnements : [déployer selon la situation](deployer-selon-la-situation.md#les-branches--le-projet-choisit-la-plateforme-nimpose-rien).

## 1. Où une branche est déclarée

| Où | Clé ou règle | Rôle |
| --- | --- | --- |
| `platform.env` | `BRANCH_<ENV>` du staging (ex. `BRANCH_STAGING=develop`) | la branche que `vps-deploy watch` suit et construit |
| `platform.env` | `BRANCH_<PROD>` d'une production (ex. `BRANCH_PROD=main`) | une **garde** : `promote` refuse une version qui n'est pas **déjà dans** `origin/<branche>`. Elle ne change pas ce qui est construit, seulement ce qui peut partir en production |
| `.gitlab-ci.yml` | `$CI_COMMIT_BRANCH == "…"` de chaque job | la branche sur laquelle le pipeline tourne ([pipeline GitLab](pipeline-gitlab.md)) |

Ces déclarations doivent **dire la même chose**. Le modèle de pipeline est testé pour cela (`tests/test-gitlab-ci.sh`) ; le contrôle de `vps-deploy check <env>` affiche la branche suivie par chaque environnement.

## 2. Les modèles courants

| Modèle | `BRANCH_STAGING` | `BRANCH_PROD` | Flux |
| --- | --- | --- | --- |
| **Standard** | `develop` | `main` | push sur `develop` → staging automatique → recette → **fusion dans `main`** → promotion de **la même image** |
| Une seule branche | `main` | `main` (ou aucune garde) | tout ce qui est poussé arrive en staging ; la production n'a plus de garde : n'importe quelle version du staging peut partir |
| Production seule ([profil B](profils-de-projet.md)) | — | `main` | `promote` construit la branche sur place ; rien n'a été essayé avant : à compenser (tests, `check`, hors heures d'activité) |
| Plusieurs productions ([profil C](profils-de-projet.md)) | `develop` | une branche par production (`main`, `release`…) | chaque production a sa garde ; aucune ne dépend d'une autre |

## 3. Changer les branches d'un projet : l'ordre compte

1. **Mettre d'abord le contenu sur la nouvelle branche.** Si le staging doit suivre `develop`, `develop` doit contenir tout ce qui tourne aujourd'hui : sinon le staging **revient en arrière** au premier déploiement. Pour une garde `main` : `main` doit contenir la version à promouvoir, sinon la promotion est refusée (c'est son rôle).
2. **Changer `platform.env` et le `.gitlab-ci.yml` ensemble, dans le dépôt**, dans le même commit, avec le test du pipeline. **Jamais en éditant `platform.env` sur le serveur** : c'est un fichier suivi par git, `vps-deploy check` refuse un clone modifié à la main.
3. **La garde est lue dans la version déployée.** Un commit qui change `BRANCH_PROD` ne s'applique à la production qu'une fois **déployé** sur elle ; d'ici là elle garde l'ancienne garde. Ne pas promouvoir juste pour « l'activer » (cela recrée les conteneurs pour rien) : elle s'active à la prochaine vraie version.
4. **Protéger les branches dans GitLab** : `main` devient une garde de production, sa fusion doit être réservée aux mainteneurs.
5. **Prévenir les autres contributeurs** : une branche qui change de rôle change leur façon de travailler.

## 4. Fusionner sans perdre de contenu

### Le piège de la fusion qui ne change rien
Une fusion résolue en gardant « notre » version de tous les fichiers (`git merge -s ours`, ou « garder le courant » partout dans un éditeur) **ajoute un commit de fusion sans apporter le moindre contenu**. L'historique prétend alors que l'autre branche est intégrée : **une prochaine fusion ne ramènera jamais ce contenu**.

Le reconnaître : une fusion normale change des fichiers par rapport à son premier parent.
```bash
git diff --name-only <fusion>^1 <fusion>      # aucun fichier = la fusion n'a rien apporté
git diff --name-only <branche-source> <fusion> # les fichiers que la source a et que la fusion n'a pas
```
Le réparer **sans réécrire l'historique** : reprendre le contenu de la source dans un **nouveau** commit.
```bash
git checkout <branche-destination>
git restore --source=<branche-source> --staged --worktree <fichiers…>     # ou « . » pour tout reprendre
git commit -m "fix : reprendre le contenu perdu par la fusion <sha>"
```

### Répéter une fusion sans toucher à son dépôt
Un espace de travail séparé permet de **voir le résultat avant** : conflits, fichiers obtenus, tests.
```bash
git worktree add --detach /tmp/essai origin/<destination>
cd /tmp/essai && git merge --no-commit --no-ff origin/<source>      # conflits ? lister : git diff --name-only --diff-filter=U
git diff --cached --stat origin/<source>                            # vide = le résultat est le contenu de la source
git merge --abort; cd - && git worktree remove --force /tmp/essai
```

### Faire d'une branche l'exact contenu d'une autre (ex. `main` = `develop`)
Quand `main` n'a rien d'unique à garder (ses seuls commits propres sont des fusions) : fusionner **avec priorité à la source**, puis forcer l'identité du contenu, en gardant les deux parents.
```bash
git checkout main
git merge --no-commit --no-ff -X theirs origin/develop      # « theirs » = la branche fusionnée
git restore --source=origin/develop --staged --worktree .   # le contenu devient exactement celui de develop
git diff --cached --stat origin/develop                     # doit être vide
git commit -m "Merge branch 'develop' into 'main'"
```
**Avant de le faire, lister ce que la destination a en propre** : `git log --oneline origin/<source>..origin/<destination>` et `git diff <ancêtre-commun> origin/<destination>`. S'il y a du contenu à garder, ne pas utiliser cette séquence : fusionner la destination **dans** la source d'abord.

### Un `pull` ou un `checkout` refusé
`Your local changes would be overwritten by checkout` : des modifications non commitées empêchent le changement de branche. Les regarder (`git status`, `git diff --cached`) **avant** de les écarter : si elles sont identiques à un commit existant (`git diff --cached <commit> -- <fichiers>` vide), les écarter est sans risque (`git restore --staged --worktree .`).

## 5. Déployer une version sans passer par le staging

| Situation | Comment | Ce qu'on perd |
| --- | --- | --- |
| Projet **sans** staging (profil B) | `vps-deploy promote origin/<branche>` : l'image est construite sur place | tout essai préalable : le dire dans la fiche du projet |
| Projet **avec** staging, correctif urgent d'une version déjà dans la branche de production | dans le clone du staging `vps-deploy build <sha> staging` (construit sans déployer), puis dans le clone de production `vps-deploy promote <sha> --env prod -y` | la recette et l'essai des migrations : elles tournent directement sur les vraies données, et **ne sont pas annulées** par un retour automatique |
| Projet avec staging, sans image préalable | refusé : « images absentes — lancer d'abord `vps-deploy build` » | — la production ne construit jamais quand un staging existe |

En règle : **passer par le staging coûte une à deux minutes** (le build est en cache, le déploiement du staging ne touche aucun utilisateur). La voie directe est réservée au cas où le staging lui-même est en panne.
