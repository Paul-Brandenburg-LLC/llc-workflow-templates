#!/usr/bin/env bash
# Selftest fuer die Doku-Erkennung des Cold-Start-Scope-Gates (cold-start-ci.yml).
# Spiegelt EXAKT das Regex aus dem Workflow-Step "Scope — laueft die Probe?".
# Erwartung: nur wenn ALLE geaenderten Dateien ins Doku-Muster passen, wird die
# Probe uebersprungen (run_probe=false); sonst volle Probe (DENY-FIRST).
set -euo pipefail

DOKU_RE='\.md$|\.mdx$|\.txt$|(^|/)LICENSE$|(^|/)CODEOWNERS$'

# gibt "false" (skip) aus, wenn alle Zeilen Doku sind, sonst "true"
scope() {
  local files="$1" nichtdoku
  [ -z "$files" ] && { echo true; return; }
  nichtdoku=$(printf '%s\n' "$files" | grep -vE "$DOKU_RE" || true)
  [ -z "$nichtdoku" ] && echo false || echo true
}

fail=0
check() { # $1=erwartet $2=beschreibung $3=dateiliste
  local got; got=$(scope "$3")
  if [ "$got" = "$1" ]; then echo "ok: $2 → run_probe=$got"
  else echo "::error::FAIL: $2 — erwartet $1, bekam $got"; fail=1; fi
}

# Nur-Doku → skip (false)
check false "reine Markdown-Aenderung"        $'README.md\ndocs/guide.md'
check false "CLAUDE.md Pin-Bump"               $'CLAUDE.md'
check false "LICENSE + Textdatei"              $'LICENSE\nnotes.txt'
check false "docs-Unterordner (Markdown)"      $'docs/adr/0003.md'

# Code unter docs/ ist KEIN Doku → volle Probe (Codex-P1-Fix)
check true  "Code unter docs/ (JS)"            $'docs/app/server.js'
check true  "docs/ Bild ohne Doku-Endung"      $'docs/img/logo.png'

# Alles mit Code/Config/Workflow/Lockfile → volle Probe (true)
check true  "App-Code geaendert"               $'src/main.ts'
check true  "Doku UND Code gemischt"           $'README.md\nsrc/app.ts'
check true  "Workflow-Datei"                   $'.github/workflows/ci.yml'
check true  "package.json"                     $'package.json'
check true  "Lockfile"                         $'package-lock.json'
check true  "PHP-Datei"                        $'public/index.php'
check true  "Config (yaml)"                    $'astro.config.mjs'
check true  "leere Liste = unsicher → voll"    ''

[ "$fail" = 0 ] && echo "coldstart-scope-selftest: ALLE OK" || { echo "coldstart-scope-selftest: FEHLER"; exit 1; }
