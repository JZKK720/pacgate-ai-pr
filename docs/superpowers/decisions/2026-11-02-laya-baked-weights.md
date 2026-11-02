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
| `laya-serve` image as shipped to 0.2.12 | **9.23 GB** |
| …of which `nvidia-*` CUDA libraries | **4.2 GB**, on a CPU-only box |
| `torch` version in that image | `2.15.0` (CUDA build) — **not** `2.15.0+cpu`, which the Dockerfile claimed |
| Same image with torch pinned to the CPU index | **1.79 GB** |
| …plus baked weights | **≈ 3.2 GB** uncompressed |

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
`multilingual` subfolder, 35 MB tokenizers). That cost is paid **only** by machines
that enable the profile: `docker compose config --images` omits `laya-serve`
entirely without `--profile laya`. Verified in both lanes.

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

## Still not established

- **No CI run has staged weights, built, and published 0.2.13.** Everything above is
  a local build of the same Dockerfile. The workflow change is validated as YAML,
  not as a green publish.
- **Whether ModelScope is fast enough from a GitHub-hosted runner** to keep the job
  inside its timeout. It was slow from this dev box (a partial pull stalled after
  257 MB). The staging step is `continue-on-error`, so a slow mirror cannot block
  the other five images; when it fails, only `laya-serve` is missing that release,
  which is the right blast radius.
