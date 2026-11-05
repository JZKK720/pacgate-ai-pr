# Machine-local picker entry: nemotron-3.5-bolt:74b-a9b-iq2

Written 2026-11-05. This describes files that are **gitignored on purpose** and exist only on
this machine. Nothing here is part of the shipped client contract.

## The premise this corrects

The question was whether we could add the 74B to the picker *instead of baking it into an image
build*. Two things are already true, and they change the shape of the answer:

- **Nothing bakes a model into an image.** `deploy/deer-flow-pacgate/Dockerfile` only
  `COPY`s `config.yaml`; Ollama weights live in the host store and reach the container over
  `host.docker.internal:11434`. Enabling this model needs no build, no rebuild, and no image tag.
- **The 74B entry already existed**, commented out, in the tracked
  `deploy/client-bundle/deer-flow-config.yaml`, with the enable steps written beside it.

So the only real question was *where* to activate it. Not *whether to build*.

## Why it cannot go in the tracked config

`audit-model-tags.ps1` and `test-model-picker-e2e.ps1` both require every **active** picker entry
to be listed in `deploy/client-bundle/ollama-models.txt`. That file is the **client pre-pull
contract**: `install.ps1` fetches every tag in it on every AIPC. Adding the 74B would make each
client download 24.8 GB for a model `scripts/test-aipc-capacity-fit.ps1` records at 24.0 GB
against a **16 GB** client card - the exact configuration the repo measured paging ~20 GB from
disk per token (278.0 s vs 22.3 s, 12.5x).

Uncommenting in the tracked file is therefore how you break clients, not how you enable a
machine.

## The hard constraint: this model only fits a Ryzen AI MAX+ 395 class machine

The two hardware classes in this project are **not both capable**, and the difference is not
RAM - it is where the weights can live:

| | Client AIPC (the shipped class) | This machine |
|---|---|---|
| CPU | Ryzen AI **HX370** | Ryzen AI **MAX+ 395** |
| GPU | Radeon **RX 7600 XT**, discrete | Radeon **8060S**, unified-memory iGPU |
| VRAM | **16 GB dedicated** (the gate budgets raw 16) | **96 GiB UMA carve-out** (`qwMemorySize`) |
| 74B at 24.0 GB | **150% over-cap** -> spills, ~278 s per tool chain | fits in the carve-out; 2.8 GB resident as `ollama ps` reports it |

`test-aipc-capacity-fit.ps1` budgets the **client** class at `$AipcVramGB = 16`; 24.0 GB is over
1.0x, i.e. `OVER_CAP`. So this entry must never be active in the shipped config: on an HX370 it
loads, spills roughly 20 GB to disk, and evicts whatever chat was already warm.

Do not read "32 GB of RAM" as the qualification. OS-visible RAM is not the binding resource for
a unified-memory APU - on this box Windows reports **31.6 GiB** while the iGPU holds a 96 GiB
carve-out taken before the OS boots. The accurate statement is the machine class: **Ryzen AI
MAX+ 395 with a Radeon 8060S iGPU**. A dedicated-VRAM card of similar size would qualify too;
an HX370 / RX 7600 XT client would not, whatever its DIMM count.

## What is on this box

| File | Tracked? | Purpose |
|---|---|---|
| `deer-flow-config.local.yaml` | **no** (gitignored) | Byte-for-byte the tracked config, except the 74B block is uncommented in place. Same position: not first, not an escalation target. |
| `compose.local-model-override.yaml` | **no** (gitignored) | Rebinds only `deer-flow` → `/app/backend/config.yaml` to the file above. |
| `.gitignore` entries | yes | The two paths above, so a `git add -A` cannot publish them. |

The tracked `deer-flow-config.yaml`, `ollama-models.txt`, both compose lanes, and every image
are untouched. That is deliberate: it keeps `audit-model-tags.ps1` green for clients while this
machine gets the extra option.

## Use it

```powershell
cd deploy/client-bundle
docker compose -f compose.prod.yaml -f compose.local-model-override.yaml up -d deer-flow
```

Compose merges the override **last**, so its `volumes` entry for the same target wins. A changed
bind-mounted file does not recreate a container, which is why the `up -d` is explicit.

Verify the container is reading it:

```powershell
docker inspect deer-flow --format '{{range .Mounts}}{{if eq .Destination "/app/backend/config.yaml"}}{{.Source}}{{end}}{{end}}'
# expect ...\deer-flow-config.local.yaml
```

Revert to the shipped config:

```powershell
docker compose -f compose.prod.yaml up -d deer-flow
```

That recreates the container with no override, so the tracked bind mount returns. Nothing else
on the box changes.

## Measured on this machine (2026-11-05)

Hardware: `COLORFIRE LinC K16`, Ryzen AI MAX+ 395 / Radeon 8060S, 96 GiB iGPU carve-out, 31.6 GiB
OS-visible RAM.

| | |
|---|---|
| Picker roster | `/api/models` lists `nemotron-bolt-74b-local` -> `nemotron-3.5-bolt:74b-a9b-iq2` |
| Cold load | **42.8 s** / **46.2 s** (`load_duration`) for a trivial prompt |
| Raw model | replied `READY` in **0.4 s** warm with the reasoning channel off |
| **Full e2e through nginx** | **HTTP 200 in 67.5 s**, assistant reply **`PONG`**, no `deerflow_error_fallback` |
| Residency | `ollama ps` reports **2.8 GB**, `100% GPU`, context 131072 |
| Free RAM before load | ~3 GiB, which is why the model is unloaded between uses |

The 67.5 s e2e figure is the honest number to quote: it is request -> agent -> Ollama -> reply
through the nginx path a client actually uses, on a warm model, with the 74B selected by
`context.model_name`. It is a *correctness* result, not a latency result - see the 278 s vs
22.3 s comparison above for why this model is not a default.

Reasoning burns the whole `num_predict` budget before producing content if you cap it low: with
`num_predict: 24` the reply came back with `content: ""` and `done_reason: "length"` because all
24 tokens went to `thinking`. That is the behaviour the entry's `when_thinking_disabled:
reasoning_effort: none` exists to prevent. The entry also carries `stream_chunk_timeout: 600`
because slow first tokens are expected here, not a hang.

## The one caveat: this file is a snapshot

`deer-flow-config.local.yaml` is a **copy**, not an include. If upstream later changes
`deer-flow-config.yaml` (new model, changed routing, changed `max_tokens`), this local copy will
**not** pick the change up and will silently keep serving the old settings - the same class of
drift `deploy/AIPC-UPDATE-GAP-ANALYSIS.md` documents for the OpenViking config.

After any `git pull` / `install.ps1 -Update`, regenerate it rather than editing it:

```powershell
cd deploy/client-bundle
# re-apply the one-block uncomment on top of the NEW tracked config
$src  = Get-Content deer-flow-config.yaml
$out  = for ($i = 0; $i -lt $src.Count; $i++) {
    $line = $src[$i]
    $inBlock = ($line -match '^  # - name: nemotron-bolt-74b-local') -or $line -match '^  #   '
    if ($inBlock) { $line -replace '^(\s*)# ', '$1' } else { $line }
}
# NOTE: verify the block bounds against the new file before trusting this; the tracked
# config states the block explicitly between its "OPTIONAL: heavier local option" and
# "on the 8060S iGPU" markers.
```

Simplest reliable check after any update:

```powershell
git --no-pager diff --no-index --stat -- deer-flow-config.yaml deer-flow-config.local.yaml
```

Expect exactly the 74B hunk plus the comment rewrite. Anything else means the tracked config
moved and the local copy needs regenerating.
