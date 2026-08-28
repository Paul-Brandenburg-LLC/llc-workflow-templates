#!/usr/bin/env bash
# Offline-Testharness fuer das bot-exempt-KLASSEN-Gate in gate-2-codex.yml
# (Step "Resolve PR HEAD", seit v1.8.0). Repliziert die Klassifikation 1:1;
# der GitHub-Zugriff (PR-Metadaten + Diff-Dateien) ist per Parametern bzw.
# vorbefuelltem FILES_JSON gestubbt. Kein GitHub, kein Netzwerk.
# exit != 0 bei jeder fehlgeschlagenen Assertion → CI-Gate 'checks' schlaegt fehl.
set -uo pipefail

# --- IDENTISCH zur Inline-Logik in gate-2-codex.yml (Step "Resolve PR HEAD") --
# Im Workflow laedt alle_dateien_unter() die Diff-Dateien lazy via gh api;
# hier ist FILES_JSON vor dem Aufruf gesetzt, der gh-Zweig bleibt unbetreten.
alle_dateien_unter() {  # $1=Pfad-Regex; true, wenn der Diff >0 Dateien hat und JEDE matcht
  local n bad
  if [ -z "${FILES_JSON:-}" ]; then
    FILES_JSON=$(gh api --paginate "/repos/$GITHUB_REPOSITORY/pulls/$PR_NUMBER/files" | jq -s '(add // [])')
  fi
  n=$(printf '%s' "$FILES_JSON" | jq 'length')
  case "$n" in ''|*[!0-9]*) return 1 ;; esac
  [ "$n" -gt 0 ] || return 1
  bad=$(printf '%s' "$FILES_JSON" | jq -r --arg re "$1" '[.[] | select((.filename|test($re))|not)] | length')
  [ "$bad" = "0" ]
}

# Eingabe: $1=AUTHOR $2=BRANCH $3=TITLE; FILES_JSON als env-Variable (JSON-Array
# von Objekten mit .filename). Ausgabe: echo true|false.
klassifiziere() {
  local AUTHOR="$1" BRANCH="$2" TITLE="$3" BOT_EXEMPT=false
  case "$AUTHOR" in
    'dependabot[bot]')
      case "$BRANCH" in dependabot/*) BOT_EXEMPT=true ;; esac ;;
    'pb-llc-auto-fix-bot[bot]')
      if printf '%s\n' "$BRANCH" | grep -qE '^chore/pin-bump-[A-Za-z0-9._-]+-v[0-9]+\.[0-9]+\.[0-9]+$' \
         && printf '%s\n' "$TITLE" | grep -qiE 'pin|bump'; then
        BOT_EXEMPT=true
      elif [ "$BRANCH" = "chore/plugin-pin-bump" ] \
         && printf '%s\n' "$TITLE" | grep -qE '^chore\(plugin\): bump pin to v[0-9]+\.[0-9]+\.[0-9]+$'; then
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

PASS=0; FAIL=0
check() { # $1=name $2=expected $3=actual
  if [ "$2" = "$3" ]; then
    echo "  ok   [$1] → exempt=$3"; PASS=$((PASS+1))
  else
    echo "  FAIL [$1] → got exempt=$3, want exempt=$2"; FAIL=$((FAIL+1))
  fi
}

BOT='pb-llc-auto-fix-bot[bot]'
echo "=== gate-2 bot-exempt Klassen-Gate (v1.8.0) ==="

# K1) Dependabot auf eigenem Branch → exempt
FILES_JSON='[]'
V=$(klassifiziere 'dependabot[bot]' 'dependabot/npm_and_yarn/lodash-4.17.21' 'chore(deps): bump lodash'); check "dependabot-own-branch" true "$V"

# K2) Dependabot-Autor auf fremdem Branch → KEIN exempt (Autor allein reicht nicht mehr)
V=$(klassifiziere 'dependabot[bot]' 'feature/anything' 'chore(deps): bump lodash'); check "dependabot-foreign-branch→blocks" false "$V"

# K3) Workflow-Pin-Welle (propagate-templates: chore/pin-bump-<tpl>-vX.Y.Z) → exempt
V=$(klassifiziere "$BOT" 'chore/pin-bump-gate-2-codex-v1.8.0' 'chore(ci): bump gate-2-codex pin to v1.8.0'); check "workflow-pin-bump" true "$V"

# K4) auto-sync-Branch (echter Workflow-Diff) → KEIN exempt
V=$(klassifiziere "$BOT" 'chore/auto-sync-gate-2-codex-v1.8.0' 'chore(ci): sync gate-2-codex to v1.8.0'); check "auto-sync→blocks" false "$V"

# K5) seed-Branch (neuer Caller) → KEIN exempt
V=$(klassifiziere "$BOT" 'chore/seed-gate-2-codex-caller-v1.8.0' 'chore(ci): seed gate-2-codex caller'); check "seed-caller→blocks" false "$V"

# K6) Plugin-Pin-Welle: fester Branch + exakte Titelform → exempt
V=$(klassifiziere "$BOT" 'chore/plugin-pin-bump' 'chore(plugin): bump pin to v1.35.0'); check "plugin-pin-bump" true "$V"

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
