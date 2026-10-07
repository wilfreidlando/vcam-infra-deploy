# Modifier une valeur : faut-il redéployer ?

> Un fichier d'environnement, `platform.env`, un modèle… : **ce qu'il faut faire pour qu'un changement soit réellement pris en compte**, et ce qu'il ne faut jamais changer à chaud.
> Retour au [sommaire](../README.md) ; la même question dans le tableau [selon la situation](deployer-selon-la-situation.md#2-selon-la-situation).

## 1. Ce que je modifie → ce que je fais

| Je modifie | Où | Ce que je fais | Pourquoi |
| --- | --- | --- | --- |
| Une **valeur de l'application** : clé d'un fournisseur, SMTP, mot de passe, mémoire, nom d'hôte… | `.env.<env>` sur le serveur (jamais commité) | **`vps-deploy up <env> <version courante>`** (la version : `vps-deploy status`) | Docker lit ce fichier à la **création** du conteneur. `up` recrée **seulement** les conteneurs dont la configuration a changé, contrôle la santé et revient en arrière seul en cas d'échec |
| `platform.env` (branches, santé, migrations, sauvegarde…) | le **dépôt** du projet : commit, push | déployer ce commit (pipeline, ou `vps-deploy watch` / `promote`) | il est lu **dans la version déployée**. L'éditer sur le serveur modifie un fichier suivi par git : `vps-deploy check` **refuse** alors le clone ([clones et droits](clones-et-droits.md)) |
| `compose.prod.yaml`, un `Dockerfile`, la configuration du nginx du projet | le dépôt | une livraison normale (nouvelle image) | ils font partie de l'image ou de la composition du commit |
| Une variable lue à la **construction** (`VITE_*`, `NEXT_PUBLIC_*`…) | le dépôt (ou `BUILD_PER_ENV=1`) | une nouvelle image : un nouveau commit | elle est figée dans les fichiers produits par le build ; la modifier dans `.env.<env>` ne change rien |
| Les tableaux et alertes du projet (`observability/`) | le dépôt | `vps-deploy obs-sync` ; **les règles d'alerte ne sont relues qu'à la recréation de Grafana** | [guide 19](../../guides/19-observabilite-de-mon-projet.md) |
| Les modèles `.env.*.example` | le dépôt | rien | ils ne servent qu'à créer un **nouveau** fichier d'environnement |
| Un nom public (`APP_VIRTUAL_HOSTS`, `APP_CERT_HOSTS`) | `.env.<env>` | le DNS **d'abord**, puis `vps-deploy up` | un nom sans DNS fait échouer l'émission du certificat de **tous** les noms de la liste ([domaines et DNS](domaines-et-dns.md)) |

## 2. Pourquoi « restart » ne suffit pas

`docker compose restart` (et donc `ops.sh restart`) **relance le même conteneur, avec l'environnement qu'il avait à sa création**. Vérifié avec Docker Compose : une variable modifiée dans le fichier garde son ancienne valeur après `restart`, et prend la nouvelle après `up -d`.

```bash
# après avoir modifié .env.<env> : la bonne commande, dans le dossier de l'environnement, avec le compte de déploiement
vps-deploy status                      # repérer la version courante de l'environnement
vps-deploy up <env> <version courante>
```

Vérifier qu'une valeur est active **sans l'afficher** (un secret ne s'affiche jamais) :
```bash
docker exec <conteneur> sh -c 'printenv NOM_DE_LA_VARIABLE | wc -c'      # > 1 : la variable existe ; pour un réglage non secret, l'afficher est sans risque
```

## 3. Avant de modifier un fichier d'environnement

1. **Faire une copie du fichier d'abord.** Le retour automatique d'un `up` raté rejoue l'ancienne *version* avec le *même* fichier, déjà modifié : il ne remet pas l'ancienne valeur.
2. **Ne pas changer à chaud** :
   - le **mot de passe d'une base** : il est enregistré dans le volume à sa création ; changer seulement la variable casse la connexion de l'application ;
   - la **clé d'application** (`APP_KEY` pour Laravel) : les données chiffrées deviennent illisibles et tout le monde est déconnecté ;
   - un **nom d'hôte** sans avoir vérifié le DNS et la collision de noms (`vps-hosts --check`).
3. **Des valeurs qui doivent changer ensemble** (un mot de passe de cache lu par le cache *et* par l'application) : elles sont dans la même pile, donc `up` recrée les deux conteneurs ; ne jamais en changer une seule.
4. **Une valeur par environnement.** Les secrets de la production ne sont jamais ceux du staging (clause C10 du [contrat](../05-contrat-projet.md)).

## 4. Ce que la plateforme garantit, ce qu'elle ne garantit pas

- Elle garantit que `up` contrôle avant de changer (`check`), recrée sans toucher aux volumes, vérifie la santé et revient en arrière si l'application ne répond pas.
- Elle **ne garantit pas** que la nouvelle valeur est correcte : une clé de fournisseur fausse laisse l'application « en bonne santé » mais incapable d'appeler le fournisseur. Tester la fonction concernée après le changement.
