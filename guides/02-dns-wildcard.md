# 2. DNS wildcard : tout sous-domaine arrive sur le VPS

**Objectif** : qu'un nouveau sous-domaine de `visibilitycam.com`
(`nouveau-projet.visibilitycam.com`) arrive sur le VPS **sans toucher au DNS**.
nginx-proxy l'envoie ensuite au bon conteneur, et acme-companion lui obtient son
certificat HTTPS.

**Durée** : 15 minutes, plus l'attente de propagation (souvent moins d'une heure).
**Risque pour les sites existants** : aucun, si l'on suit l'ordre ci-dessous.

## Ce qu'il faut savoir avant de commencer (2 minutes de lecture)

- On ajoute **un seul enregistrement** : nom `*`, type `A`, valeur = l'adresse IP
  du VPS.
- Le `*` ne s'applique **qu'aux noms qui n'ont pas déjà leur propre
  enregistrement**. `cpf.visibilitycam.com`, `mail.visibilitycam.com`, etc. gardent
  exactement leur destination actuelle. C'est une règle du DNS (RFC 4592).
- On ne touche à **rien d'autre** : ni aux enregistrements existants, ni aux e-mails
  (`MX`), ni aux `TXT`.

> **Votre cas (VisibilityCam), vérifié sur les écrans :**
> - le domaine est **acheté chez LWS**, mais LWS est en « Configuration DNS
>   personnalisée » avec `ns1/ns2/ns3.contabo.net` : **la zone DNS est chez Contabo**
>   (*Network Services → DNS Management → visibilitycam.com*), environ 93
>   enregistrements ;
> - le **wildcard existe déjà** : `*.visibilitycam.com  A  207.180.203.19`. Ce guide
>   est donc **déjà fait** : il reste seulement l'étape 5 (vérifier) ;
> - pour les **sous-domaines créés à la volée par une app** (certificat wildcard),
>   il faut une API DNS que acme.sh connaît ; ce n'est le cas ni de Contabo ni de
>   LWS. Voir l'annexe : la zone part de Contabo vers Cloudflare, et chez LWS on
>   remplace les serveurs `ns*.contabo.net` par ceux de Cloudflare.
>
> Pour ajouter un enregistrement chez Contabo : *DNS Management* → `visibilitycam.com`
> → **Add a new resource record** (bouton bleu en bas de la liste).

## Étape 1 — Relever l'adresse IP du VPS

Sur le serveur (en SSH) :

```bash
$ curl -4 -s https://ifconfig.me ; echo
207.180.203.19                     # exemple : notez VOTRE résultat
$ curl -6 -s https://ifconfig.me ; echo
                                   # vide = pas d'IPv6 : ignorez tout ce qui parle d'AAAA
```

## Étape 2 — Savoir qui gère le DNS du domaine

Le DNS peut être géré chez **Cloudflare** ou chez le **registrar** (l'endroit où le
domaine a été acheté : OVH, LWS, Namecheap, Hostinger, GoDaddy…). Pour le savoir, sur
le serveur :

```bash
$ dig +short NS visibilitycam.com
```

Si `dig` est absent : `apt install -y dnsutils`. Depuis un PC Windows : `nslookup -type=NS visibilitycam.com`.

| Ce qui s'affiche | Le DNS est géré chez | Suivre |
| --- | --- | --- |
| `xxx.ns.cloudflare.com` et `yyy.ns.cloudflare.com` | **Cloudflare** | Étape 4, cas A |
| `dns*.ovh.net` / `ns*.ovh.net` | OVH | Étape 4, cas B |
| `dns*.registrar-servers.com` | Namecheap | Étape 4, cas B |
| `ns*.lwsdns.com` ou similaire | LWS | Étape 4, cas B |
| `ns*.dns-parking.com`, `*.hostinger.com` | Hostinger | Étape 4, cas B |
| `ns*.domaincontrol.com` | GoDaddy | Étape 4, cas B |
| autre chose | l'hébergeur dont le nom apparaît | Étape 4, cas B |

## Étape 3 — Sauvegarder la zone actuelle (filet de sécurité)

Avant toute modification, garder une copie de tous les enregistrements :

- **Cloudflare** : *DNS → Records*, bouton **Import and Export** (en haut de la
  liste), puis **Export**. Un fichier `.txt` est téléchargé ; gardez-le.
- **Registrar** : la plupart proposent un export (OVH : bouton « Modifier en mode
  textuel », dont on copie le contenu). À défaut, faites des captures d'écran de toute
  la zone.

Puis vérifiez qu'il n'existe **pas déjà** un enregistrement `*` : cherchez une ligne
dont le nom est `*` ou `*.visibilitycam.com`.
- S'il en existe un et qu'il pointe **déjà** vers l'IP du VPS, il n'y a rien à faire :
  passez à l'étape 5.
- S'il pointe **ailleurs**, arrêtez-vous : un autre service reçoit aujourd'hui tous les
  noms inconnus. Il faut d'abord savoir lequel (guide 1, inventaire).

## Étape 4 — Créer l'enregistrement

### Cas A — Le DNS est chez Cloudflare

1. Ouvrir https://dash.cloudflare.com et se connecter.
2. Sur la page d'accueil du compte (liste des domaines), cliquer sur
   **visibilitycam.com**.
3. Dans le menu de gauche : **DNS**, puis **Records**.
4. Cliquer sur le bouton bleu **Add record**.
5. Remplir le formulaire :

   | Champ | Valeur |
   | --- | --- |
   | **Type** | `A` |
   | **Name** | `*` (une étoile seule ; Cloudflare affichera `*.visibilitycam.com`) |
   | **IPv4 address** | l'adresse de l'étape 1, par exemple `207.180.203.19` |
   | **Proxy status** | **désactivé** : cliquer sur le nuage pour qu'il soit **gris** et affiche **DNS only** |
   | **TTL** | `Auto` |

6. Cliquer sur **Save**.
7. La liste affiche une nouvelle ligne : `A | * | 207.180.203.19 | DNS only | Auto`.
8. Seulement si le VPS a une IPv6 (étape 1) : refaire **Add record** avec
   **Type** `AAAA`, **Name** `*`, **IPv6 address** = l'IPv6, nuage **gris**, puis
   **Save**.

**Pourquoi le nuage gris ?** En orange, Cloudflare s'interpose devant le serveur. Les
sites voient alors l'IP de Cloudflare au lieu de celle des visiteurs, et
acme-companion ne peut plus valider les certificats par la méthode habituelle (voir
`README.md` § 3). On pourra activer l'orange plus tard, **projet par projet**, jamais
sur le `*`.

**Message « A record with that host already exists »** : un enregistrement `*` existe
déjà, peut-être en `CNAME`. Revenir à l'étape 3.

### Cas B — Le DNS est chez le registrar

Le principe est le même partout : ouvrir la **zone DNS** du domaine, **ajouter un
enregistrement** de type `A`, de sous-domaine `*`, avec pour cible l'IP du VPS. Les
intitulés varient un peu d'un fournisseur à l'autre :

| Registrar | Chemin dans l'espace client |
| --- | --- |
| **OVH** | *Web Cloud* → *Noms de domaine* → `visibilitycam.com` → onglet **Zone DNS** → **Ajouter une entrée** → **A** → *Sous-domaine* : `*` ; *Cible* : l'IP → **Suivant** → **Valider** |
| **Namecheap** | *Domain List* → **Manage** (à droite de `visibilitycam.com`) → onglet **Advanced DNS** → **Add New Record** → **A Record** → *Host* : `*` ; *Value* : l'IP ; *TTL* : Automatic → coche verte pour enregistrer |
| **LWS** | *Espace client* → *Mes domaines* → `visibilitycam.com` → **Zone DNS** → **Ajouter un enregistrement** → type **A**, nom `*`, valeur l'IP → **Valider** |
| **Hostinger** | *Domaines* → `visibilitycam.com` → **DNS / Serveurs de noms** → *Gérer les enregistrements DNS* : type **A**, nom `*`, pointe vers l'IP → **Ajouter un enregistrement** |
| **GoDaddy** | *Mes produits* → `visibilitycam.com` → **DNS** → **Ajouter un nouvel enregistrement** → type **A**, nom `*`, valeur l'IP → **Enregistrer** |

Quelques interfaces veulent le nom complet (`*.visibilitycam.com`) au lieu de `*` :
si `*` est refusé, essayez le nom complet. Ajoutez l'`AAAA` de la même façon,
seulement si le VPS a une IPv6.

**Faut-il déplacer le domaine chez Cloudflare ?** Pas pour ce guide : tous les
registrars gèrent le wildcard. Cloudflare deviendra utile pour les certificats
wildcard des apps à sous-domaines automatiques (guide 10). Le déménagement est
décrit plus bas, à faire seulement ce jour-là.

## Étape 5 — Vérifier

Attendre 5 à 30 minutes (parfois jusqu'à une heure), puis, sur le serveur :

```bash
$ dig +short nimportequoi-test.visibilitycam.com
207.180.203.19                     # ← l'IP du VPS : le wildcard fonctionne

$ dig +short cpf.visibilitycam.com     # un sous-domaine existant
...                                    # ← la même valeur qu'avant (comparer avec l'export de l'étape 3)

$ curl -sI http://nimportequoi-test.visibilitycam.com | head -1
HTTP/1.1 503 Service Temporarily Unavailable
```

Le **503 est normal et attendu** : la requête arrive bien au VPS, et nginx-proxy
répond qu'aucun site ne porte ce nom. La chaîne fonctionne.

Vérification depuis plusieurs pays (facultatif) : https://dnschecker.org, saisir
`nimportequoi-test.visibilitycam.com`, type `A`. Les coches vertes doivent montrer
l'IP du VPS.

| Problème | Cause probable | Que faire |
| --- | --- | --- |
| `dig` ne renvoie rien | propagation pas terminée | attendre 30 minutes et réessayer |
| `dig` renvoie `104.x.x.x` ou `172.67.x.x` | nuage **orange** sur Cloudflare | repasser le `*` en **DNS only** (gris) |
| La ligne apparaît comme `*.visibilitycam.com.visibilitycam.com` | nom complet saisi dans une interface qui ajoute déjà le domaine | supprimer la ligne, la recréer avec `*` seul |
| Un sous-domaine existant ne répond plus | n'arrive pas avec le seul ajout de `*` (il ne remplace aucun nom existant) | comparer avec l'export de l'étape 3 : un enregistrement a sans doute été modifié par erreur ; le remettre |

## Étape 6 — Premier vrai site

Dès qu'un conteneur déclare `VIRTUAL_HOST=x.visibilitycam.com` et
`LETSENCRYPT_HOST=x.visibilitycam.com`, le site est servi et son certificat obtenu en
une à deux minutes :

```bash
$ docker logs nginx-proxy-acme 2>&1 | tail -20     # suivre l'émission du certificat
```

**Limite Let's Encrypt** : 50 nouveaux certificats par semaine pour l'ensemble de
`visibilitycam.com`. Elle ne gêne pas un usage normal, mais évitez de créer et
supprimer des sous-domaines en boucle.

## Revenir en arrière

Supprimer la ligne `*` (et la ligne `AAAA` `*` si elle a été créée) :
- Cloudflare : *DNS → Records*, **Edit** sur la ligne `*`, puis **Delete** ;
- registrar : icône corbeille ou **Supprimer** sur la ligne.

Les sites qui ont leur propre enregistrement ne sont pas affectés.

---

## Annexe — Déplacer le DNS de `visibilitycam.com` chez Cloudflare (plus tard, si besoin)

À faire quand une app a besoin de **sous-domaines automatiques avec HTTPS** :
WILMANAGER en mode `subdomain` (`centre-a.cpf.visibilitycam.com`), ou un SaaS
(guide 10). Il faut alors un certificat wildcard, qui exige une API DNS. Or acme.sh,
l'outil d'acme-companion, ne connaît pas l'API de LWS (ni celle de Contabo) ; il
connaît Cloudflare.

**Ce qui change** : seul « qui répond aux questions DNS » passe chez Cloudflare. Le
domaine reste acheté et renouvelé chez **LWS**. Le VPS reste chez **Contabo**. Le DNS continue de fonctionner pendant le
déménagement si l'on suit l'ordre. Le point délicat : **les e-mails**. Si un
enregistrement `MX` ou `TXT` est oublié, des e-mails sont perdus.

1. **Exporter la zone actuelle** là où elle est hébergée (chez VisibilityCam :
   Contabo, *DNS Management*). À défaut d'export, recopier la liste complète
   (93 lignes : passer *Rows Per Page* au maximum, puis captures d'écran). C'est la
   référence. Lister à part les `MX` et les `TXT` (taper `MX`, puis `TXT`, dans la
   recherche de la zone) : ce sont eux qui font marcher les e-mails.
2. Sur https://dash.cloudflare.com : bouton **Add a domain** (ou **+ Add** →
   *Connect a domain*) → saisir `visibilitycam.com` → laisser **Quick scan for DNS
   records** coché → **Continue**.
3. Choisir l'offre **Free** → **Continue**.
4. Cloudflare affiche les enregistrements qu'il a trouvés. **Comparer ligne par
   ligne** avec l'export de l'étape 1 et ajouter ce qui manque (**Add record**),
   surtout :
   - les `MX` (e-mails) et leurs priorités ;
   - les `TXT` : SPF (`v=spf1 …`), DKIM (`… ._domainkey`), DMARC (`_dmarc`), et les
     vérifications Google ou Microsoft ;
   - les sous-domaines peu visibles (`autodiscover`, `webmail`, `ftp`…) ;
   - le `*` créé à l'étape 4 ;
   - pour WILMANAGER en mode sous-domaine, ajouter aussi `*.cpf` (et
     `*.cpf-staging`, `*.devwilmanager` si ces environnements l'utilisent), type
     `A`, IP du VPS, DNS only.

   Mettre **tous** les enregistrements en **DNS only** (nuage gris) : le site doit se
   comporter exactement comme avant.
5. **Continue** : Cloudflare affiche **deux serveurs de noms**, par exemple
   `ada.ns.cloudflare.com` et `bob.ns.cloudflare.com`. Les noter.
6. Chez le registrar :
   - si **DNSSEC** est activé, le **désactiver d'abord**, sinon le domaine devient
     injoignable pendant le changement ;
   - puis remplacer les serveurs DNS par ceux de Cloudflare.

   **Chez LWS** (votre cas) : *Espace client* → *Mes domaines* (ou *Domaines*) →
   `visibilitycam.com` → rubrique **Serveurs DNS** (parfois *Gestion des DNS* →
   *Serveurs de noms*). Choisir l'option **serveurs DNS personnalisés / externes**,
   saisir les deux noms donnés par Cloudflare **à la place** de ceux qui y figurent
   (chez VisibilityCam : `ns1.contabo.net`, `ns2.contabo.net`, `ns3.contabo.net` ;
   vider le 3ᵉ champ), puis **Valider**. Noter d'abord les anciens noms : ils
   servent au retour arrière. Si DNSSEC apparaît comme activé dans la même page,
   le désactiver avant.

   Ailleurs : OVH, onglet **Serveurs DNS** → *Modifier les serveurs DNS* ;
   Namecheap, *Nameservers* → **Custom DNS** ; sinon, rubrique « Serveurs de noms /
   Nameservers ».
7. Revenir sur Cloudflare et cliquer **Check nameservers now**. L'activation prend de
   quelques minutes à 24 heures ; Cloudflare envoie un e-mail quand le domaine est
   **Active**.
8. Vérifier : `dig +short NS visibilitycam.com` affiche les serveurs Cloudflare ;
   `dig +short MX visibilitycam.com` affiche les mêmes valeurs qu'avant ; envoyer un
   e-mail vers une adresse `@visibilitycam.com` et vérifier qu'il arrive.

**Retour arrière** : chez le registrar, remettre les anciens serveurs DNS (notés dans
l'export). La zone de l'ancien fournisseur est intacte tant qu'on ne l'a pas
supprimée : **ne pas la supprimer** avant deux semaines sans problème.
