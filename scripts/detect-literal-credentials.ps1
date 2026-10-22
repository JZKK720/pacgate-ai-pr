# Precise detector for LITERAL credential values in tracked docs/code.
#
# Tuned to the failure modes this repo actually has:
#   (a) CJK prose:   a CJK password/login/API-key label, a colon, then <literal>
#                    (full-width or half-width colon)
#   (b) markdown row, BOLD label:   | **Password** | `<literal>` |
#   (c) markdown row, PLAIN label:  | Password | `<literal>` |     <- added 2026-10-15
#   (d) markdown row, NO label:     | `admin@x.com` | `<literal>` | <- added 2026-10-15
# plus known key formats (vq_key_, sk-, ghp_, github_pat_, AKIA, AIza, xox).
#
# (c) and (d) exist because the bold-only rule missed a LIVE pacgate-api password
# in a PUBLIC repo for six days. See the note on the md-Password rule below.
#
# Reports FILE + LINE + RULE only. Never prints the value.
# Ignores obvious non-secrets: type annotations, env refs, placeholders.
#
# EXIT CODES: 0 = clean, 1 = findings. Non-zero-on-findings was added 2026-10-15
# so this can act as a gate; before that it always exited 0 and could not.
#
# ASCII-ONLY by design: the client AIPC has only Windows PowerShell 5.1, which
# cannot parse a BOM-less script holding non-ASCII literals. The CJK rules below
# are written as \uXXXX escapes for exactly this reason - see
# deploy/DEFECT-ps51-cjk-literal-parse-failure.md.
param(
    [string[]]$Paths,

    # Print findings as file names only. For callers that want a compact gate result.
    [switch]$Quiet
)

if (-not $Paths) {
    # -c core.quotepath=false stops git from C-quoting non-ASCII paths (it emitted
    # "C:\...\u6cd5\u5f8b\u6570\u636e\u5e93MCP.md"-style strings, which then blew up
    # [System.IO.Path]::GetExtension with "Illegal characters in path"). Paths that
    # STILL cannot be stat'd are counted and reported, never silently skipped - a
    # silent skip is how a detector develops a blind spot nobody notices.
    $Paths = @(git -c core.quotepath=false ls-files)
}

$textExt = @('.md', '.txt', '.json', '.jsonc', '.yaml', '.yml', '.ps1', '.sh', '.py', '.rs', '.ts', '.js', '.sql', '.conf', '.ini', '.cfg', '.toml', '.example')

# Values that are clearly NOT secrets - if the whole value matches, skip.
#
# `supersecret\w*` is deliberate: deploy/DEFECT-ps51-cjk-literal-parse-failure.md
# documents the parse failure with the literal example `密码：SuperSecret123`, and
# without this the scan reports a permanent false positive on that file. The trade-off
# is that a REAL credential beginning "supersecret" would be skipped - acceptable
# because generated secrets in this repo are random hex, and a false positive here gets
# read as "the detector is noisy" and then ignored, which is how the last miss happened.
# Scoping the skip to the file instead was rejected: a file-level exclusion blinds the
# whole document, including any credential added to it later.
$placeholderRe = '(?i)^(\u5F85\u586B\u5199|\u5F85\u8865|xxx+|\*+|\u25A1+|todo|tbd|n/?a|none|null|-+|your[-_]?\w*|\{\{.*\}\}|\$\{.*\}|<.*>|redacted|placeholder|example|dummy|sample|changeme|change-me|change_me|value_here|replace[-_]?locally|ollama|ollama-local|\[REDACTED[^\]]*\]|supersecret\w*|password|email|role|account|verified|user|admin)$'

# A markdown table HEADER or separator row declares column names; it never holds a
# credential. Without this, `| Account | Email | Password | Role | Verified |` fires
# md-Email on the literal word "Password" and md-Password on the literal word "Role".
#
# It must match ONLY when EVERY cell is a column name. My first attempt matched any
# row whose FIRST cell was a column word, which silently suppressed the real
# findings on `| Password | `nHri...` |` and `| Email | admin@... |` - the same
# "a rule that is too broad hides the thing you are looking for" failure this change
# exists to fix. MEASURED: that version reported 3 lines and missed both.
$hdrWords  = 'account|email|password|role|user|username|verified|source|url|key|secret|token|value|name|note|status|machine|host|date|version'
$mdHeaderRe = "(?i)^\s*\|(?:\s*:?-{2,}:?\s*\|)+\s*$|^\s*\|\s*(?:$hdrWords)\s*\|(?:\s*(?:$hdrWords)\s*\|)+\s*$"

# Known real-secret formats - always flag, wherever they appear.
$formatRules = @(
    @{ Name = 'vq_key';      Re = 'vq_key_[A-Za-z0-9_\\\-]{10,}' }
    @{ Name = 'sk-key';      Re = 'sk-[A-Za-z0-9_\-]{16,}' }
    @{ Name = 'gh-pat';      Re = 'gh[pous]_[A-Za-z0-9]{30,}' }
    @{ Name = 'gh-finegrained'; Re = 'github_pat_[A-Za-z0-9_]{40,}' }
    @{ Name = 'aws-akia';    Re = 'AKIA[0-9A-Z]{16}' }
    @{ Name = 'google-aiza'; Re = 'AIza[0-9A-Za-z_\-]{35}' }
    @{ Name = 'slack-xox';   Re = 'xox[baprs]-[A-Za-z0-9\-]{10,}' }
    @{ Name = 'pem-block';   Re = '-----BEGIN [A-Z ]*PRIVATE KEY-----' }
)

# Label-driven rules: capture the value after a credential label, then decide.
# A bare email address is not a secret. It is an account IDENTIFIER, and
# admin@pacgate-law.com is published by design in deploy/client-bundle/.env.example
# and across the handover docs. `md-Email` used to fire on every one of those, which
# produced two report lines that were not findings and buried the two that were.
#
# `email` stays in $placeholderRe as a belt-and-braces guard for the CJK login rule.
# If a real credential is ever paired with an address on the same line, a
# password/API-key rule on that same line still catches it, so nothing is lost by
# dropping the address-only rule. The bold-pairing variant is kept in
# redact-exposed-credentials.ps1 for the assets docs, where an email+password block
# was pasted together and the addresses genuinely do not belong in a public repo.
$labelRules = @(
    # Rule NAMES are ASCII because single-quoted PowerShell strings do not expand
    # \uXXXX - only the .NET regex engine does. The Re patterns keep the escapes
    # (so the file stays ASCII-only and PS 5.1 can parse it); the names are plain
    # labels so the report does not print literal "\u5BC6\u7801".
    @{ Name = 'cjk-password'; Re = '\u5BC6\u7801\s*[\uFF1A:]\s*(?:&#xA;)?\s*(?<v>[^\s|`]+)' }
    @{ Name = 'cjk-login';    Re = '(?:\u7EDF\u4E00)?\u767B\u5F55\u540D\s*[\uFF1A:]\s*(?<v>[^\s|`]+)' }
    @{ Name = 'cjk-apikey';   Re = '\u5BC6\u94A5\s*[\uFF1A:]\s*(?<v>[^\s|`]+)' }
    # The field name may or may not be BOLD. It used to require the bold form, and
    # that single difference hid a live credential in a PUBLIC repository.
    #
    # MEASURED 2026-10-15: `| **Password** | `x` |` matched; `| Password | `x` |` did
    # not. deploy/BENCHMARK-REPORT-2026-10-08.md uses the plain form, and it carried
    # the pacgate-api admin password BYTE-IDENTICAL to the running .env, plus a
    # deer-flow admin password and an OpenViking key - all tracked, all public. This
    # scanner reported "FINDINGS: 1" on that tree, and the one finding was a false
    # positive in a DEFECT doc. A credential scanner with a formatting-dependent miss
    # is worse than none, because its clean report is taken as evidence.
    #
    # `(?:\*\*)?` accepts both. Anything that keys on presentation is one table edit
    # away from going quiet again.
    @{ Name = 'md-Password'; Re = '\|\s*(?:\*\*)?\s*[Pp]assword\s*(?:\*\*)?\s*\|\s*`?(?<v>[^`|\s]+)`?\s*\|' }
    # A bare credential in a code span with NO label on its own row. The benchmark
    # report's credentials table declares its columns once in a HEADER row
    # (`| Account | Email | Password | Role | Verified |`) and then lists rows that
    # carry only values, so the password is not adjacent to the word "Password" and
    # no label rule can reach it. Kept narrow (24-40 alphanumerics) to stay usable:
    # this is a signal to go look, not proof.
    @{ Name = 'md-bare-token'; Re = '\|\s*`(?<v>[A-Za-z0-9]{24,40})`\s*\|' }

    # A HARDCODED password assigned to a variable, property, or parameter default.
    # `[string]$DfPassword = '<literal>'` lived in two tracked scripts until
    # 2026-10-15 and put a live deer-flow password in a PUBLIC repo. None of the
    # rules above could see it: it is not a markdown row, not a CJK label, and not a
    # known key format. This shape was the cause of the missed finding and had no rule.
    #
    # Deliberately narrow, because a loose version of this rule is worse than none:
    # it fired on `token="test-token"` (a unit-test fixture) and on `"******"`
    # redaction markers in the operator docs, and permanent false positives are how
    # the previous rule got ignored.
    #
    #   - `password|passwd|pwd|secret` only. `token` was dropped as too generic.
    #   - requires `=` immediately, so prose ("set a password to 12 chars") cannot fire.
    #   - `[:=]` accepts the colon form used by YAML and Rust (`secret: "..."`), not
    #     just the assignment form. The broad sweep that found the hardcoded PowerShell
    #     defaults also found `secret: "..."` in state.rs and the Rust tests; without
    #     this, a real YAML `password: "<value>"` would still be invisible.
    #   - requires 12+ chars (real generated secrets here are 16-24).
    #   - the negative lookahead drops values containing `- $ : { } *`. That excludes
    #     `$env:PACGATE_API_PASSWORD` (a reference) and the gate fixtures
    #     `workspace-pass-123`, `ProvProbe-Passw0rd!`, `Zq7#vault-probe-9931`
    #     (all hyphenated BY DESIGN, so they cannot be mistaken for generated secrets).
    #     Verified against all five: each is excluded, while all three real leaked
    #     values (16-24 char alphanumeric, e.g. the pacgate-api and deer-flow admin
    #     passwords redacted from deploy/BENCHMARK-REPORT-2026-10-08.md, recoverable
    #     via `git log -S`) still match. They are deliberately NOT written here: an
    #     earlier draft of this comment quoted them verbatim, which would have
    #     re-introduced the very exposure this rule exists to detect.
    #
    # Known gap, stated rather than hidden: a real password that uses a hyphen or a
    # `$` would be missed by this rule. It is a heuristic for regression detection,
    # not a proof - the md-bare-token and known-format rules cover other shapes.
    @{ Name = 'ps-password-literal'; Re = '(?i)(?:password|passwd|pwd|secret)["'']?\s*[:=]\s*["''](?<v>(?![^"'']*[-$:{}*])[A-Za-z0-9!@#%^&+=?/~_.]{12,})["'']' }
)

# Scanners contain credential-shaped regex literals by design. Excluded so the
# scan does not report a permanent false positive on itself.
$scannerFiles = @(
    'detect-literal-credentials.ps1'
    'redact-exposed-credentials.ps1'
    'assert-no-staged-secrets.ps1'
    'assert-range-no-new-secrets.ps1'
    'check-credential-state.ps1'
)

$hits = @()
$skipped = @()

foreach ($rel in $Paths) {
    try {
        $ext = [System.IO.Path]::GetExtension($rel).ToLower()
        if ($textExt -notcontains $ext) { continue }
        if (-not (Test-Path -LiteralPath $rel)) { $skipped += $rel; continue }
        if ((Get-Item -LiteralPath $rel).PSIsContainer) { continue }
    }
    catch {
        # Name could not be resolved on this shell (see core.quotepath note above).
        # COUNT it so the run reports partial coverage instead of implying a clean tree.
        $skipped += $rel
        continue
    }

    # Self-exclusion. The credential scanners contain credential-shaped regex
    # literals by design; matching them would report a permanent false positive
    # and train people to ignore this scan entirely.
    if ($scannerFiles -contains (Split-Path $rel -Leaf)) { continue }

    $lines = $null
    # Wrap in @() to FORCE an array. Get-Content returns a bare [string] for a
    # single-line file, and indexing that yields the first CHARACTER, not the
    # line - which made this scan silently miss any one-line file (verified:
    # a planted CJK password line in a 1-line file was read as just one character).
    #
    # -Encoding UTF8 is REQUIRED, not cosmetic. Windows PowerShell 5.1 defaults
    # Get-Content to the machine's ANSI codepage (GBK here), so a UTF-8 CJK label
    # arrives as mojibake and EVERY CJK rule silently fails to match. MEASURED
    # 2026-10-15: a planted CJK password line was read as mojibake under 5.1 and the
    # scan reported CLEAN, exit 0; with -Encoding UTF8 the same line is found.
    # That is a detector that is dead on the only shell the client AIPC has.
    try { $lines = @(Get-Content -LiteralPath $rel -Encoding UTF8 -ErrorAction Stop) } catch { continue }

    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        $lineno = $i + 1

        # Column-name and rule rows in a markdown table are structure, not data.
        if ([regex]::IsMatch($line, $mdHeaderRe)) { continue }

        $fired = @()

        foreach ($r in $formatRules) {
            if ([regex]::IsMatch($line, $r.Re)) { $fired += $r.Name }
        }

        foreach ($r in $labelRules) {
            $m = [regex]::Match($line, $r.Re)
            if ($m.Success) {
                $v = $m.Groups['v'].Value.Trim()
                if ($v.Length -ge 6 -and -not [regex]::IsMatch($v, $placeholderRe)) {
                    $fired += $r.Name
                }
            }
        }

        if ($fired.Count -gt 0) {
            $hits += [pscustomobject]@{
                File   = $rel
                Line   = $lineno
                Rules  = (($fired | Select-Object -Unique) -join ', ')
            }
        }
    }
}

if (-not $hits) {
    Write-Output 'CLEAN: no literal credential values detected in tracked text files.'
    if ($skipped.Count -gt 0) {
        # Printed even on a clean run: "CLEAN" over 3 unresolvable paths is weaker
        # evidence than "CLEAN" over all of them, and the difference must be visible.
        Write-Output ("WARNING: {0} path(s) could not be read and were NOT scanned." -f $skipped.Count)
        $skipped | Select-Object -First 5 | ForEach-Object { Write-Output ("    skipped: {0}" -f $_) }
    }
    exit 0
}
else {
    Write-Output ("FINDINGS: {0} line(s) across {1} file(s)" -f $hits.Count, ($hits | Group-Object File).Count)
    if ($Quiet) {
        $hits | Group-Object File | Sort-Object Name | ForEach-Object { Write-Output ("FILE: {0}" -f $_.Name) }
    }
    else {
        Write-Output ''
        $hits | Group-Object File | Sort-Object Name | ForEach-Object {
            Write-Output ("FILE: {0}" -f $_.Name)
            $_.Group | ForEach-Object { Write-Output ("    line {0,-5} [{1}]" -f $_.Line, $_.Rules) }
            Write-Output ''
        }
    }

    # Non-zero on findings, so this can act as a gate. Until 2026-10-15 this script
    # had no exit statement at all and always returned 0, which is why it was never
    # registered in run-all-checks.ps1 and why CI could not have caught the exposure
    # it was written for. A detector that cannot fail is documentation, not a control.
    exit 1
}
