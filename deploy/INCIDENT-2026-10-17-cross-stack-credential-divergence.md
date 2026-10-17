# Incident 2026-10-17 — cross-stack credential divergence (qm 401 against pacgate-api)

**Status:** root cause found and proven; guard added; live remediation **not applied** (see §6)
**Severity:** high — qm's pacgate tools cannot authenticate; silent, and invisible to the whole test suite
**Affected:** every machine where the two `.env` files were set up or edited independently

## 1. Symptom

Reported as "qm-pacgate cannot propagate the correct pacgate-api and pacgate-mcps". The
concrete failure is narrower and worse than "propagation": **the credential the QM stack holds
is not the credential the Pacgate API accepts.**

## 2. Root cause

The deployment is **two compose projects rooted at two directories**, so it has **two
independent `.env` files**:

```
deploy/client-bundle/.env              <- pacgate-api, deer-flow, nginx, pacgate-db, pacgate-mcp
deploy/client-bundle/qm-pacgate/.env   <- qm core/portal/auth/web-ui/admin
```

Confirmed from the live stack, not from reading:

```
docker inspect pacgate-api      -> working_dir = C:\...\deploy\client-bundle
docker inspect qm-pacgate-core  -> working_dir = C:\...\deploy\client-bundle\qm-pacgate
```

Four variables appear in **both** files:

| key | role |
| --- | --- |
| `OPENVIKING_ROOT_API_KEY` | shared |
| `OPENVIKING_API_KEY` | shared |
| `PACGATE_API_EMAIL` | qm bridge account identity |
| `PACGATE_API_PASSWORD` | qm bridge account secret |

They are shared **by value**, not by reference. No compose file shares an `env_file`, no
script synchronises them, and they are separate blobs on disk. Three of the four still agree;
**one diverged:**

```
client-bundle/.env            PACGATE_API_PASSWORD = 16 chars
client-bundle/qm-pacgate/.env PACGATE_API_PASSWORD = 24 chars
live qm-pacgate-core (FLY_RESIDENT_ENV_PACGATE_API_PASSWORD) = the 24-char value
```

### Proof, not inference

POSTing each value to `http://localhost:8089/pacgate/api/auth/login` with the shared email:

| value tried | result |
| --- | --- |
| the 16-char value (`client-bundle/.env`) | **200 OK** + a 283-char JWT |
| the 24-char value (qm's) | **401 Unauthorized** |

So `qm-pacgate-core` is holding a credential that the account does not have. The 24-char value
is definitively the wrong one — the account was created with the 16-char value.

### Why it happened — a code defect, not a slip

`deploy/client-bundle/setup-qm.ps1` obtains the bridge password from a **parameter or an
interactive prompt**:

```powershell
$bridgeEmail = if ($BridgeEmail) { $BridgeEmail } else { Read-Host "Enter the Pacgate bridge service-account email ..." }
...
if ($BridgePassword) { $plainPassword = $BridgePassword }
else { $bridgePassword = Read-Host "...password" -AsSecureString; ... }
...
PACGATE_API_PASSWORD=$plainPassword      # written into qm's .env
```

It **never reads the credential the Pacgate stack is already using.** The value is retyped by
hand at setup time, into a different file, and nothing ever reconciles the two. Any later
change on either side strands the other.

Re-running `setup-qm.ps1` does **not** heal it, and this is the nastiest part: its login probe
(line ~482) tests the **new** value against the **old** account, fails, attempts creation, hits
the unique-constraint duplicate, re-probes, and then reports:

> `[WARN] bridge account creation failed and login does not match - the first sandbox tool call will 401.`
> `[WARN] Fix: reset the bridge password in pacgate-api, or update qm's .env PACGATE_API_* ...`

That is a **warning**, and the script exits successfully. The operator is told to fix a
credential by hand, and the state persists.

## 3. Why nothing caught it

This is the important part, and it is why the fix is a guard rather than a patch.

- **The 39-gate suite stayed green throughout.** Every existing test drives `pacgate-api` and
  authenticates with `PACGATE_API_PASSWORD` read from `client-bundle/.env` — the *working*
  value. **No test crossed the stack boundary.** The one broken edge was outside every test's
  field of view.
- **Everything reports healthy.** qm's portal, auth, web-ui, admin and Postgres all work.
  qm's OpenViking access works (those keys agree). All containers show `healthy`.
- **The failure is at the far end of a chain.** Only a pacgate tool called *from inside a qm
  sandbox* fails, and that requires a sandbox run to reach.
- **The stale value looks legitimate.** 24 chars, random-looking, sitting in a gitignored file
  that nothing in the repo compares against anything.

A prior handoff in this repo (`HANDOFF-AIPC-0.1.17.md:106`) already warns that
`PACGATE_API_PASSWORD` must be set "by hand". That is the same trap: a manual step with no
verification and no reconciliation.

## 4. Blast radius

Any qm harness task that calls the Pacgate API or the Pacgate MCPs from a sandbox:
document generation, matter lookups, workflow execution — i.e. the Pacgate tools that
motivate running qm alongside the Pacgate stack at all. The sandbox receives the stale value
via `FLY_RESIDENT_ENV_*` passed through as `docker run -e` (see
`qm-pacgate/patch/local-sandbox.ts:360`).

Not affected: qm's own portal/auth/admin, its Postgres store, its OpenViking access, and the
whole Pacgate stack itself.

## 5. Fix applied

`scripts/test-cross-stack-credentials.ps1` (new), registered in `run-all-checks.ps1` as a
**gate**:

- **C1** — every key present in both `.env` files must have an identical value. This is the
  defect, and it fails today.
- **C2** — each stack's live container must agree with its own `.env` (catches "file fixed,
  container never recreated"). Advisory.

Values are never printed — only a truncated SHA-256 and a length. A guard for a credential bug
must not leak the credential while reporting it, and this workspace already had one incident
where env values reached the output (`INCIDENT-2026-10-04-qm-sandbox-env-printed.md`).

Exits 2 (CANNOT CHECK) on a fresh clone, where neither file exists by design.

### Suite state

Verified on the assembled stack: the gate is **green**, and so are all 39 other gates and all
9 live-stack gates. The red state that existed between finding this and fixing it is described
in §6 — a guard that stays green until someone gets round to fixing the thing it guards would
have hidden this exactly as long as it already hid.

## 6. Remediation — applied

The correction was mechanical and both values were known, so nobody had to guess.

### 6a. File fixed

`deploy/client-bundle/qm-pacgate/.env` — `PACGATE_API_PASSWORD` set to the value from
`deploy/client-bundle/.env` (the 16-char one, proven to return 200). Written in place,
preserving the file's exact shape:

- no BOM (verified byte-wise — docker compose interpolates a BOM into the first key)
- all 25 CRLF preserved, zero bare LF
- exactly one line changed; a backup exists at `.env.bak-<timestamp>`

### 6b. Container recreated

The running container keeps the environment it was **created** with, so the file change alone
was not enough — and the guard's C2 check caught precisely that, reporting the live tag as
still stale after the file was correct:

```
[warn] qm-pacgate-core : live tag B4F78082D9AB != qm.env tag 75A89B45CC55
        - the container was created before the file changed; recreate it to apply
```

Recreated with `--no-deps` so only `core` was disturbed; the other six qm containers kept
running:

```
cd deploy/client-bundle/qm-pacgate
docker compose -f compose.qm.yaml up -d --force-recreate --no-deps core
```

Verified after: `/healthz` returns 200, restart count 0, and C1 + C2 both green.

### 6c. Root cause closed

`setup-qm.ps1` now **verifies the bridge credential before writing it**, and refuses to write a
credential the API rejects. Previously it wrote whatever was typed and only probed afterwards,
where a failure was a `[WARN]` with a successful exit — which is how a value that authenticated
with nothing got persisted in the first place.

The guard was red-checked against the incident's own recovered value:

| case | result | exit |
| --- | --- | --- |
| the incident's 24-char value | REJECTED 401 → would stop | 1 |
| the working value | VERIFIED → would proceed | 0 |
| unreachable API | INCONCLUSIVE → warns, does not block | 0 |

The middle two matter as much as the first: a wrong-password check that also blocks on a
transient network failure would make setup unusable, and the probe is deliberately a read-only
login so the existing account-provisioning path (and its 403 reasoning) stays accurate.

**Note on direction of the fix.** §6a is a *synchronisation*, not a statement about which value
is "correct" in general. The durable model is for both files to derive from one source; until
then, the guard makes divergence un-ignorable and setup refuses to create it.

## 6d. A separate finding that this fix did NOT address

Worth its own note, because the fix above makes it *work* rather than *right*.

`qm-pacgate/.env` sets `PACGATE_API_EMAIL=admin@pacgate-law.com` — the **deployment's own admin
account**. But `setup-qm.ps1` (see its "THE BRIDGE IS A SEPARATE, LEAST-PRIVILEGE SERVICE
ACCOUNT" comment) and the client-facing docs (`README-client.md`, `QM-BRINGUP-RUNBOOK.md`,
fifteen files in total) all specify a dedicated **bridge service account**,
`qm-bridge@pacgate.local`.

Probed on the live stack:

| account | result |
| --- | --- |
| `admin@pacgate-law.com` + the working password | **200** |
| `qm-bridge@pacgate.local` | 401 |
| `qm-bridge@pacgate-law.com` | 401 |
| `bridge@pacgate-law.com` | 401 |

**No bridge account exists**, so the deployment runs its sandbox under the admin identity. The
sandbox is the least-trusted lane in the stack — it executes model-directed tool calls — and
the script's own comment argues it should not hold the same principal as the install path.

Deliberately not changed here: which account the bridge uses is a security-posture decision, and
the credential divergence had to be fixed regardless of it. Creating a least-privilege bridge
account and repointing qm's `.env` at it is the recommended follow-up, and the new verification
in §6c makes that change safe to make (a wrong value will now be refused rather than persisted).

## 7. Lesson

A green suite proves nothing about a surface it does not touch. This deployment has a
**stack boundary**, and for as long as it has existed nothing tested across it. The
`FLY_RESIDENT_ENV_*` prefix is a hint that a value is *copied* across that boundary at setup
time — copied, not referenced — and copies drift.

The second lesson is about ordering. The old flow **wrote first and verified later**, and its
verification failure was a warning. So the system could persist a broken credential, report
success, and leave the repair to a human reading a line of yellow text. Verifying before the
write cost one HTTP call and converts that into a hard stop. When a setup step both *decides* a
value and *tests* it, the test belongs before the decision is committed.
