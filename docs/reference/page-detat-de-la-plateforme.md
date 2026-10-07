# La page « État de la plateforme »

> **PROTOTYPE, sans authentification** (décision du 2026-10-07, [ADR-0071](../adr/0071-page-detat-de-la-plateforme-prototype.md)). À encadrer avant de la garder : qui la voit, avec quel mot de passe.

Une page, en **consultation seule**, qui répond à « quelle version tourne où ? » pour tous les projets du serveur. Elle est faite pour les développeurs et le responsable de la plateforme : rien à cliquer, aucune action possible.

## Ce qu'elle montre

Une ligne par projet et par environnement :

| Colonne | D'où ça vient |
| --- | --- |
| **Version** et **Précédente** | les fichiers d'état de `deploy.sh` (`/var/lib/vps-platform/<projet>/<env>/current` et `previous`), 12 premiers caractères du commit |
| **Branche** | `platform.env` du projet : la branche que le staging suit, ou la garde de la production (`BRANCH_*`) |
| **Conteneurs** | Docker : conteneurs sains sur total, pour le projet Compose `<projet>-<env>` |
| **Déployée** | l'heure du dernier déploiement (date du fichier d'état) |
| **État** | « en service », « à vérifier » (avec le nom du service en défaut), « aucun conteneur » ; un **dernier échec** s'il y en a un ; les **noms publics** (`VIRTUAL_HOST`) |

**Ce qu'elle ne montre jamais** : le contenu d'un fichier d'environnement, un mot de passe, une clé, un journal. L'outil lit les variables d'un conteneur en mémoire pour y prendre **la seule** `VIRTUAL_HOST` ; le test plante des secrets et vérifie qu'ils ne sortent ni en texte, ni en JSON, ni en page.

## Les trois façons de la lire

```bash
vps-overview                         # tableau dans le terminal (sur le serveur)
vps-overview --json                  # les mêmes données, pour un script
vps-overview --html /un/dossier      # écrit index.html et status.json (c'est ce que la minuterie fait)
```

La page publiée : `https://<OVERVIEW_HOST>/` (ex. `plateforme.visibilitycam.com`) et `/status.json`.

## Les pièces

| Pièce | Rôle |
| --- | --- |
| [`bin/vps-overview.py`](../../bin/vps-overview.py) | Lit l'état et Docker, **ne modifie rien** ; écrit la page de façon atomique |
| [`overview/compose.yaml`](../../overview/compose.yaml) + [`nginx.conf`](../../overview/nginx.conf) | Un nginx sans privilège qui sert **deux fichiers** : conteneur en lecture seule, aucune capacité, aucun port publié (nginx-proxy fait le HTTPS), seules les méthodes GET et HEAD |
| [`host/vps-overview.service`](../../host/vps-overview.service) + [`.timer`](../../host/vps-overview.timer) | Régénère la page chaque minute, avec le compte `deployer` |

## Mise en service (une fois, en root, **avec l'accord du responsable**)

1. **Le nom** : `vps-hosts --free plateforme.visibilitycam.com` doit répondre `libre`, et le DNS doit pointer vers le serveur (le joker `*.visibilitycam.com` suffit s'il est en place).
2. **Le dossier de la page** (propriétaire `deployer`, groupe `vpsdeploy`) :
   ```bash
   install -d -o deployer -g vpsdeploy -m 0755 /var/lib/vps-platform/overview
   ```
3. **Une première page**, pour vérifier avant de publier : `sudo -u deployer vps-overview --html /var/lib/vps-platform/overview`, puis `vps-overview` (le tableau doit être celui attendu).
4. **La minuterie** :
   ```bash
   cp /app/vps-platform/host/vps-overview.service /app/vps-platform/host/vps-overview.timer /etc/systemd/system/
   systemctl daemon-reload && systemctl enable --now vps-overview.timer
   systemctl status vps-overview.service      # « status=0/SUCCESS » au bout d'une minute
   ```
5. **Le service web** :
   ```bash
   cd /app/vps-platform/overview && cp .env.example .env     # vérifier OVERVIEW_HOST
   docker compose --env-file .env up -d
   docker ps --filter name=vps-overview        # « healthy »
   curl -sI https://plateforme.visibilitycam.com/ | head -3  # 200 une fois le certificat émis (1 à 2 minutes)
   ```

**Retour arrière** : `docker compose --env-file .env down` (dans `overview/`), `systemctl disable --now vps-overview.timer`. Rien d'autre n'a été touché : la page n'est branchée sur aucun projet.

## Ce qu'il faut savoir

- **Sans authentification, n'importe qui qui connaît l'adresse la voit** : noms des projets et des domaines, versions déployées, santé des conteneurs. Aucun secret, mais c'est une carte de l'infrastructure ; l'en-tête `noindex` évite les moteurs de recherche, pas les curieux. D'où le statut de prototype.
- **Une page « figée »** : si la minuterie s'arrête, la page ne bouge plus mais reste servie. La date « généré le … » en tête le montre ; `systemctl status vps-overview.timer` le confirme.
- **Un projet n'apparaît que s'il a déjà été déployé par `deploy.sh`** (il lit ses fichiers d'état). Les piles anciennes, déployées autrement, n'y sont pas.
- **Un environnement « aucun conteneur »** : aucune pile ne porte le nom `<projet>-<env>` (cas d'un projet dont les conteneurs ne suivent pas ce nommage).
- **Non testé hors de cette machine** : la minuterie systemd (`ProtectSystem=strict` et l'accès à la socket Docker), et la publication derrière le vrai nginx-proxy. Le premier essai sur le serveur le dira.

## Tests

[`tests/test-overview.sh`](../../tests/test-overview.sh) : le tableau avec un faux Docker, **aucun secret qui sort**, le HTML échappé, l'écriture atomique, Docker ou dossier d'état absents, puis le **vrai nginx** (lecture seule, écritures refusées, en-têtes, 404 ailleurs). Deux régressions simulées prouvent que les contrôles mordent.
