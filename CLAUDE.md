---
standard_version: "7.0.3"
standard_pinned_at: "2026-07-05"
plugin_version: "1.19.2"
prepush_stack: "static"
tier: 4
critical_paths: []
customer: false
---
# llc-workflow-templates — Projektmemory

## Zweck
Single source of truth für reusable CI-Patterns in allen 22 LLC-Repos. Composite Actions + Reusable Workflows.

## Stack
GitHub Actions YAML, Bash. Kein eigener App-Server.

## Lokaler Start
Keiner — Templates werden via `uses:` aus anderen Repos konsumiert.

## Deploy
Tag-basiert: `git tag v1.X.Y && git push --tags`. Repos pinnen auf `@v1` (Major) oder `@v1.X.Y` (exakt).

## gate-1-verdict: Gate 1 (claude-review) → Exit (seit v1.2.0, 2026-07-03)
`gate-1-verdict.yml` (Reusable) macht Gate 1 blockierbar: liest einen HEAD-gebundenen Marker
`<!-- llc-review-verdict:approve|needs_changes sha=<HEAD> -->` aus dem `claude[bot]`-Kommentar,
setzt Status `gate-1-verdict` + exit 1 bei `needs_changes`. **Wichtig:** Consumer verwenden **nicht**
das Plugin-Skill / diesen `review.yml`-Reusable, sondern inline-Prompts in ihrer eigenen `review.yml`
— der Marker muss dort emittiert werden (SHA via `${{ github.event.pull_request.head.sha }}` getemplatet).
Details + Rollout: `docs/gate-1-verdict.md`. Beweis: `scripts/gate-1-verdict-selftest.sh` (offline) +
`gate-1-selftest.yml` (live-E2E auf PRs dieses Repos). Blockierend erst nach Owner-BP-Registrierung.

## gate-2-codex: bridge-Status (seit v1.1.5, 2026-06-02)
Der `gate-2-codex.yml`-Reusable-Job heißt `bridge` → GitHub erzeugt den Check-Run `bridge / bridge`, der den Required-Context `bridge` (in manchen Consumer-Repos) NICHT matcht. Seit **v1.1.5** postet der Workflow den Status daher unter BEIDEN Contexts (`gate-2-codex` + `bridge`), additiv. Behebt das Auto-Merge-Hängen von Daemon-Flush-PRs (PR #14).

## Critical Lessons
- Workflow-Files müssen `actionlint`-clean sein (CI prüft das)
- SHA-Pinning in `uses:` ist Pflicht ab Standard v5.11 (siehe `team-workflow.md` §N)
- Composite-Action `pre-pr-quartett` MUSS deterministisches Verhalten haben — bei Inkonsistenz zu lokalem Hook ist die Composite-Action die Wahrheit (Server-side gewinnt)