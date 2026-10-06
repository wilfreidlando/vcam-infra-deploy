# 2026-10-06 — Le runner GitLab du serveur tombe après un redémarrage : `config.toml` invalide, puis jobs sans tag

**Impact** : **tous** les projets du serveur sans runner pendant quelques minutes (jusqu'à 20:41:17, heure du serveur) ; aucun site touché. Un déploiement de projet est resté « pending » environ une heure.
**Détecté par** : la personne responsable, devant un job « stuck » dans GitLab, puis `gitlab-runner verify`.

## Ce qui s'est passé

1. Un nouveau runner SSH a été ajouté au serveur pour un projet. Le job restait « pending » : « the project doesn't have any runners online assigned to it ».
2. Le diagnostic conseillé a inclus `systemctl restart gitlab-runner`. `gitlab-runner verify` répondait alors : `FATAL: toml: line 432 (last key "runners.token_obtained_at"): Invalid TOML Datetime: "2026-10-18T53:27:08Z"` (heure 53 impossible, date dans le futur : valeur écrite à la main).
3. Le fichier était **déjà invalide** : le runner en marche l'ignorait et gardait l'ancienne configuration en mémoire. Le redémarrage a rendu l'erreur fatale : le service est passé en `activating`, en boucle, **pour tous les projets**.
4. Une fois la ligne corrigée (`systemctl is-active` → `active`, 0 redémarrage), le runner du projet a pris son premier job… qui n'était pas un déploiement : le job `garde-fous`, sans tag, écrit pour un conteneur Alpine, a échoué sur `apk: command not found`. Le runner SSH acceptait les **jobs sans tag**.

## Cause

- **`config.toml` modifié à la main** avec un horodatage invalide. Le runner tolère un fichier invalide tant qu'il tourne et n'échoue qu'au redémarrage : l'erreur reste invisible.
- **Conseil donné sans validation préalable** : « redémarrer » avant de lancer `gitlab-runner verify` sur le fichier.
- **Runner SSH ouvert aux jobs sans tag** : tout job d'un projet sans tag, ou tout analyseur de sécurité fourni par GitLab (images Docker), pouvait atterrir sur le serveur. Au-delà de l'échec, c'est un risque : du code de merge request exécuté avec les droits du compte de déploiement.

## Correction

| Quoi | Où |
| --- | --- |
| Valeur d'horodatage valide, sauvegarde de `config.toml` d'abord | fait sur le serveur |
| Runbook : valider avant de redémarrer, réparer, causes d'un job « pending » | [runner-gitlab-hors-service](../runbooks/runner-gitlab-hors-service.md) |
| Règle écrite dans la documentation des projets : le runner SSH ne prend que son tag | docs de déploiement de chaque projet |

## Protection pour tous les projets

- **Règle** : on lance `gitlab-runner verify` **avant** tout `systemctl restart gitlab-runner`.
- **Règle** : un runner SSH du serveur ne prend que les jobs qui portent son tag (« Run untagged jobs » décoché).
- **Limite connue** : la protection est **documentaire**, pas automatique. `config.toml` appartient à root et n'est pas dans le périmètre de `vps-deploy` ; aucun contrôle ne le valide aujourd'hui. Piste : une vérification périodique (`gitlab-runner verify` en tâche root, alerte sur `FATAL`), à décider.

## Reste à faire

- [ ] Décider si une alerte sur l'état du service `gitlab-runner` (ou un `verify` planifié) est utile.
