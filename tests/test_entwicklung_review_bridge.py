"""Offline-Beweise fuer die Bruecken-Logik des Box-Tors (Standard 8.1, Kap. 5).

Kein GitHub, kein SSH, keine Box: `gh` und `ssh` sind durch Attrappen ersetzt.
Gepruefte Datei: distribution/entwicklung_review_bridge.py — dieselbe, die
propagate-templates.yml in die Consumer-Repos verteilt.
"""
import importlib.util
import json
from pathlib import Path
import re
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
    b.codex_ausweichen("r", "a" * 40, "approve", "grok", [SPERRE])
    assert [z[0] for z in gh.status] == ["gate-2-codex", "bridge"]
    assert all(z[1] == "success" for z in gh.status)
    assert all("Codex ausgefallen (usage-limit)" in z[2] for z in gh.status)


def test_codex_ausweichen_ueberschreibt_ein_echtes_codex_urteil_nie(gh, monkeypatch):
    """⛔ Ein Codex-`failure` ist ein Befund, kein Ausfall."""
    monkeypatch.setattr(b, "status_lesen", lambda *a: "failure")
    b.codex_ausweichen("r", "a" * 40, "approve", "grok", [SPERRE])
    assert gh.status == []


def test_codex_ausweichen_ohne_sperre_ruehrt_das_tor_nicht_an(gh, monkeypatch):
    monkeypatch.setattr(b, "status_lesen", lambda *a: "pending")
    b.codex_ausweichen("r", "a" * 40, "approve", "grok", [])
    assert gh.status == []


def test_codex_ausweichen_sucht_nicht_mehr_selbst(gh, monkeypatch):
    """⛔ Befund 1(a): die Erkennung gehoert in den Trichter, nicht hierher.

    Suchte `codex_ausweichen()` selbst, faerbte es das Codex-Tor, waehrend der
    Status-Text des Box-Tors den Ausfall verschwiege — und genau an dieser
    Marke haengt der Sofort-Weg in gate-2-codex.yml. Ein Ausfall, der nicht in
    `sperren` steht, existiert fuer diesen Schritt nicht.
    """
    monkeypatch.setattr(b, "status_lesen", lambda *a: "pending")
    gerufen = []
    monkeypatch.setattr(b, "codex_meldung_am_pr",
                        lambda *a: gerufen.append(a) or True)
    b.codex_ausweichen("r", "a" * 40, "approve", "grok", [])
    assert gh.status == []
    assert gerufen == []


# --------------------------------------------------------------------------
# Befund 3: die Ausfall-Erkennung ist HEAD-gebunden, autor-exakt, wortlaut-eng
# --------------------------------------------------------------------------

SEIT = "2026-09-11T00:00:00Z"
DANACH = "2026-09-11T00:05:00Z"
DAVOR = "2026-09-09T12:00:00Z"


def meldung(wann, autor, text):
    return wann + "\t" + autor + "\t" + text


def test_codex_ausfall_findet_die_echte_nutzungsgrenze():
    zeilen = meldung(DANACH, "chatgpt-codex-connector[bot]",
                     "Codex usage limits reached. Try again later.")
    assert b.codex_ausfall_in_meldungen(zeilen, SEIT) is True


@pytest.mark.parametrize("autor", [
    "codexplorer",                       # ⛔ fiel unter den alten Praefix
    "codex-fan",
    "openai-watcher",
    "chatgpt-codex-connector",           # ohne [bot] — nicht der App-Login
    "jemand",
])
def test_codex_ausfall_nimmt_nur_den_exakten_login(autor):
    """⛔ `(?i)^(chatgpt-codex-connector|codex|openai)` war ein Praefix-Treffer."""
    zeilen = meldung(DANACH, autor, "Codex usage limits reached.")
    assert b.codex_ausfall_in_meldungen(zeilen, SEIT) is False


@pytest.mark.parametrize("text", [
    # ⛔ Der Kern von Befund 3: normale Pruefprosa. Ein echtes Codex-Review
    # haette sich mit dem alten Wortlaut selbst zum Ausgefallenen erklaert.
    "P2: the client has no rate limit handling; add a rate limit backoff.",
    "Consider documenting the API rate limit in the README.",
    "The usage cap of the free tier should be mentioned.",
    "I reviewed the diff and found nothing.",
])
def test_codex_ausfall_haelt_normale_pruefprosa_fuer_keinen_ausfall(text):
    zeilen = meldung(DANACH, "chatgpt-codex-connector[bot]", text)
    assert b.codex_ausfall_in_meldungen(zeilen, SEIT) is False


def test_codex_ausfall_ignoriert_eine_meldung_von_vor_diesem_head():
    """⛔ Eine Nutzungsgrenze von vorgestern ist kein laufender Ausfall."""
    zeilen = meldung(DAVOR, "chatgpt-codex-connector[bot]",
                     "Codex usage limits reached.")
    assert b.codex_ausfall_in_meldungen(zeilen, SEIT) is False


@pytest.mark.parametrize("seit", ["", None, "gestern", "2026-09-11", "2026-09-11T00:00:00+02:00"])
def test_codex_ausfall_ohne_brauchbare_zeit_ist_aus(seit):
    """Nicht ermittelbar heisst nicht raten — die Erkennung schweigt."""
    zeilen = meldung(DANACH, "chatgpt-codex-connector[bot]",
                     "Codex usage limits reached.")
    assert b.codex_ausfall_in_meldungen(zeilen, seit) is False


def test_codex_ausfall_ignoriert_eine_zeile_ohne_brauchbare_zeit():
    zeilen = meldung("irgendwann", "chatgpt-codex-connector[bot]",
                     "Codex usage limits reached.")
    assert b.codex_ausfall_in_meldungen(zeilen, SEIT) is False


def test_codex_ausfall_trennt_zeit_autor_und_text():
    """Der Wortlaut eines fremden Autors faellt nicht dem Bot zu."""
    zeilen = "\n".join([
        meldung(DANACH, "jemand", "Codex usage limits reached."),
        meldung(DANACH, "chatgpt-codex-connector[bot]",
                "I reviewed the diff and found nothing."),
    ])
    assert b.codex_ausfall_in_meldungen(zeilen, SEIT) is False


def test_status_zeit_liest_created_at_aus_der_post_antwort():
    assert b.status_zeit(json.dumps({"created_at": SEIT, "state": "pending"})) == SEIT


@pytest.mark.parametrize("antwort", [
    "", None, "kein json", "[]", json.dumps({}),
    json.dumps({"created_at": "2026-09-11"}),
    json.dumps({"created_at": 17.0}),
])
def test_status_zeit_raet_nie(antwort):
    assert b.status_zeit(antwort) == ""


def test_sperre_aus_codex_meldung_gehoert_in_den_trichter(monkeypatch):
    monkeypatch.setattr(b, "github_weich", lambda args: meldung(
        DANACH, "chatgpt-codex-connector[bot]", "Codex usage limits reached."))
    roh = b.sperre_aus_codex_meldung("r", 7, SEIT)
    assert roh == [{"vendor": "chatgpt", "reason": "nutzungsgrenze", "until": None}]
    # Und durch den Trichter kommt sie als Marke heraus.
    text = b.tor_text("approve", "grok", b.sperren_zusammenfuehren(roh))
    assert "[llc-ausfall:chatgpt/nutzungsgrenze]" in text
    assert "[llc-tor:grok/approve]" in text


def test_sperre_aus_codex_meldung_erfindet_nichts(monkeypatch):
    monkeypatch.setattr(b, "github_weich", lambda args: meldung(
        DAVOR, "chatgpt-codex-connector[bot]", "Codex usage limits reached."))
    assert b.sperre_aus_codex_meldung("r", 7, SEIT) == []


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

    def __init__(self, monkeypatch, tmp_path, body, antworten, echtes_remote=False,
                 meldungen="", pending_zeit="2026-09-11T00:00:00Z"):
        self.status, self.kommentare, self.antworten = [], [], antworten
        # ⛔ Befund 1(b): erst der Status, dann der Kommentar. Nur eine
        # gemeinsame Liste kann die REIHENFOLGE belegen; zwei getrennte
        # Listen haetten den Fehler nie gezeigt.
        self.ablauf = []
        self.meldungen = meldungen
        self.pending_zeit = pending_zeit
        ereignis = tmp_path / "event.json"
        ereignis.write_text(json.dumps({"number": 7}))
        monkeypatch.setenv("GITHUB_REPOSITORY", REPO)
        monkeypatch.setenv("GITHUB_EVENT_PATH", str(ereignis))
        monkeypatch.setenv("DEVELOPMENT_DEPLOY_KEY", "schluessel")
        monkeypatch.setenv("DEVELOPMENT_KNOWN_HOSTS", "wirt")
        self.metadaten = json.dumps({"headRefOid": HEAD, "state": "OPEN",
                                     "body": body, "files": [{"path": "a.py"}]})
        monkeypatch.setattr(b, "github", self._github)
        # Genau der Abruf, den `codex_meldung_am_pr()` macht: die PR-Kommentare
        # in der Zeilenform `<created_at>\t<login>\t<Text>`.
        monkeypatch.setattr(b, "github_weich", lambda args: self.meldungen)
        monkeypatch.setattr(b, "status", self._status)
        if not echtes_remote:
            monkeypatch.setattr(b, "remote", self._remote)
        monkeypatch.setattr(b, "status_lesen", lambda *a: "pending")

    def _github(self, args):
        if "view" in args:
            return self.metadaten
        if "comment" in args:
            self.kommentare.append(args)
            self.ablauf.append(("kommentar", str(len(self.kommentare))))
        return ""

    def _status(self, repo, head, value, description, context=b.CONTEXT):
        """Antwortet wie GitHub: das angelegte Status-Objekt mit `created_at`."""
        self.status.append((context, value, description))
        self.ablauf.append(("status", context + "=" + str(value)))
        if not self.pending_zeit:
            return ""
        return json.dumps({"context": context, "state": value,
                           "created_at": self.pending_zeit})

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


# --------------------------------------------------------------------------
# Befund 1: der HAUPTFALL — Box sagt approve, Codex schweigt an der Grenze
#
# ⛔ Genau dafuer ist Kapitel 5 gebaut, und genau da feuerte die Ausweichung
# nicht. `health` steht nicht in der Allowlist des Zwangskommandos, und
# `sperre_aus_ergebnis()` schweigt bei `approve` — `sperren` war leer, als
# `tor_text()` lief. Der Box-Status trug `[llc-tor:grok/approve]`, aber keine
# `[llc-ausfall:chatgpt/…]`-Marke; der Sofort-Weg des Codex-Tors haengt an
# genau dieser Marke. Uebrig blieb der 45-Minuten-Fristweg.
# --------------------------------------------------------------------------

CODEX_MELDUNG = ("2026-09-11T00:05:00Z\tchatgpt-codex-connector[bot]\t"
                 "Codex usage limits reached. Try again later.")


def test_main_hauptfall_codex_meldung_faerbt_schon_den_box_status(monkeypatch, tmp_path):
    lauf = Lauf(monkeypatch, tmp_path, MIT_FELD,
                {"review-start": START, "review-result": quittung("approve")},
                meldungen=CODEX_MELDUNG)
    assert lauf.starten() == 0
    _, zustand, text = lauf.tor()
    assert zustand == "success"
    # Das Codex-Tor liest den Status-TEXT. Ohne diese Marke gibt es keinen
    # Sofort-Weg, nur die Frist.
    assert "[llc-ausfall:chatgpt/nutzungsgrenze]" in text
    assert "[llc-tor:grok/approve]" in text
    assert "Ausfall chatgpt (nutzungsgrenze) — Prüfer jetzt grok" in text
    # Und die Bruecke weicht selbst aus, unter beiden Kontexten.
    codex = [z for z in lauf.status if z[0] in b.CODEX_CONTEXTS]
    assert [z[0] for z in codex] == list(b.CODEX_CONTEXTS)
    assert all(z[1] == "success" for z in codex)
    assert all("ausgewichen auf Box-Prüfer grok" in z[2] for z in codex)


def test_main_ohne_lesbare_pending_zeit_wird_nicht_geraten(monkeypatch, tmp_path):
    """Kein `created_at` -> Erkennung aus. Lieber kein Tor als ein falsches."""
    lauf = Lauf(monkeypatch, tmp_path, MIT_FELD,
                {"review-start": START, "review-result": quittung("approve")},
                meldungen=CODEX_MELDUNG, pending_zeit="")
    assert lauf.starten() == 0
    _, _, text = lauf.tor()
    assert "[llc-ausfall:" not in text
    assert not any(z[0] in b.CODEX_CONTEXTS for z in lauf.status)


def test_main_alte_codex_meldung_faerbt_nichts(monkeypatch, tmp_path):
    """Eine Nutzungsgrenze von vorgestern traegt kein Pflichttor."""
    alt = ("2026-09-09T12:00:00Z\tchatgpt-codex-connector[bot]\t"
           "Codex usage limits reached.")
    lauf = Lauf(monkeypatch, tmp_path, MIT_FELD,
                {"review-start": START, "review-result": quittung("approve")},
                meldungen=alt)
    assert lauf.starten() == 0
    _, _, text = lauf.tor()
    assert "[llc-ausfall:" not in text
    assert not any(z[0] in b.CODEX_CONTEXTS for z in lauf.status)


def test_main_codex_meldung_auch_im_stoerungsfall_im_trichter(monkeypatch, tmp_path):
    """Eine halbe Regel waere keine: der Ausfall wird auch genannt, wenn der
    eigene Lauf gescheitert ist — gruen macht ihn das nicht."""
    lauf = Lauf(monkeypatch, tmp_path, "Ein handgeschriebener PR-Text.",
                {"review-start": START, "review-result": quittung("approve")},
                meldungen=CODEX_MELDUNG)
    assert lauf.starten() == 1
    _, zustand, text = lauf.tor()
    assert zustand == "error"
    assert "[llc-ausfall:chatgpt/nutzungsgrenze]" in text
    assert "[llc-tor:" not in text
    assert not any(z[0] in b.CODEX_CONTEXTS for z in lauf.status)


# --------------------------------------------------------------------------
# Befund 1(b): erst der Status, dann der Kommentar — in JEDEM Ausgang
#
# ⛔ `gh pr comment` loest `issue_comment` aus, und daran haengt
# gate-2-codex.yml. Stand der Kommentar vorn, rechnete dieser Lauf Codex
# erneut als `pending` und schrieb das ueber das `success`, das die Bruecke
# Sekunden spaeter setzte: die Bruecke machte ihre eigene Ausweichung mit
# ihrem eigenen Kommentar kaputt.
# --------------------------------------------------------------------------

def _erster_kommentar(lauf):
    namen = [e[0] for e in lauf.ablauf]
    assert "kommentar" in namen, "kein PR-Kommentar geschrieben"
    return namen.index("kommentar")


def test_main_status_steht_vor_dem_kommentar_im_regelfall(monkeypatch, tmp_path):
    lauf = Lauf(monkeypatch, tmp_path, MIT_FELD,
                {"review-start": START, "review-result": quittung("approve")})
    assert lauf.starten() == 0
    stelle = _erster_kommentar(lauf)
    assert lauf.ablauf[:stelle] == [("status", "entwicklung-review=pending"),
                                    ("status", "entwicklung-review=success")]
    assert lauf.ablauf[stelle:] == [("kommentar", "1")]


def test_main_auch_die_ausweichung_steht_vor_dem_kommentar(monkeypatch, tmp_path):
    """⛔ Der Kern: das fertige Codex-Tor MUSS stehen, bevor der Kommentar
    einen Workflow-Lauf ausloest, der es sonst auf `pending` zuruecksetzt."""
    lauf = Lauf(monkeypatch, tmp_path, MIT_FELD,
                {"review-start": START, "review-result": quittung("approve")},
                meldungen=CODEX_MELDUNG)
    assert lauf.starten() == 0
    stelle = _erster_kommentar(lauf)
    vorher = [e[1] for e in lauf.ablauf[:stelle]]
    assert vorher == ["entwicklung-review=pending", "entwicklung-review=success",
                      "gate-2-codex=success", "bridge=success"]


def test_main_status_steht_auch_im_stoerungsfall_vor_dem_kommentar(monkeypatch, tmp_path):
    lauf = Lauf(monkeypatch, tmp_path, "Ein handgeschriebener PR-Text.",
                {"review-start": START, "review-result": quittung("approve")})
    assert lauf.starten() == 1
    stelle = _erster_kommentar(lauf)
    assert [e[1] for e in lauf.ablauf[:stelle]] == ["entwicklung-review=pending",
                                                    "entwicklung-review=error"]


def test_main_bei_ueberholtem_head_gibt_es_gar_keinen_kommentar(monkeypatch, tmp_path):
    """Der dritte Ausgang: ein neuer HEAD. Kein Urteil, kein Kommentar."""
    lauf = Lauf(monkeypatch, tmp_path, MIT_FELD,
                {"review-start": START, "review-result": quittung("approve")})
    ruf = {"n": 0}

    def wechselnd(args):
        if "view" in args:
            ruf["n"] += 1
            if ruf["n"] > 1:
                return json.dumps({"headRefOid": "c" * 40, "state": "OPEN",
                                   "body": MIT_FELD, "files": [{"path": "a.py"}]})
        return lauf._github(args)

    monkeypatch.setattr(b, "github", wechselnd)
    assert lauf.starten() == 0
    assert lauf.kommentare == []
    assert lauf.tor()[1] == "error"


# --------------------------------------------------------------------------
# TAPETE-Gegenprobe: im Regelfall aendert sich NICHTS
#
# 180 Vergleiche ueber alle Verdikte x Pruefer x Sperrvermerke gegen den
# festgeschriebenen Erwartungswert. Eine Aenderung an `tor_text()` oder
# `codex_urteil()`, die den gesunden Lauf beruehrt, faellt hier auf.
# --------------------------------------------------------------------------

VERDIKTE = ["approve", "needs_changes", "unavailable", None, "unsinn"]
PRUEFER = ["grok", "claude", "gemini", None, "mistral", ""]
SPERRLAGEN = [
    [],
    [{"vendor": "chatgpt", "reason": "usage-limit"}],
    [{"vendor": "grok", "reason": "usage-limit"}],
    [{"vendor": "chatgpt", "reason": "nutzungsgrenze"},
     {"vendor": "gemini", "reason": "usage-limit"}],
    [{"vendor": "unsinn", "reason": "x"}],
    [{"vendor": "chatgpt", "reason": None}],
]


def test_tapete_180_vergleiche_ueber_tor_text_und_codex_urteil():
    faelle = 0
    for value in VERDIKTE:
        for pruefer in PRUEFER:
            for sperren in SPERRLAGEN:
                faelle += 1
                zusammen = b.sperren_zusammenfuehren(sperren)
                text = b.tor_text(value, pruefer, zusammen)
                assert len(text) <= 140
                # Eine Verdikt-Marke gibt es nur bei bekanntem Paar.
                marke = "[llc-tor:" + str(pruefer) + "/" + str(value) + "]"
                erwartet = (pruefer in b.VENDORS
                            and value in {"approve", "needs_changes", "unavailable"})
                assert (marke in text) is erwartet
                # Und ohne Sperrvermerk fuer chatgpt ist das Codex-Tor
                # unzustaendig — der Regelfall bleibt unberuehrt.
                sperre = next((s for s in zusammen if s["vendor"] == "chatgpt"), None)
                urteil = b.codex_urteil(value, pruefer, sperre)
                if sperre is None:
                    assert urteil is None
                else:
                    assert urteil[0] in {"success", "failure"}
                    assert (urteil[0] == "success") is (value == "approve"
                                                        and pruefer in b.VENDORS)
    assert faelle == 180


# --------------------------------------------------------------------------
# Befund 5: DIE ZEITKETTE — Modellzug < Frist < Workflow-Deckel
#
# Drei Grenzen an drei Orten, und die kleinste gewinnt immer. Seit dieser
# Bruecke wird ein Abbruch ohne Urteil zur `Stoerung` und damit zu ROT: laeuft
# die mittlere Grenze ab, waehrend der Pruefer noch arbeitet, faerbt ein
# GESUNDER Pruefzug das Pflichttor rot. Am 10.09.2026 gemessen — sieben PRs
# trugen „Pruefer A ausgefallen", der Pruefer war gesund.
#
# ⚠ Diese Proben PRUEFEN die Ordnung, sie wiederholen die Zahlen nicht. Sie
# haengen an keiner Formulierung: die Frist wird aus dem Modul gelesen UND
# gemessen (was `collect()` wirklich faehrt), der Deckel aus der YAML-Datei.
# Wer eine der drei Zahlen anfasst und die anderen stehen laesst, wird hier
# rot — das ist der einzige Zweck dieses Abschnitts.
# --------------------------------------------------------------------------

WORKFLOW = Path(__file__).resolve().parents[1] / "distribution" / "entwicklung-review.yml"


def _kette(name):
    """Ein Glied der Kette aus dem Bruecken-Modul, mit benanntem Fehlschlag."""
    wert = getattr(b, name, None)
    assert isinstance(wert, int) and not isinstance(wert, bool) and wert > 0, (
        name + " fehlt in " + QUELLE.name + " oder ist keine positive Zahl: die "
        "Zeitkette steht dann als nackte Zahl im Rumpf und ist unbewacht — "
        "genau der Zustand, den dieser Abschnitt abschafft.")
    return wert


def _workflow_deckel():
    """`timeout-minutes` des Review-Jobs in SEKUNDEN, aus der Datei gelesen.

    Kommentarzeilen fliegen vorher raus: der Deckel ist eine Zahl im Bestand,
    keine Zahl in einer Prosa-Zeile daneben.
    """
    zeilen = [z for z in WORKFLOW.read_text().splitlines()
              if not z.lstrip().startswith("#")]
    treffer = re.findall(r"^\s*timeout-minutes:\s*([0-9]+)\s*$",
                         "\n".join(zeilen), re.M)
    assert len(treffer) == 1, (
        "genau EIN timeout-minutes erwartet in " + WORKFLOW.name + ", gefunden: "
        + repr(treffer) + " — ein zweiter Job ohne eigenen Deckel oder ein "
        "zweiter Deckel macht die Kette mehrdeutig.")
    return int(treffer[0]) * 60


class _Uhr:
    """Simulierte Zeit fuer `collect()`: `sleep()` stellt sie vor, sonst steht sie.

    Ersetzt `b.time` als Ganzes — nicht die Stdlib. Das Modul benutzt `time`
    ausschliesslich in `collect()`, und eine echte Frist auszusitzen waere in
    einer Probe keine Messung, sondern eine halbe Stunde Wartezeit.
    """

    def __init__(self):
        self.jetzt = 0.0

    def monotonic(self):
        return self.jetzt

    def sleep(self, dauer):
        self.jetzt += dauer


def _frist_messen(monkeypatch, frist=None):
    """Faehrt `collect()` bis zum Fristablauf und gibt (Sekunden, Abrufe) zurueck.

    Der Pruefer antwortet nie — gemessen wird also genau die Frist, die die
    Schleife WIRKLICH faehrt, nicht die, die irgendwo als Zahl steht.
    """
    uhr = _Uhr()
    monkeypatch.setattr(b, "time", uhr)
    if frist is not None:
        monkeypatch.setattr(b, "FRIST_SEKUNDEN", frist)
    abrufe = {"n": 0}

    def nie_fertig(key, hosts, args, timeout=120):
        if args[0] == "review-start":
            return dict(START)
        abrufe["n"] += 1
        return {"ok": True}

    monkeypatch.setattr(b, "remote", nie_fertig)
    with pytest.raises(b.Stoerung):
        b.collect("key", "hosts", "Paul-Brandenburg-LLC/llc-ops-backlog",
                  17, HEAD, "claude")
    return uhr.jetzt, abrufe["n"]


def test_zeitkette_steht_aufsteigend():
    """⛔ Modellzug < Frist < Deckel, mit benanntem Mindestabstand.

    Die Untergrenze (Modellzug) liegt in einem ANDEREN Repo
    (llc-ops-backlog, deploy/entwicklung-box/entwicklung_delivery.py) und ist
    von hier aus nicht messbar. Sie steht deshalb als benannte Annahme im
    Bruecken-Modul; diese Probe haelt die beiden anderen Glieder daran fest.
    """
    modellzug = _kette("MODELLZUG_DECKEL")
    abstand = _kette("KETTEN_MINDESTABSTAND")
    frist = _kette("FRIST_SEKUNDEN")
    deckel = _workflow_deckel()
    assert frist >= modellzug + abstand, (
        "Frist %d s laesst dem Modellzug (%d s) keine %d s Luft: die Bruecke "
        "gibt auf, waehrend der Pruefer noch arbeitet — und das ist seit "
        "Kapitel 5 ROT fuer einen gesunden Lauf." % (frist, modellzug, abstand))
    # ⛔ Der Deckel traegt mehr als die Frist. Drei Kosten liegen ausserhalb
    # des Fristzaehlers und werden trotzdem von ihm bezahlt: `review-start`
    # davor, ein Nachzuegler-Abruf (die Schleife darf ihn eine Sekunde vor der
    # Frist noch starten, und er laeuft einen vollen SSH-Deckel lang) und
    # `health` danach. Wer nur `frist + abstand` verlangt, rechnet den
    # Mindestabstand ein zweites Mal aus — er ist dann laengst verbraucht.
    ausserhalb = 2 * _kette("SSH_DECKEL") + _kette("NACHLAUF_HEALTH")
    assert deckel >= frist + ausserhalb + abstand, (
        "Workflow-Deckel %d s traegt Frist (%d s) plus %d s ausserhalb des "
        "Fristzaehlers (review-start, Nachzuegler-Abruf, health) nicht mit %d s "
        "Luft: der Job stirbt, bevor die Bruecke Status, Bericht und Kommentar "
        "geschrieben hat." % (deckel, frist, ausserhalb, abstand))


def test_die_deckel_ausserhalb_der_frist_werden_gefahren(monkeypatch):
    """Tapete-Gegenprobe: `SSH_DECKEL` und `NACHLAUF_HEALTH` sind keine Prosa.

    ⛔ Stuenden die beiden Zahlen nur im Kommentar oder als Vorgabewert von
    `remote()`, rechnete `test_zeitkette_steht_aufsteigend` mit Kosten, die die
    Aufrufe gar nicht haben — und der Workflow-Deckel waere wieder zu knapp,
    ohne dass irgendetwas rot wird. Gemessen wird darum, was ankommt.
    """
    gesehen = []

    def merken(key, hosts, args, timeout=None):
        gesehen.append((args[0], timeout))
        if args[0] == "review-start":
            return dict(START)
        if args[0] == "health":
            return {"ok": True, "vendor_blocks": []}
        return {"ok": True, "result": {"verdict": "approve", "findings": []},
                "head_sha": HEAD}

    monkeypatch.setattr(b, "remote", merken)
    b.collect("key", "hosts", "Paul-Brandenburg-LLC/llc-ops-backlog", 17, HEAD, "claude")
    b.sperren_von_der_box("key", "hosts")

    gefahren = dict(gesehen)
    assert gefahren["review-start"] == _kette("SSH_DECKEL"), gesehen
    assert gefahren["review-result"] == _kette("SSH_DECKEL"), gesehen
    assert gefahren["health"] == _kette("NACHLAUF_HEALTH"), gesehen


def test_die_gefahrene_frist_ist_die_eingetragene(monkeypatch):
    """Die Kette bewacht nur dann etwas, wenn `collect()` die Konstante faehrt.

    ⛔ Stuende die Frist als nackte Zahl im Rumpf — oder als Vorgabewert im
    Funktionskopf, der beim Import gebunden wird —, pruefte
    `test_zeitkette_steht_aufsteigend` einen Wert, den niemand benutzt.
    """
    assert _frist_messen(monkeypatch, 600) == (600, 40)
    assert _frist_messen(monkeypatch, 1200) == (1200, 80)


def test_die_gefahrene_frist_traegt_die_kette(monkeypatch):
    """Gemessen statt gelesen: was die Schleife faehrt, haelt die Ordnung ein."""
    gefahren, abrufe = _frist_messen(monkeypatch)
    assert gefahren >= _kette("MODELLZUG_DECKEL") + _kette("KETTEN_MINDESTABSTAND"), (
        "gefahrene Frist: %d s" % gefahren)
    ausserhalb = 2 * _kette("SSH_DECKEL") + _kette("NACHLAUF_HEALTH")
    assert gefahren + ausserhalb + _kette("KETTEN_MINDESTABSTAND") <= _workflow_deckel(), (
        "gefahrene Frist: %d s, ausserhalb des Zaehlers: %d s" % (gefahren, ausserhalb))
    assert abrufe == gefahren // _kette("ABRUF_TAKT")


def test_ein_ergebnis_beendet_die_frist_sofort(monkeypatch):
    """Tapete-Gegenprobe zur Kette: der Regelfall wartet KEINE Frist ab.

    Die laengere Frist darf einen gesunden Lauf nicht verlangsamen — sie ist
    eine Obergrenze, kein Takt.
    """
    uhr = _Uhr()
    monkeypatch.setattr(b, "time", uhr)
    fertig = {"ok": True, "head_sha": HEAD, "result": {"head_sha": HEAD}}

    def sofort(key, hosts, args, timeout=120):
        return dict(START) if args[0] == "review-start" else dict(fertig)

    monkeypatch.setattr(b, "remote", sofort)
    assert b.collect("key", "hosts", "Paul-Brandenburg-LLC/llc-ops-backlog",
                     17, HEAD, "claude") == fertig
    assert uhr.jetzt == 0.0


# ---------------------------------------------------------------------------
# Umlauf 3 — Befund des grok-Urteils auf 74a78561 (Ersatz fuer chatgpt)
# "codex_ausweichen overwrites finished Codex verdicts when status_lesen fails"
# ---------------------------------------------------------------------------

def test_ein_unlesbarer_stand_schreibt_NICHTS(gh, monkeypatch):
    """⛔ Der Befund: ein Lesefehler machte aus Befunden ein `success`.

    `status_lesen` lief ueber `github_weich`, das bei JEDEM gh/jq-Fehler einen
    leeren String liefert. Leer ist nicht in {success, failure, error} — also
    wurde die Ausweichung auf beide Kontexte geschrieben. Ein voruebergehender
    API-Fehler NACH einem echten Codex-Fehlschlag verwandelte damit Befunde in
    ein `success`, sobald eine chatgpt-Sperre vorlag.

    Unlesbar heisst jetzt UNBEKANNT, und unbekannt heisst: Finger stillhalten.
    """
    def wirft(*args):
        raise b.StatusUnlesbar("api down")

    monkeypatch.setattr(b, "status_lesen", wirft)
    b.codex_ausweichen("r", "a" * 40, "approve", "grok", [SPERRE])
    assert gh.status == [], "bei unlesbarem Stand wurde trotzdem geschrieben"


def test_jeder_kontext_wird_einzeln_geprueft(gh, monkeypatch):
    """⛔ Vorher entschied allein CODEX_CONTEXTS[0] ueber BEIDE Schreibvorgaenge.

    Stand `bridge` schon auf einem echten Urteil und `gate-2-codex` nicht, wurde
    `bridge` trotzdem ueberschrieben.
    """
    monkeypatch.setattr(b, "status_lesen",
                        lambda repo, head, ctx: "failure" if ctx == "bridge" else "pending")
    b.codex_ausweichen("r", "a" * 40, "approve", "grok", [SPERRE])
    assert [z[0] for z in gh.status] == ["gate-2-codex"], \
        "bridge trug ein echtes Urteil und haette nicht beschrieben werden duerfen"


def test_ein_unlesbarer_kontext_haelt_den_anderen_nicht_auf(gh, monkeypatch):
    """Gegenprobe: fail-closed gilt je Kontext, nicht fuer den ganzen Lauf.

    Sonst wuerde ein einzelner Lesefehler die Ausweichung ganz verhindern — und
    das Tor bliebe bei einem echten Ausfall grundlos zu.
    """
    def teils(repo, head, ctx):
        if ctx == "bridge":
            raise b.StatusUnlesbar("api down")
        return "pending"

    monkeypatch.setattr(b, "status_lesen", teils)
    b.codex_ausweichen("r", "a" * 40, "approve", "grok", [SPERRE])
    assert [z[0] for z in gh.status] == ["gate-2-codex"]


def test_status_lesen_wirft_bei_einem_abrufehler(monkeypatch):
    """Die Unterscheidung selbst: '' heisst kein Stand, StatusUnlesbar heisst Fehler."""
    def kaputt(args):
        raise RuntimeError("gh: not found")

    monkeypatch.setattr(b, "github", kaputt)
    try:
        b.status_lesen("r", "a" * 40, "gate-2-codex")
    except b.StatusUnlesbar:
        return
    raise AssertionError("status_lesen hat den Abrufehler verschluckt")
