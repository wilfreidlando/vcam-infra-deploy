# 2026-10-05 — L'alerte de sauvegarde se taisait pour un projet qui n'était plus sauvegardé

**Impact** : aucun incident, mais **un trou dans la surveillance**. Le Core de production n'a aucune sauvegarde automatique (pas de bucket S3, agent désactivé) et **aucune alerte ne le disait**, parce que le pilote envoyait ses copies.
**Détecté par** : le contrôle en profondeur de la documentation (elle laissait croire que l'alerte protégeait chaque projet), **pas par un test**.

## Ce qui s'est passé

| Constat | Détail |
| --- | --- |
| La règle « Aucune sauvegarde envoyée hors du serveur depuis 36 heures » | `absent_over_time({service="backup", deployment="prod"} \|= "uploaded to" [36h])` : vraie seulement si **aucun** agent n'a rien envoyé |
| Le pilote | 7 envois en 36 h : la règle est satisfaite |
| Le Core de production | Agent désactivé (`BACKUP_DISABLED=1`), aucun envoi : **la règle ne le voit pas** |
| Le test | Vérifiait que la règle se charge et qu'elle ne sonne pas à tort ; **jamais** qu'un projet non sauvegardé est signalé |

## Cause

**« Au moins un » n'est pas « chacun ».** `absent_over_time` porte sur l'ensemble des flux sélectionnés : un seul flux qui contient la ligne suffit à la rendre fausse. Pour surveiller chaque projet, il faut une règle qui **nomme** les projets (`by (app)`).

## Correction

| Quoi | Avant | Après |
| --- | --- | --- |
| Règles | une, globale | **deux** : la globale reste (plus aucun envoi nulle part), une règle **par projet** s'y ajoute |
| La règle par projet | — | les agents de production qui ont eu un **passage** de sauvegarde (lignes `backup:`) **moins** ceux qui ont envoyé une copie (`unless`) |
| Notification | toutes les alertes répétées toutes les 4 h | les alertes étiquetées `cadence=daily` : **une fois par jour** (route de `notifications.yaml`) |
| Projet neuf | — | pas signalé avant son premier passage (la ligne de démarrage `db-backup:` n'est pas comptée) |
| Test | — | trois faux agents de production : un qui envoie, un désactivé, un neuf. La règle par projet nomme **seulement** le désactivé ; l'ancienne règle globale se taisait |

Le rappel quotidien répond à un besoin réel : un projet **volontairement** sans sauvegarde (exception décidée, écrite dans les « écarts connus » de sa fiche) doit être rappelé, pas laissé en silence, mais sans remplir la boîte aux lettres toutes les 4 h.

## Limites à connaître

- **Un projet sans agent** (pas de conteneur `backup`, ou sans labels `observability.*`) n'apparaît dans aucune de ces règles : seuls l'état de santé du conteneur, `bin/vps-audit.sh` et le contrat (clause C11) le voient.
- Le premier rappel pour le Core arrivera **après son premier passage nocturne** (02:30 UTC), une heure plus tard (délai de la règle).

## Ce qu'il faut retenir

1. **Une alerte qui dit « il n'y a plus aucun… » ne dit rien d'un projet précis.** Pour surveiller chacun, la règle doit grouper par projet.
2. **Le test doit reproduire le cas qui a échappé** : ici, un projet qui envoie à côté d'un projet qui n'envoie pas. Un test qui n'a qu'un agent qui fonctionne ne peut pas voir le trou.
3. **Une exception acceptée doit rester visible** : un rappel par jour vaut mieux qu'un silence permanent ou qu'un bruit continu.
