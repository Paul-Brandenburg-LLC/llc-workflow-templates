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

# Bequemlichkeit: die Altfaelle messen die Body-Erkennung bei NULL offenen
# Zeilenbefunden. Die Befundzahl selbst pruefen V10-V13 ausdruecklich.
eval_body_0() { eval_body "$1" 0; }

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

# --- V10-V12: DAS P1-LOCH AUS RUNDE 3 ---------------------------------------
# `**Completed**` heisst nur "Lauf beendet". Liegen offene Zeilenbefunde am
# HEAD, ist das ein failure — egal wie gruen die Summary aussieht.
SUM_OK="$(summary '✅ **Completed**' "$SHORT_SHA")"

# V10) Ein offener Zeilenbefund schlaegt die abgeschlossene Summary
V=$(eval_body "$SUM_OK" 1); check "completed+1-offener-befund→failure (P1 R3)" failure "$V"
V=$(eval_body "$SUM_OK" 6); check "completed+6-offene-befunde→failure" failure "$V"

# V11) Null offene Befunde — erst dann traegt die abgeschlossene Summary
V=$(eval_body "$SUM_OK" 0); check "completed+0-offene-befunde→success" success "$V"

# V12) UNBEKANNT (Abruf gescheitert) darf NIE als "null Befunde" gelten.
#      Leerer Wert → pending, nicht success.
V=$(eval_body "$SUM_OK" ""); check "completed+unbekannt→pending" "" "$V"
V=$(eval_body "$SUM_OK");    check "completed+arg-fehlt→pending" "" "$V"

# V13) Offene Befunde schlagen auch einen LAUFENDEN Lauf — failure vor pending
V=$(eval_body "$(summary '🔄 **Running**' "$SHORT_SHA")" 2)
check "running+offene-befunde→failure" failure "$V"

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

echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
