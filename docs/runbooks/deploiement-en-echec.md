# Runbook : un déploiement échoue

| Gravité | Qui prévenir |
| --- | --- |
| Faible à moyenne : `deploy.sh` s'arrête **avant** de modifier quoi que ce soit, ou revient seul à la version précédente | le responsable du projet |

**Ce qu'il faut savoir d'abord** : `deploy.sh` est conçu pour échouer **sans dégâts**. Un contrôle avant déploiement refuse sans
rien modifier ; une version qui ne répond pas à son healthcheck ne reste jamais en ligne (retour automatique). La seule chose
qui ne se défait pas toute seule : **les migrations** de base de données.

## 1. Première minute

```bash
$ cd /app/<projet>/<env>
$ tail -20 /var/lib/vps-platform/<projet>/deploy.log        # la dernière ligne dit pourquoi
$ vps-deploy status                    # version courante et précédente, conteneurs
$ vps-deploy check <env>               # ne modifie rien : refait les contrôles
```

Trois questions : **quel message exact** ? **Qu'est-ce qui tourne maintenant** (`status`) ? **Des migrations ont-elles eu lieu** (le journal
dit `migrations` avant l'erreur) ?

## 2. Le message, la cause, l'action

| Message du journal | Cause | Action |
| --- | --- | --- |
| `contrôle avant déploiement en échec (ci-dessus) — rien n'a été modifié` | Un contrôle a refusé : `platform.env` incohérent, nom privé publié sur un réseau partagé, accès git | Lire les lignes **au-dessus**, corriger **dans le dépôt**, vérifier avec `vps-deploy check <env>`, pousser |
| `git fetch impossible : origin est en HTTPS …` | Le serveur lit le dépôt sans clé de déploiement (clause C9) | `git remote set-url origin git@<alias>:<compte>/<dépôt>.git` ([guide 3](../../guides/03-installer-plateforme.md), [guide 14](../../guides/14-retour-aux-depots-prives.md)) |
| `arrêter d'abord l'ancienne installation qui utilise ces volumes` | Un service a été renommé : l'ancien conteneur tient encore le volume (deux bases sur les mêmes fichiers les corrompent) | `docker rm -f <ancien conteneur>` **nommément** (les volumes restent, [contrat § 4](../05-contrat-projet.md)), puis relancer |
| `fichier .env… absent (copier l'exemple et le remplir)` | Le dossier n'a pas le fichier d'environnement de cet environnement | Le créer à partir de `.env.*.example`, mode `600` |
| `un autre déploiement de <projet> est en cours` | Un seul déploiement à la fois par projet (verrou) | Attendre la fin ; vérifier `ps` avant de supposer un verrou périmé |
| `images de <sha> absentes — lancer d'abord « vps-deploy build <sha> »` | On déploie un SHA qui n'a pas été construit | `vps-deploy build <sha>` dans le dossier de **staging** |
| `build <sha> (<env>) en échec` | Erreur dans le `Dockerfile` ou quota du registre d'images (`429`) | Lire la sortie du build ; pour un quota, réessayer plus tard |
| `nginx-proxy est déjà en erreur — aucun déploiement ne serait pris en compte` | Une configuration invalide bloque tous les changements du serveur | [Site en panne, § 4](site-en-panne.md#4-nginx-proxy-en-erreur) |
| `noms d'hôte déjà utilisés par un autre projet` | Deux projets pour un même nom public | `bin/vps-hosts.sh` pour voir qui porte quoi |
| `sauvegarde en échec — déploiement annulé` | (projet en `BACKUP_BEFORE_DEPLOY=always` seulement) la sauvegarde avant déploiement n'a pas pu être faite (agent arrêté, S3, mot de passe) | Voir le journal de l'agent `backup` ; **ne forcer (`SKIP_BACKUP=1`) qu'avec l'accord du responsable** |
| `migrations en échec — la version <v> tourne toujours, rien n'a été basculé` | Une migration a échoué | Voir § 3 |
| `santé KO — retour automatique à <v>` | La nouvelle version ne répond pas à son healthcheck ; l'ancienne a été remise | Voir § 4 |
| `ATTENTION : la version précédente <v> ne répond pas non plus` | **Rien ne tourne correctement** | Aller à [Site en panne](site-en-panne.md) **immédiatement** |
| `ERREUR` juste **après** `OK <env> = <sha>` | Une étape de fin (nettoyage des images) a échoué ; le déploiement, lui, est bon | Lire la ligne : ce n'est pas bloquant mais c'est un défaut à comprendre |

## 3. Les migrations ont échoué

Le journal dit `migrations en échec — la version <précédente> tourne toujours`. La nouvelle version **n'est pas** en ligne.

1. Lire la sortie de la migration (`deploy.sh` l'affiche juste avant le message).
2. Causes fréquentes : un nom de base qui mène à **un autre projet** (`Connection refused`, toujours la même adresse IP : voir le
   [retour d'expérience](../retours-experience/2026-10-04-premier-deploiement-skills-devops.md)), une base pas encore prête, une erreur de la
   migration elle-même.
3. Corriger **dans le dépôt**, pousser, relancer `vps-deploy up`. Rien n'a été basculé : le site continue de tourner.
4. **Si des tables ont été créées à moitié** (migration non transactionnelle) : restaurer la **dernière sauvegarde** du
   projet (celle de la nuit, ou celle prise à la main avant la migration). Depuis le 2026-10-05, la restauration remet la base **dans l'état exact** de la sauvegarde
   ([exercice de restauration](exercice-de-restauration.md)).

## 4. Le retour automatique a eu lieu

Le journal dit `santé KO — retour automatique à <version>`.

```bash
$ docker ps -a --format '{{.Names}} | {{.Status}}' | grep <projet>-<env>
$ docker logs --tail 80 <conteneur web>          # pourquoi la nouvelle version ne répond pas
```

- Les **migrations de la version échouée ne sont pas annulées**. Si elles ne sont pas compatibles avec la version restaurée,
  restaurer la dernière sauvegarde (de la nuit, ou prise à la main avant la migration).
- Corriger, pousser, redéployer : `vps-deploy up <env> <nouveau sha>`.

## 5. Revenir en arrière à la main

```bash
$ cd /app/<projet>/<env> && vps-deploy rollback <env>
```

`aucune version précédente connue pour <env>` : c'est le premier déploiement, il n'y a rien où revenir. Arrêter le projet
proprement est alors `docker compose -p <projet>-<env> down` (**jamais** `-v`).

## 6. Ce qu'il ne faut pas faire

- Modifier `platform.env` ou le compose **sur le serveur** : on change par commit (clause C6).
- Contourner un refus du contrôle avant déploiement : il dit quoi corriger, et rien n'a été modifié.
- `docker compose down -v`, `docker volume rm`, `system prune --volumes` : ils détruisent les données.
- Relancer en boucle un déploiement qui échoue : lire d'abord pourquoi.
- Forcer `SKIP_BACKUP=1` ou `SKIP_MIGRATIONS=1` sans l'accord du responsable.

## 7. Après

Si la cause est nouvelle, [retour d'expérience](../retours-experience/README.md) ; il n'est clos que lorsqu'un contrôle ou un
test empêche la récidive ([contrat § 5](../05-contrat-projet.md#5-faire-évoluer-le-contrat)).
