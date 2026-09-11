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

# --- Das Paar wird als EINE Einheit entschieden ------------------------------
# ⛔ Befund 4: `verteilung_decide` entscheidet je DATEI. War eine Haelfte des
# Paares `abweichler` und die andere `create`/`update`, wurde nur eine Datei
# geschrieben und der PR trotzdem geoeffnet. Ein Workflow ohne seine Bruecke
# laeuft bei jedem PR in „No such file" — genau das tote Pflichttor, das
# Kapitel 5 verhindern soll.
echo "=== verteilung-paar-modus ==="

paar() { # name erwartet modus...
  local name="$1" erwartet="$2"; shift 2
  VERTEILUNG_PAAR_MODE=""; VERTEILUNG_PAAR_REASON=""
  verteilung_paar_modus "$@"
  pruefe "$name" "$erwartet" "$VERTEILUNG_PAAR_MODE"
  # Jede Paar-Entscheidung traegt einen Grund — der Lauf soll im Protokoll
  # erklaerbar sein, gerade wenn er NICHTS geschrieben hat.
  [ -n "$VERTEILUNG_PAAR_REASON" ] || {
    printf 'FAIL %s ohne Grund\n' "$name"; FEHLER=$((FEHLER + 1)); }
}

paar "P1 beide create -> schreiben" schreiben create create
paar "P2 create + update -> schreiben" schreiben create update
paar "P3 skip + update -> schreiben (das GANZE Paar in einen PR)" schreiben skip update
paar "P4 beide skip -> skip" skip skip skip
# ⛔ Der Kern von Befund 4, in beiden Reihenfolgen:
paar "P5 abweichler + create -> abweichler, NICHTS wird angefasst" abweichler abweichler create
paar "P6 create + abweichler -> abweichler (Reihenfolge egal)" abweichler create abweichler
paar "P7 abweichler + skip -> abweichler" abweichler abweichler skip
paar "P8 beide abweichler -> abweichler" abweichler abweichler abweichler
paar "P9 unbekannter Modus -> abweichler, nie raten" abweichler create ""
paar "P10 leeres Paar -> abweichler, nie create" abweichler

# --- Der Verteil-Schritt selbst gegen eine gh-Attrappe -----------------------
# Die Entscheidung allein belegt nicht, dass der Schritt sie auch BEFOLGT.
# Deshalb wird der ganze `run`-Block aus propagate-templates.yml gezogen und
# ausgefuehrt; `gh` ist eine Attrappe, die Repo-Inhalte aus Fixtures liefert
# und jeden Schreibzugriff nur protokolliert. Kein Netz, keine zweite Kopie.
WF_VERT=".github/workflows/propagate-templates.yml"
VERT_BLOCK="$(awk '
  /^      - name: Box-Tor als Paar verteilen/ { s=1 }
  s && /^        run: \|$/ { r=1; next }
  r && /^      [^ ]/ { exit }
  r { print }
' "$WF_VERT" 2>/dev/null)"
if [ -z "$VERT_BLOCK" ] || ! command -v jq >/dev/null 2>&1; then
  printf 'FAIL V Verteil-Block nicht extrahierbar oder jq fehlt\n'; FEHLER=$((FEHLER + 1))
else
  V_TMP="$(mktemp -d)"
  printf '%s\n' "$VERT_BLOCK" | sed 's/^          //' > "$V_TMP/schritt.sh"
  mkdir -p "$V_TMP/bin" "$V_TMP/fix"
  cat > "$V_TMP/bin/gh" <<'ATTRAPPE'
#!/usr/bin/env bash
# Attrappe: liest Repo-Inhalte aus $FIXTUR/<basename>.json, protokolliert
# jeden Schreibzugriff nach $LOG. Fehlt eine Fixture, ist die Datei im Ziel
# nicht vorhanden (Abgang 1, wie `gh api` bei 404).
set -uo pipefail
if [ "${1:-}" = "pr" ]; then
  printf 'pr-%s\n' "${2:-}" >> "$LOG"
  [ "${2:-}" = "create" ] && echo "https://example.invalid/pull/1"
  exit 0
fi
methode="GET"; pfad=""; filter=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    api) shift ;;
    -X) methode="${2:-}"; shift 2 ;;
    --jq) filter="${2:-}"; shift 2 ;;
    -f|--input) shift 2 ;;
    -*) shift ;;
    *) [ -z "$pfad" ] && pfad="$1"; shift ;;
  esac
done
ohne_frage="${pfad%%\?*}"
if [ "$methode" = "PUT" ]; then
  printf 'put-%s\n' "$(basename "$ohne_frage")" >> "$LOG"; exit 0
fi
if [ "$methode" = "POST" ]; then
  printf 'ref\n' >> "$LOG"; exit 0
fi
antwort=""
case "$ohne_frage" in
  */git/ref/heads/*) antwort='{"object":{"sha":"0000000000000000000000000000000000000000"}}' ;;
  */contents/*)
    datei="$FIXTUR/$(basename "$ohne_frage").json"
    [ -f "$datei" ] || exit 1
    antwort="$(cat "$datei")" ;;
  *) antwort='{"default_branch":"main"}' ;;
esac
if [ -n "$filter" ]; then printf '%s' "$antwort" | jq -r "$filter"; else printf '%s' "$antwort"; fi
ATTRAPPE
  chmod +x "$V_TMP/bin/gh"
  v_fixtur() { # zieldatei inhaltsdatei ("" = fehlt im Ziel)
    if [ -z "${2:-}" ]; then rm -f "$V_TMP/fix/$1.json"; return 0; fi
    jq -nc --arg c "$(base64 < "$2" | tr -d '\n')" \
      '{sha:"aaaaaaa", content:$c, encoding:"base64"}' > "$V_TMP/fix/$1.json"
  }
  v_lauf() { # -> protokollierte Schreibzugriffe, kommasepariert
    : > "$V_TMP/log"
    ( PATH="$V_TMP/bin:$PATH" FIXTUR="$V_TMP/fix" LOG="$V_TMP/log" \
      GITHUB_WORKSPACE="$PWD" GITHUB_RUN_ID="1" \
      REPO="Paul-Brandenburg-LLC/llc-ops-backlog" DRY_RUN="false" GH_TOKEN="x" \
      bash "$V_TMP/schritt.sh" >/dev/null 2>&1 )
    paste -sd, - < "$V_TMP/log" | sed 's/,$//'
  }
  V_YML="distribution/entwicklung-review.yml"
  V_PY="distribution/entwicklung_review_bridge.py"
  # „verwaltet und abweichend": Marker bleibt, Inhalt nicht identisch.
  { cat "$V_YML"; echo "# abweichende Zeile"; } > "$V_TMP/verwaltet.yml"
  # „bewusst uebernommen": Marker-Zeile entfernt -> Abweichler-Ausweis.
  grep -v 'llc-verteilung: verwaltet' "$V_PY" > "$V_TMP/eigen.py"

  v_fixtur entwicklung-review.yml ""
  v_fixtur entwicklung_review_bridge.py ""
  pruefe "V1 beide fehlen -> beide geschrieben, ein PR" \
    'put-entwicklung-review.yml,put-entwicklung_review_bridge.py,pr-create,pr-merge' \
    "$(v_lauf | sed 's/^ref,//')"

  v_fixtur entwicklung-review.yml "$V_YML"
  v_fixtur entwicklung_review_bridge.py "$V_PY"
  pruefe "V2 beide identisch -> gar nichts, kein PR" '' "$(v_lauf)"

  v_fixtur entwicklung-review.yml "$V_TMP/verwaltet.yml"
  v_fixtur entwicklung_review_bridge.py "$V_PY"
  pruefe "V3 eine Haelfte update, andere identisch -> ein Schreiben, ein PR" \
    'put-entwicklung-review.yml,pr-create,pr-merge' "$(v_lauf | sed 's/^ref,//')"

  # ⛔ DER Befund-4-Fall: eine Haelfte ist Abweichler, die andere fehlt.
  # Vorher wurde die fehlende Haelfte geschrieben und der PR geoeffnet — das
  # Zielrepo trug danach eine Bruecke ohne Workflow oder umgekehrt.
  v_fixtur entwicklung-review.yml ""
  v_fixtur entwicklung_review_bridge.py "$V_TMP/eigen.py"
  pruefe "V4 Abweichler + fehlende Haelfte -> NICHTS geschrieben, kein PR" \
    '' "$(v_lauf)"

  v_fixtur entwicklung-review.yml "$V_TMP/verwaltet.yml"
  v_fixtur entwicklung_review_bridge.py "$V_TMP/eigen.py"
  pruefe "V5 Abweichler + update-Haelfte -> NICHTS geschrieben, kein PR" \
    '' "$(v_lauf)"

  v_fixtur entwicklung-review.yml "$V_YML"
  v_fixtur entwicklung_review_bridge.py "$V_TMP/eigen.py"
  pruefe "V6 Abweichler + identische Haelfte -> NICHTS geschrieben, kein PR" \
    '' "$(v_lauf)"

  rm -rf "$V_TMP"
fi

echo "---"
if [ "$FEHLER" -eq 0 ]; then
  echo "verteilung-decide: alle Faelle gruen"
  exit 0
fi
echo "verteilung-decide: $FEHLER Fall/Faelle rot"
exit 1
