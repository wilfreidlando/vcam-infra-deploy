# 2026-10-07 — Une fusion qui n'apporte aucun contenu : l'historique dit « fusionné », six fichiers ne l'étaient pas

**Impact** : pendant quelques heures, la branche `develop` d'un projet n'avait pas les six fichiers de configuration de déploiement (`platform.env`, le pipeline, la documentation, deux tests…) alors que son historique les donnait pour fusionnés. Le pipeline de `develop` n'avait donc **aucun job de déploiement**, seulement deux jobs de sécurité qui restaient « pending ». Aucun site touché.
**Détecté par** : la personne responsable, en voyant encore les anciennes règles dans le fichier du pipeline.

## Ce qui s'est passé

La branche de travail a été fusionnée dans `develop` : le commit de fusion existait, avec les deux parents. **Son contenu était exactement celui de `develop` avant** : zéro fichier différent du premier parent (`git diff --name-only <fusion>^1 <fusion>` vide). Les conflits avaient été résolus en gardant « notre » version de tout.

## Cause

Une fusion résolue en gardant le contenu courant partout **n'apporte rien et enregistre pourtant la fusion**. Git considère alors l'autre branche comme intégrée : **une prochaine fusion ne ramène jamais ce contenu**. Le piège est silencieux : aucun message, aucun test ne le voit.

## Correction

Reprendre le contenu perdu dans un **nouveau** commit, sans réécrire l'historique : `git restore --source=<branche-source> --staged --worktree <fichiers>` puis un commit. Les commandes, et la manière de **répéter une fusion dans un espace de travail séparé** avant de la faire : [les branches d'un projet](../reference/branches-et-fusions.md).

## Protection pour tous les projets

- **Documentaire** : la page « les branches d'un projet » décrit le piège, comment le reconnaître en une commande, comment le réparer, et la séquence qui fait d'une branche **l'exact contenu** d'une autre.
- **Pas de contrôle automatique** : la plateforme ne voit pas les fusions d'un projet. Piste : un test de pipeline qui compare le contenu de la branche du staging avec celui de la production **après** une fusion annoncée (non fait).
