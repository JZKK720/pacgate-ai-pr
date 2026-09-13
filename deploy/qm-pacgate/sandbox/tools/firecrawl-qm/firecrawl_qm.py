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


def cmd_search(args: argparse.Namespace) -> None:
    payload = {"query": args.query, "limit": args.limit}
    if args.country:
        payload["country"] = args.country
    if args.lang:
        payload["lang"] = args.lang
    result = _request("POST", "/v1/search", payload)
    data = result.get("data", [])
    for item in data:
        print(f"- {item.get('title', '')}\n  {item.get('url', '')}\n  {item.get('description', '')}\n")


def cmd_scrape(args: argparse.Namespace) -> None:
    payload = {"url": args.url, "formats": ["markdown"]}
    result = _request("POST", "/v1/scrape", payload)
    md = result.get("markdown", "")
    print(md[: args.max_chars] if args.max_chars else md)


def cmd_crawl(args: argparse.Namespace) -> None:
    payload = {"url": args.url, "limit": args.limit}
    result = _request("POST", "/v1/crawl", payload)
    print(json.dumps(result, ensure_ascii=False, indent=2))


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Firecrawl web search/scrape/crawl for QM")
    sub = parser.add_subparsers(dest="command", required=True)

    s = sub.add_parser("search", help="Search the web")
    s.add_argument("query")
    s.add_argument("--limit", type=int, default=5)
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
