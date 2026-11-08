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
#
# The patterns now live in ONE place - scripts/lib/RawPiiPatterns.ps1 - because
# duplicating them between this audit and the remediation script let them drift.
# The audit was taught to exclude the redactor's own placeholder
# (00000000000000000X) and the remediation was not, so the remediation went on
# selecting 39 already-clean documents and reporting "raw 0 -> 0" for each. A
# comment asking two copies to stay in step is not a mechanism; a shared file is.
. (Join-Path $PSScriptRoot 'lib/RawPiiPatterns.ps1')
$patterns = $PacgateRawPiiPatterns
# duplicating them between this audit and the remediation script let them drift. The
# audit was taught to exclude the redactor's placeholder and the remediation was not,
# so the remediation went on selecting 39 already-clean documents and reporting
# "raw 0 -> 0" for each. A comment asking two copies to stay in step is not a
# mechanism; a shared file is.
. (Join-Path $PSScriptRoot 'lib/RawPiiPatterns.ps1')
$patterns = $PacgateRawPiiPatterns

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
    # `2>&1` merges docker's STDERR into this stream as ErrorRecord objects, and an
    # ErrorRecord has no .Trim(). A warning line (a container-health notice, a psql
    # NOTICE) therefore threw MethodNotFound inside this filter and the error object
    # itself survived into the returned array as a counted "match". Measured
    # 2026-11-02: the audit reported "10 raw match(es)" while printing the exception
    # above the count. Cast to string first, then filter on CONTENT, so a diagnostic
    # can never be counted as a leak again.
    #
    # Encoding + hard-fail on a rejected query live in the SHARED helper. This script
    # had the same console-code-page bug as the remediation (see
    # `Invoke-PacgatePsql`): five patterns carry the full-width colon, which the pipe
    # replaced with `?` on code page 936, and `[:?]?` is a Postgres syntax error. Two
    # scripts reading the same patterns must not each own their own psql plumbing -
    # that is how they drifted apart twice before.
    return @(Invoke-PacgatePsql -Sql $sql -Container $DbContainer)
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
#
# The count must EXCLUDE matches that sit inside a token this redactor minted.
# MEASURED 2026-11-03: counting `content ~ '$rx'` alone reported `cn_landline` 2 and
# `sg_nric` 1 on documents that were clean - the patterns matched hex payloads
# inside `[CN_ID_BF05012917050DF0]` and `[CN_MOBILE_C1F3732998EFA823]`. That is the
# same false-positive class as the Rust rescan's P0-2, one layer further out, and it
# made the audit unusable in the same way: an alert an operator learns to ignore.
#
# SQL ERE has no lookbehind, so the exclusion is expressed as "at least one match
# whose text is not contained in any token". A row holding BOTH a token and a real
# leak still counts, because the real match is outside the token.
$totalLeak = 0
foreach ($name in $patterns.Keys) {
    $rx = $patterns[$name]
    # Delegates to the SHARED exclusion, but stays PER-PATTERN.
    #
    # Two copies of the exclusion logic existed (here, and the affected-document
    # query) and each had to be fixed separately. MEASURED 2026-11-03: the zero-run
    # guard was added to the shared file, this count still had a local copy, and the
    # audit kept reporting 7 historical format-preserving masks as leaks.
    #
    # Note `$rx` is still bound per iteration: substituting the whole-pattern union
    # here made every class report the same total (measured: 15 classes x 5 = 75),
    # which is a different wrong answer, not a fix.
    $row = Invoke-Psql @"
SELECT count(*) FROM kb_chunks c
WHERE c.sanitization_state = 'sanitized'
  AND EXISTS (
      SELECT 1 FROM regexp_matches(c.content, '$rx', 'g') AS m(tok)
      WHERE m.tok[1] !~ '000|111|222|333|444|555|666|777|888|999|XXX'
        AND NOT EXISTS (
            SELECT 1 FROM regexp_matches(c.content, '\[?[A-Z][A-Z0-9_]*_[0-9A-F]{8,}\]?', 'g') AS t(tok)
            WHERE strpos(t.tok[1], m.tok[1]) > 0
        )
  )
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
# 2b. Classify what the raw patterns actually found.
#
# A bare regex match is NOT a leak. Three different things match these patterns
# and only one of them is a defect:
#
#   REAL LEAK     a checksum-VALID identifier sitting in a sanitized chunk. The
#                 product's own detector would have caught it, so its presence
#                 means the row was never rewritten.
#   NOT DETECTED  a pattern match whose checksum FAILS. The product deliberately
#                 refuses to call a bare digit run an identifier (spec 8.4:
#                 "forbids identifying an identifier from a bare digit run,
#                 because that is exactly how account numbers, amounts and
#                 trademark numbers get confused"). Reporting these as leaks
#                 would demand the product redact things it is designed not to.
#   SUBSTRING     a match that is a fragment of a LONGER digit run - an 18-digit
#                 ID also matches the 11-digit mobile and 13-digit landline
#                 patterns at inner offsets. One identifier, counted three times.
#
# Measured 2026-10-25: the audit reported "12 raw matches - LEAK PRESENT" for
# four documents, of which ZERO were real leaks - one was the redactor's own
# placeholder (a guard off-by-one, now fixed), two were checksum-invalid
# fictional fixtures, and the rest were substring double-counts.
# The placeholder guard comes from the shared file, not a local copy. Three more
# copies of the literal `(?!0{16})` lived here and in the remediation script; the
# 2026-11-02 placeholder change broke all of them at once (index 10 onward eats a
# leading zero per digit), which is exactly why the value is defined once.
$idCardPattern = $patterns['cn_id_card']
$usccPattern   = $patterns['uscc']

$classify = Invoke-Psql @"
WITH m AS (
  SELECT c.document_id, c.chunk_index, c.content
  FROM kb_chunks c
  WHERE c.sanitization_state = 'sanitized'
    AND ($(Get-PacgateRawPiiPredicate 'c.content'))
)
SELECT left(document_id::text,8) || '|' || chunk_index || '|' ||
       (content ~ '$idCardPattern')::text || '|' ||
       (content ~ '$usccPattern')::text || '|' ||
       (content ~ '1[3-9][0-9]{9}')::text || '|' ||
       (content ~ '0(?:10|2[1-9]|[3-9][0-9]{2})-?[0-9]{7,8}')::text
FROM m
"@
$classify = @($classify | Where-Object { $_ -and $_.Trim() })
if ($classify.Count -gt 0) {
    Write-Output 'pattern matches, by document (t = that pattern matched):'
    Write-Output '  doc       chunk  id_card  uscc  mobile  landline'
    foreach ($line in $classify) {
        $p = ($line.Trim() -split '\|')
        if ($p.Count -ge 6) {
            Write-Output ("  {0,-8}  {1,-5}  {2,-7}  {3,-4}  {4,-6}  {5}" -f $p[0], $p[1], $p[2], $p[3], $p[4], $p[5])
        }
    }
    Write-Output ''
    Write-Output '  NOTE: id_card and uscc match the SAME 18-character run, and mobile and'
    Write-Output '        landline match INNER SUBSTRINGS of it. One identifier is counted'
    Write-Output '        up to four times by the per-pattern totals above.'
    Write-Output ''
}

# 2c. Classify the ID-shaped matches by check digit.
#
# This used to be a LEAK / NO-LEAK decision: the audit concluded that a
# checksum-invalid 18-digit run was the product working as designed, so a machine
# whose only matches were invalid IDs got "NO LEAK, exit 0".
#
# MEASURED 2026-11-02 that conclusion is WRONG and was removed. A resident ID whose
# shape is well-formed (region prefix plus a real calendar birthdate) is now redacted
# even when its check digit is wrong, because a mistyped or OCR-damaged ID is still
# personal data. The client case that forced this: `110105199003074512` has a bad
# check digit (expected X, got 2), survived the old rule layer, was indexed as
# searchable, and could be used as a lookup key against the vector store - in a
# document carrying the `sanitized` label.
#
# So this number is now EVIDENCE WEIGHT, not a verdict input:
#   * checksum-VALID matches are certainly issued identifiers;
#   * checksum-INVALID matches are identifier-SHAPED values that the current rule
#     layer redacts anyway, so finding one in a `sanitized` chunk means the chunk was
#     written before the fix (or by a build without it) and must be re-sanitized.
#
# Both are reported as leaks. The distinction survives because an operator triaging a
# long list wants to know which ones are unambiguous.
$validIds = Invoke-Psql @"
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

SELECT count(*) FROM kb_chunks c
WHERE c.sanitization_state = 'sanitized'
  AND EXISTS (
    SELECT 1 FROM regexp_matches(c.content, '$idCardPattern', 'g') AS r
    WHERE pg_temp.cn_id_valid(r[1])
  )
"@
$validIds = ($validIds | Where-Object { $_ -and $_.Trim() -match '^\d+$' } | Select-Object -Last 1)
if (-not $validIds) { $validIds = '0' }
$validIds = $validIds.Trim()
Write-Output "  checksum-VALID resident IDs in sanitized chunks: $validIds"
Write-Output '  (checksum-INVALID ID-shaped values are ALSO leaks since 2026-11-02:'
Write-Output '   a mistyped or OCR-damaged ID is still personal data and is now'
Write-Output '   redacted by the rule layer - see cn_resident_id_shape_ok)'
Write-Output ''

if ($totalLeak -gt 0) {
    Write-Output "== RESULT: $totalLeak raw match(es) inside SANITIZED chunks - LEAK PRESENT =="
    Write-Output "   $validIds of them are checksum-VALID resident IDs (certain)."
    Write-Output "   The remaining $(($totalLeak) - [int]$validIds) match(es) still count as leaks: a"
    Write-Output '   checksum-invalid but well-shaped ID is redacted by the current rule layer,'
    Write-Output '   so finding one in a sanitized chunk means the row predates the fix.'
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
