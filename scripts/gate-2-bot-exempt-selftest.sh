#!/usr/bin/env bash
# Offline-Testharness fuer das bot-exempt-KLASSEN-Gate in gate-2-codex.yml
# (Step "Resolve PR HEAD", seit v1.8.0). Repliziert die Klassifikation 1:1;
# der GitHub-Zugriff (PR-Metadaten + Diff-Dateien) ist per Parametern bzw.
# vorbefuelltem FILES_JSON gestubbt. Kein GitHub, kein Netzwerk.
# exit != 0 bei jeder fehlgeschlagenen Assertion → CI-Gate 'checks' schlaegt fehl.
set -uo pipefail

# --- IDENTISCH zur geteilten Lib in gate-2-codex.yml ($RUNNER_TEMP/gate2-lib.sh,
# BYTE-IDENTISCH auch zu scripts/gate-2-doc-only-selftest.sh) --------------------
is_pin_bump() {
  local JSON nfiles bad i patch line body key major addf rmf
  JSON="$(cat)"
  nfiles=$(printf '%s' "$JSON" | jq 'length')
  case "$nfiles" in ''|*[!0-9]*) echo false; return;; esac
  [ "$nfiles" -gt 0 ] || { echo false; return; }
  # (a) jede geaenderte Datei ist ein Workflow-File
  bad=$(printf '%s' "$JSON" | jq -r '[.[] | select((.filename|test("^\\.github/workflows/[^/]+\\.ya?ml$"))|not)] | length')
  [ "$bad" = "0" ] || { echo false; return; }
  addf="$(mktemp)"; rmf="$(mktemp)"
  i=0
  while [ "$i" -lt "$nfiles" ]; do
    patch=$(printf '%s' "$JSON" | jq -r ".[$i].patch // \"\"")
    while IFS= read -r line; do
      case "$line" in
        '+++'*|'---'*|'@@'*|' '*|'') : ;;
        '+'*|'-'*)
          # (b) jede +/- Zeile MUSS eine Org-Reusable-uses-Zeile mit Semver-Tag sein:
          #     Reusable-Workflow (workflows/<f>.yml, Job-Ebene) ODER Composite
          #     Action (actions/<name>, Step-Ebene mit Listen-'- ') — P1 Runde 4.
          if ! printf '%s\n' "$line" | grep -qE '^[-+][[:space:]]*(-[[:space:]]+)?uses:[[:space:]]*Paul-Brandenburg-LLC/llc-workflow-templates/\.github/(workflows/[A-Za-z0-9._-]+\.ya?ml|actions/[A-Za-z0-9._-]+)@v[0-9]+\.[0-9]+\.[0-9]+[[:space:]]*$'; then
            command rm -f "$addf" "$rmf"; echo false; return
          fi
          body=${line:1}
          major=$(printf '%s' "$body" | sed -E 's/.*@v([0-9]+)\.[0-9]+\.[0-9]+[[:space:]]*$/\1/')
          key=$(printf '%s' "$body" | sed -E 's/@v[0-9]+\.[0-9]+\.[0-9]+[[:space:]]*$//')
          case "$line" in
            '+'*) printf '%s\t%s\n' "$key" "$major" >> "$addf" ;;
            '-'*) printf '%s\t%s\n' "$key" "$major" >> "$rmf"  ;;
          esac
          ;;
        *) : ;;
      esac
    done <<< "$patch"
    i=$((i + 1))
  done
  # (e) mind. je eine +/- Zeile; (c)+(d) Multiset (key,major): added == removed
  if [ -s "$addf" ] && [ -s "$rmf" ] && diff <(sort "$addf") <(sort "$rmf") >/dev/null; then
    command rm -f "$addf" "$rmf"; echo true
  else
    command rm -f "$addf" "$rmf"; echo false
  fi
}

# --- IDENTISCH zur Inline-Logik in gate-2-codex.yml (Step "Resolve PR HEAD") --
# Im Workflow laedt lade_diff() die Diff-Dateien lazy via gh api; hier ist
# FILES_JSON vor jedem Aufruf gesetzt, der gh-Zweig bleibt unbetreten.
lade_diff() {  # fuellt FILES_JSON (alle Diff-Dateien inkl. .patch) genau einmal
  local erwartet geladen
  if [ -z "${FILES_JSON:-}" ]; then
    FILES_JSON=$(gh api --paginate "/repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER/files" | jq -s '(add // [])')
    # Fail-closed (P1 Runde 2): der files-Endpunkt liefert hoechstens 3000
    # Eintraege — stimmt die Zahl nicht mit changed_files des PR ueberein,
    # ist der Diff unvollstaendig und darf NIE eine Exempt-Klasse belegen
    # (leeres Array laesst jede Diff-Pruefung scheitern).
    erwartet=$(printf '%s' "$PRJSON" | jq -r '.changed_files // -1')
    geladen=$(printf '%s' "$FILES_JSON" | jq 'length')
    if [ "$geladen" != "$erwartet" ]; then FILES_JSON='[]'; fi
  fi
}
alle_patches_vorhanden() {  # true, wenn der Diff >0 Dateien hat und JEDE einen Patch traegt
  local n ohne
  lade_diff
  n=$(printf '%s' "$FILES_JSON" | jq 'length')
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  [ "$n" -gt 0 ] || return 1
  # Fail-closed (P1 Runde 2): binaere oder zu grosse Dateien haben kein
  # .patch-Feld — ihr Inhalt ist unpruefbar, also keine Exempt-Klasse.
  ohne=$(printf '%s' "$FILES_JSON" | jq -r '[.[] | select((.patch // "") == "")] | length')
  [ "$ohne" = "0" ]
}
alle_dateien_unter() {  # $1=Pfad-Regex; true, wenn der Diff >0 Dateien hat und JEDE matcht
  local n bad
  lade_diff
  n=$(printf '%s' "$FILES_JSON" | jq 'length')
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  [ "$n" -gt 0 ] || return 1
  # Renames (P1 Runde 3): auch der ALTE Pfad muss die Grenze einhalten —
  # sonst schoebe ein status:renamed z.B. einen Workflow nach tasks/.
  bad=$(printf '%s' "$FILES_JSON" | jq -r --arg re "$1" '[.[] | select( ((.filename|test($re))|not) or (((.previous_filename // .filename)|test($re))|not) )] | length')
  [ "$bad" = "0" ]
}
patch_zeilen_nur() {  # $1=Zeilen-Regex; true, wenn es +/- Patchzeilen gibt und JEDE matcht
  local lines
  lade_diff
  lines=$(printf '%s' "$FILES_JSON" | jq -r '.[].patch // ""' | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)' || true)
  [ -n "$lines" ] || return 1
  ! printf '%s\n' "$lines" | grep -qvE "$1"
}

# Eingabe: $1=AUTHOR $2=BRANCH $3=TITLE; FILES_JSON als globale Variable (JSON-
# Array von Objekten mit .filename/.patch). Ausgabe: echo true|false.
klassifiziere() {
  local AUTHOR="$1" BRANCH="$2" TITLE="$3" BOT_EXEMPT=false
  case "$AUTHOR" in
    'dependabot[bot]')
      # (1) Dependabot arbeitet ausschliesslich auf eigenen Branches.
      case "$BRANCH" in dependabot/*) BOT_EXEMPT=true ;; esac ;;
    'pb-llc-auto-fix-bot[bot]')
      if printf '%s\n' "$BRANCH" | grep -qE '^chore/pin-bump-[A-Za-z0-9._-]+-v[0-9]+\.[0-9]+\.[0-9]+$' \
         && printf '%s\n' "$TITLE" | grep -qiE 'pin|bump'; then
        if alle_patches_vorhanden \
           && [ "$(printf '%s' "$FILES_JSON" | is_pin_bump)" = "true" ]; then
          BOT_EXEMPT=true
        fi
      elif [ "$BRANCH" = "chore/plugin-pin-bump" ] \
         && printf '%s\n' "$TITLE" | grep -qE '^chore\(plugin\): bump pin to v[0-9]+\.[0-9]+\.[0-9]+$' \
         && alle_dateien_unter '^CLAUDE\.md$' \
         && alle_patches_vorhanden \
         && patch_zeilen_nur '^[+-]plugin_version: "[0-9]+\.[0-9]+\.[0-9]+"$'; then
        BOT_EXEMPT=true
      elif printf '%s\n' "$BRANCH" | grep -qE '^bot/publish-specs-[0-9]+$' \
         && alle_dateien_unter '^llc-checkliste-deploy/specs/'; then
        BOT_EXEMPT=true
      elif printf '%s\n' "$BRANCH" | grep -qE '^chore/cloud-dispatch-[0-9]{8}-[0-9]{6}$' \
         && alle_dateien_unter '^tasks/'; then
        BOT_EXEMPT=true
      fi ;;
  esac
  echo "$BOT_EXEMPT"
}

dateien() { # args: Pfade → setzt FILES_JSON auf ein Array aus {filename}-Objekten
  FILES_JSON=$(printf '%s\n' "$@" | jq -R '{filename:.}' | jq -s '.')
}
datei_mit_patch() { # $1=Pfad $2=Patch → setzt FILES_JSON auf [{filename,patch}]
  FILES_JSON=$(jq -n --arg f "$1" --arg p "$2" '[{filename:$f, patch:$p}]')
}

PASS=0; FAIL=0
check() { # $1=name $2=expected $3=actual
  if [ "$2" = "$3" ]; then
    echo "  ok   [$1] → exempt=$3"; PASS=$((PASS+1))
  else
    echo "  FAIL [$1] → got exempt=$3, want exempt=$2"; FAIL=$((FAIL+1))
  fi
}

BOT='pb-llc-auto-fix-bot[bot]'
USESLINE='    uses: Paul-Brandenburg-LLC/llc-workflow-templates/.github/workflows'
echo "=== gate-2 bot-exempt Klassen-Gate (v1.8.0) ==="

# K1) Dependabot auf eigenem Branch → exempt
FILES_JSON='[]'
V=$(klassifiziere 'dependabot[bot]' 'dependabot/npm_and_yarn/lodash-4.17.21' 'chore(deps): bump lodash'); check "dependabot-own-branch" true "$V"

# K2) Dependabot-Autor auf fremdem Branch → KEIN exempt (Autor allein reicht nicht mehr)
V=$(klassifiziere 'dependabot[bot]' 'feature/anything' 'chore(deps): bump lodash'); check "dependabot-foreign-branch→blocks" false "$V"

# K3) Workflow-Pin-Welle: Branch + Titel + Diff ist reiner Tag-Bump → exempt
P=$(printf '@@ -1,3 +1,3 @@ jobs:\n bridge:\n-%s/gate-2-codex.yml@v1.7.1\n+%s/gate-2-codex.yml@v1.8.0\n   secrets: inherit\n' "$USESLINE" "$USESLINE")
datei_mit_patch '.github/workflows/gate-2-codex.yml' "$P"
V=$(klassifiziere "$BOT" 'chore/pin-bump-gate-2-codex-v1.8.0' 'chore(ci): bump gate-2-codex pin to v1.8.0'); check "workflow-pin-bump-clean-diff" true "$V"

# K3b) Pin-Bump-Branch, aber Diff traegt echten Workflow-Code → KEIN exempt (P1-Fix Runde 1)
P=$(printf '@@ -1,3 +1,3 @@\n-%s/gate-2-codex.yml@v1.7.1\n+%s/gate-2-codex.yml@v1.8.0\n-  timeout-minutes: 5\n+  timeout-minutes: 60\n' "$USESLINE" "$USESLINE")
datei_mit_patch '.github/workflows/gate-2-codex.yml' "$P"
V=$(klassifiziere "$BOT" 'chore/pin-bump-gate-2-codex-v1.8.0' 'chore(ci): bump gate-2-codex pin to v1.8.0'); check "workflow-pin-bump-code-smuggle→blocks" false "$V"

# K3c) Pin-Bump-Branch, Diff-Datei ausserhalb .github/workflows/ → KEIN exempt
dateien 'deploy/hook.sh'
V=$(klassifiziere "$BOT" 'chore/pin-bump-gate-2-codex-v1.8.0' 'chore(ci): bump gate-2-codex pin to v1.8.0'); check "workflow-pin-bump-foreign-file→blocks" false "$V"

# K3e) Composite-Action-Pin-Welle (pre-pr-quartett, Step-Ebene mit Listen-'- ') → exempt
ACTLINE='      - uses: Paul-Brandenburg-LLC/llc-workflow-templates/.github/actions/pre-pr-quartett'
P=$(printf '@@ -18,3 +18,3 @@ steps:\n-%s@v1.7.0\n+%s@v1.7.1\n' "$ACTLINE" "$ACTLINE")
datei_mit_patch '.github/workflows/pre-pr-quartett.yml' "$P"
V=$(klassifiziere "$BOT" 'chore/pin-bump-pre-pr-quartett-v1.7.1' 'chore(ci): bump pre-pr-quartett pin to v1.7.1'); check "composite-action-pin-bump" true "$V"

# K3d) Pin-Bump-Branch, eine Datei OHNE Patch (binaer/zu gross) → KEIN exempt (fail-closed)
FILES_JSON=$(jq -n --arg p "$(printf '@@ -1,2 +1,2 @@\n-%s/gate-2-codex.yml@v1.7.1\n+%s/gate-2-codex.yml@v1.8.0\n' "$USESLINE" "$USESLINE")" '[{filename:".github/workflows/gate-2-codex.yml", patch:$p},{filename:".github/workflows/blob.yml"}]')
V=$(klassifiziere "$BOT" 'chore/pin-bump-gate-2-codex-v1.8.0' 'chore(ci): bump gate-2-codex pin to v1.8.0'); check "workflow-pin-bump-patchless-file→blocks" false "$V"

# K4) auto-sync-Branch (echter Workflow-Diff) → KEIN exempt
FILES_JSON='[]'
V=$(klassifiziere "$BOT" 'chore/auto-sync-gate-2-codex-v1.8.0' 'chore(ci): sync gate-2-codex to v1.8.0'); check "auto-sync→blocks" false "$V"

# K5) seed-Branch (neuer Caller) → KEIN exempt
V=$(klassifiziere "$BOT" 'chore/seed-gate-2-codex-caller-v1.8.0' 'chore(ci): seed gate-2-codex caller'); check "seed-caller→blocks" false "$V"

# K6) Plugin-Pin-Welle: Branch + Titel + Diff nur plugin_version in CLAUDE.md → exempt
# (Patch-Form gemessen an freiestimme-net-site#124)
P=$(printf '@@ -1,7 +1,7 @@\n ---\n standard_version: "7.5.0"\n-plugin_version: "1.34.0"\n+plugin_version: "1.35.0"\n prepush_stack: "static"\n')
datei_mit_patch 'CLAUDE.md' "$P"
V=$(klassifiziere "$BOT" 'chore/plugin-pin-bump' 'chore(plugin): bump pin to v1.35.0'); check "plugin-pin-bump-clean-diff" true "$V"

# K6b) Plugin-Pin-Branch, Patch dreht MEHR als die plugin_version-Zeile → KEIN exempt
P=$(printf '@@ -1,7 +1,7 @@\n ---\n-plugin_version: "1.34.0"\n+plugin_version: "1.35.0"\n-tier: 3\n+tier: 0\n')
datei_mit_patch 'CLAUDE.md' "$P"
V=$(klassifiziere "$BOT" 'chore/plugin-pin-bump' 'chore(plugin): bump pin to v1.35.0'); check "plugin-pin-extra-lines→blocks" false "$V"

# K6c) Plugin-Pin-Branch mit zweiter Datei im Diff → KEIN exempt
FILES_JSON=$(jq -n '[{filename:"CLAUDE.md", patch:"@@ -1,2 +1,2 @@\n-plugin_version: \"1.34.0\"\n+plugin_version: \"1.35.0\""},{filename:"src/app.js", patch:""}]')
V=$(klassifiziere "$BOT" 'chore/plugin-pin-bump' 'chore(plugin): bump pin to v1.35.0'); check "plugin-pin-second-file→blocks" false "$V"

# K6d) Plugin-Pin-Branch, CLAUDE.md OHNE Patch-Feld → KEIN exempt (fail-closed)
FILES_JSON=$(jq -n '[{filename:"CLAUDE.md"}]')
V=$(klassifiziere "$BOT" 'chore/plugin-pin-bump' 'chore(plugin): bump pin to v1.35.0'); check "plugin-pin-patchless→blocks" false "$V"

# K7) Plugin-Pin-Branch mit abweichendem Titel → KEIN exempt (Titel-Gegenprobe)
V=$(klassifiziere "$BOT" 'chore/plugin-pin-bump' 'fix: irgendwas anderes'); check "plugin-pin-wrong-title→blocks" false "$V"

# K8) Spec-Publish: Diff NUR unter llc-checkliste-deploy/specs/ → exempt
dateien 'llc-checkliste-deploy/specs/ENTWICKLUNG.html' 'llc-checkliste-deploy/specs/CHANGELOG.html'
V=$(klassifiziere "$BOT" 'bot/publish-specs-33158225929' 'docs(specs): auto-publish from standards@7eaa4a1'); check "publish-specs-clean" true "$V"

# K9) Spec-Publish mit Datei AUSSERHALB specs/ → KEIN exempt (Schmuggel-Schutz)
dateien 'llc-checkliste-deploy/specs/ENTWICKLUNG.html' 'app/index.php'
V=$(klassifiziere "$BOT" 'bot/publish-specs-33158225929' 'docs(specs): auto-publish from standards@7eaa4a1'); check "publish-specs-smuggle→blocks" false "$V"

# K10) Spec-Publish mit LEEREM Diff → KEIN exempt (0 Dateien ist keine Werkslinie)
FILES_JSON='[]'
V=$(klassifiziere "$BOT" 'bot/publish-specs-33158225929' 'docs(specs): auto-publish'); check "publish-specs-empty-diff→blocks" false "$V"

# K11) Cloud-Dispatch: Diff NUR unter tasks/ → exempt (gemessen an llc-ops-backlog#1100/#1101)
dateien 'tasks/0016-service-worker-fuer-offline-cache.yml' 'tasks/0568-gitleaks-allowlists-bekannte-fps.yml'
V=$(klassifiziere "$BOT" 'chore/cloud-dispatch-20260828-114758' 'chore(cloud-dispatch): 2 Task(s) dispatcht'); check "cloud-dispatch-clean" true "$V"

# K11b) Cloud-Dispatch: Rename VON ausserhalb nach tasks/ → KEIN exempt (P1 Runde 3)
FILES_JSON=$(jq -n '[{filename:"tasks/deploy.yml", previous_filename:".github/workflows/deploy.yml", status:"renamed"}]')
V=$(klassifiziere "$BOT" 'chore/cloud-dispatch-20260828-114758' 'chore(cloud-dispatch): 1 Task(s) dispatcht'); check "cloud-dispatch-rename-smuggle→blocks" false "$V"

# K11c) Spec-Publish: Rename INNERHALB specs/ bleibt erlaubt (Grenze haelt beidseitig)
FILES_JSON=$(jq -n '[{filename:"llc-checkliste-deploy/specs/NEU.html", previous_filename:"llc-checkliste-deploy/specs/ALT.html", status:"renamed"}]')
V=$(klassifiziere "$BOT" 'bot/publish-specs-33158225929' 'docs(specs): auto-publish'); check "publish-specs-rename-within" true "$V"

# K12) Cloud-Dispatch mit Workflow-Datei im Diff → KEIN exempt
dateien 'tasks/0999-x.yml' '.github/workflows/deploy.yml'
V=$(klassifiziere "$BOT" 'chore/cloud-dispatch-20260828-114758' 'chore(cloud-dispatch): 1 Task(s) dispatcht'); check "cloud-dispatch-smuggle→blocks" false "$V"

# K13) Cloud-Dispatch mit falschem Branch-Zeitstempel-Format → KEIN exempt
dateien 'tasks/0999-x.yml'
V=$(klassifiziere "$BOT" 'chore/cloud-dispatch-extra' 'chore(cloud-dispatch): 1 Task(s) dispatcht'); check "cloud-dispatch-bad-branch→blocks" false "$V"

# K14) Fremder Autor, egal welcher Branch → KEIN exempt
FILES_JSON='[]'
V=$(klassifiziere 'irgendwer' 'chore/plugin-pin-bump' 'chore(plugin): bump pin to v1.35.0'); check "foreign-author→blocks" false "$V"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ] || exit 1
