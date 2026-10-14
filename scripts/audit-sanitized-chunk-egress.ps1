# Audit: do `sanitized` chunks in kb_chunks still carry RAW identifiers?
#
# READ-ONLY. Issues SELECT statements only; never writes, never deletes.
#
# WHY THIS EXISTS
# ---------------
# Until 2026-10-14 the promote step set `kb_chunks.sanitization_state =
# 'sanitized'` WITHOUT rewriting `content`, so raw PII stayed in the text and the
# RAG gate - `sanitization_state IN ('sanitized','never')` - served it to chat.
# See deploy/DEFECT-sanitized-content-not-served.md.
#
# The code fix is forward-only. Rows mislabeled on 0.1.28..0.1.30 keep their raw
# text and no image upgrade rewrites them, so an operator needs to know WHICH
# documents are affected before choosing to re-sanitize or delete.
#
# This script answers "which", not "fix it". It is deliberately not a gate: on a
# machine that was never upgraded it correctly finds nothing, and on one that was
# it finds real rows that no code change can erase. Failing a suite for either
# would train people to ignore it. Run it per machine before a migration.
#
# Usage:
#   powershell -File scripts/audit-sanitized-chunk-egress.ps1
#   powershell -File scripts/audit-sanitized-chunk-egress.ps1 -MaxRows 100
param(
    # How many offending rows to name in detail.
    [int]$MaxRows = 25,
    # The container holding the product database.
    [string]$DbContainer = 'pacgate-db'
)
$ErrorActionPreference = 'Continue'

# Detection patterns, mirrored from pacgate-redact/src/detect/rules.rs so the
# audit looks for what the sanitizer actually claims to redact. Not every rule is
# reproduced - the NER tiers need weights and cannot run in SQL - so this is a
# LOWER BOUND on the leak, never an upper bound. A clean result is not a proof.
#
# Kept deliberately simple: a SQL regex cannot express the rule set's context
# windows or checksum validation, and pretending otherwise would overstate what
# this measures.
# Both 18-char patterns need the placeholder exclusion, not just one.
#
# MEASURED 2026-10-14: the redactor renders a Chinese ID card as the
# format-preserving placeholder 00000000000000000X - 17 zeros and an X. That value
# is a legitimate member of BOTH character classes below, so both patterns flagged
# the sanitizer's own output as a leak. On a machine that had just been remediated
# to zero real leaks, the audit still reported 37, and the first fix attempt only
# covered 'uscc' - so it then reported 37 against 'cn_id_card' instead.
#
# (?!0{17}) excludes exactly that placeholder and nothing else. Real Chinese ID
# cards and USCCs do not begin with 17 zeros.
#
# The lesson worth keeping: verify a regex fix against the pattern AS THE CODE
# USES IT. My first check compared against a hand-written pattern that was not the
# one in the file, so it "passed" while the defect was untouched.
$patterns = [ordered]@{
    'email'         = '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
    'cn_id_card'    = '(?!0{17})[0-9]{17}[0-9Xx]'
    # NEGATIVE LOOKAHEAD, not a bare character class.
    #
    # The naive form was '[0-9A-HJ-NPQRTUWXY]{18}', and it reported 37 leaks on a
    # machine that was CLEAN. Measured 2026-10-14 after remediating every affected
    # document: the real patterns matched 0 rows while this one matched all 37 -
    # because the redactor renders a Chinese ID card as the format-preserving
    # placeholder 00000000000000000X, and 17 zeros plus an X is a valid 18-char
    # member of that class. The audit was flagging the SANITIZER'S OWN OUTPUT as a
    # leak.
    #
    # (?!0{17}) excludes that placeholder and nothing else: it is the only value
    # this pattern exists to stop flagging, and real USCCs never begin with 17
    # zeros. Checked before adding: the id-card pattern does NOT match the
    # placeholder, so only this one needed it.
    #
    # Found because the remediation reported "37 repaired, 0 failed" while the audit
    # still said 74 leaks - a disagreement between two things I had written, which
    # is exactly the case that has to be resolved rather than explained away.
    'uscc'          = '(?!0{17})[0-9A-HJ-NPQRTUWXY]{18}'
    'cn_mobile'     = '1[3-9][0-9]{9}'
    'cn_landline'   = '0(10|2[1-9]|[3-9][0-9]{2})-?[0-9]{7,8}'
}

function Invoke-Psql([string]$sql) {
    # SQL goes in over STDIN, not through `cmd /c "..."`.
    #
    # The first version built a `cmd /c "docker exec ... -c ""$sql"""` string. The
    # nested quoting silently mangled every multi-line query - the WHERE clause was
    # dropped and all five patterns returned the table's TOTAL row count, i.e. the
    # audit reported "38 leaks" for every pattern including ones that cannot match
    # (an 18-char USCC and a 13-digit landline both returning 38). A leak audit that
    # cannot be wrong in the quiet direction is worse than none, and this one was
    # wrong loudly, which is how it was caught. STDIN has no quoting to get wrong.
    $out = $sql | docker exec -i $DbContainer psql -U pacgate -d pacgate -t -A 2>&1
    if ($LASTEXITCODE -ne 0) { return $null }
    return @($out | Where-Object { $_ -and $_.Trim() })
}

# 0. Reachability. Exit 2 rather than reporting a clean bill of health for a
#    database that was never read - that is the failure mode this whole defect
#    family shares, and repeating it inside its own audit would be careless.
$probe = Invoke-Psql 'SELECT 1'
if ($null -eq $probe -or ($probe -join '').Trim() -ne '1') {
    Write-Output "SKIP: cannot read $DbContainer (is the stack up?)."
    Write-Output '      Nothing was audited; this is NOT a clean result.'
    exit 2
}

Write-Output "== sanitized-chunk egress audit =="
Write-Output "database container: $DbContainer"
Write-Output ''
Write-Output 'NOTE: a clean result is a LOWER BOUND on raw exposure. The SQL patterns'
Write-Output '      cover the Tier-1 rules only; NER-detected names and addresses are'
Write-Output '      not checked, because they need the model weights.'
Write-Output ''

# 1. Baseline, so a zero-leak result is distinguishable from an empty table.
$totals = Invoke-Psql @"
SELECT sanitization_state, count(*)
FROM kb_chunks GROUP BY 1 ORDER BY 2 DESC
"@
Write-Output 'kb_chunks by sanitization_state:'
$totals | ForEach-Object { Write-Output "  $($_.Trim())" }
Write-Output ''

# 2. The finding: rows LABELLED sanitized whose content matches a raw pattern.
$totalLeak = 0
foreach ($name in $patterns.Keys) {
    $rx = $patterns[$name]
    $row = Invoke-Psql @"
SELECT count(*) FROM kb_chunks
WHERE sanitization_state = 'sanitized' AND content ~ '$rx'
"@
    $n = 0
    if ($row -and ($row | Select-Object -First 1).Trim() -match '^\d+$') {
        $n = [int]($row | Select-Object -First 1).Trim()
    }
    $totalLeak += $n
    $verdict = if ($n -gt 0) { 'LEAK' } else { 'ok  ' }
    Write-Output ("  {0}  {1,-14} {2}" -f $verdict, $name, $n)
}

Write-Output ''

# 3. Name the affected documents, because the remedy is per-document.
#    Deduplicated: one document can match several patterns.
$affected = Invoke-Psql @"
SELECT DISTINCT d.matter_id || '|' || d.id || '|' || coalesce(d.name,'(unnamed)')
FROM kb_chunks c JOIN documents d ON c.document_id = d.id
WHERE c.sanitization_state = 'sanitized'
  AND (c.content ~ '$($patterns.cn_id_card)'
    OR c.content ~ '$($patterns.cn_mobile)'
    OR c.content ~ '$($patterns.email)'
    OR c.content ~ '$($patterns.uscc)')
LIMIT $MaxRows
"@

$affected = @($affected | Where-Object { $_ -and $_.Trim() })
Write-Output "affected documents (up to $MaxRows):"
if ($affected.Count -eq 0) {
    Write-Output '  (none)'
}
foreach ($line in $affected) {
    $p = ($line.Trim() -split '\|')
    if ($p.Count -ge 3) {
        Write-Output "  matter=$($p[0])  doc=$($p[1])  name=$($p[2])"
    } else {
        Write-Output "  $($line.Trim())"
    }
}
Write-Output ''

# 4. Contrast: `pending` rows are CORRECT to hold raw text - they are outside the
#    retrieval gate. Reported so a reader does not mistake them for the finding.
$pend = Invoke-Psql @"
SELECT count(*) FROM kb_chunks
WHERE sanitization_state = 'pending' AND content ~ '$($patterns.cn_id_card)'
"@
$pend = ($pend | Select-Object -First 1).Trim()
Write-Output "for contrast, raw text in PENDING rows (expected, not retrievable): $pend"
Write-Output ''

if ($totalLeak -gt 0) {
    Write-Output "== RESULT: $totalLeak raw match(es) inside SANITIZED chunks - LEAK PRESENT =="
    Write-Output ''
    Write-Output 'Remediation, per affected document (choose one):'
    Write-Output '  a) Re-sanitize it. The sanitize job REPLACES the chunk text with the'
    Write-Output '     redacted rendering, so re-running it cleans the rows and keeps recall.'
    Write-Output '     MEASURED 2026-10-14: this repairs a document that the OLD code'
    Write-Output '     mislabelled, because the rewrite now selects already-''sanitized'' rows'
    Write-Output '     too. A pending-only selection returned chunks_promoted=0 and left the'
    Write-Output '     leak in place - that was a real defect, fixed before this advice shipped.'
    Write-Output '  b) Delete the rows for that document, removing the leak at once and losing'
    Write-Output '     RAG coverage for it until re-sanitized. Safe degradation.'
    Write-Output ''
    Write-Output 'Both require a build with ChunkIngestor::reingest_sanitized_chunks (the first'
    Write-Output 'image after 0.1.30). Re-running on 0.1.30 or earlier changes nothing - the'
    Write-Output 'old code had no rewrite path at all, so option (a) is a no-op there.'
    exit 1
}

Write-Output '== RESULT: no raw Tier-1 match found in a sanitized chunk =='
Write-Output '   (lower bound only - NER-tier identifiers are not covered by this check)'
exit 0
