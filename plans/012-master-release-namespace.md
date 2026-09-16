# 012 — Master Release: JZKK720 upstream + GHCR namespace

Priority: **P1** · Effort: **S** (path A) / **M** (path B) · Depends on: 011
Status: **RESOLVED — namespace pinned, dual publish implemented, credential gap closed**

## Resolution (supersedes the "awaiting owner decision" status)

Both namespaces are legitimate, and the question was never which one to pick:

- `jzkk720` is the **upstream/developer** account — repo origin, and the
  namespace holding the pre-release images the live AIPCs are running today
  (`deer-flow-pacgate:0.1.0`, `pacgate-api:0.1.2`).
- `pacgate-ai` is the **client-delivery** account — the fork, and what every
  compose file pins.

So a release populates both. `GHCR_NAMESPACE: pacgate-ai` is the committed
source of truth, and a non-blocking `mirror-upstream` job retags the same bytes
into `jzkk720` with `docker buildx imagetools create`.

Three things the original analysis missed:

1. **The mirror must RETAG, not rebuild.** Docker builds are not reproducible —
   layer tar entries carry mtimes — so rebuilding identical source yields a
   different digest. Retagging is the only way to guarantee the mirror is the
   same bytes as the client image.
2. **`secrets.GITHUB_TOKEN` cannot cross namespaces.** It is issued per
   repository and can only push to its own owner's namespace, so no amount of
   workflow restructuring makes the automatic token reach the other account.
   Both cross-namespace paths need their own PAT: `GHCR_MIRROR_PAT` for the
   mirror, `GHCR_CLIENT_PAT` (optional) for the build job.
3. **The build job had the same gap.** Once the namespace is pinned rather than
   inferred, a run started from the upstream repo tries to push into a namespace
   its own token does not own, and dies on a bare 403. It now picks the
   credential, warns in advance when the token provably cannot reach the target,
   and treats a failed login as a hard stop so an empty release can never look
   like a successful one.

`scripts/test-workflow-mutations.ps1` breaks the workflow on purpose — one
property at a time — and requires the suite to notice by name. It exists because
three checks in this work turned out to be unfalsifiable, and a check that
cannot fail is worse than no check: it reports as coverage.

### Remaining manual steps (outside the repo)

- Add `GHCR_MIRROR_PAT` (write:packages for `jzkk720`) as a fork secret, or the
  mirror skips with a warning. `GHCR_CLIENT_PAT` is only needed for a
  cross-namespace build.
- New GHCR packages default to **private** on first push. Flip the mirrored
  packages to public in the UI; a private mirror has no other symptom than a
  failed anonymous pull.

## State at time of writing (historical)

- `origin/main` (`JZKK720`) and fork `main` (`pacgate-ai`) have **identical trees**
  (`1fd4531`). `origin/main` is *ahead* by the merge commit `832d84e`.
- **There is nothing left to merge.** `git log origin/main..forkmain` is empty.
- All four `pacgate-ai/*` images are publicly pullable (200).
- `jzkk720/*` holds only the old `pacgate-api:0.1.2`. The other three were never
  published there.

## The merge question, resolved

`origin/main` already contains every fork commit plus the PR #1 merge. The
"behind by 66" reading came from a stale local clone, which has been
fast-forwarded. **No further merge action is required.**

## The real blocker: namespace ownership

`.github/workflows/build-ghcr.yml` derives its publish target from the repo that
runs it:

```yaml
IMAGE_PREFIX: ghcr.io/${{ github.repository_owner }}
password: ${{ secrets.GITHUB_TOKEN }}
```

`secrets.GITHUB_TOKEN` is issued **per repo** and can only push to that repo's
own namespace. Consequently:

| Tag pushed to | Publishes to | Compose pins | Result |
| --- | --- | --- | --- |
| `pacgate-ai/pacgate-ai-pr` | `ghcr.io/pacgate-ai/*` | `ghcr.io/pacgate-ai/*` | works today |
| `JZKK720/pacgate-ai-pr` | `ghcr.io/jzkk720/*` | `ghcr.io/pacgate-ai/*` | publishes where nothing looks |

Note `pacgate-ai` is a **User account, not an organization**.

## Fixed already (both paths benefit)

`build-ghcr.yml`:

1. **Verify step `Accept` header.** The step requested a manifest without the
   OCI/Docker `Accept` header. GHCR answers `404` to such a request even for a
   public package, so **every run failed on a fully successful release** (7/7).
   Confirmed by reproduction: 404 without the header, 200 with it.
2. **Namespace parameterized.** New `namespace` dispatch input, resolved in an
   explicit `Resolve image namespace` step. All 9 prefix references now use
   `steps.ns.outputs.prefix`, so either owner works with no manual edit.
3. **No stale default.** Removed `workflow_dispatch.default: "0.1.3"`; `tag` is
   now required with no default, so a stale tag cannot be dispatched by accident.
4. **Tag guard.** An empty resolved tag now fails loudly instead of producing a
   malformed image reference.
5. **Provenance labels.** All four builds now set
   `org.opencontainers.image.{source,revision,version}` so a published image can
   be traced to the commit that built it. Previously the only revision label was
   inherited from the bytedance base image, which was misleading.
6. **Diagnosable verify failures.** A failure now distinguishes `404` (namespace
   mismatch / tag absent) from `401` (package still private) and says which
   compose file to check.

Validated: YAML parses; step order correct; namespace resolution simulated for
origin tag-push, fork tag-push, and dispatch override; tag guard fires on empty.

## Choose ONE path

> **Which is unblocked today?** Path **A**, and it needs no git credentials.
> Path B still requires flipping four packages public by hand, and the fork's
> `git push` is currently denied (see `plans/013`). If you want the release out
> now, take A.

### Path A — keep publishing to `pacgate-ai/*`

Least churn. JZKK720 remains a mirror; the fork stays the publisher.

**Prerequisite:** the fork must first be synced to `origin/main`, so it carries
the workflow fix and the credential redaction. One click in the browser, by an
account with write access to the fork (no git credential needed):

```text
https://github.com/pacgate-ai/pacgate-ai-pr  ->  Sync fork  ->  Update branch
```

That is a clean fast-forward — GitHub's compare view states *"Able to merge"*,
and the fork is a strict ancestor of `origin/main` holding nothing origin lacks.

Then release. `git push` of a tag needs the same fork credential that is
currently missing, so prefer the browser route:

**Option A1 — Actions → Run workflow (no git credentials)**

```text
https://github.com/pacgate-ai/pacgate-ai-pr/actions/workflows/build-ghcr.yml
  ->  Run workflow
      tag       = 0.1.12
      namespace = (leave empty -> resolves to pacgate-ai)
```

**Option A2 — push a tag (needs fork write access)**

```powershell
git tag v0.1.12
git push https://github.com/pacgate-ai/pacgate-ai-pr.git v0.1.12
```

Either way, no compose changes: the pins already read `ghcr.io/pacgate-ai/*`.

Note the workflow tags **all four** images with the same tag, so a unified
`0.1.12` also resolves the current three-way pin split (`0.1.9` / `0.1.10` /
`0.1.11`).

### Path B — move the master to `jzkk720/*`

Makes JZKK720 the true source of truth. **Order matters** — do not repin before
the packages exist, or client installs break.

1. Build first, from origin:

   ```powershell
   git tag v0.1.12
   git push origin v0.1.12
   ```

   The workflow resolves the namespace to `jzkk720` automatically.

2. **Flip the four new packages to public by hand.** `GET /users/JZKK720/packages`
   works, but the `PATCH …/visibility` endpoint 404s for personal-account
   packages even with `write:packages` — visibility is UI-only. In the GitHub UI:
   profile → Packages → each of `pacgate-api`, `pacgate-mcp`,
   `deer-flow-pacgate`, `deer-flow-frontend-pacgate` → Package settings → Public.

3. Verify anonymous pulls are 200 (must all be 200 before the next step):

   ```powershell
   .\scripts\check-ghcr-pull.ps1 -Targets `
     "jzkk720/pacgate-api:0.1.12","jzkk720/pacgate-mcp:0.1.12", `
     "jzkk720/deer-flow-pacgate:0.1.12","jzkk720/deer-flow-frontend-pacgate:0.1.12"
   ```

4. **Only then** repin compose — 8 pins across 2 files:

   - `deploy/client-bundle/compose.prod.yaml`
   - `deploy/client-bundle/compose.bundle.yaml`

5. Sweep the remaining references (about 26 occurrences of `jzkk720` /
   `ghcr.io/jzkk720/*`): both `AIPC-DEPLOYMENT-HANDBOOK*.md`, both
   `AIPC2-HANDOFF-PROMPT*.md`, `DEPLOYMENT-GUIDE.md`, `PLANS.md`,
   `build-frontend.ps1`, `deer-flow-frontend-pacgate/Dockerfile`,
   `handbooks/qm-openviking-pacgate-handbook.zh.md` (client-facing),
   `ARCHITECTURE-DIAGRAMS.md`, `README-BUILD.md`, `plans/001-client-bundle.md`.

6. Re-verify a fresh clone install, per the standing fresh-clone rule.

### Path C — `pacgate-ai/*` driven from origin (not recommended)

Requires a cross-account PAT with `write:packages` for `pacgate-ai`, stored as a
secret on origin. This adds a long-lived credential immediately after a
credential leak was found in this repo (see `deploy/PLAN-CORPUS-AUDIT.md` §2).
Prefer A or B.

## Independent of the path choice

Either way, a trustworthy release still needs plan 011's two remaining steps:
unify the version across the six pin files (currently split `0.1.9` / `0.1.10` /
`0.1.11`), and build from near-HEAD so the release carries `ece697f`
(`.docx` conversion) and `150db2c` (`hnsw` index).

## Definition of done

- `build-ghcr` run is **green**, verify step included (first ever green run).
- All four images in the chosen namespace return `200` anonymously.
- Compose pins and workflow namespace agree.
- Image `org.opencontainers.image.revision` matches the tagged commit.
