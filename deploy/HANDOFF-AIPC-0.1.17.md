# AIPC Handoff — PacGate stack at 0.1.17 (2026-09-23)

**The canonical procedure for both AIPC machines.** The per-machine prompts
(`AIPC1-HANDOFF-PROMPT-v2.md`, `AIPC2-HANDOFF-PROMPT-v2.md`) point here for the
shared body and carry only machine-specific notes.

> Why one canonical file: the two per-machine prompts had drifted apart and
> contradicted each other on a **data-safety** point (whether
> `--force-recreate` on deer-flow is safe). Two copies of the same procedure
> diverge silently — the same failure mode that let the workflow-wiring defect
> survive in a second compose file. Keep machine-specific facts in the wrappers,
> keep the procedure here.

---

## Preconditions

- Windows with Docker Desktop, Ollama, and Node.js 24+ installed.
- `ollama signin` completed — required, and not optional: several configured chat
  models are Ollama **cloud** tags that route via ollama.com and authenticate
  from that session. No API key is involved.
- Git available.

## Step 0 — get the repo from the RIGHT remote

```powershell
cd C:\
git clone https://github.com/JZKK720/pacgate-ai-pr.git
cd pacgate-ai-pr
git log -1 --format="%h %s"
```

**Expected:** `4f9329e docs: current continuation snapshot (0.1.17)...` or newer.

### Do NOT clone the fork

```
JZKK720/pacgate-ai-pr      <- canonical. Clone THIS.
pacgate-ai/pacgate-ai-pr   <- 26 commits BEHIND (last checked 2026-09-23)
```

The fork is missing `b7fc540` and `039afdc`, so it still carries the **original
workflow-wiring defect**. It ships the 15 workflow YAMLs but not the wiring, so a
machine cloned from the fork serves **10 built-in workflows instead of the firm's
222**. Deploying from the fork silently loses the firm's legal template library.

Verify which remote you actually have, before installing:

```powershell
git remote -v
# origin  https://github.com/JZKK720/pacgate-ai-pr.git   <- correct
```

If it shows the fork, re-clone from JZKK720. Do not try to patch it in place.

## Step 1 — install or update

**Fresh machine:**

```powershell
cd C:\pacgate-ai-pr\deploy\client-bundle
copy .env.example .env
notepad .env        # set every value in the table below
.\install.ps1
```

### The values a HUMAN must supply

`install.ps1` **generates nothing** — it renders configs and preserves `.env`, so
anything left as a placeholder stays a placeholder. It also **never validates
these** (zero references in `install.ps1`); they are consumed only by compose as
env substitution. So nothing warns you. Fill them before the first run:

| Key | If left as `change-me` |
|---|---|
| `OPENVIKING_ROOT_API_KEY` | **install STOPS.** `[WARN]` L311 → `ERROR` L314 → `exit 1` L317. The only one that actually halts, because the rendered `deer-flow-extensions-config.json` is absent on a fresh machine |
| `PACGATE_DB_PASSWORD` | install **succeeds** — Postgres comes up on the placeholder password |
| `PACGATE_JWT_SECRET` | install **succeeds** — every token signed with a publicly-known key |
| `PACGATE_API_PASSWORD` | install **succeeds** — the admin account is created with the placeholder password |

**Read that table as a warning, not a convenience.** Three of the four do not
fail; they ship a machine that works and is insecure, which is the worse outcome
because nobody notices. `PACGATE_JWT_SECRET` in particular feeds both
`PACGATE_JWT_SECRET` and `BETTER_AUTH_SECRET` (`compose.prod.yaml` L30, L144).

`PACGATE_API_EMAIL` and `PACGATE_TENANT_ID` already carry working values
(`admin@pacgate-law.com` is the one step 4 signs in as — do not change it unless
you also change the step 4 command).

**`OPENVIKING_ROOT_API_KEY` is the one that catches people**, because it is the
only value that fails the install *after* the Docker work has started, and the
per-machine prompts name it nowhere. Any random hex works — it is a per-machine
key that `install.ps1` substitutes into `ov.conf` and the deer-flow MCP config:

```powershell
# Generate three secrets and REPLACE the placeholders IN PLACE.
# Do NOT append with Add-Content: .env.example already contains these keys, so
# appending would leave two definitions of the same key and which one wins
# depends on the parser. Replace, never append.
$hex = { -join (1..64 | ForEach-Object { '{0:x}' -f (Get-Random -Max 16) }) }
$c = Get-Content .env -Raw
foreach ($k in 'PACGATE_DB_PASSWORD','PACGATE_JWT_SECRET','OPENVIKING_ROOT_API_KEY') {
    $c = $c -replace "(?m)^$k=.*$", "$k=$(& $hex)"
}
Set-Content .env -Value $c -NoNewline
# PACGATE_API_PASSWORD: do this one by hand - it is the admin sign-in, so pick
# something you can actually type.
notepad .env
```

Sanity check before installing — every one of these must print a non-placeholder:

```powershell
Select-String .env -Pattern '^(PACGATE_DB_PASSWORD|PACGATE_JWT_SECRET|PACGATE_API_PASSWORD|OPENVIKING_ROOT_API_KEY)=' |
  ForEach-Object { $k,$v = ($_.Line -split '=',2); "$k : $(if ($v -match 'change-me' -or $v -eq '') { 'STILL PLACEHOLDER' } else { "set (len=$($v.Length))" })" }
```

For reference: this key is an **admin** credential and is sufficient for
everything the product does. The memory lane runs over **MCP** (`POST /mcp`,
`X-API-Key`) and answers **200** with it. Only the REST route
`/api/v1/search/recall` wants an account-user key, and nothing in the shipped
stack calls it — so there is no separate user key to create on these machines.

`OPENVIKING_API_KEY` is declared in `qm.config.jsonc`'s `secretEnv`, but
`setup-qm.ps1` writes it **empty** on purpose and nothing enforces it. Leave it.

**Existing install:**

```powershell
cd C:\pacgate-ai-pr\deploy\client-bundle
.\install.ps1 -Update
```

`-Update` syncs the repo itself (`git fetch` → `--ff-only` pull → prints the
changed files). A separate `git pull` beforehand is harmless but unnecessary.

If it reports **`[WARN] Repo has local changes to tracked files - skipping the
repo update`**, the update will move only the Docker images and silently leave
workflows/patches/nginx.conf stale. Resolve those edits (commit or restore) and
re-run. Untracked scratch files are fine and do not block anything.

### What an update does NOT lose

- Postgres data — named volume `pacgate-db-data`.
- File bytes, deer-flow's DB, `.jwt_secret`, `users/` — all in the
  **bind-mounted** `./data` and `./data/deer-flow`. Container recreation cannot
  touch a bind mount.
- `.env`, `./openviking`, and qm runtime files — untouched by construction.

## Step 2 — verify the release is actually running

```powershell
curl http://localhost:8089/version
# expect: {"revision":"2a51fbd...","version":"0.1.17"}
```

`/version` is served through nginx (it maps onto the API's `/build-info`). Both
fields matter: `version` comes from the Rust manifest, `revision` from the commit
the image was built at. A machine whose compose pin advanced but whose binary
answers an old version means the manifest was not bumped.

## Step 3 — verify the WORKFLOW LIBRARY is served (most important check)

This is the client-visible feature that a wrong clone silently loses.

```powershell
cd C:\pacgate-ai-pr
pwsh -File scripts/test-workflow-library-served.ps1
```

**Expected:** `RESULT: the legal workflow library is served (222 workflows, 46 categories)` and exit code 0.

| Exit | Meaning |
|---|---|
| **0** | Library served (222 workflows, 46 categories) — correct |
| **1** | **Only the 10 built-ins.** The wiring is missing — see troubleshooting |
| **2** | Could not check (stack down, or `.env` credentials unreadable). **Not a pass.** |

The library is bilingual — Chinese template names with English descriptions. Do
not use title language alone as the discriminator; use the count. The built-ins
("Contract Review", "Due Diligence Review") are English and that is expected.

## Step 4 — verify LAN sign-in and registration

The gateway rejects auth POSTs whose browser `Origin` is not allowlisted, so a
localhost-only list breaks every user browsing via the machine's hostname or IP.
`install.ps1` step 4c derives the machine's own origins into `.env`.

```powershell
curl.exe -sS -X POST -H "Origin: http://$($env:COMPUTERNAME.ToLower()):8089" `
  -H "Content-Type: application/x-www-form-urlencoded" `
  --data-raw "username=admin@pacgate-law.com&password=WRONGPASS" `
  http://localhost:8089/api/v1/auth/login/local
```

**Expected:** `401` invalid credentials. **A `403 "Cross-site auth request
denied"` means the Origin was rejected** — the CORS fix did not land.

Then from a **different device on the LAN**: open `http://<machine>:8089`, sign in
as the existing admin, and register a new user. Both must work.

Look for this line in the install output:
`[OK] Derived GATEWAY_CORS_ORIGINS for this machine: http://localhost:8089,http://<host>:8089,...`

If it printed `[WARN] GATEWAY_CORS_ORIGINS is localhost-only`, add the printed
origin to `.env` by hand, then:

```powershell
docker compose -f compose.prod.yaml up -d --force-recreate deer-flow
```

**`--force-recreate` is safe here, and REQUIRED.** Required because compose does
not recreate a container when only an env var changed. Safe because deer-flow's
state (`checkpoints.db`, `.jwt_secret`, `users/`, `channels/`) lives in the
bind-mounted `./data/deer-flow` on the host — verified, not assumed:

```
deer-flow volumes:  ./data/deer-flow -> /app/backend/.deer-flow   (type=bind)
named volumes in project:  pacgate-db-data   (Postgres only)
```

Bind-mounted data survives container recreation by definition.

> **A previous AIPC #2 prompt claimed `--force-recreate` "wipes its local DB +
> admin user".** That is **wrong** and would have blocked the correct fix. Use
> `--force-recreate`; use plain `restart` only if you specifically want to avoid
> the recreate.

## Step 5 — verify MCP tools

The agent lane is the only user-facing path to workflows; there is no workflow
gallery UI by design.

```powershell
docker logs deer-flow --since 10m 2>&1 | Select-String 'MCP tools'
# expect a non-zero count and the pacgate server listed
```

Expect roughly 16 pacgate tools. Do not trust a model's self-report about its own
toolset — read the binding log (`Initializing MCP client with N server(s)`,
`MCP tools: N`) rather than believing a chat reply.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Workflow count is 10 | Wiring missing (`WORKFLOWS_DIR` or the mount) | Re-clone from JZKK720; confirm both halves on `pacgate-api` |
| `403 Cross-site auth request denied` | Origin not allowlisted | See step 4 |
| `[WARN] ... skipping the repo update` | Tracked files edited locally | Commit or restore, re-run |
| Pull of `deer-flow-pacgate` fails anonymously | Image not public | `scripts/check-ghcr-anon.py <tag>` |
| `401` on an unknown path | Expected — auth middleware, not a 404 | Not a fault |
| Login works locally, fails on LAN | Step 4c did not run, or `.env` was localhost-only | See step 4 |

## Do NOT

- Do not clone the fork. Do not propose `docker login ghcr.io` on the client path —
  the images are public by design and the on-site engineer installs them.
- Do not build images on a client machine. A local build is a scratch artifact and
  makes that machine disagree with every other AIPC.
- Do not edit `.env` values that were auto-derived without noting why.
- Do not treat "could not check" as "verified fine". Exit 2 / SKIP is not a pass.

## Related

- `deploy/CONTINUE-HERE-2026-09-23.md` — current state, open work, traps
- `deploy/DEFECT-workflow-mount-wrong-service.md` — the workflow defect in full
- `deploy/DEPLOYMENT-GUIDE.md`, `deploy/SETUP-AND-OPERATIONS.md`
