#!/usr/bin/env bash
# 2a Repo-Konfig-Konformitaet — PB LLC §3.b.2 v7.6.1 (llc-ops-backlog#1096, S-3).
#
# Aenderung gegenueber v7.6.0: die Tier-Pflichtfelder werden auf VORHANDENSEIN
# geprueft (`has("<feld>")`), nicht mehr auf ihren Wahrheitswert.
#
# Der alte Weg las jedes Feld als `yq -r ".$k // \"\""`. Der Alternativ-Operator
# `//` greift in yq/jq bei `null` UND bei `false` — ein voellig gueltiges
# `b2c_funnel: false` wurde damit zu "" und als *fehlt* gemeldet. Gemessen
# (yq v4.53.2):
#     printf 'b2c_funnel: false\n' | yq -r '.b2c_funnel // ""'    -> leer
#     printf 'b2c_funnel: false\n' | yq -r 'has("b2c_funnel")'    -> true
# Belegt am 28.08.2026 an pb-revenue, stattzeitung-net-site (b2c_funnel: false)
# und VoicePrompt-app (customer: false); die Gegenprobe projectfovea-com-site
# ohne Pflichtfeld auf `false` lief gruen. Solange `quartett` nirgends
# erforderlicher Check ist, war das Laerm — MIT der Pflicht waere jedes Repo mit
# einem Pflichtfeld auf `false` schlagartig merge-tot gewesen.
#
# §3.b.2 2a-(vi) verlangt seit v5.9 woertlich, die Pflichtfelder muessten
# "existieren"; die Implementierung blieb hinter ihrer eigenen Beschreibung
# zurueck. Das hier ist die Korrektur, keine neue Pruefung.
#
# Die Frontmatter kommt als geprueftes JSON aus konfiguration-lesen.py — es gibt
# bewusst KEIN zweites Lesen der Datei: zwei Lesarten derselben Frontmatter, die
# auseinanderlaufen koennen, waren die Wurzel des ganzen Vorgangs.
#
# Env: KONFIG_JSON (Pflicht)
set -euo pipefail
: "${KONFIG_JSON:?KONFIG_JSON fehlt — konfiguration-lesen.sh muss vorher laufen}"

TIER=$(printf '%s' "$KONFIG_JSON" | jq -r '.tier')
FM=$(printf '%s' "$KONFIG_JSON" | jq -c '.frontmatter')

ERRORS=""
add_err() { ERRORS+="$1"$'\n'; }

# 2a-(i) AGENTS.md
[ ! -f "AGENTS.md" ] && add_err "2a-(i): AGENTS.md fehlt"
# 2a-(ii) gate-2-codex.yml
[ ! -f ".github/workflows/gate-2-codex.yml" ] && add_err "2a-(ii): .github/workflows/gate-2-codex.yml fehlt"

# 2a-(vi) Tier-Pflichtfelder — Vorhandensein UND Typ-Staffelung (v7.7.0).
#
# Das nackte `has()` aus v7.6.1 war das Pendel in die Gegenrichtung des
# `//`-Defekts: `critical_paths: false` galt als vorhanden, `.critical_paths[]?`
# lieferte still nichts, und die Glob-Pruefung (vii) lief leer — gemeldet als
# P1 der Codex-Vorpruefung am 28.08.2026 auf dem Pin-Zweig von pb-comms.
#
# Haerte folgt dem GEMESSENEN Bestand (36 Repos, 28.08.2026): Hard-Block nur
# fuer Felder, deren Bestand typrein ist und deren Typfehler eine Pruefung
# still umgeht (Listen-Felder, healthz-Number). Warnstufe fuer b2c_funnel-Typ
# (zwei Bestandsrepos: String), customer-Typ samt Enum-Mitgliedschaft
# (§8.4.7: false ODER vier String-Werte; drei Bestandsrepos false, ein
# Sonderwert) und Nicht-Leere der Listen (14 Bestandsrepos leer). Warnstufe
# wird Hard erst nach Bestandskorrektur plus Nachmessung, als eigener Bump.
case "$TIER" in
  1) PFLICHT="healthz_queue_threshold_s b2c_funnel visual_regression_paths critical_paths customer" ;;
  2) PFLICHT="critical_paths customer" ;;
  3|4) PFLICHT="customer" ;;
  *) PFLICHT="" ;;
esac
for k in $PFLICHT; do
  if [ "$(printf '%s' "$FM" | jq --arg k "$k" 'has($k)')" != "true" ]; then
    add_err "2a-(vi): Tier-${TIER} Pflichtfeld '$k' fehlt"
    continue
  fi
  # ⚠ konfiguration-lesen.py liest mit yaml.BaseLoader — JEDER Skalar kommt
  # als String an ("5", "false"). Eine Pruefung auf jq-Typen (number/boolean)
  # haette deshalb jedes Tier-1-Repo geblockt (P1 der Vorpruefung, Runde 1,
  # auf diesem Zweig). Skalare werden darum am WERT geprueft, nur die
  # Listen-Form am jq-Typ — Listen bleiben auch unter BaseLoader Arrays.
  TYP=$(printf '%s' "$FM" | jq -r --arg k "$k" '.[$k] | type')
  WERT=$(printf '%s' "$FM" | jq -r --arg k "$k" '.[$k] | tostring')
  case "$k" in
    critical_paths|visual_regression_paths)
      if [ "$TYP" != "array" ]; then
        add_err "2a-(vi): '$k' muss eine Liste sein (gelesen: $WERT) — ein Nicht-Listen-Wert umgeht die Glob-Pruefung (vii) still"
      elif [ "$(printf '%s' "$FM" | jq --arg k "$k" '.[$k] | length')" = "0" ]; then
        echo "::warning::2a-(vi): '$k' ist eine leere Liste — Befuellung ausstehend (Warnstufe v7.7.0)"
      elif [ "$(printf '%s' "$FM" | jq -r --arg k "$k" '[.[$k][] | type] | unique | join(",")')" != "string" ]; then
        add_err "2a-(vi): '$k' muss eine Liste einfacher Pfad-Eintraege sein"
      fi
      ;;
    healthz_queue_threshold_s)
      if [ "$TYP" != "number" ] && ! printf '%s' "$WERT" | grep -Eq '^[0-9]+([.][0-9]+)?$'; then
        add_err "2a-(vi): '$k' muss eine Zahl sein (gelesen: $WERT)"
      fi
      ;;
    b2c_funnel)
      case "$WERT" in
        true|True|TRUE|false|False|FALSE) : ;;
        *) echo "::warning::2a-(vi): 'b2c_funnel' sollte Boolean sein (gelesen: $WERT; Warnstufe v7.7.0, zwei Bestandsrepos)" ;;
      esac
      ;;
    customer)
      case "$WERT" in
        false|False|FALSE) : ;;
        true|True|TRUE)
          echo "::warning::2a-(vi): 'customer: true' ist kein gueltiger §8.4.7-Enum-Wert — Migration auf einen String-Wert ausstehend (Warnstufe v7.7.0)" ;;
        B2C-public|B2B-saas|internal-LLC|internal-LLC-services) : ;;
        *) echo "::warning::2a-(vi): 'customer: $WERT' steht nicht in der §8.4.7-Enum-Tabelle (CEO-Klassifikation ausstehend; Warnstufe v7.7.0)" ;;
      esac
      ;;
  esac
done

# 2a-(vii) critical_paths-Glob-Existenz. `[]?` toleriert ein fehlendes oder
# nicht-listenfoermiges Feld; dessen Abwesenheit meldet bereits (vi).
CP_LIST=$(printf '%s' "$FM" | jq -r '.critical_paths[]? // empty' 2>/dev/null || echo "")
if [ -n "$CP_LIST" ]; then
  while IFS= read -r glob; do
    [ -z "$glob" ] && continue
    # `|| true`: bash 3.2 (macOS) kennt globstar nicht und gibt Exit 1 —
    # unter `set -e` braeche der Schritt hier ab, und der Offline-Selftest
    # liefe nur auf dem Runner. Ein Schalter, der nicht gesetzt werden kann,
    # ist kein Befund.
    shopt -s nullglob globstar 2>/dev/null || true
    # shellcheck disable=SC2206  # absichtliches Globbing des Musters
    matches=( $glob )
    shopt -u nullglob globstar 2>/dev/null || true
    if [ ${#matches[@]} -eq 0 ] && [ ! -e "$glob" ]; then
      add_err "2a-(vii): critical_paths-Glob '$glob' matcht keine Datei"
    fi
  done <<< "$CP_LIST"
fi

if [ -n "$ERRORS" ]; then
  echo "::error::Pre-PR-Quartett 2a BLOCK:"
  printf '%s' "$ERRORS"
  exit 1
fi
echo "✓ 2a Repo-Konfig-Konformitaet (Tier $TIER)"
