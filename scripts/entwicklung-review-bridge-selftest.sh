#!/usr/bin/env bash
# CI-Einstieg fuer die Bruecken-Proben des Box-Tors.
#
# ci.yml laeuft ueber scripts/*-selftest.sh — eine pytest-Datei allein wuerde
# dort nie starten. Dieser Wrapper uebersetzt das eine ins andere: er prueft
# distribution/*.py syntaktisch und fuehrt dann tests/ mit pytest aus.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
FEHLER=0

echo "=== py_compile distribution/ ==="
for f in distribution/*.py; do
  [ -f "$f" ] || continue
  if python3 -m py_compile "$f"; then
    echo "ok   $f"
  else
    echo "FAIL $f"; FEHLER=$((FEHLER + 1))
  fi
done

echo "=== YAML distribution/ ==="
for f in distribution/*.yml; do
  [ -f "$f" ] || continue
  if python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$f"; then
    echo "ok   $f"
  else
    echo "FAIL $f"; FEHLER=$((FEHLER + 1))
  fi
done

# ⛔ Der Verteil-Marker ist kein Schmuck: propagate-templates.yml sucht ihn im
# ZIEL, um „verwaltet" von „bewusst uebernommen" zu unterscheiden. Fehlt er in
# der QUELLE, traegt ihn die erste Verteilung nie in die Consumer — und die
# zweite Welle wuerde jede Datei als Abweichler ausweisen.
echo "=== Verteil-Marker in den Quellen ==="
for f in distribution/entwicklung-review.yml distribution/entwicklung_review_bridge.py; do
  if grep -qF 'llc-verteilung: verwaltet' "$f"; then
    echo "ok   $f traegt den Marker"
  else
    echo "FAIL $f ohne Marker 'llc-verteilung: verwaltet'"; FEHLER=$((FEHLER + 1))
  fi
done

echo "=== pytest tests/ ==="
if ! python3 -c "import pytest" 2>/dev/null; then
  echo "pytest fehlt — Nachinstallation"
  python3 -m pip install --disable-pip-version-check --quiet pytest || {
    echo "FAIL pytest nicht verfuegbar und nicht installierbar — Proben liefen NICHT"
    exit 1
  }
fi
if python3 -m pytest tests/ -q; then
  echo "ok   pytest"
else
  echo "FAIL pytest"; FEHLER=$((FEHLER + 1))
fi

echo "---"
if [ "$FEHLER" -eq 0 ]; then
  echo "entwicklung-review-bridge: gruen"
  exit 0
fi
echo "entwicklung-review-bridge: $FEHLER Probe(n) rot"
exit 1
