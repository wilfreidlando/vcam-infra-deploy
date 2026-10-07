# Guides

Des procédures **pas à pas**. Chaque guide dit : quoi faire, quel risque pour les sites,
comment vérifier que c'est bon, et comment revenir en arrière.

Les numéros sont **stables** : des outils et d'autres documents citent « guide 3 » ou
« guide 12 ». Le numéro 13 n'est pas utilisé. Les guides sont donc regroupés ici **par thème**, sans être renumérotés.
Retour au [sommaire de la documentation](../docs/README.md).

## Par où commencer

| Je veux… | Je lis |
| --- | --- |
| Voir l'ordre complet, du début à la fin | [0. Feuille de route](00-feuille-de-route.md) |
| Reprendre le serveur sans l'avoir construit | [15. Prise en main par une nouvelle équipe](15-prise-en-main-equipe-it.md) |
| Voir un projet complet au standard, fichier par fichier | [18. Le projet pilote skills-devops](18-le-projet-pilote-skills-devops.md) |
| Mettre un projet au standard | [16. Fiche de conformité](16-mettre-un-projet-au-standard.md) |
| Comprendre Grafana | [17. Comprendre l'observabilité et lire Grafana](17-comprendre-et-lire-grafana.md) |
| Faire voir **mon projet** dans Grafana, avec ses propres tableaux et alertes | [19. L'observabilité de mon projet](19-observabilite-de-mon-projet.md) |

## A. Installer le serveur (une fois)

À faire dans l'ordre, sur le serveur ou chez les fournisseurs.

| # | Guide | Risque pour les sites existants | Durée |
| --- | --- | --- | --- |
| 1 | [Inventaire des sous-domaines](01-inventaire-sous-domaines.md) | aucun (lecture seule) | 15 min |
| 2 | [DNS wildcard](02-dns-wildcard.md) | aucun si l'on suit l'ordre | 15 min + propagation |
| 3 | [Installer la plateforme sur le serveur](03-installer-plateforme.md) | aucun | 30 min |
| 4 | [Sauvegardes vers MEGA S4](04-sauvegardes-mega-s4.md) | aucun | 20 min |
| 7 | [Staging automatique](07-staging-automatique.md) | aucun | 5 min |
| 9 | [Rotation des journaux Docker](09-rotation-journaux-hote.md) | quelques secondes possibles, en heure creuse | 10 min |
| 10 | [Apps à sous-domaines automatiques (multi-tenant)](10-sous-domaines-automatiques.md) | aucun | selon l'app |
| 11 | [Mettre à jour la plateforme sur le serveur](11-depot-plateforme.md) | aucun (outils) ; quelques secondes (observabilité) | 5 min |

## B. Mettre un projet au standard

| # | Guide | Risque pour les sites existants | Durée |
| --- | --- | --- | --- |
| 5 | [Audit et mise en conformité des projets](05-audit-et-conformite.md) | par projet, au moment choisi | variable |
| 20 | [Migrer une application déjà en service vers la plateforme (la bascule)](20-migrer-une-application-existante.md) | l'application migrée est coupée 10 à 15 min ; l'ancienne reste intacte | 1 h + la fenêtre |
| 6 | [Passer le Core au standard (staging + production)](06-core-au-standard.md) | quelques secondes de coupure du Core | 45 min |
| 16 | [Mettre un projet au standard (fiche de conformité)](16-mettre-un-projet-au-standard.md) | selon le projet | 2 h par projet |

## C. Surveiller et exploiter

| # | Guide | Risque pour les sites existants | Durée |
| --- | --- | --- | --- |
| 8 | [Surveillance externe](08-surveillance-externe.md) | aucun | 10 min |
| 17 | [Comprendre l'observabilité et lire Grafana](17-comprendre-et-lire-grafana.md) | aucun | 30 min de lecture |
| 19 | [Donner à mon projet son observabilité (labels, tableau « Application », ses propres tableaux et alertes)](19-observabilite-de-mon-projet.md) | aucun | 20 min à 1 h |
| 12 | [Reprise après sinistre (serveur perdu)](12-reprise-apres-sinistre.md) | — | 2-4 h ; **la partie « à préparer avant » est à faire dès maintenant** |
| 14 | [Revenir aux dépôts privés (clés de déploiement)](14-retour-aux-depots-prives.md) | aucun | 10 min par dépôt |

## D. Comprendre et reprendre

| # | Guide | Risque pour les sites existants | Durée |
| --- | --- | --- | --- |
| 0 | [Feuille de route : l'ordre complet (inventaire, serveur, Core, WILMANAGER), qui fait quoi, rendez-vous réguliers](00-feuille-de-route.md) | — | — |
| 15 | [Prise en main par une nouvelle équipe informatique](15-prise-en-main-equipe-it.md) | aucun | 30 min de lecture |
| 18 | [Le projet pilote skills-devops : étude de cas](18-le-projet-pilote-skills-devops.md) | aucun | 30 min de lecture |

## Pour aller plus loin

- Comprendre l'ensemble avant de commencer : [schémas](../docs/01-schemas.md) et
  [glossaire](../docs/03-glossaire.md).
- Avant de toucher au serveur, tout peut être essayé sur un poste avec Docker : [`tests/`](../tests/README.md).
- Une panne en cours : les [runbooks](../docs/runbooks/README.md), pas les guides.

**Conventions des guides :**
- `$` désigne une commande à lancer **sur le serveur**, en root ou avec sudo, sauf
  mention contraire.
- `visibilitycam.com` est le domaine utilisé dans tous les exemples.
- Un nouveau guide prend le **numéro suivant** et s'ajoute dans son thème ci-dessus.
