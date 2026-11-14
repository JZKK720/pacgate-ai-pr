# Decision: this box's local-model posture and Mid tier (2026-11-08)

**Status:** adopted
**Scope:** this machine only. `deploy/client-bundle/.env` is gitignored; nothing here changes the
shipped client contract or any image.

## What this machine is

| | Value | Source |
|---|---|---|
| CPU | AMD Ryzen AI **MAX+ 395** | `Win32_Processor` |
| iGPU | Radeon **8060S**, unified memory | `Win32_VideoController` |
| OS-visible RAM | 31.6 GiB | `Win32_ComputerSystem` |
| `AdapterRAM` | 4.0 GB (**not the real budget**) | `Win32_VideoController` |

The last row is the trap. `AdapterRAM` reads 4 GB on this iGPU and is meaningless as a capacity
number; the binding resource is the unified-memory iGPU carve-out taken before Windows boots, which
is the same point `deploy/LOCAL-MODEL-PICKER-74B.md` records. This is the **MAX+ 395 class**, not the
shipped HX370 / RX 7600 XT 16 GB client class, and the two are not interchangeable for model choice.

## Measurement 1: residency is size one

| Sequence | `ollama ps` after |
|---|---|
| Load `nemotron-3.5-bolt:74b-a9b-iq2` | `74b-a9b-iq2`, 4.2 GB, 100% GPU |
| then load `nemotron-3.5-bolt:e4b-q8_0` | **`e4b-q8_0` only** - the 74B is gone |
| load `ornith-1.5:9b` | **`ornith-1.5:9b` only** - the e4b is gone |

At no point did two large models coexist. So upstream's argument - "one tag means one resident model
and no reload between a Mid and a Low call" - is the correct argument for this box too, and it
selects **MID = LOW = `nemotron-3.5-bolt:e4b-q8_0`**. Pinning MID to `ornith-1.5:9b` guarantees an
eviction on every Mid/Low alternation on a machine that can only hold one.

## Measurement 2: throughput here, not upstream's numbers

Warm, long prompt, this box, 2026-11-08:

| Model | prefill tok/s | decode tok/s |
|---|---|---|
| `nemotron-3.5-bolt:e4b-q8_0` | **1274** | 58.9 / 34.2 |
| `ornith-1.5:9b` | 992 | 33.4 / 33.8 |

The e4b wins **both** axes here. Upstream's comment records the opposite ordering for prefill
("ornith 1263 tok/s prefill vs 1080 here"), so the trade-off it describes does not reproduce on this
machine. The decision therefore rests on this box's measurement, and on residency, not on capability.

## Measurement 3: the 74B is real on this box

`nemotron-3.5-bolt:74b-a9b-iq2`, requested with an adequate budget:

```
done_reason : stop
prefill     : 46 tok/s
decode      : 51.9 tok/s
residency   : 4.2 GB, 131072 ctx, 100% GPU
wall        : 85.6 s for a one-sentence answer
```

It is a working, selectable model here - which is the entire reason
`compose.local-model-override.yaml` and `deer-flow-config.local.yaml` exist.

**It needs a real token budget.** At `num_predict` 16-24 it returns `content: ""` with
`done_reason: "length"` because the whole budget went to `thinking`. This is the trap already
documented in `LOCAL-MODEL-PICKER-74B.md`; it is a usage constraint, not a defect.

## Decision

1. **MID = `nemotron-3.5-bolt:e4b-q8_0`**, equal to LOW. Reason: residency is size-one on this box,
   and the e4b measured faster on both axes here.
2. **MAIN stays `deepseek-v4.1-flash:cloud`.** Cloud chat is the recorded 2026-08-30 decision; it is
   not drift.
3. **The 74B stays out of `deploy/client-bundle/ollama-models.txt`.** That file is the client
   pre-pull contract; `test-aipc-capacity-fit.ps1` budgets the client class at 16 GB and records
   the 74B at 24.0 GB, i.e. OVER_CAP. Adding it would make every AIPC download 24.8 GB it cannot
   hold. This still holds.
4. **SUPERSEDED 2026-11-11 - the 74B is now this machine's picker default.** The original rule
   ("the 74B must never be the first picker entry") exists to stop an unpinned run on a *client*
   inheriting a 12x slowdown. On this box the trade-off inverts, because Ollama evicts on system
   memory here (measured: `predicted="20.6 GiB" available="2.4-8.8 GiB" system_limited=true`),
   so only one model is resident at a time. With the 74B first and the lanes left on the e4b,
   every turn evicted the 74B and paid a 61-120 s cold reload. `models[0]` = 74B and all lanes
   converged on that tag instead: measured warm e2e 3.3 s vs 67.6 s cold. The client contract is
   unaffected - only the gitignored local override changed. See
   `deploy/LOCAL-MODEL-PICKER-74B.md`, and `scripts/regen-local-model-override.py` which
   generates it.

## Known gap in the gates

`scripts/test-model-picker-e2e.ps1` reads only the **tracked** `deploy/client-bundle/deer-flow-config.yaml`
(`$cfg`, line 128). It never reads the local variant, so the local config's *static* content is
validated by nothing - only its effect is, through the live roster section. That is why
`docs/superpowers/plans/2026-11-08-upstream-sync-v0.2.32-runtime-upgrade.md` Task 3 verifies the
regenerated file by hand, with assertions, instead of trusting a green suite.

This gap is now partly mitigated: the local file is **generated** by
`scripts/regen-local-model-override.py` from the tracked config, so it cannot drift the way the
2026-11-08 hand-copy did (that copy was still missing the glm fix on 2026-11-11), and the
generator exits non-zero instead of producing a stale file when the tracked config moves.

Worth a gate. Deliberately not added here: it is a separate change, and folding it into a runtime
upgrade would mix an unverified new gate with a verification whose whole value is that its checks are
already known-good.
