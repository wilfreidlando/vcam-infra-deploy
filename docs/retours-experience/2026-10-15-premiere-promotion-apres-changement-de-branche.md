# 2026-10-15 — Première promotion en production d'e-tourisme : deux refus aux messages trompeurs

**Impact** : la mise en production d'e-tourisme (chantal.cm) a été bloquée plusieurs heures. Aucun site n'a été coupé : les deux refus sont survenus avant la bascule, et l'ancienne version a continué de servir.
**Détecté par** : la personne responsable, dans le job `deploy-prod` du pipeline GitLab.

## Ce qui s'est passé

| Heure (UTC) | Fait |
| --- | --- |
| 13:56 | `deploy-prod` refuse `31b1f13f` : « n'est pas dans origin/refonte/l1-socle (BRANCH_PROD dans platform.env) ». Or le `platform.env` du dépôt dit `BRANCH_PROD=main` depuis le 7 octobre |
| Ensuite | `develop` est fusionnée dans `main` : le refus continue, avec le même message |
| 14:12 | Avec `SKIP_BRANCH_CHECK=1` (variable du projet GitLab), la garde passe. Le déploiement s'arrête aussitôt : « aucune image du compose n'utilise ${IMAGE_TAG} — voir templates ». Le fichier compose n'avait pourtant pas changé depuis la version en production |

## Causes

1. **La garde de branche lit la règle de la version en production.** `guard_branch` s'exécute avant le checkout, donc avec le `platform.env` de la version en place (du 6 octobre), où `BRANCH_PROD=refonte/l1-socle`. C'est voulu : un commit ne doit pas pouvoir s'autoriser lui-même en modifiant `platform.env`. Mais la **première** promotion d'une version qui change la branche de production est alors toujours refusée, et le message ne le disait pas : il demandait de fusionner dans `refonte/l1-socle`, ce qui était absurde.
2. **Les erreurs de Compose étaient avalées.** `images_for` lance `docker compose config --images 2>/dev/null`. Si la configuration de l'environnement échoue (fichier d'environnement illisible, variable obligatoire `${VAR:?…}` absente, `${` dans une valeur), la liste revient vide, et `missing_images` concluait « aucune image n'utilise ${IMAGE_TAG} ». La cause exacte côté serveur reste à confirmer avec `docker compose … config --quiet` dans `/app/APPS/CHANTAL/prod`. Les pistes : droits de `.env.prod` après une édition en root, ou une valeur contenant `$`.
3. **Rien n'indiquait où passer `SKIP_BRANCH_CHECK` depuis GitLab.**

## Pourquoi rien ne l'a arrêté

- `test-branches.sh` couvrait le refus, la fusion et l'exception, mais pas une version qui **change** la branche de production.
- `test-deploy.sh` ne faisait jamais échouer la configuration Compose d'un environnement.

## Correction

- `guard_branch` reconnaît le cas : quand la version promue déclare une autre branche (`branch_declared_in`, lecture du `platform.env` du commit, en texte, jamais exécuté), le refus le dit (« change la branche de production : ancienne → nouvelle »). Il vérifie aussi la version contre la nouvelle branche et indique comment faire l'exception depuis GitLab. La règle en vigueur reste celle de la version en production. Même diagnostic quand l'ancienne branche a été supprimée sur origin.
- `missing_images` relance `docker compose config --quiet` avant de conclure, et affiche l'erreur réelle de Compose (« configuration Compose de prod invalide (compose.prod.yaml avec .env.prod) : required variable … is missing a value »).
- La page [`platform.env`](../reference/platform-env.md) dit comment passer `SKIP_BRANCH_CHECK` depuis GitLab.

## Protection automatique

- `tests/test-branches.sh`, étape « Une version qui CHANGE la branche de production » : refus expliqué, exception une fois, puis la nouvelle branche fait foi sans exception (7 contrôles).
- `tests/test-deploy.sh`, étape « Variable obligatoire absente du fichier de production » : la vraie cause est dans le journal, le message trompeur a disparu (7 contrôles).

## Reste à faire

- Mettre à jour la plateforme sur le serveur (`/app/vps-platform`).
- Confirmer la cause exacte de l'échec de configuration en production, et la corriger dans `.env.prod`.
- Après cette promotion, supprimer la variable `SKIP_BRANCH_CHECK` du projet GitLab.
