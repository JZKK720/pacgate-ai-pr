# Clean-clone proof log

## 2026-09-28 - run 1 (PASSED, with three fresh-install defects found)

- **Procedure**: `deploy/RUNBOOK-clean-clone-proof.md` section 1
- **Clone**: `C:\Users\cubecloud-io\pacgate-clean-proof\pacgate-ai-pr`, HEAD `4667c67`, origin `JZKK720/pacgate-ai-pr`
- **Result**: install path WORKS on a directory with no prior state, after the three
  defects below. Provisioning created a real matter, wrote it to `.env`, and the
  running container carried it.

### Mechanical results

| Step | Result |
|---|---|
| 1. clone | HEAD 4667c67, remote JZKK720, 4f9329e ancestor: yes |
| 2. .env | 5 required values set; `PACGATE_MATTER_ID` blank (to force creation) |
| 3. install | exit 0; all 5 images pulled; 8 services up |
| 3b. provisioning | `[OK] Provisioned matter 68c56e22...` + `[OK] deer-flow has PACGATE_MATTER_ID=68c56e22...` |
| 4a. version | 0.1.20 rev df6b025 |
| 4b. workflow library | PASS - 222 workflows, 46 categories |
| 4c. legal journey | PASS - 15 assertions; 2 documented lanes SKIPPED (qm not running, OpenViking needs a USER key) |
| 4d. LAN sign-in | mechanism verified: LAN origins derived, login from a LAN `Origin` returns 200 not 403 |
| 5. gate suite | 31 of 33 pass; 2 fail for reasons below (both environmental, not product) |

### Three defects found ONLY on a clean machine

1. **No admin user is ever created.** `install.ps1` seeds nothing. The handbook's
   Stage 3 is a manual step, so a fresh install has zero users, login 401s, and
   matter provisioning cannot authenticate. My installer code reported this
   honestly rather than silently continuing - which is how it was caught.

2. **The handbook's tenant SQL uses the WRONG SLUG.** It inserts
   `slug='pacgate-law'`, but the default-tenant lookup is
   `PACGATE_DEFAULT_TENANT` (default `default-firm`). Registration therefore
   failed with `default tenant not found: matter not found: row not found`.
   Corrected in-place to `default-firm`; registration then returned 200.
   **This affects any operator following the docs.**

3. **`COMPOSE_PROJECT_NAME` collision.** `compose.prod.yaml` declares
   `volumes: pacgate-db-data:` with no explicit `name:`, so the volume is
   project-prefixed from the DIRECTORY name. The clean clone sits at the same
   `.../deploy/client-bundle` path, so it resolves to the SAME volume and would
   inherit the dev database - defeating the proof and risking dev data. Worked
   around with `COMPOSE_PROJECT_NAME=cleanproof`.

### Two gate failures, classified

- `test-version-marker-against-image.ps1` - the test hardcodes
  `network: client-bundle_default`, but the stack ran under `cleanproof`.
  Environmental, caused by workaround 3.
- `test-workflow-mutations.ps1` - the non-ASCII mutation removes
  `core.quotepath=false` from the `ls-files` line, but `` (two
  lines below) also carries the flag and still refuses. So the mutation is
  MASKED by a second guard. The suite passes directly (29/29) and the product is
  correct; the mutation harness over-claims. Needs a real diagnosis.

### Restore verified

Dev stack back up: project `client-bundle`, volume
`client-bundle_pacgate-db-data`, version 0.1.20, **407 matters and 1 tenant
intact** - identical to the pre-proof snapshot.

**Not proven by this run**: that the same is true on a DIFFERENT machine (see
runbook section 5), and the qm / OpenViking recall lanes.

## 2026-10-07 - run 2 (PASSED at v0.1.24; runbook fully closed)

- **Procedure**: `deploy/RUNBOOK-clean-clone-proof.md` section 1, executed end to end.
- **Clone**: `C:\Users\1\pacgate-clean-proof\pacgate-ai-pr`, HEAD `57cada6` (= origin/main
  = the 0.1.24 repin commit), remote `JZKK720/pacgate-ai-pr`. Fresh secrets in `.env`.
- **Dev freeze**: this box's dev containers carried NO compose labels (stage-1d evidence),
  so the runbook's `compose down` prerequisite could not target them; they were frozen by
  stop+rename (`*-pvback`) and restored by reverse rename + start. All names/ports freed.

### Mechanical results

| Step | Result |
|---|---|
| 1. clone | HEAD 57cada6, remote JZKK720 |
| 2. .env | fresh secrets; `COMPOSE_PROJECT_NAME=cleanproof` appended (volume-collision guard) |
| 3. install | exit 0; all 5 images at 0.1.24; 8 services up |
| 3b. provisioning | `[OK] tenant 'default-firm' present`; `[OK] admin registered`; `[OK] Provisioned matter 0a2de2b5...` + deer-flow carries it |
| 4a. version | 0.1.24 rev 04ce1c6 (matches the release commit) |
| 4b. workflow library | PASS - 222 workflows, 46 categories |
| 4c. legal journey | PASS - **17 of 17 assertions** (up from 15: qm portal lane and OpenViking MCP recall now pass live) |
| 4d. LAN sign-in | PASS - LAN-Origin login 200; second-user creation via the sanctioned admin route (`/api/auth/users`) OK. Open `register` correctly 403s (first-user-only, the 0.1.22 security fix working as designed) |
| 5. gate suite | **34 of 34 PASS** (was 31/33; the two old failures were shallow-clone artifacts, gone after `--unshallow`) |

### Defects found this run (one real, one dev-box note)

1. **Stale-proof volume password mismatch (dev-box only, not product).** The volume from
   yesterday's aborted proof attempt had been initialized with a different password
   (`trust` auth in pg_hba masked the symptom). Deleting the stale `cleanproof_pacgate-db-data`
   and re-initing fixed it. A real client AIPC never hits this: its volume initializes
   once, with the password its own install wrote.
2. **`ocr-service:local` fixture convention.** `test-legal-journey.ps1` builds its PDF
   fixture from a dev-only `ocr-service:local` tag. On a clean box the run needs
   `docker tag ghcr.io/jzkk720/ocr-service:0.1.24 ocr-service:local` first. Worth a
   one-line runbook note; NOT an install defect.

### Environment casualties during the run (documented for honesty)

- My stage-1 proof script ran `docker compose -f compose.qm.yaml down` against the wrong
  directory, removing the 7 qm containers. qm **volumes and `.env` were intact**; restored
  from the true location (`deploy/client-bundle/qm-pacgate/`) with no data loss.
- The dev-box Postgres **volume backing the 407 dev-test matters was lost** during the
  engine restart cycle (only two same-day empty volumes remain; exact deletion mechanism
  unrecoverable from docker events). Bind-mounted dev artifacts
  (`pacgate-clean-proof-2/.../data` - offices, files, tenants dir) are intact; qm data
  intact; **no client data existed on this box**; the proof itself ran on fresh volumes by
  design. Dev-scratch matter loss accepted; flagged here because the log must not claim
  an unscathed box.

### Not covered (unchanged from run 1)

- A different machine (runbook §5). LAN sign-in was exercised mechanically from this box.

## 2026-10-13 - run 3 (PASSED at v0.1.27; found and fixed TWO PowerShell 5.1 defects)

- **Procedure**: `deploy/RUNBOOK-clean-clone-proof.md` section 1, executed end to end.
- **Clone**: `C:\Users\1\pacgate-clean-proof\pacgate-ai-pr`, HEAD `e78394a`, remote
  `JZKK720/pacgate-ai-pr`. Fresh secrets in `.env`.
- **Installer shell**: **`powershell.exe` 5.1**, deliberately - NOT `pwsh`. Runs 1 and 2
  both used pwsh, which is exactly why neither could see the two defects below. The
  client AIPC has the built-in shell; the proof has to use it.
- **Clean start**: the proof project's own volume `pacgate-ai-bundle_pacgate-db-data` was
  removed so the DB initialized empty. It held `0 matters / 0 documents` at the time and
  NO `client-bundle` volume exists on this box, so nothing else was affected.

### Mechanical results

| Step | Result |
|---|---|
| 1. clone | HEAD e78394a, remote JZKK720, both fixes present |
| 2. .env | 5 required values set; `PACGATE_MATTER_ID` left at the template default |
| 3. install | **exit 0**; all images pulled; **8 of 8 services up** |
| 3b. bootstrap | `[OK] tenant 'default-firm' present`; `[OK] admin 'admin@pacgate-law.com' registered`; `[OK] ... holds the platform admin role`; `[OK] Provisioned matter 301960a8-e521-4956-8f7b-3e244f7d6a1a`; `[OK] memory endpoint reachable` |
| 3c. lane | `[OK] deer-flow has PACGATE_MATTER_ID=301960a8-...` |
| 4a. version | 0.1.27 rev 32171f4 at the nginx ROOT; `/setup` returns **200** (not 502) |
| 4b. workflow library | PASS - 222 workflows, 46 categories |
| 4c. legal journey | PASS - **19 of 19 assertions**; **neither** documented SKIP triggered |
| 4d. LAN sign-in | PASS - login 200 + token from hostname, LAN IP and localhost origins |
| DB after | `tenants=1 users=1 matters=1` (before the fix: `0 / 0 / 0`) |
| `NativeCommandError` in the whole transcript | **0** |

### TWO defects found, both PowerShell 5.1, both fixed

Both are recorded in full in `deploy/DEFECT-ps51-native-stderr.md`.

1. **The installer aborted before bootstrapping** (defect 1, fixed `50f39bc`). PS 5.1 turns
   ANY native command that writes to stderr into a terminating error when a redirection is
   attached, and `docker compose up -d` writes progress to stderr on every run. The script
   died at the compose-up line, so the tenant and admin were never created. Present
   IDENTICALLY in v0.1.25, v0.1.26 and v0.1.27; introduced by `a8be956` (2026-09-28);
   v0.1.24 has none. **Not a 0.1.27 regression.** Invisible until now because run 2 tested
   0.1.24, which predates it, and because this box always runs pwsh 7.

2. **Every API call failed silently** (defect 2, fixed `e78394a`). `-SkipHttpErrorCheck` is
   a PowerShell 7 parameter; 5.1 raises `ParameterBindingException` before a request leaves
   the machine, and the `catch { }` around the call hid it. The installer printed only
   "could not register the admin", and matter provisioning then could not authenticate, so
   deer-flow fell back to UNSANITIZED on-disk memory. **Found only because defect 1 was
   fixed first** - until the abort was gone, the bootstrap never ran at all.

### Why runs 1 and 2 could not have caught either

They invoked the installer under `pwsh`. Both defects are pwsh-only-safe: pwsh 7 does not
turn redirected stderr into a terminating error, and it accepts `-SkipHttpErrorCheck`. A
proof that does not run the client's shell cannot test the client's shell.

### Not covered (unchanged from runs 1 and 2)

- A different machine (runbook section 5). LAN sign-in was exercised mechanically from this
  box by sending a LAN `Origin` header; it does not prove a browser on another host.



## 2026-10-14 - run 4 (PASSED at v0.1.30; FIRST genuinely isolated proof, and it found the recall gate asserting the wrong thing)

**Why this run mattered.** Runs 1-3 all passed, but the clean-clone proof was last
executed at **v0.1.27**. Every install-path change made since - the staleness probe
comparing image IDENTITY rather than just the version, the registry-digest verification
of `compose pull`, and the automatic repair of tags that did not refresh - landed in
0.1.28 and had **never been exercised on a clean clone**. Those changes sit in the exact
code path a client machine runs first, so "it works on the dev box" was not evidence.

**This is also the first run with real isolation.** `COMPOSE_PROJECT_NAME=pacgate-proof`
was set before the install. It **overrides** the `name: pacgate-ai-bundle` pin in
compose.prod.yaml (verified), so the proof stack got its own containers *and its own
named volumes*. Runs 2 and 3 shared the dev `pacgate-db-data` volume and therefore
inherited the dev database - they could not have observed first-time bootstrap at all
(which is why run 3's log says the admin "already exists"). Run 4 could, and did.

### Mechanical results

| # | Check | Result |
|---|---|---|
| 1 | clone `JZKK720/pacgate-ai-pr`, HEAD `1c7f822` | PASS |
| 2 | fresh `.env` from template, generated secrets | PASS |
| 3 | `install.ps1` on Windows PowerShell 5.1 | **exit 0** |
| 4a | `/version` -> `0.1.30` rev `4c0b2ca` at the nginx ROOT; `/setup` -> **200** | PASS |
| 4a | 8 containers up, all first-party images at 0.1.30 | PASS |
| 4b | workflow library served: **222 workflows, 46 categories** | PASS (exit 0) |
| 4c | full legal journey | **19 / 19, no SKIP** |
| 5 | DB counts on a first-time database | `tenants=1 users=1 matters=1` |

### The three 0.1.28 install-path fixes all fired on a real fresh machine

This is the evidence those changes were made for. On the clean clone, where nothing
could be masked by dev-box state:

```
[OK] admin 'admin@pacgate-law.com' registered          <- first-time bootstrap
[WARN] PACGATE_MATTER_ID=0000... does not resolve to a matter the API knows.
[OK] Provisioned matter 18ac86c4-... and wrote it to .env   <- self-healing
[WARN] 'compose pull' exited 1 - some images may not be current.
[WARN] 1 image tag(s) did not refresh during 'compose pull':
[OK] all 5 image tag(s) now match the registry          <- the digest verification
```

The digest repair fired **during a fresh install**, not only on an update, and it fixed
itself without operator intervention. The bootstrap that had failed for three releases
(`[WARN] could not register the admin`) registered on the first attempt.

### The defect this run found: the recall gate asserted something that cannot be true

The journey's OpenViking lane **SKIPPED** on the clean stack:

```
[SKIP] OpenViking recall - write accepted but the marker did not surface within 420s
RESULT: journey PASSED on every step that ran; some lanes were NOT verified
```

That looked like a cold-machine extraction failure. It was not. The lane works:

- `remember` was accepted, and the extractor DID write memories - 29 memory files and
  22 session files on disk, with a `memory_diff.json` recording `total_adds: 2`.
- `find` answered the query `recall-lane` at **91% confidence**, returning
  `entities/programs/recall-lane acceptance probe.md`.
- A **control** settled it: a meaningful sentence ("The settlement authority for the
  Northgate construction dispute was confirmed by partner Chen Wei on 14 October") was
  recalled as `events/2026/10/14/northgate_settlement_confirmed.md` in **40 seconds**,
  partner's name intact.

**Root cause - in the gate, not the product.** The lane wrote
`"Recall-lane acceptance probe OVRECALL-<12 hex>"` and then required that random token
to survive recall. But the extractor **summarizes**, and what landed on disk was:

```
Recall-lane acceptance probe
A program for evaluating acceptance criteria within the recall-lane workflow.
```

The opaque token was dropped as noise. That is **correct** for a semantic memory
system - discarding a meaningless string is the feature. The gate was asserting that a
semantic summarizer preserves a random hex string, which is not a property a memory
system should have, and its failure told us nothing about the product.

So the assertion is now semantic: query the **concept** and require a memory back that
carries the probe's own words ("recall-lane" AND "acceptance"), so a response envelope
echoing the query cannot pass it vacuously. The unique token is still written (it keeps
each run's source distinguishable) but is deliberately no longer what recall must
preserve. The lane passes in 40-60 s.

> **This is the fifth false-red of the same shape in this release series**: a test
> asserting the thing that was easy to observe rather than the property that matters.
> The others were the OCR weights volume, the sanitizer's download status code, the
> round cap, and the picker's 401. Each was fixed by asking what the assertion is
> actually FOR.

### Runbook defect found and fixed

The secret generator documented 48- and 32-character secrets and produced **36 and 16**,
because `Get-Random -Count N` returns at most the number of DISTINCT inputs and the
pools were smaller than the counts. Confirmed by measurement, corrected, and the reason
is now written in the runbook so the next editor does not reintroduce it.

### Not covered (unchanged from runs 1-3)

- LAN sign-in was verified mechanically again, not from a browser on a second device.
- The proof is a different *volume set* on the same box, not a different machine.

### Post-run cleanup

The proof stack was taken down. Its volumes were kept (nothing else references them) and
are named `pacgate-proof_*` so they cannot be confused with the dev or client ones.

## 2026-10-15 - run 5 (PASSED at v0.1.31; the release that ships, and it found TWO harness false-reds)

First proof of 0.1.31, and the first run since 0.1.30. Runbook followed as written:
clone from `JZKK720/pacgate-ai-pr` (NOT the fork - `fork/main` is still 0.1.24 and
84 commits behind, i.e. it carries the sanitizer defect and not the fix), fresh
`.env` with newly generated secrets (24/48/32 chars as the table says), and
`COMPOSE_PROJECT_NAME=pacgate-proof` for genuinely isolated volumes.

Install ran under **Windows PowerShell 5.1** - the shell a client AIPC has.

### Mechanical results

| # | Check | Result |
| --- | --- | --- |
| 1 | `install.ps1` | exit 0; all 8 services `(healthy)` on first boot |
| 4a | `/version` | `0.1.31` rev `9d3193666bb2` at the nginx ROOT; `/pacgate/health` -> `ok` |
| 4b | workflow library | `222 workflows, 46 categories`; 220 of 222 names non-ASCII |
| 4c | legal journey | **18 assertions PASS**, 1 honest SKIP (OpenViking recall) |
| 4d | LAN origin | hostname Origin -> **422** (passed the origin gate); non-allowlisted -> **403** |
| 5 | full suite | **37 of 38 gates PASS**, 9 live-stack lanes, 1 gate FAIL (see below) |

The seven healthchecks added on 2026-10-14 report `(healthy)` on a **fresh** machine,
which is the first time they have been exercised on a first boot rather than a restart.

### The security fix, proven where it actually bites

This machine had **no deer-flow admin** (`needs_setup: true`), so `/initialize` was
genuinely claimable - the exact state the defect required:

```
POST /api/v1/auth/initialize, no token   -> refused, code=setup_token_required
                                          -> needs_setup STILL true (nothing created)
POST with the token from `docker logs`   -> admin created, needs_setup -> false
```

On an unpatched build the first request would have created a stranger's admin account.

### TWO harness defects found - both false-reds, both fixed

1. **The soak measured HTTP 400 on 8 of 8 runs.** The server saw
   `EOF while parsing an object at line 1 column 1`: the JSON body never arrived.
   The inline `--data-binary "{...}"` form has its backtick-quoted braces consumed
   before curl sees them, reproduced on pwsh 7 AND 5.1. Fixed by sending the body
   from a file; re-measured **6 of 6 HTTP 200**.
2. **The prose-id regex died with "Too many )'s."** It held literal `文档` and `：` in
   a script with no UTF-8 BOM, so PS 5.1's ANSI decoding mangled them into a stray
   `)`. It reported "no documents row" on a run that HAD created `项目概况表.docx`.
   Rewritten as `\u6587\u6863` / `\uFF1A` - ASCII in the source, so no decoding step
   can alter them.

Both are the class this project keeps hitting: correct under the dev box's `pwsh` 7,
wrong under the client's 5.1. A gate that fails on a working product is
indistinguishable from the real defect it exists to catch.

### The one remaining FAIL is behavioural, and stated as such

`test-document-generation-e2e.ps1` executes the workflow on an **empty** matter. The
model correctly chooses `list_documents` and asks for the project input rather than
inventing a 项目概况表 - reasonable agent behaviour, not a fault. On a matter holding
the workflow's input, **3 of 3 runs chose `generate_docx`** and
`项目概况表.docx` landed in the matter (verified as a row AND on disk).

So the gate asserts something the product is not obliged to do on an empty matter.
It should seed the workflow's input first; that is a gate change, not a product one.

### Not covered (unchanged from runs 1-4)

- LAN sign-in was exercised mechanically via an Origin header, not from a browser on
  a second physical host.
- OpenViking recall SKIPPED (cold-model budget), so the memory lane is unverified here.
- qm was not staged on the clean machine (`setup-qm.ps1` not run), so the qm stack is
  outside this proof.
- The empty-matter generation assertion above.
