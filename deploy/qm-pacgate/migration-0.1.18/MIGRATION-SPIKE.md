# qm 0.1.4 → 0.1.18 migration spike: what is proven, what is not

**Date:** 2026-11-23
**Status:** config and sandbox layer PROVEN against 0.1.18. Runtime not yet exercised.
**Nothing here is applied to the live deployment.** `deploy/qm-pacgate/` still pins 0.1.4.

## Why this artifact exists

The upgrade was repeatedly described as "a release, not a bump" without anyone testing
whether that claim was true. This spike tests it. The answer is more favourable than the
verdict documents implied, and it found one blocker those documents did not name.

## 1. Is a rebuild required?

**No.** Verified in `deploy/qm-pacgate/compose.qm.yaml`: there are **zero `build:` blocks**
and all five qm images are `image: ghcr.io/yc-software/qm/...@sha256:...` pulls. We have
never compiled qm. The only local build is `sandbox-local/`, whose Dockerfile is
`FROM ghcr.io/jzkk720/pacgate-sandboxes@sha256:…` plus one `COPY` of a 3 KB script — it
does not touch qm.

So the upgrade is **not a rebuild and not a fork**. It is: pull different digests, change
the config, delete the patches.

## 2. Config migration — PROVEN

Our 5-service config (`core, web-ui, portal, auth, admin`) is rejected by 0.1.18:

```
error: qm.config.jsonc: unknown service "web-ui" — valid: core, egress-proxy, slack, auth
```

The migrated config in this directory is accepted:

```
$ npx --yes @yc-software/qm@0.1.18 check
· sandbox: sandbox/
     tools : firecrawl-qm (executable), pacgate-qm (executable)
     skills: firecrawl-web, pacgate-workflow, pacgate-workflow-reference
· sign-in email: disabled; use qm admin-login for administrator access
✓ check passed — config, sandbox layer, and plugins are valid.
```

What changed and why:

| Our 0.1.4 config | 0.1.18 | Reason |
| --- | --- | --- |
| `services: [core, web-ui, portal, auth, admin]` | `services: [core, auth]` | `core` now serves the browser UI and the sign-in front door; `portal`/`web-ui`/`admin` are not services |
| `publicUrl: http://localhost:8181` | `http://localhost:8180` | the old value pointed at the *portal* (basePort+1); with portal gone, core is the front door. Kept in the 8180 range so qm still cannot collide with Pacgate's 8089/1933 |
| `"HARNESS": "pi"` | removed | harness selection was removed; the agent runtime lives inside core |
| `"MODEL_BASE_URL"` | `"OPENAI_BASE_URL"` | renamed in `provider-endpoints.ts` (`PROVIDER_BASE_URL_ENV.openai`) |
| `PI_MODEL`, `PI_DETECT/TITLE/JUDGE_MODEL` | unchanged | still read (14 refs) |
| whole `"sandbox"` block | deleted | `sandbox.image` retired at 0.1.10; `qm sandbox publish` gone; layer is now a bind mount |
| — | `"QM_CORE_CONTAINER": "qm-pacgate-core"` | **new, and it is what replaces our `local-sandbox.ts` patch** (see §4) |
| 13 email env vars | `AUTH_EMAIL_TRANSPORT` only | see §3 |

### 3. The email path shrinks to one required key

Tested by removal rather than assumed:

- Removing `SMTP_*`, `AUTH_EMAIL_FROM`, `RESEND_API_KEY` keeps `check` green — they are now
  **optional secrets**.
- Removing `AUTH_EMAIL_TRANSPORT` **fails**: `env.auth.AUTH_EMAIL_TRANSPORT must be
  "resend" or "smtp"`. It is required unconditionally even though `sign-in email: disabled`
  is the default and `qm admin-login` is the admin path.

So the honest claim is: **we delete the Mailpit container, the SMTP wiring and 13 `.env`
variables, but we keep one vestigial `AUTH_EMAIL_TRANSPORT` key.** Saying "delete the whole
email path" would have been wrong.

## 4. Both source patches are obsolete — but only one is confirmed obsolete

- **`local-sandbox.ts`** (26 KB): DELETE. 0.1.4 has **zero** references to
  `QM_CORE_CONTAINER`; 0.1.18 reads it in `localSandboxEnv` and implements the full
  lifecycle — DNS-name reach (`local-sandbox.ts:168`), `docker network connect` to attach
  core to the sandbox network, and skipping the loopback port publish when it is set. That
  is upstream issue #271 (fix PR #1675), landed. The config now expresses the same intent
  as one key.
- **`pi-models.ts`** (12 KB, 309 lines): expected deletable — the Ollama bridge is native
  via `OPENAI_BASE_URL` and the default model is runtime-configurable per scope
  (`baseModel`). **Not proven in this spike**: the file has diverged badly (491 lines
  upstream; our copy exports `HARNESS_IDS`, which no longer exists), so deleting it is a
  behaviour change that needs a live agent turn to confirm.

## 5. The blocker `check` does NOT catch: a stale sandbox base image

`qm check` passed with our existing `sandbox/Dockerfile` even though it builds from the
WRONG base:

| | digest |
| --- | --- |
| our `sandbox/Dockerfile` `FROM` | `52cb44a6e9d166da20638c8ce55e3f423384f5557eba49915684cb8ed16e5873` |
| 0.1.18 `manifest.json` `sandboxBase` | `56eae68622f9bd8efedae4a1511b322213cc1023712ed5899e3d94a5791bed0d` |

Both resolve on GHCR (`docker manifest inspect` exits 0), so this fails silently: the
build succeeds and produces a layer on the **old** base. This is the stale-literal defect
class this repo keeps re-learning, and it is a reason to treat `check` passing as
necessary-but-not-sufficient.

**Proved, not assumed.** Mutating our `sandbox/Dockerfile` to build from
`sandbox-base@sha256:0000…0000` (all zeros, guaranteed nonexistent) still yields:

```
✓ check passed — config, sandbox layer, and plugins are valid.
exit 0
```

`qm check` does not read the `FROM` line at all. The wrong base only surfaces at build or
first agent execution.

**Required action on upgrade:** repin `sandbox/Dockerfile` to the `sandboxBase` digest from
the new package's `manifest.json`.

## 6. What is still unproven

1. **A live agent turn** on 0.1.18 with our tools — `pacgate-qm` and `firecrawl-qm` must
   actually execute, not merely be listed by `check`.
2. **`pi-models.ts` deletion** — needs that same live turn to confirm the native Ollama
   path behaves as our patch does.
3. **`sandbox-base` repin** — the digests differ; the new one resolves, but no build has
   been run against it.
4. **The client install path** — `setup-qm.ps1` and a fresh-clone install, which is the only
   valid test for install-path changes.
5. **Handbooks** — both still describe the 5-service topology.

## 7. Verdict

The upgrade is **smaller than the verdict documents implied**: no rebuild, no fork, a
migrated config that already passes `check`, and our sandbox layer accepted unchanged. It
is still not a version bump, because `check` alone does not prove the agent runs, and one
blocker (the base-image digest) is invisible to it.

Recommended order, cheapest-risk first:

1. repin `sandbox/Dockerfile` to `sandboxBase` `56eae686…` and build it
2. bring the migrated config up in a scratch directory and run one agent turn
3. only then delete `pi-models.ts` and confirm the native path
4. then the client bundle, handbooks, and a fresh-clone install
