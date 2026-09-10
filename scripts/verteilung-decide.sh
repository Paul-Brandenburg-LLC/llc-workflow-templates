#!/usr/bin/env bash
# SSOT der Verteil-Entscheidung fuer ganze Dateien aus distribution/.
#
# Anders als scripts/pin-bump-decide.sh (der einen `uses:`-Pin umschreibt)
# verteilt dieser Weg eine KOMPLETTE Datei — noetig fuer Paare aus Workflow
# und Skript, die kein Reusable-Workflow tragen kann: das Box-Tor laedt
# `.github/scripts/entwicklung_review_bridge.py` aus dem Arbeitsbaum des
# Consumers, ein `uses:`-Aufruf reicht es dort nicht hinein.
#
# Regeln (identisch zu standards/propagate-standard-bump.yml, Job `verteilung`,
# damit es im Haus nur EINE Verteil-Semantik gibt):
#   Ziel fehlt                          -> create
#   Ziel byte-identisch zur Quelle      -> skip
#   Ziel traegt "llc-verteilung: verwaltet" und weicht ab -> update
#   Ziel weicht ab OHNE Marker          -> abweichler (§0.5 Ausweis, kein PR)
#
# Aufruf:  verteilung_decide <quell-inhalt-datei> <ziel-inhalt-datei|"">
# Setzt:   VERTEILUNG_MODE, VERTEILUNG_REASON
set -uo pipefail

VERTEILUNG_MARKER='llc-verteilung: verwaltet'

# shellcheck disable=SC2034  # VERTEILUNG_MODE/-REASON liest der Aufrufer.
verteilung_decide() {
  local quelle="${1:-}" ziel="${2:-}"
  VERTEILUNG_MODE=""
  VERTEILUNG_REASON=""

  if [ -z "$quelle" ] || [ ! -f "$quelle" ]; then
    VERTEILUNG_MODE="abweichler"
    VERTEILUNG_REASON="Quelldatei fehlt — nichts zu verteilen"
    return 0
  fi
  if [ -z "$ziel" ] || [ ! -f "$ziel" ]; then
    VERTEILUNG_MODE="create"
    VERTEILUNG_REASON="Ziel fehlt — create-if-missing"
    return 0
  fi
  if cmp -s "$quelle" "$ziel"; then
    VERTEILUNG_MODE="skip"
    VERTEILUNG_REASON="Ziel ist identisch"
    return 0
  fi
  # ⛔ Der Marker wird im ZIEL gesucht, nicht in der Quelle. Die Quelle traegt
  # ihn immer; wer ihn im Ziel entfernt hat, hat die Datei bewusst uebernommen
  # und darf nicht ueberschrieben werden.
  if grep -qF "$VERTEILUNG_MARKER" "$ziel"; then
    VERTEILUNG_MODE="update"
    VERTEILUNG_REASON="verwaltet und abweichend — update"
    return 0
  fi
  VERTEILUNG_MODE="abweichler"
  VERTEILUNG_REASON="abweichend ohne Marker — Abweichler-Ausweis, kein PR"
  return 0
}
