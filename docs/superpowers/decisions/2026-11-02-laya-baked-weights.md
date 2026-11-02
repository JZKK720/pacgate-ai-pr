# laya-serve ships its own weights (2026-11-02)

## Question

> Why is laya not baked into the GHCR images stack for pacgate-ai new version to
> deploy universally?

Two separate things were conflated in that question, and separating them is the
whole answer.

## `laya-serve` was already in the GHCR stack

It has been published on every release tag since 0.2.10, by
`.github/workflows/build-ghcr.yml`. What it did **not** contain was the checkpoints;
those were staged onto the client machine and bind-mounted.

## What was actually wrong, measured

| | Measured |
|---|---|
| `laya-serve` image as shipped to 0.2.12 | **9.23 GB** (`docker images`; ~2.96 GB compressed) |
| …of which `nvidia-*` CUDA libraries | **4.2 GB**, on a CPU-only box |
| `torch` version in that image | `2.15.0` (CUDA build) — **not** `2.15.0+cpu`, which the Dockerfile claimed |
| Same image with torch pinned to the CPU index | **1.79 GB**, no CUDA |
| 0.2.13 as published | **1.64 GB compressed**, **2.8 GB** uncompressed rootfs (`du -sh /`) |
| 0.2.12 as published | 2.96 GB compressed |

`docker images` reports 4.69 GB for the 0.2.13 image on Docker Desktop. That figure
is not the rootfs: summing the layer sizes from `docker history` gives 2.93 GB and
`du -sh /` inside the container gives 2.8 GB. The registry figure, 1.64 GB
compressed, is the number a client actually downloads.

The Dockerfile's own comment said pip reported `2.15.0+cpu`. It did not: a plain
`pip install "laya[serve]"` resolves torch from PyPI's default CUDA build, dragging
in 4.2 GB of `nvidia-*` packages onto a CPU-only box. The claim was false for the
entire life of the file, and nothing checked it.

## Decision: bake the weights

| Option | Verdict |
|---|---|
| Ship a `.tar.gz` for the operator to extract | Rejected — still a client-side step, still two silent failure modes |
| A profile that fetches models on first run | Rejected — breaks the offline guarantee; AIPCs may not reach the internet |
| **Bake into `laya-serve`** | **Chosen** — Apache-2.0 checkpoint, verified via the ModelScope model API |

Baking removes the staging step and both silent failure modes measured on the old
design:

- **No cache** → container exits at boot (`LocalEntryNotFoundError`). Loud.
- **Partial cache** → `healthy`, `/health` 200, `loaded: ["multilingual"]`, Chinese
  fine, **English HTTP 500**.
- **Empty bind mount** → identical to "no cache", because a bind mount *replaces*
  the image layer instead of merging with it. Proven by mounting an empty directory
  and watching the baked snapshot vanish.

That third one is why the mount had to be **removed**, not merely adjusted. A mount
over `/home/laya/.cache/huggingface` silently un-bakes the image.

## Cost

The weights are 1.45 GB (803.6 MB `english` = the repo root, 614.0 MB
`multilingual` subfolder, 35 MB tokenizers). Measured on 0.2.13: **1.64 GB
compressed** in the registry, **2.8 GB** as an uncompressed rootfs. That cost is
paid **only** by machines that enable the profile: `docker compose config --images`
omits `laya-serve` entirely without `--profile laya`. Verified in both lanes.

**The larger cost is resident memory, and it is not in any capacity model.**
Measured 2026-11-02 with both checkpoints loaded and idle: `docker stats` reports
**4.378 GiB**, summed in-container RSS **3.27 GiB** — roughly 3× the weights,
because each checkpoint holds an fp32 copy. That is host RAM, not VRAM.

`install.ps1`'s residency tiers (`high` / `big-ram-small-vram` / `standard` /
`constrained`) describe **Ollama only**; no gate references laya at all
(`Select-String scripts/test-*.ps1 -Pattern laya` returns nothing in the four
capacity and memory gates). On a 16 GiB AIPC with a large local model already
resident, enabling laya is a plausible route into paging — the exact failure mode
`LLAMA_ARG_CACHE_RAM` exists to prevent. This is now documented in `.env.example`;
it is **not** enforced, because the right threshold depends on which local models a
given AIPC runs.

## NPU, considered and rejected

The AIPC class is AMD Ryzen AI 9 HX 370 and does expose an NPU — this dev box
reports `NPU Compute Accelerator Device`. It is still the wrong target:

1. **laya has no NPU backend.** It is PyTorch, and its only accelerator path is
   `cuda`; `LAYA_DEVICE` is parsed by `torch.device`, which has no `npu`. An AMD
   XDNA NPU needs a separate compiler with per-model operator support.
2. **The NPU is not reachable from the shipped container.** The Linux guest exposes
   no `/dev/accel` and loads no `amdxdna`; only `/dev/dri` exists. An `--device`
   passthrough has nothing to bind, and the Windows driver serves Windows processes
   only.
3. **There is no time to save.** Measured on CPU: **0.3 s** per English clause,
   **0.1 s** per Chinese clause. These are 0.6–0.8 GB encoders producing one number
   per clause.

The one place NPU could help is *startup*, via pre-converted ONNX (onnxruntime does
ship an XDNA execution provider). Nothing is published per checkpoint, so that is a
separate evaluation, not an image change.

## Verification

- Weights are baked and **checksum-verified at build time**. A corrupted weight file
  fails the build naming the expected and actual sha256 — proven by red-check.
- The image boots and serves **with no mount at all**: both checkpoints loaded, and
  both languages answer.
- Six changed/new gate assertions in `scripts/test-laya-tools.ps1` (L10), each
  red-checked by reintroducing its defect. The old L6 assertion that *required* a
  cache mount was inverted, because keeping it would have demanded the defect.

### The CI path, exercised for real (2026-11-02)

This section previously said the CI path was unproven. Tagging `v0.2.13` settled it:

| Check | Result |
|---|---|
| `laya-serve:0.2.13` published to GHCR | **yes**, after ~12 min (it builds last, after ModelScope staging) |
| Published compressed size | **1.64 GB**, vs **2.96 GB** for 0.2.12 |
| Weight layer in the published image | **1312.7 MB** — the staging step worked from a GitHub runner |
| `torch` in the published image | `2.15.0+cpu`, and no `nvidia/` directory |
| Runs with no mount | `loaded: ["multilingual","english"]`, healthy in ~30 s |
| `docker compose --profile laya up -d laya` | one command, no staging, healthy in 30 s |
| Gate against the published container | **54 passed, 0 skipped** |
| `pacgate_clause_risk` through pacgate-mcp | EN `high` 0.93, ZH `high` 0.70 — real verdicts, both languages |
| Full suite on 0.2.13 | 81 pass / 0 fail / 1 known CANNOT-CHECK |

ModelScope from a GitHub-hosted runner was **fast enough**: the staged weights made
it into the image on the first attempt. The `continue-on-error` guard was not needed
this time, and stays as protection against the mirror being slow on a future release.

## Still not established

- **How long a cold staging run takes from a runner.** This release staged and
  published, but no timing was recorded, so the job's timeout headroom is unknown.
- **Pulling ~1.6 GB on a client's link.** The AIPC install path was not re-measured
  with the larger image. On this dev box the pull needed retries against TLS
  handshake timeouts, which is a property of this link rather than of the image, but
  it is the one client-facing cost that went up.
