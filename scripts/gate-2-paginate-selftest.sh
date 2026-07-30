#!/usr/bin/env bash
# Offline-Testharness fuer die Vollstaendigkeit der Codex-Verdict-Abfragen.
# Befund geheimtreffen-site#107 (2026-07-30): gate-2-codex.yml las die Kommentar-
# und Review-Listen OHNE `--paginate`. Die REST-API liefert dann nur die erste
# Seite (30 Eintraege) und sortiert AUFSTEIGEND — das neueste Urteil steht am
# Ende und faellt als erstes weg. Ein PR mit >30 Kommentaren war damit
# strukturell unmergebar: das Gate sah null Codex-Kommentare, blieb ewig auf
# `pending`, und jede weitere Review-Runde schob das Urteil tiefer auf Seite 2.
#
# Zwei Teile, beide ohne Netzwerk:
#   A) Verhaltensprobe der Auswahl-Semantik (`sort_by | last` auf abgeschnittener
#      vs. vollstaendiger Liste) — zeigt den Verlust des Urteils direkt.
#   B) Statischer Waechter ueber ALLE Workflows: jede GET-Abfrage auf eine
#      Listen-Ressource MUSS `--paginate` tragen.
#
# Teil B prueft bewusst die KLASSE statt der zwei bekannten Fundstellen — sonst
# faellt eine kuenftig hinzugefuegte Listen-Abfrage wieder nur einem Menschen auf.
# exit != 0 bei jeder fehlgeschlagenen Assertion → CI-Job 'checks' schlaegt fehl.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
FAIL=0
ok()   { printf '  ok   — %s\n' "$1"; }
fail() { printf '  FAIL — %s\n' "$1"; FAIL=1; }

command -v jq >/dev/null 2>&1 || { echo "jq fehlt — Test kann nicht urteilen"; exit 1; }

# ---------------------------------------------------------------------------
# A) Verhaltensprobe: was die Abschneidung mit dem Urteil macht
# ---------------------------------------------------------------------------
echo "A) Auswahl-Semantik bei abgeschnittener Liste"

# 33 Kommentare, aufsteigend nach created_at wie die echte API. Nur der
# vorletzte und letzte stammen von Codex — beide liegen jenseits von Seite 1.
FIXTURE=$(jq -nc '[range(0;33) as $i | {
  user:   { login: (if $i >= 31 then "chatgpt-codex-connector[bot]" else "pb-llc-repairbot" end) },
  created_at: ("2026-07-30T\(20 + ($i / 60 | floor)):\(($i % 60) | tostring | ("0" + .)[-2:]):00Z"),
  body:   (if $i >= 31 then "Codex Review: Didn'"'"'t find any major issues.\n\n**Reviewed commit:** `8745a30847`" else "@codex review" end)
}]')

# Exakt die jq-Auswahl aus gate-2-codex.yml.
AUSWAHL='[.[] | select(.user.login == "chatgpt-codex-connector[bot]")] | sort_by(.created_at) | last | .body // empty'

VOLL=$(printf '%s' "$FIXTURE" | jq -r "$AUSWAHL")
SEITE1=$(printf '%s' "$FIXTURE" | jq -r ".[0:30] | $AUSWAHL")

# Verdict-Erkennung — identisch zu eval_body() im Workflow.
eval_body() {
  if echo "$1" | grep -qE '### Integrations-Befunde|### Findings|🚨|\*\*P[01]\*\*'; then echo failure
  elif echo "$1" | grep -qE '^### 💡 Codex Review|^### Codex Review|^Codex Review: '; then echo success
  else echo ""; fi
}

[ -n "$VOLL" ] && ok "vollstaendige Liste liefert einen Codex-Body" \
                || fail "vollstaendige Liste liefert KEINEN Body — Fixture kaputt"
[ -z "$SEITE1" ] && ok "auf Seite 1 allein ist KEIN Codex-Body zu finden (der Befund)" \
                 || fail "Seite 1 enthaelt wider Erwarten einen Codex-Body — Fixture trifft den Fall nicht"
[ "$(eval_body "$VOLL")" = "success" ] && ok "vollstaendig → Verdict 'success'" \
                                       || fail "vollstaendig → erwartet 'success', bekam '$(eval_body "$VOLL")'"
[ "$(eval_body "$SEITE1")" = "" ] && ok "abgeschnitten → gar kein Verdict (Gate bleibt pending)" \
                                  || fail "abgeschnitten → erwartet kein Verdict, bekam '$(eval_body "$SEITE1")'"

# Gegenprobe: liegt das Urteil frueh genug, traegt auch Seite 1 — sonst wuerde
# der Test auch bei einer voellig kaputten Auswahl gruen melden.
FRUEH=$(printf '%s' "$FIXTURE" | jq -c '.[0].user.login = "chatgpt-codex-connector[bot]" | .[0].body = "Codex Review: Didn'"'"'t find any major issues."')
FRUEH_S1=$(printf '%s' "$FRUEH" | jq -r ".[0:30] | $AUSWAHL")
[ -n "$FRUEH_S1" ] && ok "Gegenprobe: frueher Codex-Kommentar ist auf Seite 1 sichtbar" \
                   || fail "Gegenprobe fehlgeschlagen — die Auswahl findet auch vorhandene Bodies nicht"

# ---------------------------------------------------------------------------
# B) Statischer Waechter: jede Listen-GET-Abfrage traegt --paginate
# ---------------------------------------------------------------------------
echo "B) Vollstaendigkeit aller Listen-Abfragen in .github/workflows/"

# Ressourcen, die GitHub SEITENWEISE ausliefert. Endet ein gh-api-Pfad auf eines
# dieser Segmente, ist die Antwort eine Liste → `--paginate` ist Pflicht.
LISTEN='comments|reviews|files|commits|issues|pulls|events|labels|releases|tags|branches|check-runs|statuses|runs|artifacts|jobs'

GEPRUEFT=0
AUSNAHMEN=0
while IFS= read -r treffer; do
  datei=${treffer%%:*}
  rest=${treffer#*:}
  nr=${rest%%:*}
  zeile=${rest#*:}

  # Schreibende Aufrufe sind keine Listen-Lesungen.
  printf '%s' "$zeile" | grep -qE '\-X[[:space:]]+(POST|PATCH|PUT|DELETE)' && continue

  # Endpunkt aus der Zeile ziehen (erstes gequotetes Argument nach `gh api`).
  pfad=$(printf '%s' "$zeile" | sed -nE 's/.*gh api[^"]*"([^"]+)".*/\1/p')
  [ -z "$pfad" ] && continue
  pfad=${pfad%%\?*}       # Query abschneiden
  pfad=${pfad%/}          # evtl. Slash am Ende
  segment=${pfad##*/}

  printf '%s' "$segment" | grep -qE "^($LISTEN)$" || continue

  GEPRUEFT=$((GEPRUEFT + 1))
  if printf '%s' "$zeile" | grep -qF -- '--paginate'; then
    ok "$datei:$nr — /$segment mit --paginate"
  elif printf '%s' "$zeile" | grep -qE '\.\[0\]|\| *first'; then
    # Begruendete Ausnahme: Wer nur das ERSTE Element nimmt, bekommt es auch auf
    # Seite 1 — Abschneiden am Ende aendert daran nichts. Faehrlich ist allein
    # der Zugriff aufs LETZTE Element (`last`) oder auf die Menge (`length`).
    AUSNAHMEN=$((AUSNAHMEN + 1))
    ok "$datei:$nr — /$segment ohne --paginate zulaessig (nimmt nur das erste Element)"
  else
    fail "$datei:$nr — /$segment OHNE --paginate (sieht nur die ersten 30 Eintraege)"
  fi
  # Wer das LETZTE Element will, darf sich NIE auf eine Seite verlassen — das war
  # der Befund. Diese Kombination ist unabhaengig vom Obigen ein harter Fehler.
  if printf '%s' "$zeile" | grep -qE '\| *last|\.\[-1\]' && ! printf '%s' "$zeile" | grep -qF -- '--paginate'; then
    fail "$datei:$nr — greift auf das LETZTE Element einer Liste zu, ohne --paginate"
  fi
done < <(
  # Aufrufe ueber Backslash-Fortsetzungen zu EINER logischen Zeile zusammenziehen,
  # sonst uebersieht der Waechter ein `--paginate`, das in der Folgezeile steht
  # (falsch-positiv-Befund an propagate-templates.yml beim ersten Lauf).
  for f in .github/workflows/*.yml; do
    [ -e "$f" ] || continue
    awk -v datei="$f" '
      { zeile = $0; start = NR
        while (zeile ~ /\\[[:space:]]*$/ && (getline nxt) > 0) {
          sub(/\\[[:space:]]*$/, "", zeile); zeile = zeile " " nxt
        }
        if (zeile ~ /gh api/) print datei ":" start ":" zeile
      }' "$f"
  done
)

# Der Waechter muss ueberhaupt etwas zu pruefen gefunden haben — sonst meldet er
# gruen, weil sein Suchmuster ins Leere greift (Mutationsprobe-Lehre: die AUSWAHL
# ist haeufiger das Loch als die Bedingung).
if [ "$GEPRUEFT" -ge 2 ]; then
  ok "$GEPRUEFT Listen-Abfragen ueberhaupt gefunden und geprueft"
else
  fail "nur $GEPRUEFT Listen-Abfragen gefunden — das Suchmuster greift ins Leere, der Test kann nicht fallen"
fi

echo
[ "$FAIL" = 0 ] && { echo "gate-2-paginate-selftest: alle Proben bestanden"; exit 0; }
echo "gate-2-paginate-selftest: FEHLGESCHLAGEN"; exit 1
