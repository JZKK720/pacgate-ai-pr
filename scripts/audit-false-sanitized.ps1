# AUDIT: which documents are marked 'sanitized' but have NO TEXT behind them?
#
# WHY THIS EXISTS
#
# Before Plan A, a document whose pages OCR'd to nothing was reported as a COMPLETE
# extraction. sanitize.rs then sanitized empty text, produced a `pass` verdict, and
# marked the document 'sanitized' - so the egress gate opened on a document nobody
# could read. Plan A stops NEW occurrences. It does NOT retract the flag from
# documents already in that state, because nothing but extract.rs reads
# document_extractions and download gating reads only documents.sanitization_state.
#
# So the population that the OLD defect created has to be measured rather than
# assumed. Run this on every machine that ran a pre-Plan-A build, and record the
# count in the release note.
#
# A 'sanitized' document with zero chunks, or zero total text, is the signature:
# the redaction job ran on nothing and called it clean.
#
# Exit: 0 = no exposure, 1 = exposure found (these documents need remediation),
#       2 = cannot check (database unreachable).
#
# Usage:
#   pwsh -File scripts/audit-false-sanitized.ps1
#   pwsh -File scripts/audit-false-sanitized.ps1 -DbContainer pacgate-db

[CmdletBinding()]
param(
    [string]$DbContainer = 'pacgate-db',
    [string]$DbUser = 'pacgate',
    [string]$DbName = 'pacgate'
)

$ErrorActionPreference = 'Continue'

function Die($msg) {
    Write-Host "`nCANNOT CHECK: $msg" -ForegroundColor Yellow
    exit 2
}

Write-Host '=== false-sanitized exposure audit ===' -ForegroundColor Cyan

$probe = docker exec $DbContainer psql -U $DbUser -d $DbName -t -A -c 'SELECT 1' 2>&1
if ($LASTEXITCODE -ne 0 -or -not ("$probe".Trim() -eq '1')) {
    Die "cannot query $DbContainer as $DbUser/$DbName"
}
Write-Host "  database: $DbContainer/$DbName"

function Query([string]$sql) {
    $out = docker exec $DbContainer psql -U $DbUser -d $DbName -t -A -c $sql 2>&1
    if ($LASTEXITCODE -ne 0) { Die "query failed: $out" }
    return ("$out").Trim()
}

# The counts are reported whether or not exposure exists: a zero is only
# meaningful next to the denominator it came from.
$total      = Query 'SELECT count(*) FROM documents'
$sanitized  = Query "SELECT count(*) FROM documents WHERE sanitization_state = 'sanitized'"
$pending    = Query "SELECT count(*) FROM documents WHERE sanitization_state = 'pending'"
$blocked    = Query "SELECT count(*) FROM documents WHERE sanitization_state = 'blocked'"
$zeroChunks = Query "SELECT count(*) FROM documents d WHERE d.sanitization_state = 'sanitized' AND NOT EXISTS (SELECT 1 FROM kb_chunks c WHERE c.document_id = d.id)"
$zeroText   = Query "SELECT count(*) FROM documents d WHERE d.sanitization_state = 'sanitized' AND COALESCE((SELECT sum(length(c.content)) FROM kb_chunks c WHERE c.document_id = d.id), 0) = 0"

# document_extractions only exists after migration 008. Its absence on an old
# machine is EXPECTED, not a failure - and it means the completeness of every
# pre-existing extraction is unknown, which is why Plan A re-extracts on first access.
$hasTable = Query "SELECT count(*) FROM information_schema.tables WHERE table_name = 'document_extractions'"
$recorded = '-'
$incompleteCount = '-'
if ("$hasTable" -eq '1') {
    $recorded = Query 'SELECT count(*) FROM document_extractions'
    $incompleteCount = Query 'SELECT count(*) FROM document_extractions WHERE incomplete'
}

Write-Host ''
Write-Host '  documents total              : ' -NoNewline; Write-Host $total
Write-Host '  state = sanitized            : ' -NoNewline; Write-Host $sanitized
Write-Host '  state = pending              : ' -NoNewline; Write-Host $pending
Write-Host '  state = blocked              : ' -NoNewline; Write-Host $blocked
Write-Host '  sanitized with ZERO chunks   : ' -NoNewline; Write-Host $zeroChunks
Write-Host '  sanitized with ZERO text     : ' -NoNewline; Write-Host $zeroText
Write-Host '  document_extractions rows    : ' -NoNewline; Write-Host $recorded
Write-Host '  ...of those, incomplete=true : ' -NoNewline; Write-Host $incompleteCount

if ("$zeroText" -eq '0' -and "$zeroChunks" -eq '0') {
    Write-Host ''
    Write-Host 'RESULT: NO EXPOSURE - every sanitized document has text behind it.' -ForegroundColor Green
    if ("$hasTable" -eq '1' -and "$recorded" -eq '0' -and [int]$sanitized -gt 0) {
        Write-Host '  NOTE: 0 extraction records for pre-existing documents, as designed' -ForegroundColor DarkGray
        Write-Host '  (no backfill - they re-extract once on first access and record the truth).' -ForegroundColor DarkGray
    }
    exit 0
}

Write-Host ''
Write-Host "RESULT: EXPOSURE FOUND - $zeroChunks document(s) are 'sanitized' with no text." -ForegroundColor Red
Write-Host '  These were released through the egress gate by the OLD defect.' -ForegroundColor Yellow
Write-Host ''
Write-Host '  Enumerate them:' -ForegroundColor Cyan
docker exec $DbContainer psql -U $DbUser -d $DbName -c `
    "SELECT d.id, d.name, d.format, d.matter_id,
            COALESCE((SELECT sum(length(c.content)) FROM kb_chunks c WHERE c.document_id = d.id), 0) AS text_chars
     FROM documents d
     WHERE d.sanitization_state = 'sanitized'
       AND NOT EXISTS (SELECT 1 FROM kb_chunks c WHERE c.document_id = d.id)
     ORDER BY d.updated_at DESC"
Write-Host ''
Write-Host '  Remediation per document: re-run extraction, then either' -ForegroundColor Cyan
Write-Host '    (a) DELETE the document and re-upload the source, or' -ForegroundColor Cyan
Write-Host '    (b) UPDATE documents SET sanitization_state = ''pending'' WHERE id = <id>,' -ForegroundColor Cyan
Write-Host '        which closes the egress gate until a real sanitize job passes.' -ForegroundColor Cyan
Write-Host '  Do NOT treat this audit as the remediation - it only measures.' -ForegroundColor Yellow
exit 1
