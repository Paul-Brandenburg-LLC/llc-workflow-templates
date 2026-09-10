"""Trusted-base GitHub Actions bridge to an isolated development reviewer.

llc-verteilung: verwaltet — Quelle: llc-workflow-templates/distribution/entwicklung_review_bridge.py
Diese Datei wird von propagate-templates.yml (Job `verteilung`) synchron
gehalten. Repo-eigene Abweichungen: die Marker-Zeile oben ENTFERNEN — die
Datei wird dann als Abweichler ausgewiesen, aber nie ueberschrieben.

Standard 8.1, Kapitel 5 „Tor-Ausweichung":
  * Der Status `entwicklung-review` nennt den Pruefer-Hersteller.
  * Meldet die Box einen Sperrvermerk oder einen Ersatzwechsel, steht das im
    Status-Text: „Ausfall <vendor> (<reason>) — Pruefer jetzt <vendor>".
  * Faellt Codex aus, weicht das Codex-Tor auf den Box-Pruefer aus — aber nur,
    wenn das Box-Tor fuer DENSELBEN Commit gruen ist. Der Text nennt den
    Ausfall; ein stiller Bypass ist ausgeschlossen.
"""
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time

ALIASES = {"Paul-Brandenburg-LLC/llc-ops-backlog": "ops",
           "Paul-Brandenburg-LLC/llc-paulbrandenburg-com-app": "hub",
           "Paul-Brandenburg-LLC/standards": "standards"}
VENDORS = {"grok", "claude", "chatgpt", "gemini"}
CONTEXT = "entwicklung-review"
# Das Codex-Tor veroeffentlicht unter beiden Kontexten (gate-2-codex.yml,
# Step „Post Status"). Wer ausweicht, muss beide bedienen, sonst haengt der
# Required-Check, den das Repo tatsaechlich fuehrt.
CODEX_CONTEXTS = ("gate-2-codex", "bridge")
CODEX_VENDOR = "chatgpt"
# Wortlaut der Nutzungsgrenze — die Meldungen, die der Codex-Bot bzw. die Box
# (`entwicklung_provider.py`) bei erschoepftem Kontingent ausgibt.
QUOTA_WORTLAUT = re.compile(
    r"(?i)(usage limit|nutzungsgrenze|rate limit|quota exceeded|quota erreicht"
    r"|usage cap|out of credits|kontingent (?:erschoepft|erschöpft|aufgebraucht))")
CODEX_AUTOR = re.compile(r"(?i)^(chatgpt-codex-connector|codex|openai)")


class Stoerung(ValueError):
    """Der Lauf ist gescheitert, BEVOR ein Pruefer-Urteil vorlag.

    ⛔ Das ist KEIN Herstellerausfall. Ein ungueltiger PR-Text, fehlende
    Zugangsdaten, eine unerreichbare Box, eine kaputte Quittung — in all diesen
    Faellen hat NIEMAND geprueft, und das Tor muss zu bleiben. Die
    v8-Ausfallregel (Warnung statt Rot) gilt nur fuer den anderen Fall: der
    Pruefer wurde erreicht und hat selbst `unavailable` gemeldet.

    Erbt von `ValueError`, damit die bestehenden Auffangnetze (`validate`,
    `sperren_von_der_box`) unveraendert greifen.
    """

    def __init__(self, grund):
        super().__init__(grund)
        self.grund = grund


def github(args):
    r = subprocess.run(["gh", *args], capture_output=True, text=True, timeout=120)
    if r.returncode:
        raise RuntimeError("GitHub request failed")
    return r.stdout.strip()


def github_weich(args):
    """Lesender Abruf, der nie den Lauf abbricht. Leer heisst: unbekannt."""
    try:
        return github(args)
    except (RuntimeError, OSError, subprocess.SubprocessError):
        return ""


def metadata(repo, number):
    return json.loads(github(["pr", "view", str(number), "--repo", repo,
        "--json", "headRefOid,state,body,files"]))


def writer(body):
    found = re.findall(r"(?m)^Implementierer-Hersteller:\s*(grok|claude|chatgpt|gemini)\s*$", body)
    if len(found) != 1:
        raise Stoerung("PR-Text ohne Feld Implementierer-Hersteller")
    return found[0]


def status(repo, head, value, description, context=CONTEXT):
    github(["api", "--method", "POST", f"repos/{repo}/statuses/{head}",
            "-f", "context=" + context, "-f", "state=" + value,
            "-f", "description=" + description[:140]])


def status_lesen(repo, head, context):
    """Aktueller Zustand eines Kontexts an genau diesem Commit ('' = unbekannt)."""
    raw = github_weich(["api", f"repos/{repo}/commits/{head}/status",
                        "--jq", '[.statuses[] | select(.context=="' + context + '")] | .[0].state // ""'])
    return raw.strip()


def validate(outcome, head, paths, actual_writer):
    if outcome.get("head_sha") != head or outcome.get("ok") is not True:
        raise Stoerung("Quittung passt nicht zum HEAD")
    result = outcome["result"]
    if result.get("head_sha") != head:
        raise Stoerung("Pruefergebnis passt nicht zum HEAD")
    value = result.get("verdict")
    if value == "unavailable":
        return value, None
    review, routing = result["review"], result["routing"]
    if routing.get("vendor") not in VENDORS or routing["vendor"] == actual_writer:
        raise Stoerung("Pruefer ist kein unabhaengiger Hersteller")
    if review.get("head_sha") != head or review.get("verdict") != value:
        raise Stoerung("Befund passt nicht zur Quittung")
    findings = review.get("findings")
    if not isinstance(findings, list) or not isinstance(review.get("summary"), str):
        raise Stoerung("Befund-Schema ungueltig")
    for f in findings:
        if not isinstance(f, dict) or f.get("path") not in paths or type(f.get("line")) is not int or f["line"] <= 0:
            raise Stoerung("Befund ohne gueltige Fundstelle")
        if any(not isinstance(f.get(k), str) or not f[k].strip() for k in ["title", "reason", "recommendation"]):
            raise Stoerung("Befund unvollstaendig")
    if value != ("needs_changes" if findings else "approve"):
        raise Stoerung("Verdikt widerspricht den Befunden")
    return value, review


# --------------------------------------------------------------------------
# Ausfall-Erkennung und Status-Text — reine Funktionen, offline beweisbar
# --------------------------------------------------------------------------

def slug(text):
    """Marken-tauglicher Grund: [a-z0-9-], hoechstens 32 Zeichen.

    Idempotent: `slug(slug(x)) == slug(x)`. Der Schnitt auf 32 kann einen
    Trennstrich freilegen, der beim zweiten Lauf wegfiele — dann truege
    derselbe Grund zwei verschiedene Marken.
    """
    value = re.sub(r"[^a-z0-9]+", "-", str(text or "").lower()).strip("-")
    return value[:32].strip("-") or "unbekannt"


def prosa(text):
    """Fremdtext, der in einen Status-Text wandert: Klammern fallen weg.

    ⛔ Der Grund (`reason`) kommt von der Box, also von ausserhalb des Tores.
    Stuende er roh in der Prosa, koennte er `[llc-tor:<vendor>/approve]`
    enthalten — und die Marken-`sed` des Codex-Tors (gate-2-codex.yml, Step
    „Ausweichung") greift GIERIG die letzte Marke im ganzen Text. Ohne echtes
    Pruefer-Urteil steht keine echte Marke dahinter; die gefaelschte gewaenne
    und das Tor ginge gruen, ohne dass irgendjemand geprueft haette.
    Beweis: scripts/codex-ausweichung-selftest.sh, Faelle F1/F2.
    """
    return re.sub(r"[\[\]]", "", str(text or ""))


def pruefer_marke(vendor, verdikt):
    """HEAD-gebundene Marke im Status-Text; das Codex-Tor liest genau sie."""
    if vendor not in VENDORS or verdikt not in {"approve", "needs_changes", "unavailable"}:
        return ""
    return "[llc-tor:" + vendor + "/" + verdikt + "]"


def ausfall_marke(vendor, grund):
    if vendor not in VENDORS:
        return ""
    return "[llc-ausfall:" + vendor + "/" + slug(grund) + "]"


def beschreibung(basis, marken):
    """140 Zeichen. Die Marken ueberleben, gekuerzt wird die Prosa davor.

    GitHub schneidet laengere Beschreibungen ab. Stuende die Marke hinten und
    die Prosa vorn ungekuerzt, verlore der Schnitt genau das Feld, an dem das
    Codex-Tor die Ausweichung erkennt.
    """
    # ⛔ Zweite Lage: was auch immer als Prosa hereinkommt, es darf nicht wie
    # eine Marke aussehen. Die Marken selbst stehen in `schwanz`.
    basis = prosa(basis)
    schwanz = " ".join(m for m in marken if m)
    if not schwanz:
        return basis[:140]
    if len(schwanz) >= 140:
        return schwanz[:140]
    frei = 140 - len(schwanz) - 1
    kurz = basis if len(basis) <= frei else basis[:max(0, frei - 1)].rstrip() + "…"
    return (kurz + " " + schwanz).strip()


def sperren_zusammenfuehren(*quellen):
    """Sperrvermerke aus mehreren Quellen; je Hersteller bleibt der erste."""
    zusammen = {}
    for quelle in quellen:
        for eintrag in quelle or []:
            vendor = (eintrag or {}).get("vendor")
            if vendor in VENDORS and vendor not in zusammen:
                # ⛔ Der Grund wird HIER entschaerft, am einzigen Trichter, durch
                # den jeder Sperrvermerk laeuft — die `health`-Antwort der Box
                # ebenso wie `review-result.reason`. Eine halbe Regel waere
                # keine: entschaerfte man nur einen der beiden Wege, truege der
                # andere den Fremdtext weiter in den Status.
                zusammen[vendor] = {"vendor": vendor,
                                    "reason": slug(eintrag.get("reason") or "usage-limit"),
                                    "until": eintrag.get("until")}
    return [zusammen[v] for v in sorted(zusammen)]


def sperre_aus_ergebnis(result):
    """Der Ausfall, den `review-result.json` schon heute bezeugt.

    `entwicklung_delivery.py` schreibt bei einem Provider-Ausfall `reason`
    (z. B. `usage-limit`) neben das volle `routing`-Woerterbuch. Das ist die
    einzige Ausfall-Quelle, die die Bruecke OHNE Aenderung an der Box lesen
    kann — `health` steht nicht in der Allowlist des Zwangskommandos.
    """
    if not isinstance(result, dict) or result.get("verdict") != "unavailable":
        return []
    grund = result.get("reason")
    vendor = (result.get("routing") or {}).get("vendor")
    if not grund or vendor not in VENDORS:
        return []
    return [{"vendor": vendor, "reason": grund, "until": None}]


def ausfall_satz(pruefer, sperren):
    """„Ausfall <vendor> (<reason>) — Prüfer jetzt <vendor>" oder ''."""
    for eintrag in sperren or []:
        vendor, grund = eintrag["vendor"], eintrag.get("reason") or "usage-limit"
        if vendor == pruefer:
            return "Ausfall " + vendor + " (" + grund + ") — kein Ersatz-Prüfer"
        if pruefer in VENDORS:
            return "Ausfall " + vendor + " (" + grund + ") — Prüfer jetzt " + pruefer
        return "Ausfall " + vendor + " (" + grund + ") — kein Prüfer-Urteil"
    return ""


def tor_text(value, pruefer, sperren):
    """Status-Beschreibung des Box-Tors: Verdikt, Pruefer, Ausfall, Marken."""
    name = pruefer if pruefer in VENDORS else "?"
    basis = {"approve": "Prüfer A (" + name + "): approve",
             "needs_changes": "Prüfer A (" + name + "): Findings"}.get(
                 value, "Warnung: Prüfer A (" + name + ") ausgefallen")
    satz = ausfall_satz(pruefer, sperren)
    if satz:
        basis = satz + " · " + basis
    marken = [pruefer_marke(pruefer, value)]
    for eintrag in sperren or []:
        marken.append(ausfall_marke(eintrag["vendor"], eintrag.get("reason")))
    return beschreibung(basis, marken)


def stoerung_text(grund, sperren=()):
    """Status-Text eines KAPUTTEN Laufs — bewusst OHNE Verdikt-Marke.

    `[llc-stoerung:…]` ist keine `[llc-tor:…]`-Marke. Das Codex-Tor kann daraus
    also nie ein Urteil lesen, auch nicht versehentlich: es gibt keines. Ein
    vorhandener Sperrvermerk wird trotzdem genannt, damit das Codex-Tor den
    Ausfall erklaeren kann — gruen macht ihn das nicht (dafuer verlangt es
    `tor_state = success` UND eine `approve`-Marke).
    """
    marken = ["[llc-stoerung:" + slug(grund) + "]"]
    for eintrag in sperren or []:
        marken.append(ausfall_marke(eintrag["vendor"], eintrag.get("reason")))
    return beschreibung("Prüflauf gescheitert: " + grund + " — kein Urteil", marken)


def codex_urteil(value, pruefer, sperre):
    """Ausweichung des Codex-Tors. None = nicht zustaendig, das Tor bleibt.

    Gruen wird nur gesetzt, wenn das Box-Tor fuer denselben Commit `approve`
    gemeldet hat. Jeder Text nennt den Ausfall — kein stiller Bypass.
    """
    if not sperre:
        return None
    # Auch dieser Text ist ein Status-Text (gate-2-codex + bridge).
    grund = slug(sperre.get("reason") or "usage-limit")
    if value == "approve" and pruefer in VENDORS:
        return "success", "Codex ausgefallen (" + grund + ") — ausgewichen auf Box-Prüfer " + pruefer
    if value == "needs_changes":
        name = pruefer if pruefer in VENDORS else "?"
        return "failure", "Codex ausgefallen (" + grund + ") — Box-Prüfer " + name + " meldet Findings"
    return "failure", "Codex ausgefallen (" + grund + ") — kein grünes Box-Urteil für diesen Commit"


def render(head, value, review, reason="", pruefer=None, sperren=(), stoerung=""):
    rows = ["### Zusammenfassung", "HEAD-SHA: " + head,
            "Prüfer-Hersteller: " + (pruefer if pruefer in VENDORS else "unbekannt")]
    satz = ausfall_satz(pruefer, sperren)
    if satz:
        rows.append(satz)
    rows.append("")
    if stoerung:
        return "\n".join(rows + [
            "⛔ Der Prüflauf ist gescheitert, BEVOR ein Urteil vorlag: " + stoerung + ".",
            "Das ist **kein** Herstellerausfall, sondern ein kaputter Lauf. Das Tor",
            "steht auf `error` und bleibt zu.",
            "",
            "Die v8-Ausfallregel (Warnung statt Rot) gilt nur, wenn der Prüfer erreicht",
            "wurde und selbst „unavailable\" gemeldet hat. Hier hat niemand geprüft.", ""])
    if value == "unavailable":
        return "\n".join(rows + [
            "Prüfer A nicht verfügbar; kein Approve und keine Herstellerzulassung.",
            "Ursache: " + reason, "v8-Ausfallregel: Warnung; deterministische Gates bleiben verbindlich.", ""])
    single = lambda s: " ".join(s.split())
    rows += [single(review["summary"]), "", "### Integrations-Befunde"]
    for f in review["findings"]:
        rows += ["- **" + single(f["title"]) + "** — " + f["path"] + ":" + str(f["line"]),
                 "  " + single(f["reason"]), "  Empfehlung: " + single(f["recommendation"])]
    if not review["findings"]:
        rows += ["_Keine Modul-Inkonsistenzen gefunden._"]
    return "\n".join(rows + ["", "### Verdikt", value, ""])


# --------------------------------------------------------------------------
# Zugang zur Box
# --------------------------------------------------------------------------

def remote(key, hosts, args, timeout=120):
    # Do not forward the GitHub token or SSH material through the remote environment.
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "LANG": "C.UTF-8"}
    r = subprocess.run(["ssh", "-i", str(key), "-o", "IdentitiesOnly=yes",
        "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
        "-o", "UserKnownHostsFile=" + str(hosts), "-o", "ConnectTimeout=15",
        "entwicklung@65.21.209.115", *args], env=env, capture_output=True,
        text=True, timeout=timeout)
    if r.returncode or len(r.stdout) > 200000:
        raise Stoerung("Entwicklung nicht erreichbar")
    value = json.loads(r.stdout)
    if not isinstance(value, dict) or value.get("ok") is not True:
        raise Stoerung("Quittung der Entwicklung ungueltig")
    return value


def sperren_von_der_box(key, hosts):
    """`health` lesen — tolerant. Fehlt das Kommando, ist das kein Fehler.

    ⚠ Bestand 2026-09-10: das Zwangskommando des CI-Schluessels
    (`deploy/entwicklung-box/entwicklung-release-control`) laesst nur
    `review-start`, `review-result`, `deploy` und `rollback` durch. `health`
    existiert auf der Box (`entwicklung_v8.py`, Kommando `health`), steht aber
    NICHT in dieser Allowlist — der Aufruf endet mit „dispatcher: forbidden".
    Kein erfundenes Kommando, sondern eine fehlende Zeile; die Warnung unten
    nennt genau sie. Bis dahin traegt `sperre_aus_ergebnis()` die Erkennung.
    """
    try:
        antwort = remote(key, hosts, ["health"], timeout=60)
    except (RuntimeError, ValueError, OSError, subprocess.SubprocessError):
        print("::warning::Box-health nicht erreichbar — `health` fehlt in der "
              "Allowlist von deploy/entwicklung-box/entwicklung-release-control; "
              "Ausfall-Erkennung laeuft auf review-result.reason")
        return []
    blocks = antwort.get("vendor_blocks")
    if not isinstance(blocks, list):
        return []
    return sperren_zusammenfuehren(blocks)


def collect(key, hosts, repo, number, head, actual_writer):
    started = remote(key, hosts, ["review-start", ALIASES[repo], str(number), head, actual_writer])
    jid = started.get("job_id", "")
    if started.get("head_sha") != head or not re.fullmatch(r"[0-9]{8}T[0-9]{6}Z-[0-9]+", jid):
        raise Stoerung("Auftragskennung ungueltig")
    deadline = time.monotonic() + 900
    while time.monotonic() < deadline:
        outcome = remote(key, hosts, ["review-result", jid, head])
        if "result" in outcome:
            return outcome
        time.sleep(15)
    raise Stoerung("Pruefer-Auftrag ohne Ergebnis binnen Frist")


def codex_meldung_am_pr(repo, number):
    """Nennt eine Codex-Meldung am PR die Nutzungsgrenze? Zweite Ausfall-Quelle.

    Whitespace wird in jq zusammengezogen, damit jeder Kommentar genau EINE
    Zeile belegt — ein mehrzeiliger Text wuerde die Zuordnung Autor/Text sonst
    zerreissen und einem fremden Autor die Meldung zuschreiben.
    """
    roh = github_weich(["api", "--paginate", "repos/" + repo + "/issues/" + str(number) + "/comments",
                        "--jq", '.[] | ((.user.login // "") + "	" + ((.body // "") | gsub("\\\\s+"; " ")))'])
    for zeile in roh.splitlines():
        autor, _, text = zeile.partition("	")
        if CODEX_AUTOR.search(autor.strip()) and QUOTA_WORTLAUT.search(text):
            return True
    return False


def codex_ausweichen(repo, head, number, value, pruefer, sperren):
    """Setzt gate-2-codex/bridge, wenn Codex ausgefallen ist. Sonst nichts."""
    sperre = next((s for s in sperren if s["vendor"] == CODEX_VENDOR), None)
    if sperre is None and codex_meldung_am_pr(repo, number):
        sperre = {"vendor": CODEX_VENDOR, "reason": "nutzungsgrenze", "until": None}
    urteil = codex_urteil(value, pruefer, sperre)
    if urteil is None:
        return
    # Ein echtes Codex-Urteil an diesem Commit wird nie ueberschrieben.
    vorhanden = status_lesen(repo, head, CODEX_CONTEXTS[0])
    if vorhanden in {"success", "failure", "error"}:
        print("::notice::gate-2-codex steht bereits auf " + vorhanden + " — keine Ausweichung")
        return
    zustand, text = urteil
    for context in CODEX_CONTEXTS:
        status(repo, head, zustand, text, context=context)
    print("::warning::" + text)


def main():
    repo = os.environ["GITHUB_REPOSITORY"]
    if repo not in ALIASES:
        raise ValueError("repository not registered")
    event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
    number = event.get("number", event.get("inputs", {}).get("pr", ""))
    if not re.fullmatch(r"[1-9][0-9]{0,8}", str(number)):
        raise ValueError("invalid PR number")
    info = metadata(repo, number)
    head = info["headRefOid"]
    if not re.fullmatch(r"[0-9a-f]{40}", head) or info["state"] != "OPEN":
        raise ValueError("open PR with exact SHA required")
    status(repo, head, "pending", "Prüfer-Auftrag auf der Entwicklung")
    reason, pruefer, sperren, stoerung = "", None, [], ""
    key = os.environ.pop("DEVELOPMENT_DEPLOY_KEY", "")
    hosts = os.environ.pop("DEVELOPMENT_KNOWN_HOSTS", "")
    try:
        if not key.strip() or not hosts.strip():
            raise Stoerung("Zugangsdaten fuer die Entwicklung fehlen")
        with tempfile.TemporaryDirectory(prefix="entwicklung-review-") as temporary:
            directory = Path(temporary)
            private, known = directory / "identity", directory / "known_hosts"
            private.write_text(key.rstrip() + "\n")
            known.write_text(hosts.rstrip() + "\n")
            private.chmod(0o600)
            known.chmod(0o600)
            try:
                actual_writer = writer(info["body"])
                outcome = collect(private, known, repo, number, head, actual_writer)
                result = outcome.get("result") or {}
                pruefer = (result.get("routing") or {}).get("vendor")
                value, review = validate(outcome, head, {p["path"] for p in info["files"]}, actual_writer)
                if value == "unavailable":
                    reason = result.get("reason") or "Prüfer-Auftrag ohne verwendbares Urteil beendet"
                sperren = sperren_zusammenfuehren(sperren_von_der_box(private, known),
                                                  sperre_aus_ergebnis(result))
            except BaseException:
                # Der Sperrvermerk erklaert auch einen gescheiterten Prueflauf.
                # Er wird gelesen, SOLANGE das Schluesselverzeichnis noch steht.
                sperren = sperren_von_der_box(private, known)
                raise
    # ⛔ Zwei GRUNDVERSCHIEDENE Faelle, die frueher denselben Ausgang hatten.
    #
    # (1) `Stoerung`: der Lauf ist gescheitert, BEVOR ein Urteil vorlag —
    #     ungueltiger PR-Text, fehlende Zugangsdaten, unerreichbare Box,
    #     kaputte Quittung. Niemand hat geprueft.
    # (2) Jeder andere Fehler: ein Programmfehler in der Bruecke selbst.
    #
    # Beides ist KEIN Herstellerausfall. Frueher landete alles im selben Zweig
    # und setzte `value = "unavailable"` — und damit `entwicklung-review` auf
    # `success`. Gemessen am 10.09.2026 an llc-ops-backlog PR #1216: ein
    # handgeschriebener PR-Text ohne `Implementierer-Hersteller` erzeugte einen
    # 12-Sekunden-Lauf ohne jeden Box-Kontakt und ein gruenes Pflichttor
    # („Warnung: Pruefer A ausgefallen"). Ein gruenes Required-Check IST
    # gegenueber der Branch-Protection eine Freigabe, gleich was im Text steht.
    except Stoerung as exc:
        value, review, stoerung = None, None, exc.grund
    except (RuntimeError, ValueError, KeyError, TypeError, OSError, subprocess.SubprocessError) as exc:
        value, review, stoerung = None, None, "Programmfehler in der Brücke (" + type(exc).__name__ + ")"
    if pruefer not in VENDORS:
        pruefer = None
    # Never publish an old verdict on a new PR head.
    if metadata(repo, number)["headRefOid"] != head:
        status(repo, head, "error", "Review durch neuen HEAD überholt")
        print("Review superseded by newer HEAD")
        return
    body = render(head, value, review, reason, pruefer, sperren, stoerung)
    if len(body) > 60000:
        # Preserve a negative verdict even when the prose exceeds GitHub's limit.
        body = body[:59000] + "\n\nBericht gekürzt; vollständiges Urteil im Entwicklung-Job.\n### Verdikt\n" + value + "\n"
    with tempfile.NamedTemporaryFile("w", suffix=".md") as file:
        file.write(body)
        file.flush()
        github(["pr", "comment", str(number), "--repo", repo, "--body-file", file.name])
    if stoerung:
        # ⛔ Rot, nicht gruen. Und das Codex-Tor wird NICHT angefasst: eine
        # Bruecke, die ihren eigenen Lauf nicht zu Ende gebracht hat, darf kein
        # fremdes Tor beschreiben. `gate-2-codex` bleibt `pending` und
        # entscheidet selbst — sein Ausweich-Schritt verlangt `success` UND
        # eine `approve`-Marke, findet hier beides nicht und blockiert.
        status(repo, head, "error", stoerung_text(stoerung, sperren))
        print("::error::Prüflauf gescheitert: " + stoerung + " — kein Urteil, Tor auf error")
        raise SystemExit(1)
    status(repo, head, "failure" if value == "needs_changes" else "success",
           tor_text(value, pruefer, sperren))
    codex_ausweichen(repo, head, number, value, pruefer, sperren)
    if value == "unavailable":
        print("::warning::Prüfer A ausgefallen; keine Freigabe vorgetäuscht")
    if value == "needs_changes":
        raise SystemExit(1)


if __name__ == "__main__":
    main()
