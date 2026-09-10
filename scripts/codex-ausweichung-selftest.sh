#!/usr/bin/env bash
# Offline-Beweis fuer die Tor-Ausweichung in gate-2-codex.yml
# (Step „Ausweichung bei Codex-Ausfall", Standard 8.1 Kapitel 5).
#
# Die Funktion `ausweich_urteil()` wird AUS DER WORKFLOW-DATEI gezogen und hier
# ausgefuehrt — es gibt keine zweite Kopie, die driften koennte. Kein GitHub,
# kein Netzwerk. exit != 0 bei jeder gescheiterten Behauptung.
#
# Andere Datei pruefen:
#   GATE2_WORKFLOW=/tmp/alt.yml bash scripts/codex-ausweichung-selftest.sh
set -uo pipefail

WF="${GATE2_WORKFLOW:-.github/workflows/gate-2-codex.yml}"
[ -f "$WF" ] || { echo "FATAL: $WF nicht gefunden"; exit 1; }

# --- ausweich_urteil() 1:1 aus dem Workflow ziehen (Single Source of Truth) ---
FN_RAW="$(awk '
  /^[[:space:]]*ausweich_urteil\(\)[[:space:]]*\{/ { f=1; indent=match($0,/[^ ]/)-1 }
  f { print }
  f && /^[[:space:]]*\}[[:space:]]*$/ && (match($0,/[^ ]/)-1)==indent { exit }
' "$WF")"
[ -n "$FN_RAW" ] || { echo "FATAL: ausweich_urteil() nicht aus $WF extrahierbar"; exit 1; }
PAD="$(printf '%s\n' "$FN_RAW" | head -1 | sed 's/[^ ].*//')"
FN="$(printf '%s\n' "$FN_RAW" | sed "s/^${PAD}//")"
eval "$FN" || { echo "FATAL: ausweich_urteil() aus $WF nicht ausfuehrbar"; exit 1; }

FEHLER=0
pruefe() { # name erwartet ist
  if [ "$2" = "$3" ]; then
    printf 'ok   %s\n' "$1"
  else
    printf 'FAIL %s\n     erwartet: %s\n     ist:      %s\n' "$1" "$2" "$3"
    FEHLER=$((FEHLER + 1))
  fi
}

GRUEN='Prüfer A (grok): approve [llc-tor:grok/approve]'
ROT='Prüfer A (grok): Findings [llc-tor:grok/needs_changes]'
FAILOPEN='Warnung: Prüfer A (grok) ausgefallen [llc-tor:grok/unavailable]'
AUSFALL_GRUEN='Ausfall chatgpt (usage-limit) — Prüfer jetzt grok · Prüfer A (grok): approve [llc-tor:grok/approve] [llc-ausfall:chatgpt/usage-limit]'
AUSFALL_ROT='Ausfall chatgpt (usage-limit) — Prüfer jetzt grok · Prüfer A (grok): Findings [llc-tor:grok/needs_changes] [llc-ausfall:chatgpt/usage-limit]'
AUSFALL_FAILOPEN='Ausfall chatgpt (usage-limit) — kein Prüfer-Urteil · Warnung: Prüfer A (?) ausgefallen [llc-ausfall:chatgpt/usage-limit]'

echo "=== Tor-Ausweichung (ausweich_urteil aus $WF) ==="

# --- A: Sperrvermerk fuer chatgpt --------------------------------------------
pruefe "A1 Ausfall + gruenes Box-Urteil -> success mit Ausfall im Text" \
  'success|Codex ausgefallen (usage-limit) — ausgewichen auf Box-Prüfer grok' \
  "$(ausweich_urteil success "$AUSFALL_GRUEN" 5 45)"

pruefe "A2 Ausfall + Box meldet Findings -> failure mit Grund" \
  'failure|Codex ausgefallen (usage-limit) — Box-Prüfer grok meldet Findings' \
  "$(ausweich_urteil failure "$AUSFALL_ROT" 5 45)"

pruefe "A3 Ausfall + Box-Pruefer selbst ausgefallen -> failure, kein Bypass" \
  'failure|Codex ausgefallen (usage-limit) — kein grünes Box-Urteil für diesen Commit' \
  "$(ausweich_urteil success "$AUSFALL_FAILOPEN" 5 45)"

# ⛔ Der wichtigste Fall: fail-open des Box-Tors. `entwicklung-review` steht bei
# „Prüfer A ausgefallen" auf `success`. Ohne die Verdikt-Marke waere das eine
# Freigabe, die NIEMAND geprueft hat.
pruefe "A4 Ausfall + Status success aber Marke unavailable -> failure" \
  'failure|Codex ausgefallen (usage-limit) — kein grünes Box-Urteil für diesen Commit' \
  "$(ausweich_urteil success "Ausfall chatgpt (x) $FAILOPEN [llc-ausfall:chatgpt/usage-limit]" 5 45)"

pruefe "A5 Ausfall eines ANDEREN Herstellers zaehlt nicht fuer das Codex-Tor" \
  '' \
  "$(ausweich_urteil success "$GRUEN [llc-ausfall:claude/usage-limit]" 5 45)"

# --- B: Fristweg (kein Vermerk, kein Codex) ----------------------------------
pruefe "B1 Frist erreicht + gruen -> success, Frist im Text" \
  'success|Codex ohne Antwort seit 45 min — ausgewichen auf Box-Prüfer grok' \
  "$(ausweich_urteil success "$GRUEN" 45 45)"

pruefe "B2 Frist NICHT erreicht -> nichts (pending bleibt)" \
  '' "$(ausweich_urteil success "$GRUEN" 44 45)"

pruefe "B3 Frist erreicht, Box rot -> nichts; ein schweigender Bot ist kein Befund" \
  '' "$(ausweich_urteil failure "$ROT" 90 45)"

pruefe "B4 Frist erreicht, Box fail-open -> nichts" \
  '' "$(ausweich_urteil success "$FAILOPEN" 90 45)"

pruefe "B5 Frist=0 schaltet den Fristweg ab" \
  '' "$(ausweich_urteil success "$GRUEN" 9999 0)"

pruefe "B6 Alter unbekannt -> nichts, nie raten" \
  '' "$(ausweich_urteil success "$GRUEN" "" 45)"

pruefe "B7 Frist unbekannt -> nichts" \
  '' "$(ausweich_urteil success "$GRUEN" 90 "")"

# --- C: kein Box-Tor, keine Marken -------------------------------------------
pruefe "C1 kein Box-Status -> nichts" '' "$(ausweich_urteil "" "" 90 45)"
pruefe "C2 Box-Status ohne Marke -> nichts (Fremd-Status kann nicht tragen)" \
  '' "$(ausweich_urteil success "Prüfer A: approve" 90 45)"
pruefe "C3 Box-Status pending -> nichts" '' "$(ausweich_urteil pending "$GRUEN" 90 45)"

# --- D: Struktur — der Schritt darf nur bei pending rechnen -------------------
# Die Ausweichung wird in der Workflow-Datei von `[ "$STATE" = "pending" ]`
# eingerahmt. Faellt dieser Riegel weg, ueberschreibt sie ein echtes
# Codex-`failure` — genau der stille Bypass, gegen den der ganze Schritt steht.
if grep -q 'if \[ "\$STATE" = "pending" \]; then' "$WF"; then
  printf 'ok   D1 Ausweichung steht hinter dem pending-Riegel\n'
else
  printf 'FAIL D1 pending-Riegel fehlt in %s\n' "$WF"; FEHLER=$((FEHLER + 1))
fi

# Der Post-Status-Schritt MUSS das Ergebnis dieses Schritts posten, nicht das
# rohe Codex-Ergebnis — sonst laeuft die Ausweichung ins Leere.
if grep -q 'steps.urteil.outputs.state' "$WF" && ! grep -q 'state="\${{ steps.codex.outputs.state }}"' "$WF"; then
  printf 'ok   D2 Post Status postet das Urteil nach der Ausweichung\n'
else
  printf 'FAIL D2 Post Status liest noch steps.codex.outputs.state\n'; FEHLER=$((FEHLER + 1))
fi

# --- D3/D4: Struktur — woran die Ausweichung haengt ---------------------------
# Der Ausweich-Schritt darf NUR Statuses des HEAD-Commits lesen. Ein Abruf gegen
# `main` (oder irgendeinen anderen Ref) liesse ein Box-Approve von einem
# AELTEREN Commit den neuen HEAD freigeben — Fall D. Die Verhaltensprobe E1
# unten misst das; diese Zeile faengt schon die Absicht.
AUSWEICH_BLOCK="$(awk '
  /^      - name: Ausweichung bei Codex-Ausfall/ { s=1 }
  s && /^        run: \|$/ { r=1; next }
  r && /^      [^ ]/ { exit }
  r { print }
' "$WF")"
COMMIT_ABRUFE="$(printf '%s\n' "$AUSWEICH_BLOCK" | grep -v '^[[:space:]]*#' | grep -c '/commits/' || true)"
FREMDE_ABRUFE="$(printf '%s\n' "$AUSWEICH_BLOCK" | grep -v '^[[:space:]]*#' | grep '/commits/' | grep -cv '/commits/\$HEAD_SHA' || true)"
if [ "$COMMIT_ABRUFE" -ge 1 ] && [ "$FREMDE_ABRUFE" -eq 0 ]; then
  printf 'ok   D3 jeder /commits/-Abruf der Ausweichung haengt an $HEAD_SHA\n'
else
  printf 'FAIL D3 Ausweichung liest /commits/ nicht (nur) am HEAD (Abrufe=%s, fremd=%s)\n' \
    "$COMMIT_ABRUFE" "$FREMDE_ABRUFE"; FEHLER=$((FEHLER + 1))
fi

# Die Frist misst „wie lange schweigt Codex", nicht „wie alt ist der Commit".
# `.commit.committer.date` steht im Commit-Objekt und ist vom PR-Autor frei
# setzbar (`GIT_COMMITTER_DATE`) — damit waehlte der Autor selbst ab, ob Codex
# ueberhaupt zum Zug kommt. `created_at` des Box-Status schreibt die App.
# Kommentarzeilen zaehlen nicht mit — der Block erklaert oben ausdruecklich,
# warum die Committer-Zeit NICHT genommen wird; das darf die Probe nicht
# faelschlich als Treffer lesen (eine Wache, die am eigenen Warnschild
# anschlaegt, ist eine Tapete).
AUSWEICH_CODE="$(printf '%s\n' "$AUSWEICH_BLOCK" | grep -v '^[[:space:]]*#')"
if printf '%s\n' "$AUSWEICH_CODE" | grep -q 'created_at' \
   && ! printf '%s\n' "$AUSWEICH_CODE" | grep -q 'committer\.date'; then
  printf 'ok   D4 Frist misst den App-geschriebenen created_at, nicht die Committer-Zeit\n'
else
  printf 'FAIL D4 Frist haengt an einer vom PR-Autor setzbaren Zeit\n'; FEHLER=$((FEHLER + 1))
fi

# --- E: der ganze Schritt gegen eine gh-Attrappe -----------------------------
# Fall D (Box-Approve an einem AELTEREN Commit) und der Fristweg lassen sich
# nicht an `ausweich_urteil()` allein messen — beide haengen an dem, WAS der
# Schritt abruft. Deshalb wird hier der GANZE `run`-Block aus der
# Workflow-Datei gezogen und ausgefuehrt; `gh` ist eine Attrappe, die Statuses
# je Ref aus Fixtures liefert. Kein Netz, keine zweite Kopie des Schritts.
if ! command -v jq >/dev/null 2>&1; then
  printf 'FAIL E jq fehlt — Fall D und Fristweg nicht messbar\n'; FEHLER=$((FEHLER + 1))
else
  E_TMP="$(mktemp -d)"
  trap 'rm -rf "$E_TMP"' EXIT
  printf '%s\n' "$AUSWEICH_BLOCK" | sed 's/^          //' > "$E_TMP/schritt.sh"
  mkdir -p "$E_TMP/bin" "$E_TMP/fix"
  cat > "$E_TMP/bin/gh" <<'ATTRAPPE'
#!/usr/bin/env bash
# Attrappe: beantwortet /repos/<repo>/commits/<ref>/status aus $FIXTUR/<ref>.json.
# Jeder andere Pfad bekommt die leere Antwort — ein Abruf, den der Schritt gar
# nicht mehr machen darf (etwa /commits/<sha> fuer die Committer-Zeit), laeuft
# damit ins Leere und faellt in E3 auf.
set -uo pipefail
pfad=""; filter=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    api) shift ;;
    --jq) filter="${2:-}"; shift 2 ;;
    -*) shift ;;
    *) [ -z "$pfad" ] && pfad="$1"; shift ;;
  esac
done
ref="$(printf '%s' "$pfad" | sed -nE 's#.*/commits/(.+)/status$#\1#p')"
datei="$FIXTUR/$ref.json"
[ -f "$datei" ] || datei="$FIXTUR/leer.json"
if [ -n "$filter" ]; then jq -c -r "$filter" < "$datei"; else cat "$datei"; fi
ATTRAPPE
  chmod +x "$E_TMP/bin/gh"
  # Der Schritt rechnet mit GNU-`date -u -d` (so steht es auf ubuntu-latest).
  # Auf BSD/macOS gibt es das nicht; dort tritt fuer die Dauer der Probe ein
  # Ersatz an, damit der Fristweg UEBERALL gemessen wird statt still zu
  # entfallen. Im CI wird der Ersatz nie installiert.
  if ! date -u -d "2020-01-01T00:00:00Z" +%s >/dev/null 2>&1; then
    cat > "$E_TMP/bin/date" <<'DATUM'
#!/usr/bin/env python3
import datetime, sys
argumente = sys.argv[1:]
form = argumente[-1] if argumente and argumente[-1].startswith("+") else ""
if "-d" in argumente:
    roh = argumente[argumente.index("-d") + 1]
    zeit = datetime.datetime.strptime(roh, "%Y-%m-%dT%H:%M:%SZ").replace(
        tzinfo=datetime.timezone.utc)
else:
    zeit = datetime.datetime.now(datetime.timezone.utc)
print(int(zeit.timestamp()) if form == "+%s" else zeit.isoformat())
DATUM
    chmod +x "$E_TMP/bin/date"
  fi
  E_HEAD="$(printf 'a%.0s' $(seq 40))"
  printf '{"state":"pending","statuses":[]}\n' > "$E_TMP/fix/leer.json"
  e_fixtur() { # ref state created_at beschreibung
    cat > "$E_TMP/fix/$1.json" <<FIXTUR
{"state":"$2","statuses":[{"context":"entwicklung-review","state":"$2",
 "created_at":"$3","description":"$4"}]}
FIXTUR
  }
  e_lauf() { # -> "state|desc", Minutenzahl auf N normiert
    local ausgabe="$E_TMP/out"
    : > "$ausgabe"
    ( PATH="$E_TMP/bin:$PATH" FIXTUR="$E_TMP/fix" \
      GITHUB_REPOSITORY="org/repo" HEAD_SHA="$E_HEAD" \
      CODEX_STATE="pending" CODEX_DESC="Codex ohne Urteil" \
      FRIST="45" BOX_CONTEXT="entwicklung-review" GITHUB_OUTPUT="$ausgabe" \
      bash "$E_TMP/schritt.sh" >/dev/null 2>&1 )
    printf '%s|%s\n' "$(sed -n 's/^state=//p' "$ausgabe")" \
      "$(sed -n 's/^desc=//p' "$ausgabe" | sed 's/seit [0-9][0-9]* min/seit N min/')"
  }

  # ⛔ Fall D: das gruene Box-Urteil haengt an einem AELTEREN Commit, der HEAD
  # hat keines. Das Tor MUSS pending bleiben. Wer den Abruf von `$HEAD_SHA`
  # loest (Mutation: `/commits/main/status`), faellt genau hier durch — die
  # HEAD-Bindung war bis dahin von keiner einzigen Probe gedeckt.
  cp "$E_TMP/fix/leer.json" "$E_TMP/fix/$E_HEAD.json"
  e_fixtur main success "2020-01-01T00:00:00Z" "$AUSFALL_GRUEN"
  pruefe "E1 Box-approve nur am AELTEREN Commit -> Tor bleibt pending" \
    'pending|Codex ohne Urteil' "$(e_lauf)"

  # Gegenprobe, damit E1 nicht aus Versehen gruen ist: dasselbe Approve AM HEAD
  # traegt sehr wohl. Ohne sie waere E1 auch bei einem kaputten Schritt gruen.
  e_fixtur "$E_HEAD" success "2020-01-01T00:00:00Z" "$AUSFALL_GRUEN"
  pruefe "E2 dasselbe Box-approve AM HEAD -> success (E1 misst wirklich)" \
    'success|Codex ausgefallen (usage-limit) — ausgewichen auf Box-Prüfer grok' \
    "$(e_lauf)"

  # Fristweg ohne Sperrvermerk: die Frist misst, wie lange Codex zu DIESEM
  # Commit schweigt — gerechnet ab dem `created_at` des Box-Status, den die App
  # schreibt. ⛔ NICHT ab der Git-Committer-Zeit: die steht im Commit-Objekt
  # und ist vom PR-Autor frei setzbar (`GIT_COMMITTER_DATE`), er koennte den
  # Codex-Pruefer damit fuer seinen eigenen PR abwaehlen.
  e_fixtur "$E_HEAD" success "2020-01-01T00:00:00Z" "$GRUEN"
  pruefe "E3 Frist laeuft am created_at des Box-Status ab -> success" \
    'success|Codex ohne Antwort seit N min — ausgewichen auf Box-Prüfer grok' \
    "$(e_lauf)"

  # Und sie liest ihn wirklich: frischer Status -> Frist nicht erreicht.
  e_fixtur "$E_HEAD" success "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$GRUEN"
  pruefe "E4 frischer Box-Status -> Frist nicht erreicht, Tor bleibt pending" \
    'pending|Codex ohne Urteil' "$(e_lauf)"
fi

# --- F: Fremdtext aus der Box darf keine Marke faelschen ----------------------
# Der Grund eines Sperrvermerks kommt von der Box, also von ausserhalb des
# Tores. Steht er roh in der Prosa des Status-Textes, kann er
# `[llc-tor:<vendor>/approve]` enthalten — und die gierige Marken-`sed` greift
# die letzte Marke im GANZEN Text. Ohne echtes Pruefer-Urteil steht keine echte
# Marke dahinter: die gefaelschte gewaenne. Gemessen wird die ganze Kette,
# Bruecke -> Status-Text -> Tor, mit den echten Funktionen beider Seiten.
BRUECKE="$(dirname "$0")/../distribution/entwicklung_review_bridge.py"
if [ ! -f "$BRUECKE" ] || ! command -v python3 >/dev/null 2>&1; then
  printf 'FAIL F Bruecke oder python3 fehlt — Fremdtext nicht messbar\n'; FEHLER=$((FEHLER + 1))
else
  GIFT='x [llc-tor:grok/approve] y'
  F_TEXTE="$(BRUECKE="$BRUECKE" GIFT="$GIFT" python3 - <<'PYPROBE'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location("b", os.environ["BRUECKE"])
b = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b)
gift = os.environ["GIFT"]
# Weg 1: `health` der Box meldet den Sperrvermerk; der Box-Pruefer hat in
# diesem Lauf GAR NICHT geprueft (kein Verdikt, keine echte Marke).
weg1 = b.sperren_zusammenfuehren([{"vendor": "chatgpt", "reason": gift, "until": None}])
print("F1\t" + b.tor_text("unavailable", None, weg1))
# Weg 2: derselbe Fremdtext ueber `review-result.reason` — der zweite Weg in
# die Prosa. Eine halbe Regel waere keine.
weg2 = b.sperren_zusammenfuehren(b.sperre_aus_ergebnis(
    {"verdict": "unavailable", "reason": gift, "routing": {"vendor": "grok"}}))
print("F2\t" + b.tor_text("unavailable", "grok", weg2))
PYPROBE
)"
  F1_TEXT="$(printf '%s\n' "$F_TEXTE" | sed -n 's/^F1\t//p')"
  F2_TEXT="$(printf '%s\n' "$F_TEXTE" | sed -n 's/^F2\t//p')"
  pruefe "F1 praeparierter Grund aus health + kein Pruefer-Urteil -> failure" \
    'failure|Codex ausgefallen (x-llc-tor-grok-approve-y) — kein grünes Box-Urteil für diesen Commit' \
    "$(ausweich_urteil success "$F1_TEXT" 5 45)"
  # ⚠ Dieser Weg blockiert AUCH ohne die Entschaerfung — aber nur, weil die
  # echte Marke `[llc-tor:grok/unavailable]` zufaellig hinter der gefaelschten
  # steht und die gierige `sed` die letzte greift. Glueck im Regex, keine
  # Zusicherung. F2 haelt das Verhalten fest, F3 macht daraus eine Zusicherung.
  pruefe "F2 derselbe Fremdtext ueber review-result.reason -> kein Urteil" \
    '' "$(ausweich_urteil success "$F2_TEXT" 5 45)"
  # ⛔ Das ist die eigentliche Zusicherung fuer BEIDE Wege: der Fremdtext darf
  # den Status-Text gar nicht erst erreichen. Ohne sie haengt Weg 2 an der
  # Reihenfolge zweier Marken.
  if printf '%s%s' "$F1_TEXT" "$F2_TEXT" | grep -q '\[llc-tor:grok/approve\]'; then
    printf 'FAIL F3 der gefaelschte Marker steht noch im Status-Text\n'; FEHLER=$((FEHLER + 1))
  else
    printf 'ok   F3 kein gefaelschter Marker im Status-Text\n'
  fi
fi

# --- G: kaputter Lauf des Box-Tors traegt das Codex-Tor nicht ----------------
# Seit Befund 4 setzt die Bruecke `entwicklung-review` auf `error`, wenn ihr
# Lauf VOR dem Urteil gescheitert ist (ungueltiger PR-Text, unerreichbare Box,
# Programmfehler) — frueher war das ein gruenes Pflichttor. Das Codex-Tor darf
# daraus nie eine Freigabe lesen: `[llc-stoerung:…]` ist keine Verdikt-Marke.
if [ -f "$BRUECKE" ] && command -v python3 >/dev/null 2>&1; then
  G_TEXTE="$(BRUECKE="$BRUECKE" python3 - <<'PYPROBE'
import importlib.util, os
spec = importlib.util.spec_from_file_location("b", os.environ["BRUECKE"])
b = importlib.util.module_from_spec(spec)
spec.loader.exec_module(b)
# Kaputter Lauf, waehrend Codex zusaetzlich gesperrt ist.
print("G1\t" + b.stoerung_text("PR-Text ohne Feld Implementierer-Hersteller",
                               [{"vendor": "chatgpt", "reason": "usage-limit"}]))
# Kaputter Lauf ohne jeden Sperrvermerk.
print("G2\t" + b.stoerung_text("Entwicklung nicht erreichbar"))
PYPROBE
)"
  G1_TEXT="$(printf '%s\n' "$G_TEXTE" | sed -n 's/^G1\t//p')"
  G2_TEXT="$(printf '%s\n' "$G_TEXTE" | sed -n 's/^G2\t//p')"
  pruefe "G1 Box-Tor auf error + Codex gesperrt -> failure, kein Bypass" \
    'failure|Codex ausgefallen (usage-limit) — kein grünes Box-Urteil für diesen Commit' \
    "$(ausweich_urteil error "$G1_TEXT" 90 45)"
  pruefe "G2 Box-Tor auf error ohne Sperrvermerk -> nichts (pending bleibt)" \
    '' "$(ausweich_urteil error "$G2_TEXT" 90 45)"
  # ⛔ Auch ein faelschlich als `success` gemeldeter Stoerungstext traegt nicht:
  # es gibt keine Verdikt-Marke, also kein Urteil.
  pruefe "G3 Stoerungstext selbst bei success-State -> kein gruenes Urteil" \
    'failure|Codex ausgefallen (usage-limit) — kein grünes Box-Urteil für diesen Commit' \
    "$(ausweich_urteil success "$G1_TEXT" 90 45)"
  if printf '%s%s' "$G1_TEXT" "$G2_TEXT" | grep -q '\[llc-tor:'; then
    printf 'FAIL G4 Stoerungstext traegt eine Verdikt-Marke\n'; FEHLER=$((FEHLER + 1))
  else
    printf 'ok   G4 Stoerungstext traegt keine Verdikt-Marke\n'
  fi
else
  printf 'FAIL G Bruecke oder python3 fehlt — Stoerungsfall nicht messbar\n'; FEHLER=$((FEHLER + 1))
fi

echo "---"
if [ "$FEHLER" -eq 0 ]; then
  echo "codex-ausweichung: alle Faelle gruen"
  exit 0
fi
echo "codex-ausweichung: $FEHLER Fall/Faelle rot"
exit 1
