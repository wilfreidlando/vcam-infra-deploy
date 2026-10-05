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

step "Cohérence interne de la documentation"
# Constats du 2026-10-05, tous passés au travers du contrôle des seuls liens : un tableau d'index cassé (une ligne à 3 colonnes, une autre à 1),
# « clauses C1 à C12 » dans trois documents alors que le contrat en compte 14, l'adresse réelle du serveur dans un guide.
cat > "${WORK}/coherence.py" <<'PY'
import os, re, sys
md = []
for racine, dossiers, fichiers in os.walk("."):
    dossiers[:] = [d for d in dossiers if d not in (".git", "node_modules")]
    md += [os.path.join(racine, f) for f in fichiers if f.endswith(".md")]
bad = []
dernier = max(int(m) for m in re.findall(r"^\| C(\d+) ", open("docs/05-contrat-projet.md", encoding="utf-8").read(), flags=re.M))
OKIP = re.compile(r"^(10\.|127\.|0\.0\.0\.0|255\.|172\.(1[6-9]|2\d|3[01])\.|192\.168\.|203\.0\.113\.|198\.51\.100\.|192\.0\.2\.|1\.1\.1\.1$|8\.8\.8\.8$|9\.9\.9\.9$)")
for f in sorted(md):
    fence, lignes = False, []
    for l in open(f, encoding="utf-8").read().split("\n"):
        if l.lstrip().startswith("```"): fence = not fence; continue
        lignes.append((l, fence))
    # tableaux : même nombre de colonnes sur toutes les lignes
    i = 0
    while i < len(lignes):
        l, fc = lignes[i]
        if not fc and re.match(r"\s*\|.*\|\s*$", l) and i + 1 < len(lignes) and re.match(r"\s*\|[\s:|-]+\|\s*$", lignes[i + 1][0]):
            n = lambda s: re.sub(r"`[^`]*`", "x", s.strip()).replace("\\|", "x").count("|") - 1
            attendu, j = n(l), i + 2
            while j < len(lignes) and re.match(r"\s*\|.*\|\s*$", lignes[j][0]):
                if n(lignes[j][0]) != attendu: bad.append(f"{f[2:]}: tableau mal formé ({n(lignes[j][0])} colonnes au lieu de {attendu}) : {lignes[j][0].strip()[:60]}")
                j += 1
            i = j; continue
        i += 1
    for l, fc in lignes:
        for m in re.finditer(r"clauses? C1 (?:à|-) ?C(\d+)", l):
            # « C1 à C3 » peut désigner un sous-ensemble voulu (profil « site simple ») : on ne signale que les plages presque complètes mais en retard sur le contrat
            if 10 <= int(m.group(1)) < dernier: bad.append(f"{f[2:]}: « clauses C1 à C{m.group(1)} » alors que le contrat va jusqu'à C{dernier}")
        for m in re.finditer(r"(?<![\d.])(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})(?![\d.])", l):
            ip = m.group(0)
            if all(int(x) <= 255 for x in m.groups()) and not OKIP.match(ip) and not re.search(r"(?i)version|v\d|image|:\d|PostgreSQL|MariaDB|MySQL|Valkey|nginx|PHP", l):
                bad.append(f"{f[2:]}: adresse IP publique « {ip} » (mettre <IP-du-VPS> ou une adresse de documentation 203.0.113.x)")
        if not fc and re.search(r"\bClaude\b|\bAnthropic\b|\bChatGPT\b|\bCopilot\b|\bl'IA\b|\bagent IA\b|\bassistant IA\b", l):
            bad.append(f"{f[2:]}: mention d'un assistant IA : {l.strip()[:70]}")
print("\n".join(bad)); sys.exit(1 if bad else 0)
PY
check "tableaux bien formés, clauses citées = clauses du contrat, aucune adresse IP publique, aucun assistant IA cité" python3 "${WORK}/coherence.py"
python3 "${WORK}/coherence.py" >&2 || true   # en cas d'échec, le journal nomme chaque écart
