# 14. Revenir aux dépôts privés (clés de déploiement)

Pendant la mise en place, des dépôts peuvent être **rendus publics provisoirement**
pour que le serveur les lise en HTTPS, sans clé. C'est une **exception à la clause C9**
du [contrat](../docs/05-contrat-projet.md) (le serveur lit le dépôt par sa clé de
déploiement SSH, jamais en HTTPS). Ce guide dit comment la lever, dans quel ordre, et
ce qu'il faut surveiller en attendant.

| Risque pour les sites | Durée |
| --- | --- |
| Aucun si l'ordre est respecté : seule la lecture des dépôts change, aucun conteneur n'est touché | 10 min par dépôt |

## Tant que les dépôts sont publics

- **Rien de secret dans un dépôt public, ni dans son historique** : jamais de `.env`,
  de clé, de jeton, de mot de passe, d'adresse IP de serveur. Les modèles ne contiennent
  que des noms de variables.
- **Ne pas publier l'état du serveur.** Un inventaire (`docs/inventaire/`) liste les
  conteneurs, les domaines et les expositions encore ouvertes : dans un dépôt public,
  c'est une carte pour un attaquant. Le garder hors du dépôt public (copie locale,
  dépôt privé, ou dépôt public seulement une fois les écarts CRITIQUE corrigés).
- **Noter l'exception** : un constat « origin en HTTPS, dépôt public » dans l'inventaire
  en cours, avec la date prévue pour le retour au privé.
- `deploy.sh` fonctionne en HTTPS tant que le dépôt est public : `deploy.sh check`
  répond « accès git OK ». Il n'échoue qu'au moment où le dépôt redevient privé.

## Revenir au privé : l'ordre compte

**Ne passer le dépôt en privé qu'après l'étape 5.** Sinon `deploy.sh` ne peut plus lire
le dépôt : les sites déjà en ligne continuent de tourner, mais plus aucun déploiement
ne se fait (le staging automatique se met en pause, le message dit quoi corriger).

À répéter **pour chaque dépôt** (la plateforme `vps-platform`, puis chaque projet).
`<alias>` : `github-vcam-infra` pour la plateforme, `github-<app>` pour un projet
(contrat § 3). `<compte>/<dépôt>` : par exemple `wilfreidlando/skills-devops`.

### 1. Vérifier qu'il n'y a pas de collision (serveur)

```bash
$ sudo grep -E '^Host ' /root/.ssh/config          # aucun ne doit s'appeler <alias>
$ ls /root/.ssh/deploy_<app>* 2>&1                 # doit répondre « No such file »
```

Les clés et alias existants (GitLab, autres dépôts) ne sont pas touchés : chaque dépôt a
sa **propre clé** et son **propre alias**, et `IdentitiesOnly yes` empêche SSH
d'essayer une autre clé.

### 2. Créer la clé et l'alias (serveur, en root)

```bash
$ ssh-keygen -t ed25519 -N "" -C "vps-contabo <app>" -f /root/.ssh/deploy_<app>
$ cat >> /root/.ssh/config <<'EOF'

Host <alias>
  HostName github.com
  User git
  IdentityFile /root/.ssh/deploy_<app>
  IdentitiesOnly yes
EOF
$ chmod 600 /root/.ssh/config
$ cat /root/.ssh/deploy_<app>.pub          # la ligne entière « ssh-ed25519 AAAA… »
```

`>>` ajoute à la fin du fichier ; ne jamais le remplacer par `>`.

### 3. Déclarer la clé sur GitHub

Dépôt → **Settings → Deploy keys → Add deploy key** : coller la ligne `.pub`,
**laisser « Allow write access » décoché** (lecture seule). Une clé de déploiement ne
sert que sur **un** dépôt : GitHub refuse de la réutiliser ailleurs, d'où une clé par
dépôt.

### 4. Tester la clé (serveur)

```bash
$ ssh -T git@<alias>        # première fois : répondre « yes » ; attendu : « Hi <compte>/<dépôt>! … »
```

### 5. Changer l'origin de chaque clone, puis vérifier (serveur)

```bash
$ cd /app/<app>/staging && git remote set-url origin git@<alias>:<compte>/<dépôt>.git
$ cd /app/<app>/prod    && git remote set-url origin git@<alias>:<compte>/<dépôt>.git
$ cd /app/<app>/staging && /app/vps-platform/bin/deploy.sh check staging   # « accès git OK (git@… ) »
```

Pour la plateforme : `git -C /app/vps-platform remote set-url origin git@github-vcam-infra:wilfreidlando/vcam-infra-deploy.git`
puis `git -C /app/vps-platform fetch` (doit réussir). Les dépôts appartiennent à
`root` : lancer ces commandes en root ou avec `sudo`.

### 6. Passer le dépôt en privé, puis revérifier

Dépôt → **Settings → Danger Zone → Change visibility → Private**. Puis, sur le serveur :

```bash
$ cd /app/<app>/staging && /app/vps-platform/bin/deploy.sh check staging   # doit répondre encore « accès git OK »
```

## Retour arrière

| Situation | Action |
| --- | --- |
| Le `check` de l'étape 5 échoue | Ne pas passer en privé. Corriger l'alias ou la clé, ou revenir à l'ancien origin : `git remote set-url origin https://github.com/<compte>/<dépôt>.git` |
| Le dépôt est déjà privé et `deploy.sh` ne lit plus rien | Repasser le dépôt en public le temps de corriger (Settings → Change visibility), puis reprendre à l'étape 5 |
| Supprimer l'accès | Retirer la clé dans GitHub (Deploy keys), supprimer le bloc `Host <alias>` et les fichiers `deploy_<app>*` du serveur |

## Contrôle

`bin/vps-inventory.sh` affiche l'origin de chaque dossier : plus aucun `https://`
quand le retour au privé est terminé. Mettre à jour l'inventaire en cours : le constat
« origin en HTTPS, dépôt public » est clos.
