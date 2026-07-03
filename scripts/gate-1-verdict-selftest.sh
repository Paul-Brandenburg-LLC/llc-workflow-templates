#!/usr/bin/env bash
# Offline-Testharness fuer gate-1-verdict.yml — PB LLC: Entwicklung §3.4 / Anhang E.3.
# Repliziert die Marker-Parse- + HEAD-Bindungs-Logik des Reusable-Workflows 1:1 und
# prueft alle Verdict-Szenarien deterministisch (kein GitHub, kein Netzwerk).
# exit != 0 bei jeder fehlgeschlagenen Assertion → CI-Gate 'checks'/'offline' schlaegt fehl.
set -uo pipefail

# --- IDENTISCH zur Inline-Logik in gate-1-verdict.yml (Step "Read llc-review verdict marker") ---
# Eingabe: $1 = HEAD_SHA, stdin = ein Kommentar-Body (oder mehrere via wiederholten Aufruf).
# Ausgabe: echo verdict ("approve"/"needs_changes"/"") fuer DIESEN Body.
extract_verdict() {
  local head_sha="$1" body m v s head_lc
  body="$(cat)"
  m=$(printf '%s\n' "$body" | grep -oE '<!-- llc-review-verdict:(approve|needs_changes) sha=[0-9a-fA-F]{7,40} -->' | tail -1 || true)
  [ -z "$m" ] && { echo ""; return; }
  v=$(printf '%s' "$m" | sed -E 's/.*verdict:(approve|needs_changes) sha=.*/\1/')
  s=$(printf '%s' "$m" | sed -E 's/.*sha=([0-9a-fA-F]{7,40}) -->/\1/' | tr 'A-F' 'a-f')
  head_lc=$(printf '%s' "$head_sha" | tr 'A-F' 'a-f')
  case "$head_lc" in
    "$s"*) echo "$v" ;;
    *)     echo "" ;;
  esac
}

# Verdict → (state, exit-code) — identisch zum Workflow-Mapping.
verdict_to_state() {
  case "$1" in
    needs_changes) echo "failure 1" ;;
    approve)       echo "success 0" ;;
    *)             echo "pending 0" ;;
  esac
}

HEAD="a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"
SHORT="a1b2c3d"
OTHER="00ff00ff00ff00ff00ff00ff00ff00ff00ff00ff"

PASS=0; FAIL=0
check() { # $1=name  $2=expected_state  $3=expected_exit  $4=actual_verdict
  read -r st ex <<<"$(verdict_to_state "$4")"
  if [ "$st" = "$2" ] && [ "$ex" = "$3" ]; then
    echo "  ok   [$1] verdict='${4:-<none>}' → state=$st exit=$ex"; PASS=$((PASS+1))
  else
    echo "  FAIL [$1] verdict='${4:-<none>}' → got state=$st exit=$ex, want state=$2 exit=$3"; FAIL=$((FAIL+1))
  fi
}

echo "=== gate-1-verdict offline scenarios (HEAD=$HEAD) ==="

# 1) needs_changes, voller HEAD-SHA → failure + exit 1
V=$(printf '## Empfehlung: needs changes\nBla.\n<!-- llc-review-verdict:needs_changes sha=%s -->\n' "$HEAD" | extract_verdict "$HEAD")
check "needs_changes@full-head" failure 1 "$V"

# 2) approve, voller HEAD-SHA → success
V=$(printf 'Safe.\n<!-- llc-review-verdict:approve sha=%s -->\n' "$HEAD" | extract_verdict "$HEAD")
check "approve@full-head" success 0 "$V"

# 3) approve, Short-SHA (Praefix) → success (HEAD-Bindung via Praefix)
V=$(printf '<!-- llc-review-verdict:approve sha=%s -->\n' "$SHORT" | extract_verdict "$HEAD")
check "approve@short-head" success 0 "$V"

# 4) approve, aber STALE SHA (anderer Commit) → pending (kein False-Green!)
V=$(printf '<!-- llc-review-verdict:approve sha=%s -->\n' "$OTHER" | extract_verdict "$HEAD")
check "approve@stale-sha→pending" pending 0 "$V"

# 5) needs_changes, aber STALE SHA → pending (blockt nicht faelschlich auf altem Commit)
V=$(printf '<!-- llc-review-verdict:needs_changes sha=%s -->\n' "$OTHER" | extract_verdict "$HEAD")
check "needs_changes@stale-sha→pending" pending 0 "$V"

# 6) gar kein Marker → pending
V=$(printf '## Empfehlung: approve\nnur Prosa, kein Marker.\n' | extract_verdict "$HEAD")
check "no-marker→pending" pending 0 "$V"

# 7) mehrere Marker im Body → letzter (aktuellster) gewinnt
V=$(printf '<!-- llc-review-verdict:approve sha=%s -->\nspaeter revidiert:\n<!-- llc-review-verdict:needs_changes sha=%s -->\n' "$HEAD" "$HEAD" | extract_verdict "$HEAD")
check "multi-marker→last-wins(needs_changes)" failure 1 "$V"

# 8) Marker in Grossbuchstaben-SHA → case-insensitive Bindung
V=$(printf '<!-- llc-review-verdict:approve sha=%s -->\n' "$(printf '%s' "$HEAD" | tr 'a-f' 'A-F')" | extract_verdict "$HEAD")
check "approve@uppercase-sha" success 0 "$V"

# 9) Malformed Marker (kein sha=) → ignoriert → pending
V=$(printf '<!-- llc-review-verdict:approve -->\n' | extract_verdict "$HEAD")
check "malformed-marker→pending" pending 0 "$V"

echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1

# --- Empfehlung-Fallback-Parse (v1.4.0, spiegelt gate-1-verdict.yml Fallback-Step) ---
empfehlung_verdict() { # stdin=comment body -> approve|needs_changes|""
  local body empf; body="$(cat)"
  empf=$(printf '%s' "$body" | awk 'tolower($0) ~ /##[[:space:]]*empfehlung/{f=1} f{print}' | tr 'A-Z' 'a-z' | head -4 | tr '\n' ' ')
  local nc ap; nc=$(printf '%s' "$empf" | grep -cE 'needs[ _-]changes|request changes|aenderung' || true); ap=$(printf '%s' "$empf" | grep -cE 'approve|freigabe|safe-to-merge' || true)
  if [ "${nc:-0}" -ge 1 ] && [ "${ap:-0}" -ge 1 ]; then echo ""
  elif [ "${nc:-0}" -ge 1 ]; then echo needs_changes
  elif [ "${ap:-0}" -ge 1 ]; then echo approve
  else echo ""; fi
}
echo "=== Empfehlung-Fallback scenarios ==="
PASS2=0; FAIL2=0
chk2(){ [ "$2" = "$3" ] && { echo "  ok   [$1] -> $2"; PASS2=$((PASS2+1)); } || { echo "  FAIL [$1] got '$2' want '$3'"; FAIL2=$((FAIL2+1)); }; }
V=$(printf '## Zusammenfassung\nkram\n## Risiken\nKeine.\n## Empfehlung: approve\nSafe-to-merge.\n' | empfehlung_verdict); chk2 "inline-approve" "$V" "approve"
V=$(printf '## Empfehlung: needs changes\nDatei X Zeile Y.\n' | empfehlung_verdict); chk2 "inline-needs-changes" "$V" "needs_changes"
V=$(printf '## Empfehlung\n[approve | needs changes] -> approve\n' | empfehlung_verdict); chk2 "template-platzhalter-ambiguous" "$V" ""
V=$(printf '## Risiken\n- approve-Flow prüfen (kein Verdict!)\n## Empfehlung: needs changes\n' | empfehlung_verdict); chk2 "risks-approve-no-falsematch" "$V" "needs_changes"
V=$(printf '## Zusammenfassung\nnur Prosa, keine Empfehlung.\n' | empfehlung_verdict); chk2 "keine-empfehlung" "$V" ""
echo "=== Empfehlung: $PASS2 passed, $FAIL2 failed ==="
[ "$FAIL2" -eq 0 ] || exit 1
