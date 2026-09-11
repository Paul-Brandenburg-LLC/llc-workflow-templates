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
  ⛔ Das Paar wird als EINE Einheit entschieden (`verteilung_paar_modus`): ist
  eine Haelfte Abweichler, wird KEINE angefasst und kein PR geoeffnet. Ein
  Workflow ohne seine Bruecke laeuft bei jedem PR in „No such file" und laesst
  genau das tote Pflichttor stehen, das Kapitel 5 verhindern soll.

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

### Woher der Ausfall kommt — drei Quellen, ein Trichter

Der Codex-Ausfall wird ermittelt, BEVOR der Status-Text entsteht, und zwar an
dem einen Punkt, durch den alle Quellen laufen (`sperren_zusammenfuehren`):

1. `health` der Box (`vendor_blocks`) — heute stumm, `health` steht nicht in
   der Allowlist des Zwangskommandos;
2. `review-result.reason` — traegt nur, wenn der Box-Pruefer selbst
   `unavailable` meldet;
3. die Meldung des Codex-Bots am PR — die Quelle, die im Hauptfall (Box gibt
   `approve`, Codex schweigt an der Grenze) als einzige etwas weiss.

⛔ Quelle 3 ist deshalb dicht gebaut: exakter Login `chatgpt-codex-connector[bot]`
(kein Praefix — `codexplorer` fiel darunter), ein Wortlaut, der Grenze UND
Erreichen nennt (ein blosses „rate limit" steht in normaler Pruefprosa), und
eine HEAD-Bindung: es zaehlen nur Meldungen, die nach dem `created_at` des
`pending`-Status entstanden sind, den die Bruecke selbst fuer diesen Commit
schreibt. Nicht ermittelbar heisst nicht raten — dann ist Quelle 3 aus.

### Die Zeitkette — Modellzug < Frist < Workflow-Deckel

Drei Grenzen an drei Orten, und die kleinste gewinnt immer:

| Glied | Wo | Wert |
| --- | --- | --- |
| Modellzug des Box-Pruefers | llc-ops-backlog, `entwicklung_delivery.py` | 1500 s (Annahme, hier nicht messbar) |
| Frist der Bruecke | `FRIST_SEKUNDEN` in `entwicklung_review_bridge.py` | 1800 s |
| Deckel des Workflows | `timeout-minutes` in `entwicklung-review.yml` | 40 min = 2400 s |

Der oberste Deckel traegt mehr als die Frist. **Drei Kosten liegen ausserhalb
des Fristzaehlers von `collect()` und werden trotzdem von ihm bezahlt:**
`review-start` laeuft davor (`SSH_DECKEL`, 120 s), ein Nachzuegler-Abruf darf
eine Sekunde vor der Frist noch starten und einen vollen SSH-Deckel lang laufen
(120 s), und `health` laeuft danach (`NACHLAUF_HEALTH`, 60 s). Zusammen 300 s —
genau der `KETTEN_MINDESTABSTAND`. Bei den urspruenglich gebauten 35 min war er
damit rechnerisch aufgebraucht, bevor checkout, Python-Start und der Auslauf der
Bruecke (Status, Bericht, PR-Kommentar, Aufraeumen) ueberhaupt begannen. 40 min
machen ihn echt.

⛔ Seit ein Abbruch ohne Urteil zur `Stoerung` und damit zu ROT wird, faerbt
eine Frist unter dem Modellzug einen GESUNDEN Pruefzug rot: die Bruecke gibt
auf, waehrend der Pruefer noch arbeitet. Am 10.09.2026 gemessen — sieben PRs
trugen „Pruefer A ausgefallen", der Pruefer war gesund. Die Ordnung wird
GEPRUEFT, nicht wiederholt: `test_zeitkette_steht_aufsteigend` liest die Frist
aus der Bruecke und den Deckel aus der YAML-Datei, und
`test_die_gefahrene_frist_traegt_die_kette` MISST mit simulierter Uhr, welche
Frist `collect()` wirklich faehrt. `test_die_deckel_ausserhalb_der_frist_werden_gefahren`
misst, dass `SSH_DECKEL` und `NACHLAUF_HEALTH` an den Aufrufen ankommen und nicht
bloss im Kommentar stehen. Wer eine der Zahlen anfasst und die anderen stehen
laesst, wird rot — gegengeprueft mit vier Mutanten (`timeout-minutes` 35 und 30,
`review-start` ohne uebergebenen Deckel, `SSH_DECKEL` geschoent): jeder rot, der
gesunde Stand gruen.

### Zwei Lagen gegen den Selbst-Zurueckdreher

Die Bruecke setzt in JEDEM Ausgang **erst den Status, dann den PR-Kommentar**:
`gh pr comment` loest `issue_comment` aus, und daran haengt `gate-2-codex.yml`.
Stand der Kommentar vorn, sah dieser Lauf einen halben Zustand und schrieb
`pending` ueber die gerade gesetzte Ausweichung. Zweite Lage, unabhaengig davon,
wer den Lauf ausloest: `Post Status` in `gate-2-codex.yml` ersetzt ein an diesem
SHA schon stehendes `success`/`failure`/`error` nicht mehr durch `pending` —
je Context geprueft, denn der Schritt bedient zwei.

Beweise: `scripts/codex-ausweichung-selftest.sh` (36 Faelle; die
Entscheidungsfunktion, der ganze Ausweich-Schritt UND der Post-Status-Schritt
werden aus der Workflow-Datei gezogen, `gh` und die Statuses sind Attrappen)
und `tests/test_entwicklung_review_bridge.py` (95 Faelle, `gh`/`ssh` als
Attrappen). Die Faelle E1/E2 nageln fest, dass ein Box-Approve an einem
AELTEREN Commit den neuen HEAD nicht freigibt; E3/E4, dass die Frist am
App-geschriebenen `created_at` des Box-Status haengt und nicht an der vom
PR-Autor setzbaren Git-Committer-Zeit; F1-F3, dass Fremdtext aus der Box die
Verdikt-Marke nicht faelschen kann; H1-H6, dass `pending` kein fertiges Urteil
mehr abwertet (H2/H5/H6 als Gegenprobe, dass es trotzdem schreibt, wenn es
soll).

## Tier

Tier 4 (kein App-Server, nur Workflow-Templates). Test = `actionlint` + `shellcheck` auf Workflow-Files.

## Spec-Verweis

`team-workflow.md` §3.b.2 Server-side Gate (v5.10+), §16.X Workflow-Templates-Pinning.
