#!/usr/bin/env bash
# Offline-Testharness für scripts/render-auto-pin-bump-caller.sh.
# Beweist, dass der create-if-missing-Seed (propagate-templates.yml) einen
# gültigen, actionlint-fähigen Thin-Caller erzeugt, der strukturell mit den
# Bestands-Callern (vgl. llc-ops-backlog) identisch ist. Kein Netzwerk.
# exit != 0 bei jeder fehlgeschlagenen Assertion → CI-Gate 'checks' schlägt fehl.
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
RENDER="$DIR/render-auto-pin-bump-caller.sh"

PASS=0; FAIL=0
ok()   { echo "  ok   [$1]"; PASS=$((PASS+1)); }
bad()  { echo "  FAIL [$1] $2"; FAIL=$((FAIL+1)); }
assert_contains() { # name haystack needle
  case "$2" in *"$3"*) ok "$1" ;; *) bad "$1" "fehlt: '$3'" ;; esac
}

echo "=== render-auto-pin-bump-caller scenarios ==="

# 1) Ohne Tag-Argument → Fehler (Guard).
if bash "$RENDER" >/dev/null 2>&1; then
  bad "no-arg-fails" "haette exit!=0 liefern muessen"
else
  ok "no-arg-fails"
fi

OUT=$(bash "$RENDER" v1.5.1)

# 2) Erste Nicht-Kommentar-Zeile ist top-level 'name:' OHNE Einrückung.
FIRST=$(printf '%s\n' "$OUT" | head -1)
[ "$FIRST" = "name: Auto Pin-Bump (Plugin-Update)" ] && ok "top-level-name-no-indent" \
  || bad "top-level-name-no-indent" "erste Zeile war: '$FIRST'"

# 3) Tag korrekt injiziert.
assert_contains "uses-tag" "$OUT" "auto-pin-bump.yml@v1.5.1"

# 4) GitHub-Ausdruck-Literal bleibt WÖRTLICH erhalten (nicht bash-expandiert).
assert_contains "client-payload-literal" "$OUT" 'version: ${{ github.event.client_payload.version }}'

# 5) Trigger + secrets exakt wie Bestands-Caller.
assert_contains "trigger-dispatch" "$OUT" "types: [plugin-bump]"
assert_contains "secrets-inherit"  "$OUT" "secrets: inherit"
assert_contains "perms-contents"   "$OUT" "contents: write"
assert_contains "perms-pulls"      "$OUT" "pull-requests: write"

# 6) Anderer Tag → anderer Pin (Tag ist der einzige Freiheitsgrad).
OUT2=$(bash "$RENDER" v1.6.0)
assert_contains "other-tag" "$OUT2" "auto-pin-bump.yml@v1.6.0"
case "$OUT2" in *"@v1.5.1"*) bad "no-stale-tag" "v1.5.1 leakt in v1.6.0-Render" ;; *) ok "no-stale-tag" ;; esac

# 7) Gültiges YAML mit genau einem Job 'bump', dessen uses den Reusable trifft.
if command -v python3 >/dev/null 2>&1; then
  PYOK=$(printf '%s' "$OUT" | python3 -c "
import yaml,sys
d=yaml.safe_load(sys.stdin)
j=list(d['jobs'].keys())
u=d['jobs']['bump']['uses']
assert j==['bump'], j
assert u.endswith('auto-pin-bump.yml@v1.5.1'), u
assert d['jobs']['bump']['secrets']=='inherit'
# 'on' wird von PyYAML zu True gemappt (YAML 1.1) — beide Keys tolerieren.
on=d.get('on', d.get(True))
assert on['repository_dispatch']['types']==['plugin-bump'], on
print('yaml-ok')
" 2>&1) || true
  [ "$PYOK" = "yaml-ok" ] && ok "valid-yaml-structure" || bad "valid-yaml-structure" "$PYOK"
else
  echo "  skip [valid-yaml-structure] (kein python3)"
fi

echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
