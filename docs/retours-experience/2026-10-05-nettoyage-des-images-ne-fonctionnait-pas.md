# 2026-10-05 — Le nettoyage des anciennes images ne fonctionnait jamais

**Impact** : aucun site touché. Un déploiement réussi se terminait par une ligne `ERREUR` dans le journal
et **les anciennes images n'étaient jamais supprimées** : elles s'accumulaient sur le disque.
**Détecté par** : la lecture du journal de déploiement du projet pilote, juste après sa première
mise en production (`/var/lib/vps-platform/<projet>/deploy.log`).

## Ce qui s'est passé

| Heure (UTC) | Ligne du journal |
| --- | --- |
| 21:02:43 | `skills-devops: OK prod = <sha>` |
| 21:02:43 | `skills-devops: ERREUR — fichier .env.staging absent (copier l'exemple et le remplir)` |

La promotion avait réussi (code de sortie 0, site en HTTP 200). L'erreur venait de l'étape qui suit :
le nettoyage des images.

## Cause

Après un déploiement, `prune_images` supprime les anciennes images du projet. Pour connaître leurs noms,
elle appelait `images_for` **pour chaque environnement** (`staging` et `prod`), et `images_for` passe par
`dc`, qui exige le fichier d'environnement de l'environnement demandé.

Or, sur le serveur, **chaque dossier n'a que son propre fichier** (contrat, § 1) :

| Dossier | Fichier d'environnement |
| --- | --- |
| `/app/<projet>/prod` | `.env` |
| `/app/<projet>/staging` | `.env.staging` |

Depuis le dossier de production, demander l'environnement `staging` échouait donc (« fichier .env.staging
absent »). L'échec se produisait dans un sous-processus : le déploiement continuait, mais la liste des images
restait vide et **rien n'était jamais nettoyé**. Même chose, en sens inverse, depuis le dossier de staging.

## Pourquoi rien ne l'a arrêté

- **Le test masquait le défaut.** `tests/test-deploy.sh` posait `.env` **et** `.env.staging` dans chaque
  dossier (« pour simplifier »). La disposition réelle du serveur n'était jamais testée.
- Le nettoyage se termine par un `|| true` : une panne y est silencieuse. Seule la ligne du journal la montre.
- Personne ne relisait le journal après un déploiement réussi.

## Correction

| Quoi | Où |
| --- | --- |
| `prune_images` ne considère que les environnements dont le fichier d'environnement existe dans le dossier courant (les images portent le même nom dans tous les environnements) | `bin/deploy.sh` |
| Scénario « disposition réelle » : un seul fichier d'environnement par dossier, promotion, puis vérification qu'aucune erreur « fichier … absent » n'apparaît dans le journal | `tests/test-deploy.sh` |

Reproduit avant la correction (49 vérifications réussies, 1 en échec), puis corrigé (50 réussies).

## Protection pour tous les projets

- Le test reproduit désormais la disposition **réelle** du serveur : toute régression du même type échoue.
- Règle d'écriture des tests de la plateforme : **un test doit reproduire la disposition du serveur**, pas une
  disposition simplifiée. À relire à chaque nouveau scénario.
- Pas de nouvelle clause du contrat : c'est un défaut d'outil, pas une règle pour les projets.

## Reste à faire

| Quoi | Qui |
| --- | --- |
| Mettre l'outil à jour sur le serveur (`git pull` dans `/app/vps-platform`, [guide 11](../../guides/11-depot-plateforme.md)) | responsable de la plateforme |
| Après la prochaine promotion de chaque projet : vérifier que la ligne `ERREUR … absent` ne revient pas | responsable de chaque projet |
| Surveiller l'espace occupé par les images : `docker system df` ([runbook disque plein](../runbooks/disque-plein.md)) | responsable de la plateforme |
