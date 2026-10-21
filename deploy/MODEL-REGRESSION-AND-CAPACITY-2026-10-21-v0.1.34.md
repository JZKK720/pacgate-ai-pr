# Model regression, model picker, and capacity verdict — Pacgate-ai 0.1.34

**Date:** 2026-10-21
**Machine:** HX370 dev box (`CUBECLOUD01`) — Ryzen AI 9 HX 370, **61.6 GiB** OS-visible
RAM, **RX 7600 XT 15.98 GB** VRAM (`qwMemorySize`), iGPU Radeon 890M 2 GB UMA,
Windows 11, Docker VM gets **24 CPU / 30.17 GiB**, Ollama 0.40.6
**Residency:** `OLLAMA_NUM_PARALLEL=2`, `OLLAMA_MAX_LOADED_MODELS=2`,
`OLLAMA_KEEP_ALIVE=15m`, `OLLAMA_CONTEXT_LENGTH=32768`
**Method:** every number below came from a command run in this session. Anything
not measured is marked UNMEASURED.

---

## 0. Verdict — capable with one hard constraint

> ⚠ **CORRECTED 2026-10-21 — read `CONCURRENCY-AND-VRAM-2026-10-21.md`.** The
> measurements below stand, but two conclusions in this document were wrong:
> (1) "pick one local model; let cloud carry concurrency" — concurrency never
> required two resident models, and `NUM_PARALLEL=2` already delivers **1.57×**
> with one; (2) summing `ollama ps` sizes is **not** a valid VRAM budget (6.7 + 8.2
> = 14.9 GB also fails to fit). The eviction itself is real and reproduced.

| Workload | Verdict |
| --- | --- |
| **Cloud LLM calls** (main tier) | **WORKS**, ~2.8 s short calls, **zero VRAM** (served by ollama.com) |
| **Local chat models** | **WORKS**, 34–45 tok/s, 100% GPU |
| **Local + cloud SIMULTANEOUSLY** | **WORKS** — 2.9 s wall. Cloud is off-box, so no VRAM contention |
| **Embeddings + vectorDB** | **WORKS** — 768-dim, HNSW, sensible ranking, **~2.1 s warm** |
| **Embedding while a chat model is resident** | **WORKS** — 2.8 s, both stay on GPU |
| **Openviking VLM (image→text)** | **WORKS** — transcribed a real PNG correctly |
| **OCR on images** | **WORKS** (service side, proven) — but the **client path was closed**; see §3 |
| **2 local chat models at once** | **DOES NOT FIT** — 6.7 + 9.7 = **16.4 GB** on a **15.98 GB** card |

**The single hard constraint: only ONE local chat model can be resident at a
time.** Everything else — cloud, embeddings, VLM, OCR — fits alongside it.
This is **not** a concurrency limitation: `NUM_PARALLEL=2` lets that one model
serve two requests at once (measured 1.57× speed-up). See
`CONCURRENCY-AND-VRAM-2026-10-21.md` §5.

---

## 1. Local model regression (measured)

Each tag loaded cold, then a short generation:

| Model | OK | load+call | tok/s | Resident size | Context | Processor |
| --- | --- | --- | --- | --- | --- | --- |
| `pacgate-mid:latest` | ✅ | 10.9 s | **44.9** | 6.7 GB | **32768** (pinned) | 100% GPU |
| `pacgate-low:latest` | ✅ | 13.3 s | **34.7** | 9.7 GB | **32768** (pinned) | 100% GPU |
| `gemma4:12b-it-qat` | ✅ | 12.5 s | 34.9 | 8.2 GB | 65536 (machine-wide) | 100% GPU |
| `ornith-1.5:9b` | ✅ | 11.1 s | **44.7** | 7.7 GB | 65536 (machine-wide) | 100% GPU |
| `nomic-embed-text` | n/a | 2.1 s | — | 335 MB | 2048 | 100% GPU |

`nomic-embed-text` correctly **refuses `/api/generate`** (`does not support
generate`) — it is an embedding model. It works through `/api/embed`.

**Pinned vs unpinned is visible here and matters:** the derived `pacgate-*` tags
read **32768**, while the raw base tags (`gemma4`, `ornith`) read the machine-wide
**65536**. Anything that reaches for a base tag bypasses the pin and doubles KV
memory. 9.7 GB (pinned) vs 8.2 GB (unpinned, but at 2× context) shows the trade.

---

## 2. Cloud LLM calls (proven)

| Model | OK | latency | tokens to answer "PONG" |
| --- | --- | --- | --- |
| `deepseek-v4.1-flash:cloud` | ✅ | 2.9 s | **18** |
| `glm-5.3-flash:cloud` | ✅ | 2.9 s | **28** |

Both are `ollama.com`-served: they carry **no weight layers on disk**, never appear
in `ollama ps`, and consume **no local VRAM**. This is why the mixed workload fits.

---

## 3. ⚠ The `.png` problem — root-caused, patched in source, NOT yet deployed

### OCR capability itself: PROVEN

Rendered a 1600×700 PNG reading `SUPPLY AGREEMENT / Party A pays CNY 2400000 /
Contact 13800138000` and posted it to `ocr-service` on **:8100**:

```
{"text":"SUPPLY AGREEMENT\nParty A pays CNY 2400000\nContact13800138000",
 "pages":1,"engine":"paddleocr","incomplete":false}
```

All three lines recovered, `incomplete:false`. **The OCR service always handled
images** — `_prepare_pages` returns images "as-is".

### Two separate blockers kept clients out

**Blocker 1 — storage allowlist.** `pacgate-docx/src/store.rs` accepted only
`.docx .xlsx .pptx .pdf .txt .md .html`, so an upload was rejected before OCR was
ever consulted.

**Blocker 2 — the OCR call sent a filename with NO extension.** This was the
subtle one. `pacgate-api/src/extract.rs` posted the bytes as
`.file_name("document")`, and `ocr-service` does
`suffix = splitext(filename)[1] or ".pdf"` → every extraction took the **PDF
rasteriser** path. PDFs worked by accident; an image was handed to `pdf2image` and
returned nothing.

Measured, same image, two filenames:

| filename sent | text | incomplete |
| --- | --- | --- |
| `"document"` (what the API sent) | **0 chars** | **true** |
| `"probe.png"` | **60 chars** | false |

### Patch applied (in source, not deployed)

| File | Change |
| --- | --- |
| `pacgate-core/src/lib.rs` | added `ImagePng/Jpeg/Tiff/Bmp/Webp` to `DocumentFormat`, plus `DocumentFormat::from_storage_key` |
| `pacgate-docx/src/store.rs` | accept those extensions; map to format strings; name them in the rejection message; `read_text` names the OCR lane for an image instead of reporting invalid UTF-8 |
| `pacgate-api/src/extract.rs` | send `document.<ext>` derived from the stored format, so ocr-service routes correctly |
| `pacgate-api/src/documents.rs` | content-type + download extension for the new variants; row-mapper now uses `from_storage_key` |

The key->variant mapping existed in **two** copies (`pacgate-api/src/documents.rs`
and `pacgate-docx/src/store.rs`). Adding the raster variants to one copy only would
have left the other reporting an image as `Txt`, which hands PNG bytes to the UTF-8
text lane and surfaces "stream did not contain valid UTF-8". It is now one
`from_storage_key` in `pacgate-core`, with a test per storage key.

**Verification:** `cargo check -p pacgate-core -p pacgate-docx -p pacgate-api --all-targets`
→ **clean**; `cargo test -p pacgate-core -p pacgate-docx -p pacgate-api --lib`
→ **118 passed, 0 failed**.

**Not deployed, deliberately.** `compose.prod.yaml` pins
`ghcr.io/jzkk720/pacgate-api:0.1.34`. Building this patch over that tag would make
a published release identifier mean something the registry never built. Deploying
needs either a version bump (a release decision) or an explicit local-tag
override. **This is the one thing that needs your call.**

---

## 4. Embeddings + vectorDB — end to end

`kb_chunks.embedding` is `vector(768)` with an **HNSW** cosine index — matching
`nomic-embed-text`'s dimension exactly.

| Check | Evidence |
| --- | --- |
| Embed latency | cold 3374 ms; **warm 2089 / 2066 / 2045 ms** |
| Dimension | **768** — matches the column |
| Upload → ingest → embed → store | `kb_chunks` grew **3 → 4** on a single `.md` upload, `with_embedding` 3 → 4 |
| Real vectors | `vector_dims = 768`, non-null |
| Vector search | cosine query returned **ranked** rows |

Similarity for the probe *"partner approval for settlement offers"*:

| score | chunk |
| --- | --- |
| **0.6405** | Settlement Agreement — *Party A agrees to pay…* |
| 0.6375 | Liquidated Damages Memorandum — *settlement authority clause…* |
| 0.5410 | Supply Agreement — *Parties / Payment…* |

Semantically sensible: the settlement query ranks the settlement documents above
the unrelated supply agreement.

### ⚠ `pacgate_kb_search` returned `[]` — and that is CORRECT

Called through MCP against a matter holding 4 embedded chunks, the tool returned an
empty list. Root cause, from source `pacgate-rag/src/lib.rs:305`:

```sql
AND c.sanitization_state IN ('sanitized', 'never')   -- unconditional literal
```

The comment above it is explicit: the gate is *a property of the connection, not a
request field*, so a caller cannot pass a value to widen it. Our chunks were
`pending`/`blocked`, so they were **deliberately unsearchable**.

Proof by promotion — sanitizing one document at T3 gave
`verdict=pass, chunks_promoted=1`, the state moved `pending → sanitized`, and the
same MCP call then returned real content with `score 0.31457552`.

**So the empty result was the security boundary working, not a broken index.** An
auditor who stopped at `[]` would have filed a serious false bug.

---

## 5. Concurrency — what the card can actually hold

### 5a. Two LOCAL chat models at once — DOES NOT FIT

| | result |
| --- | --- |
| `pacgate-mid` (6.7 GB) | ok, 10.9 s, 43.5 tok/s |
| `pacgate-low` (9.7 GB) | ok, **25.8 s**, 33.2 tok/s |
| wall | 25.8 s (vs 36.7 s sequential) |
| **resident after** | **only `pacgate-low`** |

`pacgate-mid` was **evicted mid-run**. 6.7 + 9.7 = **16.4 GB against 15.98 GB of
VRAM** — it cannot hold both, which is exactly what `OLLAMA_MAX_LOADED_MODELS=2`
permits but the hardware does not.

Operationally this is a **thrash**, not a queue: each request reloads from disk
(~11 s) and the second model pays the eviction cost. `pacgate-low`'s 13.3 s → 25.8 s
is that cost, measured.

### 5b. Local + CLOUD at once — WORKS

| | result |
| --- | --- |
| `pacgate-low` (local) | ok, **2.7 s**, 32.5 tok/s |
| `deepseek (cloud)` | ok, **2.9 s** |
| wall | **2.9 s** |

The cloud leg is served off-box, so the two do not compete for VRAM. **This is the
intended architecture** (cloud = main prompting, local = utility) and it fits.

### 5c. Embedding alongside a resident chat model — WORKS

`nomic-embed-text` (335 MB) answered in **2835 ms** with `pacgate-low` (9.7 GB)
resident, and `ollama ps` afterwards showed **both** loaded. 9.7 + 0.3 GB fits.

---

## 6. Capacity model for this machine

VRAM budget: **15.98 GB**. Measured residents:

| Combination | VRAM | Fits |
| --- | --- | --- |
| `pacgate-low` (9.7) + `nomic` (0.3) | 10.0 GB | ✅ comfortable |
| `pacgate-mid` (6.7) + `nomic` (0.3) | 7.0 GB | ✅ lots of headroom |
| `pacgate-low` (9.7) + `pacgate-mid` (6.7) | **16.4 GB** | ❌ **evicts** |
| `gemma4` raw (8.2 @ 65k ctx) + `nomic` | 8.5 GB | ✅ |
| any local + a `:cloud` model | local only | ✅ cloud is free |

**Practical rule for this box:** pick **one** local chat model per role and let
cloud carry concurrency. For the MID workflow tier prefer `pacgate-mid`
(6.7 GB, 44.9 tok/s) over `pacgate-low` (9.7 GB, 34.7 tok/s) — it is both faster
and 3 GB smaller. `pacgate-low` is the VLM/utility pin and costs the most VRAM.

The `OLLAMA_MAX_LOADED_MODELS=2` setting is **not wrong**, but on a 16 GB card it
allows a pairing that cannot fit. It is a cap, not a reservation; the scheduler
enforces the memory-fit check (`system_limited=true`).

---

## 7. Findings

### F1 — Two blockers made the OCR lane unreachable from a client *(fixed in source, undeployed)*
Storage allowlist **and** an extension-less filename in the OCR call. The second
one silently routed *everything* through the PDF rasteriser. See §3 for the patch
and the deployment decision that is still open.

### F2 — A reasoning model spends its whole budget before visible output *(operational, medium)*

`pacgate-low` with `num_predict=8` returned `''` with
`thinking="The user wants me to"` and `done_reason=length`. At `num_predict=200` it
returned `PONG` in 56 tokens.

Any caller that sets a small `max_tokens` on `pacgate-low` gets a **silent empty
response with HTTP 200** — indistinguishable from a broken model. The tier
already carries `max_tokens` 4096–16384 for this reason; ad-hoc probes and any
future code path that lowers it must account for reasoning overhead. Cloud tags
(`deepseek`, `glm`) answered in 18–28 tokens and are far less sensitive.

### F3 — `pacgate_kb_search` returns `[]` until chunks are sanitized *(by design, high confusion risk)*

Correct and deliberate (§4), but the empty list carries no explanation. A client
cannot tell "nothing relevant" from "everything here is unsanitized". Returning a
count of gated-out rows, or a distinct status, would make this self-explanatory.

### F4 — The openviking config exposes its root API key in plaintext env *(security, medium)*

`docker exec openviking env` prints `OPENVIKING_CONF_CONTENT`, which contains
`"root_api_key": "<64 hex chars>"` in cleartext. That key also appears as
`OPENVIKING_ROOT_API_KEY` in `.env`. Anyone with `docker exec` (or `docker inspect`)
on this host can read it. Consider injecting it as a separate env var that the
config template references at runtime, so the composed config never embeds the
secret.

### F5 — Two local chat models cannot coexist on this card *(capacity, high)*

16.4 GB requested vs 15.98 GB available. Eviction is silent from the caller's
side — it presents as latency, not an error. `scripts/test-aipc-capacity-fit.ps1`
covers single-model fit; the **pairing** case is not covered anywhere.

---

## 8. Unmeasured

1. **The deployed `.png` fix** — patched in source and unit-tested, not running (§3).
2. **Model-picker UI flow** in the browser (`test-model-picker-e2e.ps1` needs a
   deer-flow session; the smoke lane reports `[SKIP]` for the same reason). I
   measured the models the picker offers, not the picker's own round-trip.
3. **Sustained throughput** — all figures are short calls, not a load test.
4. **`nemotron-3.5-lightning:30b-a3b` (25 GB) and `ornith-1.5:35b` (22 GB)** are on
   disk but were **not loaded**; both exceed the card and are withdrawn from the
   shipped roster for exactly that reason.
5. **Cloud weekly quota** — reachable now, but ollama.com limits were not probed.

---

## 9. Bottom line

**This machine handles the full mixed workload, with one rule:** one local chat
model at a time. Cloud calls, embeddings, the vector index, OCR and the VLM all
coexist with a single resident local model and stay on the GPU.

Measured: **34–45 tok/s** local, **~2.1 s** embeddings, **~2.9 s** cloud, and a
working HNSW search that ranks sensibly. The 16 GB card is the binding constraint,
and it binds on *local model count*, not on total workload.
