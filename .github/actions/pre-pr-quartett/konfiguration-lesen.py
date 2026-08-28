#!/usr/bin/env python3
"""Liest die CLAUDE.md-Frontmatter, prueft sie hart und gibt sie als JSON aus.

PB LLC: Entwicklung §3.b.2 v7.6.1 — S-1 und S-2 (llc-ops-backlog#1096).

Bis v7.6.0 setzte die Action bei fehlender CLAUDE.md, fehlender Frontmatter
oder unlesbarem Wert still Tier 0, uebersprang damit Pruefung 2a vollstaendig
und meldete trotzdem Erfolg. Das Gate war also genau dort blind, wo der
Angriffspfad liegt: bei dem PR, der die Konfigurationsdatei entfernt — und
derselbe PR haette `AGENTS.md` und `gate-2-codex.yml` gleich mitnehmen koennen,
also genau die Dateien, die 2a-(i)/(ii) pruefen sollen.

Zweiter Weg, gleicher Ausgang: der Eingabewert `tier: auto` uebernahm den
PR-kontrollierten Wert ohne Vergleich. Ein PR stufte damit ein Tier-1-Repo auf
Tier 4 herab und liess sich unter den schwaecheren Regeln pruefen, die er sich
selbst gegeben hatte.

Diese Fassung bricht in beiden Faellen ab (Exit 1) und gibt die geprueften
Werte als JSON auf stdout — die Folgeschritte lesen NUR dieses JSON, damit es
fuer die Frontmatter genau eine Lesart gibt und nicht zwei, die auseinander
laufen koennen.

Env:
  KOPF_DATEI        Pfad zur CLAUDE.md des PR-Stands (Pflicht)
  BASIS_DATEI       Pfad zur CLAUDE.md des Ziel-Branch-Stands (optional)
  BASIS_HAT_DATEI   "1", wenn der Ziel-Branch eine CLAUDE.md traegt
  TIER_EINGABE      Eingabewert `tier` der Action (auto|1|2|3|4)
"""
import json
import os
import sys

try:
    import yaml
except ImportError:                                    # pragma: no cover
    # Kein pip-Ausweg: auf Ubuntu 24.04 bricht ein unqualifiziertes
    # "pip install" an PEP 668 ab (externally-managed-environment).
    # Fehlt das Modul, wird dieser Schritt rot statt still ungenau.
    print("::error::PyYAML fehlt auf diesem Runner — die Frontmatter laesst "
          "sich nicht sicher lesen", file=sys.stderr)
    sys.exit(1)

KANONISCHE_TIER = ("1", "2", "3", "4")


def frontmatter(pfad):
    """YAML-Frontmatter als dict, sonst (None, Grund)."""
    # newline="" und split("\n"): sonst schluckt Python das \r einer CRLF-Datei,
    # und "---\r\n" saehe hier aus wie ein Trenner. Wer die Frontmatter
    # grosszuegiger liest als die Pruefung, die auf ihr aufsetzt, erzeugt
    # genau die Luecke, die dieses Skript schliessen soll.
    try:
        with open(pfad, encoding="utf-8", newline="") as datei:
            zeilen = datei.read().split("\n")
    except OSError as fehler:
        return None, "nicht lesbar (%s)" % fehler
    if not zeilen or zeilen[0] != "---":
        return None, "keine YAML-Frontmatter (erste Zeile ist nicht genau '---')"
    ende = next((i for i in range(1, len(zeilen)) if zeilen[i] == "---"), None)
    if ende is None:
        return None, "Frontmatter ist nicht geschlossen"
    # BaseLoader statt safe_load: er liefert jeden Skalar als Text. safe_load
    # wuerde "04", "+4" oder "0x4" vorher zu 4 normalisieren — die Pruefung
    # unten traefe dann keinen ihrer kanonischen Werte mehr, obwohl sie es
    # sollte, oder umgekehrt eine Schreibweise durchlassen, die andere
    # Leser (yq, awk) anders sehen.
    try:
        daten = yaml.load("\n".join(zeilen[1:ende]), Loader=yaml.BaseLoader)
    except yaml.YAMLError as fehler:
        return None, "Frontmatter ist kein gueltiges YAML: %s" % fehler
    if not isinstance(daten, dict):
        return None, "Frontmatter ist keine Zuordnung"
    return daten, None


def tier_von(daten):
    """Kanonisches Tier 1-4 als int, sonst (None, Grund)."""
    if "tier" not in daten:
        return None, "Schluessel 'tier' fehlt"
    roh = daten["tier"]
    if not isinstance(roh, str) or roh not in KANONISCHE_TIER:
        return None, ("tier ist nicht kanonisch (erwartet genau 1, 2, 3 oder 4), "
                      "gelesen: %r" % (roh,))
    return int(roh), None


def fehler(text):
    print("::error::%s" % text, file=sys.stderr)
    sys.exit(1)


def main():
    kopf_datei = os.environ.get("KOPF_DATEI", "CLAUDE.md")
    tier_eingabe = os.environ.get("TIER_EINGABE", "auto").strip() or "auto"

    if not os.path.isfile(kopf_datei):
        # S-1: das ist der Kern des Befundes. Frueher: Tier 0, exit 0.
        fehler("CLAUDE.md fehlt — das Pre-PR-Quartett kann Pruefung 2a nicht "
               "ausfuehren. Bis v7.6.0 meldete es hier still Erfolg; genau "
               "dieser PR haette AGENTS.md und gate-2-codex.yml mitnehmen "
               "koennen. Der Weg ist: CLAUDE.md mit Frontmatter nachtragen.")

    kopf, grund = frontmatter(kopf_datei)
    if kopf is None:
        fehler("CLAUDE.md: %s — das Pre-PR-Quartett wuerde Pruefung 2a still "
               "ueberspringen und trotzdem gruen melden" % grund)

    if tier_eingabe == "auto":
        tier, grund = tier_von(kopf)
        if tier is None:
            fehler("CLAUDE.md: %s" % grund)

        # S-2: Herabstufung gegen den Ziel-Branch pruefen. Traegt die Basis
        # keine CLAUDE.md, gibt es kein Tier, das herabgestuft werden koennte
        # — nur dann darf ohne Vergleich weitergegangen werden. Ist die Datei
        # da, aber unlesbar, wird abgebrochen: ein unlesbarer Vergleichsstand
        # ist kein fehlender, und "nichts zu vergleichen" waere hier genau die
        # Ausrede, mit der eine Herabstufung durchginge.
        if os.environ.get("BASIS_HAT_DATEI") == "1":
            basis_datei = os.environ.get("BASIS_DATEI", "")
            basis, grund = frontmatter(basis_datei)
            if basis is None:
                fehler("CLAUDE.md im Ziel-Branch: %s — ohne lesbaren "
                       "Vergleichsstand kann eine Tier-Herabstufung nicht "
                       "ausgeschlossen werden" % grund)
            tier_basis, grund = tier_von(basis)
            if tier_basis is None:
                fehler("CLAUDE.md im Ziel-Branch: %s — ohne lesbares "
                       "Vergleichs-Tier kann eine Herabstufung nicht "
                       "ausgeschlossen werden" % grund)
            if tier > tier_basis:
                fehler("Tier-Herabstufung: Ziel-Branch tier=%d, dieser PR "
                       "tier=%d. Die hoehere Tier-Zahl prueft schwaecher — das "
                       "Quartett liefe unter den Regeln des PRs statt unter "
                       "denen des Repos." % (tier_basis, tier))
            print("✓ CLAUDE.md vorhanden, tier=%d (Ziel-Branch tier=%d)"
                  % (tier, tier_basis), file=sys.stderr)
        else:
            print("::notice::Der Ziel-Branch traegt keine CLAUDE.md — kein "
                  "Tier zum Vergleichen, nur der PR-Stand geprueft (tier=%d)"
                  % tier, file=sys.stderr)
    else:
        # Ein ausdruecklich gesetztes Tier ist nicht PR-kontrolliert, es gibt
        # hier also nichts herabzustufen — unbrauchbar darf es trotzdem nicht
        # sein, sonst faellt 2a stumm durch alle case-Zweige.
        if tier_eingabe not in KANONISCHE_TIER:
            fehler("Eingabe 'tier' ist nicht kanonisch (erwartet auto, 1, 2, 3 "
                   "oder 4), gelesen: %r" % tier_eingabe)
        tier = int(tier_eingabe)
        print("✓ tier=%d aus der Action-Eingabe (kein Basis-Vergleich noetig)"
              % tier, file=sys.stderr)

    # Die geprueften Werte als EINE Wahrheit fuer die Folgeschritte. Sie lesen
    # ausschliesslich dieses JSON und nie erneut die Datei — zwei Lesarten
    # derselben Frontmatter waren die Wurzel des ganzen Vorgangs.
    json.dump({"tier": tier, "frontmatter": kopf}, sys.stdout)
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
