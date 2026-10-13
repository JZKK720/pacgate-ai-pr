# DEFECT: the frontend proxy killed every agent run longer than 30 s

**Status:** FIXED 2026-10-13 (ships without an image rebuild - see "How it reaches clients")
**Severity:** HIGH - the caller received an error while the run kept executing server-side, so
long legal-research and document-generation tasks were unusable from the UI and through nginx.
**Present in:** every deployment that inherited Next.js's default `proxyTimeout` (i.e. all of
them - the parameter was never set anywhere in this repo).
**Found by:** authenticating to deer-flow and firing real generations end to end (2026-10-13).
The picker and generation paths had previously been reported as "could not check"; they were
never actually exercised until then.

## The symptom

"The model generated fine - but my HTTP request got 500." Generation ran, the run record said
`success`, and the caller still never got the result. It read as "the model cannot generate"
and as "pacgate-api / deer-flow frontend lost connection". The model was never the problem.

## The defect

`deer-flow-frontend` is a Next.js app whose `rewrites()` proxy `/api/:path*` to the deer-flow
gateway. Next.js proxies those destinations and **`experimental.proxyTimeout` defaults to
30000 ms**. Every gateway call longer than 30 s had its socket torn down mid-flight.

The frontend logged the exact shape:

```
Failed to proxy http://deer-flow:8001/api/threads/<id>/runs/wait
Error: socket hang up  { code: 'ECONNRESET' }
```

## How it was isolated

The same request on three paths:

| Path | Result |
| --- | --- |
| nginx `:8089` (client-facing) | **HTTP 500 at 30.1 s** |
| frontend `:8090` (no nginx) | HTTP 200 at 23.8 s, `REPLY=PONG` |
| gateway `:8001` (no proxy) | HTTP 200 at 27.0 s |

Meanwhile, server-side, the failed request's own run record read:

```
status=success   error=(empty)   in=12991  out=7
[human] Reply with exactly this word and nothing else: PONG
[ai]    PONG
```

and the deer-flow log showed every dependency healthy on that same run:

```
POST http://pacgate-api:8080/api/auth/login              200 OK
GET  http://pacgate-api:8080/api/matters/<id>/memory     200 OK
POST http://host.docker.internal:11434/v1/chat/completions 200 OK
Successfully loaded 35 tool(s) from MCP servers
```

**The generation, the pacgate-api connection, the matter memory and the MCP tool loading were all
working.** Only the delivery was broken.

## The trap: independent timeouts stacked in series

Fixing the first layer exposed a second, because each hop caps the request independently and the
first one to give up wins:

| Configuration | Observed |
| --- | --- |
| Next.js default (30 s) | HTTP 500 at **30.1 s** |
| Next.js raised, nginx `location /` 300 s | HTTP 504 at **300.1 s** |

A real run on this box measured **2495 s (41 min)**, so anything in the 300 s class cuts genuine
work. Both layers are now set consistently:

- `deploy/frontend-patches/files/next.config.js` - `experimental.proxyTimeout: 3600000`
- `deploy/client-bundle/nginx/default.conf` - `proxy_read_timeout`/`proxy_send_timeout` `3600s`
  on `location /` **and** `location /research/` (they front the same upstream and the same
  long-running traffic, so they must not drift).

## How it reaches clients WITHOUT an image rebuild

`next start` reads `next.config.js` at boot, so `compose.prod.yaml` now **bind-mounts** the
patched config over the image's copy:

```yaml
volumes:
  - ../frontend-patches/files/next.config.js:/app/frontend/next.config.js:ro
```

That means the fix lands on the next repo pull / `install.ps1 -Update`. It is **also** added to
`deploy/frontend-patches/files/`, which CI copies into the frontend source before building
(`cp -rv deploy/frontend-patches/files/. deploy/deer-flow-src/frontend/`), so a future image
rebuild stays correct on its own and the two paths cannot diverge.

## Residual

- The **O23 fix (`5ac7102`)** is a different story: it is compiled into the Rust binary, so it
  genuinely needs an image rebuild. Verified absent from the published `0.1.27` image
  (`with_data_dir` symbol count 0, control symbol count 1).
- The 3600 s values are deliberately generous. If a client environment wants a hard ceiling,
  lower nginx first and keep Next.js above it - never the reverse, or the frontend silently
  becomes the narrower gate again.

## The client upgrade path, proven rather than assumed

An existing AIPC runs `git pull` + `install.ps1 -Update`. Two mechanisms are involved, and
BOTH were verified on 2026-10-13 by reproducing an old client rather than reasoning about it:

1. **Reaching the container.** Adding a bind mount CHANGES the compose service definition, so
   unlike a mere file edit `up -d` does recreate the container. Simulated by removing the
   volume block from `compose.prod.yaml`, recreating the service, and then applying the update:

   | State | Mount present | Config in container |
   | --- | --- | --- |
   | old client (no volume block) | `False` | `NONE` |
   | after the update path | `True` | `proxyTimeout: 3600000` |

   `up -d` reported `Container deer-flow-frontend Recreate / Recreated / Started`.

2. **Applying the file.** Because `next start` reads `next.config.js` only at boot, the compose
   recreate above is what makes the value live. `install.ps1` also names it explicitly in its
   `-Update` restart list (section 7c) as a second, independent path.

Reproducing an old client is the only way to test this honestly: a machine that already has the
mount never exercises the transition.

