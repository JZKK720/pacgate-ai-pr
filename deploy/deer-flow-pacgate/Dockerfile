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
RUN ln -sf /app/backend/.venv/bin/markitdown /usr/local/bin/markitdown

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