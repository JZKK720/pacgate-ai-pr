# Release & deployability plan — 0.1.32

**Date:** 2026-10-19
**Question:** what is *not* fixed, is the build deployable to other machines, do we bump and
rebuild the GHCR images, and must qm-pacgate + openviking be in the upgrade path?

---

## 1. Do NOT rebuild qm-pacgate or openviking — and here is why that is not a shortcut

You asked whether this release should include qm-pacgate and openviking images. **No, and it
cannot** — we do not own either image:

| stack | image | owner | rebuildable by us? |
| --- | --- | --- | --- |
| api / mcp / ocr / deer-flow / frontend | `ghcr.io/jzkk720/*` | **us** | yes |
| qm core / portal / auth / web-ui / admin | `ghcr.io/yc-software/qm/*@sha256:…` | **vendor** | **no** |
| openviking | `ghcr.io/volcengine/openviking@sha256:…` | **vendor** | **no** |

Both are pinned **by digest**, not tag, which is stronger: no push can silently move them.
`build-ghcr.yml` builds exactly five images (`pacgate-api`, `pacgate-mcp`, `ocr-service`,
`deer-flow-pacgate`, `deer-flow-frontend-pacgate`). Nothing else is in our release.

**So the correct treatment is config, not images.** qm and openviking reach a client through
**config + env + provisioned account state**, and that is precisely where the real defects were:

| what must travel with the release | where it lives | in the image? |
| --- | --- | --- |
| qm deploy definitions (`compose.qm.yaml`, patches, sandbox tool, sandbox-local Dockerfile) | tracked `deploy/qm-pacgate/` → staged by `setup-qm.ps1` | no — **file copy** |
| qm `.env` (secrets, OpenViking keys) | per-machine, gitignored | no |
| OpenViking config | `OPENVIKING_CONF_CONTENT` rendered into `.env` by `install.ps1` | no — **env var** |
| sandbox exec-daemon image `qm-pacgate-sandbox-local` | **built on the client** from tracked `sandbox-local/Dockerfile` | no — **local build** |

The one genuinely missing piece: **nothing builds `pacgate-sandboxes` in CI**, even though
`compose.qm.yaml` pins it by digest as `FLY_BASE_IMAGE`. On the `local` backend it is inert
(the comment says so explicitly) and the live path builds `qm-pacgate-sandbox-local` locally.
So it is not a blocker — but if a machine ever flips to the `fly` backend it would pull a
digest we cannot reproduce. Worth noting, not worth blocking on today.

---

## 2. What was NOT fixed, and why each is a decision rather than an omission

### 2a. The sandbox authenticates as the deployment admin (security posture)

`qm-pacgate/.env` sets `PACGATE_API_EMAIL=admin@pacgate-law.com`. `install.ps1` provisions
`qm-bridge@pacgate.local` with a CSPRNG password — but **only when `$needsBootstrap`**
(qm's `.env` absent). On a machine where `.env` already exists, the bridge is never created.

Probed: admin logs in; `qm-bridge@pacgate.local`, `qm-bridge@pacgate-law.com`,
`bridge@pacgate-law.com` all 401. **No bridge account exists.**

The sandbox runs model-directed tool calls and currently holds the install path's own principal.
`setup-qm.ps1`'s own comment argues against exactly this. **Deliberately not changed:** creating
the account and repointing qm is a security decision about least privilege, and it needs the
admin credential to do. The new pre-write verification makes repointing safe.

### 2b. Two compose files define the same project

`compose.prod.yaml` and `compose.bundle.yaml` both declare `name: pacgate-ai-bundle`. Four
services differ materially — and `compose.prod.yaml` bind-mounts `deploy/pacgate-mcp/server.py`
over `/app/server.py`, so a "prod" machine executes working-tree code while reporting the pinned
image tag. **Deliberately not changed:** choosing the delivery authority changes which services
get which config on every machine, and that is a deployment-topology decision. `test-lane-connectivity.ps1`
reports provenance on every run so the mix is visible instead of inferred.

### 2c. `PACGATE_MODEL_MID` defaults to a 17 GB model

Verified **latent, not active**: no workflow in the 222-workflow library declares `tier: mid`, and
`LlmTier::Mid` appears only in a test helper. Left at the vendor default to avoid an unnecessary
behaviour change. `test-aipc-capacity-fit.ps1 -Strict` fails on it if you ever wire it up.

### 2d. OpenViking account scoping is unenforced

Measured all three variants on `/mcp`: `X-OpenViking-Account: default-firm` → **200**,
`default` → **200**, no header → **200**. OpenViking reports exactly one account (`default`,
`user_count: 0`), so `default-firm` **does not exist** — yet tool calls succeed either way.
The header is advisory in this build. Not a breakage; it means per-tenant isolation is not
currently enforced by the service. Documented because it is a correctness gap, not a crash.

---

## 3. What WAS fixed for deployability in this pass

| gap | fix | why it mattered |
| --- | --- | --- |
| a fresh machine got `MAIN=gemma4:12b-it-qat` → **document workflows produced nothing** | compose defaults **and** `ModelConfig::DEFAULT_MAIN_TAG` → `deepseek-v4.1-flash:cloud` | my earlier `.env` fix was gitignored, so it would **never have reached AIPC 1 & 2** |
| `.env.example` had no tier documentation | documented all three tiers + the egress trade-off | a fresh clone had no way to know the knob existed |
| Rust ↔ compose ↔ pre-pull consistency | kept in sync; roster gate **13/13** | the gate enforces it, so drift is caught |
| qm staleness invisible on `-Update` | new read-only `test-qm-currentness.ps1` | `-Update` cannot safely restart a staff-facing stack — so staleness must be **visible** instead |

**Verified with the override removed:** `PACGATE_MODEL_MAIN` deleted from `.env`, `pacgate-api`
recreated, document gate → **19/19**, `tools_used: …, generate_docx, read_document`. A fresh
machine now works with **no manual `.env` step**.

`cargo test -p pacgate-core` → **10 passed**.

---

## 4. Does the upgrade path reach qm and openviking?

| lane | on `-Update` | correct? |
| --- | --- | --- |
| api / mcp / ocr / frontend images | pull + `up -d` (recreates on config change) | yes |
| deer-flow / deer-flow-frontend | explicit `restart` (code is bind-mounted) | yes |
| OpenViking config | rendered to `.env`, then **`up -d` re-reads it** | yes |
| **qm stack** | **NOT touched** | **deliberate** — "a restart of the co-working stack is user-visible (qm is where staff work)" |
| qm definitions | re-staged from tracked source | yes |
| qm `.env` | **preserved, never regenerated** | yes — so our credential fixes survive |

So openviking **is** in the upgrade path; qm **is not, by design**. That design is right — but it
left staleness invisible, which is how a rejected password survived every update. The new
`test-qm-currentness.ps1` closes that: it fails when the staged deploy differs from tracked
source, or when a running container holds an env value its `.env` no longer contains, and prints
the one command to run when nobody is mid-session. **Read-only** — it never restarts anything.

---

## 5. Release checklist — COMPLETED

**Do not ship the current commits under `v0.1.31`.** `test-release-provenance.ps1` was correctly
red: config that reaches a built image changed after `9d31936`, so the tag no longer identified
what clients pull.

### Status: 0.1.32 is released and verified

| step | result |
| --- | --- |
| bump to 0.1.32 | done — 99 edits / 11 files, all pins verified |
| commit + push main | done — `ec0f070` |
| annotated tag `v0.1.32` pushed | done |
| `build-ghcr.yml` | **success**, 15m23s, run `39183040344` |
| all 5 images share one revision | `ec0f070bfcf2` |
| `test-release-provenance.ps1` | **PASSED** — "v0.1.32 identifies the ec0f070bfcf2 artifacts clients will pull" |
| anonymous pull (no `docker login`) | **5/5 HTTP 200** — public, client install path works |

### One thing that blocked the first attempt, worth recording

The first tag push **failed in 17 seconds**: `build-ghcr.yml` stops at its credential-guard job,
which runs `scripts/detect-literal-credentials.ps1`. That script flagged
`test-qm-currentness.ps1:143` — my own new gate — so no image was built.

Two mistakes, both mine:

1. The code wrote an env-var **name mapping** in a shape the `ps-password-literal` heuristic
   cannot distinguish from a secret (a password-named key with a long token right of `=`). The
   rule was correct to reject it; the code was rewritten as a name-pair array so the shape does
   not exist.
2. My first repair added a comment **quoting** that shape, re-introducing the match one line
   lower — exactly the trap the detector's own note warns about. The comment now describes the
   shape without reproducing it.

**Process lesson:** after `git add` I ran `assert-no-staged-secrets.ps1` and treated it as
sufficient. It is a different, narrower guard. `detect-literal-credentials.ps1` reads the git
index (`git ls-files`), so it *would* have caught this locally — I simply did not run it. Both
now run before every commit.

The tag was force-re-pointed to the fixed commit. That was safe **only** because the failed run
produced no images; had it built some, the old tag would have had to be left alone and a new
patch version cut instead.

### Client-side after updating (AIPC 1 & 2)

```
.\install.ps1 -Update
.\scripts\test-cross-stack-credentials.ps1    # shared secrets agree
.\scripts\test-lane-connectivity.ps1          # all 11 edges (incl. qm -> api/openviking)
.\scripts\test-qm-currentness.ps1             # is qm stale? restart if so, when idle
```

`install.ps1 -Update` preserves `qm-pacgate/.env` and never rewrites it, so a machine carrying the
OLD divergent password **stays divergent**. That is exactly what
`test-cross-stack-credentials.ps1` now catches on the client: if C1 fails, set
`OPENVIKING_API_KEY` / `PACGATE_API_PASSWORD` in `qm-pacgate/.env` to the values in
`client-bundle/.env`, then recreate `core`. This cannot be fully automated because it edits a
live credential on a running staff-facing stack.

**Rollback:** images are tag-addressed and `0.1.31` stays published, so a client reverts by
pointing `compose.prod.yaml` back at `:0.1.31` and running `docker compose up -d`. No data
migration is involved, and qm/OpenViking are untouched by the release so need no rollback.


---

## 6. Honest summary

**Deployable after the bump + rebuild, with one caveat that needs a human on each machine:**
the qm credential reconciliation above cannot be fully automated, because it edits a live
credential on a running staff-facing stack. The gate makes it detectable and the fix is two
values + one recreate.

**Not fixed, by deliberate choice:** admin-as-bridge (security posture), split compose authority
(topology), MID tier size (latent), OpenViking account enforcement (vendor behaviour).
