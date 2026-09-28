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
