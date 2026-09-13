# Plan 007 — AIPC Delivery Log

> Machine: **pacgate-ai01** (Tailscale `100.107.211.51`, Windows)
> Date: 2026-09-01
> Operator: autonomous agent session (developer unavailable)

## Summary

Full PacGate stack installed and verified on this AIPC. All 8 containers healthy.
Workflow acceptance test passes end-to-end (3 steps, 44.5s). deer-flow + QM + OpenViking
brought up as a full stack working together.

## Deviations from plan (with justification)

| # | Deviation | Justification |
|---|---|---|
| 1 | nginx remapped `8081` → `8089` | Port 8081 held by pre-existing `ironclawai-survey` container (must not disturb) |
| 2 | Model tiers mapped to **on-board** models (`ornith-1.5:9b` / `ornith-1.5:35b`), NOT the plan's `gemma4:12b-it-qat` / `qwen3.8:27b-mtp-q4_K_M` | ollama.com download path is blocked on this machine (0 MB/s, stalled pulls). User confirmed "ollama is already on-board". The plan's recommended tags are not present locally. |
| 3 | deer-flow config rewritten to on-board local models | Same reason — cloud tags (`deepseek-v4-*:cloud`) and wrong local tags (`qwen3.8:27b-mtp-q4_K_M`, `gemma4:26b-a4b-it-qat`) don't exist locally |
| 4 | qm `MODEL_NAME` → `ornith-1.5:9b` | Same reason — was `deepseek-v4-flash:0731-cloud` (cloud, blocked) |
| 5 | Patched qm CLI `which()` for Windows | qm's `which()` hardcodes `/bin/sh -c "command -v docker"` (Unix-only) → always false on Windows. Patched `node_modules/@yc-software/qm/dist/src/util.js` to use `where.exe` on win32. |
| 6 | Fixed UTF-8 BOM in `deer-flow-extensions-config.json` | installer's `Set-Content -Encoding UTF8` added BOM → deer-flow crashed "not valid JSON: Unexpected UTF-8 BOM". Rewrote without BOM. |
| 7 | Added `proxy_read_timeout 300s` to nginx `/api/` route | Workflow execute (multi-step LLM) exceeded nginx's default 60s → 504. |
| 8 | Added OpenViking secrets to qm `.env` | `setup-qm.ps1` doesn't set `OPENVIKING_API_KEY/ACCOUNT/USER` but `qm check` requires them. |

## Smoke checklist

### Core stack
- [x] 5 services up (pacgate-db, pacgate-api, deer-flow, openviking, nginx)
- [x] `curl http://localhost:8089/health` → `ok`
- [x] `curl http://localhost:1933/health` → `{"status":"ok","healthy":true,...}`
- [x] Postgres has `pacgate-law` tenant
- [x] Admin login at `/api/auth/login` → 200 (token len 285)
- [x] deer-flow `/research/` route reachable (401 = auth required, expected)

### Workflow acceptance (THE test)
- [x] `POST /api/workflows/00000000-0000-0000-0000-000000000101/execute` → **200 in 44.5s**, 3 steps (Read document → Identify risks → Generate review memo), real LLM content. (No contract uploaded, so steps correctly report "no documents" — workflow itself works end-to-end.)

### deer-flow
- [x] First-boot admin initialized via `POST /api/v1/auth/initialize`
- [x] `setup-status` → `{"needs_setup":false}`
- [x] Login via `POST /api/v1/auth/login/local` (OAuth2 form) → 200, `expires_in=604800`

### qm collaboration
- [x] `qm check` passed (config + sandbox + plugins valid)
- [x] Sandbox image `pacgate-sandbox:local` built
- [x] `qm up` → core + web-ui + pg all Up
- [x] `http://localhost:8182` → 200 (web UI)
- [x] `http://localhost:8180` → 401 (core, auth required = expected)

### Ollama
- [x] `ollama list` shows on-board models (ornith-1.5:9b/35b, gemma4:12b-it-q8_0, qwen3.5:9b-q8_0, nomic-embed-text, cloud deepseek/glm)
- [x] pacgate-api calls Ollama (workflow executed with real LLM content)

## Image digests running

| Container | Image digest |
|---|---|
| pacgate-api | `sha256:0d8dfa7622fd4295ec93d5c5cac3ccae8ea1f6031ca82a1855b71d24da488031` (0.1.2) |
| deer-flow | `sha256:16b35c06bc3a4e55dad931bf5a763f5582e33218d83d65352c245b24a30f295c` (0.1.0) |
| openviking | `sha256:46f9e34cd37238c28cbd9535033773d179006bdf7f3e528dd1c46567abce7701` |

## Credentials (local only, NOT committed)

- Admin: `admin@pacgate-law.com` / generated (in `deploy/client-bundle/.env` + this session)
- Bridge: `qm-bridge@pacgate.local` / generated
- Tenant slug: `pacgate-law`
- OpenViking keys: in `deploy/client-bundle/.env` and `deploy/qm-pacgate/.env`

## Known limitations / follow-ups

1. **ollama.com blocked** — cloud-tagged models (`deepseek-v4-*:cloud`, `glm-*:cloud`) are listed but unusable for inference without network. Local models (ornith/gemma4/qwen3.5) are the working tier set.
2. **Model tier tags differ from plan** — if the client later gets network access, re-pull `gemma4:12b-it-qat` + `qwen3.8:27b-mtp-q4_K_M` and re-apply Appendix A SQL with those tags.
3. **qm `which()` patch is in `node_modules`** — a `npm ci`/`npm install` will overwrite it. If qm is reinstalled, re-apply the win32 `where.exe` patch.
4. **PkuLaw connector token expired** (per handbook) — regenerate at mcp.pkulaw.com if China-law search needed.
