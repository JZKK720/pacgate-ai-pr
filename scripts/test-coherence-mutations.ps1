# Mutation test for scripts/test-stack-version-coherence.ps1.
#
# WHY THIS SUITE EXISTS
#
# That gate was green for months while asserting the wrong thing. It compared the
# container's `.Config.Image` - the string the container was CREATED WITH -
# against the compose pin. Both operands come from the same compose file, so the
# comparison was a tautology: it could only fail if someone hand-edited a pin, and
# it could never see a RE-POINTED TAG.
#
# On 2026-11-22 that blind spot shipped a real defect: a local build took the
# `0.2.37` tag, the stack was deployed from it, and a later `docker pull`
# re-pointed the tag at the published image. `ocr-service` kept executing the
# locally-built bytes with no tag at all, under a pin naming the published
# release, and this gate reported PASS throughout.
#
# Reproduced before the fix on the REAL stack: re-pointing
# `pacgate-api:0.2.37` at `alpine:3.20` while the container kept running the
# release printed "16 passed ... every running service is the image its compose
# pin names" and exited 0.
#
# So the gate is now identity-based. This suite proves the new assertions can
# actually reject - the field, and the comparison that consumes it - rather than
# trusting a green run on a coherent stack, which is precisely how the old
# assertion survived so long.
#
# Exit codes: 0 = every mutation rejected and every file restored,
#             1 = a mutation was ACCEPTED (the gate is blind), or a restore failed.

$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')

. (Join-Path $PSScriptRoot 'lib/mutation-harness.ps1')

$gate = 'scripts/test-stack-version-coherence.ps1'

Write-Host '=== Mutation test: stack version coherence ==='
Write-Host ''

$mutations = @(
    # --- the field: create-time tag string instead of the running digest -----
    #
    # This is the ORIGINAL defect, restored exactly. It must fail
    # 'the gate inspects the RUNNING digest, not the create-time tag string'.
    @{ N = 'the gate goes back to the create-time tag string'
       File = $gate
       From = "docker inspect `$cn --format '{{.Image}}'"
       To   = "docker inspect `$cn --format '{{.Config.Image}}'"
       Want = 'the gate inspects the RUNNING digest, not the create-time tag string' }

    # --- the comparison: correct field, ignored operand ---------------------
    #
    # A verdict that reads the right digest and decides anyway. Invisible on a
    # coherent stack, which is why it is asserted structurally.
    @{ N = 'the verdict reads the running digest and ignores it'
       File = $gate
       From = '$ok = ($runningId -eq $tagId)'
       To   = '$ok = ($runningId -ne '''')'
       Want = 'the verdict compares the running digest against the tag digest' }

    # --- the discrimination helper -----------------------------------------
    #
    # A helper that always answers "same" would pass both the coherent stack and
    # the accept-case above.
    @{ N = 'the identity helper always answers "same"'
       File = $gate
       From = 'return ($tagId -eq $runningId)'
       To   = 'return $true'
       Want = 'identity comparison DETECTS a re-pointed tag (so the gate can fail)' }
)

$ok = Invoke-MutationSuite -Mutations $mutations -SuiteScript $gate -GuardPaths @($gate)

if (-not $ok) { exit 1 }
exit 0
