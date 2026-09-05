#!/usr/bin/env bash
# Offline-Testharness fuer die Zaehlung OFFENER Codex-Befund-Threads in
# gate-2-codex.yml (llc-ops-backlog#87, Codex-Vorpruefung P1 Runde 5).
#
# DER BEFUND: Die erste Fassung las `/pulls/N/comments` und strich jeden Befund,
# auf den irgendein `in_reply_to_id` zeigte — "beantwortet" galt als "erledigt".
# Eine Antwort belegt aber nur, dass jemand geschrieben hat. Ein widersprechender
# Kommentar des PR-Autors ("sehe ich anders") entfernte den weiterhin offenen
# Befund aus der Zaehlung; stand die Summary dann auf `**Completed**`, setzte die
# Bruecke das Tor auf `success` und gab den Merge frei. Das ist die gefaehrliche
# Irrtumsrichtung: zu gruen.
#
# DIE REPARATUR: Gezaehlt wird der ECHTE Thread-Zustand `isResolved` aus der
# GraphQL-Verbindung `pullRequest.reviewThreads` — derselbe Zustand, den die
# Branch-Protection mit "All comments must be resolved" verlangt. Ihn setzt nur,
# wer den Thread wirklich aufloest.
#
# Der Test schreibt den jq-Ausdruck NICHT ab, sondern zieht ihn IM GANZEN aus
# gate-2-codex.yml und fuehrt ihn aus. Dreht jemand die Datei zurueck, faellt der
# Test — er kann nicht gruen bleiben, waehrend der Workflow wieder falsch zaehlt.
# Vergleichsstand pruefen:
#   git show <sha>:.github/workflows/gate-2-codex.yml > /tmp/alt.yml
#   GATE2_WORKFLOW=/tmp/alt.yml bash scripts/gate-2-threads-selftest.sh
#
# Kein Netzwerk. exit != 0 bei jeder fehlgeschlagenen Probe → CI-Job 'checks'.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
WF="${GATE2_WORKFLOW:-.github/workflows/gate-2-codex.yml}"
FAIL=0
PASS=0
ok()   { PASS=$((PASS + 1)); printf '  ok   — %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL — %s\n' "$1"; }

command -v jq >/dev/null 2>&1 || { echo "jq fehlt — Test kann nicht urteilen"; exit 1; }
[ -f "$WF" ] || { echo "Workflow-Datei nicht gefunden: $WF"; exit 1; }

Q="'"

# ---------------------------------------------------------------------------
# Den Zaehl-Ausdruck IM GANZEN aus dem Workflow ziehen
# ---------------------------------------------------------------------------
# Anker ist die ANWEISUNG (`CODEX_OFFEN=$(printf … | jq -s '`), nicht ihre
# Nachbarschaft: eine Probe, die ihre Anker aus der Nachbarzeile liest, wird
# falsch-positiv, sobald sich die Zeilenordnung aendert (zweimal passiert).
AUSDRUCK=$(awk -v q="$Q" '
  !inb && index($0, "CODEX_OFFEN=$(printf") && index($0, "jq -s " q) {
    p = index($0, "jq -s " q)
    rest = substr($0, p + length("jq -s " q))
    if (rest != "") print rest
    inb = 1
    next
  }
  inb {
    e = index($0, q)
    if (e > 0) { if (e > 1) print substr($0, 1, e - 1); exit }
    print
  }
' "$WF")

echo "0) Der Ausdruck ist ueberhaupt da und misst den Thread-Zustand"

if [ -n "$AUSDRUCK" ]; then
  ok "Zaehl-Ausdruck aus $WF gezogen ($(printf '%s' "$AUSDRUCK" | grep -c .) Zeilen)"
else
  fail "kein Zaehl-Ausdruck in $WF gefunden — der Workflow zaehlt die offenen Befunde nicht (oder anders als erwartet)"
fi

if printf '%s' "$AUSDRUCK" | grep -qF 'isResolved'; then
  ok "der Ausdruck liest den echten Thread-Zustand (isResolved)"
else
  fail "der Ausdruck liest KEIN isResolved — eine blosse Antwort duerfte einen offenen Befund nie erledigen"
fi

# Regressions-Riegel: die alte, widerlegte Bedingung darf im AUSFUEHRBAREN Teil
# nicht wieder auftauchen. Kommentarzeilen sind ausgenommen — dort steht die
# Begruendung, warum sie es nicht mehr tut, und die soll stehen bleiben.
if grep -vE '^[[:space:]]*#' "$WF" | grep -qF 'in_reply_to_id'; then
  fail "in_reply_to_id steht wieder im Code von $WF — 'beantwortet' ist nicht 'erledigt' (P1 Runde 5)"
else
  ok "in_reply_to_id kommt im ausfuehrbaren Teil nicht mehr vor"
fi

# Ohne Ausdruck ist jede weitere Probe sinnlos — und ein stiller Durchmarsch
# waere genau der Fehler, den dieser Test verhindern soll.
[ -n "$AUSDRUCK" ] || { echo; echo "gate-2-threads-selftest: FEHLGESCHLAGEN ($FAIL)"; exit 1; }

zaehle() {  # $1 = eine oder mehrere GraphQL-Seiten (je ein JSON-Dokument)
  printf '%s' "$1" | jq -s "$AUSDRUCK" 2>/dev/null
}

# Eine GraphQL-Antwortseite bauen. $1 = JSON-Array der Threads.
seite() {
  jq -nc --argjson n "$1" \
    '{data:{repository:{pullRequest:{reviewThreads:{pageInfo:{hasNextPage:false,endCursor:null},nodes:$n}}}}}'
}

# Ein Thread. $1 = isResolved, $2 = Login des ERSTEN Kommentars,
# $3 = isOutdated (Vorgabe false).
thread() {
  jq -nc --argjson r "$1" --arg l "$2" --argjson o "${3:-false}" \
    '{isResolved:$r,isOutdated:$o,comments:{nodes:[{author:{login:$l}}]}}'
}

BOT="chatgpt-codex-connector"
BOT_REST="chatgpt-codex-connector[bot]"

probe() {  # $1 = Name, $2 = Seiten, $3 = Erwartung
  local ist; ist=$(zaehle "$2")
  [ "$ist" = "$3" ] && ok "$1 → $3" || fail "$1 → erwartet '$3', bekam '${ist:-<leer>}'"
}

echo
echo "T) Zaehlung offener Codex-Befund-Threads"

probe "keine Threads"                       "$(seite '[]')"                                      0
probe "ein OFFENER Codex-Thread"            "$(seite "[$(thread false "$BOT")]")"                1
probe "ein AUFGELOESTER Codex-Thread"       "$(seite "[$(thread true  "$BOT")]")"                0
probe "offener Thread, aber von einem Menschen" "$(seite "[$(thread false 'pb-llc-repairbot')]")" 0
probe "Login in der REST-Schreibweise mit [bot]" "$(seite "[$(thread false "$BOT_REST")]")"       1

MISCHUNG="[$(thread false "$BOT"),$(thread true "$BOT"),$(thread false 'ein-mensch')]"
probe "gemischt: 1 offen (Codex), 1 aufgeloest, 1 fremd" "$(seite "$MISCHUNG")" 1

# Paginierung: `gh api graphql --paginate` gibt jede Seite als EIGENES Dokument
# aus. Ohne `jq -s` saehe der Ausdruck nur eine davon.
ZWEI_SEITEN=$(printf '%s\n%s\n' "$(seite "[$(thread false "$BOT")]")" "$(seite "[$(thread false "$BOT")]")")
probe "zwei Seiten mit je einem offenen Thread" "$ZWEI_SEITEN" 2

# Robustheit: leere Kommentarliste und geloeschter Autor duerfen den Ausdruck
# nicht abstuerzen lassen — ein Absturz waere ein LEERES Ergebnis, und leer
# bedeutet im Workflow "unbekannt" (Gate bleibt pending). Das ist zwar die
# sichere Richtung, aber es waere ein Dauerblocker.
probe "Thread ohne Kommentare"    "$(seite '[{"isResolved":false,"isOutdated":false,"comments":{"nodes":[]}}]')"          0
probe "Thread mit geloeschtem Autor" "$(seite '[{"isResolved":false,"isOutdated":false,"comments":{"nodes":[{"author":null}]}}]')" 0

# --- O) Veraltete Threads zaehlen nicht (P1 Runde 6) ------------------------
# Das Aufloesen eines Threads loest KEINEN Workflow aus — GitHub Actions kennt
# `pull_request_review_thread` nicht, und die Caller abonnieren nur
# `pull_request`, `pull_request_review` und `issue_comment`. Wuerde die blosse
# Auflosung den Status drehen, gaebe es dafuer nie einen Lauf und das Tor bliebe
# rot stehen. Deshalb ist der Status eine Funktion des HEAD: ein Befund an Code,
# den der naechste Push aendert, wird `isOutdated` — und dieser Push feuert
# `synchronize`.
echo
echo "O) Veraltete Befunde blockieren nicht mehr — der Uebergang haengt am Push"

probe "offener, aber VERALTETER Codex-Thread"   "$(seite "[$(thread false "$BOT" true)]")"  0
probe "offener, AKTUELLER Codex-Thread"         "$(seite "[$(thread false "$BOT" false)]")" 1
probe "veraltet UND aufgeloest"                 "$(seite "[$(thread true  "$BOT" true)]")"  0

# Unbekannt ist nicht erledigt: faellt ein Feld weg, muss der Thread als OFFEN
# gelten. Mit `== false` statt `!= true` waere ein fehlendes Feld ein
# stillschweigendes "erledigt" — und damit ein gruenes Tor.
OHNE_OUTDATED='[{"isResolved":false,"comments":{"nodes":[{"author":{"login":"chatgpt-codex-connector"}}]}}]'
OHNE_RESOLVED='[{"isOutdated":false,"comments":{"nodes":[{"author":{"login":"chatgpt-codex-connector"}}]}}]'
probe "isOutdated fehlt ganz → gilt als aktuell" "$(seite "$OHNE_OUTDATED")" 1
probe "isResolved fehlt ganz → gilt als offen"   "$(seite "$OHNE_RESOLVED")" 1

# ---------------------------------------------------------------------------
# V) Verhaltensprobe: warum "beantwortet" nicht "erledigt" heisst
# ---------------------------------------------------------------------------
# Die alte Fassung, woertlich wie sie in gate-2-codex.yml stand (v1.9.0-Entwurf,
# vor P1 Runde 5). Sie steht hier als HISTORISCHE REFERENZ, damit der Befund
# messbar bleibt — nicht als Vorbild.
echo
echo "V) Der Befund: eine beliebige Antwort umging den offenen Befund"

ALT_AUSDRUCK='
  (add // []) as $all
  | ($all | map(select(.in_reply_to_id != null) | .in_reply_to_id) | unique) as $beantwortet
  | [ $all[]
      | select(.user.login == "chatgpt-codex-connector[bot]")
      | select(.commit_id == $head)
      | select(.in_reply_to_id == null)
      | select([.id] | inside($beantwortet) | not) ]
  | length'

HEAD_FIX="2293878aa0000000000000000000000000000000"

# Ein offener Codex-Befund am HEAD — und darunter ein WIDERSPRUCH des Autors.
# Der Thread ist damit beantwortet, aber NICHT aufgeloest.
REST_FIXTURE=$(jq -nc --arg sha "$HEAD_FIX" --arg bot "$BOT_REST" '[
  { id: 1, user: {login: $bot},        commit_id: $sha, in_reply_to_id: null,
    body: "P1: hier fehlt die Fehlerbehandlung" },
  { id: 2, user: {login: "ein-mensch"}, commit_id: $sha, in_reply_to_id: 1,
    body: "sehe ich anders" }
]')

ALT_ZAHL=$(printf '%s' "$REST_FIXTURE" | jq -s --arg head "$HEAD_FIX" "$ALT_AUSDRUCK" 2>/dev/null)
[ "$ALT_ZAHL" = "0" ] \
  && ok "alte Fassung: widersprochener, offener Befund zaehlt als 0 (der Befund)" \
  || fail "alte Fassung: erwartet 0 (sonst trifft die Probe den Fall nicht), bekam '${ALT_ZAHL:-<leer>}'"

# Derselbe Sachverhalt als Thread: beantwortet, aber isResolved = false. Die
# Antwort selbst taucht in der Abfrage gar nicht mehr auf (`comments(first: 1)`
# holt nur den Befund) — genau darum kann sie ihn auch nicht mehr erledigen.
NEU_ZAHL=$(zaehle "$(seite "[$(thread false "$BOT")]")")
[ "$NEU_ZAHL" = "1" ] \
  && ok "neue Fassung: derselbe Thread zaehlt als 1 — das Tor bleibt zu" \
  || fail "neue Fassung: erwartet 1, bekam '${NEU_ZAHL:-<leer>}'"

# Gegenprobe zur Gegenprobe: die alte Fassung war nicht in JEDEM Fall blind —
# sonst koennte die Probe auch bei einer voellig kaputten Fixture gruen melden.
UNBEANTWORTET=$(jq -nc --arg sha "$HEAD_FIX" --arg bot "$BOT_REST" '[
  { id: 1, user: {login: $bot}, commit_id: $sha, in_reply_to_id: null, body: "P1" }
]')
ALT_ZAHL2=$(printf '%s' "$UNBEANTWORTET" | jq -s --arg head "$HEAD_FIX" "$ALT_AUSDRUCK" 2>/dev/null)
[ "$ALT_ZAHL2" = "1" ] \
  && ok "Gegenprobe: ohne Antwort sah auch die alte Fassung den Befund (1)" \
  || fail "Gegenprobe: erwartet 1, bekam '${ALT_ZAHL2:-<leer>}' — die Fixture trifft den Fall nicht"

echo
if [ "$FAIL" = 0 ]; then
  echo "=== $PASS passed, 0 failed ==="
  exit 0
fi
echo "=== $PASS passed, $FAIL failed ==="
echo "gate-2-threads-selftest: FEHLGESCHLAGEN"
exit 1
