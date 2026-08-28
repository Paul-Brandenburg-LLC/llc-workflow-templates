#!/usr/bin/env bash
# Offline-Testharness fuer die Haertung des Pre-PR-Quartetts.
# PB LLC: Entwicklung §3.b.2 v7.6.1 — llc-ops-backlog#1096.
#
# Der Befund hatte drei Stellen in derselben Composite Action, an denen das
# Pflicht-Gate gruen meldete, ohne geprueft zu haben:
#
#   S-1  Fehlte CLAUDE.md oder ihre Frontmatter, setzte die Action still
#        `tier=0`, uebersprang Pruefung 2a VOLLSTAENDIG und meldete Erfolg —
#        ausgerechnet fuer den PR, der die Konfigurationsdatei entfernt, und
#        derselbe PR haette AGENTS.md und gate-2-codex.yml mitnehmen koennen.
#   S-2  Der Eingabewert `tier: auto` uebernahm den PR-kontrollierten Wert ohne
#        Vergleich; ein PR stufte damit ein Tier-1-Repo auf Tier 4 herab.
#   S-3  Die Pflichtfeld-Pruefung las jedes Feld als `yq -r ".$k // \"\""`. Der
#        Alternativ-Operator `//` greift bei `null` UND bei `false` — ein
#        gueltiges `b2c_funnel: false` wurde zu "" und als *fehlt* gemeldet.
#
# Vier Teile, alle ohne Netzwerk:
#   A) Verhaltensprobe S-3 — was `//` mit einem gesetzten `false` macht, und
#      dass `has()` es richtig sieht. Zeigt den Defekt direkt statt ihn zu
#      beschreiben.
#   B) Verhaltensproben S-1/S-2 gegen konfiguration-lesen.py (M-Q-1, M-Q-2,
#      M-Q-5, M-Q-6) und S-3 gegen pruefung-2a.sh (M-Q-3, M-Q-4).
#   C) Statischer Waechter ueber die KLASSE: keine Pflichtfeld-Leseoperation in
#      der Action darf je wieder ueber `//` laufen, und kein `tier=0`-Zweig darf
#      mit Erfolg enden.
#   D) Verteilweg (M-Q-7): der gerenderte Caller ist gueltige YAML und pinnt den
#      actions/-Pfad; und `migrate` ist fuer pre-pr-quartett.yml ausgeschlossen —
#      sonst ueberschriebe der Gate-2-Codex-Wrapper sie in jedem Consumer.
#
# Die Teile C und D pruefen bewusst die KLASSE statt der bekannten Fundstellen —
# sonst faellt eine kuenftig hinzugefuegte Leseoperation wieder nur einem
# Menschen auf, und zwar erst, wenn `quartett` Pflicht-Check geworden ist und
# die betroffenen Repos merge-tot sind.
# exit != 0 bei jeder fehlgeschlagenen Assertion → CI-Job 'checks' schlaegt fehl.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
WURZEL=$PWD
AKTION="$WURZEL/.github/actions/pre-pr-quartett"
FAIL=0
ok()   { printf '  ok   — %s\n' "$1"; }
fail() { printf '  FAIL — %s\n' "$1"; FAIL=1; }

command -v jq >/dev/null 2>&1 || { echo "jq fehlt — Test kann nicht urteilen"; exit 1; }
python3 -c 'import yaml' 2>/dev/null || { echo "PyYAML fehlt — Test kann nicht urteilen"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# A) Verhaltensprobe: was der Alternativ-Operator mit einem gesetzten `false` macht
# ---------------------------------------------------------------------------
echo "A) Alternativ-Operator gegen has() bei einem gesetzten false"

# jq statt yq: dieselbe Operator-Semantik, aber ohne Zusatzwerkzeug auf dem
# Runner. Der Defekt liegt im Operator, nicht im Werkzeug.
FM_FALSE='{"b2c_funnel": false, "customer": false}'
ALT=$(printf '%s' "$FM_FALSE" | jq -r '.b2c_funnel // ""')
HAT=$(printf '%s' "$FM_FALSE" | jq -r 'has("b2c_funnel")')

if [ -z "$ALT" ]; then
  ok "der alte Weg (// \"\") macht aus 'b2c_funnel: false' einen Leerstring — der Defekt ist reproduziert"
else
  fail "der alte Weg liefert '$ALT' — die Probe trifft den Befund nicht mehr, Testaufbau pruefen"
fi
if [ "$HAT" = "true" ]; then
  ok "der neue Weg (has) sieht 'b2c_funnel: false' als gesetzt"
else
  fail "has() meldet ein gesetztes false als fehlend — Kernannahme der Korrektur ist falsch"
fi
# Gegenprobe, damit has() nicht einfach alles durchlaesst:
if [ "$(printf '{"customer": false}' | jq -r 'has("b2c_funnel")')" = "false" ]; then
  ok "Gegenprobe: has() meldet ein wirklich fehlendes Feld als fehlend"
else
  fail "has() meldet ein fehlendes Feld als vorhanden — die Pruefung waere wirkungslos"
fi

# ---------------------------------------------------------------------------
# B) Verhaltensproben gegen die ausgelieferten Skripte
# ---------------------------------------------------------------------------
echo "B) konfiguration-lesen.py und pruefung-2a.sh am echten Skript"

# Ruft konfiguration-lesen.py mit einem Fixture und meldet den Exit-Code.
lesen() {  # $1=Kopf-Inhalt  $2=Basis-Inhalt ("" = Basis traegt keine Datei)  $3=TIER_EINGABE
  local kopf="$TMP/kopf.md" basis="$TMP/basis.md" hat=0
  # %b, nicht %s: die Fixtures tragen \n als Escape. Mit %s landen sie
  # woertlich in der Datei, jedes Fixture waere einzeilig — und die Proben,
  # die einen Abbruch erwarten, bestuenden aus dem falschen Grund.
  printf '%b' "$1" > "$kopf"
  if [ -n "$2" ]; then printf '%b' "$2" > "$basis"; hat=1; fi
  KOPF_DATEI="$kopf" BASIS_DATEI="$basis" BASIS_HAT_DATEI="$hat" \
    TIER_EINGABE="${3:-auto}" python3 "$AKTION/konfiguration-lesen.py" 2>"$TMP/err" >"$TMP/out"
  echo $?
}
FM1='---\ntier: "1"\nb2c_funnel: false\ncustomer: false\nhealthz_queue_threshold_s: "5"\nvisual_regression_paths:\n  - "tests/"\ncritical_paths:\n  - "scripts/"\n---\n# Repo\n'
FM4='---\ntier: "4"\ncustomer: false\n---\n# Repo\n'

# M-Q-1: CLAUDE.md fehlt ganz. Frueher: tier=0, Exit 0, Gate gruen.
KOPF_DATEI="$TMP/gibtesnicht.md" BASIS_HAT_DATEI=0 TIER_EINGABE=auto \
  python3 "$AKTION/konfiguration-lesen.py" >/dev/null 2>&1
if [ $? -ne 0 ]; then ok "M-Q-1: fehlende CLAUDE.md bricht ab (frueher: Exit 0 und Gate gruen)"
else fail "M-Q-1: fehlende CLAUDE.md laeuft durch — S-1 ist NICHT geschlossen"; fi

# M-Q-2: keine Frontmatter / nicht geschlossen / Tier ausserhalb 1-4.
[ "$(lesen '# Repo ohne Frontmatter\n' '' auto)" -ne 0 ] \
  && ok "M-Q-2a: CLAUDE.md ohne Frontmatter bricht ab" \
  || fail "M-Q-2a: fehlende Frontmatter laeuft durch"
[ "$(lesen '---\ntier: "1"\n# nie geschlossen\n' '' auto)" -ne 0 ] \
  && ok "M-Q-2b: nicht geschlossene Frontmatter bricht ab" \
  || fail "M-Q-2b: nicht geschlossene Frontmatter laeuft durch"
[ "$(lesen '---\ntier: "7"\ncustomer: false\n---\n' '' auto)" -ne 0 ] \
  && ok "M-Q-2c: tier ausserhalb 1-4 bricht ab" \
  || fail "M-Q-2c: unbrauchbares tier laeuft durch — 2a faellt stumm durch alle case-Zweige"
[ "$(lesen '---\ncustomer: false\n---\n' '' auto)" -ne 0 ] \
  && ok "M-Q-2d: fehlender Schluessel 'tier' bricht ab" \
  || fail "M-Q-2d: fehlendes tier laeuft durch"
# Gegenprobe zu M-Q-2: eine vollstaendige Frontmatter muss durchgehen.
[ "$(lesen "$FM4" '' auto)" -eq 0 ] \
  && ok "M-Q-2e (Gegenprobe): eine gueltige Frontmatter laeuft durch" \
  || fail "M-Q-2e: eine gueltige Frontmatter wird abgelehnt — die Haertung ist zu scharf"

# M-Q-5 / M-Q-6: Herabstufung ablehnen, Hochstufung zulassen.
[ "$(lesen "$FM4" "$FM1" auto)" -ne 0 ] \
  && ok "M-Q-5: Herabstufung Ziel-Branch tier=1 -> PR tier=4 wird abgelehnt" \
  || fail "M-Q-5: Herabstufung laeuft durch — S-2 ist NICHT geschlossen"
[ "$(lesen "$FM1" "$FM4" auto)" -eq 0 ] \
  && ok "M-Q-6 (Gegenprobe): Hochstufung tier=4 -> tier=1 passiert (strengere Seite)" \
  || fail "M-Q-6: Hochstufung wird abgelehnt — die Haertung blockiert das Richtige"
[ "$(lesen "$FM1" "$FM1" auto)" -eq 0 ] \
  && ok "M-Q-6b (Gegenprobe): gleiches Tier auf beiden Seiten passiert" \
  || fail "M-Q-6b: unveraendertes Tier wird abgelehnt"
# Ein unlesbarer Vergleichsstand ist kein fehlender — sonst waere "Basis kaputt"
# der bequemste Weg an S-2 vorbei.
[ "$(lesen "$FM4" '# Basis ohne Frontmatter\n' auto)" -ne 0 ] \
  && ok "M-Q-5b: unlesbarer Vergleichsstand bricht ab statt die Pruefung zu ueberspringen" \
  || fail "M-Q-5b: unlesbare Basis laesst eine moegliche Herabstufung durch"
# M-Q-6c: auch ein AUSDRUECKLICH gesetztes Tier wird gegen die Basis geprueft.
# Die Eingabe steht in .github/workflows/pre-pr-quartett.yml — einer Datei im
# Repo, die der PR veraendern kann. Ein Schutz, der nur bei `auto` greift, waere
# mit einer Einzeiler-Aenderung an der Caller-Datei zu umgehen; genau das hat
# die Codex-Vorpruefung auf diesem Zweig als P1 gemeldet.
[ "$(lesen "$FM4" "$FM1" 4)" -ne 0 ] \
  && ok "M-Q-6c: ein ausdruecklich gesetztes tier=4 gegen Basis tier=1 wird abgelehnt (Eingabe ist PR-kontrolliert)" \
  || fail "M-Q-6c: ein gesetztes tier umgeht den Herabstufungsschutz — S-2 ist ueber die Caller-Datei zu umgehen"
# Gegenprobe: die strengere Richtung bleibt zulaessig, sonst waere jedes Repo
# mit ausdruecklichem Tier blockiert.
[ "$(lesen "$FM1" "$FM4" 1)" -eq 0 ] \
  && ok "M-Q-6e (Gegenprobe): ein ausdruecklich gesetztes tier=1 gegen Basis tier=4 passiert" \
  || fail "M-Q-6e: die strengere Richtung wird faelschlich blockiert"
[ "$(lesen "$FM4" "" 4)" -eq 0 ] \
  && ok "M-Q-6f (Gegenprobe): ohne CLAUDE.md im Ziel-Branch gibt es nichts zu vergleichen" \
  || fail "M-Q-6f: fehlende Basis-Datei blockiert faelschlich"
[ "$(lesen "$FM4" '' 9)" -ne 0 ] \
  && ok "M-Q-6d: eine unbrauchbare tier-Eingabe bricht ab" \
  || fail "M-Q-6d: unbrauchbare tier-Eingabe laeuft durch"

# M-Q-3 / M-Q-4: 2a gegen ein gesetztes `false` und gegen ein wirklich fehlendes Feld.
REPO="$TMP/repo"
mkdir -p "$REPO/.github/workflows" "$REPO/scripts" "$REPO/tests"
touch "$REPO/AGENTS.md" "$REPO/.github/workflows/gate-2-codex.yml" "$REPO/scripts/x.sh"
zweia() { ( cd "$REPO" && KONFIG_JSON="$1" bash "$AKTION/pruefung-2a.sh" >/dev/null 2>&1 ); echo $?; }

JSON_FALSE='{"tier":1,"frontmatter":{"healthz_queue_threshold_s":5,"b2c_funnel":false,"visual_regression_paths":["tests/"],"critical_paths":["scripts/"],"customer":false}}'
JSON_FEHLT='{"tier":1,"frontmatter":{"healthz_queue_threshold_s":5,"visual_regression_paths":["tests/"],"critical_paths":["scripts/"],"customer":false}}'
JSON_T4_FALSE='{"tier":4,"frontmatter":{"customer":false}}'

[ "$(zweia "$JSON_FALSE")" -eq 0 ] \
  && ok "M-Q-3: Tier 1 mit 'b2c_funnel: false' laeuft gruen (der belegte Ausfall von pb-revenue)" \
  || fail "M-Q-3: ein gesetztes false gilt weiter als fehlend — S-3 ist NICHT geschlossen"
[ "$(zweia "$JSON_T4_FALSE")" -eq 0 ] \
  && ok "M-Q-3b: Tier 4 mit 'customer: false' laeuft gruen (der belegte Ausfall von VoicePrompt-app)" \
  || fail "M-Q-3b: ein gesetztes false gilt weiter als fehlend"
[ "$(zweia "$JSON_FEHLT")" -ne 0 ] \
  && ok "M-Q-4 (Gegenprobe): ein wirklich fehlendes Pflichtfeld blockt weiterhin" \
  || fail "M-Q-4: die Pruefung ist abgeschafft statt repariert — sie laesst ein fehlendes Feld durch"
# Gegenprobe zu 2a-(i)/(ii): die Datei-Existenz-Pruefungen muessen weiter greifen.
( cd "$REPO" && mv AGENTS.md AGENTS.md.weg )
[ "$(zweia "$JSON_FALSE")" -ne 0 ] \
  && ok "M-Q-4b (Gegenprobe): fehlende AGENTS.md blockt weiterhin" \
  || fail "M-Q-4b: 2a-(i) greift nicht mehr"
( cd "$REPO" && mv AGENTS.md.weg AGENTS.md )
# Gegenprobe zu 2a-(vii): ein Glob ins Leere blockt weiterhin.
[ "$(zweia '{"tier":2,"frontmatter":{"critical_paths":["gibtsnicht/**"],"customer":false}}')" -ne 0 ] \
  && ok "M-Q-4c (Gegenprobe): ein critical_paths-Glob ohne Treffer blockt weiterhin" \
  || fail "M-Q-4c: 2a-(vii) greift nicht mehr"

# v7.7.0 Typ-Staffelung (M-TF-1…5): Hard nur, wo der Bestand typrein ist und
# ein Typfehler eine Pruefung still umgeht; Warnstufe darf NIE blocken —
# sonst macht der Bump gemessene Bestandsrepos rot.
[ "$(zweia '{"tier":2,"frontmatter":{"critical_paths":false,"customer":false}}')" -ne 0 ] \
  && ok "M-TF-1: 'critical_paths: false' blockt — der has()-Freibrief ist zu" \
  || fail "M-TF-1: ein Nicht-Listen-Wert gilt weiter als vorhanden und umgeht die Glob-Pruefung still"
[ "$(zweia '{"tier":2,"frontmatter":{"critical_paths":[],"customer":false}}')" -eq 0 ] \
  && ok "M-TF-2 (Gegenprobe): eine leere Liste laeuft gruen mit Warnung (14 Bestandsrepos)" \
  || fail "M-TF-2: die leere Liste blockt — der Bump macht Bestandsrepos rot"
[ "$(zweia '{"tier":4,"frontmatter":{"customer":true}}')" -eq 0 ] \
  && ok "M-TF-3: 'customer: true' warnt nur (Enum-Migration ausstehend), blockt nicht" \
  || fail "M-TF-3: die customer-Warnstufe blockt"
[ "$(zweia '{"tier":4,"frontmatter":{"customer":"B2C-public"}}')" -eq 0 ] \
  && ok "M-TF-3b (Gegenprobe): ein §8.4.7-Enum-String laeuft gruen" \
  || fail "M-TF-3b: ein gueltiger Enum-Wert blockt"
[ "$(zweia '{"tier":1,"frontmatter":{"healthz_queue_threshold_s":"abc","b2c_funnel":false,"visual_regression_paths":["tests/"],"critical_paths":["scripts/"],"customer":false}}')" -ne 0 ] \
  && ok "M-TF-4: ein Nicht-Zahl-Threshold blockt" \
  || fail "M-TF-4: der Threshold-Typ wird nicht geprueft"
[ "$(zweia '{"tier":1,"frontmatter":{"healthz_queue_threshold_s":5,"b2c_funnel":"nein","visual_regression_paths":["tests/"],"critical_paths":["scripts/"],"customer":false}}')" -eq 0 ] \
  && ok "M-TF-5: ein String-b2c_funnel warnt nur (zwei Bestandsrepos), blockt nicht" \
  || fail "M-TF-5: die b2c_funnel-Warnstufe blockt"

# ---------------------------------------------------------------------------
# C) Statischer Waechter ueber die Klasse
# ---------------------------------------------------------------------------
echo "C) Klassen-Waechter in der Action"

# C1: keine Pflichtfeld-Leseoperation ueber den Alternativ-Operator. `//` bleibt
# dort zulaessig, wo ein fehlender Wert wirklich wie ein leerer behandelt werden
# darf (z.B. `.critical_paths[]? // empty`) — verboten ist die Form
# `.<feld> // ""`, mit der die Pflichtfelder gelesen wurden.
# Kommentarzeilen sind ausgenommen — der Defekt muss in der Datei
# beschreibbar bleiben, in der er behoben wurde.
nur_code() { grep -rhv -e '^[[:space:]]*#' "$AKTION" --include='*.sh' --include='*.yml' --include='*.py'; }
MUSTER_ALTOP='\.[A-Za-z_$][A-Za-z0-9_${}]*[[:space:]]*//[[:space:]]*\\*"\\*"'
if nur_code | grep -nE "$MUSTER_ALTOP" >/dev/null 2>&1; then
  fail "C1: eine Leseoperation der Form '.feld // \"\"' ist zurueck in der Action — genau der Defekt aus #1096"
  nur_code | grep -nE "$MUSTER_ALTOP" | sed 's/^/       /'
else
  ok "C1: keine Pflichtfeld-Leseoperation laeuft ueber den Alternativ-Operator"
fi
# Gegenprobe zum Waechter selbst: er muss den Defekt erkennen, wenn er da ist.
if printf 'VAL=$(printf "%%s" "$FM" | yq -r ".$k // \\"\\"")\n' | grep -qE "$MUSTER_ALTOP"; then
  ok "C1b (Gegenprobe): der Waechter erkennt die alte Leseform, wenn sie auftaucht"
else
  fail "C1b: der Waechter erkennt die alte Leseform NICHT — er waere ein blinder Passagier"
fi

# C2: kein Zweig darf bei fehlender Konfiguration mit Erfolg enden. Die alte
# Fassung tat genau das zweimal (`echo "tier=0" >> "$GITHUB_OUTPUT"` + exit 0).
# Die Regel ist bewusst die einfachste scharfe: die Zeichenfolge kommt in der
# Action gar nicht mehr vor. Deshalb schreibt auch die Prosa dort "Tier 0" —
# ein Waechter, der zwischen Code und Fliesstext unterscheiden muss, hat selbst
# eine Irrflaeche, und die waere hier groesser als der Nutzen.
MUSTER_TIER0='(^|[^A-Za-z0-9_.])tier[[:space:]]*=[[:space:]]*.?0[^0-9]'
if nur_code | grep -nE "$MUSTER_TIER0" >/dev/null 2>&1; then
  fail "C2: ein 'tier=0'-Zweig ist zurueck in der Action — S-1 waere wieder offen"
  nur_code | grep -nE "$MUSTER_TIER0" | sed 's/^/       /'
else
  ok "C2: kein 'tier=0'-Ausweg mehr in der Action"
fi
# Gegenprobe zum Waechter selbst — sonst meldet er ewig gruen.
if printf 'echo "tier=0" >> "$GITHUB_OUTPUT"\n' | grep -qE "$MUSTER_TIER0"; then
  ok "C2b (Gegenprobe): der Waechter erkennt das Setzen von tier=0, wenn es auftaucht"
else
  fail "C2b: der Waechter erkennt das Setzen von tier=0 NICHT — er waere ein blinder Passagier"
fi

# C3: die Action ruft ihre Pruefungen als versionierte Skripte auf — sonst laesst
# sich ihr Verhalten offline gar nicht beweisen (die Lehre aus v7.3.1: ein
# Werkzeug ohne Repo hat keine Stelle, an der ein Bump es erreicht).
for skript in konfiguration-lesen.py konfiguration-lesen.sh pruefung-2a.sh; do
  if [ -f "$AKTION/$skript" ]; then ok "C3: $skript liegt im Repo und ist pruefbar"
  else fail "C3: $skript fehlt — das Verhalten der Action ist offline nicht beweisbar"; fi
done

# ---------------------------------------------------------------------------
# D) Verteilweg (M-Q-7)
# ---------------------------------------------------------------------------
echo "D) Verteilweg fuer pre-pr-quartett.yml"

CALLER=$(bash "$WURZEL/scripts/render-pre-pr-quartett-caller.sh" v9.9.9 2>/dev/null)
if printf '%s' "$CALLER" | python3 -c 'import yaml,sys; yaml.safe_load(sys.stdin)' 2>/dev/null; then
  ok "M-Q-7a: der gerenderte Caller ist gueltige YAML"
else
  fail "M-Q-7a: der gerenderte Caller ist keine gueltige YAML"
fi
if printf '%s' "$CALLER" | grep -q 'llc-workflow-templates/\.github/actions/pre-pr-quartett@v9\.9\.9'; then
  ok "M-Q-7b: der Caller pinnt den actions/-Pfad auf den uebergebenen Tag"
else
  fail "M-Q-7b: der Caller pinnt den actions/-Pfad nicht — die Welle traefe die falsche Stelle"
fi
if printf '%s' "$CALLER" | grep -q '\${{ github.repository }}'; then
  ok "M-Q-7c: das GitHub-Ausdruck-Literal ueberlebt das Rendern woertlich"
else
  fail "M-Q-7c: \${{ github.repository }} wurde beim Rendern expandiert"
fi

# M-Q-7d: die Klasse. `migrate` rendert einen Gate-2-Codex-Wrapper; faellt
# pre-pr-quartett.yml je in diesen Zweig, ueberschreibt die Welle sie in jedem
# Consumer. Ihr Pin steht auf `.github/actions/...`, den der Erkennungs-Ausdruck
# bis v7.6.0 nicht traf — PINNED_REF war leer, und leer hiess `migrate`.
# shellcheck source=scripts/pin-bump-decide.sh
source "$WURZEL/scripts/pin-bump-decide.sh"
DECISION_MODE=""; DECISION_REASON=""
pin_bump_decide "pre-pr-quartett.yml" "" "v1.7.0"
if [ "$DECISION_MODE" != "migrate" ]; then
  ok "M-Q-7d: pre-pr-quartett.yml faellt nie in den migrate-Zweig (Modus: $DECISION_MODE)"
else
  fail "M-Q-7d: migrate fuer pre-pr-quartett.yml — der Gate-2-Codex-Wrapper wuerde sie in jedem Consumer ueberschreiben"
fi
# Gegenprobe: fuer echte Reusable-Caller bleibt migrate erhalten.
DECISION_MODE=""; DECISION_REASON=""
pin_bump_decide "gate-2-codex.yml" "" "v1.7.0"
if [ "$DECISION_MODE" = "migrate" ]; then
  ok "M-Q-7e (Gegenprobe): gate-2-codex.yml migriert weiterhin"
else
  fail "M-Q-7e: migrate ist auch fuer echte Reusable-Caller weg (Modus: $DECISION_MODE)"
fi
# Der bestehende Pin muss weiterhin gebumpt werden.
DECISION_MODE=""; DECISION_REASON=""
pin_bump_decide "pre-pr-quartett.yml" "v1.1.2" "v1.7.0"
if [ "$DECISION_MODE" = "pinbump" ]; then
  ok "M-Q-7f: der Bestands-Pin v1.1.2 wird auf den neuen Tag gebumpt"
else
  fail "M-Q-7f: der Bestands-Pin wird nicht gebumpt (Modus: $DECISION_MODE) — die 24 Repos blieben stehen"
fi

# M-Q-7g: der Erkennungs-Ausdruck in propagate-templates.yml muss den
# actions/-Pfad treffen. Sonst bleibt PINNED_REF leer und M-Q-7d ist die
# einzige verbliebene Sicherung.
if grep -q 'actions/${TEMPLATE%.yml}' "$WURZEL/.github/workflows/propagate-templates.yml"; then
  ok "M-Q-7g: propagate-templates.yml erkennt auch Composite-Action-Pins"
else
  fail "M-Q-7g: die Pin-Erkennung kennt nur workflows/-Pfade — PINNED_REF bliebe leer"
fi
# M-Q-7h: create-if-missing muss die Datei fuehren.
if grep -q 'auto-pin-bump.yml|pre-pr-quartett.yml' "$WURZEL/.github/workflows/propagate-templates.yml"; then
  ok "M-Q-7h: create-if-missing fuehrt pre-pr-quartett.yml"
else
  fail "M-Q-7h: create-if-missing fuehrt die Datei nicht — die elf Repos ohne sie blieben leer"
fi

echo
if [ "$FAIL" -ne 0 ]; then echo "=== pre-pr-quartett-selftest: FEHLGESCHLAGEN ==="; exit 1; fi
echo "=== pre-pr-quartett-selftest: alle Proben bestanden ==="
