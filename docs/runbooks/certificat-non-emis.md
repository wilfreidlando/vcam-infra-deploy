# Runbook : le certificat HTTPS n'est pas émis

| Gravité | Qui prévenir |
| --- | --- |
| Un nouveau site : le responsable du projet. Un site en production dont le certificat expire : responsable de la plateforme | selon le cas |

## 1. Symptôme

- `curl https://<nom>` répond « HTTP 000 » ou une erreur de certificat juste après le
  démarrage d'un conteneur.
- Le navigateur affiche « connexion non sécurisée » ou un certificat par défaut.

**Premier réflexe : attendre une à deux minutes.** Le conteneur peut être prêt **avant** que
le certificat soit émis (constaté le 2026-10-04 au démarrage de Grafana). Ne pas relancer le
projet : cela ne ferait que retarder.

## 2. Diagnostic

```bash
$ getent hosts <nom>                                      # le nom pointe-t-il vers le serveur ?
$ docker logs --since 10m nginx-proxy-acme 2>&1 | grep -i <nom> | tail -10
$ echo | openssl s_client -connect 127.0.0.1:443 -servername <nom> 2>/dev/null \
    | openssl x509 -noout -subject -issuer -dates         # certificat réellement servi
$ docker inspect <conteneur> --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -E 'VIRTUAL_HOST|LETSENCRYPT_HOST'
```

> Le `grep` ne laisse passer que `VIRTUAL_HOST` et `LETSENCRYPT_HOST`. **Ne jamais lancer
> `docker inspect` sans ce filtre dans un message ou un ticket** : l'environnement d'un
> conteneur contient ses secrets.

| Ce que vous voyez | Cause probable | Action |
| --- | --- | --- |
| `getent` ne répond rien ou une autre adresse | Le DNS ne pointe pas vers le serveur | Corriger l'enregistrement (guide 2) ; attendre la propagation |
| `LETSENCRYPT_HOST` absent ou différent de `VIRTUAL_HOST` | Oubli dans le compose | Les mettre à la même valeur ; recréer **ce** projet |
| Journal : `too many certificates` | Limite Let's Encrypt (50 nouveaux certificats par semaine pour le domaine) | Attendre ; ne pas créer ni supprimer des sous-domaines en boucle |
| Journal : erreur de validation, port 80 injoignable | Le port 80 est filtré, ou `nginx-proxy` est en erreur | `docker exec nginx-proxy nginx -t` ; [Site en panne, section 4](site-en-panne.md#4-nginx-proxy-en-erreur) |
| Certificat d'un autre nom | `nginx-proxy` sert son certificat par défaut | Attendre l'émission ; vérifier le nom exact (la casse compte) |
| Certificat expire dans moins de 30 jours et ne se renouvelle pas | Le companion échoue | Journal du companion ; `docker restart nginx-proxy-acme` seulement si rien d'autre n'explique |

## 3. Vérification

```bash
$ curl -s -o /dev/null -w 'HTTP %{http_code}\n' https://<nom>/        # 200 attendu, sans -k
$ echo | openssl s_client -connect 127.0.0.1:443 -servername <nom> 2>/dev/null | openssl x509 -noout -issuer -dates
```

L'émetteur est Let's Encrypt, la validité de 90 jours. Le renouvellement est automatique
30 jours avant l'échéance.

## 4. Ce qu'il ne faut pas faire

- Supprimer le dossier des certificats de `nginx-proxy` pour « forcer » : on atteint la limite
  hebdomadaire de Let's Encrypt.
- Redémarrer `nginx-proxy` à chaque essai : il sert tous les sites.
- Contourner avec un certificat auto-signé en production.

## 5. Après

Si le cas est nouveau, retour d'expérience. Une sonde externe sur chaque site de production
(guide 8) prévient d'un certificat qui échoue.
