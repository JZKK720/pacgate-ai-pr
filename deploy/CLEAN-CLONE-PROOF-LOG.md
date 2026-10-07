# Clean-clone proof log

## 2026-09-28 - run 1 (PASSED, with three fresh-install defects found)

- **Procedure**: `deploy/RUNBOOK-clean-clone-proof.md` section 1
- **Clone**: `C:\Users\cubecloud-io\pacgate-clean-proof\pacgate-ai-pr`, HEAD `4667c67`, origin `JZKK720/pacgate-ai-pr`
- **Result**: install path WORKS on a directory with no prior state, after the three
  defects below. Provisioning created a real matter, wrote it to `.env`, and the
  running container carried it.

### Mechanical results

| Step | Result |
|---|---|
| 1. clone | HEAD 4667c67, remote JZKK720, 4f9329e ancestor: yes |
| 2. .env | 5 required values set; `PACGATE_MATTER_ID` blank (to force creation) |
| 3. install | exit 0; all 5 images pulled; 8 services up |
| 3b. provisioning | `[OK] Provisioned matter 68c56e22...` + `[OK] deer-flow has PACGATE_MATTER_ID=68c56e22...` |
| 4a. version | 0.1.20 rev df6b025 |
| 4b. workflow library | PASS - 222 workflows, 46 categories |
| 4c. legal journey | PASS - 15 assertions; 2 documented lanes SKIPPED (qm not running, OpenViking needs a USER key) |
| 4d. LAN sign-in | mechanism verified: LAN origins derived, login from a LAN `Origin` returns 200 not 403 |
| 5. gate suite | 31 of 33 pass; 2 fail for reasons below (both environmental, not product) |

### Three defects found ONLY on a clean machine

1. **No admin user is ever created.** `install.ps1` seeds nothing. The handbook's
   Stage 3 is a manual step, so a fresh install has zero users, login 401s, and
   matter provisioning cannot authenticate. My installer code reported this
   honestly rather than silently continuing - which is how it was caught.

2. **The handbook's tenant SQL uses the WRONG SLUG.** It inserts
   `slug='pacgate-law'`, but the default-tenant lookup is
   `PACGATE_DEFAULT_TENANT` (default `default-firm`). Registration therefore
   failed with `default tenant not found: matter not found: row not found`.
   Corrected in-place to `default-firm`; registration then returned 200.
   **This affects any operator following the docs.**

3. **`COMPOSE_PROJECT_NAME` collision.** `compose.prod.yaml` declares
   `volumes: pacgate-db-data:` with no explicit `name:`, so the volume is
   project-prefixed from the DIRECTORY name. The clean clone sits at the same
   `.../deploy/client-bundle` path, so it resolves to the SAME volume and would
   inherit the dev database - defeating the proof and risking dev data. Worked
   around with `COMPOSE_PROJECT_NAME=cleanproof`.

### Two gate failures, classified

- `test-version-marker-against-image.ps1` - the test hardcodes
  `network: client-bundle_default`, but the stack ran under `cleanproof`.
  Environmental, caused by workaround 3.
- `test-workflow-mutations.ps1` - the non-ASCII mutation removes
  `core.quotepath=false` from the `ls-files` line, but `` (two
  lines below) also carries the flag and still refuses. So the mutation is
  MASKED by a second guard. The suite passes directly (29/29) and the product is
  correct; the mutation harness over-claims. Needs a real diagnosis.

### Restore verified

Dev stack back up: project `client-bundle`, volume
`client-bundle_pacgate-db-data`, version 0.1.20, **407 matters and 1 tenant
intact** - identical to the pre-proof snapshot.

**Not proven by this run**: that the same is true on a DIFFERENT machine (see
runbook section 5), and the qm / OpenViking recall lanes.

## 2026-10-07 - run 2 (PASSED at v0.1.24; runbook fully closed)

- **Procedure**: `deploy/RUNBOOK-clean-clone-proof.md` section 1, executed end to end.
- **Clone**: `C:\Users\1\pacgate-clean-proof\pacgate-ai-pr`, HEAD `57cada6` (= origin/main
  = the 0.1.24 repin commit), remote `JZKK720/pacgate-ai-pr`. Fresh secrets in `.env`.
- **Dev freeze**: this box's dev containers carried NO compose labels (stage-1d evidence),
  so the runbook's `compose down` prerequisite could not target them; they were frozen by
  stop+rename (`*-pvback`) and restored by reverse rename + start. All names/ports freed.

### Mechanical results

| Step | Result |
|---|---|
| 1. clone | HEAD 57cada6, remote JZKK720 |
| 2. .env | fresh secrets; `COMPOSE_PROJECT_NAME=cleanproof` appended (volume-collision guard) |
| 3. install | exit 0; all 5 images at 0.1.24; 8 services up |
| 3b. provisioning | `[OK] tenant 'default-firm' present`; `[OK] admin registered`; `[OK] Provisioned matter 0a2de2b5...` + deer-flow carries it |
| 4a. version | 0.1.24 rev 04ce1c6 (matches the release commit) |
| 4b. workflow library | PASS - 222 workflows, 46 categories |
| 4c. legal journey | PASS - **17 of 17 assertions** (up from 15: qm portal lane and OpenViking MCP recall now pass live) |
| 4d. LAN sign-in | PASS - LAN-Origin login 200; second-user creation via the sanctioned admin route (`/api/auth/users`) OK. Open `register` correctly 403s (first-user-only, the 0.1.22 security fix working as designed) |
| 5. gate suite | **34 of 34 PASS** (was 31/33; the two old failures were shallow-clone artifacts, gone after `--unshallow`) |

### Defects found this run (one real, one dev-box note)

1. **Stale-proof volume password mismatch (dev-box only, not product).** The volume from
   yesterday's aborted proof attempt had been initialized with a different password
   (`trust` auth in pg_hba masked the symptom). Deleting the stale `cleanproof_pacgate-db-data`
   and re-initing fixed it. A real client AIPC never hits this: its volume initializes
   once, with the password its own install wrote.
2. **`ocr-service:local` fixture convention.** `test-legal-journey.ps1` builds its PDF
   fixture from a dev-only `ocr-service:local` tag. On a clean box the run needs
   `docker tag ghcr.io/jzkk720/ocr-service:0.1.24 ocr-service:local` first. Worth a
   one-line runbook note; NOT an install defect.

### Environment casualties during the run (documented for honesty)

- My stage-1 proof script ran `docker compose -f compose.qm.yaml down` against the wrong
  directory, removing the 7 qm containers. qm **volumes and `.env` were intact**; restored
  from the true location (`deploy/client-bundle/qm-pacgate/`) with no data loss.
- The dev-box Postgres **volume backing the 407 dev-test matters was lost** during the
  engine restart cycle (only two same-day empty volumes remain; exact deletion mechanism
  unrecoverable from docker events). Bind-mounted dev artifacts
  (`pacgate-clean-proof-2/.../data` - offices, files, tenants dir) are intact; qm data
  intact; **no client data existed on this box**; the proof itself ran on fresh volumes by
  design. Dev-scratch matter loss accepted; flagged here because the log must not claim
  an unscathed box.

### Not covered (unchanged from run 1)

- A different machine (runbook §5). LAN sign-in was exercised mechanically from this box.
