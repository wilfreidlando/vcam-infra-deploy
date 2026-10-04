# Domaines et DNS

> Le DNS wildcard, les collisions de noms, la convention de nommage et Cloudflare.
> Retour au [sommaire de la documentation](../README.md).


**Un enregistrement DNS wildcard suffit** : `*.visibilitycam.com A <IP du VPS>` (plus
`AAAA` si IPv6). Tout nouveau sous-domaine arrive alors sur le VPS. nginx-proxy le
route vers le conteneur qui porte ce `VIRTUAL_HOST`. acme-companion obtient tout seul
son certificat Let's Encrypt, au premier démarrage du conteneur.

- **Les enregistrements existants restent prioritaires** sur le wildcard : les sites
  déjà en ligne ne changent pas.
- Un sous-domaine qui n'est porté par aucun conteneur reçoit une erreur 503 de
  nginx-proxy, sans certificat émis.
- **Limite Let's Encrypt** : 50 nouveaux certificats par semaine pour le domaine. Elle
  ne gêne pas un usage normal, mais évitez de créer et supprimer des sous-domaines en
  boucle.

**Collisions** : nginx-proxy ne refuse jamais un nom déjà pris.
- Deux projets avec le même `VIRTUAL_HOST` : il répartit les visiteurs entre les
  deux.
- Le même nom avec une casse différente : sa configuration devient invalide, et plus
  aucun changement de site n'est appliqué sur tout le serveur.

La plateforme s'en protège :
- `bin/vps-hosts.sh` fait l'inventaire, répond « libre ou pris ? » et sert de garde ;
- `deploy.sh` refuse un nom déjà pris, et refuse aussi de déployer quand nginx-proxy
  est en erreur ;
- l'audit signale les deux cas en CRITIQUE.

Mode d'emploi : [guide 1](../../guides/01-inventaire-sous-domaines.md).

**Convention de nommage, des noms « plats » (un seul niveau) :**

| Environnement | Nom |
| --- | --- |
| Production | `<projet>.visibilitycam.com` |
| Staging | `<projet>-staging.visibilitycam.com` |
| Plateforme | `grafana.visibilitycam.com` |

Pourquoi un seul niveau : si le domaine passe un jour derrière Cloudflare, son
certificat gratuit ne couvre que `*.visibilitycam.com`, pas
`*.staging.visibilitycam.com`.

## Cloudflare ?

**Recommandation : utiliser Cloudflare seulement comme hébergeur DNS, proxy
désactivé (nuage gris), au moins au début.** C'est gratuit, le wildcard se crée en un
clic, et le comportement des sites existants ne change pas.

Activer le proxy Cloudflare (nuage orange) protège contre les attaques DDoS et cache
l'IP du serveur, mais modifie trois choses pour **tous** les projets proxifiés :

1. **Les applications voient l'IP de Cloudflare au lieu de celle du client.** Il faut
   restaurer la vraie IP dans nginx-proxy (`real_ip_header CF-Connecting-IP` depuis les
   plages Cloudflare). Le Core en dépend pour la liste d'IP autorisées de MyCoolPay.
2. **Les certificats** : passer en mode SSL « Full (strict) » ; garder acme-companion
   ou poser un certificat d'origine Cloudflare.
3. **Les webhooks entrants des providers** (MyCoolPay) passent aussi par Cloudflare.

À activer projet par projet, en activant le nuage orange sur l'enregistrement
explicite de ce projet, après avoir ajouté la restauration de l'IP. Jamais sur le
wildcard d'un coup.
