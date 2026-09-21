# Pacgate AI — multi-user, multi-surface architecture plan

**Date:** 2026-09-21
**Status:** DESIGN. Answers the four operator questions; two decisions remain (§9).
**Scope:** how users, data, memory, and teams are scoped across the deer-flow
surface, the pacgate-api gateway, the OpenViking memory store, and the qm team
space.
**Supersedes/extends:** `deploy/AUTH-ASSIGNED-USERS-DESIGN.md` (§2A/2B),
`deploy/DEER-FLOW-UPSTREAM-DRIFT-ASSESSMENT-2026-09-21.md`

Evidence is cited inline. Upstream semantics come from OpenViking's published
docs and the qm repository; internal facts come from this repo.

---

## 0. Executive summary — the answers

| Question | Answer |
| --- | --- |
| **1. deer-flow per AIPC** | Single account, as the operator proposed. It is *already* the natural state: deer-flow has real per-user isolation internally (`owner_id`, `AUTO` filter, 404 on foreign threads), but our **MCP lane defeats it** by using one shared service credential. Fix that, and single-user is coherent rather than merely convenient. |
| **2. Where data lives** | Matters, workflows, metadata and knowledge → **pacgate-api Postgres + filesystem**, which already scopes every table by `tenant_id`/`matter_id`. Long-term memory → **OpenViking**, which already scopes by `account_id`/`user_id`. Neither needs new tenancy machinery; both need to be *fed the right identity*, which today they are not. |
| **3. How many users/admin in OpenViking** | **Unlimited, but not by our current wiring.** OpenViking natively supports ROOT / ADMIN / USER with unlimited accounts and users per account. Our deployment uses a **single ROOT key** on `/mcp`, which is *not bound to any tenant user* and therefore cannot scope. Multi-user requires Admin-API user keys or `trusted` mode. |
| **4. How teams work in qm** | qm already has the richest scope model of the four: **person + room/channel + team + org**, each with its own memory/files/permissions, an org-wide security *ceiling* with per-scope opt-outs, and skills shared by grant. Map **qm channel → pacgate matter** (already implemented via `external_key`) and **qm team/org → pacgate tenant**. |

**The one systemic finding:** every layer in this stack *supports* multi-user
scoping, and **every layer is currently running in its single-user/dev mode**.
The work is not inventing tenancy — it is wiring the identity we already have
through four layers that already understand it, and closing the three places
where one shared credential flattens the model.

---

## 1. Question 1 — deer-flow per AIPC: single-user for heavy work

**Agreed, with one correction to the reasoning.** The operator's framing is
"deer-flow is single-user." That is the right *operating decision*, but it is not
a limitation of deer-flow — deer-flow has real per-user isolation:

- `system_role` is `admin` | `user` (`pacgate-ai` equivalent; deer-flow's own
  roles are coarse — "細粒度 RBAC" is explicitly listed as **not implemented**).
- Repository, file paths, memory and agent config all "resolve per current user
  by default" (`AUTH_DESIGN.md`).
- Client-supplied `metadata.user_id` / `metadata.owner_id` are **stripped**
  server-side, so a client cannot claim to be another user.
- `ThreadMetaRepository.create(..., user_id=AUTO)` resolves the real user from a
  `ContextVar`; `AUTO` must never silently degrade into a global query.
- Foreign threads return **404, not 403**, to avoid leaking existence.
- Per-user memory paths are the default; only an **absolute** `memory.storage_path`
  opts out into a shared path.

So the surface is *capable* of many users. We are choosing one account for a
different and better reason: **heavy single-user work** — OCR over large
document sets, sanitization passes, long research runs, document analytics and
generation. Those jobs are resource-bound and want a stable, uncontended
workspace with one identity owning the artifacts.

### The defect that makes single-user necessary rather than chosen

Our MCP lane collapses identity:

```yaml
# deploy/client-bundle/compose.prod.yaml (pacgate-mcp)
PACGATE_JWT_TOKEN:  ${PACGATE_JWT_TOKEN}
PACGATE_TENANT_ID:  ${PACGATE_TENANT_ID:-default-firm}
PACGATE_MATTER_ID:  ${PACGATE_MATTER_ID}
```

One service credential, one tenant, one matter. The deer-flow user's identity is
never passed across the MCP boundary, so **every deer-flow session queries the
same firm data** and deer-flow's excellent per-user isolation stops at the tool
edge. This is the reason "one account" must be enforced by the `/register` gate
(see `AUTH-ASSIGNED-USERS-DESIGN.md` §6) — otherwise a second account would get
its own threads but the same knowledge base, which is the worst of both: an
illusion of separation.

**Recommendation:** one account per AIPC, `/register` gated closed, and the
frontend port (`8090:3000`) no longer published directly so the ingress cannot be
bypassed. Document explicitly that *per-user isolation inside deer-flow is real
but is not an authorization boundary for firm data* — that boundary lives in
pacgate-api.

---

## 2. Question 2 — core data, matters and workflows ship with pacgate-api + OpenViking

**Agreed, and the schema already does it.** Confirmed from
`pacgate-ai/migrations/`:

Every table carries `tenant_id` as a `NOT NULL` FK with `ON DELETE CASCADE`, and
matter-scoped tables carry `matter_id` too:

| Table | Scoping | Notes |
| --- | --- | --- |
| `tenants` | root | `slug` (URL-safe) is the natural join to OpenViking `account_id` |
| `users` | `tenant_id` | `role` = admin/attorney/paralegal/partner; `system_role` = admin/user; `soul_id` |
| `matters` | `tenant_id` | `created_by` FK; `external_key` (unique per tenant) |
| `documents` | `tenant_id`, `matter_id` | `owner_id` FK; versioned `storage_path` |
| `kb_chunks` | `tenant_id`, `matter_id` | the RAG corpus |
| `document_spans` | `tenant_id`, `matter_id`, `document_id` | OCR text + coordinates |
| `sanitizer_jobs` / `redaction_ledger_rows` | `tenant_id`, `matter_id` | redaction vault + evidence |
| `audit_log` | `tenant_id`, `user_id`, `scope` | `scope` is literally `tenant:{id}` or `matter:{id}` |

Filesystem layout is likewise tenant/matter scoped:
`{DATA_DIR}/tenants/{tenant_id}/matters/{matter_id}/docs/{name}_v{n}.{ext}`.

### Two gaps that matter for this design

**Gap 2a — authorization stops at the tenant.** `Claims` carries
`sub`, `tenant_id`, `role`, `system_role`, `soul_id`, `exp` — **no matter
membership**. Every matter handler reads the claim and scopes the query:

```rust
// pacgate-ai/crates/pacgate-api/src/matters.rs
let (tenant_id, _) = claims_to_ids(&claims)?;   // user id discarded
```

`delete_matter` has **no role check and no owner check** — only "authenticated,
same tenant." `role` (admin/attorney/paralegal/partner) exists but is not
enforced at the matter layer. In a one-firm-per-AIPC deployment this is
tolerable: the tenant boundary is the only boundary anyone needs. The moment two
teams share a tenant, **every attorney in the firm can read and delete every
matter**. That is legal-ethics relevant, not cosmetic.

**Gap 2b — the knowledge base is reached through a fixed matter.** With
`PACGATE_MATTER_ID` pinned in the environment, the agent's RAG queries are not
scoped to the user or the conversation — they are scoped to one configured
matter. "Matter" is the unit of ethical isolation in a law firm, so this is the
single most important thing to make dynamic before multi-team use.

**Recommendation:** keep pacgate-api as the system of record (it already is), and
treat these two gaps as the *prerequisite* for any multi-team story — not as
follow-up work. Concretely, add matter membership (`matter_members(matter_id,
user_id, role)`) and make the MCP lane carry the calling user's identity so
`PACGATE_MATTER_ID` becomes per-request rather than per-container.

---

## 3. Question 3 — how many users/admins in OpenViking, and where data goes

This is the question with the most consequential answer, because OpenViking's
capability and our wiring disagree.

### 3.1 What OpenViking natively supports

From `docs.openviking.ai/en/concepts/11-multi-tenant`:

> A single OpenViking Server uses `account` and `user` identity boundaries to
> control sharing and isolation.

- **`account_id`** — the outer tenant boundary ("a workspace, team, or customer
  space"). *"Data is isolated across different `account` values by default."*
  ROOT can create/delete accounts. `resources`, `user`, and `session` all live
  inside an account.
- **`user_id`** — the per-account user boundary. *"User memories and user
  sessions are isolated by `user_id`."* A normal user can only access its own
  user space; an admin can manage users in the same account.

| Role | Scope | Capabilities |
| --- | --- | --- |
| ROOT | Global | create/delete accounts, cross-tenant access, user management |
| ADMIN | Single account | manage users in the same account, regenerate user keys |
| USER | Single account | own user/peer/session data + shared resources in the same account |

**There is no documented user or account limit.** Counts are bounded only by
storage. So the honest answer to "how many users can work with OpenViking" is:
**unlimited by design, once multi-tenant mode is actually engaged.**

### 3.2 Isolation boundaries (the authoritative table)

| Data type | Across accounts | Within an account | Default boundary |
| --- | --- | --- | --- |
| Shared resources (`viking://resources`) | No | **Shared by default**; ACL can restrict | account / ACL |
| User resources (`viking://user/{uid}/resources`) | No | No | user |
| Peer resources | No | No | user / peer |
| **Memories** | No | **No** | **user / peer** |
| Skills | No | No | user |
| Sessions | No | No | user / session |

Storage gains an account prefix transparently — the public URI stays
`viking://user/alice/memories/`, while the disk path is
`/local/{account_id}/user/alice/memories/`. Isolation *"relies on request
context, `account_id` and `user_id`, applied consistently through the stack."*

### 3.3 Sharing inside an account: ACL

From `concepts/15-acl`, ACL applies **only** to shared resources
(`viking://resources/...`):

- Principals: `user:{id}`, `group:{id}`, `user:*`. (`group:*` unsupported; groups are flat.)
- Levels: `read` (read/list/find/search/grep) < `write` (+write/create/delete/move) < `manage` (+directory ops, ACL mgmt). Higher includes lower.
- Collaborative-document inheritance: a directory grant applies to descendants; a child can become `restricted` (direct grants only, ignoring inherited) while still *storing* the inherited value so un-restricting restores it.
- `acl.enabled` is **disabled by default**. While disabled, ACLs are *not resolved or enforced* and existing content *"remains public."*
- **`viking://user/{uid}/resources/...` is private and does not accept ACLs** — to share, move the resource into shared scope.
- Account `ADMIN` implicitly has `manage` on shared resources (not removable).
- Retrieval is ACL-aware: *"This keeps 'what you can search' aligned with 'what you can read.'"*

**This is exactly the primitive a law firm needs:** memories private per attorney,
shared precedent/knowledge-base material in `viking://resources` with per-directory
grants, and per-matter restriction boundaries.

### 3.4 The blocker in our deployment

Our deer-flow MCP config sends the **ROOT** key:

```json
// deploy/client-bundle/deer-flow-extensions-config.template.json
"openviking": {
  "url": "http://openviking:1933/mcp",
  "headers": { "X-API-Key": "${OPENVIKING_ROOT_API_KEY}" }
}
```

`deploy/qm-pacgate/.env.example` states the same: *"The qm sandbox's pacgate-qm
bridge calls OpenViking's /mcp endpoint, which authenticates against the ROOT
key. (The legacy app key is NOT accepted by /mcp and returns 401.)"*

Per the docs, that is load-bearing in the wrong direction:

> A `ROOT` key is for Admin APIs and selected system/monitoring APIs. **It cannot
> access tenant-scoped data APIs in `api_key` mode because it is not bound to a
> tenant user.**

And with `root_api_key` configured the server enters formal multi-tenant mode;
**without** it, `auth_mode = "api_key"` leaves the server in **dev mode where all
requests are treated as ROOT and the identity is `default/default`** (localhost
only).

Our workspace state confirms which mode we are in: `workspace/viking/_system/accounts.json`
contains exactly one account, `default`, and every session/task record carries
`"created_by_account_id": "default", "created_by_user_id": "default"`. So
**everything currently lands in one undifferentiated namespace.**

### 3.5 What that means, answered concretely

**Where does metadata and sensitive data go, and for whom?**

Today: **all of it lands in `account=default`, `user=default`** — regardless of
which attorney is working. Three separate lanes are affected:

1. **Memory (`user/default`)** — OpenViking session memories and extracted
   entities/events. Currently indistinguishable by user.
2. **Shared resources (`viking://resources`)** — *"Globally shared... not bound to
   specific account or Agent"* (our own workspace `resources/.overview.md`), and
   **ACL is disabled by default, so it remains public within the account.**
3. **Sessions (`user/default/sessions/`)** — every conversation archive, each
   with `created_by_user_id: default`.

Note also that **pacgate-api has a second, separate memory lane**:
`PacgateMemoryStorage` → `GET/PUT /api/matters/{matter_id}/memory` with `If-Match`
revisions (implemented 2026-09-20, `PACGATE_MATTER_ID=d4833de5-…` active). That
lane is matter-scoped and *firm-visible*; OpenViking is user-scoped personal
memory. **These two must not be conflated** — the same fact can exist in both,
with different visibility, and today nothing reconciles them.

### 3.6 Recommended OpenViking design

| Concept | Maps to | Why |
| --- | --- | --- |
| Firm / tenant | `account_id` = `tenants.slug` | Hard isolation boundary; matches the `NOT NULL tenant_id` everywhere else |
| Attorney | `user_id` = the pacgate user id | Private memories + sessions per person, which is the default boundary |
| Matter | a `resources/` subtree (+ `restricted` ACL mode) | *"Matters are the unit of ethical isolation"* — implement each matter as a restricted branch of shared resources, with grants only to assigned attorneys |
| Shared firm knowledge | `viking://resources/` with directory grants | Precedent, templates, public authority |
| Client/opposing party | `peer_id` | Already a first-class scope for "memory about a specific interaction peer" |

Concretely required changes:

1. **Turn on multi-tenant mode** (`root_api_key` + `auth_mode: api_key`) and
   create one `account` per firm tenant.
2. **Stop using the ROOT key for data access.** Provision a user key (or use
   `trusted` mode with `X-OpenViking-Account` / `X-OpenViking-User` injected by
   our gateway). `trusted` mode is the better fit: our gateway already knows the
   authenticated user, and header assertion avoids distributing OpenViking keys
   to every container.
3. **Enable `acl.enabled`** and treat each matter as a `restricted` subtree.
   Note the docs' warning: enabling ACL **does not migrate existing content** —
   anything already in `viking://resources` "remains public." A migration step is
   required, not optional.
4. **Decide the memory-split policy** (§3.5): what belongs in matter memory
   (firm-visible, in pacgate-api) vs personal memory (OpenViking), and how the two
   reconcile. This is a product decision with ethics implications.

---

## 4. Question 4 — qm-pacgate for teams: who designs them, who joins, what they do

qm is a **multiplayer agent harness** — the only one of the four surfaces designed
for teams from the ground up. From the repository and its design teardown:

> "Most agents are designed like personal assistants... QM gives each employee an
> isolated workspace and each shared room its own. Click any node to see what that
> scope owns."

### 4.1 qm's scope model

| Scope | Examples | Owns |
| --- | --- | --- |
| **personal** | per employee | memory, files, keychain view, permissions, crons, durable sandbox |
| **room / channel** | `#launch-week`, group DM, project | its own scoped memory, files, permissions |
| **team** | practice group | (team-scoped aggregation) |
| **org** | the firm | the security **ceiling** |

Key properties:

- *"One person's workspace does not affect another's"* — and the **same identity
  and configuration follows a user between Slack and the web app**.
- **Security posture**: the org picks one posture; narrower scopes may opt out.
  *"Isolated 'Follow organization' removes a personal or room override. Open does
  not mount a personal workspace into a room, carry credentials, message a
  teammate's entitlement, or weaken screening, command approvals, or egress."*
- **The agent acts as the person it works for, with their credentials and
  permissions, and everything is audited.** This is the property that matters most
  for a law firm — and it is precisely what deer-flow's shared MCP credential
  lacks.
- **Skills are scope-owned and shareable by grant**, with admin-gated promotion to
  the whole org.

### 4.2 Who designs teams, and who can be assigned

Two distinct roles, and the answer is different for each:

- **Who designs the team structure (which rooms exist, the org posture, promotion
  of skills to org-wide):** `ADMIN_GRANTS=<email>:org_admin` plus the **admin
  service** (`qm admin`, port 8183 — the "operator dashboard"). Deliberately
  operator-side, not self-service.
- **Who may be admitted:** `AUTH_ALLOWED_EMAILS` (exact-match allowlist) or
  `AUTH_ALLOWED_EMAIL_DOMAIN` (whole-domain), enforced by **both** the `auth`
  broker and the `portal`. Sign-in is a **one-time emailed link — no passwords.**
- **Who is in which room:** Slack/workspace membership for that surface, or the
  web surfaces. Rooms are the collaboration unit.

So: **the firm's admin designs the team shape; assignment is an allowlist we
control; people sign in by email link and land in their personal scope plus any
rooms they're in.** For a law firm this is a good fit — it is auditable,
credential-light, and revocable by editing a list.

### 4.3 What they can do together — and how it touches pacgate data

This is where qm and pacgate-api already meet, and the mapping is implemented:

`deploy/qm-pacgate/sandbox/tools/pacgate-qm/pacgate_qm.py` defines a
`ScopeContext` carrying `org_id`, `channel_id`, `team_id`, **`personal_user_id`**,
`personal_email`, and `pacgate_matter_id`, and:

```python
def derive_matter_name(scope):           # qm channel -> pacgate matter NAME
    return scope.channel_name or f"QM Channel {scope.channel_id}"

def matches_existing_matter(matter, scope):
    if scope.channel_id and matter.get("external_key") == scope.channel_id:
        return True                       # qm channel -> matter by external_key
```

and it writes the linkage into the matter description:

```
Linked QM scope
qm.orgId=… qm.channelId=… qm.teamId=… qm.personalUserId=… qm.personalEmail=…
```

So the intended model is already: **qm channel ↔ pacgate matter**
(`matters.external_key`), **qm org ↔ pacgate tenant**, and per-person identity
carried into the sandbox tool. That is the correct shape.

Two environment caveats, both already recorded in
`.env.example`, and both of which flatten the model today:

```bash
OPENVIKING_ACCOUNT=      # "the Pacgate tenant slug"     -> one fixed value
OPENVIKING_USER=         # "the attorney user id"        -> one fixed value
```

Pinning one `OPENVIKING_USER` for all qm traffic means **every team member's
agent writes to the same OpenViking user space**, even though qm itself has
per-person scopes. The `ScopeContext.personal_user_id` exists but is not what
`OPENVIKING_USER` is set from. Wiring those together is the highest-value qm
change.

### 4.4 Recommended qm design

1. **Treat qm as the only multi-user surface.** deer-flow stays single-account.
2. **`org_admin` = the firm's designated administrator**; our engineer holds the
   admin service for initial deployment, then hands over.
3. **Onboarding = add the email to `AUTH_ALLOWED_EMAILS`** (or the domain
   allowlist), let them sign in by link. No passwords to manage or reset.
4. **Each qm channel = one pacgate matter** (already implemented via
   `external_key`). Creating a matter is how a team gets a workspace.
5. **Derive `OPENVIKING_ACCOUNT` from the tenant slug and `OPENVIKING_USER` from
   `personal_user_id`** so per-person memory is real. Without this, qm's scoping
   stops at the pacgate boundary.
6. **Rooms map to matters; the org posture is the firm's ethical-wall ceiling.**
   qm's "org ceiling with narrower scopes able to opt *out*, never *up*" is a
   good analogue of firm policy vs matter-level restriction.

---

## 5. The unified identity map

```
                        ┌─────────────── qm (multi-user) ───────────────┐
  attorney signs in ───►│ org_admin designs  ·  portal + auth (link)    │
  (one-time link)       │ personal scope (1)  ·  room/channel scope (n)  │
                        └───────┬──────────────────────────┬───────────┘
                                │ channel -> matter        │ org -> tenant
                                ▼                          ▼
                    ┌──────────────────────────────────────────────────┐
                    │  pacgate-api  (system of record)                 │
                    │  tenants ─ users ─ matters ─ documents ─ kb_chunks│
                    │  spans · sanitizer_jobs · audit_log              │
                    │  every table NOT NULL tenant_id (+ matter_id)     │
                    └───────┬──────────────────────────────────────────┘
                            │ account=tenant.slug · user=attorney · matter
                            ▼
                    ┌──────────────────────────────────────────────────┐
                    │  OpenViking (context DB)                         │
                    │  account_id  = firm tenant        (hard wall)    │
                    │  user_id     = attorney          (private memory)│
                    │  resources/  = shared knowledge  (ACL by matter) │
                    │  peer_id     = client/party      (fine scope)    │
                    └──────────────────────────────────────────────────┘

  deer-flow (single account, heavy work): OCR · sanitize · research · document
  analytics/generation — writes into pacgate-api scoped by matter, and must be
  handed a per-session identity rather than one pinned PACGATE_MATTER_ID.
```

**Invariants to hold:**
- `tenants.slug` == OpenViking `account_id`. One firm = one account = one tenant.
- A matter is the ethical unit in *both* systems (pacgate `matters` / OpenViking
  restricted `resources` subtree).
- Personal memory lives in OpenViking under the attorney's `user_id`; matter
  memory lives in pacgate-api. Nothing silently writes to both.
- No component holds a credential that outranks the user it is acting for. (This
  is the violated invariant today, in three places.)

---

## 5A. CORRECTION (2026-09-21, later same day) — the binding constraint is topology, not permissions

This section corrects an error in the analysis above. §3.6 and §4.4 describe
OpenViking `account`/`user` scoping as the answer to the teams/memory problem.
**That is insufficient, and the operator's concern is better founded than the plan
originally credited.**

### Finding: each AIPC holds a complete, isolated copy of the firm's brain

Confirmed from `compose.prod.yaml` and the directory audit:

| State | Bind mount | Tracked in git? | Consequence |
| --- | --- | --- | --- |
| Document bytes + `pacgate` Postgres | `./data:/data` | **tracked-files=0, gitignored** | per machine |
| OpenViking workspace (memories, sessions, resources) | `./openviking:/app/.openviking` | not shared | per machine |
| deer-flow own SQLite state | `./data/deer-flow:/app/backend/.deer-flow` | gitignored | per machine |

And qm is coupled to its **own host**:

```jsonc
// deploy/qm-pacgate/qm.config.jsonc (sandbox.env)
"PACGATE_API_URL": "http://host.docker.internal:8089/pacgate",
"OPENVIKING_URL":  "http://host.docker.internal:1933"
```

A repo-wide search for any multi-machine mechanism (sync / federation / shared
memory) returns **nothing**.

### What this means for "Justin on AIPC1, Sylvie on AIPC2"

Both are `org_admin`, so **there is no permission wall between them**. There is a
**partition wall**: a matter, document, RAG chunk or memory created on AIPC1 does
not exist on AIPC2, and nothing reconciles them. The two machines are two
separate firms that happen to share a label.

This is the "memory wall" the operator asked about, and it is **not** solved by
OpenViking `account_id`/`user_id` — those scope *within one instance*. Scoping
correctly inside two disconnected instances still yields two disconnected
memories.

### Corrected statement of the problem

> The question is not "how many users can OpenViking hold" (unlimited, correct),
> and not "who is allowed to read what" (both admins, unbounded). It is **where
> the single source of truth lives**, and which surface is allowed to be a
> per-machine cache.

### Three architectural answers

| Option | Shape | Assessment |
| --- | --- | --- |
| **A. Centralise the data plane** | One machine (or firm server) hosts `pacgate-db` + `pacgate-api` + `openviking`; both AIPCs point at it via `DATABASE_URL`/`OPENVIKING_URL`. | Removes the wall. `pacgate-api` already takes `DATABASE_URL` from env, so this is feasible. But `./data` document bytes are filesystem, not DB — those must move to a shared share/NAS too, and one machine becomes a dependency. |
| **B. Centralise qm, keep AIPCs local** | Deploy **qm** to one host using its `--target fly\|aws` (native supported targets), with per-user/room scopes. Each AIPC keeps its own heavy-compute lane as a cache. | Best fit with qm's design: it is built as the shared multiplayer surface, and it supports real remote deployment. Team memory becomes genuinely shared while heavy OCR/research stays local. |
| **C. Federate / sync between AIPCs** | Replicate state between machines. | **No mechanism exists**; this would be new build with conflict-resolution and ethics problems (which copy wins for a matter file?). Not recommended. |

**Recommendation: B for the team plane, A only if the firm wants one shared
knowledge base across all machines.** These are complementary, not exclusive —
qm centralised for collaboration, and optionally A if the firm's matters must be
visible from every AIPC.

### Consequence for the phases

Phase 2 (OpenViking tenancy) is **still required but no longer sufficient** — it
is correct inside one instance. A new **Phase 1.5** is inserted: decide and
implement the topology (A and/or B) *before* investing in per-instance scoping,
because scoping decisions are downstream of where the data lives. Doing Phase 2
first would produce a beautiful, correctly-scoped, still-disconnected memory.

## 6. Gap register

| # | Gap | Where | Impact | Severity |
| --- | --- | --- | --- | --- |
| G1 | `/register` unconditionally open in `v2.0.0` | deer-flow | anyone reaching the URL gets an account + session | **Critical** |
| G2 | `/api/v1/auth/initialize` public; creates first admin | deer-flow | fresh AIPC can be claimed by whoever arrives first | **Critical** |
| G3 | Frontend `8090:3000` published, bypasses nginx | compose | any ingress-side control is bypassable | High |
| G4 | MCP uses one shared service credential | pacgate-mcp | per-user deer-flow isolation does not reach firm data | **High** |
| G5 | `PACGATE_MATTER_ID` pinned per container | compose/.env | RAG scope is fixed, not per-conversation/per-matter | **High** |
| G6 | No matter membership; `delete_matter` has no role/owner check | pacgate-api | any tenant user can read/delete any matter | **High** |
| G7 | OpenViking accessed with the ROOT key on `/mcp` | deer-flow + qm | identity not bound to a tenant user; cannot scope | **High** |
| G8 | OpenViking `acl.enabled` off; existing content stays public | OpenViking | shared resources readable account-wide | **High** |
| G9 | Single `OPENVIKING_USER` for all qm traffic | qm `.env` | per-person memory collapses to one space | Medium |
| G10 | `role` (admin/attorney/paralegal/partner) not enforced | pacgate-api | roles are decorative | Medium |
| G11 | Two memory lanes (pacgate matter memory vs OpenViking) unreconciled | both | same fact, two visibilities, no policy | Medium |
| G12 | qm runtime config not staged / outside `-Update` | deploy | allowlist change needs manual `setup-qm.ps1` | Medium |
| **G13** | **`qm up` is impossible from native Windows** — qm's `which()` shells out to POSIX `/bin/sh` | `@yc-software/qm@0.1.4` `dist/src/util.js:255` | the Docker target cannot run on the operator's Windows machines as-is; needs WSL or Git-Bash sh | **High** |
| G14 | No multi-machine sync mechanism exists at all | repo-wide | two AIPCs hold two disconnected brains; team memory cannot work today | **Critical (for teams)** |
| G15 | qm needs 23 required secrets incl. SMTP + `AUTH_ALLOWED_EMAILS`; `.env` absent | `qm check`, `qm doctor` | cannot bring qm up without an email transport and credentials | High |
| G16 | No shared file storage for document bytes across machines | `./data` bind mount | even with a centralised DB, files stay per-machine | High |

**Critical:** G1, G2. **Required before any multi-team use:** G4–G8, **and G14 (the topology decision)**.

---

## 7. Phased plan

Phase boundaries are chosen so each phase is independently shippable and leaves
the system coherent.

### Phase 0 — close the holes (no architecture change)

1. Gate `/register` (mirror upstream `auth.local.allow_registration`, default false).
2. Close the `/initialize` window: installer creates the admin non-interactively,
   or the stack binds to loopback until setup completes.
3. Remove/loopback-bind `8090:3000`. → G1, G2, G3 closed.
4. Prove: `POST /register` → 403 on **both** ports; admin creation works without
   the public window.

### Phase 1 — make identity flow (single-team prerequisite)

5. Pass the deer-flow user identity across the MCP boundary; make `PACGATE_MATTER_ID`
   per-request rather than per-container. → G4, G5.
6. Add `matter_members(matter_id, user_id, role)` and enforce it on matter
   read/write/delete; enforce `role` for destructive ops. → G6, G10.
7. Re-verify the memory lanes still work (the per-matter lane regression test
   from 2026-09-20 is the guard). → protects G11 from regression.

### Phase 1.5 — topology decision and implementation (NEW, inserted 2026-09-21)

Inserted ahead of OpenViking tenancy because scoping is downstream of where data
lives (§5A).

7a. Decide: centralised data plane (A) and/or centralised qm (B).
7b. If B: deploy qm to `fly` or `aws` (native targets) with the portal as the team
    front door; point each AIPC's heavy lane at it. → G14.
7c. If A: point both AIPCs at one `pacgate-db`/`pacgate-api`, and move document
    bytes to shared storage (S3-compatible or a NAS), since `./data` is
    filesystem, not DB. → G16.
7d. Resolve the qm-on-Windows blocker: either run the qm CLI under WSL/`--build-from`
    from Linux, or file the `which()` defect upstream and pin a shim. → G13.

### Phase 2 — OpenViking tenancy (the memory question)

8. Enable multi-tenant mode; create one `account` per firm tenant = `tenants.slug`.
9. Replace the ROOT key with `trusted` mode (`X-OpenViking-Account` /
   `X-OpenViking-User` asserted by our gateway) or per-user keys. → G7.
10. Enable `acl.enabled`, build the matter = `restricted` subtree model, **and
    migrate existing shared content** (it does not migrate itself). → G8.
11. Decide and document the memory-split policy; reconcile the two lanes. → G11.

### Phase 3 — qm as the team surface

12. Prove qm production auth end-to-end (portal sign-in, non-allowlisted refused,
    core rejects unauthenticated) — the acceptance test for the 2026-09-04 dev-mode
    finding.
13. Derive `OPENVIKING_ACCOUNT` from the tenant slug and `OPENVIKING_USER` from
    `ScopeContext.personal_user_id`. → G9.
14. Add `setup-qm.ps1` re-staging to the update path, or document the manual step
    prominently. → G12.

### Phase 4 — product layer

15. Team/matter provisioning UX (who creates a matter, who assigns attorneys).
16. Firm-facing admin surface — note deer-flow has **no** admin user-management
    endpoint in either version, so this is new scope in qm's admin service.

---

## 8. Design decisions this plan commits to

| Decision | Rationale |
| --- | --- |
| deer-flow = single account per AIPC | heavy single-user work; and its isolation is not a firm-data boundary anyway |
| pacgate-api = system of record for matters/documents/workflows | already implemented with tenant+matter scoping |
| OpenViking = long-term/personal memory, not the system of record | its isolation is per-user, which is the wrong shape for firm records |
| `tenants.slug` == OpenViking `account_id` | single shared join key; avoids a mapping table |
| Matter is the ethical boundary in both systems | matches legal practice and both schemas |
| qm is the only multi-user surface | it is the only one designed for it (person/room/team/org + audit) |
| No credential outranks the user it acts for | the invariant broken in three places today |

## 9. Open decisions (need the operator)

1. **Public internet or LAN/VPN only?** Now applies to two front doors. For
   legal-client data this changes TLS, rate limiting, and lockout requirements.
   OpenViking's `trusted` mode also assumes it sits behind a trusted gateway.
2. **Memory-split policy.** What may live in personal (OpenViking) memory vs firm
   records (pacgate-api)? A lawyer's personal note about a client is not the same
   asset as a matter file, and the answer has ethics and retention implications.
   This must be decided before Phase 2 step 11.
3. **Who is the firm's `org_admin`?** And do we hand over the qm admin service, or
   retain it? Affects the Phase 4 admin surface.

## 10. What I could not verify

- **qm production auth has never been demonstrated running** (no qm containers on
  this box; the 2026-09-04 plan recorded dev/cookie mode). Everything in §4.2–4.3
  is from configuration and upstream docs, **not** a live proof. Phase 3 step 12 is
  the gate.
- **OpenViking ACL enforcement was not exercised live.** The semantics in §3.3 are
  from the published docs; our deployment has ACL disabled and a single `default`
  account, so there was nothing to observe.
- **qm's `personal_user_id` → sandbox wiring** was read from
  `pacgate_qm.py`; I did not confirm the value qm actually injects at runtime.

## Appendix — evidence index

| Claim | Source |
| --- | --- |
| Every table NOT NULL `tenant_id`; matter tables add `matter_id` | `pacgate-ai/migrations/001…007` |
| `Claims` has no matter membership | `pacgate-ai/crates/pacgate-auth/src/lib.rs` |
| Matter handlers discard `user_id`; no role check | `pacgate-ai/crates/pacgate-api/src/matters.rs` |
| MCP uses one shared service credential + pinned matter | `deploy/client-bundle/compose.prod.yaml` |
| MCP receives no per-user identity | `deploy/client-bundle/deer-flow-extensions-config.template.json` |
| deer-flow per-user isolation (`owner_id`, `AUTO`, 404, per-user memory) | `deer-flow-src` `backend/docs/AUTH_DESIGN.md` (v2.0.0) |
| deer-flow roles are only admin/user; fine RBAC not implemented | same doc |
| OpenViking `account`/`user` boundaries, unlimited users, ROOT/ADMIN/USER | `docs.openviking.ai/en/concepts/11-multi-tenant` |
| Isolation table (memories private; `resources` shared in-account) | same doc |
| ROOT key cannot access tenant-scoped data APIs | same doc |
| ACL: shared scope only, read/write/manage, inheritance, `acl.enabled` off by default, no auto-migration | `docs.openviking.ai/en/concepts/15-acl` |
| Our ROOT-key usage on `/mcp` | `deer-flow-extensions-config.template.json`; `qm-pacgate/.env.example` |
| Single `default` account in our workspace | `deploy/client-bundle/openviking/workspace/viking/_system/accounts.json` |
| All sessions/tasks stamped `created_by_*: default` | `…/user/default/sessions/*/.meta.json`, `_system/tasks/**` |
| `viking://resources` "globally shared", not account/agent bound | our workspace `viking/default/resources/.overview.md` |
| qm scope model (person/room/team/org; org ceiling; audited; skills by grant) | `github.com/yc-software/qm`; design teardown |
| qm allowlist + link sign-in; org_admin; admin service | `qm-pacgate/.env.example`, `deployment.md`, `qm.config.jsonc` |
| qm channel → pacgate matter via `external_key`; scope written into description | `qm-pacgate/sandbox/tools/pacgate-qm/pacgate_qm.py` |
| `OPENVIKING_ACCOUNT` / `OPENVIKING_USER` are single pinned values | `qm-pacgate/.env.example` |
| Per-matter memory lane API + `If-Match` revisions | `pacgate-ai/crates/pacgate-api/src/matters.rs` (`get/save_matter_memory`) |
| qm dev-mode history and auth restoration task | `qm-pacgate/tasks/plan.md` (2026-09-04) |
