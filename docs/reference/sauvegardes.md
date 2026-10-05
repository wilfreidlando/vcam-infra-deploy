# Sauvegardes

> L'agent de sauvegarde, sa fréquence, et le test de restauration mensuel. Pas à pas : [guide 4](../../guides/04-sauvegardes-mega-s4.md) et [agent `db-backup`](../../images/db-backup/README.md).
> Retour au [sommaire de la documentation](../README.md).


## Le principe : les sauvegardes vivent sur S3, jamais sur le serveur

Toutes les copies de tous les projets se partageraient **le même disque** que les sites. Un disque qui se remplit **sans que personne ne le voie** les
fait tomber **tous**. Et une copie gardée sur le serveur ne protège pas d'un sinistre du serveur. La règle est donc : **la copie part sur S3, puis elle est supprimée du serveur.**

```mermaid
flowchart LR
    DB[("Base du projet")] -->|"dump"| Agent["Agent de sauvegarde<br/>chiffre en AES-256"]
    Agent -->|"envoi"| S3[("S3<br/>30 jours de copies")]
    Agent -->|"envoi réussi : copie locale supprimée"| Disk["Disque du serveur<br/>aucune copie"]
    Agent -. "envoi en échec : la copie reste<br/>3 au plus, renvoyée au passage suivant" .-> Disk
    Agent -->|"erreur visible"| Alert["Journaux, Grafana, alerte 36 h"]
```

| Situation | Ce que fait l'agent | Effet sur le disque |
| --- | --- | --- |
| **Cas normal** : S3 répond | Dump, chiffrement, envoi, **suppression de la copie locale** | Rien ne s'accumule |
| **S3 injoignable** | Garde la copie chiffrée (c'est peut-être la seule), **sort en erreur**, la renvoie au prochain passage | **Trois copies au plus** : le disque est borné par construction |
| **S3 revient** | Envoie la nouvelle copie **et** celles en attente, puis les supprime | Retour à zéro |
| **Pas de S3 configuré** | **Refuse** de sauvegarder (sortie en erreur) : pas de sauvegarde « locale seulement » par défaut | Rien d'écrit |
| **Environnement volontairement non sauvegardé** (un staging jetable) | `BACKUP_DISABLED=1` : ne fait rien, le dit | Rien d'écrit |
| **Exception explicite** `BACKUP_LOCAL_KEEP=N` | Garde aussi N copies après l'envoi | N copies : **à n'utiliser que sciemment** |

### Les quatre garde-fous qui empêchent « de saturer sans le savoir »

| # | Garde-fou | Où |
| --- | --- | --- |
| 1 | **Par construction** : aucune copie ne reste après un envoi réussi ; au plus trois si l'envoi échoue | agent `db-backup` |
| 2 | **Une sauvegarde en échec est bruyante** : sortie en erreur, ligne dans les journaux, visible dans Grafana (et, pour un projet en `BACKUP_BEFORE_DEPLOY=always`, la promotion est refusée) | agent, `deploy.sh` |
| 3 | **Alerte « Aucune sauvegarde envoyée hors du serveur depuis 36 heures »** (journaux de l'agent) ; contrôle de santé du conteneur sur le même critère. **Deux alertes, une globale et une par projet (rappel quotidien)** : voir ci-dessous | Grafana, `docker ps` |
| 4 | **Alerte disque** (« / » à plus de 85 %) pour tout ce qui ne serait pas dans ce cadre | Grafana |

### Le contrôle de santé

Le conteneur de sauvegarde est `healthy` si **un envoi a réussi il y a moins de 36 heures** (marqueur `/backups/.last-upload`, quelques octets). Ce n'est plus
« un fichier existe » : il n'y en a plus.

### Deux alertes : une globale, une par projet (constat du 2026-10-05)

| Alerte | Ce qu'elle voit | Ce qu'elle ne voit pas |
| --- | --- | --- |
| « Aucune sauvegarde envoyée hors du serveur depuis 36 heures » | **Plus aucun** envoi dans l'ensemble des agents de production : observateur cassé, tous les agents arrêtés | Un projet isolé non sauvegardé, tant qu'**un autre** projet envoie ses copies |
| « Une sauvegarde de production n'envoie plus de copie depuis 36 heures » | **Par projet** : un agent qui a eu un passage de sauvegarde sans aucun envoi, parce que l'envoi **échoue** ou que la sauvegarde est **désactivée** (`BACKUP_DISABLED=1`, bucket absent) | Un projet **sans agent** de sauvegarde, ou dont l'agent n'a pas les labels `observability.*` |

La première règle seule laissait un trou : le pilote envoyait ses copies, le Core de production avait son agent désactivé, et rien ne le disait. La seconde le dit, projet par projet.

**Une fois par jour, pas en continu.** Les alertes étiquetées `cadence=daily` suivent une route de notification propre (`notifications.yaml`) : l'e-mail est répété toutes les **24 h**, contre 4 h pour les autres alertes.
Un projet **volontairement** sans sauvegarde en production (exception décidée, écrite dans les « écarts connus » de sa fiche de déploiement) est donc rappelé une fois par jour, sans remplir la boîte aux lettres.
La bonne issue n'est pas de taire l'alerte, mais de brancher S3.

**Un projet neuf n'est pas signalé trop tôt.** La règle compte les lignes d'un **passage** de sauvegarde (préfixe `backup:`), pas la ligne de démarrage de l'agent (préfixe `db-backup:`) : un projet n'est donc signalé qu'après son premier passage nocturne.
Pour un agent désactivé, le premier rappel arrive le lendemain du déploiement, une heure après le passage de 02:30 UTC (délai de la règle).

Ce qui détecte un projet **sans aucun agent** : l'état de santé du conteneur `backup` (`docker ps` : `healthy`, voir ci-dessus), `bin/vps-audit.sh`, et la clause C11 du [contrat](../05-contrat-projet.md) (toute base a sa sauvegarde).

## L'agent

L'agent [`images/db-backup`](../../images/db-backup/README.md) tourne dans chaque projet qui a une base de données :
- dump chaque nuit, chiffré AES-256 avec une phrase de passe propre au projet ;
- copie sur S3 (MEGA S4, R2, B2…), **gardée 30 jours** (réglable), puis effacée du serveur ;
- chaque projet et **chaque production** a son propre dossier sur S3 (`BACKUP_NAME`).

## Quand une sauvegarde est-elle faite ?

| Quand | Comment | Qui |
| --- | --- | --- |
| **Chaque nuit**, à l'heure du projet (`BACKUP_TIME`) | Automatique : c'est **le filet** | l'agent |
| **À la demande**, par exemple avant une migration risquée | `deploy.sh backup [env]` (envoyée sur S3 comme la nocturne) | la personne qui déploie |
| **Avant chaque déploiement** | **Non, par défaut.** Un projet qui préfère la prudence met `BACKUP_BEFORE_DEPLOY=always` dans `platform.env` | `deploy.sh` |

**Pourquoi pas à chaque déploiement ?** Cela coûte une minute et du trafic à chaque changement, même quand la base n'est pas touchée. Et décider automatiquement « cette version
porte une migration » n'est pas fiable (chaque projet range ses migrations où il veut). Une règle simple et connue vaut mieux qu'une règle automatique qui se trompe.
Décision : [ADR-0067](../adr/0067-profils-de-projet-et-sauvegardes-sur-s3-seulement.md).

**Le risque accepté, dit clairement.** Si une migration ratée abîme les données, on ne revient qu'à la sauvegarde **de la nuit** : les écritures de la journée sont perdues.
Pour s'en protéger : prendre une sauvegarde à la main **avant** une migration risquée (`deploy.sh backup`), ou déployer juste après la nocturne. Un déploiement qui ne touche pas la base
n'a pas ce risque : revenir au code d'avant n'oblige à aucune restauration.

Selon le [profil du projet](profils-de-projet.md#7-les-sauvegardes-selon-le-profil) : un site simple n'en a pas, un staging peut la désactiver (`BACKUP_DISABLED=1`).

## Restaurer

**La restauration se fait depuis S3** : `restore.sh <env> s3://<bucket>/<préfixe>/<projet>-<env>/<fichier>`. Le runbook pas à pas, avec la table-témoin qui
prouve que la base est bien **remplacée** : [exercice de restauration](../runbooks/exercice-de-restauration.md).

**Test de restauration mensuel**, obligatoire pour qu'une sauvegarde compte : restaurer **directement depuis S3**, par exemple la production dans le staging.

```bash
cd /app/<projet>/staging
# La phrase de passe de PRODUCTION est donnée ponctuellement, jamais écrite dans .env.staging :
read -rs RESTORE_PASSPHRASE && export RESTORE_PASSPHRASE
/app/vps-platform/bin/restore.sh staging s3://<bucket>/<préfixe>/<projet>-prod/<fichier>
```

Cela restaure la production dans le staging. Attention aux données personnelles : le staging contient alors des données réelles. Le réinitialiser ensuite si besoin.
