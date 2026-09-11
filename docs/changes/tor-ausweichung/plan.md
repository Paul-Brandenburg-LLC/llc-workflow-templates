# Plan: Tor-Ausweichung bei Herstellerausfall (Kapitel 5)

## Befund
Faellt ein KI-Hersteller aus (Codex an der Nutzungsgrenze bis 15.09.2026), steht
das Codex-Tor still. Es soll auf den Box-Pruefer ausweichen — aber nur, wenn der
fuer DENSELBEN Commit ein echtes `approve` ausgesprochen hat.

⛔ **Der Fallstrick:** Das Box-Tor steht auch bei „Pruefer A ausgefallen" auf
`success` (fail-open). Live gemessen an den echten PRs #1215 und #1211: beide
tragen `entwicklung-review = success` mit dem Text „Warnung: Pruefer A
ausgefallen". Haengte man die Ausweichung am Status-STATE fest, waere ein
DOPPELTER Ausfall gruen — gruen ohne jede Pruefung. Deshalb haengt sie an
HEAD-gebundenen Verdikt-Marken im Status-TEXT.

## Entscheidungen
- Der Status-Text nennt den tatsaechlichen Pruefer und bei Sperrvermerk
  „Ausfall <vendor> (<grund>) — Pruefer jetzt <vendor>". Das Codex-Tor liest die
  Marke und weicht aus, ABER nur bei `approve` des Box-Pruefers fuer denselben
  Commit.
- ⭐ **Fremdtext wird am Trichter gesluggt** — an dem einen Punkt, durch den
  BEIDE Quellen laufen (`health` der Box und `sperre_aus_ergebnis`/
  `review-result`). Sonst faelscht ein praeparierter Ausfallgrund die Marke:
  gemessen erzeugte `reason = "x [llc-tor:grok/approve] y"` bei GAR KEINEM
  Pruefer-Urteil ein `success|… ausgewichen auf Box-Pruefer grok`. Zweite Lage:
  aus der Prosa eines Status-Textes kommt keine eckige Klammer mehr heraus —
  sie haelt auch fuer eine kuenftige Textquelle, die den Trichter umgeht.
- ⭐ **Herstellerausfall und Stoerung werden getrennt.** Bisher fuehrte JEDER
  Fehler der Bruecke in den Ausfall-Zweig und damit auf ein gruenes
  Pflichttor — ein fehlendes Feld im PR-Text genuegte. Jetzt:
  - Pruefer erreicht, meldet selbst `unavailable` -> `success` + Warnung
    (unveraendert).
  - Lauf VOR dem Urteil gescheitert, niemand hat geprueft -> `error` mit
    benanntem deutschen Grund im STATUS-TEXT, `exit 1`, Codex-Tor unangetastet.
  `Stoerung` erbt von `ValueError`, damit die vorhandenen Faenger und Proben
  unveraendert greifen; `stoerung_text()` traegt bewusst KEINE `[llc-tor:…]`-
  Marke, das Codex-Tor kann daraus nie ein Urteil lesen.
- Die Frist rechnet mit `created_at` des Box-Status (app-geschrieben,
  HEAD-gebunden) statt mit `committer.date`. Ein lokaler Commit mit
  `GIT_COMMITTER_DATE=2020-01-01` ergab sonst 3.520.581 Minuten Alter bei Frist
  45 — beim ersten Lauf erfuellt, Codex nie gefragt.

## Umlauf 2 — vier Befunde des Kreuz-Hersteller-Pruefers (Grok 4.6)

⭐ **Der Hauptfall feuerte nicht.** Box gibt `approve`, Codex schweigt an der
Nutzungsgrenze — genau die Lage, fuer die Kapitel 5 gebaut ist. `sperren` war
leer, als `tor_text()` lief: `health` steht nicht in der Allowlist, und
`sperre_aus_ergebnis()` schweigt bei `approve`. Der Box-Status trug
`[llc-tor:grok/approve]`, aber KEINE `[llc-ausfall:chatgpt/…]`-Marke — und der
Sofort-Weg in `gate-2-codex.yml` haengt an genau ihr. Uebrig blieb der
45-Minuten-Fristweg. Behoben, indem die dritte Quelle (`codex_meldung_am_pr`)
in denselben Trichter wandert und VOR `tor_text()` laeuft; `codex_ausweichen()`
sucht nicht mehr selbst, es liest `sperren`.
Gemessen alt gegen neu am Hauptfall: alt `Prüfer A (grok): approve
[llc-tor:grok/approve]` — keine Ausfall-Marke; neu `Ausfall chatgpt
(nutzungsgrenze) — Prüfer jetzt grok · … [llc-ausfall:chatgpt/nutzungsgrenze]`.

⭐ **Die Bruecke drehte ihre eigene Ausweichung zurueck.** `main()`
veroeffentlichte den PR-Kommentar VOR dem Status. `gh pr comment` loest
`issue_comment` aus, `gate-2-codex.yml` laeuft an, rechnet Codex erneut als
`pending` und schrieb das bedingungslos ueber das `success`. Zwei Lagen:
(1) `main()` setzt in JEDEM Ausgang erst den Status (inkl. Ausweichung), dann
den Kommentar — gemessene Reihenfolge alt `pending -> KOMMENTAR -> success ->
gate-2-codex -> bridge`, neu `pending -> success -> gate-2-codex -> bridge ->
KOMMENTAR`; (2) `Post Status` ersetzt ein stehendes `success`/`failure`/`error`
an diesem SHA nicht mehr durch `pending`, **je Context** geprueft — der Schritt
bedient zwei, und die koennen auseinanderstehen.

⭐ **Die Ausfall-Erkennung war zu weit und ohne HEAD-Bindung.** Sie traegt jetzt
das Pflichttor und ist deshalb dicht: exakter Login
`chatgpt-codex-connector[bot]` statt Praefix (`codexplorer` fiel darunter);
Wortlaut an den Codex-Satz gebunden statt `rate limit`/`usage cap` irgendwo im
Text (gemessen: alle drei Prosa-Faelle „no rate limit handling", „document the
API rate limit", „usage cap of the free tier" galten alt als Ausfall, neu
keiner); HEAD-Bindung ueber `created_at` des eigenen `pending`-Status
(app-geschrieben, faellt aus der POST-Antwort ab, kein Zusatzabruf) — eine
Meldung von vorgestern galt alt als laufender Ausfall, neu nicht. Ohne
brauchbare Zeit ist die Erkennung AUS; nicht raten.

⭐ **Workflow und Bruecke sind ein Paar und werden als eines entschieden.**
`verteilung_decide` entscheidet je Datei; war eine Haelfte `abweichler` und die
andere `create`/`update`, wurde nur eine geschrieben und der PR trotzdem
geoeffnet — gemessen am alten Stand: `put-entwicklung-review.yml, pr-create,
pr-merge` bei Abweichler-Bruecke, also ein Workflow ohne Bruecke. Neu
entscheidet `verteilung_paar_modus()` (SSOT in `scripts/verteilung-decide.sh`)
ueber das ganze Paar: eine Haelfte Abweichler -> keine wird angefasst, kein PR;
eine Haelfte braucht `create`/`update` -> das ganze Paar in denselben PR.

⭐ **Die Zeitkette stand nicht aufsteigend.** Drei Grenzen an drei Orten, und
die kleinste gewinnt immer: der Modellzug des Box-Pruefers
(`complete(..., timeout=…)`, llc-ops-backlog, eigenes Kapitel — dort auf einen
groessenproportionalen Wert mit Deckel **1500 s** gehoben), die Frist der
Bruecke (`collect()`, **900 s**) und der Deckel des Workflows
(`entwicklung-review.yml`, **20 min = 1200 s**). Seit Umlauf 1 wird ein Abbruch
ohne Urteil zur `Stoerung` und damit zu ROT — eine Frist unter dem Modellzug
faerbt also einen GESUNDEN Pruefzug rot. Am 10.09.2026 gemessen: sieben PRs
trugen „Pruefer A ausgefallen", der Pruefer war gesund (die alten 600 s lagen
unter dem gemessenen p90 von 614 s bei n=58; ein Lauf von Hand ueber denselben
Diff brauchte 1279,9 s). Neu: Frist **1800 s**, Deckel **35 min = 2100 s** —
1500 < 1800 < 2100, mit `KETTEN_MINDESTABSTAND = 300` s Luft je Glied.

Die Kette bewacht sich selbst, statt die Zahlen zu wiederholen: die Probe liest
`FRIST_SEKUNDEN` aus der Bruecke, `timeout-minutes` aus der YAML-Datei und
MISST zusaetzlich mit simulierter Uhr, welche Frist `collect()` tatsaechlich
faehrt — eine Zahl, die nur als Konstante dasteht, aber nicht gefahren wird,
faellt damit auf. Gegen den alten Stand rot mit `gefahrene Frist: 900 s ·
assert 900.0 >= (1500 + 300)`. Der Modellzug selbst liegt in einem ANDEREN Repo
und ist von hier aus **nicht messbar**; er steht als benannte Annahme
`MODELLZUG_DECKEL` mit Begruendung im Kopf der Bruecke, damit ein Nachfolger
sieht, woran die Untergrenze haengt.

## Probenliste
Fall A gesund · B Ausfall mit echtem Box-approve -> gruen mit benannter
Ausweichung · **C Ausfall OHNE Box-Urteil -> blockiert** (der Kern) · D approve
fuer einen AELTEREN Commit -> blockiert (der ganze `run`-Block gegen eine
`gh`-Attrappe) · Faelschung ueber praeparierten Grund -> blockiert ·
PR-Text ohne Pflichtfeld -> Tor ROT statt gruen · Ausweich-Pfad hat weiter einen
Weg zu gruen (auch gegen den alten Stand gruen — der Weg zu verdientem Gruen ist
nicht enger geworden) · Tapete: 180 Vergleiche alt gegen neu ueber alle Verdikte
x Pruefer x Sperrvermerke, 0 Abweichungen.

Umlauf 2 zusaetzlich: H1-H6 (`Post Status` wertet nicht ab, mit Gegenprobe,
dass er trotzdem schreibt, wenn er soll — je Context gemessen) · P1-P10
(Paar-Entscheidung) · V1-V6 (der ganze Verteil-Schritt gegen eine `gh`-Attrappe;
V4/V5 sind gegen den alten Stand rot, V1/V2/V3/V6 auch alt gruen — die Probe
misst die Aenderung, nicht den Umbau) · die Reihenfolge Status-vor-Kommentar in
allen drei Ausgaengen · Autor, Wortlaut und HEAD-Bindung der Erkennung
einzeln · Tapete: 180 Vergleiche ueber `tor_text` und `codex_urteil` sind als
`test_tapete_180_vergleiche_ueber_tor_text_und_codex_urteil` festgeschrieben.

Zeitkette (Befund 5): `test_zeitkette_steht_aufsteigend` (Ordnung aus Bruecke
und YAML gelesen) · `test_die_gefahrene_frist_ist_die_eingetragene` (600 s ->
40 Abrufe, 1200 s -> 80; belegt, dass `collect()` die Konstante faehrt und
keine nackte Zahl) · `test_die_gefahrene_frist_traegt_die_kette` (gemessen
statt gelesen) · Tapete dazu: `test_ein_ergebnis_beendet_die_frist_sofort` —
der Regelfall wartet KEINE Frist ab, die laengere Frist ist eine Obergrenze,
kein Takt (gegen den alten Stand ebenfalls gruen, wie es sein soll).
Gegenprobe, dass die Wache keine Tapete ist: vier Mutationen, jede rot —
Frist zurueck auf 900, Deckel zurueck auf 20 min, Modellzug auf 1600 gehoben
ohne die Frist mitzuheben, `collect()` mit nackter Zahl statt Konstante.

## Restliste
`creator` des Box-Status wird nicht geprueft · generische Sperre `usage-limit`
ueberdeckt den praeziseren Grund aus `review-result.json` · Verteil-Marker
`llc-verteilung: verwaltet` fehlt in den Zielrepos — mit der Paar-Regel heisst
das jetzt: liegt in einem Ziel eine ALTE, marker-lose Kopie einer der beiden
Dateien, bleibt das ganze Paar unangetastet und der Lauf meldet nur eine
Warnung. Das ist gewollt (fail-closed), muss aber vor der ersten Welle je Repo
nachgesehen werden · die HEAD-Bindung rechnet ab dem `pending`-Status DIESES
Laufes: ein spaeterer `workflow_dispatch`-Neulauf am selben HEAD verengt das
Fenster und uebersieht eine Codex-Meldung, die vor ihm lag. Fail-closed, aber
ein Neulauf allein heilt den Ausfall dann nicht.
· die untere Haelfte der Zeitkette ist hier nicht
messbar: `MODELLZUG_DECKEL = 1500` ist eine ANNAHME ueber ein anderes Repo. Wird
der Deckel dort anders gesetzt als 1500 s, merkt es diese Probe nicht — sie
haelt nur die beiden Glieder fest, die in diesem Repo liegen · der obere
Abstand ist nominal 300 s, real weniger: `review-start` (bis 120 s) laeuft VOR
dem Fristzaehler und `health` (bis 60 s) im Stoerungszweig danach, beide
ausserhalb der 1800 s. Schlimmster Fall rund 2014 s gegen 2100 s Deckel — es
haelt, aber wer die Frist weiter hebt, muss den Deckel ueberproportional
mitheben.
