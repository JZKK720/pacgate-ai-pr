# Remediate kb_chunks rows that an old build mislabelled `sanitized` while leaving
# the raw text in place.
#
# WHY THIS EXISTS
#
# audit-sanitized-chunk-egress.ps1 COUNTS and NAMES the affected rows. It cannot
# fix them, and no image upgrade does either: builds up to and including 0.1.30
# stamped `sanitization_state='sanitized'` and left `content` as the raw
# extraction, and the RAG gate is `WHERE sanitization_state IN
# ('sanitized','never')` - so the label was exactly the key that served the raw
# text to chat.
#
# The fix in 0.1.31 makes the sanitize job REPLACE the chunk text with the job's
# redacted rendering, and widens its selection to include already-mislabelled
# `sanitized` rows, so re-running the job on an affected document repairs it and
# keeps retrieval coverage. That is what this script drives, one document at a
# time.
#
# ORDER OF OPERATIONS, and why it matters:
#   1. update the machine to 0.1.31 or later - on 0.1.30 and earlier the job has no
#      rewrite path at all, so re-running it changes nothing;
#   2. run this script;
#   3. re-run audit-sanitized-chunk-egress.ps1 and confirm the count fell to zero.
#
# Usage:
#   powershell -File scripts/remediate-sanitized-chunk-egress.ps1 -WhatIf
#   powershell -File scripts/remediate-sanitized-chunk-egress.ps1
#   powershell -File scripts/remediate-sanitized-chunk-egress.ps1 -ApiBase http://localhost:8089/pacgate
#
# -WhatIf lists what would be remediated without calling the API.

param(
    # Root of the pacgate API as reachable from THIS machine. The client bundle
    # fronts it at /pacgate/, so the default is the client-facing route.
    [string]$ApiBase = 'http://localhost:8089/pacgate',

    # Data level to re-sanitize at. T3 matches what the e2e sanitizer gate uses.
    # Changing it changes which detectors run, so it is a parameter rather than a
    # hidden constant - but the default is the one that has been proven.
    [string]$DataLevel = 'T3',

    # List the work without performing it.
    [switch]$WhatIf,

    # How many affected documents to repair in one run. A guard against a very
    # large affected set: each repair re-embeds the whole document, so this is
    # load-proportional to document size, not to leak size.
    [int]$Limit = 100
)

$ErrorActionPreference = 'Continue'
$script:ok = 0
$script:failed = 0

$repoRoot = Split-Path -Parent $PSScriptRoot
$bundle = Join-Path $repoRoot 'deploy\client-bundle'
$envPath = Join-Path $bundle '.env'

function Invoke-Psql([string]$Sql) {
    # STDIN, never `cmd /c "... -c ""$sql"""`. The -c form silently dropped the
    # WHERE clause in an earlier version of the audit script and reported leaks for
    # patterns that cannot exist. STDIN has no quoting layer to lose.
    $out = $Sql | docker exec -i pacgate-db psql -U pacgate -d pacgate -t -A 2>&1
    return ($out | Where-Object { $_ -notmatch '^(INFO|NOTICE|WARNING)' })
}

# ── credentials ─────────────────────────────────────────────────────────────────
$apiEmail = 'admin@pacgate-law.com'
$apiPassword = ''
if (Test-Path $envPath) {
    foreach ($line in (Get-Content $envPath -ErrorAction SilentlyContinue)) {
        if ($line -match '^\s*PACGATE_API_EMAIL\s*=\s*(.+)$') { $apiEmail = $Matches[1].Trim() }
        if ($line -match '^\s*PACGATE_API_PASSWORD\s*=\s*(.+)$') { $apiPassword = $Matches[1].Trim() }
    }
}
if (-not $apiPassword -or $apiPassword -match '^change-me') {
    Write-Output 'SKIP: PACGATE_API_PASSWORD is unset or still the placeholder in deploy/client-bundle/.env.'
    Write-Output '      This script logs in as the admin to re-run sanitize jobs, so it needs real credentials.'
    exit 2
}

# ── the affected set ────────────────────────────────────────────────────────────
# Patterns come from the SHARED file, not a local copy.
#
# This script used to hard-code its own list and carry a comment saying the two must
# be kept in step with the audit. They drifted anyway: the audit learned to exclude
# the redactor's placeholder and this did not, so on an already-clean machine this
# selected 39 documents and reported "raw 0 -> 0, chunks kept=1" for every one - a
# no-op dressed up as work, and the closing audit disagreed with it.
. (Join-Path $PSScriptRoot 'lib/RawPiiPatterns.ps1')
$rawPredicate = Get-PacgateRawPiiPredicate -Column 'c.content'

# A pattern match alone is not a leak. The product refuses to call a bare digit
# run an identifier (spec 8.4), so a checksum-INVALID 18-digit run in a sanitized
# chunk is the product working as designed. Selecting on the raw predicate alone
# made this script offer to re-sanitize documents that are already clean - the
# same drift the shared-patterns file was created to stop, one level up.
#
# Measured 2026-10-25: the raw predicate selected 2 documents, both fixtures whose
# IDs fail ISO 7064 MOD 11-2. The audit reported "NO LEAK" while this reported
# "2 affected" - two scripts disagreeing about the same rows.
#
# So the selection is narrowed to rows that carry a checksum-VALID resident ID.
# That is the only class the product itself would have redacted.
$findSql = @"
CREATE OR REPLACE FUNCTION pg_temp.cn_id_valid(s text) RETURNS boolean AS `$`$
DECLARE
  w int[] := ARRAY[7,9,10,5,8,4,2,1,6,3,7,9,10,5,8,4,2];
  c text := '10X98765432';
  tot int := 0;
  i int;
BEGIN
  IF length(s) <> 18 THEN RETURN false; END IF;
  FOR i IN 1..17 LOOP
    tot := tot + (substring(s from i for 1))::int * w[i];
  END LOOP;
  RETURN substring(c from (tot % 11) + 1 for 1) = upper(substring(s from 18 for 1));
END;
`$`$ LANGUAGE plpgsql IMMUTABLE;

SELECT c.document_id::text
FROM kb_chunks c
JOIN documents d ON d.id = c.document_id
WHERE c.sanitization_state = 'sanitized'
  AND ($rawPredicate)
  AND EXISTS (
    SELECT 1 FROM regexp_matches(c.content, '(?!0{16})[0-9]{17}[0-9Xx]', 'g') AS r
    WHERE pg_temp.cn_id_valid(r[1])
  )
GROUP BY c.document_id
ORDER BY c.document_id
LIMIT $Limit;
"@

$docIds = @(Invoke-Psql $findSql | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ -and $_ -match '^[0-9a-f-]{36}$' })
$docIds = @($docIds | Sort-Object -Unique)

Write-Output "== sanitized-chunk egress remediation =="
Write-Output "api base   : $ApiBase"
Write-Output "data level : $DataLevel"
Write-Output "documents  : $($docIds.Count) affected (limit $Limit)"
Write-Output ''

if ($docIds.Count -eq 0) {
    Write-Output '== RESULT: nothing to remediate - no raw match in a sanitized chunk =='
    exit 0
}

if ($WhatIf) {
    Write-Output 'would re-run the sanitize job for:'
    $docIds | ForEach-Object { Write-Output "  $_" }
    Write-Output ''
    Write-Output '== RESULT: DRY RUN - nothing changed =='
    exit 0
}

# ── log in ──────────────────────────────────────────────────────────────────────
$loginBody = @{ email = $apiEmail; password = $apiPassword } | ConvertTo-Json -Compress
$token = $null
try {
    $login = Invoke-RestMethod -Uri "$ApiBase/api/auth/login" -Method Post -ContentType 'application/json' -Body $loginBody -TimeoutSec 20
    $token = $login.token
} catch {
    Write-Output "FAIL: login failed at $ApiBase/api/auth/login : $($_.Exception.Message)"
    exit 1
}
if (-not $token) { Write-Output 'FAIL: login returned no token'; exit 1 }
$hdr = @{ Authorization = "Bearer $token" }
Write-Output "logged in as $apiEmail"
Write-Output ''

# ── repair, one document at a time ───────────────────────────────────────────────
$i = 0
foreach ($docId in $docIds) {
    $i++
    $before = Invoke-Psql "SELECT count(*) FROM kb_chunks WHERE document_id='$docId' AND sanitization_state='sanitized' AND ($($rawPredicate -replace 'c\.content','content'));"
    $beforeN = [int]("$($before[0])".Trim())

    try {
        $job = Invoke-RestMethod -Uri "$ApiBase/api/documents/$docId/sanitize" -Method Post -Headers $hdr `
            -ContentType 'application/json' -Body (@{ data_level = $DataLevel } | ConvertTo-Json -Compress) -TimeoutSec 300
    } catch {
        Write-Output ("  [{0}/{1}] {2}  FAILED: {3}" -f $i, $docIds.Count, $docId, $_.Exception.Message)
        $script:failed++
        continue
    }

    # The rewrite is one transaction, so once the request returns the rows are
    # already replaced - no settle time needed.
    $after = Invoke-Psql "SELECT count(*) FROM kb_chunks WHERE document_id='$docId' AND sanitization_state='sanitized' AND ($($rawPredicate -replace 'c\.content','content'));"
    $afterN = [int]("$($after[0])".Trim())
    $kept = Invoke-Psql "SELECT count(*) FROM kb_chunks WHERE document_id='$docId' AND sanitization_state='sanitized';"
    $keptN = [int]("$($kept[0])".Trim())

    $verdict = if ($job.verdict) { $job.verdict } else { '?' }
    if ($afterN -eq 0) {
        # Chunks retained is reported, not merely assumed: a repair that removed the
        # rows would also read "0 leaks", and it would have silently cost the
        # document its retrieval coverage.
        Write-Output ("  [{0}/{1}] {2}  verdict={3} promoted={4}  raw {5} -> {6}  chunks kept={7}" -f `
            $i, $docIds.Count, $docId.Substring(0, 8), $verdict, $job.chunks_promoted, $beforeN, $afterN, $keptN)
        $script:ok++
    } else {
        Write-Output ("  [{0}/{1}] {2}  verdict={3} promoted={4}  raw {5} -> {6}  STILL LEAKING" -f `
            $i, $docIds.Count, $docId.Substring(0, 8), $verdict, $job.chunks_promoted, $beforeN, $afterN)
        $script:failed++
    }
}

Write-Output ''
Write-Output "== RESULT: repaired $($script:ok), failed $($script:failed) =="
Write-Output '   Re-run audit-sanitized-chunk-egress.ps1 to confirm the machine is clean.'
if ($script:failed -gt 0) { exit 1 }
exit 0
