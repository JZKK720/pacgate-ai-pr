# AIPC #1 Handoff Prompt — PacGate Full-Stack Setup (v0.1.17)

> **⚠️ PARTIALLY SUPERSEDED (2026-09-23).** This prompt is CORRECT on the
> essentials (it clones JZKK720, and the `--force-recreate` guidance is right),
> but two details have moved and one step is missing:
>
> 1. **Expected commit is now `4f9329e`, not `a0198d5`.**
> 2. **The workflow-library check is missing** — it is the client-visible feature
>    a wrong clone silently loses. See `deploy/HANDOFF-AIPC-0.1.17.md` step 3.
> 3. **Never clone the fork.** The fork is 26 commits behind and still carries
>    the original workflow-wiring defect, so it serves 10 built-in workflows
>    instead of the firm's 222.
>
> **Canonical procedure: `deploy/HANDOFF-AIPC-0.1.17.md`.** This file is kept for
the AIPC #1-specific notes below; the shared steps live there.

> Copy everything below into a fresh agent session on **AIPC #1**.

---

## Mission

Bring AIPC #1 to the **0.1.17 release**: all five runtime images
(pacgate-api, deer-flow, deer-flow-frontend, pacgate-mcp, ocr-service),
the deer-flow OCR pipeline (PaddleOCR + sanitizer + ocr-extractor agents),
the upload body-limit fix, and the LAN sign-in/register fix.

## Release: 0.1.17 (2026-09-20)

- All five images public at `ghcr.io/jzkk720/*:0.1.17` (anonymous 200 verified).
- Compose pins live in `deploy/client-bundle/compose.prod.yaml` (0.1.17).
- The API binary carries: migrations 001-007 (incl. `document_spans`,
  `sanitizer_jobs`), OCR route + `OCR_SERVICE_URL` consumer, axum
  `DefaultBodyLimit` sized from `max_upload_mb` (+14 MB headroom).
- nginx `client_max_body_size 100m` ships via the bind-mounted conf.
- MCP surface: **16 tools** (incl. `sanitize`, `ocr_document`, `ocr_batch`).

## What changed since 0.1.14 (what this update delivers)

1. **0.1.15**: OCR plumbing (extract route + spans migrations), MCP grew
   11 → 15 tools (`sanitize`, `ocr_document`).
2. **0.1.16**: ocr-service becomes a first-class image + compose service;
   PaddleOCR (~1.5 GB) downloads on FIRST EXTRACTION, not at install;
   `ocr-extractor` agent card provisioned.
3. **0.1.17**: upload body-limit fix (nginx 100 MB + axum transport cap).
   Large scans no longer die with 413/502.
4. **LAN sign-in/register fix** (install.ps1 step 4c): the gateway rejects
   auth POSTs whose browser `Origin` is not in `GATEWAY_CORS_ORIGINS`;
   the compose default was localhost-only, so every user browsing via the
   machine's LAN hostname/IP got `403 "Cross-site auth request denied."`
   on sign-in AND registration. Step 4c now auto-derives the machine's
   origins into `.env` at install/update time.

## Step 0 — update the repo

```powershell
cd C:\pacgate-ai-pr
git status --porcelain --untracked-files=no   # must be EMPTY before update
git pull --ff-only origin main
git log -1 --format="%h %s"   # expect: 4f9329e docs: current continuation snapshot...
```

If `git pull` refuses: a tracked file was edited locally. Commit or revert
it first — the update refuses to overwrite local work by design.

> **The clone must be `JZKK720/pacgate-ai-pr`, not the fork.** Check with
> `git remote -v`. The fork (`pacgate-ai/pacgate-ai-pr`) is 26 commits behind and
> still carries the original workflow-wiring defect — a machine cloned from it
> serves 10 built-in workflows instead of the firm's 222, with no error shown.
> If `origin` shows the fork, re-clone from JZKK720 rather than patching in place.
> ```powershell
> git remote -v
> git ls-remote origin refs/heads/main   # must show 4f9329e or newer
> ```

## Step 1 — run the update

```powershell
cd C:\pacgate-ai-pr\deploy\client-bundle
.\install.ps1 -Update
```

The update path is safe for existing data (named volume `pacgate-db-data`,
bind-mounted `./data`, `./openviking`, `.env`, and qm runtime files are all
untouched by construction). Watch for these expected outputs:

- `[OK] Derived GATEWAY_CORS_ORIGINS for this machine: http://localhost:8089,http://<host>:8089,...`
  — step 4c writing the LAN origins. **This is the sign-in fix landing.**
- `[WARN] GATEWAY_CORS_ORIGINS is localhost-only` — only if an operator set a
  localhost-only value; follow the printed fix line.
- `[OK] pacgate-api reports 0.1.17 (source revision ...)`.
- qm sandbox + re-stage reports (informational; qm is NOT touched destructively).

If step 4c printed the derive line, no manual `.env` edit is needed. If the
machine was installed before this fix and the warning fired, add the printed
origin line to `.env` by hand, then:

```powershell
docker compose -f compose.prod.yaml up -d --force-recreate deer-flow
```

(`--force-recreate` is REQUIRED here — compose does not recreate a container
when only the env changed. This is safe: it does NOT wipe deer-flow data,
which lives in `./data/deer-flow`.)

## Step 2 — verify the auth fix (the reason for this handoff)

```powershell
$host_ = hostname
# old user sign-in (expect 401 invalid_credentials = gate passed; NOT 403):
curl.exe -sS -X POST -H "Origin: http://$($env:COMPUTERNAME.ToLower()):8089" `
  -H "Content-Type: application/x-www-form-urlencoded" `
  --data-raw "username=admin@pacgate-law.com&password=WRONGPASS" `
  http://localhost:8089/api/v1/auth/login/local
# new user registration (expect 201):
$email = "probe-$(Get-Random)@example.com"
$body = '{"email":"' + $email + '","password":"Test12345!","name":"probe"}'
curl.exe -sS -X POST -H "Origin: http://$($env:COMPUTERNAME.ToLower()):8089" `
  -H "Content-Type: application/json" --data-raw $body `
  http://localhost:8089/api/v1/auth/register
```

Then from a DIFFERENT device on the LAN: open `http://<aipc1-host>:8089`,
sign in as the existing admin, and register a new user. Both must work.

Clean up the probe user afterwards if desired (leave one; harmless).

## Step 3 — verify release content

```powershell
# staleness marker (nginx maps /version onto the API's /build-info):
curl http://localhost:8089/version
# expect: {"revision":"2a51fbd...","version":"0.1.17"}

# MCP tool count (16 expected):
docker exec pacgate-mcp python3 -c "import server" 2>$null
docker logs pacgate-mcp --since=5m 2>&1 | Select-String "tool"
```

## Step 4 — OCR lane (first-use download)

OCR is a first-class surface but the ~1.5 GB PaddleOCR model downloads on
the FIRST extraction only. Either leave it (first real scan will trigger
the download) or warm it:

```powershell
# via the deer-flow agent chat: ask ocr-extractor to extract a small PDF,
# or POST /api/documents/:id/extract directly (needs a seeded document).
```

## Environment gotchas (Windows AIPC) — carried from the v2 template

- `python` is NOT in PATH — use `C:\Program Files\Python313\python.exe`.
- PowerShell blocks `.ps1`/`npm.ps1` — use `cmd.exe /c` or
  `node_modules\.bin\qm.cmd`.
- Chinese Windows defaults to GBK — never `Get-Content`/`Set-Content` UTF-8
  Chinese files; use `[System.IO.File]::ReadAllBytes`/`WriteAllBytes`.
- ollama.com downloads may be blocked — use on-board models only
  (`ollama signin` precondition for cloud-tagged chat models: the firm
  ACCEPTS prompt egress for `deepseek-*-cloud`; do not re-flag).
- deer-flow: NEVER wipe `./data/deer-flow`; restart (not recreate) is
  enough for bind-mounted patches/configs.

## qm lane (unchanged by this release)

qm is a SEPARATE compose project — `install.ps1 -Update` does not touch it
except the file-only re-stage (7f: copies tracked config files, never runs
`qm up`, never deletes runtime-only files). If the re-stage reported
changes, restart qm manually:

```powershell
cd C:\pacgate-ai-pr\deploy\qm-pacgate
node_modules\.bin\qm.cmd restart
```

## When done — report back

1. `git log -1` output (must show the CORS-fix commit or newer).
2. `curl http://localhost:8089/version` output.
3. The step-2 auth probes (old-user 401 + new-user 201) and the
   cross-device LAN sign-in result.
4. `docker compose -f compose.prod.yaml ps` (all services Up).
5. Any deviation from this prompt, with the exact command that differed.