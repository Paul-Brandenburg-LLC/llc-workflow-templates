# llc-ops-backlog#87 — gate-2-codex haengt jeden Doc-only-PR auf `pending`

## Befund

`gate-2-codex` macht **jeden Doc-only-PR der Org strukturell unmergebar**. Der
Defekt steckt in **jeder** gepinnten Fassung (`v1` beweglich, `v1.1.2`, `v1.6.1`,
`v1.6.2`, `v1.7.1`, `v1.8.0`, `v1.8.1`, `main`); `v1.8.0` und `v1.8.1` sind fuer
diese Datei zeichengleich, ein hoeherer Pin hilft also nicht. **35 Repos**
betroffen. Das Issue steht seit dem 29.04.2026 offen.

### Die Kette

1. Der Step `scope` trug `if: github.event_name == 'pull_request'`.
2. Codex schreibt kurz nach dem Oeffnen seinen Summary-Kommentar. Die Bruecke
   laeuft darauf als `issue_comment` **erneut** — und `scope` lief dann nicht.
3. `steps.scope.outputs.skip` blieb **leer**. Leer ist nicht `'true'`, also
   passierten die beiden folgenden Steps ihren Waechter (`skip != 'true'`).
4. Die Bruecke fiel in den Codex-Urteilszweig und ueberschrieb ihr eigenes,
   korrektes `success` mit `pending`.
5. Gruen wurde es nie wieder: der Code rechnet mit einem folgenden
   `pull_request_review`-Ereignis, aber ein Review **ohne** Befund gibt es bei
   Codex nicht — nur eine 👍-Reaktion. Deadlock.

## Was der Fix tut

1. **`scope` laeuft ereignis-unabhaengig.** Die Ereignisauswahl deckt der
   Job-`if` bereits ab (issue_comment nur an PRs, nur vom Codex-Bot); der Step
   „Resolve PR HEAD" laeuft aus demselben Grund schon ereignis-unabhaengig.
2. **`eval_body()` liest die Status-Spalte der Summary-Tabelle**, nicht die
   Ueberschrift.
3. **Der Step zaehlt die OFFENEN Codex-Zeilenbefunde am HEAD** aus
   `/pulls/N/comments` und reicht sie als zweites Argument durch:
   leer (unbekannt) → `pending` · `>0` → `failure` · `0` **und** `**Completed**`
   in der HEAD-Zeile → `success`.
4. **Abruf und Auswertung sind getrennt**, mit Exitcode-Pruefung und zwei
   `::warning::`-Ausgaengen.

## Zwei naheliegende Reparaturen, die falsch sind

Die Vorpruefung hat beide gestoppt; beide waeren schlimmer gewesen als der
Fehler:

1. **Die Ueberschrift auf `^#+ Codex Review` weiten.** Der Summary-Kommentar
   traegt den Marker `<!-- codex-pull-request-review-summary -->` und existiert
   **bereits, waehrend der Review noch laeuft** — Codex editiert ihn nur. Eine
   Ueberschriften-Erkennung setzt das Tor schon bei `Running` auf `success` und
   gibt den Merge **vor** den Befunden frei.
2. **`**Completed**` als Freigabe lesen.** Das heisst nur „Lauf beendet", NICHT
   „keine Befunde". Belegt an `llc-ops-backlog#1147`: die Summary stand fuer
   `2293878` auf Completed, waehrend sechs Zeilenbefunde dranhingen.

Ebenfalls bewusst **nicht** verwendet: das 👍 des Connectors. Es ist zwar das
echte „ohne Befund"-Signal (gemessen: `nachrichtenmaschine-app#356` hat es,
`llc-ops-backlog#1147` nicht), aber auf Reaktionen feuert kein Ereignis — die
Bruecke liefe danach nicht erneut. Das haette den Deadlock nur gegen einen neuen
getauscht.

## Nachweis (§7)

- `scripts/gate-2-verdict-selftest.sh` — **NEU**, 29 Faelle, alle gruen.
  Zieht `eval_body()` **im Ganzen** aus der Workflow-Datei und fuehrt sie aus,
  statt sie abzuschreiben; deshalb kann er nicht gruen bleiben, wenn jemand die
  Datei zurueckdreht.
- **Gegen den alten Stand rot belegt: 18/29.**
  `git show <sha>:.github/workflows/gate-2-codex.yml > /tmp/alt.yml && GATE2_WORKFLOW=/tmp/alt.yml bash scripts/gate-2-verdict-selftest.sh`
- `scripts/gate-2-paginate-selftest.sh` — Waechter um die getrennte Abrufform
  **erweitert**, nicht geschwaecht. Gegenprobe gefahren: beide verbotenen
  Schreibweisen (Pipe auf einer Zeile, Pipe ueber Backslash-Fortsetzung)
  schlagen weiter an.
- Alle zehn `scripts/*-selftest.sh` liefern `rc=0`.

## Reihenfolge beim Ausrollen — der Teil, den man nur einmal falsch macht

⛔ **Der Tag `v1.9.0` MUSS vor dem Merge existieren.**

`propagate-templates.yml` laeuft `on: push` auf `main`, wenn
`.github/workflows/gate-2-codex.yml` oder `cold-start-ci.yml` sich aendert, und
ermittelt den Tag mit `git tag -l 'v*' | sort -V | tail -1`. Fehlt `v1.9.0` in
dem Moment, verteilt sie **`v1.8.1`** — also den kaputten Stand. Und die
Zweignamen tragen den Tag (`chore/pin-bump-gate-2-codex-<TAG>`): eine zweite
Welle ersetzt die falschen PRs nicht, sondern legt **35 weitere** daneben.

Ablauf: Tore gruen abwarten → Tag `v1.9.0` auf den PR-Kopf setzen → mergen →
Welle nachhalten. Notfalls nachfassen per `workflow_dispatch` (Eingaben `tag`,
`template`, `dry_run`).

## Rollback

`git revert` des Merge-Commits auf `main`, danach Tag `v1.9.1` auf den
Revert-Stand und die Verteilung erneut laufen lassen. Der Vorzustand ist der
Deadlock — ein Rollback stellt also den Fehler wieder her und ist nur bei einem
schwereren Folgeschaden sinnvoll.

## Kein Spec-Bump

Der Standard beschreibt das Soll-Verhalten der Bruecke bereits
(`team-workflow.md`, Zeile 469: „success bei Approved oder Comment ohne Findings
… Fehlt der passende HEAD-SHA, setzt der Bridge Status `pending`"). Der Fix
**stellt dieses Verhalten her**, er aendert es nicht — damit greift die
Spec-first-Pflicht fuer Gate-/Workflow-**Aenderungen** nicht.
