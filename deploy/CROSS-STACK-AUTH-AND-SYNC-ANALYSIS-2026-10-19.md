# Cross-stack auth wiring and multi-AIPC sync — root cause analysis

**Date:** 2026-10-19
**Scope:** why qm / OpenViking / deer-flow get blocked from auth when the stack is
version-bumped, how to enforce the wiring on every future release, and whether Matters,
skills, tools, templates and workflows can sync between AIPC 1 and AIPC 2.

Everything below is measured on the live 0.1.32-era stack or read from the tracked tree with
file:line. Where I was wrong in an earlier pass I say so explicitly.

> **STATUS (added after the fixes landed, same day).** Sections 1–5 are the analysis. The
> defects in 1c, 1d and 3 are now FIXED and enforced, with gates that were red-checked
> against the original defects:
>
> | Defect | Fix | Enforcement |
> |---|---|---|
> | two origin allowlists computed differently (1c) | both derive from `GATEWAY_CORS_ORIGINS` in BOTH compose files; installer derives both published ports and repairs an incomplete existing `.env` additively | `test-origin-coherence.ps1` O1–O4 |
> | OAuth issuer hardcoded to `localhost` (1d) | six browser-facing qm URLs derive from `QM_PUBLIC_URL`; in-cluster token/JWKS stay on `auth:8080` | `test-origin-coherence.ps1` O5 |
> | sync never built (3) | `scripts/sync-pacgate-matters.ps1` (HTTP-boundary export/import, natural keys, never deletes) | `test-sync-capability.ps1` S1–S5 |
>
> Verified after the fix: all 4 previously-403 origins reach auth (422); the OIDC discovery
> document advertises the machine hostname and the authorize endpoint renders the real
> sign-in form (HTTP 200 with a PKCE challenge). See §8 for the evidence and the remaining
> owner decisions.

---

## 0. One correction I owe you

I previously said qm and OpenViking "travel as config, and that is where the real defects
were". That was too tidy. The actual failure surface is **identity, origins and OAuth
endpoints** — and I had never tested any of it. Worse: the gate I wrote to fix that class
(`test-lane-connectivity.ps1`, E1–E11) **does not test origins, CORS or OIDC at all**
(verified: no match for `Origin|CORS|OIDC|8181`). So my own "edges" gate is blind to exactly
the edges you are pointing at.

---

## 1. What actually breaks, and what does not

### 1a. A version bump does NOT rotate secrets (verified)

`install.ps1` preserves `.env`; `setup-qm.ps1` refuses to regenerate it
(`[SKIP] .env already exists - preserved, NOT regenerated`, ~line 295, with a comment
explaining that regenerating breaks `POSTGRES_PASSWORD` against the existing `pgdata`
volume and silently invalidates every issued session). Rotation requires deliberately
deleting **both** `.env` and the volume (`setup-qm.ps1:301`).

So the "rotated secrets blocked qm" theory is not the mechanism on this box.

### 1b. A version bump does NOT change ports or network coordinates (verified)

Every host port and every inter-container URL in `compose.prod.yaml`, `compose.bundle.yaml`
and `compose.qm.yaml` is a static literal or `${VAR:-default}`. Only **image tags** carry the
version (`:0.1.32`). No port, host or path depends on the release number.

`PUID` is also not a knob here: the only user directive in the whole tracked tree is
`user: node` (`compose.qm.yaml:24`). If you meant **principal/user identity**, that is real —
see §4.

### 1c. What DOES break: two origin allowlists that are computed differently

This is the concrete, reproducible defect.

**Mechanism A — `GATEWAY_CORS_ORIGINS` is machine-derived and overwrites a better default.**
`install.ps1:578-621` derives `<scheme>://<hostname|every-LAN-IP>:<nginx port>` from the
machine and writes it to `.env`. The compose default is
`http://localhost:8089,http://localhost:8090` (`compose.prod.yaml:170`). Once `.env` has a
value, compose uses **that** instead. And the derived value contains **only the nginx port**:

```
GATEWAY_CORS_ORIGINS=http://localhost:8089,http://laptop-hh9v75mk:8089,
  http://100.124.82.112:8089,http://168.192.1.76:8089,
  http://172.29.176.1:8089,http://172.18.208.1:8089
```

Port **8090 is gone** — the installer's "helpful" derivation *removed* access the shipped
default had granted.

**Mechanism B — `DEER_FLOW_TRUSTED_ORIGINS` is a third, hardcoded list.**
`compose.prod.yaml:320` sets `http://localhost:8089,http://localhost:8090,http://localhost:3000`
— localhost only, never the machine's hostname or LAN IP. A client browsing the AIPC from
another computer is never in it.

**Measured consequence** (POST to `/api/v1/auth/login/local`, which is the route the deer-flow
gateway guards):

| `Origin` sent | result |
| --- | --- |
| `http://localhost:8089` | **422** — reached auth (bad creds expected) |
| `http://laptop-hh9v75mk:8089` | **422** — works |
| `http://localhost:8090` | **403 — BLOCKED** |
| `http://laptop-hh9v75mk:8090` | **403 — BLOCKED** |
| `http://evil.example.com` | 403 — correctly blocked |

And the port the browser actually uses matters: `/` and `/research/` proxy the **frontend**
through nginx (`nginx location /` → `$frontend_upstream`), while `:8090` is that same
frontend published directly. Any client flow whose `Origin` is `:<8090>` is refused by the
gateway even though nginx's own CORS layer would allow it.

**Nothing tested this.** No script in `scripts/` references `GATEWAY_CORS_ORIGINS` or
`TRUSTED_ORIGINS`, and my `test-lane-connectivity.ps1` does not either.

### 1d. What DOES break OAuth: the issuer is hardcoded to `localhost`

`compose.qm.yaml` hardcodes the entire OIDC/OAuth surface:

| var | value | line |
| --- | --- | --- |
| `AUTH_ISSUER` | `http://localhost:8181/idp` | 207 |
| `AUTH_REDIRECT_URI` | `http://localhost:8181/auth/callback` | 209 |
| `OIDC_ISSUER` | `http://localhost:8181/idp` | 167 |
| `OIDC_AUTH_ENDPOINT` | `http://localhost:8181/idp/authorize` | 168 |
| `PORTAL_PUBLIC_URL` | `http://localhost:8181` | 180 |
| `PUBLIC_WEB_URL` | `http://localhost:8181` | 60 |

The live OIDC discovery document (read from inside `qm-pacgate-auth`) advertises exactly that:

```
issuer                 = http://localhost:8181/idp
authorization_endpoint = http://localhost:8181/idp/authorize
token_endpoint         = http://localhost:8181/idp/token
jwks_uri               = http://localhost:8181/idp/.well-known/jwks.json
```

**Why this blocks auth off-box:** the portal (`:8181`) redirects the *browser* to
`authorization_endpoint`. The browser runs on the **client machine**, so `localhost:8181`
means *their own computer* — a connection that either fails or, worse, succeeds against
something else they happen to run on 8181. OAuth therefore only works when the user is
browsing **on the AIPC itself**. That is precisely "qm blocked from OAuth" — and it is a
localhost lock, not a rotation.

Note the split that makes this easy to miss: the **server-side** endpoints
(`token_endpoint`, `userinfo`, `jwks`) correctly use the internal service name `http://auth:8080`,
so token exchange works. Only the **browser-facing** ones are locked to localhost. A test that
only exercises token exchange passes while sign-in is unusable.

`qm.config.jsonc` already has the right lever — `"publicUrl": "http://localhost:8181"` and
`"basePort": 8180`, with a comment saying portal is `basePort+1`. But `compose.qm.yaml`
**ignores it** and repeats `localhost:8181` in six places. So the intended mechanism exists
and was never wired.

---

## 2. Why an upgrade can leave qm/openviking "blocked" even with no rotation

Three independent, verified reasons — none of which is a rotated key:

1. **A corrected `.env` does not reach a running container.** Containers keep the environment
   they were *created* with. `install.ps1 -Update` recreates the main stack (`up -d`) but
   deliberately never touches qm (restarting a staff-facing stack mid-session is worse). So a
   fix can be "shipped" and still not applied. I added `test-qm-currentness.ps1` for this.
2. **Two allowlists drift apart** (§1c): the machine-derived one and the hardcoded one are
   never compared. The derivation can even *reduce* access.
3. **The browser-facing OAuth endpoints are localhost-locked** (§1d), so they work on the box
   and fail from anywhere else — the classic "works for the engineer, breaks for the client".

---

## 3. Multi-AIPC sync: the honest answer is that it was never built

You said this "should be in our original design". I checked, and the repo contains **no
replication, export, import or fleet mechanism** for live state — no route, no service, no
script. What exists is per-machine persistence plus manual backup notes in `plans/`
(`009-aipc2-sync-and-upgrade-0.1.7.md`, `026-aipc-sync-upgrade-0.1.24.md`) — those document
how to *upgrade* a machine, not how to *converge* two.

### 3a. The identity problem is the real blocker

Measured schema:

| object | id | generator |
| --- | --- | --- |
| `tenants` | `id uuid` | **`uuid_generate_v4()`** |
| `users` | `id uuid` | **`uuid_generate_v4()`** |
| `matters` | `id uuid` | random; FKs to `tenant_id`, `created_by` |
| `documents.storage_path` | text | `tenants/<tenant-uuid>/matters/<matter-uuid>/docs/…` |

So AIPC 1 and AIPC 2 give the **same firm and the same admin different UUIDs**. A naive
`pg_dump` from one into the other creates a *second* tenant and a *second* admin, and every
`storage_path` on the copied rows points at a tenant directory that does not exist on the
target. That is why "copy the data" is not a sync strategy here.

### 3b. The schema was built for idempotent upsert — and nothing uses it

This is the most useful finding, because it means the design *is* half-present:

```
tenants_slug_key            UNIQUE (slug)                       <- natural key for the firm
users_tenant_id_email_key   UNIQUE (tenant_id, email)           <- natural key for a user
idx_matters_tenant_external_key  UNIQUE (tenant_id, external_key)
                                 WHERE external_key IS NOT NULL  <- natural key for a matter
```

Every one of those is exactly the constraint you need for "insert or update by natural key"
replication. But:

```
matters: total 59 | external_key populated 0 | distinct external_key 0
```

**`external_key` is empty on 100% of matters.** The column, the partial unique index and the
comment above it exist; nothing writes to it. So today matters have no machine-independent
identity, and re-importing the same matter twice would duplicate it — which is why the partial
index is inert.

`tenants.slug` **is** stable (`default-firm` on both machines, and both share
`PACGATE_TENANT_ID=default-firm`), and `users` are keyed by `(tenant_id, email)`. So a
reconcile path for firm + users already exists; matters are the gap.

### 3c. What would not transfer today, and why

| item | where it lives | why it will not transfer |
| --- | --- | --- |
| **Matters / documents** | Postgres + `./data/tenants` (8.7 MB) | random UUIDs + UUID-embedded `storage_path`; no export route |
| **Matter natural key** | `matters.external_key` | column exists but is **0% populated** |
| **KB chunks / spans / audit** | Postgres (150 / 1025 / 842 rows) | keyed to the random matter/tenant UUIDs |
| **Workflows / templates** | `./workflows` **bind mount** (`compose.prod.yaml:137`) | repo files, not DB rows — two machines need the same checkout |
| **deer-flow skills / patches** | 20+ bind-mounted files (`compose.prod.yaml:210-275`) | image + repo mount, per-machine |
| **qm skills / sandbox tool** | `deploy/qm-pacgate/sandbox/` → staged copy | per-machine file tree |
| **deer-flow memory / chat** | `./data/deer-flow` (`deerflow.db`, `checkpoints.db`) | separate identity store from pacgate-api |
| **OpenViking memory** | `./openviking` bind mount (9.5 MB workspace) | per-machine filesystem; no export/import |
| **qm runs / memory** | own Postgres (`qm-pacgate-pg`) | separate stack, no export path |
| **Users (3 principals)** | pacgate-api `users`, deer-flow `.deer-flow/users`, qm auth | **three separate identity stores** |
| **Secrets** | `.env` (both files) | per-machine by design |

### 3d. Three identity stores, and they can disagree

Verified: pacgate-api has 3 users (`$argon2…` hashes — portable, good); deer-flow keeps its own
`/app/backend/.deer-flow/users/` with two UUID directories; qm has its own auth service with
`AUTH_SIGNING_JWK`. Nothing reconciles them. Today that is hidden because all three converge on
**one email** (`admin@pacgate-law.com` is `PACGATE_API_EMAIL`, the qm `.env` identity, qm's
`OPENVIKING_USER`, and `AUTH_ALLOWED_EMAILS`). Add a second real user and multi-AIPC sync
immediately has three stores to reconcile instead of one.

---

## 4. Answers to "how do we enforce this in future releases"

Four checks, ordered by cost. Each closes a verified gap; none of them exist today.

### Enforce 1 — origin coherence (cheap, highest value)

One gate that asserts, for the assembled stack:
- every origin in `GATEWAY_CORS_ORIGINS` is also accepted by the deer-flow auth route
  (`POST /api/v1/auth/login/local` must not return **403** for it);
- the nginx port **and** the frontend port (8090) are both represented;
- `DEER_FLOW_TRUSTED_ORIGINS` is superset-or-equal to the browser origins the installer
  derives, or is derived from the same source.

This is a live test: send one request per origin and assert not-403. It catches the class, not
the instance, and it fails on today's stack (`:8090` → 403).

### Enforce 2 — no localhost-only OAuth on a network-deployed machine

Static: assert `AUTH_ISSUER` / `OIDC_ISSUER` / `AUTH_REDIRECT_URI` / `PORTAL_PUBLIC_URL` are
`${PUBLIC_WEB_URL}`-substituted (or `${VAR:-…}`), never bare literals; and that
`compose.qm.yaml` derives them from `qm.config.jsonc`'s `publicUrl`.
Live: fetch the discovery document and assert the advertised `issuer` host equals the
configured public host, not `localhost`, whenever the machine is not loopback-only.

### Enforce 3 — release-time wiring assertion (the "did the bump break the seam" check)

A single scripted post-release smoke that must pass **before** the release is called done:

```
deer-flow login from each derived origin      -> not 403
pacgate-api login as admin                    -> 200 + token
qm portal -> auth issuer reachable            -> discovery 200, issuer host == public host
qm -> pacgate-api (from inside qm container)  -> 200   (exists: E6)
qm -> openviking /mcp (from inside container) -> 200   (exists: E7)
openviking /mcp with the CLIENT key           -> 200   (exists: C4)
```

E6/E7/C4 already exist. The first three are the missing half, and they are the ones that
"blocked from OAuth and communication".

### Enforce 4 — make the browser-facing origin a single derived value

Root-cause fix rather than a check: derive `AUTH_ISSUER`, `OIDC_*`, `PORTAL_PUBLIC_URL`,
`PUBLIC_WEB_URL` and `GATEWAY_CORS_ORIGINS`/`TRUSTED_ORIGINS` from **one** value —
`qm.config.jsonc`'s `publicUrl` for qm, and the installer's derived host list for the main
stack — and assert in CI that no bare `http://localhost:` literal survives in a browser-facing
variable. The comment in `compose.prod.yaml:167` already says a client on the LAN "is NOT in
the default list"; the defaults were never actually fixed.

---

## 5. Answers to "how do we sync across AIPCs"

Recommended shape, cheapest first. All of it needs the §3b keys populated first.

**Step 1 — give matters a natural key (prerequisite).** Populate `matters.external_key` at
creation from something machine-independent already in hand — the matter's own business
identifier, or `<tenant_slug>:<created_at>:<name-slug>`. The partial unique index already
exists, so this is a writer change plus a backfill for the 59 existing rows. **Without this,
every other sync step duplicates data.**

**Step 2 — export/import as a first-class command, not `pg_dump`.** One bundle per matter:
JSON for the relational rows + the `tenants/<slug>/matters/<key>/` file tree, with `storage_path`
rewritten on import. Keyed by `(tenant.slug, matter.external_key, users.email)` so import is an
idempotent upsert against the three unique constraints that already exist. This is the only
shape that survives the UUID divergence in §3a.

**Step 3 — decide the authority model explicitly.** Two machines either (a) both read/write with
a sync protocol (hard: 59 matters is small, but conflict resolution on `documents`/`kb_chunks` is
not), or (b) one is authoritative and the other is a restore target (easy, and probably right for
a legal firm). **Pick (b) first** — it needs only Step 2 and no distributed-systems work. Do not
build merge-by-default: for legal records, an explicit import with a visible audit trail beats
silent last-write-wins.

**Step 4 — treat content, not state, as the shippable part.** Workflows, skills, tools and
templates should travel in the **release** (they already do: `./workflows` bind mount, staged qm
sandbox). What must NOT be in the release is a machine's accumulated matters. Keep the split
sharp: release = code + content; per-machine = data + secrets.

**Explicitly out of scope for now:** real-time replication of OpenViking/vector state and qm run
history. Both are vendor-owned formats with no export path, and neither is needed for the
"restore a machine" use case.

---

## 6. Findings ranked

| # | finding | severity | evidence |
| --- | --- | --- | --- |
| 1 | OAuth issuer/browser endpoints hardcoded to `localhost` → sign-in impossible off-box | **high** | discovery doc; `compose.qm.yaml:167,207,209` |
| 2 | `GATEWAY_CORS_ORIGINS` derivation drops `:8090`; auth route returns **403** for it | **high** | measured 422 vs 403; `install.ps1:578-621` |
| 3 | `DEER_FLOW_TRUSTED_ORIGINS` hardcoded localhost; present in prod, **absent** from bundle | **high** | `compose.prod.yaml:320` |
| 4 | No test anywhere covers origins, CORS or OIDC — including my own E1–E11 gate | **high** | grep of `scripts/` |
| 5 | `matters.external_key` 0% populated → no machine-independent identity, sync duplicates | **high** | SQL count; partial unique index |
| 6 | Tenant/user UUIDs are random per machine; `storage_path` embeds them | medium | `uuid_generate_v4()`; sample paths |
| 7 | Three unreconciled identity stores (api, deer-flow, qm) | medium | argon2 users, `.deer-flow/users`, qm auth |
| 8 | `qm.config.jsonc.publicUrl` exists but compose ignores it in six places | medium | `qm.config.jsonc:12` vs `compose.qm.yaml` |
| 9 | No export/import/replication for matters, OpenViking, qm | medium | no route/script found |
| 10 | Secret rotation is not the mechanism for the reported breakage | informational | `.env` preserved; rotation needs volume delete |

---

## 7. The uncomfortable summary

The defects you are describing are real, but they are **not caused by rotation and not caused by
the version bump**. They are caused by **hardcoded `localhost` in browser-facing OAuth/CORS
configuration**, and by **two origin allowlists computed by different rules** — one of which the
installer *reduces* every time it runs.

They survived because the entire test suite — including the edge gate I added last week — tests
**server-to-server** connectivity, and every one of those paths uses `localhost` or a container
name. Nothing tested "can a browser on another machine sign in". That single missing assertion
explains why qm and OpenViking look healthy on the box and are unreachable for the client.

Sync was never designed in. The schema has the natural keys needed to *build* it
(`tenants.slug`, `users(tenant_id,email)`, `matters(tenant_id,external_key)`) — but the last one
is populated on **zero** rows, so the design was started and never finished.

---

## 8. Evidence after the fix (2026-10-19)

### 8a. The two origin gates now agree

Measured by posting a deliberately wrong credential with varying `Origin`. 422 means the
request **reached authentication** (gate passed); 403 means it was **refused at the gate**.

| Origin | gateway before | gateway after | frontend after |
|---|---|---|---|
| `http://localhost:8089` | 422 | 422 | 422 |
| `http://localhost:8090` | **403** | 422 | 422 |
| `http://<hostname>:8089` | 422 | 422 | 422 |
| `http://<hostname>:8090` | **403** | 422 | 422 |
| `http://evil.example:9999` | 403 | 403 | 403 |

The last row matters: the lists still **reject** an unknown origin. This widened access to this
machine's own browser origins, it did not disable the control.

`deer-flow` and `deer-flow-frontend` now carry the identical derived list (the frontend adds
`:3000`), verified with `printenv` on both containers.

### 8b. OAuth is usable from another machine

Before: `issuer=http://localhost:8181/idp`. After:

```
issuer                 : http://<hostname>:8181/idp
authorization_endpoint : http://<hostname>:8181/idp/authorize
token_endpoint         : http://auth:8080/token          <- still in-cluster
jwks_uri               : http://auth:8080/.well-known/jwks.json
```

`/idp/authorize` returns **HTTP 200** with the real sign-in form ("Enter your work email and
we'll send you a one-time sign-in link") when given a PKCE S256 challenge. Without PKCE it
correctly returns 400 "This sign-in request must use PKCE with S256" - unrelated to this defect,
and a good sign the endpoint is doing its job.

### 8c. Sync tool, proven on real data

Export against the live stack: **59 matters, 60 documents** copied, **17 documents correctly
withheld** by the egress gate (they are not sanitized, so the API refuses to let them leave -
that control was left intact, not bypassed).

Round-trip proof on an isolated fixture: matter created, document uploaded with the extension
rebuilt from its recorded `format`, then a **second import reused the matter by `external_key`
and skipped the existing document** - 0 created, 0 duplicated, exit 0.

### 8d. What the sync tool surfaced about this machine

`matters.external_key` is populated on **0 of 59** matters, and there are **50 separate matters
all named "Sanitizer E2E"** (each `test-sanitizer-e2e.ps1` run creates one). So a name is not a
key here. The tool therefore refuses to resolve an ambiguous name and creates a new matter
instead of guessing - attaching client documents to an arbitrary duplicate is worse than a
duplicate. **Owner decision:** populate `external_key` for real matters, and decide whether the
50 test fixtures should be cleaned up.

### 8e. Bugs I introduced and fixed while proving 8c

Recorded because they are the kind that survive a green suite:

1. `Invoke-WebRequest.Content` is a **string** for text responses, so `WriteAllBytes` failed on
   every `.md`/`.txt` document while binary formats worked. Switched to `-OutFile`.
2. `@(Get-Api ...)` wrapped a JSON array in a second array, so `.Count` was **1 instead of 63**
   and the index saw one matter. Re-import then tried to create matters that already existed and
   got HTTP 500 from the partial unique index.
3. PowerShell returns a bare **string** rather than a 1-element array for single values, so
   `$byName[$n].Count` silently made every unique name look ambiguous.
4. `DELETE /api/matters/:id` answers **500** when dependent rows exist. The tool no longer
   offers any delete at all.

### 8f. Still open (owner decisions, not code defects)

**Status after 2026-10-19.** Items 1 and 4 are now code-complete; 2, 3 and 5 remain the
owner's call.

1. **`external_key` is unpopulated.** **REPAIRABLE now.** `PATCH /api/matters/:id` exists
   (admin-only, 409 on a duplicate, 404 scoped to the tenant) and
   `sync-pacgate-matters.ps1 -Action BackfillKeys` drives it with `-WhatIf` and `-NameFilter`.
   Verified against a real build: set=200, duplicate=409, blank=null, unknown=404.
   **Still the owner's decision:** which matters get keys, and what prefix to use.
2. **The 50 duplicate "Sanitizer E2E" matters.** Test residue, not client data.
3. **qm vs compose authority** - `qm.config.jsonc` has `publicUrl`/`basePort`, but compose now
   uses `QM_PUBLIC_URL`. Two levers for one value; picking one is a design decision.
4. **`PACGATE_MODEL_MID`** now defaults to `ornith-1.5:9b` (6.6 GB) in both compose files and in
   `ModelConfig::DEFAULT_MID_TAG`, so the tier fits a 16 GB AIPC. The capacity gate is enforced
   in the suite behind `-Strict` rather than reported as a measurement.
5. **A version bump is still required** for these config changes to reach a built image; the
   provenance gate compares the tag against the tree and will be red until 0.1.33 is built.

