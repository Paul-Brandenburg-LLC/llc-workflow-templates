#!/usr/bin/env bash
# Offline-Testharness fuer die Verdict-Erkennung + die Ereignis-Unabhaengigkeit
# des Scope-Riegels in gate-2-codex.yml.
#
# Deckt den Deadlock ab, der jeden Doc-only-PR der Org unmergebar machte
# (llc-ops-backlog#87, erstmals 2026-04-29 an v1.1.2 gemeldet, am 2026-09-05 an
# nachrichtenmaschine-app#356 mit v1.8.0 erneut belegt):
#
#   1. Der Step `scope` trug `if: github.event_name == 'pull_request'`. Auf dem
#      `issue_comment`-Lauf, den Codex mit seinem Zusammenfassungs-Kommentar
#      ausloest, lief er nicht — `steps.scope.outputs.skip` blieb LEER. Leer ist
#      nicht `'true'`, also passierten die nachfolgenden Steps ihren Waechter
#      (`skip != 'true'`) und die Bruecke fiel in den Codex-Urteilszweig.
#   2. Dort traf `eval_body()` den realen Kommentar nicht: verlangt waren genau
#      drei Rauten (`^### Codex Review`), Codex schreibt aber
#      `## Codex Review Summary`. `STATE` blieb auf dem Vorgabewert `pending`
#      und ueberschrieb das eigene, zuvor korrekt gesetzte `success`.
#   3. Gruen wurde es nie von selbst: der Code rechnet mit einem folgenden
#      `pull_request_review`-Event, aber ein Review OHNE Befund existiert bei
#      Codex nicht — es kommt nur eine 👍-Reaktion. Kein Event, Deadlock.
#
# Die Muster werden AUS DER WORKFLOW-DATEI GELESEN, nicht hier kopiert. Damit
# kann der Test nicht gruen bleiben, wenn jemand die Datei zurueckdreht.
# Gegen den alten Stand rotstellen:
#   git show <alter-sha>:.github/workflows/gate-2-codex.yml > /tmp/alt.yml
#   GATE2_WORKFLOW=/tmp/alt.yml bash scripts/gate-2-verdict-selftest.sh
#
# Kein GitHub, kein Netzwerk.
# exit != 0 bei jeder fehlgeschlagenen Assertion → CI-Gate 'checks' schlaegt fehl.
set -uo pipefail

WF="${GATE2_WORKFLOW:-.github/workflows/gate-2-codex.yml}"
[ -r "$WF" ] || { echo "FATAL: $WF nicht lesbar"; exit 1; }

# --- Muster aus der Workflow-Datei ziehen (Single Source of Truth) -----------
# Die beiden Zeilen haben die Form:
#   if   echo "$1" | grep -qE '<FAILURE_RE>'; then echo failure
#   elif echo "$1" | grep -qE '<SUCCESS_RE>'; then echo success
extract_re() { # $1 = failure|success
  sed -n "s/.*grep -qE '\(.*\)'; then echo $1\$/\1/p" "$WF" | head -1
}
FAILURE_RE="$(extract_re failure)"
SUCCESS_RE="$(extract_re success)"

[ -n "$FAILURE_RE" ] || { echo "FATAL: FAILURE_RE nicht aus $WF extrahierbar"; exit 1; }
[ -n "$SUCCESS_RE" ] || { echo "FATAL: SUCCESS_RE nicht aus $WF extrahierbar"; exit 1; }

# --- IDENTISCH zur Inline-Logik in gate-2-codex.yml (Step "Read Codex Review") -
# Reihenfolge ist bedeutungstragend: Befunde schlagen die Banner-Erkennung.
eval_body() { # $1=body → echoes success|failure|"" (kein erkennbares Verdict)
  if echo "$1" | grep -qE "$FAILURE_RE"; then echo failure
  elif echo "$1" | grep -qE "$SUCCESS_RE"; then echo success
  else echo ""; fi
}

PASS=0; FAIL=0
check() { # $1=name  $2=expected  $3=actual
  if [ "$2" = "$3" ]; then
    echo "  ok   [$1] → verdict='$3'"; PASS=$((PASS+1))
  else
    echo "  FAIL [$1] → got verdict='$3', want '$2'"; FAIL=$((FAIL+1))
  fi
}

echo "=== gate-2 verdict scenarios (Muster aus $WF) ==="

# --- V1: DER REGRESSIONSFALL --------------------------------------------------
# Der reale Codex-Zusammenfassungs-Kommentar aus nachrichtenmaschine-app#356.
# ZWEI Rauten plus 'Summary'. Gegen v1.1.2..v1.8.1 ergibt das '' → pending →
# Deadlock. Muss success sein.
BODY_SUMMARY='## Codex Review Summary

Reviewed 2528273. No issues found.'
V=$(eval_body "$BODY_SUMMARY"); check "codex-summary-2-rauten (llc-ops-backlog#87)" success "$V"

# V2) Vier Rauten — die Erkennung darf nicht auf eine feste Tiefe festgenagelt sein
V=$(eval_body '#### Codex Review'); check "codex-review-4-rauten" success "$V"

# V3+V4) Die historisch bekannten Formen bleiben erkannt (Regressionsschutz)
V=$(eval_body '### 💡 Codex Review

Looks good.'); check "codex-review-banner-emoji" success "$V"
V=$(eval_body '### Codex Review'); check "codex-review-3-rauten" success "$V"
V=$(eval_body 'Codex Review: no findings'); check "codex-review-prefix-form" success "$V"

# V5) Befunde schlagen die Banner-Erkennung, auch im Summary-Format
V=$(eval_body '## Codex Review Summary

### Findings
- something'); check "findings-schlagen-banner" failure "$V"
V=$(eval_body '## Codex Review Summary

**P1** Datenverlust moeglich'); check "P1-schlaegt-banner" failure "$V"
V=$(eval_body '## Codex Review Summary

🚨 kritisch'); check "alarm-schlaegt-banner" failure "$V"

# V6) KEIN Verdict → '' (Status bleibt pending). Das ist der URSPRUNGSFALL aus
#     llc-ops-backlog#87: ein 'Codex usage limits'-Hinweis ist kein Urteil und
#     darf keines vortaeuschen.
V=$(eval_body 'Codex usage limits reached. Try again later.'); check "usage-limits-kein-verdict" "" "$V"
V=$(eval_body 'Danke fuer den PR!'); check "fremdkommentar-kein-verdict" "" "$V"

# V7) 'Codex Review' MITTEN in einer Zeile ist kein Banner — die Anker `^`
#     duerfen nicht verlorengehen, sonst faelscht ein Zitat ein Approval.
V=$(eval_body 'siehe die Codex Review Summary von gestern'); check "banner-nur-am-zeilenanfang" "" "$V"
V=$(eval_body 'ich zitiere: Codex Review: alles gut'); check "prefix-nur-am-zeilenanfang" "" "$V"

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
