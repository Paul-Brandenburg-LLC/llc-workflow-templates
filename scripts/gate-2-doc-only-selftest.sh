#!/usr/bin/env bash
# Offline-Testharness fuer die Doc-only-Scope-Erkennung in gate-2-codex.yml.
# Repliziert die Datei-Klassifikation des Reusable-Workflows 1:1 (Step "Doc-only Skip")
# inkl. des optionalen Consumer-Inputs extra_doc_only_regex (PB LLC §3.4 v7.0.4
# Render-PR-Regel, Realitaets-Audit 2026-07-06). Kein GitHub, kein Netzwerk.
# exit != 0 bei jeder fehlgeschlagenen Assertion → CI-Gate 'checks' schlaegt fehl.
set -uo pipefail

# --- IDENTISCH zur Inline-Logik in gate-2-codex.yml (Step "Doc-only Skip") ---
# Eingabe: $1 = extra_doc_only_regex (leer erlaubt), stdin = Dateiliste (ein Pfad je Zeile).
# Ausgabe: echo "true" wenn ALLE Pfade doc-only sind, sonst "false".
scope_is_doc_only() {
  local EXTRA_DOC_ONLY_REGEX="$1" f FILES DOC_ONLY=1
  FILES="$(cat)"
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if [[ ! "$f" =~ \.(md|markdown)$ ]] && \
       [[ ! "$f" =~ ^docs/ ]] && \
       [[ ! "$f" =~ ^CHANGELOG ]] && \
       [[ ! "$f" =~ ^\.github/ISSUE_TEMPLATE/ ]] && \
       [[ ! "$f" =~ ^feedback_.*\.md$ ]] && \
       { [ -z "$EXTRA_DOC_ONLY_REGEX" ] || [[ ! "$f" =~ $EXTRA_DOC_ONLY_REGEX ]]; }; then
      DOC_ONLY=0; break
    fi
  done <<< "$FILES"
  [ "$DOC_ONLY" = "1" ] && echo "true" || echo "false"
}

RENDER_RE='^llc-checkliste-deploy/specs/.*\.html$'

PASS=0; FAIL=0
check() { # $1=name  $2=expected(true|false)  $3=actual
  if [ "$2" = "$3" ]; then
    echo "  ok   [$1] → skip=$3"; PASS=$((PASS+1))
  else
    echo "  FAIL [$1] → got skip=$3, want skip=$2"; FAIL=$((FAIL+1))
  fi
}

echo "=== gate-2 doc-only scope scenarios ==="

# 1) Reines Markdown → doc-only (kein Extra-Regex noetig)
V=$(printf 'README.md\ndocs/guide.md\n' | scope_is_doc_only ''); check "pure-markdown" true "$V"

# 2) Code-Datei → NICHT doc-only
V=$(printf 'src/app.ts\nREADME.md\n' | scope_is_doc_only ''); check "code-file-blocks" false "$V"

# 3) feedback_*.md + docs/ → doc-only (Standard-Muster)
V=$(printf 'feedback_x.md\ndocs/y.md\nCHANGELOG.md\n' | scope_is_doc_only ''); check "feedback+docs+changelog" true "$V"

# 4) Render-HTML OHNE Extra-Regex → NICHT doc-only (Regression-Schutz: Default-Verhalten)
V=$(printf 'llc-checkliste-deploy/specs/v7.html\n' | scope_is_doc_only ''); check "render-html-no-extra→blocks" false "$V"

# 5) Render-HTML MIT Extra-Regex → doc-only (Render-PR-Regel greift)
V=$(printf 'llc-checkliste-deploy/specs/v7.html\n' | scope_is_doc_only "$RENDER_RE"); check "render-html-with-extra" true "$V"

# 6) Render-HTML + Markdown MIT Extra-Regex → doc-only (Mix erlaubt)
V=$(printf 'llc-checkliste-deploy/specs/v7.html\nREADME.md\n' | scope_is_doc_only "$RENDER_RE"); check "render-html+md-with-extra" true "$V"

# 7) Render-HTML + Code MIT Extra-Regex → NICHT doc-only (Code bleibt blockierend)
V=$(printf 'llc-checkliste-deploy/specs/v7.html\nsrc/app.ts\n' | scope_is_doc_only "$RENDER_RE"); check "render-html+code-with-extra→blocks" false "$V"

# 8) Extra-Regex matcht NICHT den Pfad (anderes Verzeichnis) → NICHT doc-only
V=$(printf 'other/specs/v7.html\n' | scope_is_doc_only "$RENDER_RE"); check "extra-regex-no-match→blocks" false "$V"

# 9) Leeres Extra-Regex darf NICHT alles matchen (Empty-Pattern-Falle) → Code blockt weiter
V=$(printf 'src/app.ts\n' | scope_is_doc_only ''); check "empty-extra-not-matchall" false "$V"

echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
