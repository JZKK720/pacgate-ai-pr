#!/usr/bin/env python3
"""Firecrawl QM tool — web search / scrape / crawl via the Firecrawl API.

Exposes a small CLI that QM's sandbox can call to search the web, scrape a
page, or crawl a site. Reads the API key from the FIRECRAWL_API_KEY env var
(secret, injected via the QM sandbox secretEnv).
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.request
import urllib.parse
import urllib.error


class FirecrawlToolError(RuntimeError):
    pass


def _api_key() -> str:
    key = os.environ.get("FIRECRAWL_API_KEY", "").strip()
    if not key:
        raise FirecrawlToolError("FIRECRAWL_API_KEY is required")
    return key


def _request(method: str, path: str, payload: dict | None = None) -> dict:
    key = _api_key()
    url = "https://api.firecrawl.dev" + path
    headers = {
        "Authorization": f"Bearer {key}",
        "Content-Type": "application/json",
    }
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            raw = resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", "replace")
        raise FirecrawlToolError(f"Firecrawl API {exc.code} {path}: {body}") from exc
    except urllib.error.URLError as exc:
        raise FirecrawlToolError(f"Unable to reach Firecrawl API: {exc.reason}") from exc
    if not raw:
        return {}
    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        raise FirecrawlToolError(f"Firecrawl API returned invalid JSON for {path}") from exc


def _payload_data(result: dict) -> dict:
    """The `data` envelope every Firecrawl v1 endpoint returns.

    Guarded because `data` is a LIST on /search and an OBJECT on /scrape. An
    earlier version assumed the object shape everywhere, so scrape read
    `result["markdown"]` off the TOP level - where the key does not exist - and
    printed an empty string with exit code 0. The agent then reported an empty
    page as if the site had no content, which is indistinguishable from a real
    result.
    """
    data = result.get("data")
    return data if isinstance(data, dict) else {}


def cmd_search(args: argparse.Namespace) -> None:
    payload = {"query": args.query, "limit": args.limit}
    if args.country:
        payload["country"] = args.country
    if args.lang:
        payload["lang"] = args.lang
    result = _request("POST", "/v1/search", payload)
    if result.get("success") is False:
        raise FirecrawlToolError(f"Firecrawl reported success=false for {args.query!r}")
    data = result.get("data")
    # v2 answers with {"data": {"web": [...]}} while v1 answers with {"data": [...]}.
    # Accept both so an endpoint move cannot silently produce "no results".
    if isinstance(data, dict):
        data = data.get("web") or data.get("results") or []
    if not isinstance(data, list):
        data = []
    if not data:
        print(f"No results for {args.query!r}.")
        return
    for item in data:
        if not isinstance(item, dict):
            continue
        # Search descriptions can carry the whole page in markdown (measured:
        # 12,156 chars for one result). Clipped so a 5-result search cannot
        # flood the sandbox agent's context with page bodies.
        description = (item.get("description") or "").strip()
        if len(description) > args.snippet_chars:
            description = description[: args.snippet_chars].rstrip() + "..."
        print(f"- {item.get('title', '')}\n  {item.get('url', '')}\n  {description}\n")


def cmd_scrape(args: argparse.Namespace) -> None:
    payload = {"url": args.url, "formats": ["markdown"]}
    result = _request("POST", "/v1/scrape", payload)
    if result.get("success") is False:
        raise FirecrawlToolError(f"Firecrawl reported success=false for {args.url}")
    # data.markdown, NOT result.markdown - see _payload_data's docstring.
    data = _payload_data(result)
    md = data.get("markdown") or ""
    if not md.strip():
        raise FirecrawlToolError(
            f"Firecrawl returned no markdown for {args.url} "
            f"(status={data.get('metadata', {}).get('statusCode', 'unknown')})"
        )
    meta = data.get("metadata") or {}
    title = meta.get("title") or ""
    if title:
        print(f"# {title}\n")
    print(md[: args.max_chars] if args.max_chars else md)


def cmd_crawl(args: argparse.Namespace) -> None:
    """Start a crawl, poll to completion, then print the pages.

    The old version printed the START acknowledgement
    (`{"success": true, "id": ..., "url": ...}`) and exited. That object contains
    no page content at all, so the agent got a job ticket where it expected a
    site. Crawls are asynchronous; the id has to be polled.
    """
    payload = {"url": args.url, "limit": args.limit}
    started = _request("POST", "/v1/crawl", payload)
    job_id = started.get("id")
    pages = None
    if not job_id:
        # A one-page site can come back already completed instead of queued.
        if started.get("data"):
            pages = started["data"]
        else:
            raise FirecrawlToolError(
                f"Firecrawl did not return a crawl id for {args.url}: "
                f"{json.dumps(started)[:300]}"
            )
    else:
        deadline = time.time() + args.timeout
        while time.time() < deadline:
            status = _request("GET", f"/v1/crawl/{job_id}")
            state = status.get("status")
            if state == "completed":
                pages = status.get("data") or []
                break
            if state in ("failed", "cancelled"):
                raise FirecrawlToolError(
                    f"crawl {job_id} ended {state}: {json.dumps(status)[:300]}"
                )
            time.sleep(args.interval)
        else:
            raise FirecrawlToolError(
                f"crawl {job_id} did not finish within {args.timeout}s; "
                f"poll https://api.firecrawl.dev/v1/crawl/{job_id} later"
            )

    pages = pages or []
    if not pages:
        print(f"No pages crawled from {args.url}.")
        return
    print(f"{len(pages)} page(s) from {args.url}\n")
    for page in pages:
        if not isinstance(page, dict):
            continue
        meta = page.get("metadata") or {}
        print(f"## {meta.get('title') or meta.get('sourceURL') or ''}")
        print(f"{meta.get('sourceURL') or ''}\n")
        md = page.get("markdown") or ""
        print(md[: args.max_chars] if args.max_chars else md)
        print()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Firecrawl web search/scrape/crawl for QM")
    sub = parser.add_subparsers(dest="command", required=True)

    s = sub.add_parser("search", help="Search the web")
    s.add_argument("query")
    s.add_argument("--limit", type=int, default=5)
    s.add_argument("--snippet-chars", type=int, default=400)
    s.add_argument("--country")
    s.add_argument("--lang")
    s.set_defaults(func=cmd_search)

    sc = sub.add_parser("scrape", help="Scrape a single page to markdown")
    sc.add_argument("url")
    sc.add_argument("--max-chars", type=int, default=0)
    sc.set_defaults(func=cmd_scrape)

    c = sub.add_parser("crawl", help="Crawl a site")
    c.add_argument("url")
    c.add_argument("--limit", type=int, default=10)
    c.add_argument("--max-chars", type=int, default=0)
    c.add_argument("--timeout", type=int, default=180)
    c.add_argument("--interval", type=float, default=3.0)
    c.set_defaults(func=cmd_crawl)

    return parser


def main() -> None:
    parser = build_parser()
    args = parser.parse_args()
    try:
        args.func(args)
    except FirecrawlToolError as e:
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
