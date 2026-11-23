# qm upstream 0.1.4 → 0.1.19: verified verdict

**Date:** 2026-10-05, **revised 2026-11-23**
**Pinned:** `@yc-software/qm` 0.1.4 (running: `qm-pacgate-core` `bee03e7f2271`)
**Upstream:** latest **stable** v0.1.18 (2026-11-11). v0.1.19 is a GitHub *prerelease*;
**there is no v1** (§11.1). npm `dist-tags`: `latest` = 0.1.18, `next` = 0.1.19.
**Verdict: it is not a version bump, and a pin cannot make it one (§10). But the upgrade is
now worth planning: it removes BOTH source patches and fixes the team's sign-in pain (§11).**

Everything below was measured, not read from a changelog. Upstream publishes no
changelog, so each claim names the command that produced it.

**Read §10 and §11 first if you are asking "why can't we just pin to upstream?" or "why is
0.1.4 so hard to use?"** They contain the two answers, including one correction (§11.5) to
my own first reading of the sandbox patch.

---

## 1. Why this is not a bump

`qm check` against our unmodified `qm.config.jsonc`:

| Version | Result |
| --- | --- |
| 0.1.4 (pinned) | `check passed` |
| 0.1.6 – **0.1.15** | `check passed` |
| **0.1.16** | `error: unknown service "admin"` |
| **0.1.17 – 0.1.19** | `error: unknown service "web-ui"` |

The last release with an unbroken config surface is **0.1.15**; 0.1.16 is the
first hard failure. But `check` is not the whole contract — §9.1 shows it goes
silently wrong from **0.1.10**. The last *correct* release is **0.1.9**.

## 2. The topology collapsed 5 services → 2

From `manifest.json` inside the 0.1.19 package and
`dist/src/services.js`:

```js
export const SERVICE_NAMES = ["core", "egress-proxy"];
export const VIRTUAL_SERVICE_NAMES = ["slack", "auth"];
```

| We run | 0.1.19 | Fate |
| --- | --- | --- |
| `core` | `core` | kept, greatly enlarged |
| `auth` | `auth` | kept (virtual, runs inside core) |
| `web-ui` | — | folded into core: `/app/plugins/web-ui/dist-web` is a **prebuilt bundle baked into the image** |
| `portal` | — | removed as a service |
| `admin` | — | removed as a service |
| — | `egress-proxy` | **new** |
| — | `sandbox-base` | **new** image (`ghcr.io/yc-software/qm/sandbox-base`) |

`contract` is **still 1**. That number no longer describes the topology, which is
exactly why `check` fails on service names rather than a contract bump — a
migration cannot be detected from the contract value.

## 3. The harness moved inside core

The `pi` harness is no longer a selectable runtime. In the 0.1.19 core image:

| Token | Pinned 0.1.4 | 0.1.19 |
| --- | --- | --- |
| `HARNESS` | 43 | **4** (all `HARNESS_SECURITY_POSTURE` / `HARNESS_SHARING_POSTURE`) |
| `MODEL_BASE_URL` | 1 | **0** |
| `PI_MODEL` | — | 14 (still wired) |
| `opencode` | — | **453** |

`env.core.HARNESS` is gone, and with it `MODEL_PROVIDER_HARNESSES`
(`anthropic: [pi, opencode, claude, mock]`, …) that used to reject a
provider/harness mismatch. Agent execution is now `/app/src/agent` +
`/app/src/sandbox` inside core. `opencode` at 453 references is the agent
runtime that replaced the `pi` harness.

Measured with:
`docker run --rm --entrypoint sh <core-image> -c "grep -ro 'TOKEN' /app | wc -l"`

## 4. The Ollama bridge survives — under a new name

`MODEL_BASE_URL` is gone, but the capability is not:

```ts
// /app/src/model/provider-endpoints.ts
const PROVIDER_BASE_URL_ENV: Record<ModelProvider, string> = {
  anthropic: "ANTHROPIC_BASE_URL",
  openai: "OPENAI_BASE_URL",
  openrouter: "OPENROUTER_BASE_URL",
};
```

So `"MODEL_BASE_URL": "http://host.docker.internal:11434/v1"` becomes
`"OPENAI_BASE_URL": "http://host.docker.internal:11434/v1"`. `parseProviderBaseUrl`
accepts `http(s)`, strips trailing slashes, and rejects credentials/query/fragment —
our value passes. qm does not care that the endpoint is Ollama rather than OpenAI;
only `modelProvider: "openai"` and `PI_MODEL` matter, and both still work.

**This is the one piece of our config that needs no redesign, only a rename.**

## 5. The sandbox architecture changed

`config.js:1357` now warns:

> `"sandbox.image" is retired and ignored — sandboxes boot the platform's stock image; remove the key`

and `doctor.js:130` reports `sandbox: sprites boot the platform's stock image`.
`qm sandbox publish` no longer exists.

Our `qm.config.jsonc` pins
`sandbox.image = ghcr.io/jzkk720/pacgate-sandboxes@sha256:…`, and
`deploy/DEFECT-qm-sandbox-image-unobtainable.md` plus the REPINNED 2026-10-04
comment in the config exist purely to keep that image resolvable for clients.

**Upgrading deletes the reason that entire defect and its pin exist.** The
replacement is a bind-mounted layer (`DEPLOYMENT_LAYER=/layer`,
`existingLayerSubdirs()` mounts `sandbox/<sub>:/layer/<sub>:ro`), i.e. our
`sandbox/` directory is mounted into the stock image rather than built into a
published one. That is arguably better for the client-install story — the whole
GHCR-visibility problem for `pacgate-sandboxes` evaporates — but it is a
different deployment model that must be re-proven end to end.

## 6. The open MCP question is now answered — and it inverts

Previously recorded as "the highest-value unknown". It is closed:

- **0.1.4 (what we run):** the npm CLI has zero `mcp` references; the *core
  image* has some. Our agents cannot be given MCP servers declaratively.
- **0.1.19:** MCP is a **first-class admin feature**.
  - `/app/src/mcp/mcp-server-store.ts` — persistent server store
  - `/app/src/api/routes/admin/mcp-servers.ts` — admin CRUD, 283 lines, with
    `AUTH_MODES = ["none","bearer","client-credentials","oauth-user"]`,
    `APPROVAL_POLICIES = ["annotations","all","none"]`, OAuth discovery and
    dynamic client registration
  - `/app/src/mcp/oauth-discovery.ts`
  - `mcpServers` appears 172× in the image

So qm gains the ability to call pacgate-mcp as an MCP server. It is configured
**at runtime through the admin API**, not in `qm.config.jsonc` — the config file
still has no `mcp` key.

## 7. Images are public and client-pullable

All three 0.1.19 images resolve anonymously:

```
qm/core          -> EXISTS (public, pullable)
qm/egress-proxy  -> EXISTS (public, pullable)
qm/sandbox-base  -> EXISTS (public, pullable)
```

Verified with `docker manifest inspect`. Note that a hand-rolled
`curl` to the GHCR `/v2/…/manifests/…` endpoint returned 404 **even for the
image we are running today**, so that probe is unusable on this account —
`docker manifest inspect` is the reliable check.

---

## 8. What an upgrade actually costs

Not a version bump. A re-architecture with these work items:

1. **`qm.config.jsonc`** — `services` → `["core", "auth"]` (+ `egress-proxy` if we
   want the egress control plane); delete the `portal`/`web-ui`/`admin` env
   blocks; delete `sandbox.image`; rename `MODEL_BASE_URL` → `OPENAI_BASE_URL`;
   drop `HARNESS`.
2. **`compose.qm.yaml` (both copies)** — 5 image refs → 2, plus `egress-proxy`;
   every healthcheck, dependency, network and port mapping re-derived. `web-ui`
   `:3000`, `portal`, `admin` ports disappear; core serves the UI from
   `/app/plugins/web-ui/dist-web`.
3. **Secrets set shrinks** — `AUTH_EMAIL_FROM`, `SMTP_HOST`, `SMTP_PASSWORD`,
   `SMTP_USERNAME` move to *optional* (sign-in email is `disabled` by default;
   `qm admin-login` replaces the one-time-link flow). The Mailpit catcher and
   the `AUTH_EMAIL_TRANSPORT=smtp` wiring go away.
4. **Sandbox delivery re-proof** — `sandbox/` is now a mounted layer. Must
   re-verify that `pacgate-qm` and `firecrawl-qm` tools and the three skills
   still load, and that `sandbox.sourceFingerprint` is still meaningful.
5. **Client bundle** — `deploy/client-bundle/qm-pacgate/compose.qm.yaml` and the
   handbooks (`deploy/handbooks/qm-openviking-pacgate-handbook.zh.md`) all
   describe the 5-service topology and must be rewritten together, bilingual.
6. **`DEFECT-qm-sandbox-image-unobtainable.md`** becomes obsolete — archive it
   with a pointer to this document rather than silently deleting it.
7. **Re-run the whole gate set** — `qm check`, `test-stack-version-coherence.ps1`,
   smoke, post-deploy audit — plus a fresh-clone install test, because the
   client path is what actually changes.

## 9. Recommendation

**Stay on 0.1.15 at most; do not go to 0.1.19 for this release.** Concretely:

- The only thing pulling us forward is the MCP admin surface (§6). That is a
  real capability we want, but it arrives attached to a topology rewrite that
  invalidates the client install path, the compose files, the handbooks and the
  sandbox-image workaround.
- 0.1.16–0.1.19 remove the sign-in email flow we deliberately built (Mailpit +
  SMTP + one-time links). That is a product decision for the firm, not a
  mechanical migration.
- Nothing we run today is broken. `qm check` passes on 0.1.4.

**If the firm decides the MCP reach is worth it**, take it as its own release
with its own plan: 0.1.4 → 0.1.19 in one step (there is no incremental path,
because 0.1.16 already breaks the config), behind a new bundle minor version,
with the client bundle re-proven from a fresh clone. Do not fold it into a
patch release.

### 9.1 The intermediate option does not exist

My first draft recommended "0.1.15, config-compatible, free bugfix pickup". That
was wrong, and bisecting the published packages shows why. Two **independent**
contract changes land at two different versions:

| Version | `sandbox.image` | services | `qm check` |
| --- | --- | --- | --- |
| 0.1.4 (pinned) | **honored** | 5 | pass |
| 0.1.9 | honored | 5 | pass |
| **0.1.10** | **retired & ignored** | 5 | pass |
| 0.1.15 | retired & ignored | 5 | pass |
| **0.1.16** | retired & ignored | **admin removed** | **fail** |

`qm check` passing at 0.1.15 is a **false green**. It passes because
`sandbox.image` became a *warning*, not an error — so `check` does not catch
that our published `pacgate-sandboxes` pin is now silently ignored and clients
would boot the stock image instead of ours. The `DEFECT-qm-sandbox-image-unobtainable`
workaround breaks at **0.1.10**, four releases before `check` starts complaining.

**No version above 0.1.9 preserves everything we depend on.** 0.1.4 → 0.1.9 is
the only safe window, and 0.1.9 is six releases behind head with no changelog to
say what it fixes. That is not worth a release either.

So: stay on **0.1.4** until the firm commits to the re-architecture.

## 10. Re-verification 2026-11-23: "why can we not upgrade even when pinned to upstream?"

The question assumes a pin is a compatibility guarantee. Verified against the published
packages, and the key point is that **we hold TWO independent pins, and only one of them
is the npm version this document is about.**

### 10.1 The two pins

| Pin | Where | What it controls |
| --- | --- | --- |
| **npm CLI** `@yc-software/qm` `0.1.4` | `deploy/qm-pacgate/package.json` + `package-lock.json` | the orchestrator (`check`/`plan`/`up`) **and, via `manifest.json` shipped inside the package, the image digests and the topology** |
| **runtime images** by **digest** | `deploy/qm-pacgate/compose.qm.yaml` | the five containers that actually run |

The npm pin is not decorative, which is worth stating explicitly because the running
images are digest-pinned. `manifest.json` inside `@yc-software/qm@0.1.19` is:

```json
{"services": {"core": "…@sha256:fd3482…", "egress-proxy": "…@sha256:008359…"}}
```

and on `0.1.4` the same file lists `core, web-ui, admin, portal, auth`. **The topology
lives in the CLI package.** `compose.qm.yaml`'s own header records that it "mirrors the
exact topology QM's own `qm up` produces" and that `qm up` "remain[s] the canonical
launcher". So bumping the npm pin does change what the stack is — that is precisely why
a pin cannot make an incompatible version compatible.

**A pin guarantees reproducibility, not compatibility.** It says "this exact artefact,
every time"; it cannot say "this artefact still understands our config, our topology or
our client install path."

### 10.2 The install path makes the incompatibility a hard stop

`deploy/client-bundle/setup-qm.ps1` runs `npm ci` (line 160) and then `qm check`
(lines 511, 724), and **aborts the install** on failure. So a version whose `qm check`
rejects our config does not merely warn on a maintainer's box — it stops a client
install. Measured on 0.1.19 against our unmodified `qm.config.jsonc`:

```
error: …\qm.config.jsonc: unknown service "web-ui" — valid: core, egress-proxy, slack, auth
```

### 10.3 The matrix, re-measured (not re-read)

Each row: install the CLI at that version, run `qm check` against our real config.

| Version | `qm check` | `sandbox.image` | sign-in email | services |
| --- | --- | --- | --- | --- |
| 0.1.4 (pinned) | pass | honored | active | 5 |
| 0.1.8 | pass | honored | **active** | 5 |
| **0.1.9** | pass | honored | **disabled** ← corrected | 5 |
| 0.1.10 – 0.1.15 | pass (false green) | **retired, warning only** | disabled | 5 |
| 0.1.16 | **fail** `unknown service "admin"` | ignored | disabled | 5 |
| 0.1.17 – 0.1.19 | **fail** `unknown service "web-ui"` | ignored | disabled | 2 |

### 10.4 One correction to §9.1

§9.1 attributed the sign-in-email flip (`disabled; use qm admin-login`) to **0.1.15**.
Bisected at 0.1.7 / 0.1.8 / 0.1.9: it lands at **0.1.9**, together with `sandbox.image`
still honored. That *narrows* the "safe window" from `0.1.4 → 0.1.9` to **`0.1.4 → 0.1.8`**
if the Mailpit + SMTP + one-time-link flow is a requirement.

It also means 0.1.9 is not an interesting upgrade on its own: it gains us nothing we use
and already removes the email flow. **The conclusion does not change — 0.1.4 stays — but
the reason is one release tighter than recorded.**

### 10.5 A trap in how the `sandbox.image` question is asked

Two probes give opposite answers, and only one is meaningful:

- **valid digest** (our real config): 0.1.10+ prints `"sandbox.image" is retired and
  ignored`, and `check` still **passes**. This is the false green §9.1 describes.
- **invalid tag**: `≤0.1.9` **rejects** it (`must be pinned by digest`), while `0.1.10+`
  says nothing at all. Confirms retirement happened at 0.1.10.

My first probe used an invalid tag on 0.1.9, saw a rejection, and appeared to contradict
§9.1. It did not: 0.1.9 validates a key it honors. Recorded because the same question
will be asked again, and the "silent on garbage" signal is the sharper test of retirement.

### 10.6 What would actually have to be true to upgrade

Not "pin a newer version". All of:

1. `qm.config.jsonc` rewritten: 5 services → `core` + `auth` (+ `egress-proxy`), delete
   `portal`/`web-ui`/`admin` blocks, drop `sandbox.image`, `MODEL_BASE_URL` →
   `OPENAI_BASE_URL`, drop `HARNESS`.
2. `compose.qm.yaml` (both copies) re-derived: 5 digest pins → 2, plus `egress-proxy`;
   every healthcheck, dependency, network and port mapping.
3. The sign-in email flow (Mailpit + SMTP + one-time links) replaced by `qm admin-login`
   — a **product decision for the firm**, since it removes a flow we built deliberately.
4. Sandbox delivery re-proven as a bind-mounted layer rather than a published image, and
   `DEFECT-qm-sandbox-image-unobtainable.md` archived.
5. Both handbooks rewritten bilingual, and the client bundle re-proven from a **fresh
   clone** (the only valid test for install-path changes).

That is a release, not a bump. `dist-tags` at time of measurement: `latest` = **0.1.18**,
`next` = **0.1.19** — so 0.1.19 is not even the stable channel.

---

## 11. 2026-11-23: "is there a v1, and why is 0.1.4 so hard for our team to use?"

### 11.1 There is no v1 — verified against the repo, not the registry alone

The earlier analysis read only npm. Checked the public repo directly:

| Source | Result |
| --- | --- |
| `repos/yc-software/qm/tags` | newest is `v0.1.19`; **no `v1.*` or `1.*` tag exists** |
| `releases` | newest is **v0.1.18** (stable, 2026-11-11); `v0.1.19` is `prerelease: true` |
| `npm dist-tags` | `latest` = 0.1.18, `next` = 0.1.19 |
| `package.json` on `main` | `"version": "0.1.0"` — the package's own field, not the release version |

So 0.1.18 *is* upstream's latest stable release. The claim of a v1 is not supported by the
repo. Note the repo is public and active (pushed 2026-11-23, PR numbers around #3820), so
this is a live project, not an abandoned one.

### 11.2 The usability complaint is real, and it is not about the version number

The earlier verdict answered a *compatibility* question and never addressed usability.
Reading our own handbook makes the friction concrete: **section 7 of
`deploy/handbooks/qm-openviking-pacgate-handbook.zh.md` is five entries and every one is a
workaround**, including a section titled "This sign-in link no longer works".

The dominant cause is structural: **we patch qm's source inside its image.** Verified in
`deploy/qm-pacgate/compose.qm.yaml`:

```
./patch/pi-models.ts:/app/src/model/pi-models.ts:ro
./patch/local-sandbox.ts:/app/src/sandbox/local-sandbox.ts:ro
./patch/docker-cli/docker:/usr/local/bin/docker:ro
```

Any team member who debugs qm is debugging a **modified build of a third-party product
with no upstream changelog**. That is the "very hard to use" experience, and it follows
from our patches, not from 0.1.4 being old.

### 11.3 The single highest-value usability fix needs an upgrade we cannot take

`qm admin-login [--email <admin-email>]` — "print a single-use admin login link, valid for
five minutes" — exists in **0.1.18 and 0.1.19** and does **not** exist in our pinned
**0.1.4** (checked via `qm --help` on each installed CLI). It removes the entire
magic-link path that our handbook documents as failing: no SMTP, no Mailpit, no
single-use-and-browser-bound JWT `st` claim to explain to a user.

What it would let us delete, measured in our own stack:

- the `qm-mailpit` container and its `8025` port
- `AUTH_EMAIL_TRANSPORT: smtp`, `SMTP_HOST/PORT/TLS/USERNAME/PASSWORD`, `AUTH_EMAIL_FROM`
- **13 of the variables in `.env.example`**

That is a large, user-visible simplification — and it is exactly the upgrade the topology
rewrite blocks.

### 11.4 Why the patches make the upgrade harder than the topology change alone

The two TypeScript patches are **whole-file replacements**, and upstream's files have
diverged far enough that they no longer patch cleanly:

| File | Our patch | Upstream 0.1.19 | Consequence |
| --- | --- | --- | --- |
| `pi-models.ts` | 309 lines | **491 lines** | our copy exports `HARNESS_IDS`, which **does not exist** in 0.1.19 (`grep -c` = 0); `DEFAULT_CODEX_MODEL_ID` moved `gpt-5.6-sol` → `gpt-6.1-sol` and five new exports appeared |
| `local-sandbox.ts` | — | **rewritten** (see 11.5) | our loopback workaround is now **upstream** — the patch should be deleted, not ported |

So an upgrade requires re-authoring `pi-models.ts` against a 491-line file **and**
rebuilding the topology, config, compose, handbooks and client bundle in the same change.
The patches are not a reason to stay on 0.1.4 — they are a multiplier on the cost of
leaving it.

### 11.5 Correction: the sandbox patch is obsolete upstream, and my first reading of it was wrong

§11.4's first draft said the loopback bug "is not fixed" because
`local-sandbox.ts:170` still contains `127.0.0.1:${await resolvePort(name)}`. **That was a
misreading.** The full line is a ternary:

```ts
const base = opts.coreContainer
  ? `http://${name}:${AGENT_PORT}${path}`      // container DNS - what we want
  : `http://127.0.0.1:${await resolvePort(name)}${path}`;
```

The loopback branch is only the fallback for when `coreContainer` is unset — which is
correct behaviour for a core that runs on the host. 0.1.19 has the whole `coreContainer`
implementation that our patch hand-rolls:

| Capability | Our 0.1.4 + patch | Upstream 0.1.19 |
| --- | --- | --- |
| Read `QM_CORE_CONTAINER` | **0 references** in the image | `sandbox-settings.ts:91` — `localSandboxEnv` reads it |
| Reach sandbox | patch resolves the **container IP** via `docker inspect` | **DNS name** `http://<name>:8080` (`local-sandbox.ts:168`) |
| Network attach | — | `docker network connect <net> <coreContainer>` (`:237`) with connect/disconnect lifecycle |
| Host port publish | patched | skipped when `coreContainer` is set (`:272`) |

This is upstream issue **#271** ("docker target assumes core runs on the host (five failure
modes)", open) with fix PR **#1675**, and the fix has landed in the shipped image.

**Consequence for the upgrade: delete `patch/local-sandbox.ts`, do not port it.** The
remaining patch (`pi-models.ts`) is the Ollama bridge, which 0.1.19 supports natively via
`OPENAI_BASE_URL` (§4) — so it too is likely deletable, making the upgrade
**patch-free**. That is the single strongest argument for taking it.

### 11.6 Where this leaves the decision

The honest framing is a fork, not a version choice:

- **Stay:** the team keeps a stack that works, with an admin experience we explain five
  ways (handbook §7), and two source patches to maintain.
- **Move:** one release-sized change that deletes the email path (13 env vars, Mailpit), the
  `sandbox.image` workaround, **both source patches**, and most of handbook §7 — paid for by
  re-authoring config, compose, both handbooks, and the client bundle.

**Recommendation, revised after 11.5.** The earlier "stay on 0.1.4" was correct as a
*compatibility* verdict but understated the value of moving. Three facts change the balance:

1. **The upgrade is patch-free.** `local-sandbox.ts` is obsolete upstream (§11.5) and
   `pi-models.ts`'s Ollama bridge is native via `OPENAI_BASE_URL` (§4). We would go from
   two whole-file source patches to zero — which is precisely the "hard to use" complaint.
2. **The sign-in pain has a real fix** that only exists in the newer versions:
   `qm admin-login` (§11.3).
3. **0.1.18 is the stable release** the team is being asked to use, and it is the same
   architecture as 0.1.19 (identical `core` digest), so 0.1.19's prerelease status is not a
   reason to avoid the family.

So the recommendation is now: **take the upgrade as its own planned release**, not because
0.1.4 is unsafe but because staying costs the team permanent patched-source maintenance and
a broken-by-design login flow. Do not do it as a bump: `qm check` rejects the config and
`setup-qm.ps1` aborts the install (§10.2).

**Do this first, before any upgrade work:** confirm with upstream that `coreContainer`
fully replaces our patch by opening the sandbox path end-to-end on a scratch clone
(`pacgate-qm` + `firecrawl-qm` tools and the three skills must still load). The upstream
fix landed after our patch was written, and "the capability exists" is not the same as
"our usage still works".
