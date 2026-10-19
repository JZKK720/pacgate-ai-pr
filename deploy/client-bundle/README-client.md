# Pacgate-ai Client Bundle v0.1.14

## Quick start

1. Install Docker Desktop (https://docs.docker.com/desktop/)
2. Install Ollama (https://ollama.com) and run `ollama signin` (the research
   chat models route through ollama.com; see `ollama-models.txt`)
3. Clone the repo: `git clone https://github.com/JZKK720/pacgate-ai-pr.git`
   and work in `pacgate-ai-pr\deploy\client-bundle`
4. Copy `.env.example` to `.env` and fill in all five values — DB password,
   JWT secret, tenant id, and **both OpenViking keys** (32-char hex each; the
   installer stops without them)
5. Run: `.\install.ps1` (pulls public GHCR images — no docker login — and the
   Ollama models, and renders the OpenViking configs)
6. Open browser: `http://localhost:8089`

Full step-by-step (tenant seeding, model overrides, qm, acceptance):
see `deploy/AIPC-DEPLOYMENT-HANDBOOK.md`.

## What runs

| Service | Port | Description |
|---------|------|-------------|
| nginx | 8089 (external) | Entry point — routes to API and research |
| pacgate-api | 8080 (internal) | Metadata API, auth, matters, workflows, documents |
| deer-flow | 8001 (internal) | Legal research workspace |
| OpenViking | 1933 | Long-term memory lane (MCP) |
| Postgres | 5432 (internal) | Metadata database |

QM (co-working workspace) runs **separately** via `qm up` on port 8182.

## Setting up qm (co-working workspace)

qm runs separately from the main Docker Compose stack. To set it up:

1. First, start the main stack: `.\install.ps1`
2. Register a service account in pacgate-api:
   ```powershell
   $body = @{email="qm-bridge@pacgate.local"; password="<generate-a-strong-password>"} | ConvertTo-Json
   Invoke-RestMethod -Uri "http://localhost:8089/api/auth/register" -Method POST -Body $body -ContentType "application/json"
   ```
   This account is used by the qm sandbox bridge tool to authenticate with pacgate-api.
3. Copy the `qm-pacgate/` directory next to this bundle
4. Run the qm bootstrap: `.\setup-qm.ps1`
   - This generates signing secrets, creates `.env`, and validates the config
5. Start qm: `cd qm-pacgate && npm exec qm -- up`
6. Access qm at: `http://localhost:8182`

## Switching models

### deer-flow (research workspace)
1. Edit `deer-flow-config.yaml` — reorder the `models` list (first entry = default)
2. Restart: `docker compose -f compose.prod.yaml restart deer-flow`

### qm (co-working workspace)
1. Edit `qm-pacgate/qm.config.jsonc` — change `MODEL_NAME`
2. Restart: `cd qm-pacgate && npm exec qm -- down && npm exec qm -- up`

### If a model does not fit

The shipped picker only offers models that fit a 16 GB card. Two large models
that used to be listed (a 25 GB 30B and a 22 GB 35B) are withdrawn, as is the
17 GB default for the API's Mid workflow tier. The reason is worth knowing: on
an AIPC an oversized model does **not** report an error. The machine loads it,
spills to CPU, and the run looks like a hang with no output. That is the symptom
that made these machines look broken, and nothing in the logs says "too big".

If you add a model yourself, check it first:

```powershell
# from the repo root
.\scripts\test-aipc-capacity-fit.ps1
```

It reports each model's measured size against this machine's budget and says
whether it fits. A model that does not fit will not produce an error at runtime -
it will just be slow, or appear stuck.

## Smoke testing the deer-flow outputs listing

The deer-flow workspace surfaces every file the agent wrote to
`/mnt/user-data/outputs` (docx, pdf, md, csv, …) via
`GET /api/threads/{id}/outputs`, and lets users download each one via
`GET /api/threads/{id}/artifacts/mnt/user-data/outputs/<file>`.

To confirm these are reachable **and** downloadable for a logged-in admin
through the real access path (frontend proxy `:8090` or nginx `:8089`), run:

```powershell
# From deploy/client-bundle/ (defaults to http://localhost:8090)
.\smoke-deer-flow-outputs.ps1

# Against the nginx entry point instead
.\smoke-deer-flow-outputs.ps1 -BaseUrl "http://localhost:8089"

# Pin a specific thread (skips auto-discovery)
.\smoke-deer-flow-outputs.ps1 -ThreadId <thread-uuid>
```

The script:

1. Logs in as the admin (reads `PACGATE_API_EMAIL` / `PACGATE_API_PASSWORD`
   from `.env`, or override with `-Email` / `-Password`).
2. Discovers a thread the admin owns (or uses `-ThreadId`).
3. Creates a temporary `smoke-test-output.md` in that thread's outputs dir.
4. Calls the listing endpoint and verifies each file is enriched with
   `virtual_path` + `artifact_url`.
5. Downloads the file through the artifact route and checks it returns 200
   with content.
6. Removes the temporary file.

Exit code `0` = pass, `1` = fail. Use `-KeepTestFile` to leave the temp file
in place for manual inspection.

## Updating

Run: `.\install.ps1 -Update`

This pulls the latest repository content (`git pull --ff-only`), pulls new GHCR
images and restarts containers. Your data is preserved:
- `./data/tenants/` (volume mount) — matters, documents, memory
- Postgres data (named volume) — metadata database

`-Update` also repairs two generated values that older releases left wrong. Both
are additive: an existing value is never overwritten, and no secret is touched.

| Value | Why it matters |
|---|---|
| `GATEWAY_CORS_ORIGINS` in `.env` | Sign-in is refused with **403 "cross-site auth request denied"** if the browser's address is not listed. Older installs listed port 8089 only, so signing in on port 8090 failed. `-Update` adds the missing origins. |
| `QM_PUBLIC_URL` in `qm-pacgate/.env` | The staff portal's OAuth issuer. Older installs hardcoded `http://localhost:8181`, so anyone signing in from **another computer** was redirected to their own machine and could never complete sign-in. `-Update` sets it to this machine's hostname. |

After `-Update`, recreate the affected services so they pick the new values up:

```powershell
docker compose -f compose.prod.yaml up -d --force-recreate deer-flow deer-flow-frontend
cd qm-pacgate; docker compose -f compose.qm.yaml up -d --force-recreate auth portal core
```

A corrected `.env` does nothing to a **running** container — it must be recreated.

### Signing in from another computer

If staff use the portal from their own machines rather than on the AIPC itself,
make sure the browser origin is allowed. Both of these must be true:

1. `GATEWAY_CORS_ORIGINS` in `.env` contains the exact address they type, e.g.
   `http://aipc-01.local:8089` and `http://aipc-01.local:8090`.
2. `QM_PUBLIC_URL` in `qm-pacgate/.env` is the address they type, e.g.
   `http://aipc-01.local:8181`.

To check both at once:

```powershell
# from the repo root
.\scripts\test-origin-coherence.ps1
```

It reports every origin this machine advertises and whether auth accepts it,
plus whether the OAuth issuer is reachable from a browser. Use the machine name
rather than a LAN IP where possible — a hostname survives DHCP changes.

## Moving matters between machines

Each AIPC has its own private database, so nothing is shared automatically. To
copy matters (with their documents and memory) from one machine to another:

```powershell
# On the source machine - capture a bundle
.\scripts\sync-pacgate-matters.ps1 -Action Export `
    -BaseUrl http://localhost:8089/pacgate `
    -Email admin@pacgate-law.com -Password '<admin password>' `
    -OutDir D:\sync\aipc1

# Copy that folder to the other machine, then - preview first
.\scripts\sync-pacgate-matters.ps1 -Action Import `
    -BaseUrl http://localhost:8089/pacgate `
    -Email admin@pacgate-law.com -Password '<admin password>' `
    -InDir D:\sync\aipc1 -WhatIf

# ...and apply
.\scripts\sync-pacgate-matters.ps1 -Action Import ... -InDir D:\sync\aipc1
```

Notes worth knowing before you run it:

- **Running it twice is safe.** Import reuses what already exists and never
  deletes anything.
- **Documents that are not sanitized are not copied.** The API refuses to export
  unsanitized material, and the tool reports which documents were held back
  rather than working around it. Sanitize them first if they need to travel.
- **Passwords do not travel.** Accounts that do not exist on the target are not
  created. Create them there, or the imported matters will be owned by a
  different account.
- **Matter names are not guaranteed unique.** If two matters share a name, the
  tool creates a new one rather than guessing which you meant, and says so.

### Which matter is which

A matter's `external_key` is what makes it the *same* matter on two machines.
Without one, sync matches on the matter's name, and names are not unique (a test
fixture can create dozens with one name), so a document can attach to the wrong
matter.

Setting a key requires an admin. Preview first - `-WhatIf` changes nothing:

```powershell
.\scripts\sync-pacgate-matters.ps1 -Action BackfillKeys `
    -BaseUrl http://localhost:8089/pacgate -Email admin@pacgate-law.com `
    -Password '<admin password>' -KeyPrefix PF -WhatIf

# then scope it to one group of matters and apply
.\scripts\sync-pacgate-matters.ps1 -Action BackfillKeys `
    -BaseUrl http://localhost:8089/pacgate -Email admin@pacgate-law.com `
    -Password '<admin password>' -KeyPrefix PF -NameFilter 'Acme*'
```

Keys come from the prefix you supply (`PF-0001`, `PF-0002`, ...). The tool never
invents a key on its own: a made-up identity would make two machines disagree in
a new way. Choose a prefix that means something to your firm. Running it again is
safe - matters that already have a key are skipped, never overwritten.

If it reports **HTTP 405**, this machine is running a release from before
external-key repair existed. Update first (`.\install.ps1 -Update`), then re-run.

## Troubleshooting

See `deploy/DEPLOYMENT-GUIDE.md` Part 5 for detailed troubleshooting.

Quick checks:
- `docker compose -f compose.prod.yaml ps` — are all services running?
- `docker compose -f compose.prod.yaml logs <service>` — check logs
- `ollama list` — are models available?
- `curl http://localhost:8089/health` — is the API healthy? (returns `ok`)