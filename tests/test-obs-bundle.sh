#!/usr/bin/env bash
# bin/obs-bundle.py : l'observabilité PROPRE À UN PROJET (tableaux Grafana, règles d'alerte), publiée sans modifier la plateforme.
# Sans Docker. Ce que le test prouve : un bundle valide est déposé ; un bundle invalide est REFUSÉ et le dépôt précédent reste
# intact ; un projet ne peut pas publier de points de contact ni de politique de notification, ni écraser un uid de la plateforme
# ou d'un autre projet ; un fichier retiré du projet est retiré du dépôt.
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"
trap finish EXIT

BUNDLE="${INFRA_DIR}/bin/obs-bundle.py"
G="${WORK}/grafana"          # l'arbre de Grafana de la plateforme (factice)
SRC="${WORK}/projet/observability"
mkdir -p "${G}/dashboards/Plateforme" "${G}/provisioning/alerting" "${SRC}/dashboards" "${SRC}/alerts"

sync() { python3 "${BUNDLE}" sync --app "${1:-testapp}" --src "${2:-${SRC}}" --grafana-dir "${G}"; }
write_dash() { printf '{"uid":"%s","title":"%s","id":7,"panels":[]}\n' "$2" "$3" > "$1"; }
write_alert() {  # write_alert <fichier> <uid> [dossier]
    cat > "$1" <<YAML
apiVersion: 1
groups:
  - orgId: 1
    name: groupe
    folder: ${3:-testapp}
    interval: 1m
    rules:
      - uid: $2
        title: Règle $2
        condition: C
        data:
          - refId: A
            datasourceUid: prometheus
            model: { refId: A, expr: 'up' }
YAML
}

step "Un bundle valide est déposé"
write_dash "${SRC}/dashboards/vue.json" testapp-vue "Vue du projet"
write_alert "${SRC}/alerts/regles.yaml" testapp-r1
out="$(sync 2>&1)"
check "sortie : 1 tableau, 1 fichier d'alertes, alertes changées" test "${out}" = "dashboards=1 alerts=1 alerts_changed=1"
check "le tableau est dans un dossier au nom du projet" test -f "${G}/projets/dashboards/testapp/vue.json"
check "le tableau est déposé SANS « id » (Grafana attribue le sien)" sh -c "python3 -c 'import json,sys; sys.exit(0 if json.load(open(\"${G}/projets/dashboards/testapp/vue.json\"))[\"id\"] is None else 1)'"
check "les alertes sont déposées sous projet-<projet>-…" test -f "${G}/provisioning/alerting/projet-testapp-regles.yaml"
check "re-publier à l'identique : alertes inchangées (pas de redémarrage de Grafana à demander)" \
    test "$(sync 2>&1)" = "dashboards=1 alerts=1 alerts_changed=0"

step "Un bundle invalide est REFUSÉ et le dépôt précédent reste intact"
before="$(cat "${G}/projets/dashboards/testapp/vue.json")"
echo '{ pas du json' > "${SRC}/dashboards/casse.json"
check_not "JSON invalide refusé" sync
check "le dépôt précédent est intact après le refus" test "$(cat "${G}/projets/dashboards/testapp/vue.json")" = "${before}"
check_not "aucun fichier du bundle refusé n'a été déposé" test -f "${G}/projets/dashboards/testapp/casse.json"
rm -f "${SRC}/dashboards/casse.json"
printf '{"title":"sans uid"}\n' > "${SRC}/dashboards/sansuid.json"
check_not "tableau sans uid refusé" sync
rm -f "${SRC}/dashboards/sansuid.json"

step "Un projet ne publie que SES règles : jamais les contacts ni la politique de notification"
cp "${SRC}/alerts/regles.yaml" "${WORK}/regles.ok"
{ cat "${WORK}/regles.ok"; echo "contactPoints: [ { orgId: 1, name: pirate, receivers: [] } ]"; } > "${SRC}/alerts/regles.yaml"
check_not "points de contact dans un fichier de projet : refusé" sync
{ cat "${WORK}/regles.ok"; echo "policies: [ { orgId: 1, receiver: pirate } ]"; } > "${SRC}/alerts/regles.yaml"
check_not "politique de notification dans un fichier de projet : refusée" sync
{ cat "${WORK}/regles.ok"; echo "deleteRules: [ { orgId: 1, uid: generic-down } ]"; } > "${SRC}/alerts/regles.yaml"
check_not "suppression de règles de la plateforme : refusée" sync
write_alert "${SRC}/alerts/regles.yaml" testapp-r1 Plateforme
check_not "règle rangée dans le dossier d'un autre (Plateforme) : refusée" sync
printf 'apiVersion: 1\ngroups: [ {name: x\n' > "${SRC}/alerts/regles.yaml"
check_not "YAML invalide refusé" sync
cp "${WORK}/regles.ok" "${SRC}/alerts/regles.yaml"
check "le bundle corrigé repasse" sync

step "Aucun écrasement : un uid pris par la plateforme ou par un autre projet est refusé"
write_dash "${G}/dashboards/Plateforme/serveur.json" plateforme-serveur "Serveur"
write_alert "${G}/provisioning/alerting/generic-alerts.yaml" generic-down Plateforme
write_dash "${SRC}/dashboards/usurpe.json" plateforme-serveur "Usurpateur"
check_not "uid de tableau déjà pris par la plateforme : refusé" sync
rm -f "${SRC}/dashboards/usurpe.json"
write_alert "${SRC}/alerts/regles.yaml" generic-down
check_not "uid de règle déjà pris par la plateforme : refusé" sync
cp "${WORK}/regles.ok" "${SRC}/alerts/regles.yaml"
mkdir -p "${WORK}/autre/observability/dashboards"
write_dash "${WORK}/autre/observability/dashboards/vue.json" testapp-vue "Copie"
check_not "uid de tableau déjà pris par un AUTRE projet : refusé" sync autreapp "${WORK}/autre/observability"
check "mais le même projet peut republier ses propres uid" sync

step "Un fichier retiré du projet est retiré du dépôt"
write_dash "${SRC}/dashboards/second.json" testapp-second "Second"
check "deux tableaux déposés" test "$(sync | grep -o 'dashboards=2')" = "dashboards=2"
rm -f "${SRC}/dashboards/second.json" "${SRC}/alerts/regles.yaml"
sync >/dev/null
check_not "le tableau retiré n'est plus déposé" test -f "${G}/projets/dashboards/testapp/second.json"
check_not "le fichier d'alertes retiré n'est plus déposé" test -f "${G}/provisioning/alerting/projet-testapp-regles.yaml"

step "Retrait complet d'un projet, et entrées dangereuses"
cp "${WORK}/regles.ok" "${SRC}/alerts/regles.yaml"; sync >/dev/null
python3 "${BUNDLE}" remove --app testapp --grafana-dir "${G}" >/dev/null
check_not "remove : le dossier de tableaux du projet a disparu" test -d "${G}/projets/dashboards/testapp"
check_not "remove : ses alertes ont disparu" test -f "${G}/provisioning/alerting/projet-testapp-regles.yaml"
check "remove : les fichiers de la plateforme sont intacts" test -f "${G}/provisioning/alerting/generic-alerts.yaml"
check_not "nom de projet avec « .. » refusé (pas de sortie de l'arbre)" sync '../evil'
check_not "nom de projet avec une majuscule ou un espace refusé" sync 'Mon Projet'
check "le test ne laisse rien dans l'arbre de Grafana réel du dépôt" \
    test "$(find "${INFRA_DIR}/observability/grafana/projets/dashboards" -mindepth 1 ! -name .gitkeep 2>/dev/null | wc -l)$(find "${INFRA_DIR}/observability/grafana/provisioning/alerting" -name 'projet-*' | wc -l)" = "00"

step "Le modèle du dépôt est lui-même valide"
check "templates/observabilite-projet passe la validation (un projet qui le copie n'est pas refusé)" \
    python3 "${BUNDLE}" validate --app mon-projet --src "${INFRA_DIR}/templates/observabilite-projet/observability" --grafana-dir "${G}"
