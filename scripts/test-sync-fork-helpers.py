#!/usr/bin/env python3
"""
Self-test for scripts/sync-fork-via-ui.py helpers.

Runs against the live, SIGNED-OUT GitHub pages only. It never signs in, never
clicks a control that changes state, and never needs credentials. Purpose is to
catch the class of bug that actually bit this script: a helper that silently
returns None because the page had not finished rendering.

Usage:
    set PLAYWRIGHT_BROWSERS_PATH=%LOCALAPPDATA%\\ms-playwright
    python scripts/test-sync-fork-helpers.py
"""

from __future__ import annotations

import importlib.util
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("sf", HERE / "sync-fork-via-ui.py")
sf = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(sf)

from playwright.sync_api import sync_playwright  # noqa: E402

FORK_URL = "https://github.com/pacgate-ai/pacgate-ai-pr"

results: list[tuple[str, bool, str]] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    results.append((name, ok, detail))
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}" + (f"  {detail}" if detail else ""))


def main() -> int:
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        page = browser.new_page()

        print("Testing against signed-out GitHub pages (no state is changed).")

        # 1. Signed-out detection must be reliable. A previous version scanned
        #    body text and produced a FALSE POSITIVE, because our own committed
        #    documentation contains the literal string "Sync fork".
        sf.goto_settled(page, FORK_URL)
        login = sf.signed_in_login(page)
        check("signed_in_login returns None when signed out", login is None, f"got {login!r}")

        # 2. Text-scanning for UI state is unsafe. This is measured, not assumed:
        #    the FORK page does not contain "Sync fork" when signed out, but the
        #    COMPARE page DOES - because it renders the commit diff, and our own
        #    committed docs describe "Sync fork". A body-text check therefore
        #    disagrees with itself depending on which page you are on, which is
        #    exactly how an earlier version reported hasSyncFork=True while the
        #    browser was signed out.
        fork_body = page.inner_text("body")
        check(
            "fork page does not leak a 'Sync fork' string when signed out",
            "Sync fork" not in fork_body,
            "so a fork-page text scan would accidentally be right",
        )

        sf.goto_settled(page, FORK_URL + "/compare/main...JZKK720:pacgate-ai-pr:main")
        compare_body = page.inner_text("body")
        check(
            "compare page DOES contain 'Sync fork' (via our own doc text)",
            "Sync fork" in compare_body,
            "=> proves body-text UI detection is unreliable across pages",
        )

        sf.goto_settled(page, FORK_URL)

        # 3. The behind-count must survive page-load timing. This is the bug the
        #    script had: reading at domcontentloaded returned None on a page that
        #    said "12 commits behind", which would have reported "already
        #    up to date" and silently done nothing.
        behind = sf.fork_behind_count(page)
        check("fork_behind_count detects the behind banner", behind is not None, f"got {behind}")

        if behind is not None:
            raw = re.search(r"(\d+)\s+commits?\s+behind", page.inner_text("body"))
            match = raw is not None and int(raw.group(1)) == behind
            check("behind count matches the page text", match, f"page={raw.group(0) if raw else '?'} parsed={behind}")

        # 4. The sync control must NOT be findable while signed out, otherwise
        #    the script would try to click something that is not there.
        ctrl = sf.find_control(page, "Sync fork")
        check("'Sync fork' control not found when signed out", ctrl is None, f"got {ctrl!r}")

        browser.close()

    failed = [r for r in results if not r[1]]
    print()
    print(f"{len(results) - len(failed)}/{len(results)} checks passed.")
    if failed:
        print("FAILURES:")
        for name, _, detail in failed:
            print(f"  - {name} {detail}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
