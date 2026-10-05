# ADR-0069 — Des commandes sans chemin, des branches déclarées par chaque projet, une promotion encadrée

- **Statut** : Accepté — complète ADR-0064 (standard d'hébergement) et ADR-0067 (profils de projet)
- **Date** : 2026-10-05
- **Décideurs** : responsable de la plateforme, sur demande de la direction technique

## Contexte

Deux faiblesses ressortent de l'usage du standard :

1. **Le chemin.** Déployer demandait de taper `/app/vps-platform/bin/deploy.sh` : un chemin raté, un dossier déplacé, et « No such file or directory », sans dire quoi faire. C'est le **couplage** entre un projet et la plateforme.
2. **Les branches.** `deploy.sh` savait suivre une branche pour le staging (`STAGING_BRANCH`), mais rien n'encadrait le passage en production : on pouvait promouvoir une version jamais fusionnée dans la branche de production du projet.
   Et un projet sans staging devait appeler son unique branche `STAGING_BRANCH`, ce qui trompe. Les équipes n'ont pas toutes le même flux (`develop` puis `main`, ou `main` partout, ou une production seule).

## Décision

### 1. Une commande par script, utilisable depuis n'importe quel dossier

`host/install-commands.sh` (une fois, en root) installe dans le `PATH` : `vps`, `vps-deploy`, `vps-restore`, `vps-audit`, `vps-inventory`, `vps-hosts`, `vps-obs-bundle`, `vps-daemon-config`.

- Chaque commande est un **petit script** (pas un lien symbolique) : si la plateforme est introuvable, il le **dit** en clair, avec le dossier cherché et comment corriger (code 127), au lieu de « No such file ».
- `VPS_PLATFORM_DIR=<dossier>` pointe une plateforme déplacée ; relancer l'installateur depuis le nouveau dossier réécrit les commandes. L'installateur **n'écrase jamais** un fichier qui n'est pas à lui.
- **`vps`, sans argument, dit comment on déploie** : c'est le moyen de voir, sur n'importe quel serveur, que la plateforme déploie ainsi, simplement. `vps where` (ou `vps-deploy where`) dit où elle est et quelle version.
- Les scripts résolvent leur propre emplacement **à travers les liens symboliques** : un lien dans le `PATH` ne les fait plus chercher la plateforme au mauvais endroit.
- Le `Makefile` du Core vérifie le chemin **avant** toute action.

### 2. Chaque projet déclare ses branches ; la plateforme n'en impose aucune

- `BRANCH_<ENV>` pour chaque environnement non production (`BRANCH_STAGING`, ancien nom `STAGING_BRANCH`).
- `BRANCH_<PROD>` (par exemple `BRANCH_PROD=main`) est une **garde optionnelle** : `deploy.sh promote` refuse une version qui n'est pas déjà **contenue dans `origin/<branche>`** (`git merge-base --is-ancestor`). Sans cette variable, aucune contrainte.
  Chaque production a sa branche (`BRANCH_PRODEU=release`).
- **Sans staging** (`ENVIRONMENTS=prod`), `BRANCH_PROD` est la branche que `promote` construit quand on ne donne pas de version.
- Une exception ponctuelle existe, **explicite et consignée** : `SKIP_BRANCH_CHECK=1`, avec l'accord du responsable.

### 3. Le passage staging → production réutilise l'image du staging

La production reçoit **l'image exacte** construite pour le staging (étiquette = commit) ; si elle manque, `promote` **refuse** au lieu de reconstruire. Le journal l'écrit : « même image que staging : rien n'est reconstruit ».
`BUILD_PER_ENV=1` (front dont l'image intègre la configuration de l'environnement) est la seule exception, **annoncée** dans le journal. `deploy.sh status` et `deploy.sh check` disent la branche suivie par chaque environnement.

## Conséquences

- Un nouveau projet choisit son flux dans `platform.env`, sans toucher à la plateforme.
- La garde ne vaut que si le projet la déclare : un projet qui promeut ce que son staging a validé, sans passer par une branche de production, continue comme avant.
- Les commandes demandent **une installation par serveur** (`host/install-commands.sh`) ; les chemins complets restent valables.
- Tests : `tests/test-commands.sh` (chemin juste, chemin raté, lien symbolique, refus d'écraser) et `tests/test-branches.sh` (garde, exception, plusieurs productions, production sans staging, même image).

## Ce qui n'est pas fait

- Pas d'épinglage de la version de la plateforme par projet : un projet ne déclare pas avec quelle version de la plateforme il est compatible, et `deploy.sh` ne le contrôle pas.
- La garde ne dit pas **qui** a fusionné ni quand : elle vérifie seulement l'appartenance du commit à la branche.
