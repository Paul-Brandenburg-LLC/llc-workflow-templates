#!/usr/bin/env bash
# Holt den Vergleichsstand und ruft konfiguration-lesen.py — PB LLC §3.b.2 v7.6.1.
#
# Der Vergleichsstand kommt als unveraenderlicher SHA aus dem PR-Ereignis, nie
# ueber einen Branch-Namen: der Branch koennte zwischen Ereignis und Lauf
# weitergewandert sein, und dann pruefte S-2 gegen etwas anderes als das, was
# der PR wirklich veraendert.
#
# Env: TIER_EINGABE [BASIS_SHA] [KONFIG_DATEI]
# Ausgabe: KONFIG_JSON in $GITHUB_ENV, tier in $GITHUB_OUTPUT.
set -euo pipefail

KONFIG_DATEI="${KONFIG_DATEI:-CLAUDE.md}"
BASIS_SHA="${BASIS_SHA:-}"
BASIS_DATEI=""
BASIS_HAT_DATEI=0

if [ -n "$BASIS_SHA" ]; then
  # Jeder Fehler auf dem Weg zum Vergleichsstand bricht ab. Eine still
  # geleerte Basis saehe aus wie "nichts zu vergleichen" und liesse eine
  # Herabstufung durch — die Pruefung waere dann genau da blind, wo sie
  # gebraucht wird.
  if ! git rev-parse --verify --quiet "${BASIS_SHA}^{commit}" >/dev/null 2>&1; then
    if ! git fetch --quiet --depth=1 origin "$BASIS_SHA" 2>/dev/null; then
      echo "::error::Vergleichsstand $BASIS_SHA nicht holbar — die Tier-Pruefung haette keinen Vergleichsstand" >&2
      exit 1
    fi
  fi
  if git cat-file -e "${BASIS_SHA}:${KONFIG_DATEI}" 2>/dev/null; then
    BASIS_DATEI=$(mktemp)
    if ! git show "${BASIS_SHA}:${KONFIG_DATEI}" > "$BASIS_DATEI"; then
      echo "::error::${KONFIG_DATEI} aus dem Vergleichsstand $BASIS_SHA nicht lesbar" >&2
      exit 1
    fi
    BASIS_HAT_DATEI=1
  fi
else
  echo "::notice::Kein Vergleichsstand im Ereignis (kein pull_request) — nur der aktuelle Stand wird geprueft" >&2
fi

KONFIG_JSON=$(
  KOPF_DATEI="$KONFIG_DATEI" \
  BASIS_DATEI="$BASIS_DATEI" \
  BASIS_HAT_DATEI="$BASIS_HAT_DATEI" \
  TIER_EINGABE="${TIER_EINGABE:-auto}" \
  python3 "$(dirname "$0")/konfiguration-lesen.py"
)

TIER=$(printf '%s' "$KONFIG_JSON" | jq -r '.tier')

# Mehrzeiliges JSON darf nie als nackte KEY=VALUE-Zeile in GITHUB_ENV landen —
# eine eingeschleuste Zeile setzte sonst beliebige weitere Variablen. Deshalb
# das Heredoc-Format mit zufallsfreiem, aber eindeutigem Trenner.
{
  echo "KONFIG_JSON<<QUARTETT_KONFIG_EOF"
  printf '%s\n' "$KONFIG_JSON"
  echo "QUARTETT_KONFIG_EOF"
} >> "${GITHUB_ENV:-/dev/null}"

echo "tier=$TIER" >> "${GITHUB_OUTPUT:-/dev/stdout}"
printf '%s\n' "$KONFIG_JSON"
