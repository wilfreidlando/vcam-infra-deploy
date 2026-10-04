# Prompt d'intervention sur le VPS

À coller dans Claude Code, lancé depuis le dossier de travail préparé selon le
[guide 13](../../guides/13-intervention-assistee.md). Adapter seulement les
valeurs entre `< >`.

```text
Tu interviens sur le VPS de production de l'entreprise (<alias SSH : vps-contabo>),
qui héberge des applications DÉJÀ EN PRODUCTION. Ton travail : inventorier le
serveur, le comparer au référentiel, me rendre compte au fur et à mesure, puis
appliquer les corrections que je valide, et tenir le dépôt à jour.

## Référentiel (à lire AVANT toute commande sur le serveur)
- vcam-infra-deploy/docs/05-contrat-projet.md : le contrat que tout projet doit
  respecter (clauses, noms, mise en conformité § 4, évolution du contrat § 5) ;
- vcam-infra-deploy/README.md (16 règles), guides/00-feuille-de-route.md,
  guides/13-intervention-assistee.md, docs/retours-experience/ (incidents connus),
  le dernier fichier de docs/inventaire/ s'il existe (pour comparer).
Le contrat fait foi. Si la réalité du serveur le contredit, tu le signales ; tu ne
contournes jamais une règle en silence.

## Accès
- Serveur : uniquement `ssh <vps-contabo> <commande>`. Aucune autre méthode.
- GitHub : l'accès git déjà configuré sur ce poste. Aucun mot de passe.
- Autres secrets, si une étape l'exige : <~/.config/vcam/secrets.env>. Tu l'utilises
  seulement par `set -a; . <fichier>; set +a; <commande>` et tu ne nommes que les
  variables. Tu ne lis, n'affiches, ne copies et ne commites JAMAIS une valeur de ce
  fichier, de ~/.ssh, ou d'un .env (sur le poste ou sur le serveur). Sur le serveur,
  tu lis des noms de variables, jamais leurs valeurs.

## Restrictions
1. La phase est dans .claude/PHASE. « inventaire » = LECTURE SEULE sur le serveur.
   Un garde-fou bloque les commandes qui écrivent. S'il en bloque une, tu ne le
   contournes pas (ni autre syntaxe, ni script, ni scp) : tu me dis ce que tu
   voulais faire et pourquoi, et tu l'ajoutes au plan.
2. Toujours interdit, en toute phase : supprimer un volume ou des données
   (`down -v`, `volume rm`, `prune`), toucher à SSH, au pare-feu, aux comptes, ou
   redémarrer le serveur ou Docker. Si c'est nécessaire, tu me l'expliques et c'est
   moi qui le fais.
3. Pour garder une sortie du serveur : tu récupères la sortie, puis tu l'écris en
   local avec l'outil d'écriture de fichiers (pas de `>` vers le serveur).
4. Une commande à la fois, rien de lourd pendant les heures d'activité.
5. Urgence constatée (base ou port exposé sur Internet, disque plein à plus de
   90 %, site en panne, nginx-proxy en erreur) : tu t'arrêtes et tu me préviens
   immédiatement.

## Phase 1 — Inventaire (lecture seule)
1. `ssh <vps-contabo> /app/vps-platform/bin/vps-inventory.sh` : l'inventaire
   complet, sans secret (hôte, plateforme, crons, projets, dossiers /app, réseaux
   partagés, audit, sous-domaines). Si l'outil est absent ou ancien sur le serveur,
   dis-le-moi (sa mise à jour est une action de phase 2) et fais l'inventaire
   avec les commandes de lecture autorisées.
2. Pour chaque projet déployé par deploy.sh :
   `cd /app/<app>/<env> && /app/vps-platform/bin/deploy.sh check <env>`
   (lecture seule, mais fait un `git fetch` : demande-moi avant).
3. Analyse : chaque écart rapporté à une clause du contrat.

## Format des retours (après chaque étape, pas seulement à la fin)
- Constats : tableau Projet | Constat | Clause | Gravité (URGENT / CRITIQUE /
  ATTENTION / INFO) | Preuve (commande + extrait utile, sans secret).
- Propositions dans l'ordre, chacune avec : risque pour la production, coupure
  éventuelle, retour arrière.
- Ce que tu ne sais pas, au lieu de deviner.

## Le dépôt
- Fin de phase 1 : docs/inventaire/AAAA-MM-JJ-inventaire-vps.md (sortie de
  vps-inventory.sh, puis tes constats et le plan), sur une branche
  `inventaire-vps-AAAA-MM-JJ`, avec une pull request que je relis.
- Un constat qui révèle un trou dans la plateforme (ce que deploy.sh, vps-audit.sh,
  un modèle ou un guide aurait dû arrêter) : tu appliques le contrat § 5 au complet
  (retour d'expérience, contrôle automatique, test dans tests/ qui reproduit le
  défaut, modèle, contrat, README), tu lances les tests concernés, puis une branche
  et une PR par correction.
- Jamais de push direct sur main, jamais de force-push. Le serveur ne reçoit une
  modification de la plateforme qu'après merge, par `git pull` dans
  /app/vps-platform, en phase 2.

## Phase 2 — Application
Seulement quand j'aurai écrit « phase 2 validée » ET que .claude/PHASE vaudra
« application » (c'est moi qui le change).
- Une correction à la fois, dans l'ordre du plan validé, staging d'abord. La
  production : seulement après mon accord explicite pour CE projet, dans le créneau
  que je donne.
- Avant chaque action : la commande exacte, l'effet attendu, le retour arrière.
  Après : la vérification (deploy.sh status, healthcheck, le site répond) et un
  retour.
- Projets existants : contrat § 4 (nom de projet Docker conservé, volumes jamais
  renommés ni supprimés, sauvegarde vérifiée avant toute migration en production).
- Imprévu : tu t'arrêtes, tu remets l'état précédent si c'est sûr
  (deploy.sh rollback), tu me fais un rapport. Pas de deuxième tentative improvisée.
- Fin de phase 2 : nouvel inventaire, comparé au premier, dans docs/inventaire/.

Commence par lire le référentiel, puis donne-moi en quelques lignes ton plan pour la
phase 1, avant la première commande sur le serveur.
```
