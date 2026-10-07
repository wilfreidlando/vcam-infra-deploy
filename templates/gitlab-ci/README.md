# Modèles de pipeline GitLab

> Le `.gitlab-ci.yml` d'un projet, prêt à copier, **testé** (`tests/test-gitlab-ci.sh`). Un pipeline qui déploie sur le serveur n'est pas un pipeline ordinaire :
> `deploy.sh` ne reprend pas une opération interrompue, la production ne doit jamais partir toute seule, et le runner est **le serveur lui-même**. Ces modèles
> en tirent les conséquences. Les raisons, une par une : [référence « Le pipeline GitLab d'un projet »](../../docs/reference/pipeline-gitlab.md). Retour aux [modèles](../README.md).

## 1. Lequel prendre ?

| Mon projet a… | Je copie | Profil ([profils de projet](../../docs/reference/profils-de-projet.md)) |
| --- | --- | --- |
| un staging **puis** une production | [`profil-a-staging-puis-production.gitlab-ci.yml`](profil-a-staging-puis-production.gitlab-ci.yml) | A, et C pour plusieurs productions (voir § 4) |
| **seulement** une production | [`profil-b-production-seule.gitlab-ci.yml`](profil-b-production-seule.gitlab-ci.yml) | B |
| un simple site sans base | le profil B convient ; ou aucun pipeline : `deploy.sh promote` à la main | D |

## 2. Remplacer les jetons

Chaque `<JETON>` du modèle est à remplacer **partout**. Le test refuse un modèle où il en reste un.

| Jeton | À mettre | Exemple |
| --- | --- | --- |
| `<PROJET>` | le nom du projet (`APP_NAME` de `platform.env`) ; sert à nommer les verrous | `monprojet` |
| `<BRANCHE_STAGING>` | la branche que le staging suit (`BRANCH_STAGING` de `platform.env`) ; le pipeline tourne sur elle | `develop` |
| `<BRANCHE_PROD>` | la branche que la production n'accepte qu'une fois fusionnée (`BRANCH_PROD`) | `main` |
| `<TAG_RUNNER>` | le tag du runner SSH du serveur, **jamais** celui d'un runner partagé de GitLab | `runner-monprojet` |
| `<DOSSIER_DU_PROJET>` | le dossier du projet sur le serveur : il contient les clones `staging/` et `prod/` | `/app/APPS/monprojet` |
| `<URL_STAGING>` | l'adresse du staging (affichée dans GitLab, *Operate → Environments*) | `https://dev.monprojet.example` |
| `<URL_PROD>` | l'adresse de la production | `https://monprojet.example` |

```bash
sed -e 's#<PROJET>#monprojet#g' -e 's#<BRANCHE_STAGING>#develop#g' -e 's#<BRANCHE_PROD>#main#g' -e 's#<TAG_RUNNER>#runner-monprojet#g' \
    -e 's#<DOSSIER_DU_PROJET>#/app/APPS/monprojet#g' -e 's#<URL_STAGING>#https://dev.monprojet.example#g' -e 's#<URL_PROD>#https://monprojet.example#g' \
    profil-a-staging-puis-production.gitlab-ci.yml > ../../../mon-projet/.gitlab-ci.yml
grep -n '<[A-Z_]*>' ../../../mon-projet/.gitlab-ci.yml        # ne doit rien afficher
```

## 3. Avant le premier push

1. **Le runner existe et porte le tag.** Un runner SSH, sur le serveur, avec le compte de déploiement ; **« Run untagged jobs » décoché** : sinon il prendrait des jobs écrits pour Docker, et exécuterait le code des merge requests avec les droits du compte de déploiement. [Procédure et pièges](../../docs/reference/pipeline-gitlab.md#3-le-runner-du-serveur).
2. **Les clones existent** sur le serveur, créés par le compte de déploiement, avec les fichiers d'environnement (`vps-deploy check <env>` répond OK).
3. **Les branches de `platform.env` et du pipeline sont les mêmes** : on les change **ensemble**, dans le dépôt, jamais en éditant le fichier sur le serveur ([changer les branches](../../docs/reference/branches-et-fusions.md)).
4. Premier essai : lancer le job manuel `check-vps` (ou `check-prod`), qui n'a aucun effet et dit quel compte exécute et où est la plateforme.

## 4. Variantes

- **Plusieurs productions** (profil C) : dupliquer `deploy-prod` sous un autre nom (`deploy-prodeu`), avec **son propre** `resource_group`, son `environment`, son dossier et `--env prodeu` ; chacune dépend du staging **seulement**, jamais d'une autre production.
- **Une seule branche** pour le staging et la production : possible (`BRANCH_PROD` = `BRANCH_STAGING`), au prix de la garde : n'importe quelle version du staging peut alors partir en production.
- **Tests applicatifs** (Pint, Pest…) : ils demandent un runner **Docker**, à part du runner SSH du serveur ; les ajouter avec le tag de ce runner, jamais sans tag.

## 5. Ce que ces modèles ne font pas

Pas de test applicatif, pas d'analyse de sécurité, pas de déploiement automatique en production, pas de commande `docker` : tout passe par `vps-deploy`, qui contrôle, construit une image par commit, migre, vérifie la santé et revient en arrière seul en cas d'échec.
