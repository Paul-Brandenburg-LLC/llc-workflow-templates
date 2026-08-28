#!/usr/bin/env bash
# Rendert den Caller .github/workflows/pre-pr-quartett.yml (create-if-missing).
# $1 = Templates-Tag (z.B. v1.7.0). Ausgabe: fertige Caller-YAML auf stdout.
#
# PB LLC §3.b.2 v7.6.1 — llc-ops-backlog#1096, Nebenbefund "die Datei hat keine
# Welle": pre-pr-quartett.yml lag in KEINEM Template-Pfad, propagate-templates.yml
# konnte sie also nie verteilen. Das erklaert beide Haelften des Befundes auf
# einmal — warum elf Repos die Datei nie bekamen, und warum die uebrigen 24 seit
# v1.1.2 auf demselben Stand standen, waehrend die Action bei v1.6.2 war.
# Ein Pin ohne Verteilweg ist eine Zusage, die niemand einloest.
#
# ⚠ Diese Datei ist KEIN Reusable-Workflow-Caller, sondern ein eigener Job, der
# eine Composite Action aufruft. Der Pin steht deshalb auf
# `.github/actions/pre-pr-quartett@TAG`, nicht auf `.github/workflows/...@TAG`.
# Wer das verwechselt, laesst den Migrate-Zweig von propagate-templates.yml auf
# sie los — und der rendert einen Gate-2-Codex-Wrapper ueber sie. Siehe die
# Klassenprobe in scripts/pre-pr-quartett-selftest.sh.
set -euo pipefail
TAG="${1:?Tag erforderlich (z.B. v1.7.0)}"

# Unquoted Heredoc: ${TAG} expandiert; das GitHub-Ausdruck-Literal ${{ ... }}
# wird per \$ vor der Bash-Expansion geschuetzt und bleibt woertlich erhalten.
cat <<YAML
name: Pre-PR-Quartett (Server-side)

# PB LLC §3.b.2 — Server-side-Spiegel des lokalen Plugin-Hooks.
# Schliesst die Out-of-band-PR-Luecke (gh-cli ohne Plugin, Web-UI, MCP ausserhalb Claude).
# Auto-seeded via propagate-templates.yml (create-if-missing).
# Kein lokaler Edit dieser Datei — Patches gehoeren ins templates-Repo.

on:
  pull_request:
    types: [opened, synchronize, reopened]

permissions:
  contents: read
  pull-requests: read

jobs:
  quartett:
    runs-on: ubuntu-latest
    timeout-minutes: 5
    steps:
      - uses: actions/checkout@b4ffde65f46336ab88eb53be808477a3936bae11  # v4.2.2
      - uses: Paul-Brandenburg-LLC/llc-workflow-templates/.github/actions/pre-pr-quartett@${TAG}
        with:
          repo: \${{ github.repository }}
          tier: auto
YAML
