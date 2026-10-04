#!/usr/bin/env bash
# La documentation du dépôt (docs/README.md) : chaque lien relatif et chaque ancre existent,
# chaque page est référencée dans l'index de son dossier, et aucun secret n'a été commité.
# Ne demande ni Docker ni réseau : python3 et grep seulement.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
trap finish EXIT
command -v python3 >/dev/null || { red "python3 requis"; exit 2; }

cd "${INFRA_DIR}"

step "Liens relatifs et ancres"
python3 - > "${WORK}/liens.txt" <<'EOF'
import os, re, sys

def slug(titre):
    # Algorithme des ancres GitHub : minuscules, on garde lettres, chiffres, espaces, « - » et « _ »,
    # puis chaque espace devient « - » (un « — » entouré d'espaces donne donc « -- »).
    t = titre.strip().lower()
    t = re.sub(r"[^\w\s-]", "", t, flags=re.UNICODE)
    return t.replace(" ", "-")

def lire(chemin):
    fence, lignes = False, []
    for l in open(chemin, encoding="utf-8").read().split("\n"):
        if l.startswith("```"):
            fence = not fence
            continue
        if not fence:
            lignes.append(l)
    return lignes

def ancres(chemin):
    vus, res = {}, set()
    for l in lire(chemin):
        m = re.match(r"#{1,6}\s+(.*)", l)
        if m:
            s = slug(m.group(1))
            n = vus.get(s, 0)
            res.add(s if n == 0 else f"{s}-{n}")
            vus[s] = n + 1
    return res

md = []
for racine, dossiers, fichiers in os.walk("."):
    dossiers[:] = [d for d in dossiers if d not in (".git", "node_modules")]
    md += [os.path.join(racine, f) for f in fichiers if f.endswith(".md")]

cache = {}
for f in sorted(md):
    for l in lire(f):
        l = re.sub(r"`[^`]*`", "", l)          # pas de lien dans du code en ligne
        for m in re.finditer(r"\]\(([^)\s]+)\)", l):
            cible = m.group(1)
            if cible.startswith(("http://", "https://", "mailto:")):
                continue
            chemin, _, ancre = cible.partition("#")
            if chemin == "":
                dest = f
            else:
                dest = os.path.normpath(os.path.join(os.path.dirname(f), chemin))
                if not os.path.exists(dest):
                    print(f"LIEN CASSÉ  {f[2:]} -> {cible}")
                    continue
            if ancre and dest.endswith(".md") and os.path.isfile(dest):
                if dest not in cache:
                    cache[dest] = ancres(dest)
                if ancre not in cache[dest]:
                    print(f"ANCRE ABSENTE  {f[2:]} -> {cible}")
EOF
cat "${WORK}/liens.txt"
check "aucun lien relatif cassé" test "$(grep -c '^LIEN CASSÉ' "${WORK}/liens.txt" || true)" = 0
check "aucune ancre absente" test "$(grep -c '^ANCRE ABSENTE' "${WORK}/liens.txt" || true)" = 0

step "Chaque page est référencée dans l'index de son dossier"
liste() {  # liste <dossier> <index> <motif de fichier> — affiche les pages absentes de l'index
    local dossier="$1" index="$2" motif="$3" f
    for f in "${dossier}"/${motif}; do
        [[ "$(basename "${f}")" == README.md ]] && continue
        grep -q "$(basename "${f}")" "${index}" || echo "${f}"
    done
}
check "chaque guide figure dans guides/README.md" test -z "$(liste guides guides/README.md '[0-9]*.md')"
check "chaque runbook figure dans docs/runbooks/README.md" test -z "$(liste docs/runbooks docs/runbooks/README.md '*.md')"
check "chaque retour d'expérience figure dans docs/retours-experience/README.md" test -z "$(liste docs/retours-experience docs/retours-experience/README.md '2*.md')"
check "chaque ADR figure dans docs/adr/README.md" test -z "$(liste docs/adr docs/adr/README.md '[0-9]*.md')"
check "chaque inventaire figure dans docs/inventaire/README.md" test -z "$(liste docs/inventaire docs/inventaire/README.md '2*.md')"
check "chaque page de référence figure dans docs/README.md" test -z "$(liste docs/reference docs/README.md '*.md')"
check "chaque document de docs/ figure dans docs/README.md" test -z "$(liste docs docs/README.md '0*.md')"

step "Aucun secret dans la documentation"
secrets() { grep -rIn -E 'ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----' --include='*.md' . | grep -v '^./.git/' || true; }
check "aucun jeton ni clé privée dans les fichiers Markdown" test -z "$(secrets)"
