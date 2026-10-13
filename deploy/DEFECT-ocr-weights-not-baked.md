# DEFECT: ocr-service downloaded its model weights from an external CDN on first use

**Status:** FIXED in 0.1.28 (weights baked into the image)
**Found:** 2026-10-13, while proving the v0.1.28 image against `test-sanitizer-e2e.ps1`
**Severity:** HIGH for deployability, MEDIUM for correctness

## Symptom

`test-sanitizer-e2e.ps1` reported `FAIL: extract returned text` against the
freshly published `pacgate-api:0.1.28`, while the same test was **16/16 PASS**
against `pacgate-api:0.1.27`. That looked like a 0.1.28 regression in the
sanitizer. It was not - the sanitizer was fine both times.

## How it was actually found

Rather than guess, the failing call was reproduced directly. The API container
log carried the real error:

```
url (http://pacgate-ocr-e2e:8100/extract)
```

so the failure was in the API's call to ocr-service, not in sanitization. A
manual probe of the same endpoint then produced the decisive number:

| path | time | note |
|---|---|---|
| COLD `/extract`, 1-page fixture, no weights volume | **269.9s** | what the test did |
| WARM `/extract`, same fixture, weights volume mounted | **3.4s** | what production does |
| WARM, second call | **0.14s** | |

`pacgate-api` caps that call at **300s** (`crates/pacgate-api/src/extract.rs`).
269.9s against a 300s cap is **~10% headroom**, so the failure is intermittent
rather than deterministic - which is exactly why it read as flakiness or as a
version regression.

## Root cause

PaddleOCR downloads PP-OCRv4 det/rec/cls weights into `/root/.paddleocr/whl/`
on **first construction**. This was a deliberate choice, stated twice in the
repo:

- `deploy/ocr-service/Dockerfile` - lazily initialised so "the model download happens once"
- `.github/workflows/build-ghcr.yml` - "The ~1.5GB model download happens on FIRST EXTRACTION ... so the image itself stays small."

Two things make that choice wrong for a client install:

1. **It needs a specific external host.** The only source is
   `paddleocr.bj.bcebos.com`. A fresh AIPC behind a restrictive network cannot
   read its first document at all. The rest of the bundle is deliberately
   offline-capable; this single lane broke that property.
2. **The stated size was wrong by two orders of magnitude.** Measured: the
   weights are **17.3 MB**, not ~1.5GB. The download is a slow CDN transfer, not
   compute - so it is also much cheaper to bake than the comment assumed.

## Fix

The weights are baked at image build time and verified present:

- `deploy/ocr-service/warm_up.py` (new) constructs `PaddleOCR` **the same way
  `app.py` does**, so the baked set cannot drift from what the service asks for.
  Fetching individual URLs would have been the obvious alternative and would
  silently drift the moment `lang` or `use_angle_cls` changed.
- `deploy/ocr-service/Dockerfile` runs it and then **asserts** the three model
  directories exist, so a failed download cannot produce a silently empty bake.

`compose.prod.yaml` still mounts `paddleocr-models` over `/root/.paddleocr`. The
baked copy is the floor (always present, offline-safe) and the volume is the
writable layer. PaddleOCR only downloads when a model is **missing**, so with the
bake in place it does not download at all.

## A second, independent defect found in the same place

`test-sanitizer-e2e.ps1` started its ocr-service container with **no weights
volume**, so every run paid the cold path that production never takes. The gate
was therefore not just slow - it was **unfaithful**, and it converted a harness
problem into a product-looking failure. The volume name is now **derived** from
the running `ocr-service` (falling back to the compose project prefix), and a
missing volume is stated loudly rather than silently producing a cold run.

## Verification

- `test-sanitizer-e2e.ps1` against `ghcr.io/jzkk720/pacgate-api:0.1.28` with the
  warm mount: **16/16 PASS**.
- The bake is proven by the build-time assertions in the Dockerfile
  (`test -d /root/.paddleocr/whl/{det,rec,cls}`), plus a post-publish check that
  a container started with **no** weights volume extracts without downloading.

## Honest residual

- The 300s client cap in `extract.rs` was left alone. It is adequate once the
  weights are baked (warm path is 3.4s, and a 3-page cold extract was still being
  measured when this was baked instead). If a very large or very degraded scan
  ever needs more, the cap - not the bake - is the thing to revisit.
- The bake only helps from the **next** image build onward. Machines already
  running 0.1.27 keep the CDN dependency until they pull 0.1.28.
