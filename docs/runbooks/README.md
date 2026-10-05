# Runbooks d'incident

Retour au [sommaire de la documentation](../README.md).

Une page par situation, écrite pour quelqu'un qui n'a **pas** assisté à la mise en place et
qui a peu de temps. Chaque page a le même plan : symptôme, première minute, diagnostic,
action, vérification, **ce qu'il ne faut pas faire**, et ce qu'on écrit après.

| Symptôme | Runbook |
| --- | --- |
| Un site ne répond plus, erreur 502 ou 503, tous les sites tombés | [Site en panne](site-en-panne.md) |
| `deploy.sh` s'arrête avec une erreur, la nouvelle version n'est pas en ligne | [Déploiement en échec](deploiement-en-echec.md) |
| Un conteneur redémarre sans cesse (`Restarting`, compteur de redémarrages énorme) | [Conteneur en boucle](conteneur-en-boucle.md) |
| Alerte « disque » ou `no space left on device` | [Disque plein](disque-plein.md) |
| Erreur de certificat, `HTTP 000`, HTTPS qui ne marche pas pour un nouveau nom | [Certificat non émis](certificat-non-emis.md) |
| `Connection refused` vers la base, migrations en échec, base qui ne démarre pas | [Base de données inaccessible](base-inaccessible.md) |
| Le serveur est perdu | [Reprise après sinistre](../../guides/12-reprise-apres-sinistre.md) |

## Exercices (sans incident)

| Quand | Runbook |
| --- | --- |
| Chaque mois, par projet | [Exercice de restauration](exercice-de-restauration.md) : prouver qu'une sauvegarde se restaure |

## Les cinq règles de tout incident

1. **Annoncer** dans le canal de l'équipe : qui s'en occupe, depuis quand, quel site.
2. **Regarder avant de toucher** : `deploy.sh status`, `docker ps -a`, les journaux. Ne rien
   redémarrer « pour voir » : un redémarrage efface la trace de ce qui s'est passé.
3. **Un changement à la fois**, et noter l'heure et la commande.
4. **Ne jamais détruire de données** : pas de `down -v`, `volume rm`, `system prune -a --volumes`.
5. **Écrire le retour d'expérience** ([modèle](../retours-experience/README.md)) : l'incident
   n'est clos que lorsqu'un contrôle ou un test empêche la récidive (contrat § 5).

## Outils de lecture, sûrs à tout moment

```bash
$ /app/vps-platform/bin/vps-audit.sh               # tout le serveur, aucun effet
$ /app/vps-platform/bin/vps-hosts.sh               # sous-domaines : qui porte quoi, collisions
$ cd /app/<projet>/<env> && /app/vps-platform/bin/deploy.sh status
$ cd /app/<projet>/<env> && /app/vps-platform/bin/deploy.sh check <env>   # ne modifie rien
$ docker ps -a --format '{{.Names}} | {{.Status}}' | grep -i <projet>
```

Grafana (`https://grafana.visibilitycam.com`), dossier **Applications**, donne les journaux
de tous les projets branchés sur l'observabilité ([README de l'observabilité](../../observability/README.md)).
