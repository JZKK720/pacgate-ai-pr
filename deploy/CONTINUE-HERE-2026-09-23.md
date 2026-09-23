# CONTINUE HERE — 2026-09-23

Status snapshot for the next session or the next machine. Points at authoritative
artifacts instead of reproducing them. Supersedes
`CONTINUE-FROM-OTHER-MACHINE.md` at the repo root, which stops at **session 15 /
2026-08-27 / v0.1.2** and is now badly stale.

**Latest work (2026-09-23, `151d05b`):** the legal-journey acceptance test landed
(design-doc item B). It found a real shipped-state gap — OpenViking recall cannot
work because no account user is provisioned. Details under "Open work" §2.

## Where things actually stand (verified 2026-09-23)

| Fact | Value |
|---|---|
| Branch / HEAD | `main` = `84cc6c4`, clean, matches `origin/main` |
| Release | `0.1.17`, revision `2a51fbd` |
| Images | five, `ghcr.io/jzkk720/*:0.1.17`, all anonymous-200 |
| Live dev stack | up ~23h; `pacgate-api` running `ghcr.io/jzkk720/pacgate-api:0.1.17` |
| Local suites | `scripts/run-all-checks.ps1` **20/20 gates, exit 0** |
| Live workflow library | **222 workflows / 46 categories** (HTTP + MCP lanes) |
| AIPC 1 / AIPC 2 | **neither deployed** — this is the dev PC only |

One stray untracked file named `0` sits at the repo root. Not ours; left alone.

## The event that matters most right now

The firm's workflow library was being **silently replaced by 10 built-in
workflows** because `./workflows` was bind-mounted into `deer-flow` (which has no
workflow router) while `pacgate-api` — which owns `GET /api/workflows` — had no
mount and no `WORKFLOWS_DIR`. No error; a well-formed 200 with the wrong data.

It was then **fixed only half way**. `b7fc540` corrected `compose.prod.yaml`;
`compose.bundle.yaml` kept the original defect and nothing objected, because
`install.ps1` uses `compose.prod.yaml` exclusively. `039afdc` completed it and
removed a dead mount still sitting on `deer-flow`.

Full record: `deploy/DEFECT-workflow-mount-wrong-service.md`.

**The transferable lesson:** a green runtime check certifies only the file that is
*running*. It says nothing about the parallel file beside it. When the same wiring
exists in more than one file, assert it in the source files, not just in the
running system.

## Deploying: use `JZKK720`, never the fork

**Canonical procedure: `deploy/HANDOFF-AIPC-0.1.17.md`.** Both per-machine prompts
now point there; the machine-specific wrappers carry only their own notes.

```
JZKK720/pacgate-ai-pr   main = 4f9329e   ← current, clone this
pacgate-ai/pacgate-ai-pr  main = 7e0aa4b   ← 26 commits BEHIND
```

The fork has `a0198d5` (the CORS fix) but is **missing `b7fc540` and `039afdc`**.
It carries the 15 workflow YAMLs but not the wiring, so a machine cloned from the
fork serves **10 built-ins instead of 222**.

Three client-facing docs previously told the engineer to clone the fork, and the
deployment handbook asserted the two repos were "identical ... so either clone
works" — true when written, false one day later. All corrected, runnable
fork-clone commands removed, and now **guarded** by
`scripts/test-handoff-command-safety.ps1` (21st gate, proven by injection).
`deploy/AIPC2-HANDOFF-PROMPT.md` (v1) and `-v2.md` are superseded; `AIPC1`'s v2
is correct but its expected commit moved to `4f9329e`.

Update mechanism — one command, it syncs the repo itself (`install.ps1` L73-201:
`git fetch` → `--ff-only` pull → reports changed files). No separate `git pull`
needed, and there is no early exit before that block even when the image version
already matches:

```powershell
cd C:\pacgate-ai-pr
.\deploy\client-bundle\install.ps1 -Update
```

Because the workflow fix is **compose + repo content and involves no images**,
`docker compose up -d` applies it — unlike a bind-mounted file edit, which needs
the step-7c `deer-flow` restart.

## Open work

**1. Fresh-clone install test — YOURS, and it is the real gate.**
Not done, and not something the dev box can substitute for: it accumulates
credentials, pulled models, and rendered gitignored configs that mask
clean-machine failures. This is the standing rule for any install-path change.

**2. Item B, the combined legal-journey test — DELIVERED 2026-09-23 (`151d05b`).**

`scripts/test-legal-journey.ps1` proves the whole journey in one command and fails
loudly on the first broken step. Verified live: **15 assertions pass** on 0.1.17.

```powershell
pwsh -File scripts/test-legal-journey.ps1
pwsh -File scripts/test-legal-journey.ps1 -RequireAllLanes   # on a machine where qm + OpenViking are expected
```

**Two lanes are NOT proven, and the test reports SKIP rather than a green line:**

- **qm co-work** — the qm stack is not running here. Start it with
  `deploy/qm-pacgate/setup-qm.ps1`.
- **OpenViking recall — a REAL GAP, not a test defect.** OpenViking is two-tier:
  the configured root key is an **admin** credential (200 on
  `/api/v1/admin/accounts`) while recall needs an **account-user** key. The
  `default` account reports **`user_count: 0`**, so no user is provisioned and the
  recall lane cannot work until one is created via
  `POST /api/v1/admin/accounts/{id}/users/{uid}/key`.

Design doc: `docs/superpowers/specs/2026-09-22-stack-hardening-before-2.1-design.md`.

**3. Correct `deploy/AIPC2-HANDOFF-PROMPT-v2.md`** — fix the clone URL and the
inverted namespace claim so the engineer does not deploy the defective wiring.

> **DONE (2026-09-23, `83cb23a`).** Both AIPC2 prompts and both deployment
> handbooks corrected; the v1 prompt and the v2 prompt for AIPC #2 are superseded;
> `deploy/HANDOFF-AIPC-0.1.17.md` is now canonical. Guarded by
> `scripts/test-handoff-command-safety.ps1`.

**4. Deploy AIPC 1 and AIPC 2** from a JZKK720 clone. Scheduled-update
registration is a **first-install** concern, not an update step.

**5. Plan 023 (deer-flow 2.1 upgrade) — blocked, correctly.**
`plans/023-deer-flow-2.1-upgrade.md`. Upstream `v2.1.0` returns **404**; `latest`
equals `v2.1.0-rc0`, so the rebase target does not exist. Prep 1.1-1.4 is done
(patch inventory, intents, memory-adapter decision, ship-now items). Execution
waits for GA. No image rebuild is needed for the current work.

**6. Standing gap:** `GHCR_MIRROR_PAT` is unset, so the `pacgate-ai` mirror has
still never mirrored. Compose pins `jzkk720/*`, so the client path is unaffected.

## Traps worth not re-learning

- **`docker compose up -d` does not recreate a container when only the content
  under the same tag changed.** Use `--force-recreate` after a local retag.
- **A probe reporting everything broken is probably a broken probe.** Validate it
  against a known-good control first.
- **"Could not check" must never read as "checked and fine."** Guards here use a
  distinct exit code (2 / 3) for that, and it is not reported as a pass.
- **A mutation that cannot APPLY is indistinguishable from a defect that cannot be
  DETECTED.** Verify each injected fault changed a byte before trusting green.
- **PowerShell `-match` / `-replace` are case-INSENSITIVE by default.** A comment
  containing the lowercase prose word satisfied a check meant for an UPPERCASE
  config key; the guard passed a file with the real key deleted. Use `-cmatch`.
- **Fixing by anchor string fails on indentation mismatches.** Delete or insert by
  line position within a service block instead.
- **Never answer a permission question with a dry run.** `git push --dry-run`
  reported success on a fork write that then returned permission denied.
- After `test-workflow-mutations.ps1`, always `git status --short` and restore any
  file the harness failed to put back.

## Do not re-open these (already decided)

- **Cloud chat models are intentional.** `deepseek-*-cloud` for deer-flow and qm
  is a recorded firm decision — prompt egress accepted for faster research
  timelines. The RAG pipeline (embeddings, extraction, Postgres) stays on-device.
- **Images are public by design**, and the on-site engineer installs. Do not
  propose `docker login ghcr.io` for the client path.
- **Workflows have no user-facing UI by design (so far).** The only access path is
  MCP tools inside an agent chat; a workflow gallery is unbuilt scope, not a bug.
- **Local Ollama model choice belongs to the user** and can change per machine;
  re-check `ollama list`, `deer-flow-config.yaml`, `qm.config.jsonc`, and
  `deploy/client-bundle/ollama-models.txt` before any model-dependent step.

## Verification commands

```powershell
# All local gates (static, no stack required for most)
pwsh -File scripts/run-all-checks.ps1

# The workflow library is actually served (needs the stack + .env)
pwsh -File scripts/test-workflow-library-served.ps1

# The wiring in the compose files itself (static)
pwsh -File scripts/test-workflow-compose-wiring.ps1
pwsh -File scripts/test-workflow-compose-wiring-mutations.ps1   # proves the above can fail
```
