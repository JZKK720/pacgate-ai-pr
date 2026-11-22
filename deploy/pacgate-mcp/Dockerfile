FROM python:3.12-slim

WORKDIR /app

# `docx-scalpel` ships a SELF-CONTAINED .NET host binary
# (`docx_scalpel/_bin/docxodus-pyhost`, ~156 MB) for redlines. It is not a native
# extension - it is a .NET single-file app - and .NET fails at startup with
#
#   Couldn't find a valid ICU package installed on the system.
#
# on a slim base image. Measured 2026-11-22: without this the host binary aborts
# instantly and EVERY redline call raises `DocxodusTransportError: host exited
# unexpectedly`, while the same code works on a Windows dev box that has ICU via
# the OS. `libicu-dev` pulls the runtime lib; the rest are the usual .NET
# single-file dependencies (the binary is self-contained but still needs the base
# C library and OpenSSL).
RUN apt-get update && apt-get install -y --no-install-recommends \
        libicu-dev \
        libssl3 \
        libstdc++6 \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Copy requirements first for layer caching
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY server.py .
# redline.py sits beside server.py because server.py imports it lazily
# (`import redline`) on the first pacgate_redline_* call. Without this COPY the
# three redline tools load, advertise, and then fail on first use with
# ModuleNotFoundError - which the tool-surface gate cannot see, because it only
# asserts the ADVERTISED set.
COPY redline.py .

EXPOSE 8000

# Use a heredoc-safe CMD: the module runs its own streams via mcp.run()
CMD ["python", "server.py"]
