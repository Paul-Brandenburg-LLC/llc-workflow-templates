#!/usr/bin/env bash
# Offline-Testharness fuer die VERDICT-KETTE in gate-2-codex.yml
# (llc-ops-backlog#87, Codex-Vorpruefung P1 Runde 6, Befund 1).
#
# DER BEFUND: Der Kommentar-Fallback hing als `elif` am Review-Zweig. Codex
# hinterlaesst zu einem Review regelmaessig ein formales `COMMENTED` OHNE Body —
# die Befunde stehen in den Zeilen-Threads, das Urteil im Summary-Kommentar.
# Damit traf der Review-Zweig zu, `eval_body("")` lieferte kein Verdict, `STATE`
# blieb `pending`, und der Summary wurde NIE gelesen. Nach dem Aufloesen aller
# Befunde haette das Tor dauerhaft auf `pending` gestanden — der Deadlock von
# der anderen Seite.
#
# DIE REPARATUR: Der Kommentar-Zweig laeuft eigenstaendig, wenn `STATE` noch
# `pending` ist. Ein formales Review mit klarem Urteil (APPROVED /
# CHANGES_REQUESTED / Body mit Verdict) bleibt verbindlich — dann steht `STATE`
# nicht mehr auf `pending` und dieser Zweig laeuft gar nicht erst.
#
# WARUM DIESE PROBE ZUSAETZLICH ZU gate-2-verdict-selftest.sh:
# Jener misst `eval_body()` ISOLIERT. Der Befund lag aber nicht in der Funktion,
# sondern in der KETTE darum herum — eine isolierte Funktionsprobe kann ihn
# strukturell nicht sehen. Gemessen wird hier der erreichte `STATE`.
#
# Der Kettenblock wird NICHT abgeschrieben, sondern IM GANZEN aus der
# Workflow-Datei gezogen (von `STATE=pending` bis vor die Zeile, die `state=`
# nach GITHUB_OUTPUT schreibt) und ausgefuehrt. Dreht jemand die Datei zurueck,
# faellt diese Probe.
# Gegen den alten Stand rotstellen:
#   git show <alter-sha>:.github/workflows/gate-2-codex.yml > /tmp/alt.yml
#   GATE2_WORKFLOW=/tmp/alt.yml bash scripts/gate-2-chain-selftest.sh
#
# Kein GitHub, kein Netzwerk.
# exit != 0 bei jeder fehlgeschlagenen Assertion → CI-Gate 'checks' schlaegt fehl.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
WF="${GATE2_WORKFLOW:-.github/workflows/gate-2-codex.yml}"
[ -r "$WF" ] || { echo "FATAL: $WF nicht lesbar"; exit 1; }

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ok   — %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL — %s\n' "$1"; }

# ---------------------------------------------------------------------------
# Den Kettenblock IM GANZEN aus dem Workflow ziehen
# ---------------------------------------------------------------------------
# Anker sind die ANWEISUNGEN selbst (`STATE=pending` als Vorgabewert; die Zeile,
# die den Status nach GITHUB_OUTPUT schreibt), nicht ihre Nachbarschaft: eine
# Probe, die ihre Anker aus der Nachbarzeile liest, wird falsch-positiv, sobald
# sich die Zeilenordnung aendert.
BLOCK_RAW="$(awk '
  !inb && $0 ~ /^[[:space:]]*STATE=pending[[:space:]]*$/ { inb=1; print; next }
  inb && index($0, "echo \"state=$STATE\"") { exit }
  inb { print }
' "$WF")"

echo "0) Der Kettenblock ist ueberhaupt da"
if [ -n "$BLOCK_RAW" ]; then
  ok "Kettenblock aus $WF gezogen ($(printf '%s' "$BLOCK_RAW" | grep -c .) Zeilen)"
else
  fail "kein Kettenblock in $WF gefunden — von 'STATE=pending' bis 'state=' nach GITHUB_OUTPUT"
  echo
  echo "=== $PASS passed, $FAIL failed ==="
  echo "gate-2-chain-selftest: FEHLGESCHLAGEN"
  exit 1
fi

PAD="$(printf '%s\n' "$BLOCK_RAW" | head -1 | sed 's/[^ ].*//')"
BLOCK="$(printf '%s\n' "$BLOCK_RAW" | sed "s/^${PAD}//")"

# Der Block muss BEIDE Zweige enthalten — sonst misst die Probe eine halbe Kette.
printf '%s' "$BLOCK" | grep -qF 'eval_body' \
  && ok "der Block bringt seine Verdict-Funktion mit" \
  || fail "im Block steht kein eval_body — die Kette ist unvollstaendig extrahiert"

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------
HEAD_SHA="2528273880dc8d48e29da855fd22340f9595c784"
SHORT_SHA="${HEAD_SHA:0:7}"
FREMD_SHA="9999999abcdef0000000000000000000000000000"

# Summary-Kommentar in der REALEN Form (Marker + Tabelle je Review-Lauf).
# $1=Status-Zelle  $2=Commit-Zelle
summary() {
  printf '%s\n\n## Codex Review Summary\n\n%s\n%s\n| 📝 **Code Review** | %s <relative-time datetime="2026-09-05T05:23:30Z">x</relative-time> | `%s` | PR opened |\n' \
    '<!-- codex-pull-request-review-summary -->' \
    '| Review | Status | Commit | Review trigger |' \
    '| --- | --- | --- | --- |' \
    "$1" "$2"
}
SUM_FERTIG="$(summary '✅ **Completed**' "$SHORT_SHA")"
SUM_LAEUFT="$(summary '⏳ **Running**'   "$SHORT_SHA")"
BEFUND_BODY='### Integrations-Befunde

- **P1** hier fehlt die Fehlerbehandlung'

# Die Kette einmal fahren und den erreichten Status zurueckgeben.
# $1=REVIEW_SHA $2=REVIEW_STATE $3=REVIEW_BODY $4=COMMENT_BODY $5=CODEX_OFFEN
kette() {
  (
    REVIEW_SHA="$1"; REVIEW_STATE="$2"; REVIEW_BODY="$3"
    COMMENT_BODY="$4"; CODEX_OFFEN="$5"
    export REVIEW_SHA REVIEW_STATE REVIEW_BODY COMMENT_BODY CODEX_OFFEN
    eval "$BLOCK" >/dev/null 2>&1
    printf '%s' "${STATE:-<leer>}"
  )
}

pruefe() { # $1=Fall  $2=erwartet  $3=erreicht
  if [ "$2" = "$3" ]; then
    ok "[$1] → state='$3'"
  else
    fail "[$1] → state='$3', erwartet '$2'"
  fi
}

# ---------------------------------------------------------------------------
# 1) Die neun Faelle der Kette
# ---------------------------------------------------------------------------
echo
echo "1) Die Kette Review-Zweig → Kommentar-Fallback"

# K1 — DER BEFUND: formales COMMENTED ohne Body, Urteil steht im Summary.
# Unter der alten Fassung (Kommentar-Zweig als `elif`) blieb das `pending`.
pruefe "K1 COMMENTED ohne Body + Summary Completed + 0 offen" \
  success "$(kette "$HEAD_SHA" COMMENTED "" "$SUM_FERTIG" 0)"

# K2 — ein klares Review bleibt verbindlich; der Fallback laeuft gar nicht erst.
pruefe "K2 APPROVED am HEAD" \
  success "$(kette "$HEAD_SHA" APPROVED "" "" 0)"

pruefe "K3 CHANGES_REQUESTED am HEAD" \
  failure "$(kette "$HEAD_SHA" CHANGES_REQUESTED "" "" 0)"

# K4 — COMMENTED MIT Befund-Body: das Urteil steht im Review selbst.
pruefe "K4 COMMENTED mit Findings-Body" \
  failure "$(kette "$HEAD_SHA" COMMENTED "$BEFUND_BODY" "" 0)"

# K5 — gar kein formales Review (der haeufige issue_comment-Lauf).
pruefe "K5 kein Review + Summary Completed" \
  success "$(kette "" "" "" "$SUM_FERTIG" 0)"

# K6 — abgeschlossener Lauf, aber offene Zeilenbefunde: 'Completed' allein ist
# KEINE Freigabe (llc-ops-backlog#1147).
pruefe "K6 COMMENTED ohne Body + 2 offene Threads" \
  failure "$(kette "$HEAD_SHA" COMMENTED "" "$SUM_FERTIG" 2)"

# K7 — der Summary existiert schon, WAEHREND der Lauf laeuft. Nie 'success'.
pruefe "K7 Summary Running" \
  pending "$(kette "$HEAD_SHA" COMMENTED "" "$SUM_LAEUFT" 0)"

# K8 — Review an einem FREMDEN Commit sagt ueber diesen HEAD nichts; der
# Summary am HEAD entscheidet.
pruefe "K8 Review an fremdem SHA + Summary am HEAD" \
  success "$(kette "$FREMD_SHA" CHANGES_REQUESTED "" "$SUM_FERTIG" 0)"

# K9 — Befundzahl unbekannt (Abruf oder Auswertung gescheitert). Leer darf NIE
# als 'null Befunde' gelesen werden.
pruefe "K9 offene Befunde unbekannt (leer)" \
  pending "$(kette "$HEAD_SHA" COMMENTED "" "$SUM_FERTIG" "")"

# K10-K13 — der Riegel steht seit Runde 12 VOR der ganzen Kette (Vorpruefung
# P1). Vorher sass er in `eval_body()`, und `APPROVED` setzte `success` direkt,
# also daran vorbei: ein Approval gab gruen, obwohl Codex-Befunde offen waren
# oder die Zahl gar nicht abrufbar war.
pruefe "K10 APPROVED am HEAD + 2 offene Befunde" \
  failure "$(kette "$HEAD_SHA" APPROVED "" "" 2)"

pruefe "K11 APPROVED am HEAD + Befundzahl unbekannt" \
  pending "$(kette "$HEAD_SHA" APPROVED "" "" "")"

# K12 — auch die Legacy-Bannerform im Review-Body kommt nicht vorbei (P1 R11).
pruefe "K12 Legacy-Banner im Review-Body + 1 offener Befund" \
  failure "$(kette "$HEAD_SHA" COMMENTED '### Codex Review' "" 1)"

# K13 — bewusst festgehalten: ist die Zahl UNBEKANNT, entscheidet die Kette gar
# nichts mehr, auch kein rotes Urteil. `CHANGES_REQUESTED` endet dann auf
# `pending` statt `failure`. Beide blockieren den Merge; die Irrtumsrichtung
# bleibt "zu vorsichtig". Der Fall steht hier, damit die Aenderung sichtbar ist
# und nicht unbemerkt zurueckkippt.
pruefe "K13 CHANGES_REQUESTED + Befundzahl unbekannt → pending" \
  pending "$(kette "$HEAD_SHA" CHANGES_REQUESTED "" "" "")"

# K14 — DER BEFUND aus Runde 15: fuer die Legacy-Bodyformen ist der Vorab-Treffer
# im Kommentar-Fallback die EINZIGE HEAD-Bindung (`eval_body()` prueft dort
# keinen SHA). Steckt der Kurz-Praefix nur INNERHALB einer laengeren Hex-Folge,
# nennt der Kommentar diesen HEAD nicht — das Banner darf nicht freigeben.
LEGACY_EINGEBETTET="Codex Review: no findings
geprueft an ff${SHORT_SHA}ff"
pruefe "K14 Legacy-Banner + Kurz-SHA nur eingebettet → pending" \
  pending "$(kette "" "" "" "$LEGACY_EINGEBETTET" 0)"

# K15 — Gegenprobe zu K14: derselbe Body, aber mit dem Kurz-SHA als
# eigenstaendiger Folge. Ohne sie meldete K14 auch dann gruen, wenn der
# Kommentar-Fallback ueberhaupt nicht mehr erreicht wird.
LEGACY_ECHT="Codex Review: no findings
geprueft an ${SHORT_SHA}"
pruefe "K15 Legacy-Banner + Kurz-SHA eigenstaendig → success (Gegenprobe)" \
  success "$(kette "" "" "" "$LEGACY_ECHT" 0)"

# ---------------------------------------------------------------------------
# 2) Gegenprobe: die Fixture von K1 trifft den Befund wirklich
# ---------------------------------------------------------------------------
# Ohne diese Gegenprobe koennte K1 auch dann gruen melden, wenn die Fixture den
# fehlerhaften Pfad gar nicht erreicht. Die alte Kettenform steht hier als
# Literal — nicht, um sie zu konservieren, sondern um zu belegen, dass genau
# dieser Eingang unter ihr `pending` ergab.
echo
echo "2) Gegenprobe an der alten Kettenform (Kommentar-Zweig als elif)"

ALT_KETTE='
STATE=pending
if [ -n "$REVIEW_SHA" ] && [ "$REVIEW_SHA" = "$HEAD_SHA" ]; then
  if [ "$REVIEW_STATE" = "APPROVED" ]; then
    STATE=success
  elif [ "$REVIEW_STATE" = "CHANGES_REQUESTED" ]; then
    STATE=failure
  else
    V=$(eval_body "$REVIEW_BODY" "$CODEX_OFFEN")
    [ "$V" = failure ] && STATE=failure
    [ "$V" = success ] && STATE=success
  fi
elif [ -n "$COMMENT_BODY" ] && echo "$COMMENT_BODY" | grep -qF -e "$HEAD_SHA" -e "$SHORT_SHA"; then
  V=$(eval_body "$COMMENT_BODY" "$CODEX_OFFEN")
  [ "$V" = failure ] && STATE=failure
  [ "$V" = success ] && STATE=success
fi
'

# Die Verdict-Funktion der ALTEN Kette ist dieselbe wie heute — der Unterschied
# liegt allein in der Verzweigung. Sie kommt deshalb aus dem geladenen Block.
FN_RAW="$(printf '%s\n' "$BLOCK" | awk '
  /^[[:space:]]*eval_body\(\)[[:space:]]*\{/ { f=1; indent=match($0,/[^ ]/)-1 }
  f { print }
  f && /^[[:space:]]*\}[[:space:]]*$/ && (match($0,/[^ ]/)-1)==indent { exit }
')"

alt_kette() { # gleiche Signatur wie kette()
  (
    REVIEW_SHA="$1"; REVIEW_STATE="$2"; REVIEW_BODY="$3"
    COMMENT_BODY="$4"; CODEX_OFFEN="$5"
    eval "$FN_RAW"
    eval "$ALT_KETTE" >/dev/null 2>&1
    printf '%s' "${STATE:-<leer>}"
  )
}

ALT_K1="$(alt_kette "$HEAD_SHA" COMMENTED "" "$SUM_FERTIG" 0)"
[ "$ALT_K1" = pending ] \
  && ok "alte Form: K1 blieb auf 'pending' — die Fixture trifft den Befund" \
  || fail "alte Form: erwartet 'pending', bekam '$ALT_K1' — die Fixture trifft den Befund NICHT"

# Gegenprobe zur Gegenprobe: die alte Form war nicht in jedem Fall blind, sonst
# koennte die obige Zeile auch bei einer voellig kaputten Fixture gruen melden.
ALT_K2="$(alt_kette "$HEAD_SHA" APPROVED "" "" 0)"
[ "$ALT_K2" = success ] \
  && ok "alte Form: APPROVED ergab auch dort 'success' (Fixture ist nicht generell kaputt)" \
  || fail "alte Form: erwartet 'success', bekam '$ALT_K2'"

echo
if [ "$FAIL" = 0 ]; then
  echo "=== $PASS passed, 0 failed ==="
  exit 0
fi
echo "=== $PASS passed, $FAIL failed ==="
echo "gate-2-chain-selftest: FEHLGESCHLAGEN"
exit 1
