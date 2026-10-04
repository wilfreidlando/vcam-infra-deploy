# Retours d'expérience

Un retour d'expérience (REX) par incident ou par déploiement raté. Le but n'est pas
de chercher un coupable : c'est de faire en sorte que **le même problème ne puisse
plus arriver à aucun projet**. Un REX n'est clos que lorsque la protection est
automatique : un contrôle, un test, un modèle corrigé. Voir le
[contrat, § 5](../05-contrat-projet.md#5-faire-évoluer-le-contrat).

| Date | Sujet | Protection mise en place | Statut |
| --- | --- | --- | --- |
| 2026-10-04 | [Premier déploiement de skills-devops : quatre échecs en chaîne](2026-10-04-premier-deploiement-skills-devops.md) | `deploy.sh` : contrôle avant déploiement, commande `check`, `platform.env` lu dans le commit déployé, git sans attente de mot de passe ; modèles corrigés ; contrat v2 | Clos (reste : passer le Core et centre-formation à `deploy.sh check`) |
| 2026-10-04 | [Grafana ne charge pas dans le navigateur : aucun site n'est compressé](2026-10-04-grafana-sans-compression.md) | Grafana compresse lui-même (`GF_SERVER_ENABLE_GZIP`) ; test de compression dans `test-observability.sh`. Défaut de fond (`gzip on` absent de `nginx-proxy`) à décider séparément | Partiel : correction faite, décision `nginx-proxy` ouverte |

## Modèle

Copier dans `AAAA-MM-JJ-sujet-court.md` :

```markdown
# AAAA-MM-JJ — <sujet>

**Impact** : qui a été touché, combien de temps (production ? staging ? données ?)
**Détecté par** : <personne / alerte / déploiement>

## Ce qui s'est passé
Chronologie courte, avec les messages exacts.

## Cause
La vraie cause, vérifiée (reproduite si possible), pas la première hypothèse.

## Pourquoi rien ne l'a arrêté
Quel contrôle manquait.

## Correction
Ce qui a été changé, avec les commits.

## Protection pour tous les projets
Contrôle ajouté (deploy.sh / vps-audit.sh), test qui le prouve, modèle, clause du
contrat.

## Reste à faire
Projets à mettre en conformité, avec un responsable.
```
