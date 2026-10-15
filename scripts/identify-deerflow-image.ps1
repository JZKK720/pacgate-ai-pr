# Determine which deer-flow architecture a published image implements:
#   (A) pacgate-ai/deer-flow @ pacgate-layer  -> all-in-one: backend+frontend+skills
#       (pacgate_config.py, /app/skills/public, nginx+supervisor, ports 2026/8001/3000)
#   (B) pacgate-ai/pacgate-ai-pr wrapper      -> wrapped upstream backend + separate frontend
param(
    # Empty = ghcr.io/<release namespace>/deer-flow-pacgate:latest, with the
    # namespace read from the workflow's GHCR_NAMESPACE. This default used to be
    # a literal `ghcr.io/pacgate-ai/deer-flow-pacgate:0.1.10` - the read-only
    # mirror plus a tag two releases old - so it silently inspected a stale image
    # from a namespace that publishes nothing.
    [string]$Image = ''
)

# 'Stop' is scoped to namespace resolution only. It is deliberately relaxed again
# below: the probe is a `docker run ... 2>&1`, and on Windows PowerShell 5.1 a
# native command writing to stderr becomes a TERMINATING error under 'Stop' even
# with 2>&1. A missing marker inside a container is normal output for a
# fingerprinting tool, not a reason to abort.
$ErrorActionPreference = 'Stop'
if (-not $Image) {
    $Ns = 'jzkk720'
    $wf = Join-Path (Split-Path -Parent $PSScriptRoot) '.github/workflows/build-ghcr.yml'
    if (Test-Path -LiteralPath $wf) {
        $m = Select-String -LiteralPath $wf -Pattern '^\s*GHCR_NAMESPACE:\s*(\S+)' | Select-Object -First 1
        if ($m) { $Ns = $m.Matches[0].Groups[1].Value.Trim() }
    }
    $Image = "ghcr.io/$Ns/deer-flow-pacgate:latest"
}
$ErrorActionPreference = 'Continue'

$probe = @'
echo "--- pacgate-layer python modules ---"
for f in pacgate_config.py pacgate_routing_middleware.py pacgate_hard_gates_middleware.py; do
  p=$(find / -name "$f" -not -path "*/node_modules/*" 2>/dev/null | head -1)
  echo "  $f -> ${p:-ABSENT}"
done
echo "--- 34 legal skills (/app/skills/public) ---"
if [ -d /app/skills/public ]; then
  echo "  PRESENT: $(ls /app/skills/public 2>/dev/null | wc -l) entries"
  ls /app/skills/public 2>/dev/null | head -6 | sed 's/^/    /'
else
  echo "  ABSENT"
fi
echo "--- matters router ---"
find / -type d -name matters -not -path "*/node_modules/*" 2>/dev/null | head -3 | sed 's/^/  /'
echo "--- frontend baked in? (all-in-one marker) ---"
if [ -f /app/frontend/package.json ]; then echo "  /app/frontend PRESENT"; else echo "  /app/frontend ABSENT"; fi
echo "--- entrypoint / process model ---"
echo "  CMD: $(cat /proc/1/cmdline 2>/dev/null | tr '\0' ' ')"
which nginx supervisord pacgate-entrypoint.sh 2>/dev/null | sed 's/^/  /'
echo "--- exposed ports ---"
sed -n '/EXPOSE/p' /dev/null 2>/dev/null
echo "--- backend layout ---"
ls -d /app/backend 2>/dev/null && echo "  backend venv: $(ls /app/backend/.venv/bin/python 2>/dev/null || echo none)"
echo "--- officecli / converters ---"
which officecli pandoc weasyprint markitdown 2>/dev/null | sed 's/^/  /'
echo "--- adapter (wrapper-build marker) ---"
find / -name "*pacgate_deerflow_adapter*" -o -name "pacgate_adapters" -type d 2>/dev/null | head -3 | sed 's/^/  /'
'@

Write-Output ("=" * 74)
Write-Output "IMAGE: $Image"
Write-Output ("=" * 74)
docker run --rm --entrypoint sh $Image -c $probe 2>&1
