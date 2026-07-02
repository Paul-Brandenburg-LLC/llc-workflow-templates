#!/usr/bin/env bash
# Offline-Harness fuer pin-bump-decide.sh — deterministisch, kein Netzwerk.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=pin-bump-decide.sh
source "$HERE/pin-bump-decide.sh"

T="gate-2-codex.yml"
PASS=0; FAIL=0
check() { # $1=name $2=template $3=pinned $4=tag $5=want_mode
  DECISION_MODE=""; DECISION_REASON=""
  pin_bump_decide "$2" "$3" "$4"
  if [ "$DECISION_MODE" = "$5" ]; then
    printf '  ok   [%s] pinned=%-42s tag=%-8s → %s (%s)\n' "$1" "${3:-<static>}" "$4" "$DECISION_MODE" "$DECISION_REASON"; PASS=$((PASS+1))
  else
    printf '  FAIL [%s] pinned=%s tag=%s → got %s, want %s (%s)\n' "$1" "${3:-<static>}" "$4" "$DECISION_MODE" "$5" "$DECISION_REASON"; FAIL=$((FAIL+1))
  fi
}

echo "=== pin-bump-decide offline scenarios ==="
check "static→migrate"          "$T" ""                                         "v1.1.6" migrate
check "old-exact→pinbump"       "$T" "v1.1.2"                                   "v1.1.6" pinbump
check "at-target→skip"          "$T" "v1.1.6"                                   "v1.1.6" skip
check "floating-major→skip"     "$T" "v1"                                       "v1.1.6" skip
check "commit-sha→skip"         "$T" "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678" "v1.1.6" skip
check "newer-than-target→skip"  "$T" "v1.2.0"                                   "v1.1.6" skip
check "major-bump→skip"         "$T" "v1.1.2"                                   "v2.0.0" skip
check "minor-in-line→pinbump"   "$T" "v1.0.9"                                   "v1.2.0" pinbump
check "garbage-ref→skip"        "$T" "main"                                     "v1.1.6" skip

echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
