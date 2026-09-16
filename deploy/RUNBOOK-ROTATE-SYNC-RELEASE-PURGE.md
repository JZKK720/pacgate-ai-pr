# RUNBOOK — rotate → sync fork → release → purge

**One page, in order.** Each step states who must do it, why the order matters,
and how to verify. Companion detail: `plans/013` (credentials) and `plans/012`
(namespace/release).

## Reality check: which steps can a human or an agent do?

| Step | Needs | Agent can? |
| --- | --- | --- |
| 1. Rotate | Account sign-in + new secrets | **No** — secrets must never route through an agent |
| 2. Sync fork | GitHub browser session with write access | **No** — session is signed out |
| 3. Fire release | Repo write access (Actions dispatch or tag push) | **No** — same access |
| 4. Purge history | fork write access; destructive | **No** — and it should not run unattended |

**No step is autonomous.** Three require credentials or account authority that an
agent must not hold, and step 4 is destructive and irreversible from this side.
The tooling below exists so each step is *fast and verified*, not so it is
unattended.

### Assisted mode: you sign in, a script does the clicking

For steps 2 and 3 there is a middle path that avoids moving any credential
between accounts. You sign in to the browser by hand; a script drives the UI and
then **verifies the result from the page** rather than trusting the click.

```powershell
# Browsers are already cached by the VS Code Playwright integration.
$env:PLAYWRIGHT_BROWSERS_PATH = "$env:LOCALAPPDATA\ms-playwright"

python scripts/sync-fork-via-ui.py                    # step 2
python scripts/dispatch-release-via-ui.py --tag 0.1.12  # step 3
```

Both refuse rather than guess:

- they verify the signed-in login and stop if it is not the fork owner
  (GitHub only renders "Sync fork" for accounts with write access);
- the sync script refuses to click **"Discard commits"**, which would destroy
  fork-only work;
- the dispatch script **reads the fork's workflow first** and refuses to dispatch
  if the OCI `Accept` fix is absent — dispatching on an un-synced fork starts a
  run doomed to fail at the verify step.

Neither types a password, and neither reads or stores a credential.

Verify the helpers themselves (signed-out pages only, changes nothing):

```powershell
python scripts/test-sync-fork-helpers.py     # 6/6 passing
```

Steps 1 and 4 remain fully manual — step 1 because secrets must not pass through
an agent, step 4 because it is destructive.

---

## Step 1 — Rotate

**Do this first.** Rotation must precede the history purge: the purge clears
history, but anyone who already cloned has the values.

| Credential | Action |
| --- | --- |
| `pacgate-ai` GitHub password | Change it. Then review **github.com/settings/applications** and revoke OAuth grants — the leaked file warned Tailscale and others were authorised through this account. |
| CourtListener API token | Regenerate. |
| Vaquill API key | Rotate in the Vaquill dashboard. |
| EUR-Lex / Ansvars / fyopen / chineselaw / pkulaw / qcc | Change passwords; store in a password manager. |

Also review what the account could reach and check for activity since 2026-08-13.

> **Do not sign in to git or GitHub with the leaked password.** Rotate, then use
> the new one.

**Verify:** you can sign in to the `pacgate-ai` account with the new password, and
old sessions/OAuth grants are gone.

---

## Step 2 — Sync the fork

The fork is missing the redaction **and** the CI fix, so this step unblocks both
step 3 and the fork's half of the exposure.

1. Sign in to GitHub **in the browser** as an account with write access to
   `pacgate-ai/pacgate-ai-pr` (owner: the `pacgate-ai` account).
   *"Sync fork" only renders for users with write access* — it is absent
   signed-out, which is why this is manual.
2. Open <https://github.com/pacgate-ai/pacgate-ai-pr>
3. **Sync fork → Update branch**

Why this works without git: the fork is a strict **ancestor** of `origin/main`
and holds nothing origin lacks. GitHub's compare view says *"Able to merge. These
branches can be automatically merged."*

**Verify:**

```powershell
.\scripts\check-credential-state.ps1     # all three columns must read "clean"
```

---

## Step 3 — Fire the release

Path **A** (keep the `pacgate-ai` namespace). Prerequisite: step 2.

1. Bump every pin together — this is automated because a missed pin silently
   points a client at an old image:

   ```powershell
   .\scripts\bump-release-version.ps1 -To 0.1.12 -Preview   # show what changes
   .\scripts\bump-release-version.ps1 -To 0.1.12            # apply + self-verify
   ```

   Then commit and push the bump to `origin`.

2. Build and publish, from the fork:

   ```text
   https://github.com/pacgate-ai/pacgate-ai-pr/actions/workflows/build-ghcr.yml
     -> Run workflow
        tag       = 0.1.12
        namespace = (leave empty -> resolves to pacgate-ai)
   ```

   A tag push also works but needs fork write access, which git currently lacks.

3. **⚠️ Flip the new packages to public.** This is the step most likely to be
   forgotten. `pacgate-ai` is a **user account**, and package visibility is
   **UI-only** for user accounts — the `PATCH .../visibility` API returns 404 even
   with `write:packages`. Until flipped, clients cannot pull anonymously.

   GitHub → profile → Packages → each of `pacgate-api`, `pacgate-mcp`,
   `deer-flow-pacgate`, `deer-flow-frontend-pacgate` → Package settings →
   Visibility → **Public**.

**Verify (all four must be 200):**

```powershell
.\scripts\check-ghcr-pull.ps1 -Targets `
  "pacgate-ai/pacgate-api:0.1.12","pacgate-ai/pacgate-mcp:0.1.12", `
  "pacgate-ai/deer-flow-pacgate:0.1.12","pacgate-ai/deer-flow-frontend-pacgate:0.1.12"
```

This release is the first to carry the `.docx` conversion fix (`ece697f`) and the
`hnsw` search fix (`150db2c`); the prior `0.1.9` pins shipped both defects.

**Then** update the client bundle to the new tag and record it in
`plans/007-delivery-log.md`.

---

## Step 4 — Purge history

Only after step 3: a rewrite does not invalidate published **tags**, so the
release stays pullable, whereas reversing the order means rebuilding immediately.

```powershell
.\scripts\purge-credentials-from-history.ps1                  # dry run: blast radius
.\scripts\purge-credentials-from-history.ps1 -Apply            # rewrite locally
```

The script refuses to run on a dirty tree, confirms all three files are redacted
at HEAD, tags a local safety point (`pre-purge-<sha>`), and verifies afterwards
that the paths are gone from history.

Then force-push **both** remotes and tell everyone with a clone to **re-clone**,
not pull:

```powershell
git remote add origin https://github.com/JZKK720/pacgate-ai-pr.git   # filter-repo removes remotes
git push --force-with-lease origin main --tags
git push --force-with-lease https://github.com/pacgate-ai/pacgate-ai-pr.git main --tags
```

**Verify:**

```powershell
git log --all --oneline -- "**/OPERATOR.md" "**/法律数据库MCP.md" "**/境外法律数据库和网站.md"
# expect: no output

.\scripts\check-ghcr-pull.ps1 -Targets "pacgate-ai/pacgate-api:0.1.12"
# expect: HTTP 200  (proves the rewrite did not orphan the packages)
```

---

## Why this order

**Rotate → sync → release → purge.** Two constraints force it:

1. **Rotation before purge.** Purging history does not un-leak a value that is
   already public; only rotation does.
2. **Release before purge.** Publishing happens by tag, and a rewrite does not
   invalidate tags — but rewriting first would invalidate the commit the release
   was cut from, so you would rebuild straight after.

## Remaining decision

Namespace path **B** (move to `jzkk720/*`) is still open. Path **A** above is the
one that works today. Path B additionally requires re-pinning all compose files
and repeating the visibility flip on the personal account. See `plans/012`.
