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

`compose.prod.yaml` used to mount `paddleocr-models` over `/root/.paddleocr`. Both
the mount and the now-unused volume declaration have been **removed**, because the
mount did not do what the paragraph here originally claimed.

## The volume mount SHADOWED the bake (found 2026-10-13, same day)

The original note read: "the baked copy is the floor (always present, offline-safe)
and the volume is the writable layer; PaddleOCR only downloads when a model is
missing, so with the bake in place it does not download at all. The mount is kept
because removing it would need a re-verification pass, and it is harmless."

The last clause was wrong, and measurably so. A bind/named-volume mount **replaces**
the directory - it does not layer over it. So the moment a volume is mounted at
`/root/.paddleocr`, the image's baked copy is no longer visible *at that path*, and
PaddleOCR reaches for `paddleocr.bj.bcebos.com` again for anything the volume lacks.
The bake survives only as an unreadable copy inside the image layer.

Measured on this box with the published 0.1.28 image:

| step | result |
| --- | --- |
| fresh named volume mounted, 1st run | Docker seeds it from the image: `det/ch/ch_PP-OCRv4_det_infer`, 9 files |
| delete one baked dir **inside the volume** (simulating a stale/foreign volume) | 7 files, marker written |
| same volume, container **recreated** (what an upgrade does) | `ls: cannot access '/root/.paddleocr/whl/det/ch/': No such file or directory` |

The third row is the defect: after a recreate the baked weights were **unreachable**.
The volume won, and the image's copy never came back.

### Why it was still benign *in practice*, stated honestly

A fresh volume is seeded from the image, and the seeded content is **byte-identical**
to a fresh download. Measured both ways across 0.1.27 (downloaded) and 0.1.28
(baked, **no volume**, `--network none`):

| | 0.1.27 downloaded | 0.1.28 baked |
| --- | --- | --- |
| files | 9 | 9 |
| bytes | 18,073,805 | 18,073,805 |
| `det/…/inference.pdmodel` sha256 (first 16) | `2ad68ed2768fe6c4` | `2ad68ed2768fe6c4` |
| `rec/…/inference.pdmodel` | `bf78f3898a004615` | `bf78f3898a004615` |
| `cls/…/inference.pdmodel` | `3c4337ec61722a20` | `3c4337ec61722a20` |

Every file matched. So on a machine upgrading from 0.1.27 the volume already holds
the same weights and nothing would have downloaded. That is *why* the shadowing
went unnoticed - and why "benign" was the wrong lesson to draw from it: the
guarantee the bake is supposed to provide is "extraction cannot depend on a CDN",
and a mount that can be stale removes that guarantee even when, today, it is not.

### What changed

- `compose.prod.yaml` and `compose.bundle.yaml`: the `volumes:` mount on
  `ocr-service` is gone, and `paddleocr-models:` is no longer declared. With no
  mount, the baked weights **are** the tree, and every extraction path is the
  measured 3.4s warm path.
- `scripts/smoke-full-stack.ps1` lane 6: this used to report
  `Bad "paddleocr volume NOT mounted - recreate would re-download"`, i.e. it
  **demanded** the shadowing configuration. Inverted: a mount is now the failure,
  and the lane asserts the baked `det`/`rec`/`cls` are present.
- `scripts/test-ocr-bake-integrity.ps1` (new gate): fails if **any** compose in the
  tree mounts anything over the baked path, if the volume declaration returns, if
  `warm_up.py` stops resolving `lang`/`use_angle_cls` the same way `app.py` does,
  or if the smoke lane is flipped back. Red-checked by reintroducing each.
- The 0.1.28 images are unaffected - this is compose + scripts only, so no rebuild
  was needed for the fix to reach clients. Clients get it from the repo refresh in
  `install.ps1 -Update`.
- An existing `paddleocr-models` volume on a client machine is now simply unused;
  it can be removed with
  `docker volume rm <project>_paddleocr-models` (project is `pacgate-ai-bundle`,
  so the real name is `pacgate-ai-bundle_paddleocr-models`) but leaving it is inert.
  It was removed on the dev box and `ocr-service` recreated from the current
  compose afterwards: **0** mounts, det/rec/cls present, and a real extraction
  through the API still PASSes - so the removal is proven, not assumed.

## A second, independent defect found in the same place

`test-sanitizer-e2e.ps1` started its ocr-service container with **no weights
volume**, so every run paid the cold path that production never takes. The gate
was therefore not just slow - it was **unfaithful**, and it converted a harness
problem into a product-looking failure. The volume name is now **derived** from
the running `ocr-service` (falling back to the compose project prefix), and a
missing volume is stated loudly rather than silently producing a cold run.

> Superseded by the section above: with the mount removed, "no weights volume" is
> now the **correct** and production-faithful state. The derivation was still the
> right fix for the defect it described - a harness must not invent a mount - but
> the volume it derived is no longer mounted.

## Verification

- Re-verified **2026-10-13 after the mount was removed**, so this is the exact
  production shape (no volume at all): `test-ocr-extraction.ps1` PASS,
  `test-text-native-sanitize.ps1` **59/59 PASS**, `test-sanitizer-e2e.ps1`
  **16/16 PASS**, and `smoke-full-stack.ps1` lane 6 PASS with
  `mount | grep -c /root/.paddleocr` = **0** and `det`/`rec`/`cls` all present.
- The bake is proven by the build-time assertions in the Dockerfile
  (`test -d /root/.paddleocr/whl/{det,rec,cls}`), plus a post-publish check that
  a container started with **no** weights volume extracts without downloading.
- **Offline proof against the PUBLISHED image** (`ghcr.io/jzkk720/ocr-service:0.1.28`),
  which is the property the bake exists for. The image alone carries
  `det`/`rec`/`cls` at `/root/.paddleocr/whl` (**18M, zero volumes**). A container
  started with `--network none` - verified to have **no non-loopback interfaces**
  and DNS resolving to `gaierror` - answered its own `POST /extract` over
  loopback with **HTTP 200 in 5.05s**, returning
  `{"text":"OFFLINEOCROK","pages":1,"engine":"paddleocr","incomplete":false}`
  with spans. Nothing was downloaded.
- The production container no longer mounts anything over the baked path, so the
  offline `--network none` run above is now exactly what a client executes. When
  a volume *was* mounted, inspecting the *running* container proved nothing about
  the bake either way - Docker seeds a fresh named volume **from** the image, so
  the volume also read 18M, which is how the shadowing hid. That is recorded in
  its own section above, with the probe that exposed it.

## The `ocr-service:local` indirection is now gone entirely

Removing the tag from the gates still left one live reference: the dev-box
`compose.ocr-override.yaml`. That file had been superseded twice over and was
**deleted**:

- `40938bb` (0.1.16) shipped `ocr-service` as a first-class release image and
  enabled it in `compose.prod.yaml` - the override was redundant from that point.
- It pinned `pacgate-api:plan020-test`, an image that **does not exist on this
  box**, and `ocr-service:local`, the invented tag. Combining it with
  `compose.prod.yaml` therefore *retagged both lanes backwards*, replacing the
  release images with stale local builds.

Measured before deleting: no gate asserts the file exists (`test-memory-lane.ps1`
only asserts on composes that define `deer-flow` **and** wire `PACGATE_API_URL`,
which this override does not), no doc treats it as still-needed, and the running
stack resolves `ghcr.io/jzkk720/ocr-service:0.1.28`. `test-memory-lane.ps1`'s
comment naming the file was updated in the same change.

## Honest residual

- The 300s client cap in `extract.rs` was left alone. It is adequate once the
  weights are baked (warm path is 3.4s, and a 3-page cold extract was still being
  measured when this was baked instead). If a very large or very degraded scan
  ever needs more, the cap - not the bake - is the thing to revisit.
- The bake only helps from the **next** image build onward. Machines already
  running 0.1.27 keep the CDN dependency until they pull 0.1.28.
