# ADR-0067 — Profils de projet (sans staging, plusieurs productions, site simple) et sauvegardes sur S3 seulement

- **Statut** : Accepté — complète ADR-0064 (infrastructure) et ADR-0066 (sauvegardes)
- **Date** : 2026-10-05
- **Décideurs** : responsable de la plateforme, sur demande de la direction technique

## Contexte

Deux hypothèses du premier jet ne tenaient pas face aux projets réels :

1. **Tous les projets seraient « staging puis production ».** Or certains n'auront **pas d'environnement de staging**, d'autres auront **plusieurs
   productions** (un client ou une région chacun), et un simple site web n'a besoin que de savoir qu'il est **en ligne**. L'outil de déploiement
   tenait le mot « prod » pour unique et exigeait un staging pour promouvoir ; l'observabilité complète était présentée comme le minimum.
2. **Les sauvegardes sont aussi gardées sur le serveur** (sept copies locales). Chaque projet ajoute ses copies, **sur le disque que tous les sites
   partagent** : un disque qui se remplit **sans que personne ne le voie** les fait tous tomber. Les copies hors serveur existent déjà (S3) :
   la copie locale ne protège pas d'un sinistre du serveur, et ajoute un risque.

## Décision

### 1. Des profils de projet, déclarés dans `platform.env`

- `ENVIRONMENTS` liste les environnements ; **`PROD_ENVIRONMENTS`** (défaut `prod`) dit lesquels sont des productions.
- Une production : jamais déployée automatiquement (`watch` refusé), sauvegarde avant chaque déploiement, promotion humaine, retour arrière automatique.
- **Sans staging** (`ENVIRONMENTS=prod`) : `promote <sha|ref>` **construit sur place** puis déploie ; `promote` sans version est refusé (on ne devine pas).
- **Plusieurs productions** : `promote --env <nom>` ; sans `--env`, refus (« plusieurs productions »). Versions et états indépendants.
- Les noms d'environnements sont des lettres minuscules et des chiffres (`prod`, `prodeu`) : ils servent à nommer projets Docker, images et variables.
- **L'observabilité est proportionnée** : le niveau 0 (la sonde de disponibilité) suffit à un site simple ; journaux, métriques et traces s'ajoutent selon le projet.

### 2. Les sauvegardes ne vivent que sur S3

- L'agent **supprime la copie locale dès qu'elle est envoyée** (`BACKUP_LOCAL_KEEP=0` par défaut).
- **Sans S3 configuré, il refuse** de sauvegarder (sortie en erreur) : jamais de sauvegarde « locale seulement » par défaut. Un environnement volontairement non sauvegardé le dit
  (`BACKUP_DISABLED=1`).
- Si l'envoi **échoue**, la copie chiffrée **reste** (c'est peut-être la seule) et l'agent la renvoie au passage suivant ; **trois copies au plus** (`BACKUP_PENDING_MAX`) :
  le disque est borné par construction. La sortie en erreur est visible (journaux, Grafana).
- Le contrôle de santé du conteneur lit un **marqueur** de dernier envoi réussi (et non plus la présence d'un fichier).
- **`BACKUP_LOCAL_KEEP=N`** reste possible : une exception explicite, documentée comme un risque pour le disque.

## Pourquoi

| Option écartée | Raison |
| --- | --- |
| Garder sept copies locales « au cas où » | Le sinistre qu'on redoute (le serveur) les emporte avec lui ; en attendant, elles occupent le disque de tous. Les copies S3 sont plus sûres |
| Sauvegarde locale seule quand S3 n'est pas configuré | C'est exactement le scénario du disque qui se remplit en silence, et l'impression trompeuse d'être protégé |
| Un `if` par projet dans `deploy.sh` pour chaque cas particulier | Les profils sont **déclarés** dans `platform.env`, testés une fois, identiques pour tous |
| Imposer toute la supervision à tout projet | Un site vitrine n'en a pas l'usage : une règle qu'on ne peut pas tenir finit contournée |

## Conséquences

- **Un projet qui utilisait l'agent sans S3 doit maintenant en configurer un, ou déclarer `BACKUP_DISABLED=1`.** Sur le serveur, seul le projet pilote utilise l'agent aujourd'hui : son
  production a S3 ; son staging n'en a pas et doit déclarer `BACKUP_DISABLED=1` (ou recevoir son propre dossier S3).
- **L'exercice de restauration part de S3**, plus d'un fichier local ([runbook](../runbooks/exercice-de-restauration.md)).
- Le contrôle de santé de la sauvegarde change (marqueur) : les modèles et le pilote sont mis à jour ; un conteneur recréé avec la nouvelle image **et** l'ancien compose serait signalé non sain.
- Coût : une dépendance plus forte à S3. Elle est compensée par l'alerte « aucune sauvegarde envoyée depuis 36 h », l'alerte disque, et le renvoi automatique des copies en attente.
- **Contrat 2.2** : C11 (S3 seulement), C12 (proportionnée), C13 (profils).
- **Testé** : `tests/test-deploy.sh` (projet sans staging, deux productions indépendantes, noms invalides) ; `tests/test-backup.sh` (aucune copie locale après envoi, refus sans S3,
  `BACKUP_DISABLED`, S3 injoignable : trois copies au plus, rattrapage au retour de S3).

## Reste à faire

| Quoi | Qui |
| --- | --- |
| Pour le pilote : mettre à jour son `compose.prod.yaml` (contrôle de santé) et déclarer le staging non sauvegardé ou lui donner un dossier S3 | responsable du projet pilote |
| Reconstruire l'image de l'agent sur le serveur et recréer les services `backup` | responsable de la plateforme |
| Nettoyer les anciennes copies locales déjà présentes (elles sont déjà sur S3) | responsable de la plateforme, après vérification |
