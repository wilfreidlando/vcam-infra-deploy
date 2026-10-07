# Le pipeline GitLab d'un projet

> Comment un pipeline déploie sur le serveur, pourquoi il a cette forme, et ce qui le bloque. Les modèles prêts à copier : [`templates/gitlab-ci/`](../../templates/gitlab-ci/README.md).
> Retour au [sommaire](../README.md). Un job qui reste « pending » : [runbook](../runbooks/runner-gitlab-hors-service.md).

## 1. Le principe

Le **runner GitLab est le serveur lui-même** : un runner à exécuteur SSH qui se connecte au serveur avec le compte de déploiement et y lance `vps-deploy`. Le pipeline n'écrit
**aucune commande `docker`** : `vps-deploy` contrôle, construit **une image par commit**, migre, vérifie la santé et revient en arrière seul en cas d'échec, avec un verrou par projet.

Deux conséquences dictent toute la forme du pipeline :
- **`deploy.sh` ne reprend pas une opération interrompue.** Tuer une migration ou une bascule en cours laisserait un état à moitié fait. Ce qui est long et sans effet (le contrôle, la construction de l'image) est annulable ; **le déploiement ne l'est jamais**.
- **Une production n'est jamais déployée toute seule.** C'est un bouton, une décision humaine ([profils de projet](profils-de-projet.md), « ce qui ne change jamais »).

## 2. Les garanties des modèles

Vérifiées par `tests/test-gitlab-ci.sh`, qui casse chacune dans une copie et exige que le test échoue **pour la bonne raison**.

| Garantie | Comment | Pourquoi |
| --- | --- | --- |
| Un nouveau push annule ce qui est devenu inutile | `workflow:auto_cancel:on_new_commit: interruptible`, jobs de contrôle et de construction `interruptible: true` | un pipeline figé ne bloque plus personne : le pipeline du dernier commit prend le relais |
| Le **déploiement n'est jamais interrompu** | `interruptible: false` sur `deploy-*` | pas de reprise possible ; il est court (une minute environ) |
| Build et déploiement ne tournent jamais ensemble | même `resource_group` pour le build et le déploiement d'un environnement ; un autre pour la production | `deploy.sh` prend déjà un verrou : sans `resource_group`, le second job échouerait au lieu d'attendre |
| Un job figé ne retient jamais le verrou | `timeout` sur chaque job (40 min la construction, 20 min un déploiement, 60 min pour une construction en production sans staging) | sans délai, un job suspendu garde le verrou jusqu'à l'expiration par défaut (une heure) |
| La production est **manuelle** | `when: manual` sur chaque règle de `deploy-prod`, `allow_failure: false` | une erreur n'atteint jamais les clients toute seule |
| Les jobs vont sur le **runner du serveur** | `tags:` du runner SSH, jamais un runner partagé de GitLab | un runner partagé ne voit pas le serveur |
| Aucune commande `docker` | tout passe par `vps-deploy` | jamais de démarrage service par service (l'ancien `--no-deps` laissait la base absente) |
| La construction démarre tout de suite | `needs: []` | elle ne dépend d'aucun autre job |

## 3. Le runner du serveur

Le runner est **un service unique pour tous les projets du serveur** : un seul `gitlab-runner`, un seul `config.toml`, un bloc par projet. Ce qui le concerne est donc sensible.

| Point | Règle |
| --- | --- |
| Exécuteur | **SSH**, vers le serveur lui-même, compte de déploiement (membre des groupes `docker` et du groupe de déploiement). Les jobs tournent directement sur le serveur, dans un shell non interactif : le `PATH` est posé dans le modèle |
| Tag | un tag **propre au projet** ; les jobs le demandent (`.vps: tags`) |
| **« Run untagged jobs »** | **décoché**. Sinon le runner prend des jobs écrits pour Docker (images Alpine, analyseurs de GitLab) : ils échouent (`apk: command not found`) **et** exécutent le code de n'importe quelle merge request avec les droits du compte de déploiement |
| « Protected » | facultatif, plus strict : le runner ne prend que les branches protégées. **Protéger d'abord les branches du pipeline**, sinon les déploiements restent « pending » |
| Jobs qui exigent Docker (tests applicatifs, analyses de sécurité de GitLab) | un **autre** runner, à exécuteur Docker, avec **son** tag : jamais le runner SSH du serveur |
| `concurrent` | en tête de `config.toml` : le nombre maximal de jobs **simultanés pour tous les runners du fichier**. Trop bas, les jobs d'un projet attendent ceux d'un autre |
| Le jeton | il ne s'affiche **qu'une fois**, à la création du runner dans GitLab ; l'administrateur le saisit lui-même sur le serveur. Jamais dans une discussion, un ticket, un dépôt ou la sortie de `gitlab-runner list` |
| `config.toml` | appartient à root. **Le valider avant de redémarrer le service** : `gitlab-runner verify`. Le runner en marche **ignore** un fichier invalide et garde l'ancienne configuration en mémoire ; c'est le **redémarrage** qui échoue, et alors **tous** les projets perdent leur runner ([runbook](../runbooks/runner-gitlab-hors-service.md)) |

**Ajouter le runner d'un nouveau projet** (par un administrateur) :
1. Dans GitLab, projet → *Settings → CI/CD → Runners → New project runner* : donner le tag du projet, **décocher « Run untagged jobs »**. Le jeton s'affiche une fois.
2. Sur le serveur, en root : sauvegarder `config.toml`, enregistrer le runner (`gitlab-runner register`, exécuteur SSH identique à celui d'un autre projet), ajuster `concurrent`.
3. **`gitlab-runner verify`** : plus aucune ligne `FATAL`, le nouveau runner « is alive » ; **puis seulement** `systemctl restart gitlab-runner` si c'est nécessaire (le runner relit son fichier seul, toutes les trois secondes).
4. Lancer le job manuel `check-vps` (ou `check-prod`) : il n'a aucun effet, et affiche le compte qui exécute et la version de la plateforme.

## 4. Pourquoi un job reste « pending »

| Message ou symptôme | Cause | Que faire |
| --- | --- | --- |
| « stuck because the project doesn't have any runners online assigned to it » | runner hors ligne, non activé pour ce projet, ou jamais enregistré sur le serveur | page des runners du projet (point vert ?) ; sur le serveur `gitlab-runner verify` |
| « no active runners online that can run this job » (tags) | le tag du job n'est pas celui du runner (espace, majuscule) | comparer `tags:` et le tag du runner |
| Le runner est vert mais le job attend | runner « Protected » et branche non protégée ; `concurrent` trop bas | protéger la branche ; monter `concurrent` |
| Un job sans tag attend ou échoue sur `apk` / `docker` | un modèle GitLab (SAST, Secret Detection…) sans runner Docker | le retirer du pipeline, ou lui donner un runner Docker avec son tag |
| Plus aucun job ne part, pour **aucun** projet | le service `gitlab-runner` est en boucle de redémarrage (`config.toml` invalide) | [runbook](../runbooks/runner-gitlab-hors-service.md) |

## 5. Plusieurs environnements

- **Plusieurs productions** (profil C) : un job `deploy-<nom>` par production, **chacun avec son `resource_group`**, son `environment`, son dossier et `--env <nom>` ; chacun dépend du staging, jamais d'une autre production.
- **Les branches** : le pipeline tourne sur la branche du staging ; les gardes de production sont dans `platform.env` ([les branches](branches-et-fusions.md)).
- **Le bouton de production n'est pas dans le pipeline d'une autre branche** : pour une production qui n'accepte que `main`, le bouton est dans le pipeline de la branche du staging et ne réussit qu'après la fusion dans `main`.

## 6. Ce qu'il ne faut pas faire

- Rendre un job de déploiement `interruptible: true` « pour ne plus rien bloquer » : on tuerait une migration en cours.
- Laisser le runner du serveur accepter les jobs sans tag.
- Ajouter à un pipeline un job qui appelle `docker` directement : il contourne le verrou, les contrôles et le retour arrière.
- Lancer `systemctl restart gitlab-runner` avant `gitlab-runner verify`.
- Coller un `config.toml` ou la sortie de `gitlab-runner list` dans une discussion : ils contiennent des jetons.
