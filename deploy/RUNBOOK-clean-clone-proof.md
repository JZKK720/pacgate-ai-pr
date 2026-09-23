# RUNBOOK — the clean-clone proof

**Why this exists:** the standing rule is that a fresh clone in a clean directory is
the only valid test for install-path changes, because this dev box accumulates
credentials, pulled models, and rendered gitignored configs that mask
clean-machine failures. That rule was written down; **the procedure was not.**
This is the procedure.

Two things it covers, and one it deliberately does not:

| # | Question it answers | Cost |
|---|---|---|
| **1** | Does the install path work on a directory with **no prior state**? | ~30 min, this box |
| **2** | Does the **human-facing** product behave? (judgement pass) | ~60 min, a human |
| — | Does it work on a **different machine**? | NOT covered here — see §5 |

---

## 1. Clean-clone proof (mechanical)

### Prerequisite: free ports 8089 and 8090

`install.ps1` takes **no port override**. `compose.prod.yaml` maps `nginx` to
`8089:80` and the frontend to `8090`, and this dev stack already owns both. So the
dev stack must come down first.

```powershell
cd C:\Users\cubecloud-io\github-pr\pacgate-ai-pr\deploy\client-bundle
docker compose -f compose.prod.yaml down      # NO -v: keeps the pacgate-db-data volume
```

**Nothing is lost.** Postgres lives in the named volume `pacgate-db-data`, and
files/DB/jwt/users live in the **bind-mounted** `./data` and `./data/deer-flow` on
the host. `down` (without `-v`) removes containers only.

Confirm the ports are actually free — a stale container will otherwise make step 3
fail with a confusing bind error:

```powershell
docker ps --format '{{.Names}}\t{{.Ports}}' | Select-String '8089|8090'
# expect: no output
```

### Step 1 — clone into a clean directory

Pick a path that has never held a Pacgate checkout. Do **not** reuse the dev repo.

```powershell
$proof = "$env:USERPROFILE\pacgate-clean-proof"
if (Test-Path $proof) { Remove-Item $proof -Recurse -Force }   # truly clean
New-Item -ItemType Directory -Path $proof | Out-Null
cd $proof
git clone https://github.com/JZKK720/pacgate-ai-pr.git
cd pacgate-ai-pr
git log -1 --format='%h %s'
git remote -v      # MUST be JZKK720. The fork is 26 behind and deploys a defect.
```

**Pass:** `origin` is `JZKK720/pacgate-ai-pr`, and HEAD is `4f9329e` or newer.

### Step 2 — create `.env` from the template

```powershell
cd deploy\client-bundle
copy .env.example .env
```

Five values must be real. **`OPENVIKING_ROOT_API_KEY` is not optional** —
`install.ps1` aborts if it is unset or still `change-me`, because the deer-flow
MCP config render depends on it (install.ps1:314).

```powershell
# Generate four strong secrets. Never reuse the dev box's values - a proof run
# that inherits dev state is not testing a clean machine.
$pw   = -join ((48..57) + (97..122) | Get-Random -Count 24 | % {[char]$_})
$jwt  = -join ((48..57) + (97..122) | Get-Random -Count 48 | % {[char]$_})
$ovk  = -join ((48..57) + (97..102) | Get-Random -Count 32 | % {[char]$_})
"PACGATE_DB_PASSWORD=$pw"
"PACGATE_JWT_SECRET=$jwt"
"OPENVIKING_ROOT_API_KEY=$ovk"
```

Edit `.env` and set exactly these:

| Key | Value |
|---|---|
| `PACGATE_DB_PASSWORD` | the generated `$pw` |
| `PACGATE_JWT_SECRET` | the generated `$jwt` |
| `PACGATE_API_EMAIL` | e.g. `admin@pacgate-law.com` |
| `PACGATE_API_PASSWORD` | a real password — **remember it**, step 4 needs it |
| `OPENVIKING_ROOT_API_KEY` | the generated `$ovk` |

Leave the rest at their template defaults.

### Step 3 — install

```powershell
cd C:\Users\<you>\pacgate-clean-proof\pacgate-ai-pr\deploy\client-bundle
.\install.ps1
```

Watch for these, in order. **Every string below was read out of `install.ps1`, not
paraphrased** — a runbook that tells you to expect output the script never prints
wastes exactly the time it was written to save:

| Expected line (verbatim) | Source | Meaning |
|---|---|---|
| `[OK] Docker detected` | L30 | preflight passed |
| `[OK] Ollama detected` | L37 | preflight passed |
| `[OK] Rendered <path> from template` | L358 | deer-flow MCP config rendered — **this is the OpenViking key landing** (or `L340 [OK] <path> already current` if unchanged) |
| `[OK] Derived GATEWAY_CORS_ORIGINS for this machine: <origins>` | L437 | step 4c wrote the LAN origins — **the sign-in fix landing** |
| `[OK] Images pulled` | L478 | all five images came down |
| `[OK] Stack running` | L483 | containers are up |
| `[OK] pacgate-api reports <version> (source revision <rev>)` | L664 | the running binary matches the compose pin |

**Pass:** it exits 0 and reports a version. A hard failure calls `exit 1`
(L23, L28, L35, L45, L317), so the exit code is trustworthy.

**Fail signals, and what each one means** — this is the part that saves an hour:

| Symptom (verbatim where quoted) | Real cause |
|---|---|
| `[WARN] OPENVIKING_ROOT_API_KEY is unset or still 'change-me'.` then `exit 1` | step 2 — L311 warns, L314 errors, L317 exits. Not a Docker problem |
| `bind: address already in use` on 8089 | the dev stack is still up; redo the prerequisite |
| `unauthorized` pulling an image | **not** a credentials problem — the images are public; check `python scripts/check-ghcr-anon.py 0.1.17` |
| `[WARN] GATEWAY_CORS_ORIGINS is localhost-only (<value>).` | an operator value was pre-set; follow the printed fix line |
| `[WARN] Repo has local changes to tracked files - skipping the repo update.` | `-Update` only. On a fresh clone this means the clone was NOT clean — go back to step 1 |

### A note on checking a runbook's own claims

While writing this, I checked the quoted strings with
`Select-String -Pattern ([regex]::Escape($s)) -SimpleMatch`. That **double-escapes**: it
searches for the literal text `\[OK\] ...`, so all four reported NOT FOUND when
three of them were present. The check was broken, not the strings.

Check verbatim output with **either** `-SimpleMatch` and a raw string, **or** a
regex without `-SimpleMatch` — never both. Mixing them produces a confident,
wrong answer, which is worse than no check.

### Step 4 — verify on the clean machine

Run **all four**. The first three are automated and must all pass; the fourth is
the point of the exercise.

```powershell
$r = C:\Users\<you>\pacgate-clean-proof\pacgate-ai-pr

# 4a. release is actually running
curl.exe -sS http://localhost:8089/version
#    expect {"revision":"2a51fbd...","version":"0.1.17"}
#    NOTE: /version is at the NGINX ROOT, NOT under /pacgate. The prefixed path
#    401s (unknown route hits auth middleware) and looks like an auth failure.

# 4b. the workflow LIBRARY is served, not the 10 built-ins
pwsh -File "$r\scripts\test-workflow-library-served.ps1"
#    expect exit 0, "222 workflows, 46 categories"

# 4c. the whole legal journey, on the clean stack
pwsh -File "$r\scripts\test-legal-journey.ps1"
#    expect 15 assertions pass; see §4 for the two SKIPs

# 4d. LAN sign-in from a DIFFERENT device
#    On another machine on the same network, open http://<clean-box>:8089
#    Sign in as the admin from step 2. Then register a new user.
#    BOTH must work. A 403 "Cross-site auth request denied" means step 4c of
#    install did not derive the origin.
```

### Step 5 — record the result, then restore the dev box

```powershell
# Record, because a proof nobody wrote down gets redone
$r = C:\Users\<you>\pacgate-clean-proof\pacgate-ai-pr
& pwsh -File "$r\scripts\run-all-checks.ps1" 2>&1 | Select-Object -Last 3
$v = (Invoke-RestMethod http://localhost:8089/version)
"clean-clone proof $(Get-Date -Format o) version=$($v.version) rev=$($v.revision)" |
  Tee-Object -Append "$r\deploy\CLEAN-CLONE-PROOF-LOG.md"
```

Then bring the dev stack back:

```powershell
cd C:\Users\cubecloud-io\github-pr\pacgate-ai-pr\deploy\client-bundle
docker compose -f compose.prod.yaml up -d
```

Note the clean clone's containers are named the same (`pacgate-api`, `nginx`, …)
as the dev stack's. `down` in the clean clone before starting dev, or the names
collide:

```powershell
cd $proof\pacgate-ai-pr\deploy\client-bundle
docker compose -f compose.prod.yaml down
```

---

## 2. What a green run actually proves

Be precise about this, because over-claiming here is how a proof becomes a
formality.

**Proven:** the install path works against a directory with no prior state —
clone → `.env` → `install.ps1` → running stack → correct workflow library →
passing legal journey → LAN sign-in. That is the specific class of failure the
standing rule exists to catch: a rendered config, a credential, or a pulled model
on the dev box masking a missing step.

**NOT proven:** that the same is true on a *different machine*. See §5.

---

## 3. Why not just run the existing install tests?

`scripts/test-install-repo-pull.ps1` (295 lines) and
`scripts/test-update-end-to-end.ps1` (395 lines) are real and valuable, but they
cover the **update** path with **stub docker**. They prove git-refresh and
config-render behaviour; they never pull an image, never boot a container, and
never touch a clean directory. A clean-clone install is a different question, and
it is the one nothing answered.

---

## 4. The two expected SKIPs

`test-legal-journey.ps1` SKIPs two lanes on a fresh box. Neither is a failure of
the install, and both are stated with their reason rather than passed silently:

- **qm co-work** — the qm stack is not part of `compose.prod.yaml`; it is a
  separate stack. Start it with `deploy/qm-pacgate/setup-qm.ps1`.
- **OpenViking recall** — this is a **real gap in the shipped state**, not a test
  artifact. OpenViking is two-tier: the configured root key is an *admin*
  credential (200 on `/api/v1/admin/accounts`) while `/api/v1/search/recall` needs
  an *account-user* key. A fresh install has `user_count: 0`, so recall cannot
  work until a user is provisioned via
  `POST /api/v1/admin/accounts/{id}/users/{uid}/key`.

If recall is in scope for the acceptance bar, that provisioning step must be part
of `install.ps1` — otherwise every client machine ships with a non-functional
recall lane and no error.

---

## 5. Extending the proof to a *different* machine

The clean-clone proof rules out dev-box pollution. It cannot rule out
machine-specific differences, because it runs on the same host. The
**only** ways to close that:

1. **AIPC #1 / #2** — the real thing, but the most expensive test and you find
   install bugs with an engineer's time instead of a spare hour.
2. **A VM or a Windows Sandbox** — a genuine second OS install. Cheapest real
   coverage. Note the requirements: Docker Desktop, **Ollama plus `ollama
   signin`** (cloud chat models need that session — no API key), Node.js 24+.
3. **A second physical machine** — highest fidelity, highest cost.

**Order that costs least:** clean clone here → VM/sandbox → AIPC.
Each step is strictly weaker than the next, so a failure at step 1 saves you
two machines' worth of time.

Machine-specific factors the clean clone cannot exercise, and which the VM/AIPC
step must:

- Docker Desktop install and its WSL2 backend on a machine that never had it
- Ollama install, model pulls, and the `ollama signin` session
- GPU drivers, disk space for image pulls, Windows version and firewall
- A LAN topology where the hostname and IP differ from this box's
- First-pull latency for all five images (multi-GB) on a fresh network path

---

## 6. The human judgement pass (not automatable)

The spec is explicit: `Not automatable: genuinely using the stack on a real
matter and judging output quality. That needs a human. What can be prepared is
the matter and the runbook, so the human's time goes to judgement rather than
setup.` So prepare, then hand over.

### Prepare (30 min, mechanical)

1. **A real matter.** Not `journey-<guid>`. Use an anonymised real matter with
   the document types the firm actually handles (contract, opinion, filing).
2. **Real documents.** At least one scanned PDF (exercises OCR) and one
   born-digital PDF (exercises extraction). Include a document that *should*
   contain identifiers, so redaction has something to find.
3. **A questions list** written in advance. Deciding what to judge while
   looking at output produces post-hoc rationalisation.

### Judge (60 min, human)

The pass criterion is a set of answers, not a score. Suggested questions — adjust
to the firm's actual work:

| Dimension | Question |
|---|---|
| Extraction | Is the OCR text usable, or does it need re-keying? Name one document where it failed. |
| Redaction | Did it find every identifier a lawyer would consider sensitive? Did it over-redact anything? |
| Workflow fit | Did the workflow library contain something applicable to this matter, or was it generic? |
| Search | Did it surface a document you'd forgotten was relevant? |
| Output quality | Would a lawyer sign their name to this output? If not, what is missing? |

Record **verbatim** what failed, with the document and the step. "Search was
weak" is not actionable; "searching the counterparty name returned 0 of 3
documents I know mention it" is.

### Time-box it

An hour of judgement beats a week of setup. If a dimension needs more, that is a
finding about the product, not about the session.

---

## Related

- `docs/superpowers/specs/2026-09-22-stack-hardening-before-2.1-design.md` — the spec this serves
- `deploy/HANDOFF-AIPC-0.1.17.md` — the install/update procedure this verifies
- `deploy/CONTINUE-HERE-2026-09-23.md` — current state and open work
- `scripts/test-legal-journey.ps1` — step 4c, and the two SKIPs in §4
