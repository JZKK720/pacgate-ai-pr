# Copilot agent prompt - install and verify Pacgate-ai on the HX370 / 64 GB machine

This is a **prompt**, not documentation. Paste the fenced block below into a
Copilot agent session running on the HX370 machine. It is written to be executed,
not read for background - the human-facing guide is
`deploy/HANDOFF-HX370-64GB-2026-10-20.md`.

Why a separate prompt: an agent on a fresh machine has no session context. It
does not know what was already verified elsewhere, so without explicit limits it
will "helpfully" rebuild images, regenerate configs, or bump a version - all of
which are wrong here. The prompt states the boundaries precisely, and asks for
evidence instead of reassurance.

---

## The prompt

```text
You are installing an already-released product on THIS machine. Your job is to
install it, verify it with the repo's own gates, and report evidence. It is NOT
to modify the product.

TARGET: Pacgate-ai 0.1.34. The images are built, published to GHCR, publicly
pullable, and their baked revision (8adb4818e7e5) matches tag v0.1.34. Nothing
needs rebuilding.

HARD LIMITS - do not do these, even if something looks broken:
  1. Do NOT build, rebuild, retag, or push any Docker image.
  2. Do NOT bump the version, create a git tag, or push to the remote.
  3. Do NOT change the machine-wide Ollama context setting. Ollama here is
     shared with other tools. Context is pinned per model already; if you
     believe you must change a global setting, STOP and ask.
  4. Do NOT edit files under deploy/client-bundle/ except .env. If a check
     fails, report it - do not patch around it.
  5. Do NOT copy files from any other machine.

STEP 1 - get the code
  git clone https://github.com/JZKK720/pacgate-ai-pr.git C:\pacgate-ai-pr
  cd C:\pacgate-ai-pr
  git log --oneline -1
You are on main, NOT a tag checkout. That is deliberate: the tag predates the
pre-flight script. Confirm the image pins are 0.1.34:
  Select-String -Path deploy\client-bundle\compose.prod.yaml -Pattern 'image: ghcr.io/jzkk720'
All five must read :0.1.34. If they do not, STOP and report.

STEP 2 - pre-flight (read-only)
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\preflight-install.ps1
Run it with whatever PowerShell this machine has. If `pwsh` exists use it,
otherwise `powershell` (Windows PowerShell 5.1) - both are supported. Do NOT
install PowerShell 7 just to run these scripts.
It exits 1 if anything is a blocker. Report its FULL output.
Two things in that output need your judgement, not a fix:
  - The hardware tier line. Record the OS-visible RAM, the discrete VRAM, and
    the tier it selected. This machine is 64 GB with a 16 GB RX 7600 XT, so the
    EXPECTED tier is "big-ram-small-vram" (ctx 32768, 2 resident models). If it
    selects something else, report that as a finding with the numbers - do not
    adjust anything to force it.
  - Any port that is already listening. If a previous Pacgate stack is running,
    ask before stopping it.

STEP 3 - prepare .env
The installer REQUIRES deploy/client-bundle/.env and will not create it.
  cd deploy\client-bundle
  copy .env.example .env
Fill in these three with strong generated values (any long random string):
  PACGATE_DB_PASSWORD
  PACGATE_JWT_SECRET
  PACGATE_API_PASSWORD
Also check OPENVIKING_ROOT_API_KEY. If it is still "change-me", OpenViking will
boot-loop on /health 503. Replace it with a strong value.
Do not print the secret values in your summary. Say which keys you set and that
.env is gitignored and stays on this machine.

STEP 4 - install
  cd C:\pacgate-ai-pr\deploy\client-bundle
  .\install.ps1
This takes a while (image pulls plus model downloads) and it restarts Ollama
once. Let it finish. Capture the output.

STEP 5 - verify (this is the acceptance bar, not a formality)
  cd C:\pacgate-ai-pr
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\run-all-checks.ps1
This launcher picks pwsh when present and falls back to `powershell` itself -
do not hand-pick the shell for it.
On the authoring machine this reports "ALL 45 GATES PASSED". Expect the same.
A gate that fails here is a REAL finding about this hardware - report it with
its full output. Do not re-run until green, and do not edit the gate.

Then these targeted checks, and report each result (same shell form):
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test-aipc-capacity-fit-strict.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test-ollama-context-scope.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test-cross-stack-credentials.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test-lane-connectivity.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test-origin-coherence.ps1

STEP 6 - prove the model context is the one the machine chose
  ollama ps
After a workflow run, report the CONTEXT column for whichever local models
loaded. Pacgate no longer creates derived tags: there is no pacgate-mid or
pacgate-low to look for, and a run that shows the BASE tags is the expected
result, not a failure.

Expected on a 32 GiB-or-more machine: the base tags (ornith-1.5:9b and/or
gemma4:12b-it-qat) load at ctx 32768. If they load at 131072 with a large KV
allocation instead, the installed OLLAMA_CONTEXT_LENGTH or the per-model pin
in deer-flow-config.yaml did not apply - report it.

Do NOT run `ollama create`, and do not expect derived tags. That mechanism was
removed on 2026-10-21 because the tags existed in no published image, could not
be pre-pulled, and split one model into two residency names that evicted each
other (measured 15.9 s / 15.4 s reloads). A leftover pacgate-mid / pacgate-low
on a machine that was upgraded rather than freshly installed is harmless: it is
unused and shares its blobs with the base tag, so it costs no disk.

Also confirm the shared app setting was NOT changed by reading it, not by
changing it:
  ollama ps   (and report the CONTEXT column values)

STEP 7 - report
Give me:
  - hardware: OS-visible RAM, discrete VRAM, selected tier
  - .env: which keys you set (never the values)
  - install: exit status, and the count of models pulled
  - gates: the exact final line from run-all-checks (e.g. "ALL 45 GATES PASSED")
    plus every failing gate verbatim if any
  - ollama ps: the CONTEXT column for whatever local model loaded
  - anything that surprised you, stated plainly

Rules for the report:
  - Quote real command output. Do not say "should work" or "looks good".
  - If a step failed, say what failed and STOP rather than working around it.
  - If you had to make a judgement call, say so and say which.
  - Do not claim success for a step you did not actually run.

If you get stuck: the human-facing guide is
deploy/HANDOFF-HX370-64GB-2026-10-20.md, and it documents the expected hardware
tier, why context is pinned per model, and the rollback path. Ask rather than
guess on anything that mutates state.
```

---

## Notes on why the prompt is shaped this way

- **The limits come first**, because the highest-risk failure is an agent
  "fixing" a red gate by rebuilding or editing around it, which would produce a
  machine running artifacts nobody published.
- **Step 6 exists** because the context pin is the one thing that silently fails
  in a way that still looks like success - the model loads, inference works, and
  only `ollama ps` reveals it is using twice the memory budgeted.
- **The expected tier is stated as an expectation, not a target.** If the HX370
  reports something else, that is a finding about the hardware, and an agent
  told to "make it match" would silently paper over the very thing the
  deployment is meant to reveal.
- **No step says "make tests pass".** It says run them and report. Nothing in
  this install path legitimately requires editing the product.
