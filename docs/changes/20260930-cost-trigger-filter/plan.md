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

## Review-Ausführung absichern

Der bestehende review.yml-Lauf nutzte von der gepinnten Action nicht
unterstützte Eingaben und wurde ohne Review grün. Auf die im Trading-Repo
bereits funktionierenden OAuth-/Prompt-Eingaben umgestellt; ein fehlender
Ausführungsnachweis lässt den Job jetzt scheitern. Der Modelltyp bleibt gleich.

## Günstigerer Rechner für die Statusberechnung

Der unveränderte Gate-2-Code benötigt nur Bash, GitHub CLI, jq und Coreutils.
Diese sind laut offizieller Image-Liste auf `ubuntu-slim` vorhanden. Der
Job behält seine Fünf-Minuten-Grenze (Slim erlaubt maximal 15 Minuten).
GitHub nennt 0,002 USD/Minute statt 0,006 USD/Minute für den bisherigen
Linux-Rechner. Vor Release muss der echte Gate-2-Lauf auf Slim bestehen.

Quellen: https://docs.github.com/de/billing/reference/actions-runner-pricing
und https://github.com/actions/runner-images/blob/main/images/ubuntu-slim/ubuntu-slim-Readme.md
