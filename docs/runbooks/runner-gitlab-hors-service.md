# Runbook : le runner GitLab ne prend plus de jobs (ou plus aucun runner ne tourne)

| Gravité | Qui prévenir |
| --- | --- |
| **Élevée.** Un seul service `gitlab-runner` sert **tous** les projets du serveur : s'il est en boucle de redémarrage, plus aucun pipeline ne déploie, pour personne. Les sites, eux, continuent de tourner. | le responsable de la plateforme ; dire aux projets de ne pas pousser en attendant |

## 1. Première minute

```bash
$ systemctl is-active gitlab-runner          # « active » ? « activating » = boucle de redémarrage
$ gitlab-runner verify                       # lit config.toml ET interroge GitLab ; en cas d'erreur de syntaxe : « FATAL: toml: line N … »
$ journalctl -u gitlab-runner -n 50 --no-pager     # (root ou groupe adm)
```

**Ne jamais coller la sortie de `gitlab-runner list` ni le contenu de `config.toml` dans une discussion : ils contiennent les tokens.** `verify` n'affiche qu'un identifiant court.

## 2. Les cas, du plus fréquent au plus rare

| Symptôme | Cause probable | Action |
| --- | --- | --- |
| `FATAL: toml: line N (last key "…")` ; service `activating` | `/etc/gitlab-runner/config.toml` invalide, très souvent après une modification à la main (ex. `token_obtained_at` avec une heure impossible comme `53:27`) | § 3 : réparer la ligne **avant** tout redémarrage |
| GitLab : « This job is stuck because the project doesn't have any runners online assigned to it » | Le runner est hors ligne, non activé pour ce projet, ou son **tag** ne correspond pas à celui du job | Dans GitLab (*Settings → CI/CD → Runners*) : point vert ? tag exact (sans espace ni majuscule) ? « Enable for this project » ? |
| Le job reste « pending » alors que le runner est vert | Runner coché **« Protected »** et branche non protégée ; ou `concurrent` trop bas | Protéger la branche, ou décocher ; `concurrent` (en tête de `config.toml`) = nombre maximal de jobs simultanés pour **tous** les runners du fichier : le monter |
| Un job prend le travail d'un autre, échoue sur `apk: command not found` ou `docker: not found` | Le runner SSH accepte les **jobs sans tag** (« Run untagged jobs ») et reçoit des jobs écrits pour des conteneurs | Décocher « Run untagged jobs » : un runner SSH du serveur ne prend que les jobs qui portent son tag |
| Le runner est vert, le job démarre, puis `Permission denied` dans un clone de projet | Fichiers appartenant à root dans le clone (un `git pull` en root) | [REX 2026-10-06](../retours-experience/2026-10-06-git-pull-en-root-dans-un-clone.md) : `chown`/`chmod`/ACL, § « Correction » ; `vps-deploy check` le détecte désormais et donne la commande |

## 3. Réparer un `config.toml` invalide

Le runner relit `config.toml` toutes les trois secondes **et ignore un fichier invalide en gardant l'ancienne configuration en mémoire** : tout paraît marcher jusqu'au prochain redémarrage, qui échoue. C'est pourquoi on **valide avant de redémarrer**.

```bash
$ cp -a /etc/gitlab-runner/config.toml /etc/gitlab-runner/config.toml.avant-fix-$(date +%s)   # toujours une copie d'abord
$ sed -n 'Np' /etc/gitlab-runner/config.toml       # N = le numéro de ligne donné par FATAL ; vérifier que c'est bien la ligne attendue
$ sed -i 'Ns/=.*/= 2026-10-06T18:30:00Z/' /etc/gitlab-runner/config.toml     # exemple pour token_obtained_at (horodatage informatif, GitLab le réécrit)
$ gitlab-runner verify                             # plus de « FATAL » ; chaque runner « is alive »
$ systemctl restart gitlab-runner && systemctl is-active gitlab-runner      # « active »
```

Si la ligne affichée n'est **pas** celle attendue, ne rien modifier : demander de l'aide sans coller de token.

## 4. Vérification

- `systemctl is-active gitlab-runner` répond `active` depuis plusieurs minutes, compteur de redémarrages à 0 : `systemctl show gitlab-runner -p NRestarts`.
- Un job du projet concerné passe de « pending » à « running ».
- Les sites ne se sont jamais arrêtés : `docker ps` et `vps status` inchangés.

## 5. Ce qu'il ne faut pas faire

- **Redémarrer `gitlab-runner` avant d'avoir validé `config.toml`** (`gitlab-runner verify`) : si le fichier est invalide, le service ne repart pas et **tous** les projets sont bloqués.
- Modifier `config.toml` à la main sans copie préalable ; inventer un `token_obtained_at` (il est écrit par GitLab).
- Laisser un runner SSH accepter les jobs sans tag : n'importe quel code de merge request s'exécuterait sur le serveur avec les droits du compte de déploiement (souvent membre du groupe `docker`).
- Enregistrer un nouveau runner en copiant le token d'un autre : en créer un dans GitLab (le token ne s'affiche qu'une fois) et le saisir soi-même sur le serveur.

## 6. Ce qu'on écrit après

Un [retour d'expérience](../retours-experience/README.md) si le service est resté arrêté ; l'incident n'est clos que lorsque la protection est automatique (voir le REX du 2026-10-06 pour ce qui reste manuel).
