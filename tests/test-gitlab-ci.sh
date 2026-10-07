#!/usr/bin/env bash
# Les modèles de pipeline GitLab (templates/gitlab-ci/) : profil A (staging puis production) et profil B (production seule).
# Ce que le test prouve, sur chaque modèle rendu avec des valeurs d'exemple : un YAML valide sans jeton <…> oublié ; un nouveau push annule
# ce qui est inutile (workflow:auto_cancel) ; le DÉPLOIEMENT n'est jamais interruptible (deploy.sh n'a pas de reprise) ; chaque job a un délai
# maximal ; build et déploiement partagent un verrou ; la production n'est JAMAIS automatique ; aucune commande « docker » ; le tag du runner SSH
# est demandé partout. Puis, pour qu'il ne passe pas à vide, il CASSE chaque garantie dans une copie et exige un échec.
# Ne demande ni Docker ni réseau : python3 et PyYAML.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
trap finish EXIT
python3 -c 'import yaml' 2>/dev/null || { red "PyYAML requis (apt install python3-yaml, ou python3 -m pip install pyyaml)"; exit 2; }
cd "${INFRA_DIR}/templates/gitlab-ci"

# Valeurs d'exemple : tous les jetons du modèle y sont remplacés.
render() {  # render <modèle> <sortie>
    sed -e 's#<PROJET>#monprojet#g' -e 's#<BRANCHE_STAGING>#develop#g' -e 's#<BRANCHE_PROD>#main#g' -e 's#<TAG_RUNNER>#runner-monprojet#g' \
        -e 's#<DOSSIER_DU_PROJET>#/app/APPS/monprojet#g' -e 's#<URL_STAGING>#https://dev.monprojet.example#g' -e 's#<URL_PROD>#https://monprojet.example#g' "$1" > "$2"
}

cat > "${WORK}/assert.py" <<'PY'
"""assert.py <fichier> <a|b> : liste les garanties NON tenues (une par ligne) ; code 1 s'il y en a."""
import re, sys, yaml
f, profil = sys.argv[1], sys.argv[2]
texte = open(f).read()
d = yaml.safe_load(texte)
ko = []
def veut(cond, quoi):
    if not cond: ko.append(quoi)
J = lambda n: d.get(n) or {}
jobs = [n for n in d if n not in ("workflow", "stages", "variables", "default", "include") and not n.startswith(".")]
veut(not re.search(r"<[A-Z_]+>", texte), "un jeton <…> n'a pas été remplacé")
veut(d.get("workflow", {}).get("auto_cancel", {}).get("on_new_commit") == "interruptible", "workflow:auto_cancel:on_new_commit doit valoir interruptible")
veut(not re.search(r"\bdocker\b", " ".join(" ".join(map(str, J(n).get("script", []))) for n in jobs)), "aucune commande docker dans le pipeline (tout passe par vps-deploy)")
veut(d.get(".vps", {}).get("tags") == ["runner-monprojet"], "le tag du runner SSH doit être demandé (.vps:tags)")
for n in jobs:
    veut(J(n).get("extends") == ".vps", f"{n} doit hériter de .vps (tag du runner, PATH, GIT_STRATEGY)")
    veut(bool(J(n).get("timeout")), f"{n} doit avoir un délai maximal (timeout)")
for n in ("deploy-staging", "deploy-prod"):
    if n in d:
        veut(J(n).get("interruptible") is False, f"{n} ne doit JAMAIS être interruptible (pas de reprise sur interruption)")
        veut(bool(J(n).get("resource_group")), f"{n} doit avoir un resource_group (un seul déploiement à la fois)")
veut("deploy-prod" in d and all(r.get("when") == "manual" for r in J("deploy-prod").get("rules", [])) and bool(J("deploy-prod").get("rules")), "deploy-prod doit être MANUEL sur chacune de ses règles (jamais automatique)")
veut(J("deploy-prod").get("allow_failure") is False, "deploy-prod ne doit pas pouvoir échouer en silence (allow_failure: false)")
sc = " ".join(map(str, J("deploy-prod").get("script", [])))
veut("promote" in sc and "--env prod" in sc, "deploy-prod doit promouvoir (promote … --env prod)")
if profil == "a":
    veut(d.get("stages") == ["build", "deploy"], "stages doit valoir [build, deploy]")
    veut(J("build-staging").get("interruptible") is True and J("build-staging").get("needs") == [], "build-staging doit être annulable et démarrer sans attendre (needs: [])")
    veut(J("deploy-staging").get("needs") == ["build-staging"], "deploy-staging doit attendre build-staging")
    veut(J("deploy-prod").get("needs") == ["deploy-staging"], "deploy-prod doit dépendre de deploy-staging (même image)")
    veut(J("build-staging").get("resource_group") and J("build-staging").get("resource_group") == J("deploy-staging").get("resource_group"), "build et déploiement de staging doivent partager le même verrou")
    veut(J("deploy-prod").get("resource_group") not in (None, J("deploy-staging").get("resource_group")), "la production doit avoir son propre verrou")
    veut("build" in " ".join(map(str, J("build-staging").get("script", []))) and "up staging" in " ".join(map(str, J("deploy-staging").get("script", []))), "build-staging construit, deploy-staging déploie (up)")
    br = set(re.findall(r'"([^"]+)"', " ".join(r.get("if", "") for n in jobs for r in J(n).get("rules", []))))
    veut(br == {"develop"}, f"tous les jobs doivent suivre la branche du staging ({br})")
else:
    veut(d.get("stages") == ["deploy"], "stages doit valoir [deploy] (pas de staging)")
    veut(not any("staging" in n for n in jobs), "aucun job de staging dans le profil B")
    veut(sc.index("check prod") < sc.index("promote") if "check prod" in sc and "promote" in sc else False, "deploy-prod doit contrôler (check prod) AVANT de promouvoir")
    t = str(J("deploy-prod").get("timeout", "0m"))
    veut(t.endswith("m") and int(t[:-1]) >= 40 or t.endswith("h"), "deploy-prod construit l'image sur place : délai d'au moins 40 minutes")
print("\n".join(ko)); sys.exit(1 if ko else 0)
PY

chk() {  # chk <description> <fichier> <profil> : la liste des garanties non tenues s'affiche si le test échoue
    local out; out="$(python3 "${WORK}/assert.py" "$2" "$3" 2>&1)" && ok "$1" || { ko "$1"; sed 's/^/      /' <<< "${out}"; }
}
chk_casse() {  # chk_casse <description> <fichier> <profil> <fragment> : DOIT échouer, et POUR LA BONNE RAISON (le fragment est dans le message)
    local out; out="$(python3 "${WORK}/assert.py" "$2" "$3" 2>&1)" && { ko "$1 : le test n'a RIEN vu"; return; }
    grep -qF -- "$4" <<< "${out}" && ok "$1" || { ko "$1 : échec, mais pas pour la bonne raison (attendu : « $4 »)"; sed 's/^/      /' <<< "${out}"; }
}

step "Profil A : staging puis production"
render profil-a-staging-puis-production.gitlab-ci.yml "${WORK}/a.yml"
chk "toutes les garanties du profil A sont tenues" "${WORK}/a.yml" a

step "Profil B : production seule"
render profil-b-production-seule.gitlab-ci.yml "${WORK}/b.yml"
chk "toutes les garanties du profil B sont tenues" "${WORK}/b.yml" b

step "Le test voit chaque faute (une copie cassée exprès par garantie)"
mutate() {  # mutate <entrée> <sortie> <ancien> <nouveau> : remplace la PREMIÈRE occurrence, échoue si elle est absente
    python3 - "$@" <<'PY'
import sys
src, out, old, new = sys.argv[1:5]
s = open(src).read()
if old not in s: sys.exit(f"motif absent : {old!r}")
open(out, "w").write(s.replace(old, new, 1))
PY
}
mutate "${WORK}/a.yml" "${WORK}/m1.yml" "  interruptible: false
  timeout: 20m
  needs: [build-staging]" "  interruptible: true
  timeout: 20m
  needs: [build-staging]"
chk_casse "déploiement rendu interruptible" "${WORK}/m1.yml" a "ne doit JAMAIS être interruptible"
mutate "${WORK}/a.yml" "${WORK}/m2.yml" "  timeout: 40m
" ""
chk_casse "délai maximal retiré du build" "${WORK}/m2.yml" a "doit avoir un délai maximal"
mutate "${WORK}/a.yml" "${WORK}/m3.yml" "- if: \$CI_COMMIT_BRANCH == \"develop\"
    when: manual
  allow_failure: false" "- if: \$CI_COMMIT_BRANCH == \"develop\"
  allow_failure: false"
chk_casse "production rendue automatique" "${WORK}/m3.yml" a "doit être MANUEL"
mutate "${WORK}/a.yml" "${WORK}/m4.yml" "  - \$DEPLOY up staging \"\$CI_COMMIT_SHA\"" "  - docker compose up -d"
chk_casse "commande docker écrite dans le pipeline" "${WORK}/m4.yml" a "aucune commande docker"
mutate "${WORK}/a.yml" "${WORK}/m5.yml" "  resource_group: monprojet-prod" "  resource_group: monprojet-staging"
chk_casse "production sur le verrou du staging" "${WORK}/m5.yml" a "propre verrou"
mutate "${WORK}/a.yml" "${WORK}/m6.yml" "  - runner-monprojet" "  - autre-runner"
chk_casse "mauvais tag de runner" "${WORK}/m6.yml" a "le tag du runner SSH"
mutate "${WORK}/a.yml" "${WORK}/m7.yml" "    on_new_commit: interruptible" "    on_new_commit: conservative"
chk_casse "annulation automatique désactivée" "${WORK}/m7.yml" a "workflow:auto_cancel"
mutate "${WORK}/b.yml" "${WORK}/m8.yml" "  - \$DEPLOY check prod
  - \$DEPLOY promote" "  - \$DEPLOY promote"
chk_casse "profil B : promotion sans contrôle préalable" "${WORK}/m8.yml" b "AVANT de promouvoir"
printf '%s\n' "# <JETON_OUBLIE>" >> "${WORK}/m10.yml"; cat "${WORK}/a.yml" >> "${WORK}/m10.yml"
chk_casse "jeton <…> oublié dans le fichier" "${WORK}/m10.yml" a "n'a pas été remplacé"

step "Tous les jetons des modèles sont expliqués dans le README"
for j in $(grep -ohE '<[A-Z_]+>' *.yml | sort -u); do
    check "jeton ${j} documenté" grep -qF "${j}" README.md
done
