# 5. Audit et mise en conformité des projets existants

## Étape 1 — Lancer l'audit (lecture seule)

```bash
$ /app/vps-platform/bin/vps-audit.sh | tee /app/audit-$(date +%F).txt
```

Le script ne modifie, ne redémarre et n'affiche aucune valeur secrète. Il classe les
constats par projet :

- **CRITIQUE** : exposé à Internet ou aux autres projets (base de données joignable,
  port publié, collision de sous-domaine, socket Docker en écriture…) ;
- **ATTENTION** : fera tomber quelque chose un jour (pas de limite mémoire, journaux
  sans rotation, pas de redémarrage automatique…) ;
- **INFO** : bonne pratique manquante.

## Étape 2 — Prioriser

1. Les **CRITIQUE**, projet par projet, en commençant par les bases publiées
   sur Internet.
2. Les **ATTENTION** de type « aucune limite mémoire » et « journaux sans
   rotation » : ce sont eux qui font tomber **tout le serveur**.
3. Le reste, au fil des déploiements.

## Étape 3 — Corriger un projet

Le tableau « constat → correction » est dans `README.md` § 7. Les blocs YAML
à copier sont dans `templates/`. Procédure pour un projet :

```bash
$ cd /app/<projet>                       # dossier du projet sur le serveur
$ docker compose ls                      # noter le NOM du projet compose (colonne NAME)
$ cp docker-compose.yml docker-compose.yml.avant-standard
$ nano docker-compose.yml                # appliquer les corrections
$ docker compose -p <NOM> config -q      # vérifie la syntaxe, ne lance rien
$ docker compose -p <NOM> up -d          # recrée seulement les conteneurs modifiés
$ /app/vps-platform/bin/vps-audit.sh | sed -n '/■ <NOM>/,/^$/p'
```

**Garder le même nom de projet compose (`-p <NOM>`).** Les volumes de données en
dépendent : un autre nom donnerait l'impression que la base est vide. Les données
seraient intactes, mais dans l'ancien volume.

Retour arrière : `cp docker-compose.yml.avant-standard docker-compose.yml && docker
compose -p <NOM> up -d`.

## Deux corrections qui demandent de l'attention

**Retirer un port de base de données publié** (`ports: - "3306:3306"`). Vérifier
d'abord si quelqu'un s'y connecte de l'extérieur (outil d'administration, autre
serveur). Si c'est le cas :
- remplacer par `127.0.0.1:3306:3306` : la base reste accessible depuis le serveur
  seulement ;
- se connecter depuis un poste par un tunnel SSH :
  `ssh -L 3306:127.0.0.1:3306 root@<vps>`.

**Ajouter une limite mémoire.** Mesurer d'abord la consommation réelle :

```bash
$ docker stats --no-stream --format 'table {{.Name}}\t{{.MemUsage}}'
```

Fixer la limite à environ 2 fois la valeur observée. Une limite trop basse fait
redémarrer le conteneur en boucle (`OOMKilled`) ; dans ce cas, l'augmenter.

## Étape 4 — Brancher les backends sur l'observabilité

Pour chaque backend (Laravel ou autre), ajouter les labels `observability.*`
(`observability/README.md`). Le label suffit pour les journaux ; le réseau
`observability` n'est nécessaire que pour les métriques et les traces. Jamais de
PHP-FPM, de base ni de Redis sur ce réseau. Les frontends n'en ont pas besoin.

## Étape 5 — Relancer l'audit chaque mois

Ou après chaque nouveau projet. L'objectif : aucune ligne CRITIQUE ni ATTENTION.
