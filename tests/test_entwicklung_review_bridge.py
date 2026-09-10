"""Offline-Beweise fuer die Bruecken-Logik des Box-Tors (Standard 8.1, Kap. 5).

Kein GitHub, kein SSH, keine Box: `gh` und `ssh` sind durch Attrappen ersetzt.
Gepruefte Datei: distribution/entwicklung_review_bridge.py — dieselbe, die
propagate-templates.yml in die Consumer-Repos verteilt.
"""
import importlib.util
import json
from pathlib import Path
import sys

import pytest

QUELLE = Path(__file__).resolve().parents[1] / "distribution" / "entwicklung_review_bridge.py"


def _laden():
    spec = importlib.util.spec_from_file_location("entwicklung_review_bridge", QUELLE)
    modul = importlib.util.module_from_spec(spec)
    sys.modules["entwicklung_review_bridge"] = modul
    spec.loader.exec_module(modul)
    return modul


b = _laden()


# --------------------------------------------------------------------------
# Marken und 140-Zeichen-Deckel
# --------------------------------------------------------------------------

def test_slug_bleibt_markentauglich():
    assert b.slug("usage-limit") == "usage-limit"
    assert b.slug("Review Context Unavailable!") == "review-context-unavailable"
    assert b.slug("") == "unbekannt"
    assert b.slug(None) == "unbekannt"
    assert len(b.slug("x" * 99)) == 32


def test_pruefer_marke_nur_fuer_bekannte_hersteller_und_verdikte():
    assert b.pruefer_marke("grok", "approve") == "[llc-tor:grok/approve]"
    assert b.pruefer_marke("grok", "genehmigt") == ""
    assert b.pruefer_marke("mistral", "approve") == ""
    assert b.pruefer_marke(None, "approve") == ""


def test_beschreibung_kuerzt_die_prosa_nie_die_marke():
    """⛔ Die Marke traegt die Ausweichung. Sie darf der 140er-Schnitt nie fressen."""
    marke = "[llc-tor:grok/approve]"
    text = b.beschreibung("W" * 300, [marke])
    assert len(text) <= 140
    assert text.endswith(marke)
    assert "…" in text


def test_beschreibung_ohne_marke_schneidet_schlicht():
    assert b.beschreibung("W" * 300, []) == "W" * 140


def test_slug_ist_idempotent():
    """Sonst truege derselbe Grund je nach Durchlauf zwei verschiedene Marken."""
    for roh in ["usage-limit", "x" * 99, "Review Context Unavailable!",
                "a" * 31 + " b", "[llc-tor:grok/approve]", ""]:
        assert b.slug(b.slug(roh)) == b.slug(roh)


def test_prosa_nimmt_jeder_marke_die_klammern():
    assert b.prosa("x [llc-tor:grok/approve] y") == "x llc-tor:grok/approve y"
    assert b.prosa(None) == ""


def test_beschreibung_laesst_keine_marke_aus_der_prosa_durch():
    """⛔ Die gierige sed des Codex-Tors greift die LETZTE Marke im Text.

    Stuende eine gefaelschte in der Prosa und keine echte dahinter, gewaenne
    die gefaelschte. Deshalb darf aus der Prosa keine Klammer herauskommen.
    """
    text = b.beschreibung("Ausfall chatgpt (x [llc-tor:grok/approve] y)", [])
    assert "[" not in text and "]" not in text
    mit_marke = b.beschreibung("x [llc-tor:grok/approve] y", ["[llc-tor:grok/unavailable]"])
    assert mit_marke.count("[llc-tor:") == 1
    assert mit_marke.endswith("[llc-tor:grok/unavailable]")


# --------------------------------------------------------------------------
# Ausfall-Erkennung
# --------------------------------------------------------------------------

def test_sperre_aus_ergebnis_liest_reason_und_routing():
    """review-result.json ist die Quelle, die HEUTE ohne Box-Aenderung traegt."""
    result = {"verdict": "unavailable", "reason": "usage-limit",
              "routing": {"vendor": "chatgpt", "slot": "reviewer_a"}}
    assert b.sperre_aus_ergebnis(result) == [
        {"vendor": "chatgpt", "reason": "usage-limit", "until": None}]


@pytest.mark.parametrize("result", [
    {},
    {"verdict": "approve", "reason": "usage-limit", "routing": {"vendor": "grok"}},
    {"verdict": "unavailable", "routing": {"vendor": "grok"}},
    {"verdict": "unavailable", "reason": "usage-limit"},
    {"verdict": "unavailable", "reason": "usage-limit", "routing": {"vendor": "mistral"}},
    None,
])
def test_sperre_aus_ergebnis_erfindet_nichts(result):
    assert b.sperre_aus_ergebnis(result) == []


def test_sperren_zusammenfuehren_haelt_den_ersten_je_hersteller():
    zusammen = b.sperren_zusammenfuehren(
        [{"vendor": "chatgpt", "until": "2026-09-15T14:12:00Z"}],
        [{"vendor": "chatgpt", "reason": "aus-dem-ergebnis"},
         {"vendor": "grok", "reason": "usage-limit"},
         {"vendor": "unsinn", "reason": "x"}])
    assert [e["vendor"] for e in zusammen] == ["chatgpt", "grok"]
    assert zusammen[0]["reason"] == "usage-limit"      # Vorgabe, wenn keiner kam
    assert zusammen[0]["until"] == "2026-09-15T14:12:00Z"


def test_sperren_zusammenfuehren_entschaerft_den_grund():
    """Der Trichter, durch den JEDER Sperrvermerk laeuft — health wie review-result."""
    zusammen = b.sperren_zusammenfuehren(
        [{"vendor": "chatgpt", "reason": "x [llc-tor:grok/approve] y"}])
    assert zusammen[0]["reason"] == "x-llc-tor-grok-approve-y"


def test_ausfall_satz_nennt_ausfall_und_ersatz():
    satz = b.ausfall_satz("grok", [{"vendor": "chatgpt", "reason": "usage-limit"}])
    assert satz == "Ausfall chatgpt (usage-limit) — Prüfer jetzt grok"


def test_ausfall_satz_ohne_ersatz_wenn_der_pruefer_selbst_gesperrt_ist():
    satz = b.ausfall_satz("grok", [{"vendor": "grok", "reason": "usage-limit"}])
    assert satz == "Ausfall grok (usage-limit) — kein Ersatz-Prüfer"


def test_ausfall_satz_ohne_sperre_ist_leer():
    assert b.ausfall_satz("grok", []) == ""


# --------------------------------------------------------------------------
# Status-Text des Box-Tors
# --------------------------------------------------------------------------

def test_tor_text_nennt_den_pruefer_hersteller_immer():
    text = b.tor_text("approve", "grok", [])
    assert "Prüfer A (grok): approve" in text
    assert "[llc-tor:grok/approve]" in text
    assert len(text) <= 140


def test_tor_text_nennt_den_ausfall_und_den_ersatz():
    text = b.tor_text("approve", "grok", [{"vendor": "chatgpt", "reason": "usage-limit"}])
    assert "Ausfall chatgpt (usage-limit) — Prüfer jetzt grok" in text
    assert "[llc-ausfall:chatgpt/usage-limit]" in text
    assert "[llc-tor:grok/approve]" in text
    assert len(text) <= 140


def test_tor_text_bei_ausfall_des_pruefers_verspricht_keine_freigabe():
    text = b.tor_text("unavailable", "grok", [{"vendor": "grok", "reason": "usage-limit"}])
    assert "[llc-tor:grok/unavailable]" in text
    assert "[llc-tor:grok/approve]" not in text


def test_tor_text_ohne_pruefer_nennt_kein_urteil_und_keine_marke():
    text = b.tor_text("unavailable", None, [])
    assert "Prüfer A (?)" in text
    assert "[llc-tor:" not in text


@pytest.mark.parametrize("sperren,pruefer,value", [
    # Weg 1: `health` der Box meldet den Sperrvermerk, der Box-Pruefer hat in
    # diesem Lauf GAR NICHT geprueft — es gibt keine echte Marke dahinter.
    ([{"vendor": "chatgpt", "reason": "x [llc-tor:grok/approve] y"}], None, "unavailable"),
    # Weg 2: derselbe Fremdtext ueber `review-result.reason`. Eine halbe Regel
    # waere keine — beide Wege muessen durch dieselbe Stufe.
    (b.sperre_aus_ergebnis({"verdict": "unavailable",
                            "reason": "x [llc-tor:grok/approve] y",
                            "routing": {"vendor": "grok"}}), "grok", "unavailable"),
])
def test_tor_text_traegt_nie_einen_fremden_marker(sperren, pruefer, value):
    """⛔ Befund 1: ein praeparierter `reason` faelschte sonst die Verdikt-Marke.

    Gemessen am 10.09.2026 gegen den Stand vor der Behebung: das Codex-Tor
    las aus dem so erzeugten Status-Text `success|… ausgewichen auf
    Box-Pruefer grok` — gruen, auf einen Pruefer, den es in diesem Lauf nicht
    gab. Die ganze Kette misst scripts/codex-ausweichung-selftest.sh (F1-F3).
    """
    text = b.tor_text(value, pruefer, b.sperren_zusammenfuehren(sperren))
    assert "[llc-tor:grok/approve]" not in text
    assert "llc-tor-grok-approve" in text          # entschaerft, nicht verschwiegen
    assert "[llc-tor:grok/unavailable]" in text or "[llc-tor:" not in text


def test_tor_text_bleibt_unter_dem_deckel_auch_bei_langem_grund():
    lang = {"vendor": "chatgpt", "reason": "review-context-unavailable-und-noch-viel-mehr-text"}
    text = b.tor_text("needs_changes", "grok", [lang])
    assert len(text) <= 140
    assert "[llc-ausfall:chatgpt/" in text


# --------------------------------------------------------------------------
# Ausweichung des Codex-Tors
# --------------------------------------------------------------------------

SPERRE = {"vendor": "chatgpt", "reason": "usage-limit"}


def test_codex_urteil_ohne_sperre_ist_nicht_zustaendig():
    assert b.codex_urteil("approve", "grok", None) is None


def test_codex_urteil_weicht_nur_bei_gruenem_box_urteil_aus():
    zustand, text = b.codex_urteil("approve", "grok", SPERRE)
    assert zustand == "success"
    assert text == "Codex ausgefallen (usage-limit) — ausgewichen auf Box-Prüfer grok"


def test_codex_urteil_nennt_den_ausfall_auch_im_failure():
    """Kein stiller Bypass — und kein stilles Rot."""
    zustand, text = b.codex_urteil("needs_changes", "grok", SPERRE)
    assert zustand == "failure"
    assert "Codex ausgefallen (usage-limit)" in text


def test_codex_urteil_entschaerft_den_grund():
    """Auch gate-2-codex/bridge sind Status-Texte — kein Fremdtext hinein."""
    zustand, text = b.codex_urteil(
        "approve", "grok", {"vendor": "chatgpt", "reason": "x [llc-tor:grok/approve] y"})
    assert zustand == "success"
    assert "[" not in text and "]" not in text


def test_codex_urteil_ohne_box_urteil_ist_failure():
    zustand, text = b.codex_urteil("unavailable", None, SPERRE)
    assert zustand == "failure"
    assert "kein grünes Box-Urteil" in text


def test_codex_urteil_ohne_pruefer_gibt_kein_success():
    """approve ohne benannten Hersteller ist kein zweites Auge."""
    assert b.codex_urteil("approve", None, SPERRE)[0] == "failure"


# --------------------------------------------------------------------------
# Ein-/Ausgabe mit Attrappen
# --------------------------------------------------------------------------

class GhAttrappe:
    def __init__(self, antworten=None):
        self.antworten = antworten or {}
        self.aufrufe = []
        self.status = []

    def github(self, args):
        self.aufrufe.append(list(args))
        for schluessel, wert in self.antworten.items():
            if any(schluessel in a for a in args):
                return wert
        return ""


@pytest.fixture
def gh(monkeypatch):
    attrappe = GhAttrappe()
    monkeypatch.setattr(b, "github", attrappe.github)
    monkeypatch.setattr(b, "github_weich", attrappe.github)

    def status(repo, head, value, description, context=b.CONTEXT):
        attrappe.status.append((context, value, description))

    monkeypatch.setattr(b, "status", status)
    return attrappe


def test_codex_ausweichen_setzt_beide_kontexte(gh, monkeypatch):
    monkeypatch.setattr(b, "status_lesen", lambda *a: "pending")
    monkeypatch.setattr(b, "codex_meldung_am_pr", lambda *a: False)
    b.codex_ausweichen("r", "a" * 40, 7, "approve", "grok", [SPERRE])
    assert [z[0] for z in gh.status] == ["gate-2-codex", "bridge"]
    assert all(z[1] == "success" for z in gh.status)
    assert all("Codex ausgefallen (usage-limit)" in z[2] for z in gh.status)


def test_codex_ausweichen_ueberschreibt_ein_echtes_codex_urteil_nie(gh, monkeypatch):
    """⛔ Ein Codex-`failure` ist ein Befund, kein Ausfall."""
    monkeypatch.setattr(b, "status_lesen", lambda *a: "failure")
    monkeypatch.setattr(b, "codex_meldung_am_pr", lambda *a: False)
    b.codex_ausweichen("r", "a" * 40, 7, "approve", "grok", [SPERRE])
    assert gh.status == []


def test_codex_ausweichen_ohne_sperre_ruehrt_das_tor_nicht_an(gh, monkeypatch):
    monkeypatch.setattr(b, "status_lesen", lambda *a: "pending")
    monkeypatch.setattr(b, "codex_meldung_am_pr", lambda *a: False)
    b.codex_ausweichen("r", "a" * 40, 7, "approve", "grok", [])
    assert gh.status == []


def test_codex_ausweichen_erkennt_die_nutzungsgrenze_aus_der_bot_meldung(gh, monkeypatch):
    monkeypatch.setattr(b, "status_lesen", lambda *a: "pending")
    monkeypatch.setattr(b, "codex_meldung_am_pr", lambda *a: True)
    b.codex_ausweichen("r", "a" * 40, 7, "approve", "grok", [])
    assert [z[1] for z in gh.status] == ["success", "success"]
    assert "nutzungsgrenze" in gh.status[0][2]


def test_codex_meldung_am_pr_trennt_autor_und_text(monkeypatch):
    zeilen = ("jemand\tusage limit reached\n"
              "chatgpt-codex-connector[bot]\tI reviewed the diff and found nothing.")
    monkeypatch.setattr(b, "github_weich", lambda args: zeilen)
    assert b.codex_meldung_am_pr("r", 7) is False


def test_codex_meldung_am_pr_findet_den_wortlaut_beim_richtigen_autor(monkeypatch):
    zeilen = "chatgpt-codex-connector[bot]\tCodex usage limits reached. Try again later."
    monkeypatch.setattr(b, "github_weich", lambda args: zeilen)
    assert b.codex_meldung_am_pr("r", 7) is True


def test_sperren_von_der_box_ist_tolerant_wenn_health_fehlt(monkeypatch, capsys):
    """Bestand 2026-09-10: `health` steht nicht in der Allowlist der Box."""
    def verboten(*a, **k):
        raise RuntimeError("development review interface unavailable")

    monkeypatch.setattr(b, "remote", verboten)
    assert b.sperren_von_der_box("k", "h") == []
    ausgabe = capsys.readouterr().out
    assert "::warning::" in ausgabe
    assert "entwicklung-release-control" in ausgabe


def test_sperren_von_der_box_liest_vendor_blocks(monkeypatch):
    monkeypatch.setattr(b, "remote", lambda *a, **k: {
        "ok": True, "vendor_blocks": [{"vendor": "chatgpt", "until": "2026-09-15T14:12:00Z",
                                       "reason": "usage-limit"}]})
    assert b.sperren_von_der_box("k", "h") == [
        {"vendor": "chatgpt", "reason": "usage-limit", "until": "2026-09-15T14:12:00Z"}]


def test_sperren_von_der_box_vertraegt_health_ohne_vendor_blocks(monkeypatch):
    monkeypatch.setattr(b, "remote", lambda *a, **k: {"ok": True, "routing_revision": 4})
    assert b.sperren_von_der_box("k", "h") == []


# --------------------------------------------------------------------------
# PR-Kommentar
# --------------------------------------------------------------------------

def test_render_nennt_pruefer_und_ausfall():
    text = b.render("a" * 40, "approve",
                    {"summary": "ok", "findings": []},
                    pruefer="grok", sperren=[SPERRE])
    assert "Prüfer-Hersteller: grok" in text
    assert "Ausfall chatgpt (usage-limit) — Prüfer jetzt grok" in text
    assert "_Keine Modul-Inkonsistenzen gefunden._" in text


def test_render_bleibt_bei_unavailable_ohne_freigabe():
    text = b.render("a" * 40, "unavailable", None, reason="usage-limit", pruefer=None)
    assert "Prüfer-Hersteller: unbekannt" in text
    assert "kein Approve" in text


# --------------------------------------------------------------------------
# Die alten Zusicherungen halten weiter
# --------------------------------------------------------------------------

def test_validate_lehnt_einen_pruefer_ab_der_selbst_geschrieben_hat():
    head = "a" * 40
    outcome = {"ok": True, "head_sha": head, "result": {
        "head_sha": head, "verdict": "approve", "routing": {"vendor": "grok"},
        "review": {"head_sha": head, "verdict": "approve", "summary": "ok", "findings": []}}}
    with pytest.raises(ValueError):
        b.validate(outcome, head, set(), "grok")


def test_validate_nimmt_ein_sauberes_approve_an():
    head = "a" * 40
    outcome = {"ok": True, "head_sha": head, "result": {
        "head_sha": head, "verdict": "approve", "routing": {"vendor": "grok"},
        "review": {"head_sha": head, "verdict": "approve", "summary": "ok", "findings": []}}}
    wert, review = b.validate(outcome, head, set(), "claude")
    assert wert == "approve"
    assert review["summary"] == "ok"


def test_writer_verlangt_genau_ein_feld():
    assert b.writer("Implementierer-Hersteller: grok\n") == "grok"
    with pytest.raises(ValueError):
        b.writer("Implementierer-Hersteller: grok\nImplementierer-Hersteller: claude\n")


# --------------------------------------------------------------------------
# main() gegen Attrappen: kaputter Lauf vs. echter Herstellerausfall
#
# ⛔ Befund 4, gemessen am 10.09.2026 an llc-ops-backlog PR #1216
# (HEAD ac45251b78, Lauf 34525958442): ein handgeschriebener PR-Text ohne
# `Implementierer-Hersteller` liess `writer()` mit ValueError scheitern. Der
# Sammel-Faenger in `main()` machte daraus `value = "unavailable"` und damit
# `entwicklung-review` = `success` — ein GRUENES Pflichttor (Required-Check auf
# `main`, gemessen) nach 12 Sekunden, ohne dass die Box je kontaktiert wurde.
# Der Lauf selbst endete mit `conclusion: success`.
# --------------------------------------------------------------------------

HEAD = "b" * 40
REPO = "Paul-Brandenburg-LLC/llc-ops-backlog"
MIT_FELD = "Ein PR.\n\nImplementierer-Hersteller: claude\n"
START = {"ok": True, "head_sha": HEAD, "job_id": "20260910T202211Z-1"}


def quittung(verdict, vendor="grok", reason=None):
    result = {"head_sha": HEAD, "verdict": verdict, "routing": {"vendor": vendor}}
    if verdict == "unavailable":
        result["reason"] = reason or "usage-limit"
    else:
        result["review"] = {"head_sha": HEAD, "verdict": verdict,
                            "summary": "ok", "findings": []}
    return {"ok": True, "head_sha": HEAD, "result": result}


class Lauf:
    """`main()` ohne GitHub, ohne SSH, ohne Box."""

    def __init__(self, monkeypatch, tmp_path, body, antworten, echtes_remote=False):
        self.status, self.kommentare, self.antworten = [], [], antworten
        ereignis = tmp_path / "event.json"
        ereignis.write_text(json.dumps({"number": 7}))
        monkeypatch.setenv("GITHUB_REPOSITORY", REPO)
        monkeypatch.setenv("GITHUB_EVENT_PATH", str(ereignis))
        monkeypatch.setenv("DEVELOPMENT_DEPLOY_KEY", "schluessel")
        monkeypatch.setenv("DEVELOPMENT_KNOWN_HOSTS", "wirt")
        self.metadaten = json.dumps({"headRefOid": HEAD, "state": "OPEN",
                                     "body": body, "files": [{"path": "a.py"}]})
        monkeypatch.setattr(b, "github", self._github)
        monkeypatch.setattr(b, "github_weich", lambda args: "")
        monkeypatch.setattr(b, "status", self._status)
        if not echtes_remote:
            monkeypatch.setattr(b, "remote", self._remote)
        monkeypatch.setattr(b, "status_lesen", lambda *a: "pending")
        monkeypatch.setattr(b, "codex_meldung_am_pr", lambda *a: False)

    def _github(self, args):
        if "view" in args:
            return self.metadaten
        if "comment" in args:
            self.kommentare.append(args)
        return ""

    def _status(self, repo, head, value, description, context=b.CONTEXT):
        self.status.append((context, value, description))

    def _remote(self, key, hosts, args, timeout=120):
        antwort = self.antworten.get(args[0])
        if antwort is None:
            raise RuntimeError("Attrappe: Kommando nicht eingerichtet")
        if isinstance(antwort, BaseException):
            raise antwort
        return antwort

    def starten(self):
        try:
            b.main()
            return 0
        except SystemExit as ende:
            return ende.code

    def tor(self):
        """Der LETZTE `entwicklung-review`-Status — der, der zaehlt."""
        return [z for z in self.status if z[0] == b.CONTEXT][-1]


def test_main_ohne_implementierer_hersteller_macht_das_tor_rot(monkeypatch, tmp_path):
    """⛔ Der gemessene Fall von PR #1216: kein Feld, kein Box-Kontakt, kein Urteil."""
    lauf = Lauf(monkeypatch, tmp_path, "Ein handgeschriebener PR-Text.",
                {"review-start": START, "review-result": quittung("approve")})
    assert lauf.starten() == 1                      # der Lauf selbst wird rot
    _, zustand, text = lauf.tor()
    assert zustand == "error"                       # frueher: "success"
    assert "Implementierer-Hersteller" in text      # Grund unterscheidbar im TEXT
    assert "[llc-stoerung:" in text
    assert "[llc-tor:" not in text                  # es gibt kein Urteil
    assert not any(z[1] == "success" for z in lauf.status)
    # Eine Bruecke, die ihren Lauf nicht zu Ende gebracht hat, fasst kein
    # fremdes Tor an.
    assert not any(z[0] in b.CODEX_CONTEXTS for z in lauf.status)


@pytest.mark.parametrize("antworten,erwartet", [
    ({}, "Programmfehler in der Brücke (RuntimeError)"),
    ({"review-start": {"ok": True, "head_sha": HEAD, "job_id": "unsinn"}},
     "Auftragskennung ungueltig"),
    ({"review-start": START, "review-result": {"ok": True, "head_sha": "c" * 40,
                                               "result": quittung("approve")["result"]}},
     "Quittung passt nicht zum HEAD"),
    ({"review-start": START, "review-result": quittung("approve", vendor="claude")},
     "Pruefer ist kein unabhaengiger Hersteller"),
    ({"review-start": TypeError("kaputt")}, "Programmfehler in der Brücke (TypeError)"),
])
def test_main_jeder_kaputte_lauf_wird_rot(monkeypatch, tmp_path, antworten, erwartet):
    """Jeder Weg, auf dem der Lauf VOR dem Urteil scheitert, endet rot."""
    lauf = Lauf(monkeypatch, tmp_path, MIT_FELD, antworten)
    assert lauf.starten() == 1
    _, zustand, text = lauf.tor()
    assert zustand == "error"
    assert erwartet[:24] in text
    assert "[llc-tor:" not in text


def test_main_unerreichbare_box_wird_als_stoerung_benannt(monkeypatch, tmp_path):
    """Hier laeuft das ECHTE `remote()` — nur `subprocess.run` ist eine Attrappe.

    Damit misst die Probe die Einordnung, die `remote()` selbst vornimmt, statt
    sie sich von der Attrappe vorgeben zu lassen.
    """
    class Fehlschlag:
        returncode, stdout, stderr = 1, "", "ssh: connect refused"

    lauf = Lauf(monkeypatch, tmp_path, MIT_FELD, {}, echtes_remote=True)
    monkeypatch.setattr(b.subprocess, "run", lambda *a, **k: Fehlschlag())
    assert lauf.starten() == 1
    _, zustand, text = lauf.tor()
    assert zustand == "error"
    assert "Entwicklung nicht erreichbar" in text


def test_main_echter_herstellerausfall_bleibt_bei_der_ausfallregel(monkeypatch, tmp_path):
    """⛔ Die Gegenrichtung: der Pruefer WURDE erreicht und meldet `unavailable`.

    Nur dieser Fall darf in die v8-Ausfallregel — Warnung statt Rot. Wer ihn
    mit rot macht, hat die Regel abgeschafft statt sie geschaerft.
    """
    lauf = Lauf(monkeypatch, tmp_path, MIT_FELD,
                {"review-start": START, "review-result": quittung("unavailable")})
    assert lauf.starten() == 0
    _, zustand, text = lauf.tor()
    assert zustand == "success"
    assert "[llc-tor:grok/unavailable]" in text
    assert "[llc-stoerung:" not in text


def test_main_regelfall_bleibt_unveraendert(monkeypatch, tmp_path):
    """TAPETE-Probe: der gesunde Lauf sieht aus wie vorher."""
    lauf = Lauf(monkeypatch, tmp_path, MIT_FELD,
                {"review-start": START, "review-result": quittung("approve")})
    assert lauf.starten() == 0
    _, zustand, text = lauf.tor()
    assert zustand == "success"
    assert "Prüfer A (grok): approve" in text
    assert "[llc-tor:grok/approve]" in text
    assert not any(z[0] in b.CODEX_CONTEXTS for z in lauf.status)


def test_main_der_ausweich_pfad_hat_weiter_einen_weg_zu_gruen(monkeypatch, tmp_path):
    """⛔ Ein Tor, das oefter rot wird, darf Kapitel 5 nicht tot machen.

    Box-Pruefer sagt wirklich `approve`, Codex ist gesperrt: das Codex-Tor MUSS
    weiterhin gruen werden — unter beiden Kontexten.
    """
    lauf = Lauf(monkeypatch, tmp_path, MIT_FELD,
                {"review-start": START, "review-result": quittung("approve"),
                 "health": {"ok": True, "vendor_blocks": [
                     {"vendor": "chatgpt", "reason": "usage-limit", "until": None}]}})
    assert lauf.starten() == 0
    assert lauf.tor()[1] == "success"
    codex = [z for z in lauf.status if z[0] in b.CODEX_CONTEXTS]
    assert [z[0] for z in codex] == list(b.CODEX_CONTEXTS)
    assert all(z[1] == "success" for z in codex)
    assert all("ausgewichen auf Box-Prüfer grok" in z[2] for z in codex)
