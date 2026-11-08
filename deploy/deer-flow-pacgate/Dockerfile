# Deer-flow wrapper image for Pacgate-ai
# Layers the pacgate_deerflow_adapter on top of deer-flow's published backend image.
# Never forks deer-flow source — the adapter is pip-installed on top.

FROM ghcr.io/bytedance/deer-flow-backend@sha256:e7c503a803c99a039e08da61359932877a9e0d0196799429698244117338af13

# Copy the adapter package
COPY pacgate-adapters/python/pacgate_deerflow_adapter /app/adapters/pacgate_deerflow_adapter

# Install the adapter package globally and also expose the copied source tree on
# PYTHONPATH, because DeerFlow itself runs from /app/backend via `uv run --no-sync`.
RUN pip install --no-cache-dir /app/adapters/pacgate_deerflow_adapter

# Pacgate: bake the document-conversion CLI so the agent's sandbox bash tool can
# convert generated markdown to docx/pdf/html/txt (the MD->docx/pdf direction).
# pandoc is the office-cli (MD->docx/html/txt); weasyprint is its PDF engine
# (MD->pdf). Both land in /usr/bin, which is on the agent's bash PATH and in the
# sandbox system-path allowlist, so the agent can call them directly. markitdown
# (PDF/DOCX/PPTX/XLSX -> MD) is already in the image venv at
# /app/backend/.venv/bin and is reachable via the pacgate_convert_document MCP
# tool. apt-get update is required because the base image's package lists are
# not refreshed at build time.
#
# fonts-noto-cjk is REQUIRED for Chinese PDF/DOCX rendering: the base image ships
# zero CJK glyphs, so `pandoc --pdf-engine=weasyprint` produced blank/boxed Chinese
# text. Without these fonts, weasyprint/pandoc cannot render any CJK content.
RUN apt-get update && apt-get install -y --no-install-recommends \
    pandoc weasyprint fonts-noto-cjk \
    && rm -rf /var/lib/apt/lists/*

# Pacgate: expose markitdown on the agent's PATH. markitdown lives in the image
# venv (/app/backend/.venv/bin) which is NOT on the agent's bash PATH and whose
# absolute path is blocked by the sandbox path-validation allowlist. Symlinking
# it into /usr/local/bin (on PATH + in the allowlist) lets the agent run
# `markitdown <file>` directly for PDF/DOCX/PPTX/XLSX -> MD on demand.
# Pacgate 2026-10-27: bake the windowed loop-detection middleware into the image.
# At the pinned v2.0.0 base, Layer 2 kept a MONOTONIC same-tool counter cleared
# only by reset() (which the gateway never calls), so a productive document run
# was force-stopped mid-work at 50 bash calls ("[FORCED STOP] Tool bash called 50
# times", thread 6cc8dfae, 92 calls / 71 bash / 55 distinct commands). The file
# backports upstream e492bb1c (#4072) + 4746a257 (#4295).
#
# BAKED rather than only bind-mounted so the standalone image - and any lane that
# forgets the mount - still has the fix. The client compose lanes ALSO mount it,
# which is intentional: the mount is what lets the fix ship without an image
# rebuild, and both point at the same file, so they cannot diverge. REMOVE BOTH at
# the 2.1.0 rebase - but NOT because v2.1.0 carries these commits (measured
# 2026-10-27: it does not; it keys its counters per run instead). Remove it because
# v2.1.0 has an equivalent-or-stronger fix of its own. The loop_detection CONFIG
# block is KEPT at the rebase - its keys are unchanged at v2.1.0.
COPY deploy/client-bundle/patches/deer-flow-loop-detection.py /app/backend/packages/harness/deerflow/agents/middlewares/loop_detection_middleware.py

# Pacgate 2026-10-28: clamp the lead-agent recursion budget. The chat UI sends
# recursion_limit: 1000 per run and build_run_config() let that overwrite its own
# 100 default, so a thrashing run spent all 1000 supersteps (~16 min, 3M+ tokens)
# before failing with a bare GraphRecursionError. Mounted in both compose lanes
# too; the ceiling is DEERFLOW_MAX_RECURSION_LIMIT (default 4000 as of 0.2.8 -
# it was 500, which measured below three successful runs' super-step counts).
#
# NOTE (2026-10-30): this COPY used to claim the bake and the mount "cannot
# diverge" because they point at the same file. That is only true if the file never
# changes between builds. Measured on the 0.2.7 image: its baked copy still reads
# `{"recursion_limit": 100}` while the tracked source now defaults to the ceiling.
# The running stack is correct because the mount wins; the image is stale. Any run
# WITHOUT the mount - a bare `docker run`, a debug shell, a lane that forgets the
# mount - would silently reintroduce the 100 floor.
#
# scripts/test-baked-patch-parity.ps1 now asserts that a baked patch always has a
# shadowing mount in both lanes (so a stale bake can only be masked, never live)
# and reports the drift so the rebuild is a known task rather than a surprise.
COPY deploy/client-bundle/patches/deer-flow-run-recursion-cap.py /app/backend/app/gateway/services.py

RUN ln -sf /app/backend/.venv/bin/markitdown /usr/local/bin/markitdown

# Pacgate 2026-11-06: strip pymupdf4llm's inline HTML from heading titles.
#
# pymupdf4llm 2.1 wraps highlighted heading text in <mark> and uses <br> for line
# breaks INSIDE a heading. Measured on the 65-page CJK tutorial PDF: 118 <mark>
# and 335 <br> in the converted markdown, and 59 of 241 headings arrived as
# "**<mark>1.1 ...</mark>**".
#
# Those titles are not cosmetic. UploadsMiddleware renders them into the agent's
# prompt as the "Document outline" section, so the markup was spending prompt
# tokens on tags and obscuring the text the agent matches a question against.
#
# BAKED as well as mounted, for the same reason the loop-detection patch is: a
# standalone `docker run` of this image - or any lane that forgets the mount -
# must not reintroduce the defect. Both compose lanes also mount it so a fix can
# ship without an image rebuild, and scripts/test-baked-patch-parity.ps1 asserts
# the bake and the mount never point at different code.
COPY deploy/client-bundle/patches/deer-flow-file-conversion.py /app/backend/packages/harness/deerflow/utils/file_conversion.py

# Pacgate 2026-11-06: install pymupdf4llm so the PREFERRED PDF->Markdown path runs.
#
# MEASURED (this box, 2026-11-06). deerflow/utils/file_conversion.py already
# tries pymupdf4llm first and falls back to MarkItDown only when the module is
# missing or the output looks image-based. pymupdf4llm was NOT in the image, so
# every upload took the fallback - and MarkItDown does not reproduce the source
# PDF's typographic hierarchy.
#
# Same 65-page structured PDF, same convert_file_to_markdown() call:
#     MarkItDown (what the image actually ran):   0 outline entries, 0 `#` lines
#     pymupdf4llm (the path the code asks for) : 51 outline entries
# The PDF carries a clean 4-level hierarchy (body 10.4pt; headings at 11.2 /
# 13.0 / 19.0 / 33.0pt) that MarkItDown flattens completely.
#
# CONSEQUENCE THAT MADE THIS A BUG, not a quality nit. With no headings,
# UploadsMiddleware emits "No structural headings detected" and no section map,
# so the agent has no navigable view of a 141 KB document. On thread b315a961
# that produced three consecutive runs of 87-104 bash calls re-reading the same
# file (103, 52 and 42 re-touches) and 3.2-3.5M tokens each, all three killed by
# GraphRecursionError with no deliverable. The prompt's convergence block cannot
# fix a task whose structure the model was never shown.
#
# NOTE ON THE DEPENDENCY SET: the base venv is uv-managed and ships NO pip, so
# this uses `uv pip install` against the interpreter explicitly. Keep the
# `--python` flag - a bare `uv pip install` in this image resolves its own
# environment and silently does nothing to /app/backend/.venv.
#
# RapidOCR is optional: pymupdf4llm prints one "RapidOCR is missing" notice and
# continues. Image-only PDFs still fall back to MarkItDown via
# _pymupdf_output_too_sparse(), exactly as before, so text-less scans are
# unaffected by this layer.
COPY deploy/pacgate-pins/pymupdf4llm.constraints.txt /tmp/pymupdf4llm.constraints.txt
RUN uv pip install --python /app/backend/.venv/bin/python \
      --constraint /tmp/pymupdf4llm.constraints.txt \
      pymupdf4llm \
    && rm -f /tmp/pymupdf4llm.constraints.txt \
    && /app/backend/.venv/bin/python -c "import pymupdf4llm, pymupdf; print('pymupdf4llm ok; pymupdf', pymupdf.__version__)"

# Pacgate: bake OfficeCLI so the agent can create/read/modify real Office
# documents (.docx/.xlsx/.pptx) via its `officecli mcp` stdio MCP server AND via
# the `officecli` CLI on PATH. OfficeCLI is a single self-contained .NET binary
# (no Office, no runtime deps). Pinned to a specific release tag for a
# deterministic build; the binary is fetched at build time (not runtime) so it
# survives container recreation. The URL below is the GitHub release asset
# `officecli-linux-x64` (glibc, matches Debian 12). We use python (already in
# the image) as the downloader because the base image has no curl/wget.
#
# IMPORTANT: BEST-EFFORT. Some client/CI networks egress-block `github.com`
# release *asset* downloads (verified 2026-09-13: deb.debian.org + ghcr.io work,
# github.com release HEAD times out). If the download fails, do NOT fail the
# whole image build — log and continue. The agent prompt carries a fallback
# ("if `which officecli` returns nothing, use `pandoc <file>.md -o <file>.docx`"),
# so a missing binary degrades gracefully instead of breaking the image.
ARG OFFICECLI_VERSION=v1.0.149
RUN python3 -c "import urllib.request,os,sys; \
    v=sys.argv[1]; \
    url='https://github.com/iOfficeAI/OfficeCLI/releases/download/'+v+'/officecli-linux-x64'; \
    print('fetching officecli', url); \
    d=urllib.request.urlopen(urllib.request.Request(url, headers={'User-Agent':'pacgate-build'}), timeout=180).read(); \
    open('/usr/local/bin/officecli','wb').write(d)" "$OFFICECLI_VERSION" \
    && chmod +x /usr/local/bin/officecli \
    && OFFICECLI_SKIP_UPDATE=1 officecli --version \
    || echo "WARNING: officecli download skipped (github.com unreachable on this network); agent will fall back to pandoc for docx delivery." \
    && rm -rf /tmp/*

# Ship a minimal startup-safe DeerFlow config. This keeps the wrapper bootable
# on a clean machine; runtime env can still override the memory backend inputs.
COPY deploy/deer-flow-pacgate/config.yaml /app/backend/config.yaml

# The adapter package is installed here and enabled via config.yaml. For actual
# Pacgate-backed memory, pass PACGATE_API_EMAIL/PASSWORD or PACGATE_JWT_TOKEN
# plus PACGATE_MATTER_ID at runtime.
ENV DEER_FLOW_CONFIG_PATH=/app/backend/config.yaml
ENV PYTHONPATH=/app/adapters:/app/backend
ENV PACGATE_API_URL=http://pacgate-api:8080
ENV PACGATE_TENANT_ID=default-firm

# Keep deer-flow's original startup command unchanged
CMD ["sh", "-c", "cd backend && uv run --no-sync uvicorn app.gateway.app:app --host 0.0.0.0 --port 8001"]