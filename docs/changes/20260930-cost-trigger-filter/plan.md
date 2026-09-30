# Gate-2-Rechner nur für relevante Ereignisse starten

Automatische Fortschrittsmeldungen anderer Bots verändern weder das
Codex-Urteil noch offene Befund-Threads. Sie starten künftig keinen
Gate-2-Rechner. Weiterhin akzeptiert: alle PR-/Review-Ereignisse, sämtliche
Codex-Kommentare und alle menschlichen Kommentare an offenen PRs.
Automatisierte Resolver können ausdrücklich `/gate-2 recheck` kommentieren.
Die Neuberechnung liest weiterhin unverändert Urteil, HEAD und offene
Threads; keine Freigaberegel wird gelockert.

## Nachweis

Alle bestehenden Verdict-/HEAD-/Thread-Selbsttests plus Auswertung des echten
Job-Ausdrucks mit menschlichem Recheck, Codex-Summary, fremden Bot-Meldungen,
explizitem Bot-Recheck, geschlossenem PR und reinem Issue. CI und Reviews.

## Auslieferung

Nach Merge neuen unveränderlichen Patch-Tag v1.9.2 am geprüften Commit
setzen. Bestehenden `propagate-templates.yml`-Weg gezielt für gate-2-codex.yml
mit diesem Tag ausführen, Consumer-Ergebnisse vollständig prüfen.

## Rollback / Smoke

Consumer auf bisherige Pins zurücksetzen; kein Tag wird umgeschrieben.
Probe: fremde Bot-Fortschrittsmeldung startet keinen Runner, menschlicher
und expliziter Bot-Recheck bleiben möglich. Keine Änderungen an Deploy-
oder Produktivdiensten.
