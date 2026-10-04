# 13. Intervention assistée sur le serveur (Claude Code)

Faire inventorier puis mettre en conformité le serveur par Claude Code, **depuis
votre poste**, avec des restrictions qui ne dépendent pas de sa bonne volonté :

- **Vos secrets restent invisibles** : la clé SSH, l'accès GitHub et le fichier de
  secrets sont utilisés par les commandes, jamais lus ni affichés.
- **Un garde-fou technique** (`hooks/garde-serveur.sh`) refuse toute commande qui
  écrit sur le serveur pendant l'inventaire, et pour toujours ce qui détruirait des
  données ou l'accès au serveur. Il est testé : `tests/test-claude-guard.sh`.
- **Vous approuvez chaque modification** : seules les commandes de lecture listées
  passent sans vous.
- **Tout finit dans le dépôt**, par des pull requests que vous relisez : l'inventaire
  (`docs/inventaire/`), et toute correction de la plateforme avec son test.

| Risque pour les sites | Durée |
| --- | --- |
| Aucun en phase 1 (lecture seule). Phase 2 : celui de chaque action, annoncé avant | Préparation 20 min ; inventaire 30 min à 1 h |

> Ceci se fait avec **Claude Code sur votre poste** (Linux, macOS, ou Windows avec
> WSL2). Une session Claude dans le navigateur ou dans le cloud n'a accès ni à vos
> fichiers ni à votre clé SSH.

## Étape 0 — Le serveur a la dernière plateforme (vous, sur le serveur)

L'inventaire utilise `bin/vps-inventory.sh`. Le mettre à jour est une écriture :
vous la faites vous-même, avant de commencer (guide 11).

```bash
$ cd /app/vps-platform && git pull && ls bin/vps-inventory.sh
```

## Étape 1 — Dossier de travail et dépôts (poste)

```bash
mkdir -p ~/vcam && cd ~/vcam
git clone git@github.com:wilfreidlando/vcam-infra-deploy.git
git clone git@github.com:wilfreidlando/vcam-core-system.git
git clone git@github.com:wilfreidlando/skills-devops.git
```

Le `git push` doit déjà marcher dans ces dossiers (votre clé SSH GitHub, ou
`gh auth login`). **Aucun mot de passe GitHub dans un fichier** : GitHub ne les
accepte plus pour `git` depuis 2021.

## Étape 2 — Accès au serveur par une clé dédiée (poste)

Une clé **propre à cet usage**, que l'on retire du serveur à la fin :

```bash
ssh-keygen -t ed25519 -f ~/.ssh/vps_contabo -C "intervention assistée $(date +%F)"
ssh-copy-id -i ~/.ssh/vps_contabo.pub root@<IP du serveur>   # dernière saisie du mot de passe root
```

Dans `~/.ssh/config` :

```
Host vps-contabo
  HostName <IP du serveur>
  User root
  IdentityFile ~/.ssh/vps_contabo
  IdentitiesOnly yes
```

Vérifier : `ssh vps-contabo hostname` répond sans rien demander.

## Étape 3 — Les autres secrets, si une étape en a besoin (poste)

Uniquement ce qui ne passe ni par SSH ni par git (accès MEGA S4…) :

```bash
mkdir -p ~/.config/vcam && touch ~/.config/vcam/secrets.env && chmod 600 ~/.config/vcam/secrets.env
```

Une ligne `NOM=valeur` par secret. Le fichier est **hors des dépôts**, lisible par
vous seul, et le kit interdit à Claude de le lire (règle `deny`). Il ne peut que le
charger dans une commande (`set -a; . ~/.config/vcam/secrets.env; set +a; …`).

## Étape 4 — Installer le kit (poste)

```bash
cd ~/vcam
mkdir -p .claude/hooks
cp vcam-infra-deploy/templates/intervention-claude/settings.json .claude/settings.json
cp vcam-infra-deploy/templates/intervention-claude/hooks/garde-serveur.sh .claude/hooks/
chmod +x .claude/hooks/garde-serveur.sh
echo inventaire > .claude/PHASE
```

`jq` est requis : `sudo apt install jq`, ou `brew install jq`. Si l'alias SSH n'est
pas `vps-contabo`, le remplacer dans `settings.json` et lancer Claude Code avec
`VPS_SSH_ALIAS=<alias>`.

**Vérifier le garde-fou** avant de s'en servir :

```bash
cd ~/vcam
echo '{"tool_input":{"command":"ssh vps-contabo docker restart nginx-proxy"}}' \
  | CLAUDE_PROJECT_DIR=$PWD .claude/hooks/garde-serveur.sh; echo "code $?"
# attendu : « BLOQUÉ (phase inventaire … » puis « code 2 »
echo '{"tool_input":{"command":"ssh vps-contabo docker ps"}}' \
  | CLAUDE_PROJECT_DIR=$PWD .claude/hooks/garde-serveur.sh; echo "code $?"
# attendu : « code 0 »
```

## Étape 5 — Lancer l'intervention

```bash
cd ~/vcam && claude
```

Coller le prompt de [`templates/intervention-claude/PROMPT.md`](../templates/intervention-claude/PROMPT.md).
Claude Code doit tourner en mode normal (il demande l'accord), **jamais** avec
`--dangerously-skip-permissions`. La touche Échap interrompt l'action en cours.

## Déroulement

| Étape | Vous | Claude |
| --- | --- | --- |
| Démarrage | collez le prompt | lit le référentiel, propose son plan |
| Phase 1 — inventaire | approuvez ou refusez ce qui n'est pas une lecture déjà autorisée | inventaire, retour après chaque étape, PR « inventaire » avec le plan |
| Entre les phases | relisez et mergez la PR, validez le plan, puis `echo application > ~/vcam/.claude/PHASE` et écrivez « phase 2 validée » | — |
| Phase 2 — application | feu vert projet par projet, créneau pour chaque production | applique, vérifie, rend compte ; une PR par trou de la plateforme |
| Fin | `echo inventaire > ~/vcam/.claude/PHASE` | nouvel inventaire, comparé au premier |

## Après l'intervention

1. **Retirer la clé du serveur** : supprimer sa ligne (commentaire « intervention
   assistée … ») dans `/root/.ssh/authorized_keys`. L'accès disparaît.
2. Archiver l'inventaire final dans `docs/inventaire/` (fait par la PR).
3. Les écarts restants sont dans le plan, avec un responsable.

## Ce que le garde-fou bloque

| Phase | Bloqué |
| --- | --- |
| Toujours | `down -v`, `volume rm/prune`, `system prune`, `rm -rf` sur `/`, `/app`, `/etc`, `/root`, `/home`, `/var/lib/docker`, `/var/lib/vps-platform`, redémarrage du serveur, arrêt de Docker ou de SSH, pare-feu (`ufw disable/reset/delete`, `iptables -F`), comptes et clés SSH, `DROP`/`TRUNCATE` |
| Inventaire | En plus, toute écriture sur le serveur : `docker` qui change un conteneur, `docker compose up/down…`, `deploy.sh watch/up/build/promote/rollback`, `restore.sh`, `git pull/checkout/…`, `systemctl start/stop…`, cron, paquets, fichiers (`rm`, `mv`, `cp`, `chmod`, `sed -i`, `tee`, `>`) |
| Jamais bloqué | Les commandes **locales** (le garde-fou ne regarde que ce qui part vers le serveur) ; `deploy.sh check` (lecture, avec votre accord) |

Ce n'est pas un bac à sable : une commande déguisée pourrait passer. Il arrête les
erreurs et les excès de zèle. Votre accord sur chaque modification reste la vraie
barrière. Si vous constatez qu'une commande dangereuse est passée, c'est un trou à
corriger dans `garde-serveur.sh` **avec son test** dans `tests/test-claude-guard.sh`
(contrat, § 5).
