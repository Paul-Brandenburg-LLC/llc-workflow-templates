#!/usr/bin/env bash
# shellcheck disable=SC2034  # DECISION_MODE/DECISION_REASON sind Rueckgabe-Globals fuer den Aufrufer
# SSOT-Entscheidungslogik fuer propagate-templates.yml -- PB LLC §3.4 / v7.0.0 §16.2b.
# Wird sowohl vom Workflow (via checkout + source) als auch vom Offline-Harness genutzt.
#
# pin_bump_decide TEMPLATE PINNED_REF TARGET_TAG
#   PINNED_REF = aktuell im Consumer gepinnter Ref (leer = statische Datei, kein Reusable)
#   Setzt Globals: DECISION_MODE (migrate|pinbump|skip) + DECISION_REASON
#
# Regeln:
#   - leer            -> migrate  (statisch -> reusable@TARGET)
#   - == TARGET       -> skip     (schon aktuell)
#   - 40-hex SHA      -> skip     (bewusster Commit-Pin)
#   - vN (floating)   -> skip     (bekommt Updates automatisch)
#   - vX.Y.Z, anderer Major als TARGET -> skip (Major-Bump = manuell, kein gate-freier Auto-PR)
#   - vX.Y.Z < TARGET (gleicher Major) -> pinbump
#   - vX.Y.Z >= TARGET                 -> skip
#   - sonst           -> skip     (unbekanntes Pin-Format)
#
# Ausnahme pre-pr-quartett.yml (v7.6.1, llc-ops-backlog#1096): diese Datei ist
# KEIN Reusable-Workflow-Caller, sondern ein eigener Job, der eine Composite
# Action aufruft (`.github/actions/pre-pr-quartett@REF`). Fuer sie gibt es
# `migrate` NICHT — der Migrate-Zweig in propagate-templates.yml rendert einen
# Gate-2-Codex-Wrapper, der sie in jedem Consumer ueberschreiben wuerde. Ein
# leerer PINNED_REF heisst hier deshalb `skip`, nicht `migrate`; fehlt die Datei
# ganz, greift vorher der create-Zweig (create-if-missing).
pin_bump_decide() {
  # shellcheck disable=SC2034  # DECISION_MODE/DECISION_REASON = Rueckgabe-Globals fuer den Aufrufer
  local template="$1" pinned="$2" tag="$3"

  if [ -z "$pinned" ]; then
    if [ "$template" = "pre-pr-quartett.yml" ]; then
      DECISION_MODE="skip"
      DECISION_REASON="pre-pr-quartett.yml ohne erkennbaren Action-Pin -- KEIN migrate (der Migrate-Wrapper wuerde sie mit einem Gate-2-Codex-Caller ueberschreiben)"
      return 0
    fi
    DECISION_MODE="migrate"; DECISION_REASON="statische Datei -> reusable@$tag"; return 0
  fi
  if [ "$pinned" = "$tag" ]; then
    DECISION_MODE="skip"; DECISION_REASON="bereits auf Target $tag gepinnt"; return 0
  fi
  if printf '%s' "$pinned" | grep -qE '^[0-9a-f]{40}$'; then
    DECISION_MODE="skip"; DECISION_REASON="Commit-SHA-Pin ($pinned) -- bewusst, kein Auto-Bump"; return 0
  fi
  if printf '%s' "$pinned" | grep -qE '^v[0-9]+$'; then
    DECISION_MODE="skip"; DECISION_REASON="Floating-Major-Pin ($pinned) -- Updates automatisch"; return 0
  fi
  if printf '%s' "$pinned" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
    local pinned_major="${pinned%%.*}" tag_major="${tag%%.*}" newest
    if [ "$pinned_major" != "$tag_major" ]; then
      DECISION_MODE="skip"; DECISION_REASON="Major-Bump $pinned->$tag -- manuell reviewen (kein gate-freier Auto-PR)"; return 0
    fi
    newest=$(printf '%s\n%s\n' "$pinned" "$tag" | sort -V | tail -1)
    if [ "$newest" = "$tag" ] && [ "$pinned" != "$tag" ]; then
      DECISION_MODE="pinbump"; DECISION_REASON="$pinned < $tag (gleicher Major) -> Pin-Bump"; return 0
    fi
    DECISION_MODE="skip"; DECISION_REASON="$pinned >= Target $tag -- kein Bump"; return 0
  fi
  DECISION_MODE="skip"; DECISION_REASON="unbekanntes Pin-Format '$pinned'"; return 0
}
