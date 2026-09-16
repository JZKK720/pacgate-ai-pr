# 011 — GHCR Master Release

Priority: **P1** · Effort: **M** · Depends on: 012 (namespace choice) · Status: **BLOCKED ON THE FORK CREDENTIAL**

Closes the two defects found in the 2026-09-15 audit
(`deploy/GHCR-MASTER-BUILD-AUDIT.md`) and produces the first GHCR release that
is both CI-verified and content-current with `main`.

## Current blocker (2026-09-16)

Step 1 is **done and pushed**. The release itself is blocked on **fork push
access**, not on the build:

- The workflow fix is on `main` (commits `48eb8c1`, `ae42ae0`), so a tag pushed
  to **`origin`** would now build and verify correctly — into `ghcr.io/jzkk720/*`.
- But the compose pins all read `ghcr.io/pacgate-ai/*`, and publishing there
  requires tagging the **fork**, which git cannot push to: the credential store
  holds `JZKK720` only. See `plans/013-credential-rotation.md` for the
  account-switch steps.

So the release is waiting on one of: the fork-push credential, or a decision to
move the pins to `jzkk720/*` (plan 012 path B).

## Re-verified 2026-09-16: the staleness is real

Both defects were re-confirmed by pulling the currently-pinned images:

| Image | Evidence | Status |
| --- | --- | --- |
| `pacgate-mcp:0.1.9` | `/app/requirements.txt` ships `markitdown>=0.1.5` with **no extras** | still broken — `pacgate_convert_document` fails on every `.docx` |
| `pacgate-api:0.1.9` | migration 002 uses **`ivfflat`**, `main` uses `hnsw` | still broken — newly-uploaded documents are not reliably searchable |

Both fixes (`ece697f`, `150db2c`) are in `main` and in **no published image**.
All four current pins do resolve publicly (HTTP 200), so the install works — it
just ships these two defects.

## Why

Every `build-ghcr` run has failed (7/7) — all four image builds succeed, but the
final verification step fails, so CI has never been a usable signal. Meanwhile
the published `pacgate-api` and `pacgate-mcp` images predate two client-visible
fixes.

## Decisions already settled — do not relitigate

- Publish under **`ghcr.io/pacgate-ai/*`**. Enforced by
  `IMAGE_PREFIX: ghcr.io/${{ github.repository_owner }}` plus the org's compose
  pins. Tagging `origin` (`JZKK720`) would build `ghcr.io/jzkk720/*`, which
  nothing references. **Superseded:** the namespace is now a settable input and
  the owner-choice is tracked in `plans/012-master-release-namespace.md` — read
  that first.
- Images are **public by design**; the on-site engineer installs them. Never add
  `docker login ghcr.io` to the client path.
- `origin/main`, fork `main`, and local HEAD all have **identical trees**
  (`1fd4531…`), and both fork feature branches are fully merged. The build is a
  true single source of truth — there is no other repo holding unreleased work.
- **The upstream merge is already complete.** `origin/main` contains every fork
  commit plus merge `832d84e`; `git log origin/main..forkmain` is empty. No
  further merge action is needed.

## Steps

### 1. Fix the verify step (unblocks a meaningful CI signal)

> **DONE 2026-09-15.** The `Accept` header, namespace parameterization, tag
> guard, provenance labels, and diagnosable failures are all implemented in
> `.github/workflows/build-ghcr.yml` and YAML-validated. See
> `plans/012-master-release-namespace.md` for what changed and the remaining
> namespace decision.

In `.github/workflows/build-ghcr.yml`, add the OCI manifest `Accept` header to
the manifest request (~line 131). GHCR returns `404` without it even on public
packages.

```yaml
code=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json" \
  -H "Authorization: Bearer $tok" \
  "https://ghcr.io/v2/${IMAGE_PREFIX#ghcr.io/}/${img}/manifests/${{ steps.tag.outputs.tag }}")
```

While here: refresh the stale `workflow_dispatch.default` (`"0.1.3"`) and add
OCI provenance labels so a published image can be traced to its commit:

```text
org.opencontainers.image.revision = ${{ github.sha }}
org.opencontainers.image.source   = ${{ github.server_url }}/${{ github.repository }}
org.opencontainers.image.version  = ${{ steps.tag.outputs.tag }}
```

**STOP** if the header alone does not turn the verify step green — that would
mean a package is genuinely private, and step 4 will need a visibility flip.

### 2. Choose ONE master version

Current pins are split three ways (`api`/`mcp` `0.1.9`, `deer-flow` `0.1.10`,
`frontend` `0.1.11`), but the workflow tags all four with a single tag. Pick the
next unified version — **`0.1.12`** is recommended (above every existing pin).

### 3. Bump every pin to that version

| File | What to change |
| --- | --- |
| `pacgate-ai/Cargo.toml` | `version` |
| `pacgate-ai/Cargo.lock` | pacgate crate versions |
| `deploy/client-bundle/compose.prod.yaml` | 4 image pins |
| `deploy/client-bundle/compose.bundle.yaml` | 4 image pins |
| `deploy/client-bundle/deer-flow-extensions-config.template.json` | version string |
| `deploy/client-bundle/patches/deer-flow-prompt.py` | version string |

Verify no stale pin survives:

```powershell
git grep -nE "0\.1\.(9|10|11)" -- deploy pacgate-ai
```

### 4. Build the master release

Push the tag **to the fork** (this is the actual trigger):

```powershell
git tag v0.1.12
git push https://github.com/pacgate-ai/pacgate-ai-pr.git v0.1.12
```

Or run the workflow manually with `tag = 0.1.12`. `origin` has zero runs of this
workflow — a tag there does nothing.

**STOP** if the new verify step fails. Distinguish "manifest absent" (`404` on a
tag that was never pushed) from "private" (`401`).

### 5. Prove the release locally, from a fresh clone

Per the standing fresh-clone rule — this dev box accumulates credentials, pulled
models, and rendered gitignored configs that mask fresh-clone failures.

```powershell
.\scripts\check-ghcr-pull.ps1 -Targets `
  "pacgate-ai/pacgate-api:0.1.12","pacgate-ai/pacgate-mcp:0.1.12", `
  "pacgate-ai/deer-flow-pacgate:0.1.12","pacgate-ai/deer-flow-frontend-pacgate:0.1.12"
```

Expect `HTTP 200` on all four, then confirm the two stale-image bugs are gone:

```powershell
# must show markitdown[docx,pptx,xlsx,pdf]
docker run --rm --entrypoint cat ghcr.io/pacgate-ai/pacgate-mcp:0.1.12 /app/requirements.txt

# must show USING hnsw (not ivfflat)
docker run --rm --entrypoint sh ghcr.io/pacgate-ai/pacgate-api:0.1.12 `
  -c "grep -iE 'hnsw|ivfflat' /app/migrations/002_rag_schema.sql"
```

### 6. Repin the client bundle and record

Confirm `install.ps1` and the handbooks reference the new tag, then log the
release in `plans/007-delivery-log.md`.

## Follow-ups (not blocking this release)

- **Decide the fate of `pacgate-ai/deer-flow@pacgate-layer`.** It is the only
  sibling fork carrying custom work, and it defines a competing all-in-one
  `deer-flow-pacgate` image (34 legal skills, `pacgate_config.py` routing +
  hard gates, `matters` router). It is **not** in our build and our published
  image was probed to confirm that (only `/app/adapters` + `/app/backend`).
  Evidence says it is superseded — it is 8 days older than our wrapper, pinned
  to an older officecli, and targets the deprecated `ghcr.io/jzkk720/*`
  namespace — but its routing/hard-gate middleware is not replicated anywhere
  else. Either port that middleware forward, or retire the branch explicitly so
  `deploy/AIPC2-HANDOFF-PROMPT-v2.md` stops pointing AIPC #2 at it. Two
  pipelines currently publish the same image name, so this also removes an
  ambiguity.
- **Correct the "pacgate-ai org" wording** in `deploy/README-BUILD.md` — it is a
  User account, not an organization.
- **Add `.dockerignore` files.** There are none anywhere, so `deer-flow-pacgate`
  uploads `pacgate-ai/target/`, `.git/`, and PDFs to the builder on every build.
- **Make the officecli fallback observable.** `f510487` uses
  `... && officecli --version || echo "WARNING: skipped" && rm -rf /tmp/*`,
  which in `sh` parses as `((A && B) || C) && D` — the `||` swallows a failed
  install. Intentional best-effort, but a presence check would make the
  degradation visible in the build log.
- **Fix the stale comment** in `deploy/build-frontend.ps1` (`ghcr.io/jzkk720/…`).
- **Confirm QM image sourcing.** `yc-software/qm/{core,auth,portal,web-ui}` are
  not anonymously readable (404). Verify how a clean AIPC obtains them.

## Definition of done

- `build-ghcr` run for `v0.1.12` is **green**, verify step included.
- All four `ghcr.io/pacgate-ai/*:0.1.12` tags return `200` anonymously.
- `pacgate-mcp:0.1.12` carries the markitdown extras; `pacgate-api:0.1.12`
  carries the `hnsw` index.
- Every pin in both compose files points at `0.1.12`.
- Release recorded in `plans/007-delivery-log.md`.
