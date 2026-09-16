# GHCR Master-Build Audit — 2026-09-15

Read-only audit answering: *can we build a single master GHCR release from
`origin/main` / the `pacgate-ai` fork, and does that build pick up everything?*

Scope: image publishing pipeline only (`.github/workflows/build-ghcr.yml`,
`deploy/*/Dockerfile`, `deploy/client-bundle/compose.*.yaml`,
`deploy/build-*.ps1`). All probes were anonymous/read-only.

---

## 1. Verdict

**Yes — the master build works, and it is a true single source of truth.**
Two defects block a *trustworthy* release, and neither is a build problem:

| # | Defect | Severity | Blocking? |
| --- | --- | --- | --- |
| 1 | CI has never passed — the *verification* step is broken | HIGH | Yes (masks real failures) |
| 2 | Published `pacgate-api` / `pacgate-mcp` are stale vs `main` | CRITICAL | Yes (ships known bugs) |

All four `docker/build-push-action` steps passed on **every** CI run. Only the
final curl-based manifest check failed, so the pipeline itself is sound.

---

## 2. Topology

| Property | `origin` | fork |
| --- | --- | --- |
| URL | `JZKK720/pacgate-ai-pr` | `pacgate-ai/pacgate-ai-pr` |
| Visibility | public | public |
| Release tags | none | `v0.1.3` … `v0.1.9` |
| `build-ghcr.yml` | present | present |
| `github.repository_owner` | `JZKK720` | `pacgate-ai` |
| Workflow runs | 0 | 7 (all failed at verify) |

`origin/main` (`832d84e`) and fork `main` (`28dc159`) have **identical trees**
(`1fd4531…`), and local HEAD matches both. Content-wise the ref choice is
cosmetic.

### Why the fork is nonetheless the mandatory release source

The workflow sets `IMAGE_PREFIX: ghcr.io/${{ github.repository_owner }}`, and
every compose pin targets `ghcr.io/pacgate-ai/*`. A tag pushed to `origin` would
build into `ghcr.io/jzkk720/*`, which compose does not reference — and the
personal namespace holds **no** current images (`jzkk720/pacgate-api:0.1.9`
returns 404). Release tags must go to the fork.

---

## 3. Defect 1 — the verify step is broken (CI never green)

All 7 runs fail identically. Step-level trace of run `34588942041` (`v0.1.9`):

```text
ok   Set up job / Checkout / Resolve image tag / Set up Docker Buildx / Log in to GHCR
ok   Build & push pacgate-api
ok   Build & push pacgate-mcp
ok   Build & push deer-flow-pacgate
ok   Clone deer-flow frontend source
ok   Build & push deer-flow-frontend-pacgate
** failure **  Verify image manifest (anonymous HEAD)      <-- the ONLY failure
ok   Post ... (all cleanup)
```

### Root cause, reproduced

`build-ghcr.yml:131` omits the OCI manifest `Accept` header. GHCR answers `404`
for a header-less manifest request **even when the package is public**:

```text
CI as written (no Accept header) => HTTP 404
Corrected (with Accept header)   => HTTP 200
```

This exact gotcha was already learned and fixed in
`deploy/AIPC-DEPLOYMENT-HANDBOOK*.md` — it was simply never carried back into the
workflow.

**Effect:** CI reports failure on a fully successful release, so a genuinely
broken build is indistinguishable from a false alarm.

**Fix** — add the header to the verify step:

```yaml
code=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json" \
  -H "Authorization: Bearer $tok" \
  "https://ghcr.io/v2/${IMAGE_PREFIX#ghcr.io/}/${img}/manifests/${{ steps.tag.outputs.tag }}")
```

---

## 4. Defect 2 — published images are stale vs `main` (CRITICAL)

The current compose pins are split three ways (`api`/`mcp` `0.1.9`,
`deer-flow` `0.1.10`, `frontend` `0.1.11`), yet the workflow tags **all four**
with one tag. A release therefore requires unifying the pins.

Verified by pulling the published images and diffing their **contents** against
`main`.

### `pacgate-mcp:0.1.9` — stale, ships a broken tool

```text
published 0.1.9 : markitdown>=0.1.5
main HEAD       : markitdown[docx,pptx,xlsx,pdf]>=0.1.5
```

DOCX/PPTX/XLSX/PDF support are **optional extras** in markitdown and do not
arrive automatically. The published image therefore throws
`FileConversionException` on every `.docx` — `pacgate_convert_document` is broken
in the current release. Fixed in `ece697f` (2026-09-12), after the `0.1.9` build.

### `pacgate-api:0.1.9` — stale, ships a client-visible RAG bug

```text
published 0.1.9 : ... USING ivfflat (embedding vector_cosine_ops) WITH (lists = 100)
main HEAD       : ... USING hnsw   (embedding vector_cosine_ops)
```

IVFFlat fixes cluster centroids at index-build time, so **newly uploaded
documents are not reliably returned by search**. Fixed in `150db2c`
(2026-09-12), after the build.

### `deer-flow-pacgate:0.1.10` / `deer-flow-frontend-pacgate:0.1.11` — newer, untagged

`0.1.10` was built 2026-09-13 06:38 and tested to include base-absent content
(`fonts-noto-cjk`, `officecli 1.0.149`, `glm-5.3`), so it was built from
near-HEAD rather than from the `v0.1.9` tag. `0.1.11` has **no backing tag at
all** — both came from manual local builds.

### Build provenance

| image | tag | built | `created` | revision label |
| --- | --- | --- | --- | --- |
| `pacgate-api` | `0.1.9` | pre-`ece697f` | 2026-09-11T10:26:29Z | — |
| `pacgate-mcp` | `0.1.9` | pre-`ece697f` | 2026-09-11T10:26:49Z | — |
| `deer-flow-pacgate` | `0.1.10` | near-HEAD | 2026-09-13T06:38:07Z | `7e7f041` † |
| `deer-flow-frontend-pacgate` | `0.1.11` | near-HEAD | 2026-09-13T04:01:29Z | — |

† `7e7f041` is the **bytedance `v2.0.0` tag**, inherited from the `FROM` base
image — not a Pacgate commit. The Pacgate layers set no
`org.opencontainers.image.revision`, so an image cannot be traced back to the
commit that built it. Worth adding.

### Public pullability

All four `ghcr.io/pacgate-ai/*` pins, on both `:<tag>` and `:latest`, return
**HTTP 200**. External deps verified public:
`bytedance/deer-flow-backend@sha256:e7c503a8…`,
`volcengine/openviking@sha256:46f9e34c…`.

---

## 5. Release mechanics and pin surface

`workflow_dispatch.default` is stale (`"0.1.3"`). Trigger a unified release by
tag, or by dispatch with an explicit tag input. Pushing to the fork **is** the
trigger; a tag on `origin` is a no-op (zero runs of this workflow).

Files carrying a version pin (must move together):

| File | Note |
| --- | --- |
| `pacgate-ai/Cargo.toml`, `Cargo.lock` | `0.1.9` |
| `deploy/client-bundle/compose.prod.yaml` | 4 pins |
| `deploy/client-bundle/compose.bundle.yaml` | 4 pins — not covered by `.github/instructions` |
| `deploy/client-bundle/deer-flow-extensions-config.template.json` | |
| `deploy/client-bundle/patches/deer-flow-prompt.py` | |

---

## 6. Source-of-truth map — does the master build pick up everything?

**Yes, for the `pacgate-ai-pr` stack.** Three independent checks confirm no work
is stranded:

| Check | Result |
| --- | --- |
| All fork branches merged? | Yes — `feat/agent-capability-enablement` and `feat/deer-flow-pacgate-mcp` are both fully contained in fork `main` |
| Fork `main` contained in local HEAD? | Yes |
| Tree equality | `origin/main` = fork `main` = local HEAD = `1fd4531…` |

A build from any of the three refs produces identical bytes. There is no "other
repo" holding unreleased stack work.

### The build consumes upstream directly, not the sibling forks

The `pacgate-ai/*` sibling repos (`markitdown`, `odysseus`, `ironclaw`,
`hermes-agent`, `dockhand-dash`) are **upstream mirrors**, not stack components.
Nothing in the build path references them. Our real dependencies are:

| Dependency | Source |
| --- | --- |
| deer-flow backend | `ghcr.io/bytedance/deer-flow-backend@sha256:e7c503a8…` |
| deer-flow frontend | `github.com/bytedance/deer-flow` tag `v2.0.0` |
| markitdown | PyPI `markitdown[docx,pptx,xlsx,pdf]` |
| openviking | `ghcr.io/volcengine/openviking@sha256:46f9e34c…` |

### The one exception: `pacgate-ai/deer-flow@pacgate-layer`

`pacgate-ai/deer-flow` is the **only** sibling fork carrying custom work. Branch
`pacgate-layer` (`107199c`, 2026-09-05, PR #1) defines an **all-in-one** image —
`docker/Dockerfile.pacgate` — containing:

- 34 legal skills in `/app/skills/public/`
- `pacgate_config.py` (3-axis routing + 5 hard gates)
- `pacgate_routing_middleware.py` + `pacgate_hard_gates_middleware.py`
- `matters` router + frontend, nginx + supervisor, ports 2026/8001/3000

**None of this is in our build.** The published image was probed directly and
contains only `/app/adapters` + `/app/backend` — the wrapper architecture, not
the layer architecture.

Assessment — treat the layer as **superseded, not pending**:

| | `pacgate-layer` | our wrapper |
| --- | --- | --- |
| Last change | 2026-09-05 | 2026-09-13 |
| officecli | `1.0.139` | `v1.0.149` |
| Namespace | `ghcr.io/jzkk720/*` (deprecated — 404s) | `ghcr.io/pacgate-ai/*` |
| Post-tag fixes | none | markitdown extras, HNSW, CJK fonts, `tool_search` |

The layer is 8 days older and targets a namespace that no longer serves images.
Its Dockerfile also differs architecturally (separate frontend image vs. bundled
all-in-one). Legal capability in the delivered stack instead comes through
`deploy/client-bundle/workflows/` (15 YAMLs) and `personas/`.

**This is a decision for the owner, not an automatic merge:** the layer's routing
and hard-gate middleware are not replicated anywhere else. Either port that
middleware forward into the wrapper, or retire the branch explicitly so
`deploy/AIPC2-HANDOFF-PROMPT-v2.md` stops directing AIPC #2 to build from it.

### Two pipelines currently compete for the same image name

| Pipeline | Repository | Publishes |
| --- | --- | --- |
| `build-ghcr.yml` | `pacgate-ai/pacgate-ai-pr` | 4 images incl. `deer-flow-pacgate` |
| layer workflow | `pacgate-ai/deer-flow` (`pacgate-layer`) | also `deer-flow-pacgate` |

Both can produce `deer-flow-pacgate:*`. Whichever pushed last wins. Retiring the
layer removes this ambiguity.

### Minor wording correction

`pacgate-ai` is a **User account, not an organization** — the REST org endpoint
returns nothing for it; `/users/pacgate-ai/repos` lists the 7 repos. The
"pacgate-ai org" phrasing in `deploy/README-BUILD.md` should be corrected.

---

## 7. Non-blocking findings

- **No `.dockerignore` anywhere.** `deer-flow-pacgate` builds with context `.`
  (whole repo), uploading `pacgate-ai/target/`, `.git/`, and PDFs to the builder
  every release.
- **officecli step masks its own failure.** `f510487` rewrote it to
  `... && officecli --version || echo "WARNING: skipped" && rm -rf /tmp/*`.
  In `sh`, `A && B || C && D` parses as `((A && B) || C) && D`, so the `||`
  swallows a failed install. The comment says this is *intentional* best-effort
  (some client networks egress-block `github.com` release assets), but the
  consequence is that "officecli is present" is unverifiable from a green build.
- **`deploy/frontend-patches/` vs `deploy/client-bundle/patches/`.** Two patch
  trees exist (5 and 8 files). `build-frontend.ps1` reads the former; the latter
  is what `compose.prod.yaml` mounts. They must be kept in sync manually.
- **Stale comment**: `deploy/build-frontend.ps1` header still references
  `ghcr.io/jzkk720/deer-flow-frontend-pacgate:0.1.0`.
- **Third-party QM images** `yc-software/qm/{core,auth,portal,web-ui}` are not
  anonymously readable (404). Affects only the QM stack, not the four Pacgate
  images. Confirm how AIPCs obtain them before a clean-room install.

---

## 8. Answer

> *Can we build the master GHCR, and will it pick up all the fixes and updates?*

**Yes to both.** The build is proven — four images build and push on every CI
run, all published tags are publicly pullable, and the three refs
(`origin/main`, fork `main`, local HEAD) hold byte-identical trees with both fork
feature branches fully merged. Nothing is stranded in another repo.

Three things are needed for a *trustworthy* release:

1. Fix the `Accept` header in the verify step so CI can go green and start
   meaning something.
2. Unify the version across the six pin files (currently split three ways).
3. Re-tag from **near-HEAD**, not from `v0.1.9`, so the release picks up
   `ece697f` (broken `.docx` conversion) and `150db2c` (newly-uploaded documents
   unfindable) — both client-visible.

One thing needs an owner decision rather than a merge: the
`pacgate-ai/deer-flow@pacgate-layer` branch. It is the only sibling fork with
custom work, it is not in our build, and it is now competing for the same image
name from the deprecated namespace. See `plans/011-ghcr-master-release.md`.

---

## Appendix — audit tooling added

Read-only helpers:

- `scripts/check-ghcr-pull.ps1` — anonymous HEAD probe (200 public / 401–403 private).
- `scripts/inspect-ci-runs.ps1` — step-level CI conclusions via the public API (no auth).
- `scripts/test-ci-verify-step.ps1` — reproduces the `Accept`-header divergence.
- `scripts/identify-deerflow-image.ps1` — fingerprints a deer-flow image as wrapper vs. all-in-one.
- `scripts/list-related-repos.ps1`, `scripts/find-pacgate-repos.ps1` — repo/package inventory.
- `scripts/audit-fork-divergence.ps1` — fork-vs-upstream comparison (needs a token when the anon API budget is spent).

For image provenance prefer:

```powershell
docker buildx imagetools inspect ghcr.io/pacgate-ai/<img>:<tag> --format "{{json .Image}}"
```

The anonymous REST blob path returns `404`, so `imagetools` is the reliable
route. Note the unauthenticated GitHub API budget is 60 requests/hour; prefer
`git ls-remote` for ref checks.
