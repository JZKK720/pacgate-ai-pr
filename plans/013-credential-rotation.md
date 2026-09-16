# 013 — Credential Rotation and History Purge

Priority: **P0 — do this before anything else** · Effort: **S–M** · Depends on: —

## Status

Redaction is **done and pushed to origin**. The fork is a **one-click fix** (see
below) — no credential transfer needed. Rotation and history purge are
**outstanding**.

## Push state (verified 2026-09-16)

| Location | State |
| --- | --- |
| Local `HEAD` (`af8438c`) | redacted |
| `origin/main` (`JZKK720`) | **redacted — pushed and verified** |
| fork `main` (`pacgate-ai`) | **STILL LIVE — but fixable without credentials** |

## Recommended fix for the fork: GitHub's Sync fork (no git credentials)

`git push` to the fork fails with `permission denied` because
`git-credential-manager` holds credentials for **`JZKK720` only** (confirmed via
`git-credential-manager github list`). **No credential needs to be transferred to
git** — the fork is a strict ancestor of `origin/main`, so it can be
fast-forwarded from the browser:

1. Sign in to GitHub **in the browser** as an account with write access to
   `pacgate-ai/pacgate-ai-pr` (its owner is the `pacgate-ai` account).
   *"Sync fork" is only rendered for users with write access* — it is not visible
   signed-out, so this step is required.
   **Use the rotated password, not the leaked one** (see Step 1).
2. Open `https://github.com/pacgate-ai/pacgate-ai-pr`.
   GitHub reports *"This branch is 9 commits behind JZKK720/pacgate-ai-pr:main"*.
3. Click **Sync fork → Update branch**.

Verified preconditions — GitHub's own compare view states *"Able to merge. These
branches can be automatically merged."*:

| Check | Result |
| --- | --- |
| fork `main` is an ancestor of `origin/main` | **yes** |
| fork has commits origin lacks (would block non-FF) | **none** |
| GitHub compare verdict | **Able to merge** (fast-forward) |
| all three credential files redacted at `origin/main` | **yes** |
| workflow fix present at `origin/main` | **yes** |

Then re-run `scripts/check-credential-state.ps1` — all three columns must read
`clean`.

> **Do NOT sign in to git (or GitHub) using the leaked password.** The value is
> compromised; rotate first, then sign in with the new one.

**Fallback** (only if you prefer git, requires interactive sign-in):

```powershell
git credential-manager github login            # sign in as the pacgate-ai account
git push https://github.com/pacgate-ai/pacgate-ai-pr.git main
git credential-manager github logout JZKK720   # return to the original account
```

## Why this is P0

On 2026-09-15 a credential sweep found three tracked files holding **real,
working credentials** in a **public** repository. Redacting them stops *new*
exposure from fresh clones of `HEAD`. It does **not**:

- undo the exposure that already happened,
- remove the values from git history, or
- remove them from every existing clone (both AIPCs have one).

**Treat every value below as compromised. Rotation is mandatory, not optional.**

## What was exposed

| File | Exposed material |
| --- | --- |
| `pacgate-ai/pacgate-ai-assets/…/pacgate-ai-remote-handbook/OPERATOR.md` | `pacgate-ai` GitHub account email, ID, and plaintext password |
| `pacgate-ai/pacgate-ai-assets/…/MCP授权/法律数据库MCP.md` | Legal-portal unified login + password (chineselaw / pkulaw / qcc) |
| `pacgate-ai/pacgate-ai-assets/…/MCP授权/境外法律数据库和网站.md` | CourtListener, Vaquill, EUR-Lex, Ansvars, fyopen passwords **and two API keys** |

All three were present on both `origin/main` (`JZKK720`) and fork `main`
(`pacgate-ai`), both public, introduced by `01a4644` (2026-08-13).

## Done already (2026-09-15/16)

- All 10 credential-bearing lines **redacted** in place; markdown tables left
  structurally intact so they still render.
- `OPERATOR.md`'s false claim *"This file is gitignored"* corrected, and its
  "look up the value in the table above" instruction repointed at the password
  manager.
- Root `.gitignore` hardened with a credential-hygiene block. Note the
  `pacgate-ai-assets` subtree previously had **no** guard at all.
- Repo-wide re-scan returns **CLEAN** (no literal credential values in tracked
  text files).
- Redaction pushed to `origin` and verified by reading the remote blob, not by
  trusting the push.

## ⚠️ Sequencing: do the GHCR release BEFORE the history rewrite

The two outstanding items interact, and the order matters:

1. **First, sync the fork** (one click, above) and **fire the GHCR release**
   (`plans/011` / `012`). The workflow fix now lets CI go green, and this is the
   first release carrying the `.docx` and search fixes.
2. **Then rotate and rewrite history.**

Why this order: the release publishes **image tags**, not commits. A force-push
rewrite after the release does not invalidate published tags, so clients keep
pulling the same images. Doing it the other way round means rebuilding and
re-tagging a release immediately afterwards.

Evidence this is safe: the currently published images carry **no**
`org.opencontainers.image.source` label (they predate the provenance labels
added in `48eb8c1`), so no package is bound to a specific commit. Even so,
**verify pullability after any force-push** before relying on it:

```powershell
.\scripts\check-ghcr-pull.ps1 -Targets "pacgate-ai/pacgate-api:0.1.9","pacgate-ai/pacgate-mcp:0.1.9","pacgate-ai/deer-flow-pacgate:0.1.10","pacgate-ai/deer-flow-frontend-pacgate:0.1.11"
```

## Step 1 — Rotate (do this first)

Rotation must precede the history purge: the purge removes the values from
history, but anyone who already cloned has them.

| Credential | Action |
| --- | --- |
| `pacgate-ai` GitHub account password | Change it. Then review **github.com/settings/applications** and revoke every OAuth grant — the file itself warned that Tailscale and others were authorised through this account. |
| CourtListener API token | Regenerate in the account settings. |
| Vaquill API key | Rotate in the Vaquill dashboard. |
| EUR-Lex / Ansvars / fyopen / chineselaw / pkulaw / qcc | Change passwords; use a password manager, never a repo file. |

Also review whether the exposed account had access that should be narrowed, and
check for unexpected activity on the `pacgate-ai` account since 2026-08-13.

**Good news:** GHCR images are pulled **anonymously**, so neither the password
rotation nor revoking OAuth grants affects client installs or the image
packages. Package visibility is governed separately.

## Step 2 — Purge history

Both repos need this, and the rewrite is **destructive** — coordinate first.

```powershell
# Install once: pip install git-filter-repo
git filter-repo --invert-paths `
  --path "pacgate-ai/pacgate-ai-assets/pacgate-ai/assets/assets/pacgate-ai-remote-handbook/OPERATOR.md" `
  --path "pacgate-ai/pacgate-ai-assets/pacgate-ai/assets/assets/智库资料收集/智库资料收集/MCP授权/法律数据库MCP.md" `
  --path "pacgate-ai/pacgate-ai-assets/pacgate-ai/assets/assets/智库资料收集/智库资料收集/MCP授权/境外法律数据库和网站.md"
```

Then force-push **both** remotes and tell anyone with a clone to re-clone rather
than pull. A rewrite changes every commit hash from `01a4644` onward.

Before publishing this, consider whether the whole `pacgate-ai-assets/` subtree
(59 files of client business material) belongs in a public repo at all. Removing
three files fixes this incident; a subtree that was never intended for the public
eye is the underlying condition.

## Step 3 — Prevent recurrence

- [ ] The `.gitignore` hygiene block is in place (done).
- [ ] Add a CI secret scan (`gitleaks` or GitHub secret scanning) so a future
      leak fails the pipeline instead of reaching `main`.
- [ ] **Extend the audit method.** The 2026-09-01 public-flip audit cleared this
      repo while all three files were present. It searched token *literals*
      (`sk-`, `ghp_`, `AKIA`, `xox`, PEM, Bearer) and never matched
      password-shaped prose or markdown tables. My own first generic scanner
      missed them the same way. A publish-readiness audit must cover:
      - CJK credential keywords — `密码` / `密钥` / `账号` / `账户` / `统一登录`
      - markdown **table** credential rows, not just `key: value`
      - filenames announcing secrets — `OPERATOR.md`, `*授权*`, `*密钥表*`
      - **the whole history**, not just `HEAD`
- [ ] Run `scripts/detect-literal-credentials.ps1` before any visibility change.

## Verification

```powershell
# Must print CLEAN
pwsh -NoProfile -File .\scripts\detect-literal-credentials.ps1

# Confirm the three files are gone from history
git log --all --oneline -- "**/OPERATOR.md" "**/法律数据库MCP.md" "**/境外法律数据库和网站.md"

# Confirm the repos still serve images (rotation must not break this)
.\scripts\check-ghcr-pull.ps1 -Targets "pacgate-ai/pacgate-api:0.1.9"
```

## Definition of done

- Every credential in the table above is rotated.
- OAuth grants on the `pacgate-ai` account reviewed and pruned.
- Both repos rewritten and force-pushed; collaborators advised to re-clone.
- `git log --all` no longer finds the three files.
- A secret-scanning gate exists so the next one fails CI.
- Decision recorded on whether `pacgate-ai-assets/` stays public.
