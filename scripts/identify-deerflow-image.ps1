# Determine which deer-flow architecture a published image implements:
#   (A) pacgate-ai/deer-flow @ pacgate-layer  -> all-in-one: backend+frontend+skills
#       (pacgate_config.py, /app/skills/public, nginx+supervisor, ports 2026/8001/3000)
#   (B) pacgate-ai/pacgate-ai-pr wrapper      -> wrapped upstream backend + separate frontend
param(
    [string]$Image = 'ghcr.io/pacgate-ai/deer-flow-pacgate:0.1.10'
)

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
