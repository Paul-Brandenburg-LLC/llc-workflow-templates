# Templates — `templates/`

Konfig-Templates, die pro Repo in `.github/<file>` kopiert werden. Anders als `.github/actions/` (Composite-Actions, die als `uses:` von außen referenziert werden), werden diese Files **kopiert**, nicht referenziert — Dependabot-Konfig kennt keine `uses:`-Indirektion.

## Inhalt

| Datei | Ziel-Pfad pro Repo | Spec-Anker |
|---|---|---|
| `dependabot.yml` | `.github/dependabot.yml` | team-workflow.md §12 + Plugin `/llc-dependabot-sweep` |

## Anwendung

```bash
# Pro Adoption-Repo:
curl -sSL https://raw.githubusercontent.com/Paul-Brandenburg-LLC/llc-workflow-templates/main/templates/dependabot.yml \
  -o .github/dependabot.yml
# Nicht-zutreffende Ecosystem-Blöcke entfernen (z. B. composer in Node-Repos)
git add .github/dependabot.yml
git commit -m "chore(deps): adopt llc-workflow-templates/dependabot.yml"
```

Bulk-Sync wird über das Patch-Script in `~/.claude/scripts/dependabot-sync-rollout.sh` (siehe Memory-Eintrag `project_phase_n_hygiene_routinen_2026_04_28.md`) automatisiert.
