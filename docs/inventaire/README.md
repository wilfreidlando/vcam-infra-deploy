# Inventaires du serveur

Un fichier par inventaire : `AAAA-MM-JJ-inventaire-vps.md`. Chacun contient la
sortie de `bin/vps-inventory.sh` (lecture seule, aucun secret), puis l'analyse :
les écarts au [contrat](../05-contrat-projet.md), clause par clause, avec pour
chacun un responsable et une échéance.

Quand en faire un : avant toute mise en conformité, à la fin de chaque phase de
la [feuille de route](../../guides/00-feuille-de-route.md), et une fois par
trimestre. Comparer avec le précédent (`diff`) montre ce qui a dérivé.

Comment : à la main (`/app/vps-platform/bin/vps-inventory.sh > inventaire.md` sur
le serveur), ou assisté par Claude Code avec garde-fous
([guide 13](../../guides/13-intervention-assistee.md)).

Avant de committer, relire : l'outil masque les secrets qu'il connaît (valeurs
d'environnement, identifiants dans les URL git, arguments de cron nommés
`*TOKEN*`, `*PASS*`, `*SECRET*`, `*KEY*`), mais un secret écrit autrement dans
un cron, par exemple, doit être retiré à la main.

| Date | Fichier | Contexte |
| --- | --- | --- |
| — | — | Premier inventaire : phase 0 de la feuille de route |
