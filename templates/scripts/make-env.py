#!/usr/bin/env python3
"""Génère le fichier d'environnement d'un environnement (.env.<env>) à partir de son modèle, SANS jamais afficher un secret.
Modèle de la plateforme vcam-infra-deploy : à copier dans le projet sous scripts/make-env.py ; adapter SECRET_KEYS et COPIED ci-dessous
(templates/scripts/README.md).

    scripts/make-env.py <dossier-du-clone> <env> [--copy-from <fichier .env existant>]

- Chaque secret VIDE du modèle (SECRET_KEYS : mots de passe, clés, phrase de sauvegarde) reçoit une valeur aléatoire DISTINCTE.
  Le modèle laisse ces valeurs vides (règle R09 : aucun secret, même factice, dans le dépôt).
- APP_KEY est générée (32 octets aléatoires) sauf si elle est reprise de la source.
- --copy-from : reprend d'un .env existant UNIQUEMENT une liste blanche de réglages (COPIED).
  Jamais les accès à la base ou au cache, ni APP_DEBUG ou les journaux.
- Refuse d'écraser un fichier existant. Le fichier créé est lisible par le propriétaire et le groupe (660).
- N'affiche que des NOMS de variables et des comptes, jamais une valeur.
"""
import base64
import os
import re
import secrets
import sys

# À ADAPTER au projet. Reprises d'un environnement existant (--copy-from), jamais le reste : la clé d'application (les données chiffrées ne se
# lisent qu'avec elle), le courrier, et les clés des fournisseurs externes que le projet utilise (à ajouter ici, une par ligne).
COPIED = [
    "APP_KEY", "MAIL_MAILER", "MAIL_HOST", "MAIL_PORT", "MAIL_USERNAME", "MAIL_PASSWORD", "MAIL_FROM_ADDRESS",
]

# À ADAPTER au projet. Secrets générés : ils sont VIDES dans les modèles .env.<env>.example et le restent tant que ce script n'a pas tourné
# (compose et l'entrypoint refusent une valeur vide : un oubli se voit tout de suite). Un secret par ligne, distinct à chaque environnement.
SECRET_KEYS = ["DB_PASSWORD", "DB_ROOT_PASSWORD", "REDIS_PASSWORD", "BACKUP_PASSPHRASE"]


def read_env(path):
    out = {}
    for line in open(path, encoding="utf-8"):
        m = re.match(r"^\s*([A-Za-z_][A-Za-z0-9_]*)=(.*)$", line.rstrip("\n"))
        if m:
            out[m.group(1)] = m.group(2)
    return out


def main(argv):
    args = [a for a in argv if not a.startswith("--")]
    src = None
    if "--copy-from" in argv:
        i = argv.index("--copy-from")
        src = argv[i + 1]
        args = [a for a in args if a != src]
    if len(args) != 2:
        sys.exit(__doc__.strip().split("\n\n")[0] + "\n\nusage : make-env.py <dossier> <env> [--copy-from <fichier>]")
    folder, env = args
    example = os.path.join(folder, f".env.{env}.example")
    target = os.path.join(folder, f".env.{env}")
    if not os.path.isfile(example):
        sys.exit(f"modèle introuvable : {example}")
    if os.path.exists(target):
        sys.exit(f"REFUS : {target} existe déjà (rien n'est écrasé)")

    text = open(example, encoding="utf-8").read()
    copied, skipped = [], []
    source = read_env(src) if src else {}
    if src and not source:
        sys.exit(f"REFUS : {src} ne contient aucune variable lisible")

    # 1. Réglages repris de la source (liste blanche)
    for key in COPIED:
        if not src:
            break
        val = source.get(key, "").strip()
        if val in ("", "null"):
            skipped.append(key)
            continue
        pattern = re.compile(rf"(?m)^#?\s*{re.escape(key)}=.*$")
        line = f"{key}={val}"
        if pattern.search(text):
            text = pattern.sub(lambda m: line, text, count=1)
        else:
            text += f"\n{line}\n"
        copied.append(key)

    # 2. APP_KEY générée si elle n'est pas reprise
    generated_key = "APP_KEY" not in copied
    if generated_key:
        key = "base64:" + base64.b64encode(secrets.token_bytes(32)).decode()
        text = re.sub(r"(?m)^APP_KEY=.*$", lambda m: f"APP_KEY={key}", text, count=1)

    # 3. Secrets aléatoires distincts pour chaque secret vide du modèle
    n_secrets = 0
    for key in SECRET_KEYS:
        pattern = re.compile(rf"(?m)^{key}=[ \t]*$")
        if pattern.search(text):
            value = secrets.token_urlsafe(24).replace("-", "x").replace("_", "y")
            text = pattern.sub(lambda m: f"{key}={value}", text, count=1)
            n_secrets += 1

    fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o660)
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(text)
    os.chmod(target, 0o660)

    print(f"{target} créé (droits 660) : {n_secrets} secret(s) aléatoire(s) distinct(s) généré(s), valeurs non affichées")
    if src:
        print(f"repris de {os.path.basename(src)} : {', '.join(copied) if copied else 'rien'}")
        if "APP_KEY" in copied:
            print("APP_KEY reprise de la source : nécessaire pour relire les données chiffrées de l'application en service")
        if skipped:
            print(f"absents ou vides dans la source (laissés au modèle) : {', '.join(skipped)}")
    if generated_key:
        print("APP_KEY générée (nouvelle clé : les données chiffrées d'une AUTRE application ne seront pas lisibles)")


if __name__ == "__main__":
    main(sys.argv[1:])
