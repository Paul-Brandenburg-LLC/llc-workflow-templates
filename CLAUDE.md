---
standard_version: "5.11.4"
standard_pinned_at: "2026-05-01"
plugin_version: "1.12.4"
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

## Critical Lessons
- Workflow-Files müssen `actionlint`-clean sein (CI prüft das)
- SHA-Pinning in `uses:` ist Pflicht ab Standard v5.11 (siehe `team-workflow.md` §N)
- Composite-Action `pre-pr-quartett` MUSS deterministisches Verhalten haben — bei Inkonsistenz zu lokalem Hook ist die Composite-Action die Wahrheit (Server-side gewinnt)
