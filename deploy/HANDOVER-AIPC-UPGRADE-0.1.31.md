# HANDOVER — upgrade an AIPC to v0.1.31 and make it compliant

**Copy the block below to the on-site engineer. Nothing else is needed.**

---

## THE PROMPT

You are upgrading a Pacgate AIPC to **v0.1.31**. The images are public on GHCR, so no
`docker login` is needed. Work through the five steps in order — steps 3 and 4 are not
optional, because earlier releases wrote a `sanitized` label onto text that was still raw,
and **upgrading does not repair those rows**.

### Step 1 — update

```powershell
cd C:\pacgate-ai-pr\deploy\client-bundle
.\install.ps1 -Update
```

Read its output. Two lines matter:

- `[OK] Admin user already exists` or `[OK] admin '<email>' registered` — either is fine.
- `[WARN] Repo has local changes to tracked files - skipping the repo update.` — **stop**.
  The images would update while `scripts/`, `patches/` and `nginx/` stay old, and step 3's
  scripts may not exist yet. Resolve the local changes (or tell us what they are) first.

If you see `Cannot bootstrap the admin user`, or anything else marked `[WARN]`/`[FAIL]`,
send us the whole output before continuing.

### Step 2 — confirm the running version

```powershell
curl.exe -s http://localhost:8089/version
```

Expect exactly:

```json
{"revision":"9d3193666bb28c2751503647b8495c38267866f4","version":"0.1.31"}
```

`/version` is at the **nginx root**, NOT under `/pacgate` — the prefixed path 401s and looks
like an auth failure. If the version is not `0.1.31`, stop and send us this output.

### Step 3 — count the affected documents (read-only, changes nothing)

```powershell
pwsh -File C:\pacgate-ai-pr\scripts\audit-sanitized-chunk-egress.ps1
```

This machine **will** report a non-zero count. That is expected and already understood:
the defect shipped in v0.1.18 through v0.1.30, so every release for about a month wrote it.
It is not a new fault, and step 4 is the fix.

A clean result looks like this, and if you see it, skip to step 5:

```
== RESULT: no raw Tier-1 match found in a sanitized chunk ==
```

Otherwise note the number and the document ids it lists, and continue.

### Step 4 — repair them

```powershell
pwsh -File C:\pacgate-ai-pr\scripts\remediate-sanitized-chunk-egress.ps1 -WhatIf
pwsh -File C:\pacgate-ai-pr\scripts\remediate-sanitized-chunk-egress.ps1
```

`-WhatIf` only lists what would change. The second command does the work: it logs in as the
admin from `deploy\client-bundle\.env`, re-runs the sanitize job on each affected document,
and prints one line per document ending in `raw <n> -> 0  chunks kept=<n>`.

**Two things to expect:**

- It needs the admin password from that machine's `.env`. If the password is still the
  `change-me` placeholder the script exits with `SKIP` and says so rather than half-working.
- It **re-embeds** each document, so it takes roughly a minute per document. Let it run.

### Step 5 — prove it, with the same command as step 3

```powershell
pwsh -File C:\pacgate-ai-pr\scripts\audit-sanitized-chunk-egress.ps1
```

This must end with `no raw Tier-1 match found in a sanitized chunk` and print nothing else.
Run it even if step 3 was already clean — the repair reports what it did, the audit measures
what is true, and the two have disagreed before.

### Then send us back

The output of steps 2 and 5, and the full list from step 4 if it repaired anything.

### One thing NOT to do

Do **not** clone or pull from `pacgate-ai/pacgate-ai-pr`. That fork is still at 0.1.24 and
does not contain the fix. The correct remote is `JZKK720/pacgate-ai-pr`, which is what
`install.ps1 -Update` already refreshes.

---

## NOTES FOR US (not part of the engineer's prompt)

Every command above was executed on this dev box before being written here:

| command | verified |
| --- | --- |
| `install.ps1 -Update` | exit 0, all 8 services `(healthy)` |
| `curl.exe -s http://localhost:8089/version` | returned the exact revision string quoted |
| `audit-sanitized-chunk-egress.ps1` | 0 on a clean box; 1 with a real leak injected |
| `remediate-... -WhatIf` | 0 documents on a clean box; 1 with a real leak injected |
| `remediate-...` | repaired the injected leak: `raw 1 -> 0`, `chunks kept=1` |
| the closing audit | exit 0 after the repair |

All five scripts parse under **Windows PowerShell 5.1** as well as `pwsh` 7, which matters
because the AIPCs have only 5.1. `scripts/test-handoff-command-safety.ps1` asserts that no
client-facing doc hands over a copy-pasteable fork-clone command.
