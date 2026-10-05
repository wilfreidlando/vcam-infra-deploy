# Runbook : le serveur est chargé, comment voir pourquoi

| Gravité | Qui prévient | Quand |
| --- | --- | --- |
| Variable : une charge élevée **sans site en panne** est un signal à comprendre, pas une urgence ; **un site lent ou en panne** est un incident | le responsable de la plateforme | Alerte « charge très élevée », site lent, ou simple curiosité |

Page écrite pour quelqu'un qui n'a pas assisté à la mise en place. Elle donne **où regarder**, **comment lire**, et **ce qui cause le plus souvent une charge** sur ce serveur. Le serveur héberge
beaucoup de petits conteneurs : la charge vient rarement d'un seul gros coupable.

## 1. D'abord : le serveur est-il vraiment saturé ?

La « charge moyenne » (`uptime`) compte les processus **qui veulent le processeur** ou qui attendent le disque. Elle peut dépasser le nombre de cœurs **sans que le processeur soit plein**
(beaucoup de petits travaux brefs). On regarde donc **trois chiffres ensemble** :

```bash
nproc                       # nombre de cœurs
vmstat 1 6                  # lire les colonnes ci-dessous
```

| Colonne de `vmstat` | Ce qu'elle dit | Alerte si… |
| --- | --- | --- |
| `r` | Processus en attente d'un cœur | Reste **au-dessus du nombre de cœurs** longtemps (un pic bref est normal) |
| `id` | Processeur **inactif** (%) | Descend sous 15 % : le serveur est vraiment plein |
| `wa` | Attente du **disque** (%) | Dépasse 10 % : un disque saturé ralentit tout |
| `st` | Processeur « volé » par l'hébergeur (%) | Dépasse quelques % : le problème est chez l'hébergeur, pas ici |
| `sy` | Temps passé dans le **noyau** | Très élevé avec `id` correct : beaucoup de petites opérations (processus qui démarrent, réseau, événements) |

**Lecture.** Une charge de 7 sur 6 cœurs avec `id` à 60 % et `wa` à 0 n'est **pas** une saturation : c'est un serveur qui fait **beaucoup de petites choses**. Il faut alors chercher **ce qui s'agite**, pas ce qui consomme.

## 2. Où voir, dans l'ordre

| Besoin | Où | Ce qu'on y lit |
| --- | --- | --- |
| Tendance sur des heures ou des jours | Grafana → **Plateforme → Serveur — vue d'ensemble** | Processeur, mémoire, swap, disque, **charge par processeur** |
| Qui consomme, **par conteneur** | Grafana → **Plateforme → Conteneurs** (demande cAdvisor) | Processeur et mémoire de chaque conteneur, redémarrages |
| Instantané, tout de suite | `docker stats --no-stream` | Processeur (% d'un cœur) et mémoire de chaque conteneur |
| Les processus qui travaillent | `top -b -n1` (les premières lignes) | Les plus gourmands, y compris `dockerd`, `nginx`, `docker-gen` |
| **Qui redémarre sans cesse** | voir § 3 | Le coupable le plus fréquent |
| Ce qui s'agite côté Docker | `timeout 60 docker events --filter type=container` | Les démarrages et arrêts, **hors `exec_*`** |
| Les alertes | Grafana → Alerting | « charge très élevée », « un conteneur redémarre en boucle » |

## 3. Les quatre causes les plus fréquentes ici, de la plus sournoise à la plus banale

### A. Un conteneur qui redémarre en boucle : **il ne gêne pas que lui-même**

C'est la plus grave pour la charge, et la moins visible. À **chaque** démarrage ou arrêt de conteneur, `nginx-proxy` (par `docker-gen`) **régénère sa configuration pour tous les sites
et recharge nginx**. Un conteneur en boucle déclenche donc, **plusieurs fois par minute, une régénération et un rechargement pour tout le serveur**, plus du travail pour `dockerd` et `containerd`,
plus des journaux qui grossissent. Voir [Conteneur en boucle](conteneur-en-boucle.md).

```bash
# Les conteneurs avec le plus de redémarrages
docker ps -q | xargs docker inspect --format '{{.RestartCount}} {{.Name}} {{.State.Status}}' | sort -rn | head
# Les démarrages / arrêts en cours, sur 60 s (sans les exec)
timeout 60 docker events --filter type=container | grep -v -E 'exec_(create|start|die)'
# Pourquoi il tombe : ses dernières lignes (jamais « --since » sur un gros journal, voir § 5)
docker logs --tail 20 <conteneur>
```

Causes habituelles, vues sur ce serveur : **un nom de service qui n'existe plus** (« host not found in upstream », « getaddrinfo … Name does not resolve ») parce qu'un autre conteneur a été
supprimé ou renommé. Un compteur à plusieurs **dizaines de milliers** de redémarrages est une boucle oubliée depuis des semaines.

### B. Des tâches planifiées qui démarrent une application entière chaque minute

Un conteneur « cron » ou un `php artisan schedule:work` démarre une application complète **à chaque minute**, même s'il n'y a rien à faire. Pris un par un, c'est peu ; multipliés par des dizaines
de projets, c'est un bruit de fond constant et des pics de plusieurs processus à la fois.

### C. Beaucoup de conteneurs, aucune limite

Plusieurs centaines de conteneurs, dont des dizaines de bases de données, chacune avec un petit travail permanent. Sans limite de processeur ni de mémoire, **rien n'empêche un projet d'en prendre trop**.
Les projets au standard ont une limite mémoire (clause C8) ; les autres non.

### D. Le disque et les journaux

Un proxy dont le journal d'accès pèse plusieurs Go, ou des journaux sans rotation, ajoutent des écritures permanentes. Voir [guide 9](../../guides/09-rotation-journaux-hote.md).

## 4. Que faire

| Constat | Action | Qui |
| --- | --- | --- |
| **Un conteneur en boucle** | 1. Lire son journal. 2. **Prévenir le responsable du projet** : le conteneur est à lui. 3. S'il est inutile, l'arrêter (`docker stop`) pour stopper la boucle ; s'il est utile, **réparer la cause** (le service manquant). **Ne pas le supprimer** sans l'accord du projet | le responsable du projet |
| Charge élevée, rien en boucle, `id` correct | Regarder le tableau Conteneurs : le plus gros consommateur est-il normal ? | le responsable de la plateforme |
| `id` sous 15 % ou `wa` élevé | Identifier le coupable (`docker stats`, `top`), **limiter** son processeur ou sa mémoire (`deploy.resources.limits` dans son compose) | le responsable du projet |
| `st` élevé | Voir avec l'hébergeur | le responsable de la plateforme |

**Pour éviter que cela revienne** : l'alerte « un conteneur redémarre en boucle » (Grafana, demande cAdvisor) prévient dès que ça commence, au lieu de le découvrir à 200 000 redémarrages.

## 5. Ce qu'il ne faut pas faire

- **`docker logs --since …` sur un gros journal.** Docker **relit tout le fichier** depuis le début : sur un journal de plusieurs Go, la commande dure des minutes et **ajoute elle-même de la charge** (vécu en
  faisant précisément cette analyse). Utiliser **`--tail N`**, qui lit depuis la fin.
- **Redémarrer Docker ou le serveur** pour « voir si ça passe » : cela efface la trace de ce qui se passe et coupe tous les sites.
- **Supprimer un conteneur ou un volume** d'un autre projet pour faire cesser une boucle. Arrêter, oui ; supprimer, jamais sans l'accord.
- **Conclure sur la seule « charge moyenne »** sans regarder `vmstat` : elle peut être haute sans que le serveur soit plein.

## 6. Ce qu'on écrit après

| Quoi | Où |
| --- | --- |
| Ce qui a été trouvé, avec les noms des conteneurs et les chiffres (**privé**, c'est un inventaire) | Le journal privé du responsable de la plateforme |
| Une cause qui peut se reproduire et que rien n'a empêchée | Un [retour d'expérience](../retours-experience/README.md) |
