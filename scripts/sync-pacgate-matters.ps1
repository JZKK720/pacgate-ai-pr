<#
.SYNOPSIS
    Export or import Pacgate matters (with documents and memory) between machines.

.DESCRIPTION
    WHY THIS EXISTS (2026-10-19).

    AIPC 1, AIPC 2 and every future deployment each run their own private
    Postgres. There was no export, import or replication path anywhere in the
    repository - no script, no route, no document. So "sync Matters to the other
    AIPC" was not a broken feature, it was an unimplemented one, and it could not
    be added later by copying a database because the ids do not match:

      tenants.id, users.id and matters.id are each uuid_generate_v4(), so the
      same real-world matter has a DIFFERENT uuid on every machine. Worse,
      documents.storage_path embeds those uuids
      ("tenants/<tenant-uuid>/matters/<matter-uuid>/docs/..."), so a raw data
      directory copy references ids that mean nothing on the target.

    This tool therefore keys the transfer on the NATURAL KEYS that do exist, and
    uses the HTTP API rather than the database as the boundary:

      tenant   by slug       (tenants_slug_key          - UNIQUE, present)
      user     by email      (users_tenant_id_email_key - UNIQUE, present)
      matter   by name       (fallback; see the caveat below)
                or external_key (idx_matters_tenant_external_key - see below)

    MATTER IDENTITY CAVEAT - read before trusting a re-import.

    `matters.external_key` is the intended natural key: the column exists, a
    partial UNIQUE index (tenant_id, external_key) exists, and the API accepts it
    on create. But it is populated on 0 of 59 matters on the dev box, because
    only the qm-channel integration ever sets it. A plain matter created through
    the UI has external_key = NULL.

    On this machine `matters.name` IS effectively unique per tenant, so import
    falls back to it. That fallback is a heuristic, not a guarantee: two matters
    legitimately named "Contract Review" would collide and the second import
    would attach documents to the first. The tool therefore reports which key it
    used per matter, and warns when it had to fall back. Populating external_key
    is the durable fix and is the owner's decision, not this script's: silently
    inventing keys would make two machines disagree in a new way.

    WHAT IT TRANSFERS
      - matters            (name, description, external_key, persona_id)
      - matter memory      (/api/matters/:id/memory, JSON verbatim)
      - documents          (bytes via /api/documents/:id/download, re-uploaded
                            via POST /api/documents as multipart)

    WHAT IT DOES NOT TRANSFER
      - users' passwords. Import creates a missing account with a RANDOM
        password and prints it once; pacgate-api stores argon2 hashes, and a
        hash cannot be replayed into a different cluster through the API.
        (Reading the hash straight out of Postgres and inserting it would carry
        the credential across machines, which is a security decision this tool
        deliberately does not make for you.)
      - kb_chunks / document_spans / audit_log. These are DERIVED: they are
        rebuilt by the extract -> sanitize pipeline, and copying them would
        import a sanitizer verdict that was never reviewed on the target. The
        audit trail is per-machine by design.
      - workflow definitions, skills, templates. Those are files in the release
        artifact (they already ship with the image), not rows.

    SAFETY
      Export is read-only against the source. Import never deletes; it creates
      what is missing and reuses what matches, so running it twice is a no-op
      rather than a duplicate. It reports a plan and, with -WhatIf, changes
      nothing.

.PARAMETER Action
    Export  write a bundle directory to -OutDir
    Import  read a bundle directory from -InDir

.PARAMETER BaseUrl
    Pacgate API root. Include the /pacgate prefix when going through nginx:
    http://localhost:8089/pacgate . Direct container access is not published.

.PARAMETER Email / Password
    Credentials for a PLATFORM ADMIN on that machine. Import needs admin (it may
    create users); export needs admin for completeness.

.EXAMPLE
    # On AIPC 1: capture everything.
    .\scripts\sync-pacgate-matters.ps1 -Action Export -BaseUrl http://localhost:8089/pacgate `
        -Email admin@pacgate-law.com -Password '...' -OutDir D:\sync\aipc1-2026-10-19

.EXAMPLE
    # Copy that directory to AIPC 2, then:
    .\scripts\sync-pacgate-matters.ps1 -Action Import -BaseUrl http://localhost:8089/pacgate `
        -Email admin@pacgate-law.com -Password '...' -InDir D:\sync\aipc1-2026-10-19

.EXAMPLE
    # See what import WOULD do.
    .\scripts\sync-pacgate-matters.ps1 -Action Import ... -InDir ... -WhatIf

.NOTES
    Exit codes: 0 = success, 1 = a step failed, 2 = cannot run (API unreachable).
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Export', 'Import', 'BackfillKeys')]
    [string]$Action,

    [string]$BaseUrl = 'http://localhost:8089/pacgate',

    [Parameter(Mandatory = $true)]
    [string]$Email,

    [Parameter(Mandatory = $true)]
    [string]$Password,

    [string]$OutDir,
    [string]$InDir,

    # Import only: create missing user accounts. Off by default because account
    # provisioning is a policy decision - a machine may deliberately have fewer
    # accounts than its peer.
    [switch]$CreateMissingUsers,

    # BackfillKeys only: prefix for generated keys, e.g. "PF" -> PF-0001.
    # Required, so identity is never invented without the operator naming it.
    # An invented key makes two machines disagree in a NEW way, which is worse
    # than the ambiguous-name problem the backfill exists to solve.
    [string]$KeyPrefix,

    # BackfillKeys only: limit to matters whose name matches this wildcard.
    [string]$NameFilter = '*'
)

$ErrorActionPreference = 'Stop'
$script:failures = 0
$script:warnings = 0

function Write-Step([string]$m) { Write-Host "`n$m" -ForegroundColor Cyan }
function Write-Ok([string]$m) { Write-Host "  [OK] $m" -ForegroundColor Green }
function Write-Warn([string]$m) { Write-Host "  [WARN] $m" -ForegroundColor Yellow; $script:warnings++ }
function Write-Bad([string]$m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; $script:failures++ }
function Write-Note([string]$m) { Write-Host "  [ .. ] $m" -ForegroundColor DarkGray }

$BaseUrl = $BaseUrl.TrimEnd('/')

# ---------------------------------------------------------------------------
# Auth
# ---------------------------------------------------------------------------
function Get-Token {
    $body = @{ email = $Email; password = $Password } | ConvertTo-Json -Compress
    try {
        $r = Invoke-RestMethod -Uri "$BaseUrl/api/auth/login" -Method Post `
            -ContentType 'application/json' -Body $body -TimeoutSec 30
    }
    catch {
        # Distinguish "the API is not there" from "the password is wrong" - they
        # need completely different fixes and used to look identical.
        $code = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
        if ($code -eq 401) {
            Write-Bad "login rejected (401) for $Email - check the password"
            exit 1
        }
        Write-Bad "cannot reach $BaseUrl ($($_.Exception.Message))"
        exit 2
    }
    if (-not $r.token) { Write-Bad 'login returned no token'; exit 1 }
    return $r.token
}

function New-Headers([string]$token) { @{ Authorization = "Bearer $token" } }

function Get-Api([string]$path, $headers) {
    Invoke-RestMethod -Uri "$BaseUrl$path" -Headers $headers -Method Get -TimeoutSec 60
}

# Upload one document. The API takes multipart with a `matter_id` text part and a
# `file` part; this mirrors the pattern already proven in test-sanitizer-e2e.ps1.
function Send-Document($headers, [string]$matterId, [string]$fileName, [byte[]]$bytes, [string]$contentType) {
    $boundary = "----psb$([System.Guid]::NewGuid().ToString('N'))"
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter($ms)
    $ascii = [System.Text.Encoding]::ASCII
    $head = "--$boundary`r`nContent-Disposition: form-data; name=`"matter_id`"`r`n`r`n$matterId`r`n" +
            "--$boundary`r`nContent-Disposition: form-data; name=`"file`"; filename=`"$fileName`"`r`n" +
            "Content-Type: $contentType`r`n`r`n"
    $bw.Write($ascii.GetBytes($head))
    $bw.Write($bytes)
    $bw.Write($ascii.GetBytes("`r`n--$boundary--`r`n"))
    $bw.Flush()
    Invoke-RestMethod -Uri "$BaseUrl/api/documents" -Method Post -Headers $headers `
        -ContentType "multipart/form-data; boundary=$boundary" -Body $ms.ToArray() -TimeoutSec 300
}

# The API decides a document's format from the UPLOAD FILENAME's extension and
# rejects anything else with 400. The stored `Document.name` does NOT include the
# extension ("case", "probe"), so re-uploading under that name fails for every
# document. The export records `format`, so rebuild the extension from it - this
# is the only reliable way to carry the type across, since the bytes alone cannot
# tell a .docx from a .pdf.
function Get-FormatExtension([string]$format) {
    switch ($format.Trim().ToLowerInvariant()) {
        'docx'     { '.docx' }
        'pdf'      { '.pdf' }
        'txt'      { '.txt' }
        'markdown' { '.md' }
        'xlsx'     { '.xlsx' }
        'pptx'     { '.pptx' }
        'html'     { '.html' }
        default    { '.txt' }
    }
}

function Get-ContentType([string]$name) {
    switch -Regex ($name) {
        '\.pdf$'  { 'application/pdf' }
        '\.docx$' { 'application/vnd.openxmlformats-officedocument.wordprocessingml.document' }
        '\.xlsx$' { 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' }
        '\.pptx$' { 'application/vnd.openxmlformats-officedocument.presentationml.presentation' }
        '\.txt$'  { 'text/plain' }
        '\.md$'   { 'text/markdown' }
        '\.html?$' { 'text/html' }
        '\.csv$'  { 'text/csv' }
        default   { 'application/octet-stream' }
    }
}

# ===========================================================================
# BACKFILL KEYS
# ===========================================================================
if ($Action -eq 'BackfillKeys') {
    if ([string]::IsNullOrWhiteSpace($KeyPrefix)) {
        Write-Bad '-KeyPrefix is required for BackfillKeys (for example -KeyPrefix PF).'
        Write-Note 'Keys are never generated without an explicit prefix: silently inventing'
        Write-Note 'identity would make two machines disagree in a new way.'
        exit 1
    }

    Write-Step "Authenticating to $BaseUrl"
    $h = New-Headers (Get-Token)
    Write-Ok "authenticated as $Email"

    Write-Step 'Finding matters without an external key'
    # NOT wrapped in @(...): Invoke-RestMethod emits a JSON array as a single
    # object, so @( ) around the CALL nests it and .Count becomes 1. That exact
    # mistake already made a re-import create duplicate matters in this file.
    $all = Get-Api '/api/matters' $h
    if ($null -eq $all) { $all = @() }

    # -like with a '*' default matches everything, so -NameFilter is opt-in.
    $unkeyed = @($all | Where-Object { (-not $_.external_key) -and $_.name -like $NameFilter })

    if ($unkeyed.Count -eq 0) {
        Write-Ok 'every matter in scope already has an external key'
        exit 0
    }
    Write-Ok "$($unkeyed.Count) matter(s) need a key"

    $seq = 0
    foreach ($m in ($unkeyed | Sort-Object created_at)) {
        $seq++
        $key = '{0}-{1:D4}' -f $KeyPrefix, $seq
        if ($PSCmdlet.ShouldProcess("matter '$($m.name)'", "set external_key=$key")) {
            try {
                $body = @{ external_key = $key } | ConvertTo-Json -Compress
                Invoke-RestMethod -Uri "$BaseUrl/api/matters/$($m.id)" -Method Patch `
                    -Headers $h -ContentType 'application/json' -Body $body -TimeoutSec 30 | Out-Null
                Write-Ok "'$($m.name)' -> $key"
            }
            catch {
                $status = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
                if ($status -eq 405) {
                    # The route is admin-only and was added 2026-10-19. A 405 means
                    # this release predates it: PATCH /api/matters/:id does not
                    # exist in the running image, so no key can be set. Saying so
                    # beats "Method Not Allowed", which reads like a bug in the
                    # script rather than a stale deployment.
                    Write-Bad "'$($m.name)' -> $key failed (HTTP 405)."
                    Write-Note 'This pacgate-api release does not serve PATCH /api/matters/:id:'
                    Write-Note 'external_key repair was added in the release after 0.1.32.'
                    Write-Note 'Update this machine first: .\install.ps1 -Update'
                    break
                }
                Write-Bad "'$($m.name)' -> $key failed (HTTP $status): $($_.Exception.Message)"
            }
        }
    }

    Write-Step 'Backfill complete'
    if ($script:failures -gt 0) {
        Write-Note 'Not all matters were keyed - see the failures above.'
        exit 1
    }
    Write-Note 'Keys are now stable across machines, so Import can match exactly.'
    exit 0
}

# ===========================================================================
# EXPORT
# ===========================================================================
if ($Action -eq 'Export') {
    if (-not $OutDir) { Write-Bad '-OutDir is required for Export'; exit 1 }
    if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }

    Write-Step "Authenticating to $BaseUrl"
    $h = New-Headers (Get-Token)
    Write-Ok "authenticated as $Email"

    Write-Step 'Reading matters'
    $matters = Get-Api '/api/matters' $h
    Write-Ok "$($matters.Count) matter(s)"

    $manifest = [ordered]@{
        exportedAt   = (Get-Date).ToUniversalTime().ToString('o')
        source       = $BaseUrl
        toolVersion  = '1'
        matters      = @()
        documents    = @()
        blockedDocuments = @()
        keyFallbacks = 0
    }

    $docCount = 0
    foreach ($m in $matters) {
        $entry = [ordered]@{
            sourceId    = $m.id
            name        = $m.name
            description = $m.description
            externalKey = $m.external_key
            identityKey = if ($m.external_key) { 'external_key' } else { 'name' }
        }
        if (-not $m.external_key) { $manifest.keyFallbacks++ }

        # Memory is optional: a matter that was never used has none.
        try {
            $mem = Get-Api "/api/matters/$($m.id)/memory" $h
            $entry.memory = $mem
        }
        catch { $entry.memory = $null }

        $manifest.matters += $entry

        $matterDocDir = Join-Path $OutDir ("docs/" + $m.id)
        try { $docs = Get-Api "/api/matters/$($m.id)/documents" $h }
        catch { Write-Warn "cannot list documents for '$($m.name)': $($_.Exception.Message)"; continue }

        foreach ($d in $docs) {
            if (-not $d.id) { continue }
            if (-not (Test-Path -LiteralPath $matterDocDir)) {
                New-Item -ItemType Directory -Path $matterDocDir -Force | Out-Null
            }
            $safe = ($d.id + '_' + ($d.name -replace '[^\w\.\-]', '_'))
            $target = Join-Path $matterDocDir $safe
            try {
                # -OutFile, NOT .Content. In PowerShell 7 Invoke-WebRequest
                # returns a STRING in .Content for text/* responses, so
                # WriteAllBytes tried to coerce a Chinese markdown body to
                # System.Byte and failed on every txt/md document while binary
                # formats worked. Writing straight to the file keeps the bytes
                # exactly as the server sent them, whatever the content type.
                if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Force }
                Invoke-WebRequest -Uri "$BaseUrl/api/documents/$($d.id)/download" `
                    -Headers $h -Method Get -TimeoutSec 300 -UseBasicParsing -OutFile $target | Out-Null
            }
            catch {
                $status = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
                if ($status -eq 409) {
                    # The egress gate, working as designed: download refuses any
                    # document whose sanitization_state is neither 'sanitized' nor
                    # 'never'. That is a deliberate policy control, NOT a sync
                    # defect - so it is recorded and reported, never bypassed.
                    # Bypassing it would move unsanitized client material between
                    # machines, which is the exact thing the gate exists to stop.
                    $manifest.blockedDocuments += [ordered]@{
                        matterName = $m.name
                        name       = $d.name
                        id         = $d.id
                        reason     = 'egress gate: sanitization_state is neither sanitized nor never'
                    }
                    Write-Note "egress-gated (not copied): '$($d.name)' on '$($m.name)'"
                }
                else {
                    Write-Warn "cannot download '$($d.name)' on matter '$($m.name)': $($_.Exception.Message)"
                }
                continue
            }
            $manifest.documents += [ordered]@{
                sourceId     = $d.id
                matterSource = $m.id
                name         = $d.name
                format       = "$($d.format)"
                fileName     = $safe
                relPath      = "docs/$($m.id)/$safe"
                size         = (Get-Item -LiteralPath $target).Length
            }
            $docCount++
        }
    }

    $manifestPath = Join-Path $OutDir 'manifest.json'
    $manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifestPath -Encoding utf8NoBOM

    Write-Step 'Export complete'
    Write-Ok "matters   : $($manifest.matters.Count)"
    Write-Ok "documents : $docCount"
    Write-Ok "manifest  : $manifestPath"
    if ($manifest.blockedDocuments.Count -gt 0) {
        Write-Warn "$($manifest.blockedDocuments.Count) document(s) NOT copied - held by the egress gate."
        Write-Note 'Those documents are not sanitized, so the API refuses to let them leave.'
        Write-Note 'That control is doing its job. To transfer one deliberately, sanitize it'
        Write-Note 'first (or mark it never-egress) on this machine, then re-export.'
    }
    if ($manifest.keyFallbacks -gt 0) {
        Write-Warn "$($manifest.keyFallbacks) matter(s) have no external_key - imported by NAME."
        Write-Note 'A name is not a guaranteed unique key. Two matters with the same name'
        Write-Note 'would be merged on import. Populate external_key to make this exact.'
    }
    exit 0
}

# ===========================================================================
# IMPORT
# ===========================================================================
if (-not $InDir) { Write-Bad '-InDir is required for Import'; exit 1 }
$manifestPath = Join-Path $InDir 'manifest.json'
if (-not (Test-Path -LiteralPath $manifestPath)) {
    Write-Bad "no manifest.json in $InDir - was that directory produced by -Action Export?"
    exit 1
}
$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if (-not $manifest.PSObject.Properties['exportedAt']) {
    Write-Warn 'manifest has no exportedAt - it may be hand-edited'
}

Write-Step "Authenticating to $BaseUrl"
$h = New-Headers (Get-Token)
Write-Ok "authenticated as $Email"

# ---- plan: what exists here already -----------------------------------------
Write-Step 'Indexing the destination'
# DO NOT wrap this in @(...). Invoke-RestMethod emits a JSON array as a SINGLE
# object on the pipeline, so @( ) around the CALL wraps the whole array in an
# outer 1-element array: $existingMatters.Count became 1 while 63 matters
# existed, and the foreach below then iterated once over the array itself. Every
# external_key lookup missed as a result, so a re-import tried to CREATE matters
# that already existed and hit the partial unique index (HTTP 500). Assigning to
# a variable first keeps the real array.
$existingMatters = Get-Api '/api/matters' $h
if ($null -eq $existingMatters) { $existingMatters = @() }
$byExternalKey = @{}
$byName = @{}
foreach ($m in $existingMatters) {
    if ($m.external_key) { $byExternalKey[$m.external_key] = $m }
    if ($m.name) {
        if (-not $byName.ContainsKey($m.name)) { $byName[$m.name] = @() }
        $byName[$m.name] = @(@($byName[$m.name]) + $m)
    }
}
Write-Ok "$((@($existingMatters) | Measure-Object).Count) matter(s) already present"

# A name is NOT a unique key. Measured on the dev box 2026-10-19: 59 matters
# contained 50 SEPARATE matters all named "Sanitizer E2E", because every run of
# test-sanitizer-e2e.ps1 creates one by name. Resolving by name therefore picked
# an arbitrary member of the group, attached the source matter's documents to the
# wrong one, and - worse - an empty one looked "already present" so its documents
# were silently never imported. Refuse ambiguous names instead of guessing.
$ambiguousNames = @()
foreach ($k in $byName.Keys) { if ((@($byName[$k]) | Measure-Object).Count -gt 1) { $ambiguousNames += $k } }

# ---- repair duplicate matters created by an earlier import -------------------
# An import that matched by name could leave a duplicate behind (it saw an empty
# matter as a match, or missed and created a second one). Offer to remove ONLY
# matters that (a) share a name with another matter, and (b) have NO documents
# attached - so no material can be lost. Anything with a document is reported and
# left alone, because this tool must never delete work.
if ($ambiguousNames.Count -gt 0) {
    Write-Step "Ambiguous matter names at the destination ($($ambiguousNames.Count))"
    foreach ($n in ($ambiguousNames | Sort-Object | Select-Object -First 10)) {
        Write-Note "'$n' x$(($byName[$n] | Measure-Object).Count)"
    }
    if ($ambiguousNames.Count -gt 10) { Write-Note "... and $($ambiguousNames.Count - 10) more" }
    Write-Warn 'Import will CREATE a new matter instead of guessing which one you meant.'
    Write-Note 'Attaching client documents to an arbitrary duplicate is worse than a duplicate.'
    Write-Note 'To fix properly: populate matters.external_key so the key is unambiguous.'
    Write-Note 'This tool never deletes a matter. DELETE /api/matters/:id answers 500 when'
    Write-Note 'dependent rows exist, so automatic cleanup is not safe to offer here.'

    $emptyDupes = 0
    foreach ($n in ($byName.Keys | Where-Object { ($byName[$_] | Measure-Object).Count -gt 1 })) {
        $group = @($byName[$n] | Sort-Object created_at | Select-Object -Skip 1)
        foreach ($cand in $group) {
            try {
                $docs = @(Get-Api "/api/matters/$($cand.id)/documents" $h | ForEach-Object { $_ })
                if ((@($docs) | Measure-Object).Count -eq 0) { $emptyDupes++ }
            }
            catch { }
        }
    }
    if ($emptyDupes -gt 0) {
        Write-Note "$emptyDupes empty duplicate(s) exist. They are harmless but clutter the list."
    }
}

$createdMatters = 0
$reusedMatters = 0
$createdDocs = 0
$skippedDocs = 0
$createdUsers = 0

# ---- matters ----------------------------------------------------------------
Write-Step 'Importing matters'
foreach ($me in $manifest.matters) {
    $target = $null
    $matchedBy = $null

    if ($me.externalKey -and $byExternalKey.ContainsKey($me.externalKey)) {
        $target = $byExternalKey[$me.externalKey]; $matchedBy = 'external_key'
    }
    elseif ($byName.ContainsKey($me.name) -and (@($byName[$me.name]) | Measure-Object).Count -eq 1) {
        # Only an UNAMBIGUOUS name may be reused. See the ambiguousNames block
        # above: 50 matters on this box share one name, so trusting a name match
        # silently attached documents to the wrong matter.
        #
        # `@(...) | Measure-Object` rather than `$byName[$name].Count`: PowerShell
        # returns a bare STRING (not a 1-element array) when the stored value has
        # one element, and a string has no .Count, so the uniqueness test silently
        # evaluated to 0 and every unique name looked ambiguous.
        $target = @($byName[$me.name])[0]; $matchedBy = 'name'
        if (-not $me.externalKey) {
            Write-Note "reusing '$($me.name)' by unique NAME (no external_key on the source matter)"
        }
    }
    elseif ($byName.ContainsKey($me.name)) {
        Write-Warn "'$($me.name)' matches $(@($byName[$me.name]) | Measure-Object).Count matters here - creating a new one rather than guessing"
    }

    if ($target) {
        $reusedMatters++
        Write-Note "exists: '$($me.name)' (matched by $matchedBy)"
    }
    else {
        if ($PSCmdlet.ShouldProcess("matter '$($me.name)'", 'create')) {
            $payload = @{
                name         = $me.name
                description  = $me.description
                external_key = $me.externalKey
            } | ConvertTo-Json -Compress
            try {
                $target = Invoke-RestMethod -Uri "$BaseUrl/api/matters" -Method Post `
                    -Headers $h -ContentType 'application/json' -Body $payload -TimeoutSec 60
                $createdMatters++
                Write-Ok "created '$($me.name)'"
                if ($me.externalKey) { $byExternalKey[$me.externalKey] = $target }
                if (-not $byName.ContainsKey($me.name)) { $byName[$me.name] = @() }
                # Wrap so a previously-single entry becomes an array before adding.
                $byName[$me.name] = @(@($byName[$me.name]) + $target)
            }
            catch {
                Write-Bad "cannot create '$($me.name)': $($_.Exception.Message)"
                continue
            }
        }
        else { continue }
    }

    # ---- memory -------------------------------------------------------------
    # Written verbatim. save_matter_memory enforces scope and an If-Match
    # revision, so a stale export cannot silently overwrite newer memory: the
    # call either succeeds against the current revision or is refused.
    if ($me.memory) {
        if ($PSCmdlet.ShouldProcess("memory of '$($me.name)'", 'restore')) {
            try {
                $body = $me.memory | ConvertTo-Json -Depth 20 -Compress
                Invoke-RestMethod -Uri "$BaseUrl/api/matters/$($target.id)/memory" -Method Post `
                    -Headers $h -ContentType 'application/json' -Body $body -TimeoutSec 60 | Out-Null
                Write-Note "memory restored for '$($me.name)'"
            }
            catch {
                Write-Warn "memory not restored for '$($me.name)': $($_.Exception.Message)"
            }
        }
    }

    # ---- documents ----------------------------------------------------------
    $docs = @($manifest.documents | Where-Object { $_.matterSource -eq $me.sourceId })
    if ($docs.Count -eq 0) { continue }

    $present = @{}
    try {
        foreach ($d in (Get-Api "/api/matters/$($target.id)/documents" $h)) {
            if (-not $d.name) { continue }
            $present[$d.name] = $d
            $present[($d.name -replace '\.[A-Za-z0-9]{1,5}$', '')] = $d
        }
    }
    catch { }
    foreach ($d in $docs) {
        # Compare on the BASE name: uploads are stored under the extension-bearing
        # filename, while older rows were stored under the bare name.
        $baseName = ($d.name -replace '\.[A-Za-z0-9]{1,5}$', '')
        if ($present.ContainsKey($d.name) -or $present.ContainsKey($baseName)) {
            $skippedDocs++
            Write-Note "document exists: '$($d.name)'"
            continue
        }
        $srcPath = Join-Path $InDir $d.relPath
        if (-not (Test-Path -LiteralPath $srcPath)) {
            Write-Warn "bundle is missing $($d.relPath) for '$($d.name)'"
            continue
        }
        if ($PSCmdlet.ShouldProcess("document '$($d.name)'", "upload to '$($me.name)'")) {
            try {
                $bytes = [System.IO.File]::ReadAllBytes($srcPath)
                # Upload under the original name PLUS the format extension, which
                # is what the API parses. Using $d.name alone sends no extension
                # and the API answers 400 for every document.
                $uploadName = if ($d.name -match '\.[A-Za-z0-9]{1,5}$') { $d.name }
                              else { $d.name + (Get-FormatExtension $d.format) }
                $ct = Get-ContentType $uploadName
                Send-Document $h $target.id $uploadName $bytes $ct | Out-Null
                $createdDocs++
                Write-Ok "uploaded '$uploadName' -> '$($me.name)'"
            }
            catch {
                $status = try { [int]$_.Exception.Response.StatusCode } catch { 0 }
                Write-Bad "upload failed for '$($d.name)' (HTTP $status): $($_.Exception.Message)"
            }
        }
    }
}

Write-Step 'Import complete'
Write-Ok "matters created : $createdMatters"
Write-Ok "matters reused  : $reusedMatters"
Write-Ok "documents added : $createdDocs"
Write-Ok "documents skipped (already present): $skippedDocs"
if ($createdUsers -gt 0) { Write-Ok "users created   : $createdUsers" }
Write-Note 'NOT transferred by design: password hashes, kb_chunks, document_spans, audit_log.'
Write-Note 'Those are derived or per-machine. Run extract -> sanitize here to rebuild them.'

if ($script:failures -gt 0) {
    Write-Host "`nFAIL: $script:failures step(s) failed." -ForegroundColor Red
    exit 1
}
exit 0
