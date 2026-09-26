#!/usr/bin/env python3
"""
Dispatch the GHCR release workflow on the pacgate-ai fork, via the UI.

Companion to sync-fork-via-ui.py. Same model: you sign in by hand, this drives
the clicks and then VERIFIES the result from the page rather than trusting that
a click worked.

PREREQUISITE: the fork must already be synced to origin/main, so it carries the
workflow fix (the OCI Accept header). Running this on an un-synced fork will
start a run that fails at the verify step. The script checks for the fix first
and refuses if it is missing.

USAGE
    set PLAYWRIGHT_BROWSERS_PATH=%LOCALAPPDATA%\\ms-playwright
    python scripts/dispatch-release-via-ui.py --tag 0.1.12

    Options:
      --tag <x.y.z>    image tag to build (required)
      --user <login>   account login that must be signed in
                       (default: the owner of this checkout's origin remote)
      --profile <dir>  persistent browser profile (keeps you signed in)
      --headless       hide the window (you still must already be signed in)
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
import time

try:
    from playwright.sync_api import sync_playwright, TimeoutError as PWTimeout
except ImportError:
    sys.exit("playwright is not installed. python -m pip install playwright")

# The repo to dispatch is a property of THIS CHECKOUT, not of this script.
#
# It was hardcoded as "pacgate-ai/pacgate-ai-pr". That is now the READ-ONLY
# MIRROR, which publishes NO images: per .github/workflows/build-ghcr.yml
# (2026-09-18), `jzkk720` is the release authority for both code and images, and
# `pacgate-ai` is a read-only mirror. Dispatching against the mirror starts a run
# that fails at the verify step, because `secrets.GITHUB_TOKEN` can only push to
# the namespace of the account that runs the workflow.
#
# Deriving it from the origin remote means the value cannot go stale when the
# remote moves again - the same failure mode as hardcoding a model tag in a crate
# while the machines carried something else.
FALLBACK_FORK = "JZKK720/pacgate-ai-pr"


def resolve_fork() -> str:
    """Return 'owner/repo' for the checkout this script is running inside."""
    try:
        out = subprocess.run(
            ["git", "remote", "get-url", "origin"],
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        url = (out.stdout or "").strip()
        # https://github.com/owner/repo(.git) and git@github.com:owner/repo(.git)
        m = re.search(r"github\.com[:/]+([^/]+)/([^/]+?)(?:\.git)?$", url)
        if m:
            return f"{m.group(1)}/{m.group(2)}"
    except Exception:
        pass
    print(f"[dispatch-release] WARNING: could not read the origin remote; using {FALLBACK_FORK}")
    return FALLBACK_FORK


FORK = resolve_fork()
FORK_OWNER = FORK.split("/", 1)[0]
WORKFLOW_URL = f"https://github.com/{FORK}/actions/workflows/build-ghcr.yml"
ACTIONS_URL = f"https://github.com/{FORK}/actions"


def log(msg: str) -> None:
    print(f"[dispatch-release] {msg}", flush=True)


def goto_settled(page, url: str) -> None:
    page.goto(url, wait_until="domcontentloaded")
    try:
        page.wait_for_load_state("networkidle", timeout=15000)
    except PWTimeout:
        pass
    time.sleep(1.5)


def signed_in_login(page) -> str | None:
    """Authoritative sign-in check via GitHub's meta tag.

    Deliberately avoids body-text scanning: measured that the compare page
    contains the string "Sync fork" (from our own committed docs) while signed
    out, so text checks are unreliable.
    """
    try:
        meta = page.query_selector('meta[name="user-login"]')
        if meta:
            val = (meta.get_attribute("content") or "").strip()
            if val:
                return val
    except Exception:
        pass
    try:
        if page.query_selector('a[href="/login"], a[href^="/login?"]'):
            return None
    except Exception:
        pass
    return None


def find_control(page, *texts):
    for t in texts:
        for sel in ("button", "a", "summary"):
            for el in page.query_selector_all(sel):
                try:
                    if not el.is_visible():
                        continue
                    if (el.inner_text() or "").strip().lower() == t.lower():
                        return el
                except Exception:
                    continue
    return None


def workflow_has_accept_fix(page) -> bool | None:
    """Confirm the synced workflow carries the OCI Accept header.

    Reads the raw file from the fork's default branch. Returns None if it could
    not be read (treated as 'unknown', and the caller refuses rather than
    guessing).
    """
    try:
        page.goto(
            f"https://raw.githubusercontent.com/{FORK}/main/.github/workflows/build-ghcr.yml",
            wait_until="domcontentloaded",
        )
        txt = page.inner_text("body")
        if "404" in txt[:60] and "Not Found" in txt:
            return None
        return "Accept: $ACCEPT" in txt or "manifest.list.v2+json" in txt
    except Exception:
        return None


def latest_run_ids(page) -> set[str]:
    """Collect run URLs currently listed on the Actions page."""
    ids: set[str] = set()
    try:
        for a in page.query_selector_all('a[href*="/actions/runs/"]'):
            href = a.get_attribute("href") or ""
            m = re.search(r"/actions/runs/(\d+)", href)
            if m:
                ids.add(m.group(1))
    except Exception:
        pass
    return ids


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--tag", required=True, help="image tag, e.g. 0.1.12")
    ap.add_argument(
        "--user",
        default=FORK_OWNER,
        help=f"account login that must be signed in (default: {FORK_OWNER}, the repo owner)",
    )
    ap.add_argument("--profile", default=".playwright-profile")
    ap.add_argument("--headless", action="store_true")
    args = ap.parse_args()

    if not re.fullmatch(r"\d+\.\d+\.\d+", args.tag):
        return _fail(f"--tag must look like 0.1.12 (got {args.tag!r})")

    log(f"repository: {FORK}  (derived from the origin remote)")
    log(f"expecting sign-in as: {args.user}")

    with sync_playwright() as p:
        ctx = p.chromium.launch_persistent_context(
            args.profile, headless=args.headless, viewport={"width": 1400, "height": 950}
        )
        page = ctx.pages[0] if ctx.pages else ctx.new_page()

        # ── 1. Sign-in check ────────────────────────────────────────────────
        goto_settled(page, WORKFLOW_URL)
        login = signed_in_login(page)
        if not login:
            log("Not signed in. Open the window and sign in, then re-run.")
            log("  https://github.com/login")
            ctx.close()
            return 2
        log(f"signed in as: {login}")
        if login.lower() != args.user.lower():
            log(f"REFUSING: signed in as {login!r}, expected {args.user!r}.")
            log("Nothing was changed. Sign out and sign in as the fork owner.")
            ctx.close()
            return 3

        # ── 2. Prerequisite: workflow fix present? ──────────────────────────
        fix = workflow_has_accept_fix(page)
        if fix is None:
            log("REFUSING: could not read the workflow from the fork's default branch.")
            log("Most likely the fork has not been synced yet. Run:")
            log("    python scripts/sync-fork-via-ui.py")
            ctx.close()
            return 4
        if not fix:
            log("REFUSING: the fork's workflow does NOT contain the OCI Accept fix.")
            log("Dispatching now would start a run that fails at the verify step")
            log("(that is the 7/7 failure this fix exists to repair). Sync first:")
            log("    python scripts/sync-fork-via-ui.py")
            ctx.close()
            return 5
        log("prerequisite OK: workflow carries the Accept-header fix")

        # ── 3. Dispatch ─────────────────────────────────────────────────────
        goto_settled(page, WORKFLOW_URL)
        before = latest_run_ids(page)

        run_btn = find_control(page, "Run workflow")
        if not run_btn:
            log("Could not find a 'Run workflow' button. It only renders for users")
            log("with write access. Screenshot saved.")
            page.screenshot(path="dispatch-debug.png", full_page=True)
            ctx.close()
            return 6

        run_btn.click()
        time.sleep(1.5)

        # The dispatch form: tag input + a second "Run workflow" confirm.
        tag_input = None
        for sel in ("input[name='inputs[tag]']", "input#inputs\\[tag\\]", "input[type='text']"):
            try:
                el = page.query_selector(sel)
                if el and el.is_visible():
                    tag_input = el
                    break
            except Exception:
                continue

        if not tag_input:
            log("Could not find the 'tag' input. Screenshot saved.")
            page.screenshot(path="dispatch-no-tag-input.png", full_page=True)
            ctx.close()
            return 7

        tag_input.fill(args.tag)
        log(f"filled tag = {args.tag}")

        # Leave namespace empty: it resolves to the fork owner (pacgate-ai),
        # which is what the compose pins reference.
        confirm = find_control(page, "Run workflow")
        if not confirm:
            log("Could not find the confirm button. Screenshot saved.")
            page.screenshot(path="dispatch-no-confirm.png", full_page=True)
            ctx.close()
            return 8

        confirm.click()
        log("dispatched - waiting for the run to appear")
        time.sleep(6)

        # ── 4. VERIFY a new run exists ──────────────────────────────────────
        for attempt in range(1, 7):
            goto_settled(page, ACTIONS_URL)
            after = latest_run_ids(page)
            new = after - before
            if new:
                log(f"VERIFIED: new run started -> {sorted(new)[0]}")
                log(f"  https://github.com/{FORK}/actions/runs/{sorted(new)[0]}")
                log("")
                log("Watch it go green (this should be the FIRST successful run -")
                log("every previous run failed at the verify step).")
                log("")
                log("Then, once green, flip the new packages to Public in the UI:")
                log("  profile -> Packages -> each pacgate image -> Package settings")
                log("  -> Visibility -> Public")
                log("Verified with:")
                log(f"  pwsh -NoProfile -File ./scripts/check-ghcr-pull.ps1 -Targets 'pacgate-ai/pacgate-api:{args.tag}'")
                ctx.close()
                return 0
            log(f"  attempt {attempt}: no new run yet")
            time.sleep(5)

        log("NOT CONFIRMED: no new run appeared. Check the Actions page manually.")
        page.screenshot(path="dispatch-after.png", full_page=True)
        ctx.close()
        return 9


def _fail(msg: str) -> int:
    log(msg)
    return 1


if __name__ == "__main__":
    sys.exit(main())
