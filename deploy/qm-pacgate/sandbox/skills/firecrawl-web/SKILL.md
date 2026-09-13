---
name: firecrawl-web
description: Search the web, scrape a page to markdown, or crawl a site using the Firecrawl API. Use when QM collaboration needs current web information, external sources, or page content extraction that the legal databases do not cover.
---

Use `firecrawl-qm search "<query>" [--limit N] [--country <cc>] [--lang <lang>]` to search the web and get ranked results with titles, URLs, and descriptions.

Use `firecrawl-qm scrape "<url>" [--max-chars N]` to fetch a single page and return its content as markdown.

Use `firecrawl-qm crawl "<url>" [--limit N]` to crawl a site and return discovered pages.

## Rules

- Prefer the legal databases (pacgate_connector_search / pacgate_kb_search) for legal authority. Use Firecrawl for current events, company news, regulatory announcements, and general web research.
- Never fabricate URLs or search results — only report what Firecrawl actually returns.
- For legal conclusions, always cite the source URL returned by Firecrawl and flag it as web-sourced (not authority-verified).
