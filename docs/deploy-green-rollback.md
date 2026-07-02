# Auto-Rollback via `green/<sha>` — Deploy-Pattern

**Standard:** PB LLC: Entwicklung §8.6 / v7.0.0 Anhang E.5.2.
**Audit-Befund (2026-07-02):** Auto-Rollback war org-weit defekt — der Rollback-Step
dispatchte den **Commit-SHA** des letzten grünen Runs als `ref`
(`gh workflow run -r <40-hex>`) → **HTTP 422** (ein `ref` muss Branch **oder Tag** sein,
kein blanker Commit-SHA), und ein angehängter true-Fallback schluckte den Fehler still.
Belegt an blockzocker Run 28531401474.

## Fix (Composite-Action `green-rollback`)

- **Erfolgspfad:** Nach bestandenem §8.6-Effect-Check (Smoke/Health) wird der Commit als
  **unveränderliches Tag `green/<sha>`** markiert und der bewegliche Zeiger **`green/latest`**
  nachgezogen (`mode: mark`).
- **Failure-Pfad:** Ein `if: failure()`-Step (`mode: rollback`) dispatcht den Deploy erneut mit
  **`-r green/latest`** — ein echter **TAG-Ref** → strukturell **kein 422** mehr.
- **Ohne Fehler-Schlucker:** Kein `|| true`; ein fehlgeschlagener Rollback-Dispatch macht den
  Job rot. Fehlt `green/latest` (allererster Deploy), schlägt der Rollback laut fehl statt still.

## Einbindung in eine `deploy.yml`

```yaml
permissions:
  contents: write   # green-Tags anlegen/bewegen (mark)
  actions: write    # Rollback-Deploy dispatchen (rollback)

jobs:
  deploy:
    steps:
      # … checkout, drift-check, snapshot, mirror/deploy …

      - name: Smoke test (§8.6-Effect-Check)
        if: github.event.inputs.dry_run != 'true'
        run: ./scripts/smoke-test.sh

      # ✅ Nur wenn ALLE vorherigen Steps (inkl. Smoke) grün sind:
      - name: Mark green
        if: github.event.inputs.dry_run != 'true'
        uses: Paul-Brandenburg-LLC/llc-workflow-templates/.github/actions/green-rollback@v1
        with:
          mode: mark
          github_token: ${{ secrets.GITHUB_TOKEN }}

      # 🔁 Bei Failure irgendeines Steps: zurück auf green/latest.
      - name: Rollback on failure
        if: failure() && github.event_name == 'push' && github.event.inputs.dry_run != 'true'
        uses: Paul-Brandenburg-LLC/llc-workflow-templates/.github/actions/green-rollback@v1
        with:
          mode: rollback
          deploy_workflow: deploy.yml
          github_token: ${{ secrets.GITHUB_TOKEN }}
```

**Loop-Sicherheit:** Der Rollback-Step läuft nur bei `github.event_name == 'push'`. Der
Rollback selbst dispatcht via `workflow_dispatch` (Event ≠ `push`) → ein fehlschlagender
Rollback-Deploy triggert **keinen** zweiten Rollback. Kein Endlos-Loop.

## Exakter Diff für `mailer-app` (Tier-2, lftp/Infomaniak)

`mailer-app/.github/workflows/deploy.yml` hat heute den 422-Bug:

```diff
       - name: Smoke test
         if: github.event.inputs.dry_run != 'true'
         run: ./scripts/smoke-test.sh

+      - name: Mark green (§8.6 bestanden)
+        if: github.event.inputs.dry_run != 'true'
+        uses: Paul-Brandenburg-LLC/llc-workflow-templates/.github/actions/green-rollback@v1
+        with:
+          mode: mark
+          github_token: ${{ secrets.GITHUB_TOKEN }}
+
       - name: Rollback on failure
         if: failure() && github.event_name == 'push' && github.event.inputs.dry_run != 'true'
         env:
           GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
         run: |
-          LAST_GREEN=$(gh run list --workflow=deploy.yml --branch=main --status=success \
-            --limit=1 --json headSha -q '.[0].headSha' -R "${{ github.repository }}")
-          if [ -z "$LAST_GREEN" ]; then
-            echo "::warning::Kein vorheriger grüner Deploy — kein Auto-Rollback möglich"; exit 0
-          fi
-          gh workflow run deploy.yml -r "$LAST_GREEN" -f ref="$LAST_GREEN" \
-            -R "${{ github.repository }}" || true
+          # ersetzt durch green-rollback-Action (mode: rollback), siehe unten
```

und `permissions:` von `contents: read` → `contents: write` (für `mark`). Der `run:`-Block
wird durch einen zweiten `uses: …/green-rollback@v1` (mode: rollback) ersetzt.

> **Adoptions-Hinweis:** `mailer-app` (und alle Tier-1/2-Deploy-Repos) tragen
> `customer: "internal-LLC-services"` → ein Edit ihrer `deploy.yml` ist ein Workflow-Change in
> einem Customer-Repo und **Owner-Approval-gated** (`block-workflow-change-customer-repo-without-approval`).
> Ausserdem ist ein echter roter Smoke-Test gegen die lftp-/Infomaniak-Prod riskant. Deshalb ist
> die Wirkung **verhaltens-simuliert** (`scripts/green-rollback-selftest.sh`, 7/7) statt live gegen
> Prod erzwungen. Die eigentliche Adoption erfolgt als Owner-approbierter Folge-PR.

## Beweis

`scripts/green-rollback-selftest.sh` (Mock-`gh`, Temp-Tag-State, kein Netz):
1. `mark A` → `green/A` + `green/latest=A`
2. `mark B` → `green/latest=B`, `green/A` unverändert (immutable)
3. `mark A` erneut → idempotent
4. `rollback` → dispatcht **`-r green/latest`** (Tag-Ref, **kein** 40-hex Commit-SHA → kein 422)
5. `rollback` ohne `green/latest` → **exit 1** (kein stiller Erfolg)
6. statisch: **kein `|| true`** im Action-Code
