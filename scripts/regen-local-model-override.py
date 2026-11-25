"""Regenerate deploy/client-bundle/deer-flow-config.local.yaml (machine-local override).

    python scripts/regen-local-model-override.py
    python scripts/regen-local-model-override.py --promote glm-5.3-flash-cloud

THIS GENERATES A GITIGNORED FILE. Nothing here changes the shipped client contract:
`deploy/client-bundle/deer-flow-config.yaml`, `ollama-models.txt`, both compose lanes
and every image are untouched. See deploy/LOCAL-MODEL-PICKER-74B.md for the reasoning.

TWO MODES:

  (default)   Activate the commented-out 74B entry and make it `models[0]`. For a box
              with a large unified-memory carve-out. See the banner below.

  --promote   Move an ALREADY-ACTIVE roster entry to `models[0]` and converge the five
              auxiliary lane pins on it. Nothing is added, because the tracked config
              already carries the cloud entries and keeps the tracked file the single
              source of truth. This is the correct mode when no LOCAL tag fits the
              host's VRAM - measured 2026-10-05 on a 4 GB Radeon 8060S, where the
              shipped default is 9.09 GB and the smallest local tag is 6.10 GB, so
              every local run died at load and audit-post-deploy stage 8 could not be
              evaluated at all. A cloud tag loads by definition: no weights on disk.

Which mode? Run `scripts/test-aipc-capacity-fit.ps1 -Vram <host GB>` first. If it says
every local entry is OVER_CAP for this host, use --promote.

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

# ── capacity mode ────────────────────────────────────────────────────────────
#
# The 74B mode above exists for THIS box class (96 GiB unified carve-out). It is the
# wrong answer on a small GPU, and on 2026-10-05 that mattered: this machine has an
# AMD Radeon 8060S with 4 GB of VRAM, so the shipped picker default
# (nemotron-3.5-bolt:e4b-q8_0, 9.09 GB) and every other local tag (6.10-24.24 GB)
# fails to load. Direct probes died both on the GPU path and on the CPU fallback,
# and audit-post-deploy stage 8 could not be evaluated at all.
#
# `--promote <entry>` is the general form: it does not ADD a model, it MOVES an
# already-active roster entry to `models[0]` and converges the five auxiliary lane
# pins on it. That is all that is needed to promote a cloud entry, because the cloud
# entries already exist and are already active - they are simply not first. Nothing
# in the shipped contract changes; this still writes a gitignored file.
#
# The lane convergence is the same requirement the 74B mode documents: a lane left on
# a different tag forces an evict + cold reload. For cloud tags the reload is a network
# round trip rather than a disk load, but the wasted turn time is the same class of bug.


def _entry_bounds(lines: list[str], name: str) -> tuple[int, int]:
    """Return the [start, end] line span of an active roster entry named `name`."""
    try:
        start = next(
            i for i, line in enumerate(lines) if line.strip() == f"- name: {name}"
        )
    except StopIteration:
        raise SystemExit(
            f"no ACTIVE roster entry named {name!r}. --promote only moves entries that "
            "already exist in the tracked config, so that the tracked config stays the "
            "single source of truth. Available entries:\n  "
            + "\n  ".join(
                ln.strip().removeprefix("- name: ")
                for ln in lines
                if re.match(r"^  - name: ", ln)
            )
        ) from None
    end = start
    while end + 1 < len(lines) and re.match(r"^  [\s\S]*\S", lines[end + 1]):
        end += 1
    return start, end


def promote_entry(lines: list[str], name: str) -> list[str]:
    """Move an existing active entry to models[0] and converge the lane pins on it."""
    start, end = _entry_bounds(lines, name)
    block = lines[start : end + 1]
    tag_line = next((l for l in block if re.match(r"^\s+model:\s", l)), None)
    if not tag_line:
        raise SystemExit(f"entry {name!r} has no `model:` line; refusing to promote it")
    tag = tag_line.split("model:", 1)[1].strip()

    # Relabel: the tracked copy may call a cloud entry "requires ollama signin" and a
    # local one "fits a 16 GB AIPC card" - both misleading where it is now the default.
    # The value is QUOTED because it contains a colon, and an unquoted `foo: bar` inside
    # a YAML scalar is a parse error ("mapping values are not allowed here"). Measured
    # 2026-10-05: without the quotes deer-flow refused to start at all.
    new_desc = (
        f"LOCAL MACHINE DEFAULT. Promoted to models[0] because no local tag fits "
        f"this host VRAM. Backing tag {tag}."
    )
    block = [
        f'    description: "{new_desc}"'
        if re.match(r"^\s+description:", line)
        else line
        for line in block
    ]

    lines = lines[:start] + lines[end + 1 :]
    models_idx = lines.index("models:")
    entry = [
        "",
        f"  # ── MACHINE-LOCAL DEFAULT: {name} ─────────────────────────────────────────",
        "  # FIRST entry on purpose: `models[0]` IS the picker default (agent.py takes",
        "  # default_model_name = app_config.models[0].name, and the frontend falls back",
        "  # to models[0] when a thread has no model yet).",
        "",
        *block,
        "",
    ]
    lines = lines[: models_idx + 1] + entry + lines[models_idx + 1 :]

    # Converge every auxiliary lane onto the promoted entry, including the
    # `cloud_model: nemotron-bolt-7b-local` pin - the tracked config uses that name as
    # its "heavy lift" alias, and the promoted entry serves that role here.
    pins = [
        ("model_name", "nemotron-bolt-7b-local", 2),
        ("local_model", "nemotron-bolt-7b-local", 1),
        ("cloud_model", "nemotron-bolt-7b-local", 1),
    ]
    for key, old, expected in pins:
        pattern = re.compile(rf"^(\s+){key}: {re.escape(old)}$")
        hits = 0
        for i, line in enumerate(lines):
            if pattern.match(line):
                lines[i] = pattern.sub(rf"\g<1>{key}: {name}", line)
                hits += 1
        if hits != expected:
            raise SystemExit(
                f"{key}: {old!r}: expected {expected} hit(s), got {hits}. The tracked "
                "config's lane pins moved - update this generator deliberately."
            )
    return lines



def main() -> int:
    import argparse

    ap = argparse.ArgumentParser(
        description="Generate the gitignored machine-local deer-flow config override."
    )
    ap.add_argument(
        "--promote",
        metavar="ENTRY",
        help="Move an ALREADY-ACTIVE roster entry (e.g. glm-5.3-flash-cloud) to "
        "models[0] and converge the auxiliary lane pins on it. Use this when no local "
        "tag fits the host's VRAM.",
    )
    args = ap.parse_args()

    if not SRC.exists():
        raise SystemExit(f"tracked config not found: {SRC}")

    # The output is a YAML file consumed by deer-flow at gateway startup, so a parse
    # error is not cosmetic: measured 2026-10-05, one unquoted `description:` containing
    # "tag: glm-5.3-flash-cloud" crash-looped the container with
    #   RuntimeError: Failed to load configuration during gateway startup:
    #   mapping values are not allowed here
    # Validate before writing so this class of bug cannot leave a broken mount behind.
    def _require_valid_yaml(text: str, label: str) -> None:
        try:
            import yaml  # type: ignore
        except ImportError:
            return  # optional; the guard is best-effort on machines without PyYAML
        try:
            yaml.safe_load(text)
        except Exception as exc:  # noqa: BLE001 - surface any parser error verbatim
            raise SystemExit(f"refusing to write {label}: invalid YAML ({exc})") from exc

    lines = SRC.read_text(encoding="utf-8").split("\n")

    if args.promote:
        lines = promote_entry(lines, args.promote)
        header = f"""\
# {"=" * 78}
# MACHINE-LOCAL OVERRIDE - NOT SHIPPED, NOT FOR CLIENTS. Generated file.
#
# Regenerate with: python scripts/regen-local-model-override.py --promote {args.promote}
# Read by deer-flow only when compose.local-model-override.yaml is merged in.
#
# WHY: no LOCAL model tag fits this host's VRAM, so the shipped picker default cannot
# load at all and every agent run fails at model startup. `{args.promote}` is an
# already-active entry in the tracked config; this file only moves it to `models[0]`
# (the picker default) and converges the five auxiliary lane pins onto it, so a lane
# left on a different tag cannot force an evict on every turn.
#
# The tracked config, ollama-models.txt, the images and every client are untouched.
# {"=" * 78}

"""
        _require_valid_yaml(header + "\n".join(lines), DST.name)
        DST.write_text(header + "\n".join(lines), encoding="utf-8")
        print(f"wrote {DST} (promoted {args.promote} to models[0])")
        return 0


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

    retarget(r"^(\s{6})model: nemotron-3\.5-bolt:e4b-q8_0$", r"\1model: " + MEM74, 1)
    retarget(r"^(\s+)model_name: nemotron-bolt-7b-local$", r"\1model_name: " + BOLT74, 2)
    retarget(r"^(\s+)local_model: nemotron-bolt-7b-local$", r"\1local_model: " + BOLT74, 1)
    retarget(r"^(\s+)cloud_model: nemotron-bolt-7b-local$", r"\1cloud_model: " + BOLT74, 1)

    _require_valid_yaml(BANNER + "\n".join(lines), DST.name)
    DST.write_text(BANNER + "\n".join(lines), encoding="utf-8")
    print(f"wrote {DST}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
