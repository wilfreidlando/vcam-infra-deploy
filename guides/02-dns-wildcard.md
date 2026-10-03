# 2. DNS wildcard

**Objectif** : que tout nouveau sous-domaine de `visibilitycam.com` arrive sur le VPS
sans aucune manipulation DNS. nginx-proxy l'envoie ensuite au bon conteneur, et
acme-companion lui obtient son certificat.

## Pourquoi c'est sans risque pour l'existant

Un enregistrement wildcard (`*`) ne sert **que** pour les noms qui n'ont pas déjà
leur propre enregistrement. Tous les sous-domaines actuels gardent leur
enregistrement et leur destination. C'est une règle du DNS (RFC 4592) : le wildcard
n'est jamais prioritaire sur un nom explicite.

## Étape 1 — Connaître l'adresse du serveur

```bash
$ curl -4 -s https://ifconfig.me ; echo      # IPv4 publique du VPS
$ curl -6 -s https://ifconfig.me ; echo      # IPv6 (si vide : pas d'IPv6, sauter l'AAAA)
```

## Étape 2 — Créer l'enregistrement

Chez l'hébergeur DNS actuel du domaine : registrar, ou Cloudflare si le domaine y
est déjà.

| Type | Nom | Valeur | TTL |
| --- | --- | --- | --- |
| `A` | `*` | IPv4 du VPS | 3600 (ou « Auto ») |
| `AAAA` | `*` | IPv6 du VPS | 3600 — **seulement** si le VPS a une IPv6 qui fonctionne |

Selon l'interface, le nom s'écrit `*` ou `*.visibilitycam.com`.

**Sur Cloudflare** : mettre le nuage en **gris** (« DNS only »). Le nuage orange
change le comportement des sites (voir `infra/README.md` § 3) : ne l'activer que
projet par projet, plus tard.

**Faut-il déplacer le domaine chez Cloudflare ?** Pas pour le wildcard : tous les
registrars le gèrent. Ce ne sera utile que pour les apps à sous-domaines
automatiques (guide 10). Ce jour-là, le déménagement demande une précaution, décrite
dans le guide 10.

## Étape 3 — Vérifier

Après quelques minutes (jusqu'au TTL de l'ancien enregistrement négatif, souvent
moins d'une heure) :

```bash
$ dig +short nimportequoi-test.visibilitycam.com      # → l'IP du VPS
$ dig +short <un sous-domaine existant>               # → inchangé
$ curl -sI http://nimportequoi-test.visibilitycam.com | head -1
HTTP/1.1 503 Service Temporarily Unavailable          # normal : aucun conteneur ne porte ce nom
```

Le 503 prouve que la chaîne fonctionne : le DNS mène au VPS, et nginx-proxy répond
qu'aucun site ne porte ce nom.

## Étape 4 — Premier vrai site

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

Supprimer l'enregistrement `*`. Les sites explicites ne sont pas affectés.
