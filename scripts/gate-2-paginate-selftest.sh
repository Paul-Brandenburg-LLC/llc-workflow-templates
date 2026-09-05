#!/usr/bin/env bash
# Offline-Testharness fuer die Vollstaendigkeit der Codex-Verdict-Abfragen.
# Befund geheimtreffen-site#107 (2026-07-30): gate-2-codex.yml las die Kommentar-
# und Review-Listen OHNE `--paginate`. Die REST-API liefert dann nur die erste
# Seite (30 Eintraege) und sortiert AUFSTEIGEND — das neueste Urteil steht am
# Ende und faellt als erstes weg. Ein PR mit >30 Kommentaren war damit
# strukturell unmergebar: das Gate sah null Codex-Kommentare, blieb ewig auf
# `pending`, und jede weitere Review-Runde schob das Urteil tiefer auf Seite 2.
#
# Folgebefund (Codex-P1 auf llc-workflow-templates#32): `--paginate` allein reicht
# nicht. `gh api --paginate` gibt laut Handbuch jede Seite EINZELN aus; ein `--jq`
# laeuft dann je Seite und liefert ein Ergebnis PRO SEITE. `sort_by | last` waehlt
# damit den letzten Eintrag jeder Seite statt den letzten insgesamt — der Wert wird
# mehrzeilig, ein SHA-Vergleich kann nie treffen, und ein veraltetes `failure` steht
# neben dem aktuellen `success`. Neuere gh-Versionen aggregieren Array-Antworten
# still, aber undokumentiert, versionsabhaengig und NICHT fuer Objekt-Antworten
# (z.B. /actions/runs/*/jobs). Verbindlich ist deshalb: Seiten explizit mit
# `jq -s '(add // []) | …'` zusammenfuehren, kein `--jq` neben `--paginate`.
#
# Zwei Teile, beide ohne Netzwerk:
#   A) Verhaltensprobe der Auswahl-Semantik — (A1) abgeschnittene vs. vollstaendige
#      Liste, (A2) seitenweise vs. zusammengefuehrte Auswertung. Beide zeigen den
#      Verlust bzw. die Verfaelschung des Urteils direkt.
#   B) Statischer Waechter ueber ALLE Workflows: jede GET-Abfrage auf eine
#      Listen-Ressource MUSS `--paginate` tragen UND ihre Seiten vor der Auswahl
#      zusammenfuehren.
#
# Teil B prueft bewusst die KLASSE statt der bekannten Fundstellen — sonst
# faellt eine kuenftig hinzugefuegte Listen-Abfrage wieder nur einem Menschen auf.
# exit != 0 bei jeder fehlgeschlagenen Assertion → CI-Job 'checks' schlaegt fehl.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
FAIL=0
ok()   { printf '  ok   — %s\n' "$1"; }
fail() { printf '  FAIL — %s\n' "$1"; FAIL=1; }

command -v jq >/dev/null 2>&1 || { echo "jq fehlt — Test kann nicht urteilen"; exit 1; }

# ---------------------------------------------------------------------------
# A1) Verhaltensprobe: was die Abschneidung mit dem Urteil macht
# ---------------------------------------------------------------------------
echo "A1) Auswahl-Semantik bei abgeschnittener Liste"

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
# A2) Verhaltensprobe: seitenweise vs. zusammengefuehrte Auswertung
# ---------------------------------------------------------------------------
# `gh api --paginate` OHNE Zusammenfuehrung sieht fuer jq wie mehrere Dokumente
# hintereinander aus — genau das simulieren wir hier: zwei Seiten-Arrays, jedes
# mit einem Codex-Eintrag. Seite 1 traegt ein veraltetes Urteil auf einem alten
# Commit, Seite 2 das aktuelle auf HEAD.
echo
echo "A2) Auswahl-Semantik bei seitenweiser Auswertung (der P1 auf #32)"

HEAD_FIX="8745a30847ffe0113e1a04a5a9b3b5b0c7d19e02"
ALT_FIX="3a461de00000000000000000000000000000abcd"

SEITE_1=$(jq -nc --arg sha "$ALT_FIX" '[{
  user: { login: "chatgpt-codex-connector[bot]" }, commit_id: $sha,
  submitted_at: "2026-07-30T18:00:00Z", state: "COMMENTED",
  body: "### Integrations-Befunde\n**P1** irgendein alter Befund" }]')
SEITE_2=$(jq -nc --arg sha "$HEAD_FIX" '[{
  user: { login: "chatgpt-codex-connector[bot]" }, commit_id: $sha,
  submitted_at: "2026-07-30T20:11:00Z", state: "COMMENTED",
  body: "Codex Review: Didn'"'"'t find any major issues." }]')
SEITEN=$(printf '%s\n%s\n' "$SEITE_1" "$SEITE_2")   # = Ausgabe von `gh api --paginate`

R_AUSWAHL='[.[] | select(.user.login == "chatgpt-codex-connector[bot]")] | sort_by(.submitted_at) | last // {}'

# So lief es vor dem Fix: `--jq` wendet den Filter auf JEDE Seite an.
JE_SEITE=$(printf '%s' "$SEITEN" | jq -r "$R_AUSWAHL | .commit_id // empty")
# So laeuft es jetzt: Seiten erst zusammenfuehren (`-s`), dann auswaehlen.
GESLURPT=$(printf '%s' "$SEITEN" | jq -sr "(add // []) | $R_AUSWAHL | .commit_id // empty")

[ "$(printf '%s\n' "$JE_SEITE" | grep -c .)" = 2 ] \
  && ok "seitenweise → zwei SHAs statt einem (der Befund)" \
  || fail "seitenweise → erwartet 2 Zeilen, bekam '$(printf '%s' "$JE_SEITE" | tr '\n' '|')'"
[ "$JE_SEITE" = "$HEAD_FIX" ] \
  && fail "seitenweise trifft wider Erwarten den HEAD — die Probe trifft den Fall nicht" \
  || ok "seitenweise → SHA-Vergleich gegen HEAD kann nie treffen, Gate bliebe pending"
[ "$GESLURPT" = "$HEAD_FIX" ] \
  && ok "zusammengefuehrt → genau der HEAD-Commit, Urteil wird verbindlich" \
  || fail "zusammengefuehrt → erwartet '$HEAD_FIX', bekam '$GESLURPT'"

# Dieselbe Falle bei den Kommentar-Bodies: seitenweise steht das veraltete
# `failure` neben dem aktuellen `success` — eval_body() sieht die P1-Marker und
# haelt das Gate faelschlich rot.
K_AUSWAHL='[.[] | select(.user.login == "chatgpt-codex-connector[bot]")] | sort_by(.submitted_at) | last | .body // empty'
K_JE_SEITE=$(printf '%s' "$SEITEN" | jq -r "$K_AUSWAHL")
K_GESLURPT=$(printf '%s' "$SEITEN" | jq -sr "(add // []) | $K_AUSWAHL")

[ "$(eval_body "$K_JE_SEITE")" = "failure" ] \
  && ok "seitenweise → veraltetes 'failure' ueberschreibt das aktuelle 'success'" \
  || fail "seitenweise → erwartet 'failure', bekam '$(eval_body "$K_JE_SEITE")'"
[ "$(eval_body "$K_GESLURPT")" = "success" ] \
  && ok "zusammengefuehrt → das juengste Urteil zaehlt ('success')" \
  || fail "zusammengefuehrt → erwartet 'success', bekam '$(eval_body "$K_GESLURPT")'"

# ---------------------------------------------------------------------------
# B) Statischer Waechter: jede Listen-GET-Abfrage traegt --paginate
#    UND fuehrt ihre Seiten vor der Auswahl zusammen
# ---------------------------------------------------------------------------
echo
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

  # --- Zweite Haelfte derselben Zusage (Codex-P1 auf #32) --------------------
  # `--paginate` holt die Seiten, fuehrt sie aber nicht zusammen. Wer daneben
  # `--jq` setzt, laesst den Filter je Seite laufen: `last` liefert dann ein
  # Ergebnis pro Seite. Zulaessig ist allein die Erlaubnisform — `--paginate`
  # ohne `--jq`, Zusammenfuehrung per `jq -s`/`--slurp`. Bewusst eine
  # Erlaubnis- und keine Verbotsliste: eine Aufzaehlung gefaehrlicher jq-Operatoren
  # waere umgehbar, sobald jemand `.[-1]`, `limit(...)` oder `to_entries` nutzt.
  printf '%s' "$zeile" | grep -qF -- '--paginate' || continue

  # Getrennter Abruf (llc-ops-backlog#87): `VAR=$(gh api --paginate …)` prueft
  # den Exitcode und wertet erst DANACH aus. Das ist strenger als die Pipe —
  # eine Pipe verschluckt den Abruffehler, weil `jq` auf leerer Eingabe `0`
  # liefert und mit Exitcode 0 endet. Die Zusammenfuehrung steht dann nicht auf
  # der `gh api`-Zeile, sondern auf der Zeile, die die Variable auswertet.
  # Anerkannt wird das NUR, wenn dort tatsaechlich `jq -s`/`--slurp` steht —
  # die Zusage bleibt dieselbe, nur ihre Fundstelle verschiebt sich.
  zuweisung=$(printf '%s' "$zeile" | sed -nE 's/.*[^A-Za-z0-9_]([A-Za-z_][A-Za-z0-9_]*)=\$\(gh api[[:space:]].*/\1/p')
  if [ -n "$zuweisung" ] && grep -E -- "\\\$\\{?${zuweisung}\\}?" "$datei" | grep -qE -- 'jq [^|]*-[a-zA-Z]*s[a-zA-Z]*\b|--slurp'; then
    ok "$datei:$nr — /$segment: Abruf getrennt geprueft, Seiten bei der Auswertung von \$$zuweisung zusammengefuehrt (jq -s)"
    continue
  fi

  if printf '%s' "$zeile" | grep -qE -- '--jq|--template'; then
    fail "$datei:$nr — --paginate zusammen mit --jq/--template (Filter laeuft je SEITE); Seiten stattdessen mit 'jq -s \"(add // []) | …\"' zusammenfuehren"
  elif printf '%s' "$zeile" | grep -qE -- 'jq [^|]*-[a-zA-Z]*s[a-zA-Z]*\b|--slurp'; then
    ok "$datei:$nr — /$segment fuehrt die Seiten vor der Auswahl zusammen (jq -s)"
  else
    fail "$datei:$nr — --paginate ohne Zusammenfuehrung: die Seiten kommen einzeln an, die Auswahl braucht 'jq -s \"(add // []) | …\"'"
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
