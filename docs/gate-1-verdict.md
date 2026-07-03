# Gate 1 (claude-review) Verdict → Exit — Rollout-Doku

**Standard:** PB LLC: Entwicklung §3.4 / Anhang E.3 (M13b).
**Audit-Befund (2026-07-02):** Gate 1 war rein beratend — der Reviewer schrieb
„## Empfehlung: needs changes", aber nichts machte den Check rot; mm#128 wurde mit
„Needs Changes" gemergt. Dieser Mechanismus schliesst die Lücke.

## Zwei Hälften

### a) Marker-Emission (im **effektiven** Review-Prompt)

> **Architektur-Befund (wichtig):** Die Consumer-Repos verwenden **nicht** das Plugin-Skill
> `/llc-review` und **nicht** den Reusable `review.yml` aus diesem Repo. Jedes Repo trägt seinen
> Reviewer-Prompt **inline** in seiner eigenen `.github/workflows/review.yml`
> (`prompt: | …`, `claude_code_oauth_token`). Das Plugin-Skill und der `review.yml`-Reusable
> hier sind damit **Referenz/SSOT-Persona**, nicht der laufende Code. Der Marker muss dort
> emittiert werden, wo der Reviewer real läuft = im Inline-Prompt jeder Consumer-`review.yml`.

Hänge an den Inline-Reviewer-Prompt (nach „## Empfehlung") genau das an:

```
Beende deinen Review-Kommentar mit GENAU einer dieser Zeilen als allerletztes (nichts dahinter).
Ersetze <verdict> durch `approve`, wenn deine Empfehlung "approve" lautet, sonst durch `needs_changes`:

<!-- llc-review-verdict:<verdict> sha=${{ github.event.pull_request.head.sha }} -->
```

`${{ github.event.pull_request.head.sha }}` wird von GitHub Actions **vor** dem Modell-Aufruf in
den Prompt-Text expandiert → der SHA ist autoritativ (nicht modell-generiert); das Modell wählt
nur das Verdict-Token. Damit ist der Marker HEAD-gebunden, ohne dass das Modell `git` aufrufen muss.

### b) Parser (dieser Reusable — `gate-1-verdict.yml`)

Liest den neuesten Kommentar des Review-Bots (`claude[bot]`), extrahiert den Marker, prüft
**HEAD-Bindung** (Marker-SHA = aktueller HEAD, Short-SHA als Präfix erlaubt) und setzt:

| Verdict @ HEAD | Commit-Status `gate-1-verdict` | Job-Exit |
|---|---|---|
| `needs_changes` | `failure` | **1 (rot)** |
| `approve` | `success` | 0 |
| kein/stale Marker | `pending` | 0 |

Stale-Approval ist ausgeschlossen: ein `approve` von Commit A zählt nicht für Commit B
(gleiche HEAD-Bindung wie `gate-2-codex.yml` v7.0.0).

## Consumer-Einbindung

In der Consumer-`ci.yml` (oder eigener `gate-1.yml`):

```yaml
jobs:
  gate-1-verdict:
    uses: Paul-Brandenburg-LLC/llc-workflow-templates/.github/workflows/gate-1-verdict.yml@v1
    secrets: inherit
```

Trigger sollte `pull_request` + `issue_comment` (created) sein, damit der Parser erneut läuft,
sobald `claude[bot]` seinen Verdict-Kommentar postet.

## Blockierend schalten = Owner-Aktion (BP)

Der Check wird **erst dann Merge-blockierend**, wenn der Owner den Kontext **`gate-1-verdict`**
zu den Required-Status-Checks der Branch-Protection hinzufügt. Branch-Protection-Toggle ist eine
Owner-Aktion (mir per §4-Hook verboten). Bis dahin ist der Check sichtbar (rot/grün), aber nicht
zwingend.

## Beweise

- **Offline:** `scripts/gate-1-verdict-selftest.sh` — 9/9 Parse-/HEAD-Bindungs-Szenarien.
- **Live-E2E:** `.github/workflows/gate-1-selftest.yml` — postet auf jedem PR (der Gate-1-Dateien
  berührt) einen HEAD-gebundenen `needs_changes`-Marker und ruft den echten Reusable auf; der wird
  **rot** (exit 1). Der `assert`-Job (grün) bestätigt, dass die Rötung erwartetes Verhalten ist.

## Rollout-Welle (offen, Owner-Approval-gated)

Der Marker-Append in jede Consumer-`review.yml` ist eine Workflow-Änderung in (teils Customer-)
Repos → Owner-Approval-Hook. Sinnvoll gebündelt über die Adoptions-/Propagations-Welle.
Bis der Marker in einer Consumer-`review.yml` steht, bleibt `gate-1-verdict` dort `pending`
(blockt nicht fälschlich — fail-safe).

## v1.4.0 — Empfehlung-Fallback (löst den Self-Mod-Guard-Blocker)

**Problem:** Der Gate-1-Marker sollte aus der Consumer-`review.yml` kommen — aber ein PR, der `review.yml` ändert, lässt die claude-review-Action fehlschlagen (**Self-Mod-Guard §16.10**: „workflow file must have identical content to default branch"). Damit war der Marker-Ansatz **strukturell nicht ausrollbar** (bewiesen an mailer #99).

**Fix:** `gate-1-verdict.yml` parst jetzt als **Fallback** das `## Empfehlung`-Urteil **direkt** aus dem `claude[bot]`-Kommentar und bindet es über den **Run-SHA** des Kommentars an den HEAD (robuster als Timestamp). **Kein review.yml-Edit mehr nötig.** Mehrdeutige Empfehlungen (unausgefüllter Platzhalter) → `pending` (fail-safe). Der explizite Marker bleibt als optionaler, präziserer Override erhalten.

**Konsequenz für den Rollout:** Gate 1 wird armierbar durch **nur** (a) `gate-1-verdict.yml@v1` als Job in der Consumer-`ci.yml` (kein self-modding Workflow) + (b) `gate-1-verdict` als Required-Check (Owner-BP). Keine 20 self-mod-geblockten review.yml-PRs.
