# AIPC Update Gap Analysis — 2026-09-16

**End-goal:** both AIPCs pick up upstream repo + GHCR updates and run a fully
functional runtime **without a developer logging into each machine** for updates,
debugging, or fixes.

**Verdict: the end-goal is NOT met.** The release work made the *images* current,
but the update *mechanism* cannot deliver them unattended. Today an update
requires a human on each machine, and several classes of fix never arrive at all.

Evidence below is measured from the repo, not assumed.

---

## 1. What the documented update actually does

`deploy/AIPC-DEPLOYMENT-HANDBOOK.md` §"Update to a new version":

```powershell
cd C:\pacgate-ai-pr
git pull
cd deploy\client-bundle
.\install.ps1 -Update
```

`install.ps1 -Update` performs exactly three things:

| Step | Action |
| --- | --- |
| 1 | `docker compose pull` |
| 2 | `docker compose up -d` |
| 3 | `docker exec pacgate-nginx nginx -s reload` |

**It never runs `git pull`.** That is a separate manual step the operator must
remember — and the handbook is the only place it is written down.

---

## 2. Coverage table — what actually reaches a running machine

Measured by `scripts/audit-aipc-update-coverage.ps1` across all 16 bind mounts in
`compose.prod.yaml`.

| Component | Mechanism | Unattended? |
| --- | --- | --- |
| GHCR images (4) | `pull` + `up -d` recreates on image change | **Yes** |
| `nginx/default.conf` | explicit `nginx -s reload` in install.ps1 | **Yes** |
| `workflows/*.yaml` (15) | bind-mounted `:ro`, read per request | **Yes** |
| **8 Python patches** | bind-mounted, but process imports at start | **No — needs restart** |
| `deer-flow-config.yaml` | bind-mounted | **No — needs restart** |
| `deer-flow-extensions-config.json` | **rendered only if absent** | **No — updates never land** |
| **qm stack (7 containers)** | not referenced by install.ps1 at all | **No** |
| **qm sandbox image** | `localhost:5000/...`, machine-local | **No — cannot be pulled** |
| **the repo itself** | install.ps1 never pulls | **No — manual** |

**9 of 16 bind mounts require a human action to take effect.**

---

## 3. Three concrete defects, not hypotheticals

### 3a. A silent, high-impact lost update (proven)

The extensions config is rendered **only when the file does not exist**:

```powershell
if ((Test-Path $dfTemplate) -and -not (Test-Path $dfRendered)) { ... }
```

Commit `453646f` changed the **template** in two ways:

```diff
-        "X-API-Key": "${OPENVIKING_API_KEY}"
+        "X-API-Key": "${OPENVIKING_ROOT_API_KEY}"
+    "pacgate": {
+      "enabled": true, "type": "http", "url": "http://pacgate-mcp:8000/mcp",
```

That added the `pacgate-mcp` server (so the agent can query legal databases) and
fixed the OpenViking API key. Any machine that had **already rendered** its
config kept the old file — so it silently kept the broken key and never gained
`pacgate-mcp`.

This is not an oversight in the installer; it is the natural consequence of
render-once. The template then changed **three more times** (`ea27163`,
`cb0f5b7`, `f510487`) with the same failure mode.

### 3b. Python patches need a restart the update path does not perform

Eight `patches/*.py` files are bind-mounted over modules inside the container:
gateway routers, the lead agent, the run worker, the sync tool, and a
site-packages module.

A bind-mounted **file** change does not alter compose config, so `up -d` does
**not** recreate the container. Python imports modules at process start and does
not hot-reload. A patch fix therefore sits on disk and does nothing until
something restarts deer-flow — which `-Update` never does.

### 3c. No staleness detection exists

There is no version endpoint, build marker, or image-digest check exposed to the
machine. A machine cannot tell whether it is current, so nothing can be polled or
alerted on. Combined with (3a) and (3b), a machine can be **silently behind
indefinitely** and look healthy.

---

## 4. Why the release work did not close this

The 0.1.12 release fixed the *artifact*: images now build green and carry the
`.docx` and search fixes. That is necessary but not sufficient. The remaining gap
is in **delivery**:

- images update — but only if a human runs the update
- compose/pins/patches update — but only if a human runs `git pull` **first**
- patches then need a restart the script does not do
- the rendered config never updates at all
- qm is entirely outside the loop
- nothing detects staleness

**A developer still has to log into each machine.** The end-goal is unmet.

---

## 5. What "done" would require

Ordered by value per unit of effort.

1. **Make `install.ps1 -Update` actually update the repo.** Pull the repo itself
   (or verify the checkout is current) before pulling images. Removes the most
   commonly forgotten step.
2. **Re-render the config from the template on every update.** Replace
   render-if-absent with render-and-compare: regenerate from the template and
   only warn if a local edit would be lost. Fixes 3a permanently.
3. **Restart what a restart is needed for.** Add explicit
   `docker compose restart deer-flow` (and any other patched service) to
   `-Update`, so bind-mounted code changes take effect.
4. **Include qm in the update path.** `setup-qm.ps1` already builds the sandbox
   and `compose.qm.yaml` pins digests; `-Update` should cover it, or at minimum
   detect and report qm drift.
5. **Publish a version/staleness marker.** Expose the running image tag (e.g.
   nginx `/version`) so a machine — or a monitor — can tell whether it is
   current.
6. **Add a scheduled updater.** Once 1–3 are safe and idempotent, a Windows
   scheduled task running `-Update` on a cadence removes the human entirely.
   **Sequence this last**: automating a currently-lossy update would propagate
   the silent-failure modes above at machine speed.

---

## 6. Honest position on the current state

| Question | Answer |
| --- | --- |
| Are the images current and correct? | **Yes** — 0.1.12 is live, public, verified carrying both fixes |
| Can an AIPC pull them unattended? | **No** — a human must run the update |
| Would a human-per-machine update deliver everything? | **Not reliably** — patches need a restart, the config never re-renders, qm is excluded |
| Can anyone tell if a machine is stale? | **No** — no marker exists |
| Is the end-goal met? | **No** |

The release was necessary progress. It is not the end-goal, and the gap between
them is the six items in §5.

---

## Appendix — tooling

- `scripts/audit-aipc-update-coverage.ps1` — read-only; classifies every bind
  mount by whether it reaches a running machine unattended.
