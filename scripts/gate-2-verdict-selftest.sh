#!/usr/bin/env bash
# Offline-Testharness fuer die Verdict-Erkennung + die Ereignis-Unabhaengigkeit
# des Scope-Riegels in gate-2-codex.yml.
#
# Deckt den Deadlock ab, der jeden Doc-only-PR der Org unmergebar machte
# (llc-ops-backlog#87, erstmals 2026-04-29 an v1.1.2 gemeldet, am 2026-09-05 an
# nachrichtenmaschine-app#356 mit v1.8.0 erneut belegt):
#
#   1. Der Step `scope` trug `if: github.event_name == 'pull_request'`. Auf dem
#      `issue_comment`-Lauf, den Codex mit seinem Summary-Kommentar ausloest,
#      lief er nicht — `steps.scope.outputs.skip` blieb LEER. Leer ist nicht
#      `'true'`, also passierten die nachfolgenden Steps ihren Waechter
#      (`skip != 'true'`) und die Bruecke fiel in den Codex-Urteilszweig.
#   2. Dort traf `eval_body()` den realen Kommentar nicht: verlangt waren genau
#      drei Rauten (`^### Codex Review`), Codex schreibt aber
#      `## Codex Review Summary`. `STATE` blieb auf dem Vorgabewert `pending`
#      und ueberschrieb das eigene, zuvor korrekt gesetzte `success`.
#   3. Gruen wurde es nie von selbst: der Code rechnet mit einem folgenden
#      `pull_request_review`-Event, aber ein Review OHNE Befund existiert bei
#      Codex nicht — es kommt nur eine 👍-Reaktion. Kein Event, Deadlock.
#
# ⛔ Zwei naheliegende Reparaturen sind FALSCH und werden hier aktiv
# ausgeschlossen — beide stammen aus der Codex-Vorpruefung dieses Fixes:
#
#   (P1, Runde 2) Die Ueberschrift auf `^#+` weiten. Der Summary-Kommentar
#   existiert bereits, waehrend der Review noch LAEUFT; er wird nur editiert.
#   Eine Ueberschriften-Erkennung setzt das Tor bei „Running" auf `success` und
#   gibt den Merge VOR den Befunden frei. Faelle V3/V4.
#
#   (P1, Runde 3) `**Completed**` als Freigabe lesen. Das heisst nur „Lauf
#   beendet", NICHT „keine Befunde": an llc-ops-backlog#1147 stand die Summary
#   fuer `2293878` auf Completed, waehrend sechs Zeilenbefunde offen waren.
#   Befunde stehen NICHT im Kommentar-Body, sondern als Review-Threads am Diff —
#   die Bruecke hat sie nie gelesen. Deshalb bekommt `eval_body()` die Zahl der
#   OFFENEN (nicht aufgeloesten) Befund-Threads als zweites Argument.
#   Faelle V10-V13.
#
# Die Funktion `eval_body()` wird AUS DER WORKFLOW-DATEI GELESEN und hier
# ausgefuehrt, nicht abgeschrieben. Damit kann der Test nicht gruen bleiben, wenn
# jemand die Datei zurueckdreht.
# Gegen den alten Stand rotstellen:
#   git show <alter-sha>:.github/workflows/gate-2-codex.yml > /tmp/alt.yml
#   GATE2_WORKFLOW=/tmp/alt.yml bash scripts/gate-2-verdict-selftest.sh
#
# Kein GitHub, kein Netzwerk.
# exit != 0 bei jeder fehlgeschlagenen Assertion → CI-Gate 'checks' schlaegt fehl.
set -uo pipefail

WF="${GATE2_WORKFLOW:-.github/workflows/gate-2-codex.yml}"
[ -r "$WF" ] || { echo "FATAL: $WF nicht lesbar"; exit 1; }

# --- eval_body() 1:1 aus dem Workflow ziehen (Single Source of Truth) --------
# Vom Funktionskopf bis zur ersten schliessenden Klammer auf Kopf-Einrueckung,
# danach um genau diese Einrueckung entdenten.
FN_RAW="$(awk '
  /^[[:space:]]*eval_body\(\)[[:space:]]*\{/ { f=1; indent=match($0,/[^ ]/)-1 }
  f { print }
  f && /^[[:space:]]*\}[[:space:]]*$/ && (match($0,/[^ ]/)-1)==indent { exit }
' "$WF")"
[ -n "$FN_RAW" ] || { echo "FATAL: eval_body() nicht aus $WF extrahierbar"; exit 1; }
PAD="$(printf '%s\n' "$FN_RAW" | head -1 | sed 's/[^ ].*//')"
FN="$(printf '%s\n' "$FN_RAW" | sed "s/^${PAD}//")"
eval "$FN" || { echo "FATAL: eval_body() aus $WF nicht ausfuehrbar"; exit 1; }

# Die Funktion liest HEAD_SHA/SHORT_SHA aus ihrem Step-Kontext — hier gestellt.
HEAD_SHA="2528273880dc8d48e29da855fd22340f9595c784"
SHORT_SHA="${HEAD_SHA:0:7}"
FREMD_SHA="9999999"

# Seit Runde 12 ist die Befundzahl KEIN Argument von eval_body() mehr: der
# Riegel steht oberhalb der ganzen Kette, nicht in der Body-Beurteilung (er war
# dreimal umgangen worden — Runden 3, 11, 12). Die Faelle dazu misst deshalb
# gate-2-chain-selftest.sh (K6, K9, K10-K13), wo die Kette wirklich laeuft.
# Der Helfer bleibt nur als Name stehen, damit die Body-Faelle unten lesbar
# bleiben.
eval_body_0() { eval_body "$1"; }

PASS=0; FAIL=0
check() { # $1=name  $2=expected  $3=actual
  if [ "$2" = "$3" ]; then
    echo "  ok   [$1] → verdict='$3'"; PASS=$((PASS+1))
  else
    echo "  FAIL [$1] → got verdict='$3', want '$2'"; FAIL=$((FAIL+1))
  fi
}

# Baut einen Summary-Kommentar in der REALEN Form (Marker + Tabelle).
# $1=Status-Zelle  $2=Commit-Zelle
summary() {
  printf '%s\n\n## Codex Review Summary\n\n%s\n%s\n| 📝 **Code Review** | %s <relative-time datetime="2026-09-05T05:23:30Z">x</relative-time> | `%s` | PR opened |\n' \
    '<!-- codex-pull-request-review-summary -->' \
    '| Review | Status | Commit | Review trigger |' \
    '| --- | --- | --- | --- |' \
    "$1" "$2"
}

echo "=== gate-2 verdict scenarios (eval_body aus $WF) ==="

# --- V1: DER REGRESSIONSFALL --------------------------------------------------
# Realer Codex-Summary aus nachrichtenmaschine-app#356: abgeschlossener Lauf
# fuer den aktuellen HEAD. Gegen v1.1.2..v1.8.1 ergab das '' → pending →
# Deadlock. Muss success sein.
V=$(eval_body_0 "$(summary '✅ **Completed**' "$SHORT_SHA")")
check "summary-completed-am-HEAD (llc-ops-backlog#87)" success "$V"

# V2) Voller 40-Zeichen-SHA in der Commit-Zelle zaehlt genauso
V=$(eval_body_0 "$(summary '✅ **Completed**' "$HEAD_SHA")")
check "summary-completed-voller-sha" success "$V"

# --- V9: DAS P1-LOCH (Vorpruefung Runde 2) ------------------------------------
# Derselbe Kommentar, waehrend der Review noch laeuft. Der Marker und die
# Ueberschrift stehen bereits da. Muss '' sein (Gate bleibt pending) — sonst
# mergt der PR vor den Befunden.
V=$(eval_body_0 "$(summary '🔄 **Running**' "$SHORT_SHA")")
check "summary-running-am-HEAD→pending (P1)" "" "$V"
V=$(eval_body_0 "$(summary '⏳ **Queued**' "$SHORT_SHA")")
check "summary-queued-am-HEAD→pending" "" "$V"

# V3) Abgeschlossener Lauf eines FREMDEN Commits sagt ueber diesen HEAD nichts
V=$(eval_body_0 "$(summary '✅ **Completed**' "$FREMD_SHA")")
check "summary-completed-fremder-commit→pending" "" "$V"

# V4) Zwei Zeilen: fremder Commit fertig, HEAD laeuft noch → pending.
#     Das ist der Fall, in dem eine reine "enthaelt Completed"-Pruefung kippen
#     wuerde — die Status-Zelle muss ZUR HEAD-Zeile gehoeren.
MIXED=$(printf '%s\n\n## Codex Review Summary\n\n| Review | Status | Commit |\n| --- | --- | --- |\n| 📝 **Code Review** | ✅ **Completed** | `%s` | \n| 📝 **Code Review** | 🔄 **Running** | `%s` | \n' \
  '<!-- codex-pull-request-review-summary -->' "$FREMD_SHA" "$SHORT_SHA")
V=$(eval_body_0 "$MIXED"); check "summary-fremd-fertig+HEAD-laeuft→pending" "" "$V"

# V5) Umgekehrt: fremder Commit laeuft, HEAD ist fertig → success
MIXED2=$(printf '%s\n\n## Codex Review Summary\n\n| Review | Status | Commit |\n| --- | --- | --- |\n| 📝 **Code Review** | 🔄 **Running** | `%s` | \n| 📝 **Code Review** | ✅ **Completed** | `%s` | \n' \
  '<!-- codex-pull-request-review-summary -->' "$FREMD_SHA" "$SHORT_SHA")
V=$(eval_body_0 "$MIXED2"); check "summary-HEAD-fertig+fremd-laeuft→success" success "$V"

# V6) Befunde schlagen alles — auch einen abgeschlossenen Summary
V=$(eval_body_0 "$(summary '✅ **Completed**' "$SHORT_SHA")
### Findings
- something")
check "findings-schlagen-summary" failure "$V"
V=$(eval_body_0 "$(summary '✅ **Completed**' "$SHORT_SHA")
**P1** Datenverlust moeglich")
check "P1-schlaegt-summary" failure "$V"
V=$(eval_body_0 "$(summary '✅ **Completed**' "$SHORT_SHA")
🚨 kritisch")
check "alarm-schlaegt-summary" failure "$V"

# V7) Die historisch bekannten Banner-Formen bleiben erkannt (Regressionsschutz)
V=$(eval_body_0 '### 💡 Codex Review

Looks good.'); check "banner-emoji-bleibt" success "$V"
V=$(eval_body_0 '### Codex Review'); check "banner-3-rauten-bleibt" success "$V"
V=$(eval_body_0 'Codex Review: no findings'); check "prefix-form-bleibt" success "$V"

# V8) KEIN Verdict → '' (Status bleibt pending). URSPRUNGSFALL aus
#     llc-ops-backlog#87: ein 'Codex usage limits'-Hinweis ist kein Urteil.
V=$(eval_body_0 'Codex usage limits reached. Try again later.'); check "usage-limits-kein-verdict" "" "$V"
V=$(eval_body_0 'Danke fuer den PR!'); check "fremdkommentar-kein-verdict" "" "$V"

# V10) 'Codex Review' MITTEN in einer Zeile ist kein Banner — die Anker `^`
#      duerfen nicht verlorengehen, sonst faelscht ein Zitat ein Approval.
V=$(eval_body_0 'siehe die Codex Review Summary von gestern'); check "banner-nur-am-zeilenanfang" "" "$V"
V=$(eval_body_0 'ich zitiere: Codex Review: alles gut'); check "prefix-nur-am-zeilenanfang" "" "$V"

# Die Faelle zur BEFUNDZAHL (offen / unbekannt) standen bis Runde 12 hier und
# messen jetzt dort, wo der Riegel wirklich sitzt: gate-2-chain-selftest.sh,
# K6 (offen), K9 (unbekannt), K10-K13 (auch an APPROVED und am Legacy-Banner
# vorbei). Sie hier zu belassen haette die Illusion erhalten, eval_body() sei
# die Stelle, die den Merge absichert — genau die Illusion, die dreimal ein P1
# gekostet hat.

# --- V16: DAS ZWEITE P1-LOCH AUS RUNDE 11 ------------------------------------

# V16) Die Summary-Tabelle traegt JE REVIEW-ART eine Zeile. Ein abgeschlossenes
#      Security Review am aktuellen HEAD oeffnete das Tor, waehrend das Code
#      Review am selben Commit noch lief — die alte Pruefung sah nur "irgendeine
#      Zeile mit dem SHA traegt Completed".
ZWEI_ARTEN=$(printf '%s\n\n## Codex Review Summary\n\n| Review | Status | Commit |\n| --- | --- | --- |\n| 🔒 **Security Review** | ✅ **Completed** | `%s` | \n| 📝 **Code Review** | 🔄 **Running** | `%s` | \n' \
  '<!-- codex-pull-request-review-summary -->' "$SHORT_SHA" "$SHORT_SHA")
V=$(eval_body_0 "$ZWEI_ARTEN")
check "security-fertig+code-review-laeuft→pending (P1 R11)" "" "$V"

# Gegenprobe zu V16: sind BEIDE Arten am HEAD fertig, traegt die Summary.
# Ohne sie koennte V16 auch bei einer generell kaputten Fixture gruen melden.
ZWEI_FERTIG=$(printf '%s\n\n## Codex Review Summary\n\n| Review | Status | Commit |\n| --- | --- | --- |\n| 🔒 **Security Review** | ✅ **Completed** | `%s` | \n| 📝 **Code Review** | ✅ **Completed** | `%s` | \n' \
  '<!-- codex-pull-request-review-summary -->' "$SHORT_SHA" "$SHORT_SHA")
V=$(eval_body_0 "$ZWEI_FERTIG")
check "beide-review-arten-fertig→success (Gegenprobe)" success "$V"

# --- V17: DAS P1-LOCH AUS RUNDE 13 -------------------------------------------

# V17) Die Summary traegt je Review-LAUF eine eigene Zeile. Wird ein Review
#      erneut angestossen (Push, "@codex review"), steht neben dem alten
#      `Completed` ein neues `Running` — fuer DENSELBEN HEAD und dieselbe
#      Review-ART. Die alte Pruefung suchte irgendeine gruene Zeile und gab
#      frei, waehrend der neue Lauf noch lief: es konnte waehrend eines
#      laufenden Re-Reviews gemergt werden.
#      "Es gibt eine gruene Zeile" ist nie dasselbe wie "es gibt keine ungruene".
ZWEI_LAEUFE=$(printf '%s\n\n## Codex Review Summary\n\n| Review | Status | Commit |\n| --- | --- | --- |\n| 📝 **Code Review** | ✅ **Completed** | `%s` | \n| 📝 **Code Review** | 🔄 **Running** | `%s` | \n' \
  '<!-- codex-pull-request-review-summary -->' "$SHORT_SHA" "$SHORT_SHA")
V=$(eval_body_0 "$ZWEI_LAEUFE")
check "alter-lauf-fertig+neuer-laeuft-am-HEAD→pending (P1 R13)" "" "$V"

# V18) Dieselbe Lage in umgekehrter Reihenfolge. Die Zeilenfolge in der Tabelle
#      ist nicht garantiert; eine Pruefung, die nur die erste Zeile ansieht,
#      waere hier gruen und bei V17 rot (oder umgekehrt).
ZWEI_LAEUFE_UMGEKEHRT=$(printf '%s\n\n## Codex Review Summary\n\n| Review | Status | Commit |\n| --- | --- | --- |\n| 📝 **Code Review** | 🔄 **Running** | `%s` | \n| 📝 **Code Review** | ✅ **Completed** | `%s` | \n' \
  '<!-- codex-pull-request-review-summary -->' "$SHORT_SHA" "$SHORT_SHA")
V=$(eval_body_0 "$ZWEI_LAEUFE_UMGEKEHRT")
check "neuer-laeuft+alter-fertig-am-HEAD→pending (P1 R13, Reihenfolge)" "" "$V"

# V19) Gegenprobe zu V17/V18: sind BEIDE Laeufe am HEAD fertig, traegt die
#      Summary. Ohne sie koennten V17/V18 auch bei einer generell kaputten
#      Fixture oder einer Funktion, die NIE success liefert, gruen melden.
ZWEI_LAEUFE_FERTIG=$(printf '%s\n\n## Codex Review Summary\n\n| Review | Status | Commit |\n| --- | --- | --- |\n| 📝 **Code Review** | ✅ **Completed** | `%s` | \n| 📝 **Code Review** | ✅ **Completed** | `%s` | \n' \
  '<!-- codex-pull-request-review-summary -->' "$SHORT_SHA" "$SHORT_SHA")
V=$(eval_body_0 "$ZWEI_LAEUFE_FERTIG")
check "beide-laeufe-fertig→success (Gegenprobe)" success "$V"

echo "=== Abruf-Fehler darf nicht als 'null Befunde' gelten ==="

# A1) Die Demonstration der Falle (Vorpruefung P1, Runde 4): der jq-Filter
#     ALLEIN kann "keine Befunde" nicht von "Abruf gescheitert" unterscheiden —
#     auf leerer Eingabe liefert er 0 und endet mit Exitcode 0. Deshalb darf er
#     nie direkt an `gh api` haengen.
LEER_ERGEBNIS="$(printf '' | jq -s --arg head x '(add // []) | length' 2>/dev/null)"
if [ "$LEER_ERGEBNIS" = "0" ]; then
  echo "  ok   [leere-eingabe-liefert-0 (die Falle ist real)]"; PASS=$((PASS+1))
else
  echo "  FAIL [leere-eingabe-liefert-0] → got '$LEER_ERGEBNIS'"; FAIL=$((FAIL+1))
fi

# A2) Also MUSS der Workflow den Abruf getrennt pruefen: Ausgabe in eine
#     Variable, Exitcode als Bedingung, erst dann jq.
OFFEN_BLOCK="$(awk '/CODEX_OFFEN=/{f=1} f{print} f && /CODEX_OFFEN:-unbekannt/{exit}' "$WF")"
# Fehlt der Block ganz (alter Stand), ist das ein Fehlschlag der Probe — kein
# Abbruch: die Gegenprobe soll alle Befunde zeigen, nicht beim ersten aufhoeren.
if [ -z "$OFFEN_BLOCK" ]; then
  echo "  FAIL [abruf-exitcode-wird-geprueft] → CODEX_OFFEN-Block fehlt ganz"
  echo "  FAIL [kein-direkter-pipe-gh-nach-jq] → CODEX_OFFEN-Block fehlt ganz"
  echo "  FAIL [vorgabewert-ist-leer-nicht-null] → CODEX_OFFEN-Block fehlt ganz"
  FAIL=$((FAIL+3))
else

# Gemessen wird die ZUSAGE, nicht der Variablenname: der Abruf steht in einer
# eigenen Zuweisung, deren Exitcode die `if`-Bedingung ist. (Der Name hing hier
# einmal fest auf `COMMENTS_RAW` und machte die Probe rot, als der Abruf auf
# GraphQL wechselte — der Name ist nicht die Zusage.)
if printf '%s' "$OFFEN_BLOCK" | grep -qE '^[[:space:]]*if [A-Z][A-Z0-9_]*=\$\(gh api'; then
  echo "  ok   [abruf-exitcode-wird-geprueft]"; PASS=$((PASS+1))
else
  echo "  FAIL [abruf-exitcode-wird-geprueft] → gh api haengt ungeprueft an jq"; FAIL=$((FAIL+1))
fi

# A3) Gegenprobe zu A2: die `gh api`-ANWEISUNG selbst darf nicht in `jq`
#     laufen — samt ihrer Backslash-Fortsetzungen. Nur die eigene Anweisung
#     zaehlt: dass die FOLGE-Anweisung die Variable durch `jq -s` schickt, ist
#     genau der gewollte Zustand und darf hier nicht als Verstoss gelten.
# Die Anweisung endet nicht zwangslaeufig am Zeilenende: ein GraphQL-Query steht
# als mehrzeiliger `-f query='…'`-String da, ganz ohne Backslash-Fortsetzungen.
# Zusammengezogen wird deshalb, solange die Zeile fortgesetzt wird ODER noch ein
# Apostroph offen steht — sonst sieht die Probe nur die erste Zeile und ein
# nachgestelltes `| jq` bliebe unentdeckt.
GH_ANWEISUNG="$(printf '%s\n' "$OFFEN_BLOCK" | awk -v q="'" '
  function apo(s,   c, i) { c = 0; for (i = 1; i <= length(s); i++) if (substr(s, i, 1) == q) c++; return c }
  /gh api/ && /--paginate/ {
    z = $0
    while ((z ~ /\\[[:space:]]*$/ || apo(z) % 2 == 1) && (getline n) > 0) {
      sub(/\\[[:space:]]*$/, "", z); z = z " " n
    }
    print z; exit }')"
if [ -z "$GH_ANWEISUNG" ]; then
  echo "  FAIL [kein-direkter-pipe-gh-nach-jq] → gh-api-Anweisung nicht auffindbar"; FAIL=$((FAIL+1))
elif printf '%s' "$GH_ANWEISUNG" | grep -q '| *jq'; then
  echo "  FAIL [kein-direkter-pipe-gh-nach-jq] → der stille Fehlerfall ist zurueck: $GH_ANWEISUNG"; FAIL=$((FAIL+1))
else
  echo "  ok   [kein-direkter-pipe-gh-nach-jq]"; PASS=$((PASS+1))
fi

# A4) Und der Vorgabewert vor dem Abruf muss LEER sein, nicht 0.
if printf '%s' "$OFFEN_BLOCK" | grep -qE '^[[:space:]]*CODEX_OFFEN=""'; then
  echo "  ok   [vorgabewert-ist-leer-nicht-null]"; PASS=$((PASS+1))
else
  echo "  FAIL [vorgabewert-ist-leer-nicht-null] → unbekannt wuerde als 0 gelesen"; FAIL=$((FAIL+1))
fi
fi

echo "=== scope-Riegel: Ereignis-Unabhaengigkeit ==="

# S1) Der `if` des Steps `scope` darf NICHT am Ereignistyp haengen. Doc-only ist
#     eine Eigenschaft des DIFFS, nicht des Ausloesers. Haengt er daran, bleibt
#     `outputs.skip` auf jedem anderen Event leer und die nachfolgenden Steps
#     laufen in den falschen Zweig.
# Ab `id: scope` die ERSTE `if:`-Zeile nehmen — Kommentarzeilen duerfen
# dazwischenstehen, ohne die Probe blind zu machen.
SCOPE_IF=$(awk '/^[[:space:]]*id: scope[[:space:]]*$/{f=1; next} f && /^[[:space:]]*#/{next} f && /^[[:space:]]*if:/{print; exit} f && /^[[:space:]]*[a-z_]+:/{exit}' "$WF")
[ -n "$SCOPE_IF" ] || { echo "FATAL: if-Zeile des Steps scope nicht auffindbar in $WF"; exit 1; }
if printf '%s' "$SCOPE_IF" | grep -q 'github.event_name'; then
  echo "  FAIL [scope-if-ereignis-unabhaengig] → if haengt am Ereignistyp:$SCOPE_IF"
  FAIL=$((FAIL+1))
else
  echo "  ok   [scope-if-ereignis-unabhaengig] →$SCOPE_IF"
  PASS=$((PASS+1))
fi

# S2) Gegenprobe zu S1: der Step muss ueberhaupt noch einen `if` tragen — sonst
#     liefe er auch auf Bot-PRs, deren Klassen-Gate ihn absichtlich uebergeht.
if printf '%s' "$SCOPE_IF" | grep -q 'bot_exempt'; then
  echo "  ok   [scope-if-behaelt-bot-exempt-waechter]"; PASS=$((PASS+1))
else
  echo "  FAIL [scope-if-behaelt-bot-exempt-waechter] → bot_exempt-Waechter fehlt:$SCOPE_IF"
  FAIL=$((FAIL+1))
fi

echo "=== Job-if: Recheck-Eingang (P1 Runde 9) ==="

# S3-S5 teilen sich EINE Extraktion und EIN Praedikat.
#
# Der `if` des JOBS `bridge` ist ein Blockskalar (`>-`), sein Ausdruck steht
# also ueber mehrere, tiefer eingerueckte Zeilen. Kommentarzeilen bleiben
# ausgenommen: ueber dem `if` steht die Begruendung, und die zitiert die alte
# Fassung dem Wortlaut nach. Ein `grep` ueber die Rohdatei traefe den
# Begruendungstext und meldete falsch rot.
JOB_IF=$(awk '
  /^  bridge:[[:space:]]*$/ { injob=1; next }
  !injob { next }
  /^[[:space:]]*#/ { next }
  collecting && /^      [^[:space:]]/ { print; next }
  collecting { exit }
  /^    if:/ { collecting=1; print; next }
  /^    [a-zA-Z_-]+:/ { exit }
' "$WF" | tr '\n' ' ')

# Wachhund ueber der Extraktion: ein leerer oder abgeschnittener Treffer darf
# NIE als bestandene Probe durchgehen. Beide Anker kommen in jeder denkbaren
# Fassung des Ausdrucks vor - in der alten wie in der neuen.
case "$JOB_IF" in
  *github.event_name*issue_comment*) : ;;
  *) echo "FATAL: if-Block des Jobs bridge nicht auffindbar in $WF (gelesen: $JOB_IF)"; exit 1 ;;
esac

# Das Praedikat, das S3 misst und S4 gegenprueft.
bindet_kommentar_an_den_bot() {
  printf '%s' "$1" | grep -q 'github\.event\.comment\.user\.login'
}

# Die alte Fassung woertlich (origin/main, vor diesem Fix) - nur fuer S4.
ALT_IF="(github.event_name == 'pull_request') || (github.event_name == 'pull_request_review' && github.event.review.user.login == 'chatgpt-codex-connector[bot]') || (github.event_name == 'issue_comment' && github.event.issue.pull_request != null && github.event.comment.user.login == 'chatgpt-codex-connector[bot]')"

# S3) Der Job-`if` darf `issue_comment` NICHT mehr an den Kommentar-Autor
#     binden. Das Tor steht bei offenen Codex-Befunden auf `failure`; das
#     AUFLOESEN eines Threads erzeugt aber kein Actions-Ereignis
#     (`pull_request_review_thread` gibt es nur als Webhook). Ohne einen
#     Eingang, den ein MENSCH ausloesen kann, bliebe das Tor nach dem
#     Aufloesen dauerhaft rot - derselbe Deadlock von der anderen Seite.
#     Die Bruecke ist ein reiner Neuberechner, der Ausloeser aendert am
#     Ergebnis nichts.
if bindet_kommentar_an_den_bot "$JOB_IF"; then
  echo "  FAIL [job-if-hat-recheck-eingang] → issue_comment haengt wieder am Kommentar-Autor: $JOB_IF"
  FAIL=$((FAIL+1))
else
  echo "  ok   [job-if-hat-recheck-eingang]"
  PASS=$((PASS+1))
fi

# S4) Gegenprobe zu S3: dasselbe Praedikat, auf die alte Fassung angewandt,
#     MUSS anschlagen. Ohne sie meldete S3 auch dann gruen, wenn das Praedikat
#     gar nichts mehr trifft - eine Probe, die nichts misst.
if bindet_kommentar_an_den_bot "$ALT_IF"; then
  echo "  ok   [job-if-gegenprobe-alte-fassung]"
  PASS=$((PASS+1))
else
  echo "  FAIL [job-if-gegenprobe-alte-fassung] → das Praedikat schlaegt nicht einmal auf der alten Fassung an; S3 misst nichts"
  FAIL=$((FAIL+1))
fi

# S5) Der PR-Waechter muss bleiben. Ohne `issue.pull_request != null` liefe die
#     Bruecke auf reinen Issues, ohne `issue.state == 'open'` auch an
#     geschlossenen PRs - dort ist nichts mehr zu entscheiden. S3 allein liesse
#     sich sonst durch ersatzloses Streichen der issue_comment-Bedingung
#     "bestehen".
S5_FEHLT=""
printf '%s' "$JOB_IF" | grep -q 'github\.event\.issue\.pull_request != null' || S5_FEHLT="$S5_FEHLT issue.pull_request!=null"
printf '%s' "$JOB_IF" | grep -q "github\.event\.issue\.state == 'open'" || S5_FEHLT="$S5_FEHLT issue.state=='open'"
if [ -z "$S5_FEHLT" ]; then
  echo "  ok   [job-if-behaelt-pr-waechter]"
  PASS=$((PASS+1))
else
  echo "  FAIL [job-if-behaelt-pr-waechter] → fehlt:$S5_FEHLT"
  FAIL=$((FAIL+1))
fi

echo "=== Kette: der Riegel steht vor jedem Erfolgszweig (S6/S7) ==="

# Dreimal ist dieselbe Klasse durchgerutscht (Vorpruefung Runden 3, 11, 12):
# ein Riegel, der IN einem Zweig sitzt, wird vom naechsten Zweig umgangen.
# Beim dritten Mal hilft keine groessere Sorgfalt, sondern ein Waechter, der
# die Klasse strukturell ausschliesst: im Kettenblock darf KEIN `STATE=success`
# vor dem CODEX_OFFEN-Riegel stehen.
riegel_vor_success() { # $1=Kettenblock → 0 = Riegel zuerst, 1 = success zuerst,
                       #                  2 = eines von beiden nicht auffindbar
  local code riegel erfolg
  code="$(printf '%s\n' "$1" | grep -vE '^[[:space:]]*#')"
  riegel="$(printf '%s\n' "$code" | grep -n -m1 'CODEX_OFFEN' | cut -d: -f1)"
  erfolg="$(printf '%s\n' "$code" | grep -n -m1 'STATE=success' | cut -d: -f1)"
  [ -n "$riegel" ] && [ -n "$erfolg" ] || return 2
  [ "$riegel" -lt "$erfolg" ]
}

KETTE_BLOCK="$(awk '/^[[:space:]]*STATE=pending[[:space:]]*$/{f=1} f{print} f && /state=\$STATE/{exit}' "$WF")"
[ -n "$KETTE_BLOCK" ] || { echo "FATAL: Kettenblock nicht auffindbar in $WF"; exit 1; }

# S6) Der gemessene Stand.
riegel_vor_success "$KETTE_BLOCK"; S6=$?
case "$S6" in
  0) echo "  ok   [riegel-steht-vor-jedem-erfolgszweig]"; PASS=$((PASS+1)) ;;
  1) echo "  FAIL [riegel-steht-vor-jedem-erfolgszweig] → ein STATE=success steht VOR dem CODEX_OFFEN-Riegel"; FAIL=$((FAIL+1)) ;;
  *) echo "  FAIL [riegel-steht-vor-jedem-erfolgszweig] → Riegel oder Erfolgszweig nicht auffindbar"; FAIL=$((FAIL+1)) ;;
esac

# S7) Gegenprobe: die alte Anordnung (APPROVED setzt success, der Riegel liegt
#     erst darunter in eval_body) MUSS anschlagen. Ohne sie meldete S6 auch
#     dann gruen, wenn die Messung gar nichts mehr trifft.
ALT_ANORDNUNG='STATE=pending
if [ "$REVIEW_STATE" = "APPROVED" ]; then
  STATE=success
fi
V=$(eval_body "$COMMENT_BODY" "$CODEX_OFFEN")
state=$STATE'
riegel_vor_success "$ALT_ANORDNUNG"; S7=$?
if [ "$S7" = 1 ]; then
  echo "  ok   [gegenprobe-alte-anordnung-schlaegt-an]"; PASS=$((PASS+1))
else
  echo "  FAIL [gegenprobe-alte-anordnung-schlaegt-an] → rc=$S7; die Messung trifft die alte Anordnung nicht"
  FAIL=$((FAIL+1))
fi

echo "=== Kurz-SHA-Bindung: Aufloesung im Step head (P1 R13) ==="

# Die HEAD-Bindung akzeptiert auch die siebenstellige Kurzform, weil Codex die
# Commit-Zelle der Summary so schreibt (llc-ops-backlog#1147: `2293878`). Sieben
# Hex-Zeichen sind 28 Bit: ein PR-Autor kann einen neuen Commit mit demselben
# Praefix wie ein bereits abgeschlossener Review-Commit erzeugen und dessen
# Freigabe uebernehmen. Aufgeloest wird deshalb EINE EBENE HOEHER, im Step
# `Resolve PR HEAD` — `eval_body()` wird offline geprueft und darf kein Netz
# sehen. Hier wird der Block genauso aus der YAML gezogen und ausgefuehrt, nur
# mit gestelltem `gh`.
AUFL_RAW="$(awk '/^[[:space:]]*SHORT="\$SHA"[[:space:]]*$/{f=1} f{print} f && /short=\$SHORT/{exit}' "$WF")"
if [ -z "$AUFL_RAW" ]; then
  for p in kurz-sha-abruf-getrennt-geprueft kurz-sha-eindeutig-erlaubt-die-kurzform \
           kurz-sha-fremde-aufloesung-faellt-auf-voll-zurueck \
           kurz-sha-abruf-gescheitert-faellt-auf-voll-zurueck \
           kurz-sha-vorgabe-ist-voll-nicht-leer kurz-sha-kommt-aus-dem-step-output; do
    echo "  FAIL [$p] → Aufloesungs-Block fehlt ganz"; FAIL=$((FAIL+1))
  done
else
PAD2="$(printf '%s\n' "$AUFL_RAW" | head -1 | sed 's/[^ ].*//')"
AUFL="$(printf '%s\n' "$AUFL_RAW" | sed "s/^${PAD2}//")"

# B1) Struktur: der Abruf steht in einer eigenen Zuweisung, deren Exitcode die
#     `if`-Bedingung ist. Eine Pipe verschluckt den Abruffehler.
if printf '%s' "$AUFL" | grep -qE '^[[:space:]]*if [A-Z][A-Z0-9_]*=\$\(gh api'; then
  echo "  ok   [kurz-sha-abruf-getrennt-geprueft]"; PASS=$((PASS+1))
else
  echo "  FAIL [kurz-sha-abruf-getrennt-geprueft] → der Abruf haengt ungeprueft"; FAIL=$((FAIL+1))
fi

# Verhalten OHNE Netz: `gh` wird gestellt, der echte Block ausgefuehrt.
gh() { if [ "${GH_RC:-0}" != 0 ]; then return "${GH_RC}"; fi; printf '%s\n' "${GH_OUT:-}"; }
kurz_aufloesung() { # $1=rc des Abrufs  $2=Ausgabe des Abrufs → gesetzter short-Wert
  local SHA GITHUB_REPOSITORY GITHUB_OUTPUT ergebnis
  SHA="$HEAD_SHA"
  GITHUB_REPOSITORY="Paul-Brandenburg-LLC/llc-workflow-templates"
  GITHUB_OUTPUT="$(mktemp)"
  # `mktemp` kann LEER scheitern — dann schriebe die Umleitung ins Nichts und
  # die Probe waere blind.
  [ -n "$GITHUB_OUTPUT" ] || { printf 'MKTEMP-LEER'; return 0; }
  GH_RC="$1"; GH_OUT="$2"
  eval "$AUFL"
  ergebnis="$(sed -n 's/^short=//p' "$GITHUB_OUTPUT")"
  rm -f "$GITHUB_OUTPUT"
  printf '%s' "$ergebnis"
}

FREMD_VOLL="0123456789012345678901234567890123456789"

# B2) Loest der Praefix eindeutig auf genau diesen HEAD auf, bleibt die
#     Kurzform erlaubt. Faellt sie weg, ist das ein NEUER Deadlock: Codex
#     schreibt die Commit-Zelle siebenstellig.
V=$(kurz_aufloesung 0 "$HEAD_SHA")
check "kurz-sha-eindeutig-erlaubt-die-kurzform" "${HEAD_SHA:0:7}" "$V"

# B3) Loest er auf einen ANDEREN Commit auf (Praefix-Kollision), faellt die
#     Bindung auf den vollen SHA zurueck — die Stale-Uebernahme ist damit zu.
V=$(kurz_aufloesung 0 "$FREMD_VOLL")
check "kurz-sha-fremde-aufloesung-faellt-auf-voll-zurueck" "$HEAD_SHA" "$V"

# B4) Scheitert der Abruf (mehrdeutig, 422, kein Netz, fehlende Rechte), gilt
#     der Kurz-Hash als NICHT verwendbar. Vorgabe bleibt der volle SHA.
V=$(kurz_aufloesung 1 "")
check "kurz-sha-abruf-gescheitert-faellt-auf-voll-zurueck" "$HEAD_SHA" "$V"

# B5) Und die Vorgabe darf NIE leer sein: `grep -F -e ""` traefe jede Zeile und
#     machte das Tor maximal gruen — die falsche Irrtumsrichtung. Gemessen an
#     der Zuweisung im Block, nicht nur am Ergebnis.
if printf '%s' "$AUFL" | grep -qE '^[[:space:]]*SHORT="\$SHA"[[:space:]]*$'; then
  echo "  ok   [kurz-sha-vorgabe-ist-voll-nicht-leer]"; PASS=$((PASS+1))
else
  echo "  FAIL [kurz-sha-vorgabe-ist-voll-nicht-leer] → Vorgabe ist nicht der volle SHA"; FAIL=$((FAIL+1))
fi

# B6) Der Verbraucher muss den geprueften Wert auch NEHMEN. Rechnet der
#     Urteils-Step die Kurzform wieder selbst aus (`${HEAD_SHA:0:7}`), laeuft
#     die ganze Aufloesung ins Leere.
B6_FEHLT=""
grep -qF 'SHORT_SHA: ${{ steps.head.outputs.short }}' "$WF" || B6_FEHLT="$B6_FEHLT env-SHORT_SHA-aus-step-output"
grep -qE '^[[:space:]]*SHORT_SHA="\$\{HEAD_SHA:0:7\}"' "$WF" && B6_FEHLT="$B6_FEHLT lokale-Neuberechnung-zurueck"
if [ -z "$B6_FEHLT" ]; then
  echo "  ok   [kurz-sha-kommt-aus-dem-step-output]"; PASS=$((PASS+1))
else
  echo "  FAIL [kurz-sha-kommt-aus-dem-step-output] → fehlt/falsch:$B6_FEHLT"; FAIL=$((FAIL+1))
fi
fi

echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
