#!/usr/bin/env python3
"""
Ermittelt den PDF-Link des Wochenmenüplans (SV Gastronomie, Galexis dailys Niederbipp).

Die Seite ist eine JS-App: der PDF-Link entsteht erst beim Rendern. Darum Headless-Chromium.
Kandidaten-Quellen:
  1. Netzwerkverkehr (PDF-Responses, URLs in JSON/Text-Antworten)
  2. gerendertes DOM (href/src/data-* mit .pdf)
  3. aktives Klicken auf Download-/PDF-/Wochenmenü-Buttons (Popup, Download, Navigation)
Jeder Kandidat wird per HTTP verifiziert (Status 200, %PDF-Header, Mindestgrösse).

Ausgabe:
  stdout          -> ausschliesslich die verifizierte PDF-URL
  stderr          -> Logs
  --json-out      -> JSON mit URL, Metadaten, Zeitstempel
  $GITHUB_OUTPUT  -> pdf_url=<url>  (falls gesetzt)
Exit-Code: 0 = OK, 1 = kein verifizierbarer PDF-Link gefunden.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import urljoin, urlparse

from playwright.sync_api import Error as PWError
from playwright.sync_api import Page, sync_playwright

DEFAULT_URL = (
    "https://sv-gastronomie.ch/menu/"
    "Galexis%20AG,%20dailys,%20Niederbipp/Mittagsmen%C3%BC"
)
USER_AGENT = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/124.0 Safari/537.36"
)

# findet absolute und relative .pdf-Pfade in Text/JSON (auch mit \/ escaped)
PDF_IN_TEXT = re.compile(r"""(?:https?:)?[^\s"'<>\\()]*?\.pdf(?:\?[^\s"'<>\\()]*)?""", re.I)
TRIGGER_TEXT = re.compile(
    r"pdf|wochen\s*men|wochen\s*plan|menüplan|menuplan|download|herunterladen|"
    r"drucken|print|speichern|export",
    re.I,
)
SCORE_KEYWORDS = ("woche", "week", "wochen", "menu", "menü", "kw")


def log(msg: str) -> None:
    print(f"[{datetime.now():%H:%M:%S}] {msg}", file=sys.stderr, flush=True)


@dataclass
class Collector:
    base_url: str
    candidates: dict[str, str] = field(default_factory=dict)  # url -> Quelle
    netlog: list[dict] = field(default_factory=list)

    def add(self, raw: str, source: str) -> None:
        raw = raw.strip().replace("\\/", "/")
        if not raw or raw.startswith(("blob:", "data:", "javascript:")):
            if raw.startswith("blob:"):
                log(f"WARN: blob-URL gefunden (nicht wiederverwendbar): {raw[:80]}")
            return
        url = urljoin(self.base_url, raw)
        if urlparse(url).scheme not in ("http", "https"):
            return
        if url not in self.candidates:
            self.candidates[url] = source
            log(f"Kandidat [{source}]: {url}")

    def on_response(self, resp) -> None:
        try:
            url = resp.url
            ctype = (resp.headers.get("content-type") or "").lower()
            rtype = resp.request.resource_type
            self.netlog.append(
                {"url": url, "status": resp.status, "type": rtype, "ctype": ctype}
            )
            if "application/pdf" in ctype or urlparse(url).path.lower().endswith(".pdf"):
                self.add(url, "network:pdf")
                return
            if rtype in ("xhr", "fetch") and ("json" in ctype or "text" in ctype):
                body = resp.text()
                for m in PDF_IN_TEXT.findall(body):
                    self.add(m, "network:body")
        except Exception:
            pass  # Response evtl. schon verworfen (Redirect/Abbruch)


def scan_dom(page: Page, col: Collector) -> None:
    js = """
    () => {
      const out = [];
      for (const el of document.querySelectorAll('*')) {
        for (const a of el.attributes) {
          if (/\\.pdf(\\?|#|$)/i.test(a.value) || /pdf/i.test(a.name)) out.push(a.value);
        }
      }
      return out;
    }
    """
    try:
        for v in page.evaluate(js):
            for m in PDF_IN_TEXT.findall(v) or ([v] if v.lower().endswith(".pdf") else []):
                col.add(m, "dom")
    except PWError:
        pass


def click_triggers(page: Page, col: Collector, timeout_ms: int = 6000) -> None:
    """Klickt auf plausible Download-Elemente und fängt Popup/Download/Navigation ab."""
    loc = page.locator("a, button, [role=button]").filter(has_text=TRIGGER_TEXT)
    count = min(loc.count(), 12)
    log(f"{count} Trigger-Elemente für aktiven Klick")
    start_url = page.url
    for i in range(count):
        el = loc.nth(i)
        try:
            label = (el.inner_text(timeout=1000) or "").strip().replace("\n", " ")[:60]
            href = el.get_attribute("href")
            if href:
                col.add(href, "click:href")
            log(f"Klick #{i}: '{label}'")
            ctx = page.context
            with ctx.expect_page(timeout=timeout_ms) as popup_info:
                try:
                    with page.expect_download(timeout=timeout_ms) as dl_info:
                        el.click(timeout=2000)
                    col.add(dl_info.value.url, "click:download")
                except Exception:
                    pass
            try:
                popup = popup_info.value
                popup.wait_for_load_state("domcontentloaded", timeout=5000)
                if popup.url and popup.url != "about:blank":
                    col.add(popup.url, "click:popup")
                popup.close()
            except Exception:
                pass
        except Exception:
            # kein Popup/Download: Navigation oder DOM-Änderung prüfen
            if page.url != start_url:
                col.add(page.url, "click:navigation")
                page.goto(start_url, wait_until="networkidle")
        scan_dom(page, col)


def score(url: str) -> int:
    u = url.lower()
    return sum(1 for k in SCORE_KEYWORDS if k in u)


def verify(ctx, url: str, min_bytes: int) -> dict | None:
    """Lädt den Kandidaten und prüft, ob es wirklich ein PDF ist."""
    try:
        r = ctx.request.get(url, timeout=30000, headers={"Accept": "application/pdf,*/*"})
        body = r.body()
    except Exception as e:
        log(f"Verifikation fehlgeschlagen ({url}): {e}")
        return None
    ctype = r.headers.get("content-type", "")
    ok = r.status == 200 and body[:5] == b"%PDF-" and len(body) >= min_bytes
    log(f"Verify {url} -> {r.status}, {ctype}, {len(body)} B, ok={ok}")
    if not ok:
        return None
    return {
        "url": url,
        "final_url": r.url,
        "size_bytes": len(body),
        "sha256": hashlib.sha256(body).hexdigest(),
        "content_type": ctype,
        "_body": body,
    }


def run_once(url: str, debug_dir: Path, min_bytes: int, headless: bool) -> dict | None:
    col = Collector(base_url=url)
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=headless)
        ctx = browser.new_context(
            user_agent=USER_AGENT, locale="de-CH", viewport={"width": 1440, "height": 1000},
            accept_downloads=True,
        )
        page = ctx.new_page()
        page.on("response", col.on_response)
        try:
            page.goto(url, wait_until="networkidle", timeout=60000)
            page.wait_for_timeout(2500)  # späte Renderings abwarten
            scan_dom(page, col)

            result = _first_valid(ctx, col, min_bytes)
            if not result:
                click_triggers(page, col)
                page.wait_for_timeout(1500)
                result = _first_valid(ctx, col, min_bytes)

            if not result:
                debug_dir.mkdir(parents=True, exist_ok=True)
                page.screenshot(path=str(debug_dir / "page.png"), full_page=True)
                (debug_dir / "page.html").write_text(page.content(), encoding="utf-8")
                (debug_dir / "network.json").write_text(
                    json.dumps(col.netlog, indent=2, ensure_ascii=False), encoding="utf-8"
                )
                (debug_dir / "candidates.json").write_text(
                    json.dumps(col.candidates, indent=2, ensure_ascii=False), encoding="utf-8"
                )
                log(f"Debug-Artefakte geschrieben nach {debug_dir}")
            else:
                result["source"] = col.candidates.get(result["url"], "?")
            return result
        finally:
            ctx.close()
            browser.close()


def _first_valid(ctx, col: Collector, min_bytes: int) -> dict | None:
    for cand in sorted(col.candidates, key=score, reverse=True):
        res = verify(ctx, cand, min_bytes)
        if res:
            return res
    return None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawTextHelpFormatter)
    ap.add_argument("--url", default=os.getenv("MENU_URL", DEFAULT_URL))
    ap.add_argument("--json-out", type=Path, default=Path("menu_pdf.json"))
    ap.add_argument("--save-pdf", type=Path, help="PDF zusätzlich lokal speichern (optional)")
    ap.add_argument("--debug-dir", type=Path, default=Path("debug"))
    ap.add_argument("--retries", type=int, default=3)
    ap.add_argument("--min-bytes", type=int, default=5000)
    ap.add_argument("--headed", action="store_true", help="Browser sichtbar (lokales Debugging)")
    args = ap.parse_args()

    result = None
    for attempt in range(1, args.retries + 1):
        log(f"Versuch {attempt}/{args.retries}")
        try:
            result = run_once(args.url, args.debug_dir, args.min_bytes, not args.headed)
        except Exception as e:
            log(f"Fehler in Versuch {attempt}: {e!r}")
        if result:
            break
        time.sleep(5 * attempt)

    if not result:
        log("FEHLER: kein verifizierbarer PDF-Link gefunden")
        return 1

    body = result.pop("_body")
    result["page_url"] = args.url
    result["fetched_at"] = datetime.now(timezone.utc).isoformat()
    args.json_out.write_text(json.dumps(result, indent=2, ensure_ascii=False), encoding="utf-8")
    if args.save_pdf:
        args.save_pdf.parent.mkdir(parents=True, exist_ok=True)
        args.save_pdf.write_bytes(body)

    if gh_out := os.getenv("GITHUB_OUTPUT"):
        with open(gh_out, "a", encoding="utf-8") as f:
            f.write(f"pdf_url={result['url']}\n")
    if summary := os.getenv("GITHUB_STEP_SUMMARY"):
        with open(summary, "a", encoding="utf-8") as f:
            f.write(f"### Menü-PDF\n\n{result['url']}\n\n{result['size_bytes']} Bytes\n")

    print(result["url"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
