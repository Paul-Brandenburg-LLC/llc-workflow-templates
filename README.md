# llc-workflow-templates

Reusable Workflows + Composite Actions für die LLC-Org. Implementiert verbindlich **PB LLC: Entwicklung §3.4 / §7.2 / §3.b.2** (Standard ≥ v5.10).

Single source of truth für CI-Patterns die in allen 22 LLC-Repos identisch sein müssen. Repos pinnen auf einen SemVer-Tag (`@v1`, `@v1.1`, `@v2`).

## Inhalt

### Composite Actions (`.github/actions/`)

- `pre-pr-quartett/` — Server-side Pre-PR-Quartett-Gate (§3.b.2, Required-Status-Check pro Repo). Spiegelt den lokalen Plugin-Hook serverseitig — schließt Out-of-band-PR-Lücke (gh-cli ohne Plugin, Web-UI).

### Verteilte Ganz-Dateien (`distribution/`)

Dateien, die als GANZES in die Consumer-Repos geschrieben werden — fuer Faelle,
die ein `uses:`-Pin nicht traegt. Erkennungszeile im Ziel:
`llc-verteilung: verwaltet`. Wer sie im Ziel entfernt, uebernimmt die Datei
selbst; die Verteilung weist ihn dann als Abweichler aus und fasst ihn nie an.
Entscheidung: `scripts/verteilung-decide.sh`, Beweis
`scripts/verteilung-decide-selftest.sh`.

- `entwicklung-review.yml` + `entwicklung_review_bridge.py` — das Box-Tor
  (Status `entwicklung-review`). Die Bruecke wird als Datei aus dem Arbeitsbaum
  des Consumers gestartet, ein Reusable-Pin reicht dafuer nicht; beide Dateien
  gehen deshalb in EINEM PR. Verteilt via
  `propagate-templates.yml` mit `template: entwicklung-review`.
  ⛔ Ziel-Repos nur die drei, die die Box kennt (`llc-ops-backlog`,
  `llc-paulbrandenburg-com-app`, `standards`).

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

## Tor-Ausweichung bei Herstellerausfall (Standard 8.1, Kapitel 5)

Alle drei Tore nennen den pruefenden Hersteller, und keines bleibt bei einem
Ausfall stumm stehen:

| Tor | Kontext | Verhalten bei Ausfall |
| --- | --- | --- |
| Claude-Review | `review` / `gate-1-verdict` | unveraendert (Marker-Pflicht) |
| Codex | `gate-2-codex` + `bridge` | weicht auf den Box-Pruefer aus, wenn das Box-Tor fuer DENSELBEN Commit `approve` gemeldet hat |
| Box (Grok) | `entwicklung-review` | Status nennt den Pruefer-Hersteller und den Ausfall |

⛔ **Ausfall ist nicht dasselbe wie kaputter Lauf.** Die v8-Ausfallregel
(Warnung statt Rot) gilt nur, wenn der Pruefer erreicht wurde und selbst
`unavailable` gemeldet hat. Scheitert der Lauf schon davor — PR-Text ohne
`Implementierer-Hersteller`, fehlende Zugangsdaten, unerreichbare Box, kaputte
Quittung, Programmfehler —, hat niemand geprueft: das Tor geht auf `error`, der
Grund steht im Status-Text (`[llc-stoerung:<grund>]`), und der Lauf selbst wird
rot. Ein gruenes Pflichttor IST gegenueber der Branch-Protection eine Freigabe,
gleich was im Text daneben steht.

Das Box-Tor schreibt zwei HEAD-gebundene Marken in seinen Status-Text:
`[llc-tor:<vendor>/<verdikt>]` und, bei einem Sperrvermerk,
`[llc-ausfall:<vendor>/<grund>]`. Einen Status setzen kann nur, wer
Schreibrecht am Repo hat — der Autor eines Fork-PR also nicht; die Marke ist
damit so vertrauenswuerdig wie der Status selbst. Fremdtext, der ueber die
Bruecke in den Status-Text wandert (der Grund eines Sperrvermerks kommt von der
Box), wird vorher entschaerft. Das Codex-Tor liest sie
und weicht aus; ein `success` ohne `approve`-Marke gibt es nicht, auch nicht
beim fail-open des Box-Tors. Jeder Ausweich-Text nennt den Ausfall im Klartext.

Beweise: `scripts/codex-ausweichung-selftest.sh` (30 Faelle; die
Entscheidungsfunktion UND der ganze Ausweich-Schritt werden aus der
Workflow-Datei gezogen, `gh` und die Statuses sind Attrappen) und
`tests/test_entwicklung_review_bridge.py` (56 Faelle, `gh`/`ssh` als
Attrappen). Die Faelle E1/E2 nageln fest, dass ein Box-Approve an einem
AELTEREN Commit den neuen HEAD nicht freigibt; E3/E4, dass die Frist am
App-geschriebenen `created_at` des Box-Status haengt und nicht an der vom
PR-Autor setzbaren Git-Committer-Zeit; F1-F3, dass Fremdtext aus der Box die
Verdikt-Marke nicht faelschen kann.

## Tier

Tier 4 (kein App-Server, nur Workflow-Templates). Test = `actionlint` + `shellcheck` auf Workflow-Files.

## Spec-Verweis

`team-workflow.md` §3.b.2 Server-side Gate (v5.10+), §16.X Workflow-Templates-Pinning.
