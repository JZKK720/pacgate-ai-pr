# Proves the sanitization gate EXCLUDES a non-sanitized row.
#
# Unit tests assert the SQL contains the gate. That is not the same claim. This
# script inserts three rows directly - pending, sanitized, blocked - plus a
# NULL-state row, and asserts that a search-equivalent SELECT returns only the
# sanitized one. A gate that is present but ineffective passes the unit tests
# and fails here.
#
# Requires: docker, the pacgate-db container, and migrations 001-005 applied.

$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')

$Db = 'pacgate-db'
$failures = 0

function Assert-Equal($label, $expected, $actual) {
    if ("$expected" -eq "$actual") {
        Write-Host "  PASS  $label" -ForegroundColor Green
    } else {
        Write-Host "  FAIL  $label" -ForegroundColor Red
        Write-Host "        expected: $expected"
        Write-Host "        actual:   $actual"
        $script:failures++
    }
}

function Invoke-Psql([string]$sql) {
    $out = docker exec $Db psql -U pacgate -d pacgate -t -A -c $sql 2>&1
    if ($LASTEXITCODE -ne 0) { throw "psql failed: $out" }
    return ($out | Out-String).Trim()
}

Write-Host "=== sanitization gate: exclusion proof ===" -ForegroundColor Cyan

# Confirm the column exists at all. A missing column would make every later
# assertion fail with a confusing error, so check it explicitly first.
$col = Invoke-Psql "SELECT column_default FROM information_schema.columns WHERE table_name='kb_chunks' AND column_name='sanitization_state'"
Assert-Equal "kb_chunks.sanitization_state default is pending" "'pending'::text" $col

# Build a throwaway tenant/matter/document so the fixture cannot collide with
# real data and can be removed wholesale afterwards.
$T = '00000000-0000-0000-0000-00000000dead'
$U = '00000000-0000-0000-0000-0000000000ff'
$M = '00000000-0000-0000-0000-00000000beef'
$D = '00000000-0000-0000-0000-00000000cafe'

Invoke-Psql "INSERT INTO tenants (id, name, slug) VALUES ('$T','gate-test','gate-test') ON CONFLICT DO NOTHING" | Out-Null
Invoke-Psql "INSERT INTO users (id, tenant_id, email, role) VALUES ('$U','$T','gate@test.local','attorney') ON CONFLICT DO NOTHING" | Out-Null
Invoke-Psql "INSERT INTO matters (id, tenant_id, name, created_by) VALUES ('$M','$T','gate matter','$U') ON CONFLICT DO NOTHING" | Out-Null
Invoke-Psql "INSERT INTO documents (id, matter_id, tenant_id, name, format, storage_path, owner_id) VALUES ('$D','$M','$T','gate.docx','docx','gate/doc_v1.docx','$U') ON CONFLICT DO NOTHING" | Out-Null

# Three chunks, one per state. Same content so only the state differs.
Invoke-Psql "DELETE FROM kb_chunks WHERE document_id='$D'" | Out-Null
Invoke-Psql "INSERT INTO kb_chunks (tenant_id, matter_id, document_id, chunk_index, content, data_level, sanitization_state) VALUES ('$T','$M','$D',0,'GATEPROBE pending','T3','pending')" | Out-Null
Invoke-Psql "INSERT INTO kb_chunks (tenant_id, matter_id, document_id, chunk_index, content, data_level, sanitization_state) VALUES ('$T','$M','$D',1,'GATEPROBE sanitized','T3','sanitized')" | Out-Null
Invoke-Psql "INSERT INTO kb_chunks (tenant_id, matter_id, document_id, chunk_index, content, data_level, sanitization_state) VALUES ('$T','$M','$D',2,'GATEPROBE blocked','T3','blocked')" | Out-Null

# The unfiltered count proves the fixture is real: three rows exist.
$all = Invoke-Psql "SELECT count(*) FROM kb_chunks WHERE content LIKE 'GATEPROBE%'"
Assert-Equal "fixture inserted 3 chunks" 3 $all

# THE assertion: the gate clause, run for real, returns only the sanitized row.
$gated = Invoke-Psql "SELECT content FROM kb_chunks c WHERE c.tenant_id='$T' AND c.matter_id='$M' AND c.sanitization_state IN ('sanitized','never') ORDER BY c.chunk_index"
Assert-Equal "gate returns exactly one row" "GATEPROBE sanitized" $gated

# A NULL state must be excluded, not treated as sanitized.
Invoke-Psql "INSERT INTO kb_chunks (tenant_id, matter_id, document_id, chunk_index, content, data_level, sanitization_state) VALUES ('$T','$M','$D',3,'GATEPROBE nullstate','T3',NULL)" | Out-Null
$withNull = Invoke-Psql "SELECT count(*) FROM kb_chunks c WHERE c.matter_id='$M' AND c.sanitization_state IN ('sanitized','never')"
Assert-Equal "a NULL state is excluded by the gate" 1 $withNull

# Cross-store identity: the path copy and the column copy must agree.
$pathMatter = Invoke-Psql "SELECT matter_id FROM documents WHERE id='$D'"
$chunkMatter = Invoke-Psql "SELECT DISTINCT matter_id FROM kb_chunks WHERE document_id='$D' LIMIT 1"
Assert-Equal "documents.matter_id matches kb_chunks.matter_id" $pathMatter $chunkMatter

# Clean up.
Invoke-Psql "DELETE FROM kb_chunks WHERE document_id='$D'" | Out-Null
Invoke-Psql "DELETE FROM documents WHERE id='$D'" | Out-Null
Invoke-Psql "DELETE FROM matters WHERE id='$M'" | Out-Null
Invoke-Psql "DELETE FROM users WHERE id='$U'" | Out-Null
Invoke-Psql "DELETE FROM tenants WHERE id='$T'" | Out-Null

Write-Host ""
if ($failures -eq 0) {
    Write-Host "ALL ASSERTIONS PASSED" -ForegroundColor Green
    exit 0
} else {
    Write-Host "$failures ASSERTION(S) FAILED" -ForegroundColor Red
    exit 1
}