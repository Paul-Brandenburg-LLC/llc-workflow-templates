# llc-workflow-templates

Reusable Workflows + Composite Actions für die LLC-Org. Implementiert verbindlich **PB LLC: Entwicklung §3.4 / §7.2 / §3.b.2** (Standard ≥ v5.10).

Single source of truth für CI-Patterns die in allen 22 LLC-Repos identisch sein müssen. Repos pinnen auf einen SemVer-Tag (`@v1`, `@v1.1`, `@v2`).

## Inhalt

### Composite Actions (`.github/actions/`)

- `pre-pr-quartett/` — Server-side Pre-PR-Quartett-Gate (§3.b.2, Required-Status-Check pro Repo). Spiegelt den lokalen Plugin-Hook serverseitig — schließt Out-of-band-PR-Lücke (gh-cli ohne Plugin, Web-UI).

### Reusable Workflows (`.github/workflows/`)

- `gate-2-codex.yml` — Bridge-Workflow für Codex-Comment-Match → `gate-2-codex` Status-Check. Spiegelt blockzocker-Pattern (PR #82+#84) als zentrale Quelle.
- `cold-start-ci.yml` — Tier-1/2 Cold-Start-Probe gegen unerreichbare TEST-NET-IPs (`192.0.2.0/24`, RFC 5737). NestJS- und Go-Stacks unterstützt.
- `deploy-nestjs-tier1.yml` — NestJS-Deploy-Pattern mit `dist/.git-sha`-Stamp + Restart-Issue-Auto-Close (blockzocker-Stand v5.9.1).
- `resolve-gpt5-findings.yml` — Auto-Resolver-Loop für Cross-Vendor-Review-Findings (Phase E in Standard v5.9.2).
- `visual-regression-baseline.yml` — Initial-Snapshot-Generation für Tier-1 (Phase L).

## Versionierung

SemVer-Tags. Repos pinnen auf Major-Tag (`@v1`) für automatische Patch+Minor-Updates, oder auf exakten Tag (`@v1.2.3`) für stable-pinning.

## Verwendung

### Composite-Action (`pre-pr-quartett`)

```yaml
# In jedem LLC-Repo: .github/workflows/pre-pr-quartett.yml
name: Pre-PR-Quartett
on: pull_request

jobs:
  quartett:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: Paul-Brandenburg-LLC/llc-workflow-templates/.github/actions/pre-pr-quartett@v1
        with:
          repo: ${{ github.repository }}
```

### Reusable-Workflow (`gate-2-codex`)

```yaml
# In jedem LLC-Repo: .github/workflows/gate-2-codex.yml
name: Gate 2 Codex
on:
  pull_request:
    types: [opened, synchronize, reopened]
  pull_request_review:
    types: [submitted, edited]
  issue_comment:
    types: [created, edited]

jobs:
  bridge:
    uses: Paul-Brandenburg-LLC/llc-workflow-templates/.github/workflows/gate-2-codex.yml@v1
    secrets: inherit
```

## Tier

Tier 4 (kein App-Server, nur Workflow-Templates). Test = `actionlint` + `shellcheck` auf Workflow-Files.

## Spec-Verweis

`team-workflow.md` §3.b.2 Server-side Gate (v5.10+), §16.X Workflow-Templates-Pinning.
