#!/usr/bin/env python3
"""État de la plateforme en un coup d'œil : quelle version tourne où. LECTURE SEULE, aucun secret.

  vps-overview                  tableau dans le terminal
  vps-overview --json           les mêmes données en JSON
  vps-overview --html <dossier> écrit <dossier>/index.html et status.json (écriture atomique) : c'est la page publiée par overview/

Sources : les fichiers d'état de deploy.sh ($STATE_DIR/<projet>/<env>/{current,previous,failed}), Docker (conteneurs du projet
« <projet>-<env> », leur santé) et, pour chaque conteneur, la SEULE variable VIRTUAL_HOST (noms publics) ; la branche suivie vient de
platform.env du dossier du projet. Rien d'autre n'est lu ni écrit : jamais le contenu d'un fichier d'environnement.
"""
import html
import json
import os
import re
import subprocess
import sys
import tempfile
import time

STATE_DIR = os.environ.get("STATE_DIR", "/var/lib/vps-platform")


def docker(*args):
    """Sortie standard d'une commande docker, ou None si Docker est injoignable."""
    try:
        r = subprocess.run(["docker", *args], capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return r.stdout if r.returncode == 0 else None


def lire(chemin):
    try:
        with open(chemin, encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return ""


def sha_valide(s):
    return bool(re.fullmatch(r"[0-9a-f]{40}", s))


def environnements(state_dir):
    """[(projet, env, courant, précédent, échec, horodatage du dernier déploiement)] d'après l'état de deploy.sh."""
    out = []
    try:
        projets = sorted(os.listdir(state_dir))
    except OSError:
        return None
    for projet in projets:
        base = os.path.join(state_dir, projet)
        if not os.path.isdir(base):
            continue
        for env in sorted(os.listdir(base)):
            d = os.path.join(base, env)
            if not os.path.isfile(os.path.join(d, "current")):
                continue
            courant = lire(os.path.join(d, "current"))
            out.append({
                "projet": projet, "env": env,
                "courant": courant if sha_valide(courant) else "",
                "precedent": lire(os.path.join(d, "previous")) if sha_valide(lire(os.path.join(d, "previous"))) else "",
                "echec": lire(os.path.join(d, "failed")) if sha_valide(lire(os.path.join(d, "failed"))) else "",
                "deploye_le": int(os.path.getmtime(os.path.join(d, "current"))),
            })
    return out


def conteneurs():
    """{projet compose: [{nom, service, etat, dossier}]}, santé déduite du statut Docker."""
    sortie = docker("ps", "-a", "--format",
                    '{{.Names}}\t{{.Label "com.docker.compose.project"}}\t{{.Label "com.docker.compose.service"}}'
                    '\t{{.Label "com.docker.compose.project.working_dir"}}\t{{.Status}}')
    if sortie is None:
        return None
    par_projet = {}
    for ligne in sortie.splitlines():
        champs = ligne.split("\t")
        if len(champs) != 5 or not champs[1]:
            continue
        nom, projet, service, dossier, statut = champs
        if "(unhealthy)" in statut:
            etat = "unhealthy"
        elif "(healthy)" in statut:
            etat = "healthy"
        elif "(health: starting)" in statut:
            etat = "starting"
        elif statut.startswith("Up"):
            etat = "running"
        else:
            etat = "stopped"
        par_projet.setdefault(projet, []).append({"nom": nom, "service": service, "etat": etat, "dossier": dossier})
    return par_projet


def noms_publics(noms):
    """{conteneur: [noms d'hôte]} : UNIQUEMENT VIRTUAL_HOST (le reste de l'environnement est lu en mémoire et jeté aussitôt)."""
    if not noms:
        return {}
    sortie = docker("inspect", "--format", "@@{{.Name}}\n{{range .Config.Env}}{{println .}}{{end}}", *noms)
    if sortie is None:
        return {}
    out, courant = {}, None
    for ligne in sortie.splitlines():
        if ligne.startswith("@@"):
            courant = ligne[2:].lstrip("/")
        elif courant and ligne.startswith("VIRTUAL_HOST="):
            hotes = [h.strip().lower() for h in ligne.split("=", 1)[1].split(",") if h.strip()]
            out[courant] = [h for h in hotes if re.fullmatch(r"[a-z0-9*][a-z0-9.*-]*", h)]
    return out


def branche(dossier, env):
    """La branche suivie (staging) ou gardée (production) d'après platform.env : seules les clés BRANCH_* y sont lues."""
    texte = lire(os.path.join(dossier, "platform.env")) if dossier else ""
    if not texte:
        return ""
    valeurs = {}
    for l in texte.splitlines():
        m = re.match(r"\s*(BRANCH_[A-Z0-9_]+|STAGING_BRANCH)=[\"']?([^\"'#\s]+)", l)
        if m:
            valeurs[m.group(1)] = m.group(2)
    cle = "BRANCH_" + re.sub(r"[^A-Z0-9]", "_", env.upper())
    if cle in valeurs:
        return valeurs[cle]
    if env == "staging":
        return valeurs.get("STAGING_BRANCH", "main")
    return ""


def modele(state_dir=STATE_DIR, maintenant=None):
    maintenant = maintenant or int(time.time())
    envs = environnements(state_dir)
    if envs is None:
        raise SystemExit(f"vps-overview : dossier d'état introuvable ({state_dir}) — aucun déploiement n'a eu lieu ici, ou STATE_DIR est faux")
    cont = conteneurs()
    tous = [c["nom"] for e in envs for c in (cont or {}).get(f"{e['projet']}-{e['env']}", [])]
    hotes = noms_publics(tous) if cont else {}
    for e in envs:
        liste = (cont or {}).get(f"{e['projet']}-{e['env']}", [])
        e["conteneurs"] = {"total": len(liste), "sains": sum(1 for c in liste if c["etat"] in ("healthy", "running")),
                           "en_defaut": [c["service"] for c in liste if c["etat"] in ("unhealthy", "stopped")]}
        e["domaines"] = sorted({h for c in liste for h in hotes.get(c["nom"], [])})
        e["branche"] = branche(next((c["dossier"] for c in liste if c["dossier"]), ""), e["env"])
        if cont is None:
            e["statut"] = "inconnu"
        elif not liste:
            e["statut"] = "absent"
        elif e["conteneurs"]["en_defaut"]:
            e["statut"] = "defaut"
        else:
            e["statut"] = "ok"
        e["age_s"] = max(0, maintenant - e["deploye_le"])
        e["dernier_echec"] = bool(e["echec"]) and e["echec"] != e["courant"]
    envs.sort(key=lambda e: (e["projet"], e["env"] != "staging", e["env"]))
    return {"genere_le": maintenant, "docker_joignable": cont is not None, "environnements": envs}


def duree(s):
    if s < 90:
        return "à l'instant"
    if s < 5400:
        return f"il y a {s // 60} min"
    if s < 172800:
        return f"il y a {s // 3600} h"
    return f"il y a {s // 86400} j"


def utc(t):
    return time.strftime("%Y-%m-%d %H:%M UTC", time.gmtime(t))


LIBELLE = {"ok": "en service", "defaut": "à vérifier", "absent": "aucun conteneur", "inconnu": "Docker injoignable"}


def texte(m):
    en_tete = ["PROJET", "ENV", "VERSION", "PRÉCÉDENTE", "BRANCHE", "CONTENEURS", "DÉPLOYÉE", "ÉTAT / DOMAINES"]
    rangees = []
    for e in m["environnements"]:
        c = e["conteneurs"]
        rangees.append([e["projet"], e["env"], e["courant"][:12] or "?", e["precedent"][:12] or "-", e["branche"] or "-",
                        f"{c['sains']}/{c['total']}", duree(e["age_s"]),
                        LIBELLE[e["statut"]]
                        + (f" ({', '.join(c['en_defaut'])})" if c["en_defaut"] else "")
                        + (f" — dernier échec {e['echec'][:12]}" if e["dernier_echec"] else "")
                        + (f" — {', '.join(e['domaines'])}" if e["domaines"] else "")])
    # Largeur de chaque colonne = sa cellule la plus longue (une branche « refonte/l1-socle » ne doit pas coller à la colonne suivante).
    largeurs = [max(len(l[k]) for l in [en_tete] + rangees) + 2 for k in range(7)]
    mise = lambda l: "".join(l[k].ljust(largeurs[k]) for k in range(7)) + l[7]
    return "\n".join([mise(en_tete)] + [mise(r) for r in rangees]) + f"\n\nGénéré le {utc(m['genere_le'])}."


PAGE = """<!doctype html>
<html lang="fr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="robots" content="noindex,nofollow"><meta http-equiv="refresh" content="60">
<title>État de la plateforme</title>
<style>
:root{--bg:#f6f7f9;--fg:#1c2330;--mut:#5d6778;--card:#fff;--line:#dfe3ea;--ok:#1b7f4c;--warn:#b25e09;--bad:#b3261e;--chip:#eef1f6}
@media (prefers-color-scheme:dark){:root:not([data-theme=light]){--bg:#11151c;--fg:#e6e9ef;--mut:#9aa4b5;--card:#1a2029;--line:#2b3340;--ok:#4cc38a;--warn:#f0a042;--bad:#f2766e;--chip:#252d39}}
*{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font:15px/1.5 system-ui,-apple-system,Segoe UI,sans-serif}
main{max-width:1100px;margin:0 auto;padding:24px 16px}h1{font-size:1.4rem;margin:0 0 4px}.sub{color:var(--mut);margin:0 0 20px}
.warn{background:var(--card);border:1px solid var(--warn);border-left-width:4px;padding:10px 14px;border-radius:6px;margin:0 0 16px}
.wrap{overflow-x:auto;background:var(--card);border:1px solid var(--line);border-radius:8px}
table{width:100%;border-collapse:collapse;min-width:760px}th,td{text-align:left;padding:9px 12px;border-bottom:1px solid var(--line);vertical-align:top}
th{font-size:.78rem;text-transform:uppercase;letter-spacing:.04em;color:var(--mut)}tr:last-child td{border-bottom:0}
code{font:13px ui-monospace,SFMono-Regular,Menlo,monospace;background:var(--chip);padding:1px 6px;border-radius:4px}
.s{font-weight:600;white-space:nowrap}.s.ok{color:var(--ok)}.s.defaut,.s.inconnu{color:var(--warn)}.s.absent{color:var(--mut)}.bad{color:var(--bad)}
.mut{color:var(--mut)}a{color:inherit}
</style></head><body><main>
<h1>État de la plateforme</h1>
<p class="sub">Consultation seule · généré le @@QUAND@@ · se rafraîchit toutes les minutes</p>
@@ALERTE@@<div class="wrap"><table>
<thead><tr><th>Projet</th><th>Env.</th><th>Version</th><th>Précédente</th><th>Branche</th><th>Conteneurs</th><th>Déployée</th><th>État</th></tr></thead>
<tbody>
@@LIGNES@@</tbody></table></div>
<p class="sub" style="margin-top:14px">Les versions sont les 12 premiers caractères du commit. Un environnement « aucun conteneur » n'a pas de pile démarrée sous le nom attendu (projet-environnement).</p>
</main></body></html>
"""


def page(m):
    e_ = html.escape
    lignes = []
    for e in m["environnements"]:
        c = e["conteneurs"]
        etat = f"<span class='s {e['statut']}'>{e_(LIBELLE[e['statut']])}</span>"
        if c["en_defaut"]:
            etat += "<br><span class='bad'>" + e_(", ".join(c["en_defaut"])) + "</span>"
        if e["dernier_echec"]:
            etat += f"<br><span class='bad'>dernier échec <code>{e_(e['echec'][:12])}</code></span>"
        if e["domaines"]:
            etat += "<br>" + "<br>".join(f"<a href='https://{e_(h)}' rel='noopener'>{e_(h)}</a>" if "*" not in h else e_(h) for h in e["domaines"])
        lignes.append(
            f"<tr><td><strong>{e_(e['projet'])}</strong></td><td>{e_(e['env'])}</td>"
            f"<td><code>{e_(e['courant'][:12] or '?')}</code></td><td>{('<code>' + e_(e['precedent'][:12]) + '</code>') if e['precedent'] else '<span class=mut>-</span>'}</td>"
            f"<td>{e_(e['branche']) or '<span class=mut>-</span>'}</td><td>{c['sains']}/{c['total']}</td>"
            f"<td title='{e_(utc(e['deploye_le']))}'>{e_(duree(e['age_s']))}</td><td>{etat}</td></tr>\n")
    alerte = "" if m["docker_joignable"] else "<p class='warn'>Docker n'a pas répondu : l'état des conteneurs est inconnu, seules les versions sont fiables.</p>\n"
    # replace, pas « % » : le CSS de la page contient des « % ».
    return PAGE.replace("@@QUAND@@", e_(utc(m["genere_le"]))).replace("@@ALERTE@@", alerte).replace("@@LIGNES@@", "".join(lignes))


def ecrire_atomique(chemin, contenu):
    d = os.path.dirname(chemin)
    fd, tmp = tempfile.mkstemp(dir=d, prefix=".tmp-")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(contenu)
    os.chmod(tmp, 0o644)
    os.replace(tmp, chemin)


def main(argv):
    if "-h" in argv or "--help" in argv:
        print(__doc__)
        return 0
    if argv and argv[0] == "--html":
        if len(argv) != 2:
            print("usage : vps-overview --html <dossier>", file=sys.stderr)
            return 2
        os.makedirs(argv[1], exist_ok=True)
        m = modele()
        ecrire_atomique(os.path.join(argv[1], "status.json"), json.dumps(m, ensure_ascii=False, indent=1))
        ecrire_atomique(os.path.join(argv[1], "index.html"), page(m))
        return 0
    if argv and argv[0] not in ("--json",):
        print(f"vps-overview : option inconnue « {argv[0]} » (--json, --html <dossier>)", file=sys.stderr)
        return 2
    m = modele()
    print(json.dumps(m, ensure_ascii=False, indent=1) if argv else texte(m))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
