#!/usr/bin/env bash
# Verhaltens-Simulation fuer .github/actions/green-rollback (PB LLC §8.6 / v7.0.0 E.5.2).
# Kein echter Deploy, kein GitHub: ein Mock-`gh` haelt Tag-Refs in einem Temp-State und
# loggt Rollback-Dispatches. Beweist: green/<sha> + green/latest werden gesetzt, Rollback
# dispatcht einen TAG-Ref (kein Commit-SHA -> strukturell kein 422), fehlt green/latest
# schlaegt der Rollback laut fehl (kein '|| true').
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ACTION_SH="$HERE/../.github/actions/green-rollback/green-rollback.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BIN="$TMP/bin"; STATE="$TMP/state"; mkdir -p "$BIN" "$STATE/tagref"

# --- Mock gh ---
cat > "$BIN/gh" <<'MOCK'
#!/usr/bin/env bash
# bash-3.2-kompatibel (macOS) — keine assoziativen Arrays.
set -uo pipefail
STATE="${GH_STATE:?}"
sub="${1:-}"; shift || true
if [ "$sub" = "api" ]; then
  method=GET; apipath=""; refval=""; shaval=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -X) method="$2"; shift 2;;
      -f|-F)
        kv="$2"; k="${kv%%=*}"; v="${kv#*=}"
        case "$k" in ref) refval="$v";; sha) shaval="$v";; esac
        shift 2;;
      --jq) shift 2;;
      -*) shift;;
      *) [ -z "$apipath" ] && apipath="$1"; shift;;
    esac
  done
  case "$apipath" in
    */git/refs/tags/*)
      tag="${apipath#*/git/refs/tags/}"; file="$STATE/tagref/$tag"
      case "$method" in
        GET)   [ -f "$file" ] && exit 0 || exit 1 ;;
        PATCH) mkdir -p "$(dirname "$file")"; printf '%s' "$shaval" > "$file"; exit 0 ;;
      esac ;;
    */git/refs)
      tag="${refval#refs/tags/}"; file="$STATE/tagref/$tag"
      mkdir -p "$(dirname "$file")"; printf '%s' "$shaval" > "$file"; exit 0 ;;
  esac
  exit 0
elif [ "$sub" = "workflow" ]; then
  ref=""
  while [ $# -gt 0 ]; do case "$1" in -r) ref="$2"; shift 2;; *) shift;; esac; done
  echo "$ref" >> "$STATE/dispatch.log"; exit 0
fi
exit 0
MOCK
chmod +x "$BIN/gh"
export GH_STATE="$STATE"
export PATH="$BIN:$PATH"

SHA_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
SHA_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
REPO="Paul-Brandenburg-LLC/mailer-app"

PASS=0; FAIL=0
ok()   { echo "  ok   $1"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL $1"; FAIL=$((FAIL+1)); }
tagval() { cat "$STATE/tagref/$1" 2>/dev/null || echo "<missing>"; }

run_action() { # MODE + optional SHA ; $1=mode $2=sha ; echoes rc; captures green_ref into GREEN_REF
  local out; out="$TMP/gh_output"; : > "$out"
  MODE="$1" SHA="${2:-}" DEPLOY_WF="deploy.yml" REPO="$REPO" GITHUB_OUTPUT="$out" \
    bash "$ACTION_SH" >/dev/null 2>&1
  local rc=$?
  GREEN_REF=$(sed -n 's/^green_ref=//p' "$out" | tail -1)
  return $rc
}

echo "=== green-rollback behavior simulation ==="

# 1) mark A
run_action mark "$SHA_A"; [ $? -eq 0 ] && [ "$(tagval green/$SHA_A)" = "$SHA_A" ] && [ "$(tagval green/latest)" = "$SHA_A" ] \
  && ok "mark A → green/$SHA_A + green/latest=A" || bad "mark A"

# 2) mark B (latest bewegt sich, A bleibt immutable)
run_action mark "$SHA_B"; [ "$(tagval green/latest)" = "$SHA_B" ] && [ "$(tagval green/$SHA_A)" = "$SHA_A" ] \
  && ok "mark B → green/latest=B, green/$SHA_A unveraendert" || bad "mark B / immutability"

# 3) mark A erneut → idempotent, kein Fehler, A unveraendert
run_action mark "$SHA_A"; rc=$?; [ $rc -eq 0 ] && [ "$(tagval green/$SHA_A)" = "$SHA_A" ] \
  && ok "mark A erneut → idempotent (rc=0)" || bad "mark A idempotent (rc=$rc)"

# 4) rollback → dispatch mit TAG-Ref green/latest, NICHT ein Commit-SHA (kein 422)
run_action rollback; rc=$?
DISP=$(tail -1 "$STATE/dispatch.log" 2>/dev/null || echo "")
if [ $rc -eq 0 ] && [ "$DISP" = "green/latest" ] && ! printf '%s' "$DISP" | grep -qE '^[0-9a-f]{40}$'; then
  ok "rollback → dispatch -r '$DISP' (Tag-Ref, kein 40-hex Commit-SHA) → kein 422"
else
  bad "rollback dispatch (rc=$rc, dispatched='$DISP')"
fi
[ "$GREEN_REF" = "green/latest" ] && ok "rollback green_ref-Output = green/latest" || bad "rollback output ($GREEN_REF)"

# 5) rollback ohne green/latest → lauter Fehler (exit 1), KEIN stiller Erfolg
rm -rf "$STATE/tagref"/* "$STATE/dispatch.log"; mkdir -p "$STATE/tagref"
run_action rollback; rc=$?
[ $rc -eq 1 ] && [ ! -f "$STATE/dispatch.log" ] && ok "rollback ohne green/latest → exit 1 (kein stiller Erfolg)" || bad "rollback-empty (rc=$rc)"

# 6) statischer Check: KEIN '|| true' in Action-Logik
if grep -qE '\|\|[[:space:]]*true' "$ACTION_SH" "$HERE/../.github/actions/green-rollback/action.yml"; then
  bad "'|| true' im Action-Code gefunden (Audit-Anti-Pattern!)"
else
  ok "kein '|| true' im Action-Code"
fi

echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
