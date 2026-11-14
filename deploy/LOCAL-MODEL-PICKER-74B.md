# Machine-local picker entry: nemotron-3.5-bolt:74b-a9b-iq2

Written 2026-11-05. This describes files that are **gitignored on purpose** and exist only on
this machine. Nothing here is part of the shipped client contract.

> **Updated 2026-11-11 - the 74B is now this box's picker DEFAULT.** It is `models[0]`, and
> every auxiliary lane (memory / title / summarization / routing) was repointed to it. That
> reverses the 2026-11-05/11-08 "must never be first" rule *for this machine only*, on
> measured grounds: Ollama here cannot hold two models at once, so leaving the lanes on the
> e4b would evict and cold-reload the 74B on every turn. See
> [The 74B is the default (2026-11-11)](#the-74b-is-the-default-2026-11-11). The shipped
> config and every client are still untouched.

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
| `scripts/regen-local-model-override.py` | yes | **The generator.** Rewrites the two files below from the current tracked config. |
| `deer-flow-config.local.yaml` | **no** (gitignored) | Generated: tracked config + the 74B first in `models:` + a 74B memory lane + lanes repointed to the 74B. |
| `compose.local-model-override.yaml` | **no** (gitignored) | Rebinds only `deer-flow` → `/app/backend/config.yaml` to the file above. |
| `.gitignore` entries | yes | The two paths above, so a `git add -A` cannot publish them. |

The tracked `deer-flow-config.yaml`, `ollama-models.txt`, both compose lanes, and every image
are untouched. That is deliberate: it keeps `audit-model-tags.ps1` green for clients while this
machine gets the extra option.

**Generate it, do not hand-edit it.** A hand-made copy is a snapshot and rots silently: the
copy written on 2026-11-08 was still missing the tracked file's glm-5.3
`when_thinking_enabled: reasoning_effort: none` fix by 2026-11-11, so it would have served the
known-broken glm behaviour to anyone who picked glm. The generator fails loudly instead of
guessing when the tracked file moves:

```powershell
python scripts/regen-local-model-override.py
# then, because the bind-mounted file changed:
cd deploy/client-bundle
docker compose -f compose.prod.yaml -f compose.local-model-override.yaml up -d deer-flow
```

## The 74B is the default (2026-11-11)

Earlier revisions of this file said the 74B "must never be the first entry". That rule exists
to protect the **client** class, and it still does. On this box the argument inverts, for a
reason that is a property of the hardware and was measured rather than assumed.

`models[0]` is the picker default in deer-flow (`agent.py`:
`default_model_name = app_config.models[0].name`; the frontend falls back to `models[0]` for a
thread with no model yet). Making the 74B default moves four lanes onto it: chat, title,
memory, summarization - plus `model_routing`.

**Why all of them, and not just chat.** Ollama evicts on *system* memory here, not on
`OLLAMA_MAX_LOADED_MODELS` (which is 2):

```
"model predicted to exceed available memory, evicting"
predicted="20.6 GiB" predicted_num_ctx=131072 available="2.4-8.8 GiB" system_limited=true
```

Windows sees **31.6 GiB** and the 74B asks for **20.6 GiB** of it, so exactly one model is
resident at a time. Verified in both directions on 2026-11-11: loading the 74B unloaded the
e4b, and loading the e4b unloaded the 74B. Left on the e4b, the title lane alone would evict
the 74B after every reply and pay the cold reload (measured 61-120 s) on the next turn.
Converging every lane on one tag is the same property the tracked config already describes for
its e4b pins.

**Live result.** Same run, twice through nginx: first (cold) **67.6 s**, second (warm)
**3.3 s**, both `HTTP 200`, reply `PONG`. The difference is exactly the model reload that the
lane convergence removes.

**Measured cost of the 74B here.** Cold load 61-120 s; `json_schema` tool call 41 s; 2048-token
memory extraction 43 s; title 2.8-3.3 s warm. It satisfies the structured-output requirement
the tracked config demands of a default (valid JSON, `done_reason=stop`).

**The caveat.** Picking a non-74B model in the picker re-introduces the thrash, because the
auxiliary lanes stay on the 74B - the mirror image of what the e4b pins do in the shipped
config. Use a 7.5B entry when speed matters more than depth.

**Second caveat, outside deer-flow's control.** Converging *deer-flow's* lanes does not make the
74B exclusive on this box. Other services use the e4b tag and will evict it when they generate:
`PACGATE_MODEL_MID` and `PACGATE_MODEL_LOW` are both `nemotron-3.5-bolt:e4b-q8_0` in
`deploy/client-bundle/.env`, and `open-webui` also lists it. Measured 2026-11-11: e4b loads
appeared in Ollama's log mid-run while deer-flow's own logs showed no request for that tag. So
an occasional cold reload of the 74B caused by a *different* container is expected and is not a
deer-flow config fault. Fixing it would mean moving those tiers to the 74B too, which trades
their latency for residency - a separate decision, not made here.

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

Measured again 2026-11-11 after the 74B became the default: cold **67.6 s**, then **3.3 s** on a
warm repeat, same `PONG` reply through nginx. The warm number is the one to expect in normal use
now that the auxiliary lanes no longer evict the model between turns.

Reasoning burns the whole `num_predict` budget before producing content if you cap it low: with
`num_predict: 24` the reply came back with `content: ""` and `done_reason: "length"` because all
24 tokens went to `thinking`. That is the behaviour the entry's `when_thinking_disabled:
reasoning_effort: none` exists to prevent, and it matters more now that the memory lane is the
74B too - a 2048-token cap with the reasoning channel live would return nothing. The entry also
carries `stream_chunk_timeout: 600` because slow first tokens are expected here, not a hang.

## Regenerate after any update

The local file is **generated**, so it cannot drift - but it also does not update itself. After
any `git pull` / `install.ps1 -Update`, run the generator so the local override is rebuilt from
the new tracked config:

```powershell
python scripts/regen-local-model-override.py
```

It fails loudly (non-zero exit, no write) when the tracked config moves under it - for example
if the commented 74B block is renamed, or if the lane pins stop matching. That is deliberate: a
silent skip would leave this box serving a stale config, which is exactly the failure the
2026-11-08 snapshot suffered.

Then recreate the container, because a changed bind-mounted file does not restart it:

```powershell
cd deploy/client-bundle
docker compose -f compose.prod.yaml -f compose.local-model-override.yaml up -d deer-flow
```

Verify, rather than trusting the merge:

```powershell
docker inspect deer-flow --format '{{range .Mounts}}{{if eq .Destination "/app/backend/config.yaml"}}{{.Source}}{{end}}{{end}}'
# expect ...\deer-flow-config.local.yaml

cd ../.. ; pwsh -NoProfile -File scripts/test-model-picker-e2e.ps1 -NginxUrl http://localhost:8089
# expect: roster starts with nemotron-bolt-74b-local, and "generating with: nemotron-bolt-74b-local"
```

`test-model-picker-e2e.ps1` validates the tracked config statically and this file only through
the live roster, which is why the live section is the check that matters here.
