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

## `www.<domaine>` : un nom de plus, à déclarer trois fois

Un nom n'arrive à un projet que s'il est **déclaré à `nginx-proxy`**, **dans le certificat** et **dans le DNS**. Ce n'est vrai ni pour `www.` ni pour un sous-domaine d'un domaine déjà servi : si un projet n'a déclaré que
`exemple.cm`, `https://www.exemple.cm` ne marche pas (pas de certificat pour ce nom, ou aucune route). Ce n'est pas propre à un projet : c'est vrai de **tous** ceux du serveur.

| Il faut | Où | Comment |
| --- | --- | --- |
| Le **DNS** | la zone du domaine | un enregistrement `www` vers le serveur ; **le vérifier avant d'ajouter le nom** : un nom sans DNS fait échouer l'émission du certificat pour **tous** les noms de la liste |
| Le **routage** | `.env.<env>` : `APP_VIRTUAL_HOSTS=exemple.cm,www.exemple.cm` | porté par le conteneur web seul (`VIRTUAL_HOST`) |
| Le **certificat** | `.env.<env>` : `APP_CERT_HOSTS=exemple.cm,www.exemple.cm` | un certificat par nom (HTTP-01), pas de joker ; l'émission prend une à deux minutes après `vps-deploy up` |

**Redirection vers le nom sans `www`** (recommandée : un seul nom canonique, pas de contenu en double) : dans le nginx **du projet** (le conteneur qui reçoit le trafic de `nginx-proxy`), un bloc **avant** le serveur par défaut :
```nginx
server {
    listen 80;
    server_name ~^www\.(?<domaine_sans_www>.+)$;
    return 301 https://$domaine_sans_www$request_uri;      # chemin et paramètres conservés ; aucun nom écrit en dur
}
```
La règle est la même pour chaque environnement : seul le `www.` qui arrive jusqu'au conteneur (déclaré dans `APP_VIRTUAL_HOSTS`) est redirigé. Un `www.dev.exemple.cm` n'existe que si on le déclare.
Le changement de `.env.<env>` s'applique par `vps-deploy up` ([modifier une valeur](modifier-une-valeur.md)) ; la redirection, elle, fait partie de l'image du projet (une livraison).
