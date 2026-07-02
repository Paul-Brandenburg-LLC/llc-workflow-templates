#!/usr/bin/env bash
# green-rollback core — PB LLC: Entwicklung §8.6 / v7.0.0 Anhang E.5.2.
#
# Audit-Befund (2026-07-02): Auto-Rollback dispatchte den Commit-SHA des letzten
# gruenen Runs als `ref` → `gh workflow run -r <40-hex>` liefert HTTP 422 (ref muss
# Branch ODER TAG sein, kein blanker Commit-SHA); ein angehaengter true-Fallback schluckte den Fehler.
#
# Fix: Erfolgreiche Deploys werden als unveraenderliches Tag `green/<sha>` markiert
# und der bewegliche Zeiger `green/latest` nachgezogen. Der Rollback dispatcht
# `-r green/latest` — ein echter TAG-Ref → strukturell kein 422 mehr. Ohne Fehler-Schlucker.
#
# Env: MODE(mark|rollback) REPO GH_TOKEN [SHA] [DEPLOY_WF]
set -euo pipefail
: "${MODE:?MODE fehlt (mark|rollback)}"
: "${REPO:?REPO fehlt}"
OUT="${GITHUB_OUTPUT:-/dev/stdout}"

ref_exists() { gh api "/repos/$REPO/git/refs/tags/$1" >/dev/null 2>&1; }

case "$MODE" in
  mark)
    : "${SHA:?SHA fehlt (mark)}"
    IMMUT="green/${SHA}"
    # 1) Unveraenderliches Historien-Tag green/<sha> (idempotent — nie ueberschreiben).
    if ref_exists "$IMMUT"; then
      echo "::notice::${IMMUT} existiert bereits (immutable) — unveraendert"
    else
      gh api -X POST "/repos/$REPO/git/refs" -f "ref=refs/tags/${IMMUT}" -f "sha=$SHA" >/dev/null
      echo "::notice::green-Tag erstellt: ${IMMUT}"
    fi
    # 2) Beweglicher Zeiger green/latest → sha (nur bei bestandenem §8.6-Effect-Check aufrufen!).
    if ref_exists "green/latest"; then
      gh api -X PATCH "/repos/$REPO/git/refs/tags/green/latest" -f "sha=$SHA" -F force=true >/dev/null
    else
      gh api -X POST "/repos/$REPO/git/refs" -f "ref=refs/tags/green/latest" -f "sha=$SHA" >/dev/null
    fi
    echo "::notice::green/latest -> ${SHA}"
    echo "green_ref=${IMMUT}" >> "$OUT"
    ;;

  rollback)
    DEPLOY_WF="${DEPLOY_WF:-deploy.yml}"
    if ! ref_exists "green/latest"; then
      echo "::error::Kein green/latest-Tag vorhanden — kein Auto-Rollback moeglich. Manuelle Intervention noetig."
      exit 1
    fi
    ROLLBACK_REF="green/latest"
    echo "::warning::Rollback: re-deploy von TAG '${ROLLBACK_REF}' (Tag-Ref, kein Commit-SHA -> kein 422)."
    echo "green_ref=${ROLLBACK_REF}" >> "$OUT"
    # Ohne Fehler-Schlucker: ein fehlgeschlagener Rollback-Dispatch MUSS den Job rot machen (Audit-Fix).
    gh workflow run "$DEPLOY_WF" -r "$ROLLBACK_REF" -f ref="$ROLLBACK_REF" -R "$REPO"
    echo "::notice::Rollback-Deploy von ${ROLLBACK_REF} dispatcht."
    ;;

  *)
    echo "::error::Unbekannter MODE '$MODE' (erwartet: mark|rollback)"; exit 1 ;;
esac
