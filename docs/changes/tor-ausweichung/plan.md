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

## Probenliste
Fall A gesund · B Ausfall mit echtem Box-approve -> gruen mit benannter
Ausweichung · **C Ausfall OHNE Box-Urteil -> blockiert** (der Kern) · D approve
fuer einen AELTEREN Commit -> blockiert (der ganze `run`-Block gegen eine
`gh`-Attrappe) · Faelschung ueber praeparierten Grund -> blockiert ·
PR-Text ohne Pflichtfeld -> Tor ROT statt gruen · Ausweich-Pfad hat weiter einen
Weg zu gruen (auch gegen den alten Stand gruen — der Weg zu verdientem Gruen ist
nicht enger geworden) · Tapete: 180 Vergleiche alt gegen neu ueber alle Verdikte
x Pruefer x Sperrvermerke, 0 Abweichungen.

## Restliste
`creator` des Box-Status wird nicht geprueft · `codex_meldung_am_pr()` schlaegt
im Regelfall an (Wortlaut ungebunden) · generische Sperre `usage-limit`
ueberdeckt den praeziseren Grund aus `review-result.json` · Verteil-Marker
`llc-verteilung: verwaltet` fehlt in den Zielrepos.
