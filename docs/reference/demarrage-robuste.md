# Un conteneur qui démarre proprement : ne jamais boucler, ne jamais démarrer à moitié

> Ce qu'on attend d'un conteneur d'application quand sa base, son cache ou sa configuration ne sont pas prêts. Un conteneur qui **quitte** est relancé par Docker, quitte, est relancé :
> des milliers de redémarrages, des journaux noyés, et personne ne sait lequel est la cause. Un conteneur qui **démarre à moitié** sert des erreurs. Retour au [sommaire](../README.md) ; l'incident type :
> [runbook conteneur en boucle](../runbooks/conteneur-en-boucle.md).

## 1. Ce que la plateforme fournit, et ce qu'elle ne fournit pas

| | Fourni | Où |
| --- | --- | --- |
| Ordre de démarrage : la base et le cache **sains** avant l'application | oui | `depends_on: { condition: service_healthy }` dans les [modèles](../../templates/README.md) |
| Contrôles de santé **réels** du web, de la base, du cache, du worker et du planificateur | oui | modèles (testés : `test-templates.sh` refuse un contrôle désactivé) |
| Cache protégé par mot de passe obligatoire | oui | `--requirepass ${REDIS_PASSWORD:?…}` : la composition est refusée sans valeur |
| Limite de mémoire, rotation des journaux, `restart: unless-stopped` | oui | modèles, clauses du [contrat](../05-contrat-projet.md) |
| Migrations **avant** la bascule, avec la nouvelle image, jamais au démarrage d'un conteneur | oui | `MIGRATE_CMD` de `platform.env` : plusieurs conteneurs qui démarrent ensemble ne se disputent pas la base |
| **Un `entrypoint` prêt à copier** (attendre, signaler, ne pas quitter) | **non** | il dépend de l'image du projet ; **à écrire et à tester** selon cette page. Un modèle testé est un manque connu |

## 2. Ce que fait un bon `entrypoint`

1. **Vérifier les variables obligatoires.** Une variable absente ou vide, une clé d'application qui n'a pas la forme attendue : **un seul message clair**, qui nomme la variable, puis le conteneur **attend** (il ne quitte pas). Le message est la première ligne qu'on lira dans les journaux.
2. **Attendre la base**, sans quitter : tenter une vraie connexion (le protocole de la base, pas seulement le port ouvert), toutes les quelques secondes, en journalisant **une ligne tous les dix essais**. Distinguer :
   - *pas encore prête* (connexion refusée, base qui démarre) → on **attend** ;
   - *erreur de configuration* (mot de passe refusé, rôle ou base inexistants) → **un message clair, puis attente** : attendre ne la résoudra pas, mais boucler non plus ; la correction se fait dans le fichier d'environnement puis `vps-deploy up`.
3. **Attendre le cache** de la même façon, **authentification comprise** : un mot de passe refusé est une erreur de configuration, pas une attente.
4. **Préparer** ce que l'application met en cache (par exemple, pour Laravel : `config:cache`, `event:cache`, `view:cache`, le lien public vers le stockage), **après** les attentes.
5. **`exec "$@"`** : le processus de l'application remplace le script (il reçoit les signaux, `docker stop` est propre).

**Attendre sans quitter** : une boucle `sleep` qui reste en vie, avec un `trap` sur `TERM` pour que `docker stop` ne soit pas lent. Ne **jamais** terminer par `exit 1` sur une dépendance absente.

## 3. Les pièges rencontrés

| Piège | Conséquence | À retenir |
| --- | --- | --- |
| `set -e` dans l'entrypoint : la première connexion ratée **quitte** le script | le conteneur sort au premier essai, avant que la base soit prête | `cmd && rc=0 \|\| rc=$?` pour tester sans quitter |
| Le contrôle de santé d'un worker : `pgrep -f "artisan queue:work"` | **toujours vrai** : `pgrep` se trouve lui-même dans la liste (sa propre ligne de commande contient le motif) | motif entre crochets : `pgrep -f 'artisan [q]ueue:work'` |
| Le pilote PHP `pdo_pgsql` renvoie le code **7** pour *toute* erreur de connexion | on ne peut pas distinguer « base pas prête » de « mot de passe refusé » par le code | classer l'erreur par le **message** du serveur (`password authentication failed`, `does not exist`, `no pg_hba.conf entry`) |
| `pgrep` absent de l'image (Debian « slim ») | le contrôle de santé échoue toujours | installer `procps` (déjà présent sur Alpine) |
| Tester le démarrage avec une image officielle de base de données | le serveur **temporaire d'initialisation** répond déjà aux sondes, puis redémarre : la première requête tombe pendant le redémarrage | attendre la **seconde** annonce « prêt » dans les journaux |
| Un worker dont `--max-time` le fait quitter proprement (code 0) | des centaines de « redémarrages » qui n'en sont pas | lire le **code de sortie** avant de s'inquiéter (`docker inspect -f '{{.State.ExitCode}}'`) |

## 4. Les cinq scénarios à tester sur la VRAIE image

Un `entrypoint` n'est pas prouvé tant qu'il n'a pas été essayé contre une base et un cache réels, dont on arrête et relance l'un ou l'autre :

| # | Scénario | Attendu |
| --- | --- | --- |
| A | la **base est absente**, puis elle arrive | message « en attente de la base », le conteneur **reste en vie**, **0 redémarrage**, le processus démarre **seul** à l'arrivée |
| B | le **cache est absent**, puis il arrive | idem |
| C | une **variable obligatoire** est absente ou mal formée | un message qui **nomme la variable**, conteneur en vie, 0 redémarrage, le processus **ne démarre pas** |
| D | un **mot de passe** de la base ou du cache est faux | un message clair (« refuse la connexion », « mot de passe refusé »), conteneur en vie, 0 redémarrage |
| E | tout est correct (le **témoin**) | le processus démarre, 0 redémarrage, aucun message d'erreur de configuration ; sans lui, A à D ne prouveraient rien |

Pour que le test puisse **voir** quand le processus démarre sans que sa propre ligne de commande le fasse croire, la commande de test écrit un marqueur **construit** (`echo "PRO"."CESSUS"`) : l'entrypoint journalise la commande qu'il va lancer, qui contiendrait sinon le marqueur dès la première seconde.
