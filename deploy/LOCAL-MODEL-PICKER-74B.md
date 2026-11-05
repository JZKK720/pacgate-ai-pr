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

| | |
|---|---|
| Picker roster | `/api/models` lists `nemotron-bolt-74b-local` → `nemotron-3.5-bolt:74b-a9b-iq2` |
| Cold load | **42.8 s** (`load_duration` 41.4 s) for a trivial prompt |
| Generation | replied `READY` in **0.4 s** warm with the reasoning channel off |
| Residency | `ollama ps` reports **2.8 GB**, `100% GPU` |
| Host visible RAM | 31.6 GiB - the same bucket the repo measured as a 32 GB box |
| Free RAM before load | ~2-3 GiB, which is why the model is unloaded between uses |

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
