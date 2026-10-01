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

# ⛔ Ein Paar wird als EINE Einheit entschieden, nie Datei fuer Datei.
#
# Der Verteil-Weg des Box-Tors traegt ein untrennbares Paar: der Workflow
# `.github/workflows/entwicklung-review.yml` startet die Bruecke als Datei aus
# dem Arbeitsbaum (`python3 .github/scripts/entwicklung_review_bridge.py`).
# Entschied man je Datei, konnte eine Haelfte `abweichler` sein und die andere
# `create`/`update` — geschrieben wurde dann NUR eine, und der PR ging trotzdem
# auf. Ein Workflow ohne seine Bruecke laeuft bei jedem PR in „No such file"
# und laesst genau das tote Pflichttor stehen, das dieses Kapitel verhindern
# soll; eine Bruecke ohne Workflow tut nichts.
#
# Regeln:
#   irgendeine Haelfte `abweichler` -> abweichler: KEINE wird angefasst
#   irgendeine Haelfte create/update -> schreiben: das GANZE Paar in EINEN PR
#   alle Haelften `skip`            -> skip
#   unbekannter Modus / leeres Paar -> abweichler (nichts anfassen, nie raten)
#
# Aufruf:  verteilung_paar_modus <modus> [<modus> ...]
# Setzt:   VERTEILUNG_PAAR_MODE, VERTEILUNG_PAAR_REASON
# shellcheck disable=SC2034  # VERTEILUNG_PAAR_MODE/-REASON liest der Aufrufer.
verteilung_paar_modus() {
  local modus abweichler=0 schreiben=0 unbekannt=0
  VERTEILUNG_PAAR_MODE=""
  VERTEILUNG_PAAR_REASON=""

  if [ "$#" -eq 0 ]; then
    VERTEILUNG_PAAR_MODE="abweichler"
    VERTEILUNG_PAAR_REASON="kein Paar uebergeben — nichts anfassen"
    return 0
  fi
  for modus in "$@"; do
    case "$modus" in
      abweichler) abweichler=$((abweichler + 1)) ;;
      create|update) schreiben=$((schreiben + 1)) ;;
      skip) ;;
      *) unbekannt=$((unbekannt + 1)) ;;
    esac
  done
  if [ "$unbekannt" -gt 0 ]; then
    VERTEILUNG_PAAR_MODE="abweichler"
    VERTEILUNG_PAAR_REASON="unbekannter Modus im Paar — nichts anfassen"
    return 0
  fi
  if [ "$abweichler" -gt 0 ]; then
    VERTEILUNG_PAAR_MODE="abweichler"
    VERTEILUNG_PAAR_REASON="$abweichler von $# Haelften weicht ab — das ganze Paar bleibt unangetastet"
    return 0
  fi
  if [ "$schreiben" -gt 0 ]; then
    VERTEILUNG_PAAR_MODE="schreiben"
    VERTEILUNG_PAAR_REASON="$schreiben von $# Haelften braucht create/update — das ganze Paar in einen PR"
    return 0
  fi
  VERTEILUNG_PAAR_MODE="skip"
  VERTEILUNG_PAAR_REASON="alle Haelften identisch"
  return 0
}
