# Décisions d'architecture (ADR)

Une ADR (*Architecture Decision Record*) garde **une décision** et son raisonnement : le
contexte, les options écartées, ce qui a été choisi et pourquoi. Elle répond à la question
« pourquoi est-ce ainsi ? » pour quelqu'un qui arrive deux ans plus tard.

Une ADR est **datée et jamais réécrite**. Si la décision change, on écrit une nouvelle ADR qui
amende ou remplace l'ancienne, et on met à jour le statut de l'ancienne.

Retour au [sommaire de la documentation](../README.md).

| ADR | Sujet | Statut | Date |
| --- | --- | --- | --- |
| [0064](0064-infrastructure-vps-staging-observabilite-mutualisee.md) | Standard d'hébergement du VPS : staging, déploiement par promotion d'image, observabilité et sauvegardes mutualisées | Accepté | 2026-10-03 |
| [0065](0065-supervision-du-serveur-node-exporter.md) | Supervision du serveur : node-exporter, cAdvisor, sondes de sites et alertes génériques | Accepté | 2026-10-05 |
| [0066](0066-sauvegardes-agent-maison-ou-portabase.md) | Sauvegardes : notre agent, Portabase, ou les deux ? | **Proposé** (essai à faire) | 2026-10-05 |

## Quand écrire une ADR

- Un choix **difficile à défaire** (le standard d'hébergement, le format des sauvegardes).
- Un choix **contesté** ou qui écarte une option évidente.
- Une évolution du contrat **sans incident** à l'origine (avec incident, on écrit un
  [retour d'expérience](../retours-experience/README.md), voir le
  [contrat, § 5](../05-contrat-projet.md#5-faire-évoluer-le-contrat)).

## Modèle

Copier dans `NNNN-sujet-court.md` (numéro suivant, quatre chiffres) :

```markdown
# ADR-NNNN — <titre>

- **Statut** : Proposé | Accepté | Remplacé par ADR-XXXX
- **Date** : AAAA-MM-JJ
- **Décideurs** : <qui>

## Contexte
Le problème et les contraintes.

## Options
Ce qui a été envisagé, avec le pour et le contre de chacune.

## Décision
Ce qui est choisi, en une phrase, puis le détail.

## Conséquences
Ce que cela change, ce que cela coûte, ce qu'il reste à faire.
```
