#!/usr/bin/env bash
# Rendert den Thin-Caller .github/workflows/auto-pin-bump.yml (create-if-missing).
# $1 = Templates-Tag (z.B. v1.5.1). Ausgabe: fertige Caller-YAML auf stdout.
#
# Bytegleich zur Struktur der 20 Bestands-Caller (vgl. llc-ops-backlog): reagiert
# auf repository_dispatch [plugin-bump], ruft den Reusable @TAG mit `version` aus
# dem client_payload, `secrets: inherit`. Einziger Freiheitsgrad = der Tag.
# PB LLC §3.4 v7.0.4 — propagate-templates.yml seedet damit Repos ohne die Datei.
set -euo pipefail
TAG="${1:?Tag erforderlich (z.B. v1.5.1)}"

# Unquoted Heredoc: ${TAG} expandiert; das GitHub-Ausdruck-Literal ${{ ... }}
# wird per \$ vor der Bash-Expansion geschützt und bleibt wörtlich erhalten.
cat <<YAML
name: Auto Pin-Bump (Plugin-Update)

# PB LLC §3.4 v7.0.4 — Thin-Caller auf den Reusable in llc-workflow-templates.
# Auto-seeded via propagate-templates.yml (create-if-missing).
# Kein lokaler Edit dieser Datei — Patches gehören ins templates-Repo.

on:
  repository_dispatch:
    types: [plugin-bump]

permissions:
  contents: write
  pull-requests: write

jobs:
  bump:
    uses: Paul-Brandenburg-LLC/llc-workflow-templates/.github/workflows/auto-pin-bump.yml@${TAG}
    with:
      version: \${{ github.event.client_payload.version }}
    secrets: inherit
YAML
