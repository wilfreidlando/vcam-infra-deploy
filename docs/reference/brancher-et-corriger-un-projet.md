# Brancher un nouveau projet, corriger un projet existant

> La liste de contrôle d'un nouveau projet, et la table des corrections pour un projet déjà en ligne. Pour la procédure complète clause par clause : [guide 16](../../guides/16-mettre-un-projet-au-standard.md).
> Retour au [sommaire de la documentation](../README.md).

## Brancher un nouveau projet (check-list)

1. **Modèle** : copier depuis `templates/` selon le type :
   - `compose.laravel.yaml` : Laravel avec queue, scheduler, base, cache et
     sauvegarde ;
   - `compose.web.yaml` : n'importe quel backend web ;
   - `frontend/` : SPA React/Angular/Vue (`Dockerfile.spa`) ou Next.js
     (`Dockerfile.nextjs`).

   Renommer en `compose.prod.yaml` et remplacer `mon-saas` par le nom du projet
   **partout**, noms de services compris (règle 13).
2. **`platform.env`** (commité) : nom, healthcheck, migrations, sauvegarde. Modèle :
   `templates/platform.env`, ou `templates/frontend/platform.env` pour un frontend.
3. **Fichiers d'environnement** (non commités) : `.env` et `.env.staging`, avec les
   variables de `templates/env.platform.example`. Les ajouter au `.gitignore`.
4. **Sur le serveur** :
   ```bash
   # clé de déploiement + alias SSH github-<projet> : guide 3, étape 0 (règle 16)
   mkdir -p /app/<projet> && cd /app/<projet>
   git clone git@github-<projet>:<compte>/<dépôt>.git staging
   git clone git@github-<projet>:<compte>/<dépôt>.git prod
   # déposer .env.staging dans staging/ et .env dans prod/
   cd staging && /app/vps-platform/bin/deploy.sh check staging   # aucun déploiement, lecture seule
   /app/vps-platform/bin/deploy.sh watch                         # premier staging
   cd ../prod && /app/vps-platform/bin/deploy.sh promote    # première production
   ```
5. Ajouter la ligne cron de staging automatique ([protocole de livraison](organisation-et-livraison.md#protocole-de-livraison)).
6. Ajouter `https://<projet>.visibilitycam.com/<health>` à la surveillance externe.
7. Lancer `vps-audit.sh` : le projet ne doit avoir **aucune** ligne CRITIQUE ni
   ATTENTION.

## Corriger un projet existant

1. **Lancer l'audit** (lecture seule, aucun effet sur les sites) :
   ```bash
   /app/vps-platform/bin/vps-audit.sh
   ```
2. **Corriger dans le compose du projet**, en commençant par les CRITIQUE :

| Constat de l'audit | Correction dans le compose |
| --- | --- |
| Port publié sur Internet / base publiée | Supprimer `ports:`. Pour un accès d'administration : `127.0.0.1:5432:5432`, puis tunnel SSH. Le web passe par `VIRTUAL_HOST` |
| Base sur le réseau `nginx-proxy` | Retirer la base de ce réseau. Seul le conteneur web y reste ; app et base partagent un réseau `<projet>-internal` |
| Socket Docker monté / `privileged` | Supprimer, sauf outil d'infrastructure assumé |
| Pas de politique de redémarrage | `restart: unless-stopped` |
| Aucune limite mémoire | `deploy.resources.limits.memory` (partir de 2× la consommation observée : `docker stats`) |
| Journaux sans rotation | Bloc `logging` des modèles, ou réglage global ([réglages de l'hôte](reglages-de-lhote.md)) |
| `VIRTUAL_HOST` sans `LETSENCRYPT_HOST` | Ajouter `LETSENCRYPT_HOST` (même valeur) et `LETSENCRYPT_EMAIL` |
| `VIRTUAL_HOST` hérité sur un conteneur non exposé | La variable est dans un `env_file` partagé : la renommer (`APP_PUBLIC_HOST`) et ne mettre `VIRTUAL_HOST: ${APP_PUBLIC_HOST}` que sur le conteneur web |
| Image `latest` | `image: <projet>:${IMAGE_TAG:-latest}` + `deploy.sh` |
| Pas de healthcheck | Bloc `healthcheck` des modèles |
| `deploy.sh check` : nom « db » aussi publié sur nginx-proxy par … | Renommer le service (`<app>-db`) et `DB_HOST` ; procédure : [contrat, § 4](../05-contrat-projet.md#4-appliquer-le-contrat-à-un-projet-déjà-en-production) |
| `deploy.sh check` : `platform.env` cite un service absent | Aligner `HEALTH_SERVICE`/`MIGRATE_SERVICE`/`BACKUP_SERVICE`/`DB_SERVICE` sur le compose, dans le même commit |
| `deploy.sh check` : origin en HTTPS | `git remote set-url origin git@github-<app>:<compte>/<dépôt>.git` (guide 3) |

3. **Appliquer sans coupure inutile** : la correction prend effet quand le projet est
   recréé (`docker compose up -d`), donc au prochain déploiement. Les volumes de
   données ne sont pas touchés tant que le **nom du projet compose** ne change pas.
   Pour l'adopter, garder le nom actuel : c'est l'option `-p` utilisée par
   `deploy.sh`, `<APP_NAME>-prod`. Vérifier avec `docker compose ls` avant de choisir
   `APP_NAME`.
4. **Relancer l'audit.**
