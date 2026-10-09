# Upstream Release Handoff — port two fixes, cut 0.1.21

> For: the maintainer of `JZKK720/pacgate-ai-pr` (or an agent working in that repo).
> Everything below is verified against the live stack on AIPC #1 (2026-09-29/30).
> Evidence: `deploy/BENCHMARK-REPORT-2026-09-29.md` (committed on this branch).

## Why

Two production defects were found by benchmarking the running 0.1.20 stack and
fixed on the deployment machine. They are **not yet in this repo**, and the
machine's working copy (`pacgate-law` monorepo) has no push target — so the
fixes exist only as a locally rebuilt image and local commits. Until they land
upstream and a new image is published, **every AIPC silently loses the MCP fix
on its next `docker compose pull`**.

## The two fixes to port

Paths map 1:1 — the deployment monorepo nests everything under `pacgate-ai/`,
so `pacgate-ai/deploy/X` here = `deploy/X` there. **Port the logic, not the
files**: the monorepo copies carry GBK-mojibake em-dashes in comments from a
PowerShell read; this repo's files are clean.

### Fix 1 — pacgate-mcp serves 401s forever after 24 h (code change)

`deploy/pacgate-mcp/server.py`. pacgate-api issues **24-hour JWTs**
(`pacgate-core/src/lib.rs` L97: `Duration::hours(24)`), but `PacgateApi` logs
in exactly once in `__init__` and has no 401 handling — so 24 h after every
(re)start, every MCP tool call returns `pacgate-api error 401` until the
container is recreated. Observed live: login 09-28 07:33 → tools OK 09-29
05:33/05:35 → first 401 at 08:05, exactly the 24 h boundary.

Port: add a `_relogin()` method and a retry-once-on-401 wrapper in
`get`, `post`, `delete`, and `post_multipart` (retry only when
`self.email and self.password` are set — a `PACGATE_JWT_TOKEN`-only
deployment has nothing to re-login with). The monorepo commit is `d3ebf7b`
(class body 2,324 → 3,733 chars; 5 `_relogin` sites). Same method set
otherwise — verified structurally identical.

### Fix 2 — ocr-service re-downloads its model weights on every recreate (compose only)

`deploy/client-bundle/compose.bundle.yaml` **and** `compose.prod.yaml`
(both define the service; `scripts/test-ner-enabled.ps1` checks both).
PaddleOCR downloads its PP-OCRv4 det/rec/cls weights (~18 MB) into
`/root/.paddleocr` on first extraction — **not baked into the image**
(verified: a fresh container from `ghcr.io/jzkk720/ocr-service:0.1.20` has
no `/root/.paddleocr`). The service declared no volume, so the cache lived
in the container's writable layer and was lost on every recreate, forcing a
re-download from `paddleocr.bj.bcebos.com` — the only source. An offline
recreate leaves ocr-service unable to initialise and every extraction fails
closed.

Port: add to the `ocr-service` service in both files:

```yaml
    volumes:
      - paddleocr-models:/root/.paddleocr
```

and to the top-level `volumes:` block:

```yaml
  paddleocr-models:
```

Monorepo commit `77569d7`. Applied live: volume created, one warmup
extraction, weights in the volume, `POST /extract` → 200.

## Also on this branch (already committed, push as-is)

- `def8ee5` — `scripts/test-legal-journey.ps1`: the qm and OpenViking lanes
  reported SKIP on a healthy stack because the probes were wrong (qm's portal
  is an OIDC front door — 401 on every path by design, `/healthz` is the
  liveness surface; OpenViking's real lane is the MCP endpoint, and its
  extractor dedupes near-identical probes). Now 17 assertions, 0 SKIP.
- `58f2291` — `deploy/BENCHMARK-REPORT-2026-09-29.md`: measured latencies for
  every surface (reads ≤116 ms, OCR 3–5 s cold / 6 ms cached, sanitize 24.7 s
  first-run NER build, OpenViking recall 40–55 s async, local LLM 25.6 s
  baseline) plus the two defect write-ups above.

## Release mechanics (verified from `build-ghcr.yml`)

A **plain push to main builds nothing** — the trigger is `push: tags:
v0.1.*` plus `workflow_dispatch` with a required `tag` input. So:

1. Port the two fixes (above).
2. Bump the version: workspace `pacgate-ai/Cargo.toml` → `0.1.21` and all five
   `image:` pins in both compose files (`bump-release-version.ps1` does this;
   verify with `scripts/test-model-roster-consistency.ps1`).
3. Push main to the fork (`pacgate-ai/pacgate-ai-pr`) — fast-forward, verified
   `7e0aa4b..58f2291` dry-run exit 0.
4. Open the PR fork → `JZKK720/pacgate-ai-pr`, merge.
5. Publish: `workflow_dispatch` with `tag=0.1.21` (safer than a tag push —
   decouples the published tag from the build commit; the 0.1.14 release
   failed exactly because a tag pointed at a commit with an invalid workflow).
6. Verify: all five images at 0.1.20→0.1.21 on GHCR (anonymous manifest HEAD
   is 200), then on an AIPC `docker compose pull && docker compose up -d` and
   confirm `/version` reports 0.1.21 and `pacgate-mcp` contains `_relogin`.

## Acceptance (per machine, after the pull)

```powershell
curl.exe -s http://localhost:8089/version          # {"version":"0.1.21",...}
docker exec pacgate-mcp grep -c _relogin /app/server.py   # 5, not 0
docker exec ocr-service sh -c "ls /root/.paddleocr/whl"    # det rec cls (from the volume)
pwsh -File scripts/test-legal-journey.ps1          # 17 assertions, 0 SKIP
```

## Traps (all hit on this machine)

- `docker compose pull` overwrites a locally rebuilt tag with the published
  image — expected, but it means the MCP fix is lost until 0.1.21 exists.
- The monorepo's `build-ghcr.yml` is stale (pre-`e3413d3`); do not port CI
  files from there — this repo's workflow is authoritative.
- `docker.io` is unreachable from the AIPC (VPN does not proxy it); image
  builds there need the daocloud mirror retag trick
  (`docker pull docker.m.daocloud.io/library/python:3.12-slim` + retag).
  CI builds on GitHub are unaffected.
- PowerShell 5.1 cannot run the gate suite (`pwsh`-only APIs); PowerShell 7
  is installed on the AIPC at
  `%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe`.