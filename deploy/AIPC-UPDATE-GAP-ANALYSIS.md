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

---

## AIPC1 handoff (2026-10-30) - what was adopted, and what deliberately was not

The handoff arrived as a delta inventory plus nine verdict records. Each item was
re-verified against this tree and the live 0.2.7 container before any change. Four of
the nine did not survive that check, and adopting them would have shipped patches for
behaviour that is already correct.

| ID | Verdict | Outcome here |
|---|---|---|
| V-01 | MCP arguments never path-translated | **Adopted.** `deer-flow-mcp-args.py` + `test-mcp-argument-paths.ps1`. The handoff's root cause was right and was re-proved: without `InjectedToolArg`, `runtime` arrives as `None`, so a rewrite would silently no-op. |
| V-01b | - | **Found, not in the handoff.** The mounted adapter renames hyphens to underscores in the tool prefix, while `get_mcp_tools()` compared against the raw server key. Every hyphenated server lost session pooling and the result path conversion. Fixed in the same patch. |
| V-02 | `read_file` on a binary says use `pandoc` | **Rejected - already fixed upstream.** The live container returns the pandas/openpyxl hint. `git log -S pandoc` over `sandbox/tools.py` finds nothing; upstream fixed it in `6a4a30fa`. |
| V-03 | Recursion default was a hardcoded 100 | **Adopted.** The default now equals the ceiling. The existing gate asserted the 100 default as correct, so that assertion was flipped first and red-checked. Two independent floors (`channels/manager.py:51`, `client.py:218`) are recorded as known remaining gaps, not silently declared fixed. |
| V-04 | `officecli set` rejects the selector `get` accepts | **Adopted as a prompt fix, not a code fix.** officecli is an upstream binary and was not patched. The prompt no longer teaches a command the sandbox rejects, and documents `batch --input`. |
| V-05 | 14 skills declared tools that resolve to nothing | **Rejected - not applicable.** Upstream ships 3 seeded skills and all three deliberately declare no `allowed-tools`, with the measured reason in their headers. `test-skill-evolution.ps1` E5 already enforces this. |
| V-06 | `audit-model-tags.ps1` false positives | **Adopted.** Scoped to the `models:` block and registered in the gate list, which it never was - it was described in comments there but never invoked, which is why it reported clean while the Rust tier roster 404'd. |
| V-07 | The connector template wipes 27 connectors | **Adopted, and worse than reported.** The change report compared against a hardcoded three-name list, so removals beyond `firecrawl` were not even named. Measured on a fixture: 6 servers in, 3 out, 1 named. The render now merges and never removes. |
| V-08 | `thinking_enabled` defaults ON | **Adopted in source.** Build-time only: the frontend image ships compiled output and has no source mount, so this lands on the next image build. |
| V-09 | A local 0.2.8 was invented | **Nothing to do.** Confirmed: no `0.2.8` string exists in the tracked tree. Recorded so it is not repeated. |
| Part 3 | 5 of 6 playbook references are dangling | **Not applicable.** Upstream has no `playbooks/` and none of the three seeded skills references one. The dangling references live in AIPC1's 60-skill corpus, which lives in a different repo and must not be ported. |
| Part 4 | `OPERATOR.md` is tracked and public | **Corrected.** `git ls-files` returns nothing, `git check-ignore` matches, and both historical blobs carry `[REDACTED - see password manager]` with no live value. Credential status is owned by `plans/013-credential-rotation.md`. |

### Firecrawl: why it is NOT in the template, and what to do per machine

AIPC1 asked whether each machine needs its own Firecrawl key registered before the
connector ships. Two measured facts decide the shape:

1. **`firecrawl` is not in the template at all.** `deer-flow-extensions-config.template.json`
   carries exactly three servers (`openviking`, `pacgate`, `officecli`). `firecrawl`
   appeared only in the installer's hardcoded `$knownServers` list - which is why the
   old render named it and nothing else. Adding it now means writing a NEW connector
   entry, and the invocation form (`command`/`args`) is not recorded anywhere in this
   repo, because AIPC1's live config is gitignored. It is therefore not invented here.
2. **A failing MCP server takes every MCP tool with it.** The pinned 0.2.7 image has no
   per-server isolation: `get_mcp_tools()` awaits one `client.get_tools()` for all
   servers and its `except` handler logs and `return []`. So one `firecrawl` entry with
   an empty key does not degrade web search - it silently removes `pacgate`,
   `officecli` and every legal-database connector too.

Because of (2), the per-machine registration must be an **opt-in switch**, not an
enabled-by-default entry: ship the connector with `"enabled": false` and a
`${FIRECRAWL_API_KEY}` placeholder, and let the operator flip `enabled` to `true` on a
machine only after the key is in `.env`. The key store already exists - `setup-qm.ps1`
reads `FIRECRAWL_API_KEY` from the bundle's gitignored `.env`, which is the documented
single source - so no new secret mechanism is needed.

**Open action:** obtain AIPC1's exact firecrawl `command`/`args` and add the disabled
entry plus a gate assertion that every enabled server resolves to a non-empty key.
Until then, no machine should add an enabled firecrawl entry by hand: one wrong entry
is a total MCP outage, not a partial one.

### Deliberately not ported

The 60 skills and the `playbooks/` corpus live in `pacgate-ai/deer-flow` on branch
`pacgate-layer`, not here. The live `deer-flow-extensions-config.json` holds 27
legal-database credentials and is gitignored for that reason. Porting either would
leak credentials or fork a corpus that has its own repo.

### Open, not fixed by this change

- `app/channels/manager.py:51` and `deerflow/client.py:218` each hardcode
  `recursion_limit: 100` independently of `build_run_config`. The IM path routes
  through the gateway and is therefore clamped; a direct `deerflow.client` caller is not.
- The frontend thinking fix is inert until the next frontend image build.
- `compose.prod.yaml`'s seed-skills comment cites
  `sandbox/tools.py:validate_local_tool_path`, which does not exist in the pinned image
  (the real function is `validate_local_file_path`). The behaviour it describes is
  correct; the citation is wrong.
## 0.2.8 release verification (2026-10-30)

Tag `v0.2.8` = `b970466`. Workflow run 41058079927 on `v0.2.8` completed; all five
images are published and anonymously pullable (token `200` per package, which is the
check that matters - clients run `docker login` for nothing).

| Check | Result |
|---|---|
| `credential-guard` job (blocks the build) | success |
| all 5 images built and pushed | success |
| anonymous pull token, each package | 200 |
| stack up on `:0.2.8`, every service healthy | yes |
| `test-stack-version-coherence` | 14 passed |
| `test-baked-patch-parity` | 13 passed, **0 warnings** (drift resolved) |
| `test-thinking-default` incl. T5 (built image) | 12 passed |
| `test-mcp-argument-paths` | 21 passed |
| `test-document-generation-e2e` (live run) | 19 passed, 0 failed |

The frontend fix is now in the compiled bundle, which is the only way it could ship:
`thinking_enabled:"thinking"===d.mode||"pro"===d.mode||"ultra"===d.mode`. The 0.2.7
image carried `thinking_enabled:"flash"!==d.mode`. The backend's baked recursion
default also moved from the stale `100` to `_PACGATE_MAX_RECURSION_LIMIT`.

### GHCR preflight fails behind a dead local proxy, and that is not a repo defect

Both `preflight-release-tag.ps1` and `verify-delivery-state.ps1` reported every GHCR
tag as `UNVERIFIED` / `ERROR` while the packages were in fact public and pullable.
The cause was the environment, not the code:

```text
HTTP_PROXY=http://127.0.0.1:7892
HTTPS_PROXY=http://127.0.0.1:7892     <- nothing listening on 7892
```

`docker manifest inspect ghcr.io/...:0.2.7` reported `proxyconnect tcp: dial tcp
127.0.0.1:7892: connectex: No connection could be made`, and `curl` to
`https://ghcr.io/v2/` returned `http=000 exit=7`. With the proxy cleared, the same
commands return the 0.2.7 manifest (and `manifest unknown` for 0.2.8 before the
release), which is the correct pair of answers.

So when either script says GHCR is `UNVERIFIED`, check the proxy before believing the
registry is unreachable:

```powershell
Test-NetConnection 127.0.0.1 -Port 7892 -InformationLevel Quiet   # False = dead proxy
$env:HTTP_PROXY = ''; $env:HTTPS_PROXY = ''; $env:NO_PROXY = '*'
.\scripts\preflight-release-tag.ps1
```

The scripts are right to refuse to guess: an unreadable answer is not evidence the
images exist. The mistake would be reading `UNVERIFIED` as "the registry is down".

## Firecrawl and e2e coverage (2026-10-31)

### Firecrawl is a connector, not an MCP server - and that is a safety decision

Each AIPC pastes its own `FIRECRAWL_API_KEY` into `.env`; until then the connector
reports `available=false` and /api/search simply returns no web results.

The alternative - a `firecrawl` entry in `deer-flow-extensions-config.json` - was
rejected on measurement, not preference:

- the pinned deer-flow image carries no `firecrawl-mcp` binary (only `npx`), so the
  entry would need a runtime install on an offline machine;
- the MCP template has never contained a firecrawl entry;
- and the image has NO per-server isolation. `get_mcp_tools()` awaits one
  `client.get_tools()` for all servers and its `except` handler logs and `return []`.
  A firecrawl entry with an empty key would not degrade web search, it would remove
  every MCP tool including `pacgate` and `officecli`.

As a `DataSourceConnector` the failure mode is one empty result set. Verified
contract: `POST https://api.firecrawl.dev/v1/search` with `{"query","limit"}` returns
`{"success",data:[{"url","title","description"}]}`; `limit` is honored and CJK
queries round-trip.

`source_level` is `auxiliary_db`. A web page is not statutory text and must not be
graded `authority_verified`.

### A connector key name was wrong for three releases

The code reads `COURTLISTENER_API_KEY`. Both compose files and `plans/013` told
operators to set a differently spelled name with an extra underscore. Nothing reads
that spelling, so an operator who followed the docs got a connector that reported
`available=false` forever with no error, no log line, and no symptom beyond "this
source never returns results". `test-connector-registry.ps1` now asserts the contract
in both directions: every key the code reads is documented, and no documented
connector key is one the code ignores.

### A second false "implemented" claim

The registry has 27 catalog entries; 11 were marked `implemented: true` while only 10
had a `DataSourceConnector` impl. `ansvar` was the mismatch, and `ANSVAR_API_KEY` was
documented for a connector that cannot be constructed. `GET /api/search/registry`
returned the claim while `GET /api/search/connectors` omitted the name, so the two
endpoints disagreed. Fixed, and `K6` in `test-connector-registry.ps1` now compares the
flags against the impls so it cannot drift again.

### Two coverage gaps closed

- The **legal journey** (matter -> upload -> extract -> sanitize -> review gate ->
  KB search -> external search -> connector health -> deer-flow auth -> qm ->
  OpenViking recall) passed 19/19 while being absent from `run-all-checks.ps1`. A
  release could have shipped with the entire journey broken and the suite would have
  said "all green".
- **No agent->MCP E2E existed.** `smoke-full-stack.ps1` said so in its own text. The
  measured cost: an unescaped brace in the prompt made every agent run die at
  construction with `KeyError: '"command"'` and the full suite stayed green.
  `test-agent-mcp-e2e.ps1` now starts a run that cannot be answered without a tool
  call and asserts a real advertised tool name appears in the payload, with a result.
  Verified live: the run calls `pacgate_list_connectors` and `pacgate_kb_search`.

### Baseline for the next release

Connector availability on the shipped `0.2.8` image, measured: **4 of 10** -
`courtlistener`, `sec_edgar`, `gleif`, `eur-lex`. Firecrawl is registered in this
change but is not in that image; a rebuild makes it **5 of 11**, and adding
`FIRECRAWL_API_KEY` makes it available. The rest (`yuandian`, `pkulaw`, `qcc`,
`fyopen`, `vaquill`, `opencorporates`) need subscriptions only the client can
provide. Re-measure with:

```powershell
pwsh -NoProfile -File scripts/test-legal-journey.ps1 2>&1 | Select-String 'connector health'
```

and correct this paragraph if the number differs - do not leave a claim that was not
measured.
