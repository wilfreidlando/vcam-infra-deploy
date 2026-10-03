# 1. Inventaire des sous-domaines et prévention des collisions

## Le risque

nginx-proxy choisit le site à servir **uniquement** d'après la variable
`VIRTUAL_HOST` de chaque conteneur. Si deux conteneurs de deux projets différents
déclarent le même nom, nginx-proxy **ne signale aucune erreur** : il les met dans le
même groupe et **répartit les visiteurs entre les deux applications**. Une visite sur
deux arrive alors sur le mauvais site.

**Pire, constaté en test réel avec nginx-proxy 1.7.** Il suffit que le même nom
soit déclaré avec une casse différente (`Blog.visibilitycam.com` et
`blog.visibilitycam.com`). nginx-proxy génère alors une configuration
**invalide** (`duplicate upstream`) et ne peut plus se recharger :
- les sites existants continuent sur l'ancienne configuration ;
- **plus aucun nouveau site ni aucun changement n'est pris en compte sur tout le
  serveur**, jusqu'à la correction.

L'audit signale cet état en CRITIQUE (« configuration refusée »), et `deploy.sh`
refuse de déployer tant qu'il dure.

Deux autres pièges du même genre :
- **Un conteneur arrêté garde son nom.** Le jour où quelqu'un le redémarre, il
  reprend ce nom, même si un nouveau projet l'utilise entre-temps.
- **Un nom explicite gagne toujours sur un wildcard.** Si un SaaS sert
  `*.monsaas.visibilitycam.com` et qu'un autre projet déclare
  `client1.monsaas.visibilitycam.com`, ce client du SaaS disparaît.

## Étape 1 — Dresser l'inventaire (lecture seule)

Depuis le dossier de la plateforme (guide 3), ou depuis une copie de ce dépôt sur le
serveur :

```bash
$ infra/bin/vps-hosts.sh
```

Le script lit tous les conteneurs du serveur (arrêtés compris) et les certificats
détenus par nginx-proxy. Il ne modifie rien. Il affiche :
- la liste **nom → projet → conteneur → état → certificat** ;
- **COLLISIONS** : un même nom revendiqué par plusieurs projets. À corriger en
  premier ;
- les **noms tenus par des conteneurs arrêtés** ;
- les **certificats sans conteneur**, souvent d'anciens sites.

Si votre conteneur nginx-proxy ne s'appelle pas `nginx-proxy` :
`NGINX_PROXY_CONTAINER=<nom> infra/bin/vps-hosts.sh`.

## Étape 2 — Compléter avec l'historique public des certificats

Chaque certificat HTTPS émis est publié dans des journaux publics (Certificate
Transparency). On y retrouve donc **tous les sous-domaines qui ont eu un site
HTTPS**, y compris ceux qui ne sont plus sur ce serveur ou qui sont hébergés
ailleurs :

```bash
$ infra/bin/vps-hosts.sh --ct visibilitycam.com
```

Le script interroge crt.sh, un service public parfois lent. S'il ne répond pas,
réessayez plus tard ou ouvrez `https://crt.sh/?q=%25.visibilitycam.com` dans un
navigateur. Cette option est la seule que je n'ai pas pu exécuter : mon
environnement de test bloquait crt.sh.

Chaque nom est marqué « sur ce VPS » ou « ABSENT d'ici ». Un nom absent est soit un
ancien site, soit un site hébergé ailleurs. **Il est à considérer comme pris** tant
que vous n'avez pas vérifié.

Troisième source : la **zone DNS** chez votre registrar (liste des enregistrements).
Exportez-la : tout enregistrement explicite y est un nom pris.

## Étape 3 — Garder le registre

```bash
$ infra/bin/vps-hosts.sh --csv > /app/registre-sous-domaines-$(date +%F).csv
```

Ouvrez-le dans un tableur, ajoutez une colonne « responsable » et une colonne
« encore utile ? ». C'est la base pour décider quoi nettoyer (étape 5).

## Étape 4 — Avant de créer un nouveau sous-domaine

```bash
$ infra/bin/vps-hosts.sh --free monprojet.visibilitycam.com
libre : monprojet.visibilitycam.com          # → vous pouvez l'utiliser
```

Le script répond « PRIS » si le nom est utilisé par un conteneur, même arrêté, s'il
est couvert par le wildcard d'un SaaS, ou s'il a encore un certificat.

**`deploy.sh` fait ce contrôle tout seul** : un projet déployé avec la plateforme
**refuse de démarrer** si l'un de ses noms appartient déjà à un autre projet. Rien
n'est modifié et le journal indique quel projet tient le nom. L'audit (guide 5)
signale aussi les collisions en CRITIQUE.

## Étape 5 — Corriger une collision existante

1. Identifier le projet légitime (registre, propriétaires).
2. Dans le compose de l'**autre** projet, changer son `VIRTUAL_HOST` /
   `LETSENCRYPT_HOST`, ou arrêter et supprimer son conteneur s'il ne sert plus :
   ```bash
   $ docker rm -f <conteneur>       # un conteneur arrêté qui ne sert plus
   ```
3. Relancer `infra/bin/vps-hosts.sh` : la section COLLISIONS doit disparaître.

## Règles de nommage pour la suite

| Usage | Nom |
| --- | --- |
| Production d'un projet | `<projet>.visibilitycam.com` |
| Staging | `<projet>-staging.visibilitycam.com` |
| SaaS à sous-domaines clients | `<client>.<projet>.visibilitycam.com`, ou mieux, son propre domaine (guide 10) |
| Plateforme | `grafana.visibilitycam.com` |

`<projet>` : en minuscules, sans point, unique sur le serveur (vérifié par
`--free`). Ne jamais réutiliser un nom d'un ancien site sans avoir vérifié qu'il est
vraiment abandonné.
