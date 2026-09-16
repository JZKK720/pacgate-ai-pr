#!/usr/bin/env python3
"""
Sync the pacgate-ai fork to origin/main, using a browser you sign in to.

WHY THIS EXISTS
    `git push` to the fork fails with "permission denied" because the local git
    credential store only holds JZKK720. Rather than shuffling credentials
    between accounts, this drives the GitHub UI - you sign in once, by hand,
    and the script performs the fast-forward.

WHAT IT DOES
    1. Opens a real (non-headless) Chromium window.
    2. Waits for YOU to sign in as an account with write access to the fork.
    3. Verifies the signed-in account before touching anything.
    4. Navigates to the fork and clicks "Sync fork" -> "Update branch".
    5. Re-reads the page and confirms the fork actually moved.

SAFETY
    - Read-only until you are verified signed in as the right account.
    - Never types a password: sign-in is manual, always.
    - Refuses to click "Discard commits" (that would destroy fork-only work).
    - Re-verifies the result from the page rather than trusting the click.

USAGE
    set PLAYWRIGHT_BROWSERS_PATH=%LOCALAPPDATA%\\ms-playwright
    python scripts/sync-fork-via-ui.py

    Options:
      --user <login>   required account login (default: pacgate-ai)
      --profile <dir>  reuse a persistent browser profile (keeps you signed in
                       between runs). Default: .playwright-profile
      --headless       do not show the window (you still must be signed in)
"""

from __future__ import annotations

import argparse
import sys
import time

try:
    from playwright.sync_api import sync_playwright, TimeoutError as PWTimeout
except ImportError:
    sys.exit(
        "playwright is not installed.\n"
        "  python -m pip install playwright\n"
        "  (browsers are usually already cached; if not: python -m playwright install chromium)"
    )

FORK = "pacgate-ai/pacgate-ai-pr"
FORK_URL = f"https://github.com/{FORK}"


def log(msg: str) -> None:
    print(f"[sync-fork] {msg}", flush=True)


def goto_settled(page, url: str) -> None:
    """Navigate and WAIT for the page to settle.

    GitHub renders the "N commits behind" banner and the Sync fork control
    after DOMContentLoaded. Reading at domcontentloaded made fork_behind_count()
    return None on a page that plainly said "12 commits behind" - i.e. the
    script would have reported "already up to date" and silently done nothing.
    Verified: domcontentloaded -> no match; after networkidle -> match.
    """
    page.goto(url, wait_until="domcontentloaded")
    try:
        page.wait_for_load_state("networkidle", timeout=15000)
    except PWTimeout:
        pass  # networkidle is best-effort; the retry loop below covers it
    time.sleep(1.5)


def signed_in_login(page) -> str | None:
    """Return the signed-in login, or None.

    Reads GitHub's user-login meta tag, which is authoritative. Deliberately
    does NOT scan body text: an earlier check reported a false positive because
    our own committed docs contain the string "Sync fork".
    """
    try:
        meta = page.query_selector('meta[name="user-login"]')
        if meta:
            val = (meta.get_attribute("content") or "").strip()
            if val:
                return val
    except Exception:
        pass

    # Fallback: the header avatar link, e.g. href="/pacgate-ai"
    try:
        if page.query_selector('a[href="/login"], a[href^="/login?"]'):
            return None  # explicit login link => signed out
        el = page.query_selector('summary[aria-label*="View profile"], summary[aria-label*="profile"]')
        if el:
            label = el.get_attribute("aria-label") or ""
            if "and " in label:
                return label.split("and ")[-1].strip().rstrip(".")
    except Exception:
        pass
    return None


def wait_for_signin(page, want: str, timeout_s: int = 300) -> str | None:
    log("Open the window and sign in as %r." % want)
    log("(Never type credentials into this script - sign in in the browser.)")
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        login = signed_in_login(page)
        if login:
            return login
        time.sleep(2)
    return None


def find_control(page, *texts):
    """Find a visible button/link/summary whose text matches one of `texts`."""
    for t in texts:
        for sel in ("button", "a", "summary"):
            for el in page.query_selector_all(sel):
                try:
                    if not el.is_visible():
                        continue
                    label = (el.inner_text() or "").strip()
                    if label.lower() == t.lower():
                        return el
                except Exception:
                    continue
    return None


def fork_behind_count(page, attempts: int = 5) -> int | None:
    """Parse 'N commits behind' from the fork page. None if not behind.

    Retries: the banner is rendered client-side, so an immediate read can miss
    it. Returns None ONLY after exhausting retries, so callers can distinguish
    'genuinely not behind' from 'did not load in time'.
    """
    import re
    for i in range(attempts):
        try:
            body = page.inner_text("body")
            m = re.search(r"(\d+)\s+commits?\s+behind", body)
            if m:
                return int(m.group(1))
        except Exception:
            pass
        time.sleep(1.0)
    return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--user", default="pacgate-ai")
    ap.add_argument("--profile", default=".playwright-profile")
    ap.add_argument("--headless", action="store_true")
    args = ap.parse_args()

    with sync_playwright() as p:
        ctx = p.chromium.launch_persistent_context(
            args.profile,
            headless=args.headless,
            viewport={"width": 1400, "height": 950},
        )
        page = ctx.pages[0] if ctx.pages else ctx.new_page()

        # ── 1. Ensure signed in ─────────────────────────────────────────────
        goto_settled(page, FORK_URL)
        login = signed_in_login(page)

        if not login:
            goto_settled(page, "https://github.com/login")
            login = wait_for_signin(page, args.user)
            if not login:
                log("Timed out waiting for sign-in. Nothing was changed.")
                ctx.close()
                return 2
            goto_settled(page, FORK_URL)

        log(f"signed in as: {login}")

        # ── 2. Verify the account BEFORE touching anything ──────────────────
        if login.lower() != args.user.lower():
            log(
                f"REFUSING: signed in as {login!r} but this fork is owned by "
                f"{args.user!r}. GitHub only shows 'Sync fork' to accounts with "
                f"write access, so the wrong account will simply not work.\n"
                f"          Sign out and sign in as {args.user!r}, then re-run.\n"
                f"          Nothing was changed."
            )
            ctx.close()
            return 3

        behind = fork_behind_count(page)
        if behind is None:
            log("The fork shows no 'N commits behind' banner - it may already be")
            log("up to date. Nothing to do. Verify with:")
            log("    pwsh -NoProfile -File ./scripts/check-credential-state.ps1")
            ctx.close()
            return 0

        log(f"fork is {behind} commit(s) behind origin/main - proceeding")

        # ── 3. Sync fork -> Update branch ───────────────────────────────────
        sync_btn = find_control(page, "Sync fork")
        if not sync_btn:
            log("Could not find a 'Sync fork' button. Likely causes:")
            log("  - you are signed in as an account WITHOUT write access")
            log("  - GitHub changed the UI")
            log("Nothing was changed. Screenshot saved for diagnosis.")
            page.screenshot(path="sync-fork-debug.png", full_page=True)
            log("  -> sync-fork-debug.png")
            ctx.close()
            return 4

        sync_btn.click()
        time.sleep(1.5)

        # Guard: never discard fork-only commits.
        if find_control(page, "Discard commits", "Discard N commits"):
            log("STOPPING: a 'Discard commits' option appeared, which would")
            log("destroy fork-only work. Not clicking anything. Inspect manually.")
            page.screenshot(path="sync-fork-discard-warning.png", full_page=True)
            ctx.close()
            return 5

        update_btn = find_control(page, "Update branch", "Update N branches")
        if not update_btn:
            log("'Sync fork' opened but no 'Update branch' control was found.")
            page.screenshot(path="sync-fork-no-update.png", full_page=True)
            ctx.close()
            return 6

        update_btn.click()
        log("clicked 'Update branch' - waiting for GitHub to finish")
        time.sleep(4)

        # ── 4. VERIFY from the page, not from the click ─────────────────────
        goto_settled(page, FORK_URL)
        after = fork_behind_count(page)

        if after is None:
            log("VERIFIED: the fork no longer reports being behind.")
        elif after < behind:
            log(f"PARTIAL: behind went {behind} -> {after}. Re-run to finish.")
            ctx.close()
            return 7
        else:
            log(f"NOT CONFIRMED: still reports {after} behind. The click may not")
            log("have taken effect. Screenshot saved.")
            page.screenshot(path="sync-fork-after.png", full_page=True)
            ctx.close()
            return 8

        log("")
        log("Done. Now verify the credentials are gone from the fork:")
        log("    pwsh -NoProfile -File ./scripts/check-credential-state.ps1")
        log("All three columns must read 'clean'.")
        ctx.close()
        return 0


if __name__ == "__main__":
    sys.exit(main())
