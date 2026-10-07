#!/usr/bin/env python3
"""Publie l'observabilité PROPRE À UN PROJET (tableaux Grafana, règles d'alerte) sans modifier la plateforme.

Le projet livre, dans son dépôt :

    observability/dashboards/*.json     des tableaux Grafana (JSON exporté), chacun avec un « uid »
    observability/alerts/*.yaml         des règles d'alerte (format de provisionnement Grafana)

et `deploy.sh obs-sync` (ou la fin d'un déploiement de production) les dépose dans l'arbre de Grafana de la plateforme, dans des
emplacements ignorés par git :

    <grafana>/projets/dashboards/<projet>/*.json            un dossier Grafana par projet
    <grafana>/provisioning/alerting/projet-<projet>-*.yaml  les règles d'alerte du projet

Garde-fous (un projet ne doit JAMAIS pouvoir casser Grafana ni toucher à ce qui n'est pas à lui) :
  - JSON et YAML lus AVANT dépôt : un fichier invalide est refusé, le dépôt précédent reste intact ;
  - un tableau doit avoir un « uid » ; il est déposé sans « id » (Grafana attribue le sien) ;
  - un fichier d'alertes ne peut contenir QUE « apiVersion » et « groups » : ni points de contact, ni politique de
    notification, ni suppression de règles (cela changerait ce que toute la plateforme envoie) ;
  - le dossier d'un groupe d'alertes doit être le nom du projet ;
  - aucun « uid » ne doit déjà exister ailleurs (plateforme ou autre projet) : refus plutôt qu'écrasement ;
  - les REQUÊTES (PromQL, LogQL) doivent être bien formées : parenthèses, accolades et crochets équilibrés, valeur de sélecteur entre guillemets,
    jamais de guillemet échappé à tort (« \" » dans une chaîne YAML entre apostrophes reste un antislash littéral : Grafana la refuse à l'évaluation,
    la règle ne s'évalue jamais et personne n'est prévenu).

Sortie : une ligne « dashboards=N alerts=M alerts_changed=0|1 ». Code de sortie : 0 ok, 3 refus (message sur stderr), 2 usage.
"""
import argparse
import glob
import json
import os
import re
import shutil
import sys

try:
    import yaml
except ImportError:  # pragma: no cover - dit clairement quoi installer
    yaml = None

APP_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,62}$")
FILE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,100}$")
ALERT_TOP_KEYS = {"apiVersion", "groups"}


def refuse(msg):
    print(f"obs-bundle : REFUSÉ — {msg}", file=sys.stderr)
    sys.exit(3)


def read_json(path):
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError) as e:
        refuse(f"{os.path.basename(path)} n'est pas un JSON valide ({e})")


def read_yaml(path):
    if yaml is None:
        refuse("PyYAML est requis pour vérifier les alertes (apt install python3-yaml)")
    try:
        with open(path, encoding="utf-8") as f:
            return yaml.safe_load(f)
    except (OSError, yaml.YAMLError) as e:
        refuse(f"{os.path.basename(path)} n'est pas un YAML valide ({str(e).splitlines()[0] if str(e) else e})")


OPEN, CLOSE = "([{", ")]}"
PAIR = dict(zip(CLOSE, OPEN))


def query_problem(expr):
    """Un défaut de forme dans une requête PromQL/LogQL, ou None. Parcourt le texte en respectant les chaînes (« " » et « ` »)."""
    if not isinstance(expr, str) or not expr.strip():
        return None
    stack, i, n = [], 0, len(expr)
    while i < n:
        c = expr[i]
        if c in "\"`":
            end, j = c, i + 1
            while j < n and expr[j] != end:
                j += 2 if (expr[j] == "\\" and end == '"') else 1
            if j >= n:
                return f"chaîne non fermée ({c}…)"
            i = j + 1
            continue
        if c == "\\":
            return f"antislash hors d'une chaîne, à la position {i} : un guillemet échappé (« \\\" ») dans une chaîne YAML entre apostrophes reste un antislash littéral"
        if c in OPEN:
            stack.append(c)
        elif c in CLOSE:
            if not stack or stack.pop() != PAIR[c]:
                return f"« {c} » sans son ouvrante"
        # Dans un sélecteur { … }, la valeur d'un label est TOUJOURS une chaîne : label="x", label=~"x", label!="x", label!~"x".
        if c in "=!~" and stack and stack[-1] == "{":
            j = i
            while j < n and expr[j] in "=!~":
                j += 1
            if expr[i:j] in ("=", "!=", "=~", "!~"):
                k = j
                while k < n and expr[k] == " ":
                    k += 1
                if k >= n or expr[k] not in "\"`":
                    return f"la valeur d'un label doit être entre guillemets (après « {expr[i:j]} », position {k})"
            i = j
            continue
        i += 1
    if stack:
        return f"« {stack[-1]} » jamais fermée"
    return None


def rule_uids(doc):
    """Les uid des règles d'un fichier de provisionnement (liste vide si la forme est inattendue)."""
    out = []
    if isinstance(doc, dict):
        for g in doc.get("groups") or []:
            for r in (g or {}).get("rules") or []:
                if isinstance(r, dict) and r.get("uid"):
                    out.append(str(r["uid"]))
    return out


def existing_uids(gdir, app):
    """uid de tableaux et de règles déjà pris, hors dépôt actuel de ce projet."""
    dash, rules = {}, {}
    for f in glob.glob(os.path.join(gdir, "dashboards", "**", "*.json"), recursive=True):
        try:
            u = json.load(open(f, encoding="utf-8")).get("uid")
        except (OSError, ValueError, AttributeError):
            continue
        if u:
            dash[str(u)] = "la plateforme"
    for f in glob.glob(os.path.join(gdir, "projets", "dashboards", "*", "*.json")):
        owner = os.path.basename(os.path.dirname(f))
        if owner == app:
            continue
        try:
            u = json.load(open(f, encoding="utf-8")).get("uid")
        except (OSError, ValueError, AttributeError):
            continue
        if u:
            dash[str(u)] = f"le projet {owner}"
    for f in glob.glob(os.path.join(gdir, "provisioning", "alerting", "*.y*ml")):
        name = os.path.basename(f)
        if name.startswith(f"projet-{app}-"):
            continue
        m = re.match(r"^projet-(.+?)-", name)
        owner = f"le projet {m.group(1)}" if m else "la plateforme"
        if yaml is None:
            continue
        try:
            for u in rule_uids(yaml.safe_load(open(f, encoding="utf-8"))):
                rules[u] = owner
        except (OSError, yaml.YAMLError):
            continue
    return dash, rules


def validate(app, src, gdir):
    dashboards, alerts = [], []
    ddir = os.path.join(src, "dashboards")
    adir = os.path.join(src, "alerts")
    taken_d, taken_r = existing_uids(gdir, app)
    seen_d, seen_r = {}, {}

    for path in sorted(glob.glob(os.path.join(ddir, "*.json"))):
        name = os.path.basename(path)
        if not FILE_RE.match(name):
            refuse(f"nom de fichier de tableau invalide : {name}")
        d = read_json(path)
        if not isinstance(d, dict):
            refuse(f"{name} : un tableau Grafana est un objet JSON")
        uid = d.get("uid")
        if not uid or not isinstance(uid, str):
            refuse(f"{name} : le tableau n'a pas d'« uid » (obligatoire : sans lui Grafana en invente un et les liens cassent)")
        if len(uid) > 40:
            refuse(f"{name} : « uid » trop long ({len(uid)} caractères, 40 au plus)")
        if not d.get("title"):
            refuse(f"{name} : le tableau n'a pas de « title »")
        if uid in taken_d:
            refuse(f"{name} : l'uid « {uid} » existe déjà ({taken_d[uid]})")
        if uid in seen_d:
            refuse(f"{name} : l'uid « {uid} » est aussi dans {seen_d[uid]}")
        seen_d[uid] = name
        for panel in d.get("panels") or []:
            for t in (panel or {}).get("targets") or []:
                msg = query_problem((t or {}).get("expr"))
                if msg:
                    refuse(f"{name} : requête du panneau « {(panel or {}).get('title', '?')} » invalide ({msg}) : {str(t.get('expr'))[:90]}")
        d["id"] = None
        dashboards.append((name, d))

    for path in sorted(glob.glob(os.path.join(adir, "*.y*ml"))):
        name = os.path.basename(path)
        if not FILE_RE.match(name):
            refuse(f"nom de fichier d'alertes invalide : {name}")
        doc = read_yaml(path)
        if not isinstance(doc, dict):
            refuse(f"{name} : un fichier d'alertes est un objet YAML (apiVersion, groups)")
        extra = set(doc) - ALERT_TOP_KEYS
        if extra:
            refuse(
                f"{name} : clé(s) interdite(s) {sorted(extra)}. Un projet ne publie que des RÈGLES (groups) : "
                "les points de contact et la politique de notification sont ceux de la plateforme"
            )
        if doc.get("apiVersion") != 1:
            refuse(f"{name} : apiVersion doit valoir 1")
        groups = doc.get("groups")
        if not isinstance(groups, list) or not groups:
            refuse(f"{name} : « groups » doit être une liste non vide")
        for g in groups:
            if not isinstance(g, dict) or not g.get("name") or not g.get("rules"):
                refuse(f"{name} : chaque groupe a un « name » et des « rules »")
            if g.get("folder") != app:
                refuse(f"{name} : le dossier du groupe « {g.get('name')} » doit être « {app} » (le nom du projet), pas « {g.get('folder')} »")
            if g.get("orgId", 1) != 1:
                refuse(f"{name} : orgId doit valoir 1")
            for r in g["rules"]:
                for k in ("uid", "title", "condition", "data"):
                    if not isinstance(r, dict) or not r.get(k):
                        refuse(f"{name} : une règle du groupe « {g['name']} » n'a pas de « {k} »")
                for q in r["data"] if isinstance(r["data"], list) else []:
                    msg = query_problem(((q or {}).get("model") or {}).get("expr"))
                    if msg:
                        refuse(f"{name} : la règle « {r['uid']} » (donnée {(q or {}).get('refId', '?')}) a une requête invalide ({msg}) : {str(q['model']['expr'])[:90]}")
                u = str(r["uid"])
                if u in taken_r:
                    refuse(f"{name} : l'uid de règle « {u} » existe déjà ({taken_r[u]})")
                if u in seen_r:
                    refuse(f"{name} : l'uid de règle « {u} » est aussi dans {seen_r[u]}")
                seen_r[u] = name
        alerts.append((name, path))
    return dashboards, alerts


def replace_dir(target, files):
    """Remplace un dossier d'un bloc : on écrit à côté, puis on échange (jamais de dépôt à moitié fait)."""
    parent = os.path.dirname(target)
    os.makedirs(parent, exist_ok=True)
    tmp = os.path.join(parent, f".tmp-{os.path.basename(target)}")
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(tmp)
    for name, d in files:
        with open(os.path.join(tmp, name), "w", encoding="utf-8") as f:
            json.dump(d, f, ensure_ascii=False, indent=2)
            f.write("\n")
    shutil.rmtree(target, ignore_errors=True)
    if files:
        os.rename(tmp, target)
    else:
        shutil.rmtree(tmp, ignore_errors=True)


def read_all(paths):
    out = {}
    for p in paths:
        with open(p, encoding="utf-8") as f:
            out[os.path.basename(p)] = f.read()
    return out


def deposit(app, src, gdir):
    dashboards, alerts = validate(app, src, gdir)
    target_d = os.path.join(gdir, "projets", "dashboards", app)
    replace_dir(target_d, dashboards)

    adir = os.path.join(gdir, "provisioning", "alerting")
    os.makedirs(adir, exist_ok=True)
    old = read_all(glob.glob(os.path.join(adir, f"projet-{app}-*.y*ml")))
    new = {}
    for name, path in alerts:
        with open(path, encoding="utf-8") as f:
            new[f"projet-{app}-{name}"] = f.read()
    for name in old:
        if name not in new:
            os.remove(os.path.join(adir, name))
    for name, text in new.items():
        with open(os.path.join(adir, name), "w", encoding="utf-8") as f:
            f.write(text)
    changed = 0 if old == new else 1
    print(f"dashboards={len(dashboards)} alerts={len(alerts)} alerts_changed={changed}")


def remove(app, gdir):
    shutil.rmtree(os.path.join(gdir, "projets", "dashboards", app), ignore_errors=True)
    adir = os.path.join(gdir, "provisioning", "alerting")
    n = 0
    for f in glob.glob(os.path.join(adir, f"projet-{app}-*.y*ml")):
        os.remove(f)
        n += 1
    print(f"dashboards=0 alerts=0 alerts_changed={1 if n else 0}")


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("action", choices=["sync", "validate", "remove"])
    ap.add_argument("--app", required=True)
    ap.add_argument("--src", help="dossier observability/ du projet")
    ap.add_argument("--grafana-dir", required=True, help="observability/grafana de la plateforme")
    a = ap.parse_args()
    if not APP_RE.match(a.app):
        refuse(f"nom d'application invalide « {a.app} » (minuscules, chiffres, - et _)")
    if a.action == "remove":
        remove(a.app, a.grafana_dir)
        return
    if not a.src or not os.path.isdir(a.src):
        print("obs-bundle : --src doit être un dossier existant", file=sys.stderr)
        sys.exit(2)
    if a.action == "validate":
        d, al = validate(a.app, a.src, a.grafana_dir)
        print(f"dashboards={len(d)} alerts={len(al)} valide")
        return
    deposit(a.app, a.src, a.grafana_dir)


if __name__ == "__main__":
    main()
