# Mutation test for the qm bootstrap + port-coupling checks.
#
# Same reasoning as test-workflow-mutations.ps1: a check that cannot fail reports
# as coverage. The port-coupling assertions were added because R1 of
# deploy/qm-pacgate/INTEGRATION-MAP.md was an unvalidated assumption - qm reaches
# the main stack only over hardcoded HOST ports, and nothing checked the two files
# agreed. If those assertions cannot go red, R1 is still unvalidated and we have
# only added a green line.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Set-Location (Split-Path -Parent $PSScriptRoot)

. (Join-Path $PSScriptRoot 'lib/mutation-harness.ps1')

$prod = 'deploy/client-bundle/compose.prod.yaml'
$qmCfg = 'deploy/qm-pacgate/qm.config.jsonc'
$setup = 'deploy/client-bundle/setup-qm.ps1'
$test = './scripts/audit-qm-bootstrap.ps1'

Write-Host '=== Mutation test: qm bootstrap + port coupling ==='
Write-Output ''

$mutations = @(
    # --- port coupling (R1) -------------------------------------------------
    @{ N = 'the main stack stops publishing a port qm reaches'
       File = $prod
       Rx   = '(?m)^\s*-\s*"8089:80"\s*$'
       To   = '      - "8088:80"'
       Want = 'the main stack publishes host port 8089, which qm reaches via host.docker.internal' }

    @{ N = 'qm reaches a host port the main stack does not publish'
       File = $qmCfg
       From = 'http://host.docker.internal:8089/pacgate'
       To   = 'http://host.docker.internal:9999/pacgate'
       Want = 'the main stack publishes host port 9999, which qm reaches via host.docker.internal' }

    @{ N = 'a qm host-port coupling is removed by retyping the URL'
       File = $qmCfg
       From = 'http://host.docker.internal:1933'
       To   = 'http://host.docker.internal:11434/api'
       Want = 'qm still reaches every documented host port' }

    @{ N = 'qm ports collide with a published main-stack port'
       File = $qmCfg
       From = '"basePort": 8180,'
       To   = '"basePort": 8089,'
       Want = 'qm ports do not collide with main-stack published ports' }

    @{ N = 'the basePort declaration is removed'
       File = $qmCfg
       Rx   = '"basePort"\s*:\s*\d+,?\r?\n'
       To   = ''
       Want = 'qm basePort parsed from qm.config.jsonc' }

    # --- bootstrap completeness ---------------------------------------------
    @{ N = 'a required variable is dropped from the generated .env'
       File = $setup
       Rx   = '(?m)^POSTGRES_PASSWORD=[^\r\n]*\r?\n'
       To   = ''
       Want = 'missing required variable: POSTGRES_PASSWORD' }

    # --- staging ------------------------------------------------------------
    @{ N = 'the staging copy is removed'
       File = $setup
       Rx   = 'Copy-Item[^\r\n]*'
       To   = '# removed'
       Want = 'contains a Copy-Item that stages it' }

    @{ N = 'the staging copy starts clobbering .env'
       File = $setup
       Rx   = "exclude\s*=\s*@\(\s*'\.env',\s*"
       To   = 'exclude = @('
       Want = 'excludes .env, so a re-run cannot destroy generated secrets' }
)

$ok = Invoke-MutationSuite -Mutations $mutations -SuiteScript $test -GuardPaths @($prod, $qmCfg, $setup)

if (-not $ok) { exit 1 }
exit 0
