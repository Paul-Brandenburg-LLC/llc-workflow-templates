# Plan #43 — Gate-2 erkennt Codex 10-Hex-Commitzelle

## Ziel
Codex schreibt in der Summary-Zelle und in `**Reviewed commit:**` oft 10 Hex, nicht 7 und nicht 40. Gate-2 v1.9.0 prüft Gleichheit. Folge: pending trotz „no findings“ am HEAD (devops-dashboard-app#145, llc-paulbrandenburg-com-app#389).

## Blast-Radius
mittel — eine Workflow-Datei + zwei Offline-Selbsttests. Kein Deploy-Pfad, keine Migration.

## Schnitt
1. Commit-Zelle: Präfix von HEAD, Länge 7–40, zählt.
2. Kommentar-Fallback: maximale Hex-Läufe 7–40, nur wenn HEAD damit anfängt.
3. V26/K14 (Einbettung in fremden SHA) bleiben pending. V29 + K16 neu.

## Nicht
- Standard-Bump, Org-Roll v8
- Status fälschen

## Tests
`bash scripts/gate-2-verdict-selftest.sh` (49) und `gate-2-chain-selftest.sh` (20) lokal grün.

## Rollback
Revert; Consumer bleiben auf v1.9.0 bis Pin-Bump.
