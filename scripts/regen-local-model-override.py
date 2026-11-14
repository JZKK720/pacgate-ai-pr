"""Regenerate deploy/client-bundle/deer-flow-config.local.yaml (machine-local override).

    python scripts/regen-local-model-override.py

THIS GENERATES A GITIGNORED FILE. Nothing here changes the shipped client contract:
`deploy/client-bundle/deer-flow-config.yaml`, `ollama-models.txt`, both compose lanes
and every image are untouched. See deploy/LOCAL-MODEL-PICKER-74B.md for the reasoning.

Why a generator instead of a hand-edited copy: the tracked config keeps moving, and a
snapshot silently rots. The previous hand-made copy was already stale on 2026-11-11 -
it predated the glm-5.3 `when_thinking_enabled: reasoning_effort: none` fix that landed
in the tracked file, so it would have served the broken glm behaviour. Deriving the
override from the current tracked config every time makes that class of drift
impossible by construction.

What it does, all in one pass over the tracked file:
  1. Activates the `nemotron-bolt-74b-local` entry the tracked config keeps commented
     out, and moves it to the TOP of `models:` - `models[0]` IS the picker default
     (`agent.py`: `default_model_name = app_config.models[0].name`; the frontend falls
     back to `models[0]` for a thread with no model yet).
  2. Adds a 74B memory lane next to it, same Ollama tag, 2048-token cap.
  3. Repoints memory / title / summarization / model_routing at the 74B entries.

Step 3 is required, not cosmetic. Ollama here evicts on SYSTEM memory, not on
OLLAMA_MAX_LOADED_MODELS (which is 2):

    "model predicted to exceed available memory, evicting"
    predicted="20.6 GiB" predicted_num_ctx=131072 available="2.4-8.8 GiB" system_limited=true

Windows sees 31.6 GiB while the 74B asks for 20.6 GiB of it, so exactly ONE model is
resident at a time - verified in both directions on 2026-11-11 (loading the 74B unloaded
the e4b; loading the e4b unloaded the 74B). Leaving the auxiliary lanes on the e4b while
chat defaults to the 74B would therefore evict and cold-reload (measured 60-120 s) on
every turn. Converging every lane on one tag is the same property the tracked config
describes for its e4b pins.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
SRC = REPO / "deploy" / "client-bundle" / "deer-flow-config.yaml"
DST = REPO / "deploy" / "client-bundle" / "deer-flow-config.local.yaml"

BOLT74 = "nemotron-bolt-74b-local"
MEM74 = "nemotron-bolt-74b-memory"
TAG74 = "nemotron-3.5-bolt:74b-a9b-iq2"

BANNER = f"""\
# {"=" * 78}
# MACHINE-LOCAL OVERRIDE - NOT SHIPPED, NOT FOR CLIENTS. Generated file.
#
# Regenerate with: python scripts/regen-local-model-override.py
# Read by deer-flow only when compose.local-model-override.yaml is merged in.
#
# What this file changes on top of the tracked deer-flow-config.yaml:
#   1. `{BOLT74}` ({TAG74}) is the FIRST entry,
#      so it is `models[0]` - the model picker's default for this machine.
#   2. A 74B memory lane (`{MEM74}`) is added next to it, same tag,
#      2048-token cap.
#   3. memory / title / summarization / model_routing all point at the 74B entries.
#
# WHY (3) IS REQUIRED, NOT COSMETIC - measured on this box 2026-11-11:
#   Ollama evicts on SYSTEM memory, not on OLLAMA_MAX_LOADED_MODELS (which is 2):
#     "model predicted to exceed available memory, evicting"
#     predicted="20.6 GiB" predicted_num_ctx=131072 available="2.4-8.8 GiB" system_limited=true
#   The OS sees 31.6 GiB while the 74B asks for 20.6 GiB of it, so exactly ONE model
#   is resident at a time. Verified both directions: loading the 74B unloaded the
#   e4b, and loading the e4b unloaded the 74B.
#   Therefore pinning the auxiliary lanes to the e4b while chat defaults to the 74B
#   would evict and cold-reload (measured 60-120 s) on EVERY turn. Converging every
#   lane on the 74B tag keeps ONE model resident, which is exactly the property the
#   tracked config's own notes describe for the e4b era.
#
# WHAT THIS COSTS, HONESTLY: the 74B is slow. Measured here: cold load 61-120 s,
#   41 s for a json_schema tool call, 43 s for a 2048-token memory extraction,
#   2.8-3.3 s warm for a title. That is the price of the deeper model; the shipped
#   e4b default is ~12x faster per token on a tool chain (22.3 s vs 278.0 s).
#
# WHY IT IS SAFE HERE AND NOWHERE ELSE: this is a Ryzen AI MAX+ 395 / Radeon 8060S
#   box with a 96 GiB unified-memory carve-out. The shipped client class is HX370 /
#   RX 7600 XT with 16 GB of dedicated VRAM, where this tag is 24.0 GB = OVER_CAP and
#   pages ~20 GB from disk per token. The tag is deliberately absent from
#   ollama-models.txt (the client pre-pull contract); it is pulled here by hand.
#
# CAVEAT: picking a NON-74B model in the picker re-introduces the eviction thrash,
#   because the auxiliary lanes stay on the 74B. Same class of caveat the tracked
#   config already has for ornith. Use the fast 7.5B entries when you want speed.
# SECOND CAVEAT: other containers use the e4b tag too (PACGATE_MODEL_MID/LOW in .env,
#   and open-webui), and a generation there evicts the 74B. That is outside deer-flow.
# {"=" * 78}

"""

MEMORY_ENTRY = f"""
  # Machine-local: 74B twin of nemotron-bolt-7b-memory. Same tag as the chat entry so
  # the memory lane never evicts the model the chat is using. The hard 2048 cap is
  # kept: memory facts are short JSON and an unbudgeted generation here holds the
  # single runner slot. `when_thinking_disabled` is load-bearing - without it all
  # 2048 tokens go to invisible reasoning and content comes back empty.
  - name: {MEM74}
    display_name: Nemotron 3.5 Bolt 74B (Memory, capped)
    description: Internal 74B model for background memory updates. Hard 2048-token cap.
    use: langchain_openai:ChatOpenAI
    model: {TAG74}
    api_key: ollama
    base_url: http://host.docker.internal:11434/v1
    max_tokens: 2048
    temperature: 0.1
    stream_chunk_timeout: 600
    supports_thinking: true
    supports_reasoning_effort: true
    when_thinking_disabled:
      reasoning_effort: none
"""

POINTER = """\
  # Machine-local: the 74B entry that the tracked config keeps commented out is
  # ACTIVATED in this file and moved to the TOP of `models:` (see the banner at the
  # top of this file). It is deliberately NOT left here too - one entry, one place.
"""


def main() -> int:
    if not SRC.exists():
        raise SystemExit(f"tracked config not found: {SRC}")

    lines = SRC.read_text(encoding="utf-8").split("\n")

    # 1. Extract the commented 74B block out of the tracked config.
    try:
        start = next(
            i for i, line in enumerate(lines) if line.strip() == f"# - name: {BOLT74}"
        )
    except StopIteration:
        raise SystemExit(
            f"tracked config no longer contains a commented '`# - name: {BOLT74}`' block. "
            "The tracked file moved - update this generator instead of hand-editing "
            "deer-flow-config.local.yaml."
        ) from None

    end = start
    while end + 1 < len(lines) and re.match(r"^  #(\s{2,}\S|\s*$)", lines[end + 1]):
        end += 1
    block = [re.sub(r"^  # ?", "  ", line) for line in lines[start : end + 1]]
    if not any(TAG74 in line for line in block):
        raise SystemExit(f"extracted block does not mention {TAG74}; refusing to write")

    # The tracked labels call this entry "Optional, slow" - accurate there, misleading
    # here, where it IS the picker default. Relabel for this machine only.
    block = [
        re.sub(
            r"^(\s+display_name:).*$",
            r"\1 Nemotron 3.5 Bolt 74B (Local default)",
            line,
        )
        if re.match(r"^\s+display_name:", line)
        else re.sub(
            r"^(\s+description:).*$",
            r"\1 LOCAL default on this machine. Deeper reasoning, 24.8 GB. Slower than the 7.5B.",
            line,
        )
        if re.match(r"^\s+description:", line)
        else line
        for line in block
    ]

    # 2. Replace the commented block with a pointer - never duplicate the entry.
    lines = lines[:start] + POINTER.rstrip("\n").split("\n") + lines[end + 1 :]

    # 3. Insert the two 74B entries as the first ACTIVE entries under `models:`.
    models_idx = lines.index("models:")
    entry = [
        "",
        "  # ── MACHINE-LOCAL DEFAULT: nemotron-3.5-bolt 74B ──────────────────────────",
        "  # FIRST entry on purpose: `models[0]` IS the picker default (agent.py takes",
        "  # default_model_name = app_config.models[0].name, and the frontend falls back",
        "  # to models[0] when a thread has no model yet).",
        "",
        *block,
        *MEMORY_ENTRY.rstrip("\n").split("\n"),
        "",
    ]
    lines = lines[: models_idx + 1] + entry + lines[models_idx + 1 :]

    # 4. Repoint the lanes that would otherwise keep the e4b resident (see banner).
    def retarget(pattern: str, replacement: str, expected: int) -> None:
        hits = 0
        for i, line in enumerate(lines):
            new = re.sub(pattern, replacement, line)
            if new != line:
                lines[i] = new
                hits += 1
        if hits != expected:
            raise SystemExit(
                f"{pattern!r}: expected {expected} hit(s), got {hits}. The tracked "
                "config's lane pins moved - update this generator deliberately."
            )

    retarget(r"^(\s+)model_name: nemotron-bolt-7b-memory$", r"\1model_name: " + MEM74, 1)
    retarget(r"^(\s+)model_name: nemotron-bolt-7b-local$", r"\1model_name: " + BOLT74, 2)
    retarget(r"^(\s+)local_model: nemotron-bolt-7b-local$", r"\1local_model: " + BOLT74, 1)
    retarget(r"^(\s+)cloud_model: nemotron-bolt-7b-local$", r"\1cloud_model: " + BOLT74, 1)

    DST.write_text(BANNER + "\n".join(lines), encoding="utf-8")
    print(f"wrote {DST}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
