# Guides de mise en place

Les actions à faire **une fois**, sur le serveur ou chez les fournisseurs, dans
l'ordre. Chaque guide dit : quoi faire, comment vérifier que c'est bon, et comment
revenir en arrière.

| # | Guide | Risque pour les sites existants | Durée |
| --- | --- | --- | --- |
| 0 | [**Feuille de route** : l'ordre complet (inventaire, serveur, Core, WILMANAGER), qui fait quoi, rendez-vous réguliers](00-feuille-de-route.md) | — | — |
| 1 | [Inventaire des sous-domaines](01-inventaire-sous-domaines.md) | aucun (lecture seule) | 15 min |
| 2 | [DNS wildcard](02-dns-wildcard.md) | aucun si l'on suit l'ordre | 15 min + propagation |
| 3 | [Installer la plateforme sur le serveur](03-installer-plateforme.md) | aucun | 30 min |
| 4 | [Sauvegardes vers MEGA S4](04-sauvegardes-mega-s4.md) | aucun | 20 min |
| 5 | [Audit et mise en conformité des projets](05-audit-et-conformite.md) | par projet, au moment choisi | variable |
| 6 | [Passer le Core au standard (staging + production)](06-core-au-standard.md) | quelques secondes de coupure du Core | 45 min |
| 7 | [Staging automatique](07-staging-automatique.md) | aucun | 5 min |
| 8 | [Surveillance externe](08-surveillance-externe.md) | aucun | 10 min |
| 9 | [Rotation des journaux Docker](09-rotation-journaux-hote.md) | quelques secondes possibles, en heure creuse | 10 min |
| 10 | [Apps à sous-domaines automatiques (multi-tenant)](10-sous-domaines-automatiques.md) | aucun | selon l'app |
| 11 | [Mettre à jour la plateforme sur le serveur](11-depot-plateforme.md) | aucun (outils) ; quelques secondes (observabilité) | 5 min |
| 12 | [Reprise après sinistre (serveur perdu)](12-reprise-apres-sinistre.md) | — | 2-4 h ; **la partie « à préparer avant » est à faire dès maintenant** |
| 13 | [Intervention assistée sur le serveur (Claude Code, garde-fous)](13-intervention-assistee.md) | aucun en inventaire ; annoncé action par action ensuite | 20 min de préparation |
| 14 | [Revenir aux dépôts privés (clés de déploiement)](14-retour-aux-depots-prives.md) | aucun | 10 min par dépôt |

Pour comprendre l'ensemble avant de commencer : [schémas](../docs/01-schemas.md) et
[glossaire](../docs/03-glossaire.md).

Avant de toucher au serveur, tout peut être essayé sur un poste avec Docker :
[`tests/`](../tests/README.md).

**Conventions des guides :**
- `$` désigne une commande à lancer **sur le serveur**, en root ou avec sudo, sauf
  mention contraire.
- `visibilitycam.com` est le domaine utilisé dans tous les exemples.
