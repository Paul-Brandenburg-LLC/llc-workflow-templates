#!/usr/bin/env bash
# Offline-Beweis fuer scripts/verteilung-decide.sh (Standard 8.1, Kapitel 5/6).
# Kein GitHub, kein Netzwerk. exit != 0 bei jeder gescheiterten Behauptung.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
# shellcheck source=scripts/verteilung-decide.sh
source scripts/verteilung-decide.sh

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FEHLER=0

pruefe() { # name erwartet-mode ist-mode
  if [ "$2" = "$3" ]; then
    printf 'ok   %s\n' "$1"
  else
    printf 'FAIL %s\n     erwartet: %s\n     ist:      %s\n' "$1" "$2" "$3"
    FEHLER=$((FEHLER + 1))
  fi
}

QUELLE="$TMP/quelle.yml"
printf 'name: X\n# llc-verteilung: verwaltet — Quelle: llc-workflow-templates/distribution/x.yml\nfoo: 1\n' > "$QUELLE"

echo "=== verteilung-decide ==="

verteilung_decide "$QUELLE" ""
pruefe "Ziel fehlt -> create" create "$VERTEILUNG_MODE"

verteilung_decide "$QUELLE" "$TMP/gibtsnicht.yml"
pruefe "Zielpfad zeigt ins Leere -> create" create "$VERTEILUNG_MODE"

cp "$QUELLE" "$TMP/gleich.yml"
verteilung_decide "$QUELLE" "$TMP/gleich.yml"
pruefe "identisch -> skip" skip "$VERTEILUNG_MODE"

printf 'name: X\n# llc-verteilung: verwaltet — Quelle: llc-workflow-templates/distribution/x.yml\nfoo: 2\n' > "$TMP/alt.yml"
verteilung_decide "$QUELLE" "$TMP/alt.yml"
pruefe "verwaltet + abweichend -> update" update "$VERTEILUNG_MODE"

# ⛔ Der wichtigste Fall: ein Repo hat die Datei bewusst uebernommen und den
# Marker entfernt. Ein Ueberschreiben waere ein stiller Eingriff in fremden
# Code — es gibt nur den Ausweis.
printf 'name: X\nfoo: 2\n' > "$TMP/eigen.yml"
verteilung_decide "$QUELLE" "$TMP/eigen.yml"
pruefe "abweichend ohne Marker -> abweichler" abweichler "$VERTEILUNG_MODE"

verteilung_decide "" "$TMP/alt.yml"
pruefe "Quelle fehlt -> abweichler, nie create" abweichler "$VERTEILUNG_MODE"

# Marker irgendwo in der Datei, nicht nur in Zeile 2 (Python-Docstring!)
printf '"""Doku\n\nllc-verteilung: verwaltet — Quelle: x\n"""\nprint(2)\n' > "$TMP/skript.py"
verteilung_decide "$QUELLE" "$TMP/skript.py"
pruefe "Marker im Docstring zaehlt -> update" update "$VERTEILUNG_MODE"

# Ein Grund steht immer dabei — der Lauf soll im Protokoll erklaerbar sein.
verteilung_decide "$QUELLE" "$TMP/eigen.yml"
if [ -n "$VERTEILUNG_REASON" ]; then
  printf 'ok   jede Entscheidung traegt einen Grund\n'
else
  printf 'FAIL VERTEILUNG_REASON leer\n'; FEHLER=$((FEHLER + 1))
fi

echo "---"
if [ "$FEHLER" -eq 0 ]; then
  echo "verteilung-decide: alle Faelle gruen"
  exit 0
fi
echo "verteilung-decide: $FEHLER Fall/Faelle rot"
exit 1
