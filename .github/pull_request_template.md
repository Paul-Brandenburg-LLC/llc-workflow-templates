<!-- llc-verteilung: verwaltet — Quelle: standards/distribution/pull_request_template.md -->
## Summary
<!-- Was ändert sich, warum? -->

## Blast-Radius

<!-- Genau einen ankreuzen -->

- [ ] klein (Doc/Config-Tweak, Single-File, kein Code-Path)
- [ ] mittel (Feature/Refactor mit Tests)
- [ ] groß (Struktur, Deploy-Pfad, Datenmigration)

## Test-Plan

- [ ] CI grün

<!--
Ab hier nur bei `mittel` oder `groß` ausfüllen (§6.b). Bei `klein` verlangt
§6.a kein Ritual — die Abschnitte dürfen dann leer bleiben oder entfallen.
-->

## Plan-Link

<!--
Pflicht bei `mittel` / `groß`: Pfad `docs/changes/<issue>/plan.md`, eine URL —
oder im Regelfall-`mittel` unterhalb der Nicht-trivial-Schwelle (Anhang K:
> 100 Zeilen netto ODER > 5 Dateien ODER Kontrakt-/Geld-Pfad-Änderung)
wörtlich: PR-Body (Regelfall §6.b v7.5.0)
-->

## Rollback-Plan

<!-- Pflicht bei `mittel` / `groß`: Wie kommt der Stand zurück, wenn es bricht? -->

## Smoke-Test-Pfad

<!-- Pflicht bei `mittel` / `groß`: Welche URL/welcher Aufruf belegt nach dem Deploy, dass es läuft? -->

## CEO-Freigabe

<!-- Pflicht bei `groß` (§6 Kurzfassung): Link auf die schriftliche Freigabe. -->
