# Pacgate QM sandbox layer — extends the digest-pinned qm sandbox-base with
# document-conversion capability and the deployment-layer tool binaries.
#
# Build: npm exec qm -- sandbox build   (from deploy/qm-pacgate/)
#
# NOTE: when a custom sandbox/Dockerfile exists, the qm CLI does NOT generate
# the COPY lines for tools/<id>/<binary> (that only happens in the no-Dockerfile
# path), so this Dockerfile must COPY the tool launchers itself. Each tool
# launcher is a bash script that `exec python3 <script>.py`, so both files are
# copied and the launcher is made executable.
FROM ghcr.io/yc-software/qm/sandbox-base@sha256:52cb44a6e9d166da20638c8ce55e3f423384f5557eba49915684cb8ed16e5873

# markitdown pulls mammoth (docx), openpyxl (xlsx), python-pptx (pptx) and
# pdfminer-based readers as dependencies — one install covers the office
# formats the firm's clients send. Installed into the image's agent venv so
# `markitdown` is on PATH for sandbox scripts and `python3 -c` one-liners.
RUN /opt/agent-venv/bin/pip install --no-cache-dir markitdown

# Pacgate: bake the document-conversion CLI so the QM agent can convert
# generated markdown to docx/pdf/html/txt (the MD->docx/pdf direction).
# pandoc is the office-cli (MD->docx/html/txt); weasyprint is its PDF engine
# (MD->pdf). python-docx + markdown give a pure-Python fallback for docx
# generation. markitdown (PDF/DOCX/PPTX/XLSX -> MD) is already installed above.
# fonts-noto-cjk is REQUIRED for Chinese PDF/DOCX rendering (weasyprint/pandoc
# render blank CJK text without it).
RUN apt-get update && apt-get install -y --no-install-recommends \
    pandoc weasyprint fonts-noto-cjk \
    && rm -rf /var/lib/apt/lists/* \
    && /opt/agent-venv/bin/pip install --no-cache-dir python-docx markdown

# Deployment-layer tool binaries (qm CLI only auto-COPYs these when there is no
# custom Dockerfile — see qm dist/src/commands/sandbox.js prepare()).
COPY tools/pacgate-qm/pacgate-qm /usr/local/bin/pacgate-qm
COPY tools/pacgate-qm/pacgate_qm.py /usr/local/bin/pacgate_qm.py
COPY tools/firecrawl-qm/firecrawl-qm /usr/local/bin/firecrawl-qm
COPY tools/firecrawl-qm/firecrawl_qm.py /usr/local/bin/firecrawl_qm.py
RUN chmod -R a+rx /usr/local/bin