#!/usr/bin/env bash
# Offline-Testharness fuer die Scope-Erkennung in gate-2-codex.yml.
# Repliziert die Datei-Klassifikation des Reusable-Workflows 1:1:
#  - Doc-only (Step "Scope Skip", PB LLC §3.4 v5.8 M2 + v7.0.4 Render-PR-Regel)
#  - Pin-Bump (PB LLC §3.4 v7.0.5 — reine Versions-Tag-Bumps von Org-Reusables)
# Kein GitHub, kein Netzwerk.
# exit != 0 bei jeder fehlgeschlagenen Assertion → CI-Gate 'checks' schlaegt fehl.
set -uo pipefail

# --- IDENTISCH zur Inline-Logik in gate-2-codex.yml (Step "Scope Skip") -------
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

# --- IDENTISCH zur Inline-Logik in gate-2-codex.yml (Step "Scope Skip", v7.0.5) ---
# true, wenn der GESAMTE Diff ausschliesslich den Versions-Tag bestehender
# Org-Reusable-uses-Zeilen in .github/workflows/*.yml aendert (kein Ziel-/
# with:-/Zeilen-Wechsel, kein Major-Bump, keine weiteren Hunks/Dateien).
# stdin: JSON-Array von PR-File-Objekten (Felder .filename, .patch).
is_pin_bump() {
  local JSON nfiles bad i patch line body key major addf rmf
  JSON="$(cat)"
  nfiles=$(printf '%s' "$JSON" | jq 'length')
  case "$nfiles" in ''|*[!0-9]*) echo false; return;; esac
  [ "$nfiles" -gt 0 ] || { echo false; return; }
  # (a) jede geaenderte Datei ist ein Workflow-File
  bad=$(printf '%s' "$JSON" | jq -r '[.[] | select((.filename|test("^\\.github/workflows/[^/]+\\.ya?ml$"))|not)] | length')
  [ "$bad" = "0" ] || { echo false; return; }
  addf="$(mktemp)"; rmf="$(mktemp)"
  i=0
  while [ "$i" -lt "$nfiles" ]; do
    patch=$(printf '%s' "$JSON" | jq -r ".[$i].patch // \"\"")
    while IFS= read -r line; do
      case "$line" in
        '+++'*|'---'*|'@@'*|' '*|'') : ;;
        '+'*|'-'*)
          # (b) jede +/- Zeile MUSS eine Org-Reusable-uses-Zeile mit Semver-Tag sein
          if ! printf '%s\n' "$line" | grep -qE '^[-+][[:space:]]*uses:[[:space:]]*Paul-Brandenburg-LLC/llc-workflow-templates/\.github/workflows/[A-Za-z0-9._-]+\.ya?ml@v[0-9]+\.[0-9]+\.[0-9]+[[:space:]]*$'; then
            command rm -f "$addf" "$rmf"; echo false; return
          fi
          body=${line:1}
          major=$(printf '%s' "$body" | sed -E 's/.*@v([0-9]+)\.[0-9]+\.[0-9]+[[:space:]]*$/\1/')
          key=$(printf '%s' "$body" | sed -E 's/@v[0-9]+\.[0-9]+\.[0-9]+[[:space:]]*$//')
          case "$line" in
            '+'*) printf '%s\t%s\n' "$key" "$major" >> "$addf" ;;
            '-'*) printf '%s\t%s\n' "$key" "$major" >> "$rmf"  ;;
          esac
          ;;
        *) : ;;
      esac
    done <<< "$patch"
    i=$((i + 1))
  done
  # (e) mind. je eine +/- Zeile; (c)+(d) Multiset (key,major): added == removed
  if [ -s "$addf" ] && [ -s "$rmf" ] && diff <(sort "$addf") <(sort "$rmf") >/dev/null; then
    command rm -f "$addf" "$rmf"; echo true
  else
    command rm -f "$addf" "$rmf"; echo false
  fi
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

echo "=== gate-2 pin-bump scenarios (§3.4 v7.0.5) ==="

# Baut ein PR-files-JSON-Array aus (filename, patch)-Paaren — exakt die Form,
# die der Workflow via `gh api .../pulls/N/files` erhaelt.
files_json() { # args: f1 p1 [f2 p2 ...]  → JSON-Array auf stdout
  local out="" f p
  while [ "$#" -gt 0 ]; do
    f="$1"; p="$2"; shift 2
    out="$out$(jq -n --arg f "$f" --arg p "$p" '{filename:$f, patch:$p}')"$'\n'
  done
  printf '%s' "$out" | jq -s '.'
}

USESLINE='    uses: Paul-Brandenburg-LLC/llc-workflow-templates/.github/workflows'

# P1) Reiner Tag-Bump, 1 Datei (v1.5.2 → v1.5.3) → SKIP
P=$(printf '@@ -1,3 +1,3 @@ jobs:\n bridge:\n-%s/gate-2-codex.yml@v1.5.2\n+%s/gate-2-codex.yml@v1.5.3\n   secrets: inherit\n' "$USESLINE" "$USESLINE")
V=$(files_json '.github/workflows/gate-2-codex.yml' "$P" | is_pin_bump); check "pinbump-single-file" true "$V"

# P2) Reiner Tag-Bump, mehrere Dateien → SKIP
P2A=$(printf '@@ -1,2 +1,2 @@\n-%s/gate-2-codex.yml@v1.5.2\n+%s/gate-2-codex.yml@v1.5.3\n' "$USESLINE" "$USESLINE")
P2B=$(printf '@@ -1,2 +1,2 @@\n-%s/review.yml@v1.5.2\n+%s/review.yml@v1.5.3\n' "$USESLINE" "$USESLINE")
V=$(files_json '.github/workflows/gate-2-codex.yml' "$P2A" '.github/workflows/review.yml' "$P2B" | is_pin_bump); check "pinbump-multi-file" true "$V"

# P3) Major-Bump (v1 → v2) → KEIN SKIP
P=$(printf '@@ -1,2 +1,2 @@\n-%s/gate-2-codex.yml@v1.5.2\n+%s/gate-2-codex.yml@v2.0.0\n' "$USESLINE" "$USESLINE")
V=$(files_json '.github/workflows/gate-2-codex.yml' "$P" | is_pin_bump); check "pinbump-major-bump→blocks" false "$V"

# P4) with:-Block-Aenderung zusaetzlich → KEIN SKIP
P=$(printf '@@ -1,3 +1,4 @@\n-%s/gate-2-codex.yml@v1.5.2\n+%s/gate-2-codex.yml@v1.5.3\n+    with:\n+      use_app_token: false\n' "$USESLINE" "$USESLINE")
V=$(files_json '.github/workflows/gate-2-codex.yml' "$P" | is_pin_bump); check "pinbump-with-change→blocks" false "$V"

# P5) Misch-Diff mit Nicht-uses-Zeile → KEIN SKIP
P=$(printf '@@ -1,3 +1,3 @@\n-%s/gate-2-codex.yml@v1.5.2\n+%s/gate-2-codex.yml@v1.5.3\n-  timeout-minutes: 5\n+  timeout-minutes: 10\n' "$USESLINE" "$USESLINE")
V=$(files_json '.github/workflows/gate-2-codex.yml' "$P" | is_pin_bump); check "pinbump-mixed-nonuses→blocks" false "$V"

# P6) uses-Ziel-Aenderung (Pfad wechselt, gleicher Tag) → KEIN SKIP
P=$(printf '@@ -1,2 +1,2 @@\n-%s/gate-2-codex.yml@v1.5.2\n+%s/review.yml@v1.5.2\n' "$USESLINE" "$USESLINE")
V=$(files_json '.github/workflows/gate-2-codex.yml' "$P" | is_pin_bump); check "pinbump-target-change→blocks" false "$V"

# P7) Nicht-Workflow-Datei (Pfad ausserhalb .github/workflows) → KEIN SKIP
P=$(printf '@@ -1,2 +1,2 @@\n-%s/gate-2-codex.yml@v1.5.2\n+%s/gate-2-codex.yml@v1.5.3\n' "$USESLINE" "$USESLINE")
V=$(files_json 'docs/example.yml' "$P" | is_pin_bump); check "pinbump-nonworkflow-path→blocks" false "$V"

# P8) Reine Netto-Addition (neue uses-Zeile, kein Removal) → KEIN SKIP (unbalanciert)
P=$(printf '@@ -1,1 +1,2 @@\n bridge:\n+%s/gate-2-codex.yml@v1.5.3\n' "$USESLINE")
V=$(files_json '.github/workflows/gate-2-codex.yml' "$P" | is_pin_bump); check "pinbump-net-add→blocks" false "$V"

# P9) uses-Ziel auf Fremd-Action (nicht Org-Reusable) → KEIN SKIP
P=$(printf '@@ -1,2 +1,2 @@\n-%s/gate-2-codex.yml@v1.5.2\n+    uses: actions/checkout@v4.2.2\n' "$USESLINE")
V=$(files_json '.github/workflows/gate-2-codex.yml' "$P" | is_pin_bump); check "pinbump-foreign-action→blocks" false "$V"

# P10) Nur Kontext-/Hunk-Zeilen, keine echte +/- Aenderung → KEIN SKIP
P=$(printf '@@ -1,2 +1,2 @@ jobs:\n bridge:\n   secrets: inherit\n')
V=$(files_json '.github/workflows/gate-2-codex.yml' "$P" | is_pin_bump); check "pinbump-context-only→blocks" false "$V"

echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
