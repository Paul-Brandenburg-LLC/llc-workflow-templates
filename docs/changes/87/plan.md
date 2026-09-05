# llc-ops-backlog#87 — gate-2-codex haengt jeden Doc-only-PR auf `pending`

## Befund

`gate-2-codex` macht **jeden Doc-only-PR der Org strukturell unmergebar**. Der
Defekt steckt in **jeder** gepinnten Fassung (`v1` beweglich, `v1.1.2`, `v1.6.1`,
`v1.6.2`, `v1.7.1`, `v1.8.0`, `v1.8.1`, `main`); `v1.8.0` und `v1.8.1` sind fuer
diese Datei zeichengleich, ein hoeherer Pin hilft also nicht. **33 Repos**
betroffen. Am 05.09.2026 ausgezaehlt (Abruf und Auswertung getrennt, sonst
verschluckt die Pipe den Abruffehler): **37 aktive Repos** = 32 mit exaktem Pin
(v1.6.1 … v1.8.1) + **1 mit einer eigenen alten Kopie** des kaputten Tors
(`stattzeitung-net-site`, keine Pin-Zeile) + 3 ganz ohne die Datei
(`claude-in-tmux-app`, `codex-in-tmux-app`, `grokbuild-app`; je 404 nachgeprueft)
+ `llc-workflow-templates` selbst, wo die Datei die Reusable IST und kein Caller.
Die Welle trifft damit **33**, nicht 32 — die eigene Kopie wird als Modus
`migrate` durch einen Thin-Caller ersetzt und ist ebenso betroffen. Die
urspruenglich gemeldete "35" war eine Schaetzung. Das Issue steht seit dem
29.04.2026 offen.

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

1. **`scope` laeuft ereignis-unabhaengig.** Doc-only ist eine Eigenschaft des
   DIFFS, nicht des Ausloesers. Die Ereignisauswahl deckt der Job-`if` ab
   (issue_comment nur an offenen PRs); der Step „Resolve PR HEAD" laeuft aus
   demselben Grund schon ereignis-unabhaengig.
2. **`eval_body()` liest die Status-Spalte der Summary-Tabelle**, nicht die
   Ueberschrift.
3. **Der Step zaehlt die OFFENEN Codex-Befund-Threads** und reicht sie als
   zweites Argument durch: leer (unbekannt) → `pending` · `>0` → `failure` ·
   `0` **und** `**Completed**` in der HEAD-Zeile → `success`.
   Gemessen wird der echte Thread-Zustand `isResolved` aus der GraphQL-
   Verbindung `pullRequest.reviewThreads` — **nicht** das Vorhandensein einer
   Antwort (siehe „Die dritte falsche Reparatur" unten).
4. **Abruf und Auswertung sind getrennt**, mit Exitcode-Pruefung und zwei
   `::warning::`-Ausgaengen.
5. **Der Kommentar-Zweig haengt nicht mehr als `elif` am Review-Zweig.**
6. **Der Job-`if` traegt einen Recheck-Eingang** (siehe „Die fuenfte falsche
   Reparatur").

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

## Die dritte falsche Reparatur (Vorpruefung P1, Runde 5)

**Eine Antwort ist kein Beleg fuer Erledigung.** Die erste Fassung von Punkt 3
las `/pulls/N/comments` und strich jeden Befund, auf den irgendein
`in_reply_to_id` zeigte — „beantwortet" galt als „erledigt". Ein
widersprechender Kommentar des PR-Autors („sehe ich anders") haette den
weiterhin offenen Befund damit aus der Zaehlung entfernt; stand die Summary auf
`**Completed**`, waere das Tor auf `success` gegangen. Wieder die gefaehrliche
Irrtumsrichtung: zu gruen.

Gemessen wird deshalb `isResolved` aus `pullRequest.reviewThreads` — derselbe
Zustand, den die Branch-Protection mit „All comments must be resolved" verlangt.
Ihn setzt nur, wer den Thread wirklich aufloest.

Damit entfaellt auch der HEAD-Filter: ein offener Thread blockiert, gleich an
welchem Commit er haengt. Das ist Absicht — die `commit_id` von
Review-Kommentaren wandert beim Push ohnehin auf den neuen HEAD mit.

Ebenfalls bewusst **nicht** verwendet: das 👍 des Connectors. Es ist zwar das
echte „ohne Befund"-Signal (gemessen: `nachrichtenmaschine-app#356` hat es,
`llc-ops-backlog#1147` nicht), aber auf Reaktionen feuert kein Ereignis — die
Bruecke liefe danach nicht erneut. Das haette den Deadlock nur gegen einen neuen
getauscht.

## Die fuenfte falsche Reparatur (Vorpruefung P1, Runde 9)

**Ein Statuszustand, aus dem kein Ereignis mehr herausfuehrt.** Das Tor zaehlt
offene Codex-Befund-Threads und steht bei Befunden auf `failure`. Das
**Aufloesen** eines Threads loest aber KEINEN Actions-Lauf aus: an der
Ereignis-Liste nachgeschlagen (05.09.2026) kennt Actions `pull_request`,
`pull_request_review`, `pull_request_review_comment` und
`pull_request_target` — `pull_request_review_thread` gibt es nur als **Webhook**.
Ein Befund an **unveraenderten** Zeilen (also nicht `isOutdated`) liesse das Tor
nach dem Aufloesen dauerhaft rot stehen: derselbe Deadlock von der anderen
Seite.

Der Ausweg ist **nicht**, die Zaehlung fallen zu lassen und auf die native
Conversation-Protection zu setzen. Nachgemessen ueber alle 32 Consumer-Repos:
`required_conversation_resolution` ist **3× `true`**, 22× nicht gesetzt, 7× keine
Branch-Protection lesbar. In 29 von 32 Repos waere das ein echtes Loch — und §4
verbietet, die Branch-Protection zu setzen.

Deshalb der ausdrueckliche Recheck-Eingang im Job-`if`: die Bruecke ist ein
reiner **Neuberechner**, sie liest den Zustand und schreibt einen Status. Wer
den Lauf ausloest, aendert am Ergebnis nichts; die Verengung auf den Codex-Bot
war eine Sparmassnahme und hat die Neuberechnung nach dem Aufloesen verhindert.
Jetzt genuegt **ein beliebiger PR-Kommentar** (oder ein Review, oder ein Push) —
alles Ereignisse, die die verteilten Caller ohnehin abonnieren. Der Failure-Text
nennt den Weg heraus. Der PR-Waechter (`issue.pull_request != null`,
`issue.state == 'open'`) bleibt: auf reinen Issues und an geschlossenen PRs hat
die Bruecke nichts zu suchen.

**Die Regel dahinter:** Wer einen Statuszustand entwirft, muss fuer JEDEN
Uebergang ein Ereignis benennen koennen, das die Konsumenten wirklich
abonnieren.

## Die sechste und siebte falsche Reparatur (Vorpruefung P1, Runde 11)

Beide zeigen wieder in dieselbe Richtung — **zu gruen** — und beide sassen in
Zweigen, die die vorigen Runden nicht erreicht hatten:

**6. Der Thread-Riegel hing nur im Summary-Zweig.** `eval_body()` prueft die
Zahl offener Codex-Befund-Threads; diese Pruefung stand aber INNERHALB des
Summary-Marker-Zweigs. Ein Body in einer der Legacy-Formen (`### Codex Review`,
`### 💡 Codex Review`, `Codex Review: …`) lief daran vorbei und lieferte
`success`, obwohl offene Zeilenbefunde am HEAD hingen — genau der Fehler aus
Runde 3, eine Verzweigung tiefer. Der Riegel steht jetzt **vor jedem
erfolgliefernden Zweig**: unbekannte Zahl → `pending`, Zahl > 0 → `failure`,
und erst danach wird ueberhaupt ein Body-Format gelesen.

**7. Ein abgeschlossenes Security Review oeffnete das Tor.** Die Summary-Tabelle
traegt **je Review-ART eine eigene Zeile**. Die Pruefung lautete „irgendeine
Zeile mit dem aktuellen SHA traegt `**Completed**`" — ein fertiges Security
Review gab damit frei, waehrend das Code Review am selben Commit noch `Running`
stand. Verlangt werden jetzt alle drei Merkmale auf **derselben** Zeile: der
HEAD-SHA, `**Code Review**` und `**Completed**`. Fehlt eines, bleibt es
`pending`.

**Die Regel dahinter:** Ein Riegel, der in EINEM Zweig sitzt, ist kein Riegel —
er gehoert vor die Verzweigung. Und eine Tabelle mit mehreren Zeilen misst man
zeilenweise, nie ueber das ganze Dokument.

## Die achte falsche Reparatur (Vorpruefung P1, Runde 12)

**`APPROVED` umging den Thread-Riegel.** Der Riegel sass in `eval_body()`, aber
ein formales `APPROVED`-Review setzt `STATE=success` **direkt** — es liest gar
keinen Body. Ein Approval gab damit gruen, obwohl Codex-Befunde offen waren
oder die Zahl nicht abrufbar war.

Damit war es dreimal dieselbe Klasse an drei verschiedenen Stellen (Runde 3 im
Summary-Zweig, Runde 11 im Legacy-Zweig, Runde 12 an `APPROVED`). Beim dritten
Mal wird die Regel nicht ein viertes Mal nachgebaut, sondern **uebernommen**:
der Riegel steht jetzt genau **einmal**, oberhalb der gesamten Urteilskette —
unbekannte Zahl → `pending`, Zahl > 0 → `failure`, und nur bei bekannt-null
laeuft die Kette ueberhaupt. `eval_body()` beurteilt seitdem ausschliesslich
den Body und hat kein zweites Argument mehr.

Dazu ein **Struktur-Waechter** statt mehr Sorgfalt (S6/S7 in
`gate-2-verdict-selftest.sh`): im Kettenblock darf kein `STATE=success` vor dem
`CODEX_OFFEN`-Riegel stehen — mit Gegenprobe an der alten Anordnung, damit die
Messung nicht ins Leere greift.

**Die Regel dahinter:** Rutscht dieselbe Luecke dreimal durch, ist nicht die
Sorgfalt zu klein, sondern die Stelle falsch. Ein geteilter Zustand wandert
eine Ebene hoeher — und dorthin gehoert dann ein Waechter, kein Kommentar.

## Nachweis (§7)

- `scripts/gate-2-verdict-selftest.sh` — **NEU**, 37 Faelle, alle gruen.
  Zieht `eval_body()` **im Ganzen** aus der Workflow-Datei und fuehrt sie aus,
  statt sie abzuschreiben; deshalb kann er nicht gruen bleiben, wenn jemand die
  Datei zurueckdreht. Enthaelt fuenf Struktur-Proben, die nicht das Verhalten,
  sondern die YAML-Bedingungen selbst messen: S1/S2 am Step `scope`
  (ereignis-unabhaengig, `bot_exempt`-Waechter bleibt) und S3-S5 am `if` des
  JOBS `bridge` (Recheck-Eingang da, Praedikat schlaegt auf der alten Fassung
  an, PR-Waechter `issue.pull_request != null` + `issue.state == 'open'`
  bleibt). Alle ziehen die Bedingung per `awk` aus der Datei und lassen
  **Kommentarzeilen aus** — ueber dem `if` steht die Begruendung, und die
  zitiert die alte Fassung woertlich; ein `grep` ueber die Rohdatei traefe sie.
- **Gegen den alten Stand rot belegt: 20/37** (17 Fehlschlaege gegen
  `origin/main`). Jede Erweiterung ist zusaetzlich gegen ihren DIREKTEN
  Vorgaenger rotgestellt, damit der Beleg nicht in der Masse untergeht: gegen
  `712ec11` genau die zwei neuen S3 und S5, gegen `dcf6169` genau die vier
  neuen Faelle V14-V16 (die Gegenprobe „beide Review-Arten fertig" bleibt dort
  gruen — sie misst, dass die Fixture nicht generell kaputt ist).
  `git show <sha>:.github/workflows/gate-2-codex.yml > /tmp/alt.yml && GATE2_WORKFLOW=/tmp/alt.yml bash scripts/gate-2-verdict-selftest.sh`
- `scripts/gate-2-threads-selftest.sh` — **NEU**, 20 Faelle, alle gruen. Zieht
  den Zaehl-Ausdruck ebenfalls **im Ganzen** aus der Workflow-Datei. Enthaelt
  die Verhaltensprobe des Runde-5-Befunds: derselbe widersprochene, offene
  Befund zaehlt unter der alten Fassung **0**, unter der neuen **1**. Gegen den
  alten Stand rot belegt.
- `scripts/gate-2-paginate-selftest.sh` — Waechter zweimal **erweitert**, nie
  geschwaecht: um die getrennte Abrufform (Teil B) und um GraphQL-Verbindungen
  (Teil B2, `--paginate` + `$endCursor` + `pageInfo` + `jq -s`). Gegenproben
  gefahren und im Test verankert: die beiden verbotenen Pipe-Schreibweisen und
  drei bewusst falsche GraphQL-Fassungen schlagen weiter an.
- `scripts/gate-2-chain-selftest.sh` — **NEU**, 13 Proben (die neun Faelle der
  Kette plus zwei Struktur- und zwei Gegenproben), alle gruen. Zieht den
  KETTENBLOCK im Ganzen aus der Workflow-Datei (von `STATE=pending` bis vor die
  Zeile, die `state=` nach `GITHUB_OUTPUT` schreibt) und misst den erreichten
  `STATE`. Noetig, weil der Runde-6-Befund nicht in `eval_body()` lag, sondern in
  der Verzweigung darum herum — eine isolierte Funktionsprobe kann ihn
  strukturell nicht sehen.
  **Gegen den alten Stand rot belegt:** gegen `2ddd736` (vor dem elif-Fix)
  2 Fehlschlaege (K1, K6), gegen `origin/main` 4 (K1, K5, K6, K8).
  Die alte Kettenform steht als Literal im Test und belegt, dass die Fixture von
  K1 den fehlerhaften Pfad wirklich erreicht (`pending`) — mit Gegenprobe, dass
  sie nicht generell kaputt ist (`APPROVED` ergibt auch dort `success`).
- Alle **zwoelf** `scripts/*-selftest.sh` liefern `rc=0`. `ci.yml` zaehlt das
  Verzeichnis aus (`for t in scripts/*-selftest.sh`) — der neue Test haengt ohne
  Nachtrag in der Pflicht-CI.

## Reihenfolge beim Ausrollen — der Teil, den man nur einmal falsch macht

⛔ **Der Tag `v1.9.0` MUSS vor dem Merge existieren.**

`propagate-templates.yml` laeuft `on: push` auf `main`, wenn
`.github/workflows/gate-2-codex.yml` oder `cold-start-ci.yml` sich aendert, und
ermittelt den Tag mit `git tag -l 'v*' | sort -V | tail -1`. Fehlt `v1.9.0` in
dem Moment, verteilt sie **`v1.8.1`** — also den kaputten Stand. Und die
Zweignamen tragen den Tag (`chore/pin-bump-gate-2-codex-<TAG>`): eine zweite
Welle ersetzt die falschen PRs nicht, sondern legt **33 weitere** daneben.

⚠ `stattzeitung-net-site` laeuft im Modus `migrate`, sein Zweig heisst deshalb
`chore/auto-sync-gate-2-codex-v1.9.0` und faellt NICHT unter die Bot-Ausnahme
(die verlangt woertlich `^chore/pin-bump-…-vX.Y.Z$`). Er braucht einen echten
Codex-Durchlauf und ist der wahrscheinlichste Straggler.

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

## Erledigt (war offen: Verhaltenstest der Verdict-KETTE)

Gebaut als `scripts/gate-2-chain-selftest.sh`, 05.09.2026. Alle neun geplanten
Faelle sind drin und gruen:

| Fall | Eingang | erwartet |
|---|---|---|
| K1 | `COMMENTED` ohne Body + Summary `Completed` + 0 offene | `success` (**der Befund**; vorher `pending`) |
| K2 | `APPROVED` | `success` |
| K3 | `CHANGES_REQUESTED` | `failure` |
| K4 | `COMMENTED` mit Findings-Body | `failure` |
| K5 | kein Review + Summary `Completed` | `success` |
| K6 | `COMMENTED` ohne Body + 2 offene Threads | `failure` |
| K7 | Summary `Running` | `pending` |
| K8 | Review an fremdem SHA + Summary am HEAD | `success` |
| K9 | offene Befunde unbekannt (leer) | `pending` |

Damit ist die Nacharbeit aus Runde 6 abgeschlossen; es steht nichts mehr offen.
