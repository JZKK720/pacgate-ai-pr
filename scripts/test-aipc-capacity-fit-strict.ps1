# Thin wrapper so the suite can run the capacity gate in SHIPPING mode.
#
# WHY THIS EXISTS. run-all-checks.ps1 invokes each gate as
# `& $psLauncher -NoProfile -File $s` with no arguments, but
# test-aipc-capacity-fit.ps1 only fails when given -Strict. Registering the
# capacity script itself in the gate list would therefore keep passing while an
# over-cap model shipped - which is exactly what happened: the script already
# knew about a 25 GB entry, and it sat in the measurements list, whose whole
# contract is to ignore the exit code.
#
# The interactive command (`test-aipc-capacity-fit.ps1` with no flag) stays
# advisory on purpose: the 96 GiB dev box can run all of it, and a developer
# should not be blocked from seeing the full size table.

[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'test-aipc-capacity-fit.ps1') -Strict
exit $LASTEXITCODE
