---
name: firecrawl-web
description: Search the web, scrape a page to markdown, or crawl a site using the Firecrawl API. Use when QM collaboration needs current web information, external sources, or page content extraction that the legal databases do not cover.
---

Use `firecrawl-qm search "<query>" [--limit N] [--country <cc>] [--lang <lang>]` to search the web and get ranked results with titles, URLs, and descriptions.

Use `firecrawl-qm scrape "<url>" [--max-chars N]` to fetch a single page and return its content as markdown.

Use `firecrawl-qm crawl "<url>" [--limit N] [--max-chars N]` to crawl a site. The command polls until the crawl finishes (default budget 180s, `--timeout`) and then prints each page's title, URL and markdown.

## Rules

- Prefer the legal databases (pacgate_connector_search / pacgate_kb_search) for legal authority. Use Firecrawl for current events, company news, regulatory announcements, and general web research.
- Never fabricate URLs or search results — only report what Firecrawl actually returns.
- For legal conclusions, always cite the source URL returned by Firecrawl and flag it as web-sourced (not authority-verified).
- A search hit is `auxiliary_db`, never authority. Do not cite a web page as a statute, regulation, or case.

## When the tool answers with an error

- `FIRECRAWL_API_KEY is required` — this deployment has no web key configured. Say the web lane is unavailable and continue with the legal databases; do not retry, and do not try to work around it.
- `Firecrawl API 401` / `403` — the configured key is wrong or revoked. Report it; a retry cannot fix it.
- `Firecrawl API 402` — the account is out of credits.
- `crawl ... did not finish within Ns` — the crawl is still running upstream. Use `scrape` on the specific pages you need instead of re-crawling.
- `Firecrawl returned no markdown for <url>` — the page exists but had no extractable body (a login wall, a JS-only shell, or a PDF that needs `parse`). Do not report the page as empty; report that it could not be read.

## Limits that are not bugs

- This tool cannot click, fill forms, or sign in. If a page needs interaction, look for an already-public document URL instead.
- A 25-page site crawl costs one credit per page. Prefer `search` + `scrape` on what you actually need.
- Markdown is truncated only when you pass `--max-chars`; without it the full page is printed.
