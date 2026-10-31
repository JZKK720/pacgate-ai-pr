# Firecrawl Connector + Full-Stack E2E Coverage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a first-class Firecrawl web-search connector that any AIPC can activate by pasting its own API key, and close the two measured end-to-end coverage gaps (the legal journey is not in the gate suite; nothing exercises the agent→MCP call path).

**Architecture:** Firecrawl becomes a `DataSourceConnector` implementation inside `pacgate-search`, registered in `default_router()` and gated on `FIRECRAWL_API_KEY`. It is **not** a third-party MCP server in `deer-flow-extensions-config.json` — that is why this works where the earlier plan could not proceed: the Rust connector pattern already handles a missing key safely (`is_available()` → `false`, `search()` → empty), so an AIPC with no key loses nothing and gains everything once a key is pasted.

**Tech Stack:** Rust (tokio, reqwest, serde_json, async-trait) inside `pacgate-ai/crates/pacgate-search`; PowerShell 5.1-compatible gates; Docker Compose.

## Global Constraints

- Connector search must never fabricate: on any failure return `Vec::new()` and `tracing::warn!`, matching every existing connector.
- `is_available()` must be exactly `self.api_key.is_some()` — the property that makes a missing key a non-event.
- `source_level` is `"auxiliary_db"` (a web page is not statutory authority). `pacgate-core::SourceLevel` derives `snake_case`.
- `SearchResult.source_name` must equal `name()`; the router and `/api/search/health` both rely on that agreement.
- Every connector key comes from `.env` via `env_file:` — never a compose `environment:` literal, never tracked. `.gitignore:151` covers `.env`.
- Gates: `0` pass, `1` real failure, `2` CANNOT CHECK. Exit 2 is never a failure and never a pass.
- A `.ps1` with CJK literals needs a UTF-8 BOM; ASCII-only files must not have one.
- Patch/`.gitattributes` LF rules apply to `deploy/client-bundle/patches/**`; Rust sources are ordinary LF.
- No `0.2.9` bump in this plan. Compose pins stay at `0.2.8`, and the stack is already up on it.

---

## Verified findings this plan is built on

Measured 2026-10-31 against the running 0.2.8 stack and the tracked source. Do not re-derive; do not "fix" anything not listed.

| # | Finding | Evidence |
|---|---|---|
| F1 | Firecrawl is **not** in the MCP connector template | `deer-flow-extensions-config.template.json` carries exactly `openviking`, `pacgate`, `officecli` |
| F2 | Firecrawl is **not** an MCP server on AIPC1's image either | 0.2.8 image has no `firecrawl-mcp`/`firecrawl` binary; only `npx` |
| F3 | Firecrawl is reachable **as a REST API** | `POST https://api.firecrawl.dev/v1/search` → `http=200` with `{"success":true,"data":[...]}`, no key required for this endpoint to answer |
| F4 | Response contract | top-level `success`, `data`, `id`; each item `url`, `title`, `description`. `limit` honored (asked 2, got 2). CJK query works (中华人民共和国合同法) |
| F5 | Connector architecture already exists | `pacgate-search/src/lib.rs` has `DataSourceConnector` trait + `SearchRouter` + `default_router()` with 11 connectors |
| F6 | Baseline connector availability | legal journey: **4 of 10** available — `courtlistener, sec_edgar, gleif, eur-lex` |
| F7 | **Doc bug**: CourtListener key name is wrong in docs | code reads `COURTLISTENER_API_KEY` (lib.rs:540, 1681); both compose comments and `plans/013-credential-rotation.md:281` say `COURT_LISTENER_API_KEY` |
| F8 | **Coverage gap 1**: legal journey not in the suite | `test-legal-journey.ps1` passes 19/19 but is absent from `run-all-checks.ps1`'s `$gates` |
| F9 | **Coverage gap 2**: no agent→MCP E2E | `smoke-full-stack.ps1:188` states verbatim: "agent->MCP invocation NOT exercised ... there is no committed agent-run E2E" |
| F10 | Full 8-service stack is healthy | `pacgate-db`, `pacgate-api`, `deer-flow`, `deer-flow-frontend`, `pacgate-mcp`, `ocr-service`, `openviking`, `nginx` all up; 7 smoke lanes |

---

## File Structure

| Path | Responsibility |
|---|---|
| `pacgate-ai/crates/pacgate-search/src/lib.rs` | *(modify)* `FirecrawlConnector` impl + registration in `default_router()` |
| `deploy/client-bundle/.env.example` | *(modify)* document `FIRECRAWL_API_KEY` with the paste-your-own-key instructions |
| `deploy/client-bundle/compose.prod.yaml`, `compose.bundle.yaml` | *(modify)* add `FIRECRAWL_API_KEY` to the connector-key comment; fix the `COURT_LISTENER_API_KEY` typo |
| `scripts/test-connector-registry.ps1` | *(create)* static gate: every connector's key var is documented correctly, and Firecrawl is registered |
| `scripts/test-agent-mcp-e2e.ps1` | *(create)* live gate: an agent run invokes a real MCP tool end to end |
| `scripts/run-all-checks.ps1` | *(modify)* register legal-journey + the two new gates |
| `deploy/AIPC-UPDATE-GAP-ANALYSIS.md` | *(modify)* record the connector + coverage decisions |

---

### Task 1: Firecrawl connector in pacgate-search

**Files:**
- Modify: `pacgate-ai/crates/pacgate-search/src/lib.rs` (insert the connector before `default_router` at line ~1663; add one `with_connector` line inside it)

**Interfaces:**
- Consumes: `DataSourceConnector`, `SearchQuery`, `SearchResult`, `SearchError`, `build_connector_client()`.
- Produces: `pub struct FirecrawlConnector` with `FirecrawlConnector::new(api_key: Option<String>) -> Self`; `name()` returns `"firecrawl"`.

- [ ] **Step 1: Confirm the exact insertion point and baseline build**

```powershell
cd D:\users\joeyzh\github-pr\pacgate-ai-pr
Select-String -Path pacgate-ai/crates/pacgate-search/src/lib.rs -Pattern '^pub fn default_router' 
cargo build -p pacgate-search 2>&1 | Select-Object -Last 3
```

Expected: `default_router` at line ~1663, and a clean build. Record the baseline warning count; the new code must not increase it.

- [ ] **Step 2: Add the connector implementation**

Insert immediately before the `/// Create a default SearchRouter with all connectors.` comment that precedes `pub fn default_router()`:

```rust
// ─────────────────────────────────────────────────────────────────────────────
// Firecrawl — general web search and page extraction
// ─────────────────────────────────────────────────────────────────────────────

/// Firecrawl — web search and page-to-markdown extraction.
///
/// Requires an API key (env: `FIRECRAWL_API_KEY`). Each AIPC registers its own
/// key, so this connector is deliberately inert until one is pasted into `.env`:
/// `is_available()` is false and `search()` returns an empty Vec, which the router
/// treats as "no results from this source" rather than an error.
///
/// WHY THIS IS A CONNECTOR AND NOT AN MCP SERVER: measured 2026-10-31, the pinned
/// deer-flow image carries no `firecrawl-mcp` binary (only `npx`), the MCP
/// connector template has never contained a firecrawl entry, and that image has
/// NO per-server isolation - `get_mcp_tools()` awaits one `client.get_tools()` for
/// all servers and returns `[]` on any exception. So a firecrawl MCP entry with an
/// empty key would not degrade web search; it would remove every MCP tool,
/// including `pacgate` and `officecli`. As a Rust connector its failure mode is a
/// single empty result set, which is the property that makes per-machine keys safe.
///
/// `source_level` is `auxiliary_db`, not `authority_verified`: a web page is not
/// statutory text, and the 4-level grading must not be inflated by a search hit.
pub struct FirecrawlConnector {
    api_key: Option<String>,
    client: reqwest::Client,
}

impl FirecrawlConnector {
    pub fn new(api_key: Option<String>) -> Self {
        Self {
            api_key,
            client: build_connector_client(),
        }
    }
}

#[async_trait]
impl DataSourceConnector for FirecrawlConnector {
    fn name(&self) -> &str { "firecrawl" }
    fn display_name(&self) -> &str { "Firecrawl (Web Search)" }
    fn is_available(&self) -> bool { self.api_key.is_some() }

    async fn search(&self, query: &SearchQuery) -> Vec<SearchResult> {
        let api_key = match &self.api_key {
            Some(k) => k,
            None => return Vec::new(),
        };

        // Contract measured against the live endpoint 2026-10-31:
        //   POST https://api.firecrawl.dev/v1/search
        //   {"query": "...", "limit": N}
        //   -> {"success": true, "data": [{"url","title","description"}], "id": "..."}
        // `limit` is honored server-side and CJK queries round-trip correctly.
        let body = serde_json::json!({
            "query": query.keywords,
            "limit": query.limit,
        });

        let resp = match self.client
            .post("https://api.firecrawl.dev/v1/search")
            .header("Authorization", format!("Bearer {}", api_key))
            .header("Content-Type", "application/json")
            .json(&body)
            .send()
            .await
        {
            Ok(r) => r,
            Err(e) => {
                tracing::warn!(connector = self.name(), error = %e, "firecrawl search failed");
                return Vec::new();
            }
        };

        if !resp.status().is_success() {
            // A wrong or expired key lands here. Warn, do not propagate: the router
            // aggregates, and one dead source must not fail the whole search.
            tracing::warn!(
                connector = self.name(),
                status = %resp.status(),
                "firecrawl search returned a non-success status"
            );
            return Vec::new();
        }

        let json: serde_json::Value = match resp.json().await {
            Ok(v) => v,
            Err(e) => {
                tracing::warn!(connector = self.name(), error = %e, "firecrawl response was not JSON");
                return Vec::new();
            }
        };

        // `success:false` can still arrive with HTTP 200 on some deployments.
        if json.get("success").and_then(|v| v.as_bool()) == Some(false) {
            tracing::warn!(connector = self.name(), "firecrawl reported success=false");
            return Vec::new();
        }

        json.get("data")
            .and_then(|d| d.as_array())
            .map(|arr| {
                arr.iter()
                    .filter_map(|item| {
                        let title = item.get("title")?.as_str()?.to_string();
                        let url = item.get("url").and_then(|v| v.as_str()).map(String::from);
                        let summary = item
                            .get("description")
                            .and_then(|v| v.as_str())
                            .unwrap_or("")
                            .to_string();
                        Some(SearchResult {
                            title,
                            citation: None,
                            summary,
                            url,
                            source_name: self.name().to_string(),
                            source_level: "auxiliary_db".to_string(),
                            jurisdiction: query.jurisdiction.clone(),
                            date: None,
                            metadata: Some(item.clone()),
                        })
                    })
                    .collect()
            })
            .unwrap_or_default()
    }

    async fn health_check(&self) -> Result<(), SearchError> {
        let api_key = match &self.api_key {
            Some(k) => k,
            None => return Err(SearchError::Auth("FIRECRAWL_API_KEY is not set".into())),
        };

        // A one-result search is a real end-to-end probe: it exercises auth, the
        // request schema and the response schema, unlike a health endpoint that can
        // answer 200 while search is broken. Deliberately cheap (limit: 1).
        match self.client
            .post("https://api.firecrawl.dev/v1/search")
            .header("Authorization", format!("Bearer {}", api_key))
            .header("Content-Type", "application/json")
            .json(&serde_json::json!({ "query": "test", "limit": 1 }))
            .send()
            .await
        {
            Ok(resp) if resp.status().is_success() => Ok(()),
            Ok(resp) if resp.status().as_u16() == 401 || resp.status().as_u16() == 403 => {
                Err(SearchError::Auth(format!("HTTP {}", resp.status())))
            }
            Ok(resp) if resp.status().as_u16() == 429 => {
                Err(SearchError::RateLimited("HTTP 429".into()))
            }
            Ok(resp) => Err(SearchError::Unavailable(format!("HTTP {}", resp.status()))),
            Err(e) => Err(SearchError::Connection(e.to_string())),
        }
    }
}

```

- [ ] **Step 3: Register it in `default_router()`**

Add one line to the chain, immediately after the `OpenCorporatesConnector` entry and before the closing `}`:

```rust
        .with_connector(Arc::new(FirecrawlConnector::new(
            std::env::var("FIRECRAWL_API_KEY").ok(),
        )))
```

- [ ] **Step 4: Build and confirm no new warnings**

```powershell
cd D:\users\joeyzh\github-pr\pacgate-ai-pr
cargo build -p pacgate-search 2>&1 | Select-Object -Last 6
```

Expected: `Finished`, warning count no higher than Step 1's baseline.

- [ ] **Step 5: Prove both key states behave correctly**

This is the assertion that matters: an AIPC without a key must be unaffected.

```powershell
cd D:\users\joeyzh\github-pr\pacgate-ai-pr
Remove-Item Env:FIRECRAWL_API_KEY -ErrorAction SilentlyContinue
cargo test -p pacgate-search 2>&1 | Select-Object -Last 6
```

Then confirm the registry reports it unavailable without a key:

```powershell
@'
use pacgate_search::default_router;
fn main() {
    for (name, display, available) in default_router().list_connectors() {
        println!("{name}\t{available}\t{display}");
    }
}
'@ | Out-File -Encoding utf8 "$env:TEMP\listconn.rs"
```

Expected: the list contains a `firecrawl` row with `available=false`. (If the crate has no `examples/` harness, assert the same thing through the running API in Task 3 Step 5 instead — do not add a binary just for this.)

- [ ] **Step 6: Commit**

```powershell
git add pacgate-ai/crates/pacgate-search/src/lib.rs
git commit -m "feat(search): add a Firecrawl web-search connector"
```

Commit message body:

```text
Adds FirecrawlConnector to pacgate-search and registers it in default_router().

Each AIPC pastes its own FIRECRAWL_API_KEY into .env. Until then is_available()
is false and search() returns an empty Vec, so a machine with no key loses
nothing - which is the whole reason this is a Rust connector rather than a
deer-flow MCP server entry.

That choice is deliberate and measured. The pinned deer-flow image carries no
firecrawl-mcp binary, the MCP connector template has never had a firecrawl entry,
and the image has NO per-server isolation: get_mcp_tools() awaits one
client.get_tools() across all servers and returns [] on any exception. A firecrawl
MCP entry with an empty key would therefore remove every MCP tool, including
pacgate and officecli. As a connector the failure mode is one empty result set.

source_level is auxiliary_db, not authority_verified: a web page is not statutory
text, and the 4-level grading must not be inflated by a search hit.

Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>
```

---

### Task 2: Ship the key to the machine, and fix the CourtListener typo

**Files:**
- Modify: `deploy/client-bundle/.env.example` (near the other `*_API_KEY` entries, ~line 245)
- Modify: `deploy/client-bundle/compose.prod.yaml:138-142`
- Modify: `deploy/client-bundle/compose.bundle.yaml:114-118`
- Modify: `plans/013-credential-rotation.md:281`

**Interfaces:**
- Produces: `FIRECRAWL_API_KEY=` documented in `.env.example`; both compose comments list the correct `COURTLISTENER_API_KEY` name plus `FIRECRAWL_API_KEY`.

- [ ] **Step 1: Confirm the typo is real, not a second alias**

```powershell
cd D:\users\joeyzh\github-pr\pacgate-ai-pr
Select-String -Path pacgate-ai/crates/pacgate-search/src/lib.rs -Pattern 'COURTLISTENER_API_KEY|COURT_LISTENER_API_KEY'
```

Expected: only `COURTLISTENER_API_KEY` (lib.rs:540 and :1681). Nothing in Rust reads `COURT_LISTENER_API_KEY`, so that spelling is a dead name in the docs.

- [ ] **Step 2: Document the key in `.env.example`**

Insert after the last commented connector key (immediately after `#OPENCORPORATES_API_KEY=`):

```text
# Firecrawl — general web search and page extraction (https://firecrawl.dev).
#
# Each machine registers its OWN key: paste it here and restart pacgate-api.
# Until you do, the connector reports available=false and /api/search simply
# returns no web results - nothing else changes. There is no shared key and none
# is shipped in this repo; a tracked key would be a credential incident.
#
# Verify after setting it:  curl -s http://localhost:8089/api/search/health
#   -> the "firecrawl" row flips from available=false to true
#
#FIRECRAWL_API_KEY=
```

- [ ] **Step 3: Correct the connector-key comment in both compose files**

In `compose.prod.yaml` replace lines 138-142:

```yaml
    # Load ALL secrets from .env so pacgate-search's default_router() can read
    # the connector API keys (YUANDIAN_API_KEY, PKULAW_API_KEY, QCC_API_KEY,
    # FYOPEN_API_KEY, COURT_LISTENER_API_KEY, VAQUILL_API_KEY, ANSVAR_API_KEY,
    # OPENCORPORATES_API_KEY). Without these, every external legal connector
    # reports available=false and search returns only free sources.
```

with:

```yaml
    # Load ALL secrets from .env so pacgate-search's default_router() can read
    # the connector API keys (YUANDIAN_API_KEY, PKULAW_API_KEY, QCC_API_KEY,
    # FYOPEN_API_KEY, COURTLISTENER_API_KEY, VAQUILL_API_KEY, ANSVAR_API_KEY,
    # OPENCORPORATES_API_KEY, FIRECRAWL_API_KEY). Without these, every external
    # legal connector reports available=false and search returns only free sources.
    #
    # NOTE the CourtListener spelling: the code reads COURTLISTENER_API_KEY
    # (pacgate-search/src/lib.rs:540 and :1681). This comment and
    # plans/013 said COURT_LISTENER_API_KEY for three releases; an operator who
    # followed it got a connector that reported available=false forever, with no
    # error anywhere. Keep this list in lockstep with the code.
```

Apply the equivalent edit to `compose.bundle.yaml` (its block is at lines 114-118).

- [ ] **Step 4: Correct `plans/013-credential-rotation.md`**

Replace the row containing `COURT_LISTENER_API_KEY` with:

```markdown
| `COURTLISTENER_API_KEY` | `compose.prod.yaml` (passed to pacgate-search) |
```

- [ ] **Step 5: Prove the env var actually reaches the process**

```powershell
cd D:\users\joeyzh\github-pr\pacgate-ai-pr\deploy\client-bundle
docker compose -f compose.prod.yaml config 2>&1 | Select-String 'FIRECRAWL|COURTLISTENER'
```

Expected: with `FIRECRAWL_API_KEY` set in `.env`, the rendered config shows it under `pacgate-api`'s environment (via `env_file`). If it does not appear, `.env` is not the path being read — fix that before continuing.

- [ ] **Step 6: Commit**

```powershell
git add deploy/client-bundle/.env.example deploy/client-bundle/compose.prod.yaml `
        deploy/client-bundle/compose.bundle.yaml plans/013-credential-rotation.md
git commit -m "docs(config): document FIRECRAWL_API_KEY and fix the CourtListener key name"
```

---

### Task 3: Gate the connector registry

**Files:**
- Create: `scripts/test-connector-registry.ps1`
- Test: itself (red-checked in Step 3)

**Interfaces:**
- Consumes: `pacgate-ai/crates/pacgate-search/src/lib.rs`; both compose files; `.env.example`.
- Produces: exit 0/1/2.

- [ ] **Step 1: Write the gate**

```powershell
# Guard: every connector's key variable is named consistently, and a connector
# that ships must be registered.
#
# WHY THIS EXISTS (measured 2026-10-31)
#
# `pacgate-search` reads COURTLISTENER_API_KEY (lib.rs:540 and :1681). Both compose
# files and plans/013 told operators to set COURT_LISTENER_API_KEY instead. Nothing
# reads that name, so the connector reported available=false forever and the only
# symptom was "this source never returns results" - no error, no log line, nothing
# to search for. Measured baseline: 4 of 10 connectors available.
#
# A key name is a contract between the code and the operator's .env. This gate
# asserts the contract in one direction at least: every env var the CODE reads must
# be spelled identically wherever the docs tell a human to set it.
#
# WHAT IS ASSERTED
#   K1 every `std::env::var("<X>_API_KEY")` in pacgate-search is documented
#   K2 no doc names a key that the code does not read (the typo, both directions)
#   K3 FirecrawlConnector is registered in default_router()
#   K4 is_available() for a keyed connector is api_key.is_some(), so a missing key
#      cannot break a machine
#   K5 source_level is a value the SourceLevel enum actually derives
#
# Exit 2 means CANNOT CHECK.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'
Set-Location (Split-Path -Parent $PSScriptRoot)

$lib = 'pacgate-ai/crates/pacgate-search/src/lib.rs'
$composes = @('deploy/client-bundle/compose.prod.yaml',
              'deploy/client-bundle/compose.bundle.yaml')
$envExample = 'deploy/client-bundle/.env.example'
$core = 'pacgate-ai/crates/pacgate-core/src/lib.rs'

$script:passed = 0
$script:failed = 0
function Check($n, $ok, $d) {
    if ($ok) { $script:passed++; Write-Host "  [PASS] $n" -ForegroundColor Green }
    else { $script:failed++; Write-Host "  [FAIL] $n" -ForegroundColor Red; if ($d) { Write-Host "         $d" -ForegroundColor DarkGray } }
}

Write-Host '=== connector registry ===' -ForegroundColor Cyan
Check 'the search crate exists' (Test-Path $lib) $lib
if (-not (Test-Path $lib)) { Write-Host 'RESULT: cannot continue'; exit 1 }
$src = Get-Content $lib -Raw

# ── K1/K2: the key names the code reads, matched against what the docs say ──
$codeKeys = @()
foreach ($m in [regex]::Matches($src, 'std::env::var\("([A-Z0-9_]*_API_KEY)"\)')) {
    $codeKeys += $m.Groups[1].Value
}
$codeKeys = @($codeKeys | Sort-Object -Unique)
Write-Host ("         code reads: {0}" -f ($codeKeys -join ', ')) -ForegroundColor DarkGray
Check 'K1 the crate reads at least one API key' ($codeKeys.Count -gt 0)

$docText = ''
foreach ($f in @($composes + $envExample)) {
    if (Test-Path $f) { $docText += (Get-Content $f -Raw) }
}

foreach ($k in $codeKeys) {
    # A documented key may be commented out (`#FIRECRAWL_API_KEY=`), which is the
    # intended shape: the operator uncomments it. Match the name anywhere.
    Check "K1 $k is documented for the operator" ($docText -match [regex]::Escape($k)) `
          "nothing in the compose comments or .env.example names $k"
}

# K2 - the typo direction. Walk the API_KEY tokens mentioned in the CONNECTOR-KEY
# comment block and require the code to read each one. This is what catches
# COURT_LISTENER_API_KEY.
#
# SCOPE, or this assertion is a false-failure machine: the same files document
# OPENVIKING_API_KEY and OPENVIKING_ROOT_API_KEY, which deer-flow and the OpenViking
# container read and pacgate-search legitimately does not. Verified: an unscoped scan
# yields four "phantoms", two of which are correct-by-design. So the scan is limited
# to the lines that list connector keys, which is the only place the contract holds.
$connectorBlock = ''
foreach ($f in $composes) {
    if (-not (Test-Path $f)) { continue }
    $lines = Get-Content $f
    $inBlock = $false
    foreach ($line in $lines) {
        if ($line -match 'connector API keys') { $inBlock = $true; $connectorBlock += "$line`n"; continue }
        if ($inBlock) {
            if ($line -match '^\s*#') { $connectorBlock += "$line`n" }
            else { $inBlock = $false }
        }
    }
}

$docKeyTokens = @()
foreach ($m in [regex]::Matches($connectorBlock, '\b([A-Z][A-Z0-9_]*_API_KEY)\b')) {
    $docKeyTokens += $m.Groups[1].Value
}
$docKeyTokens = @($docKeyTokens | Sort-Object -Unique)
Check 'K2 the connector-key comment block was found' ($docKeyTokens.Count -ge 5) `
      "scanned $($docKeyTokens.Count) key(s); the 'connector API keys' comment may have been reworded"

$phantom = @($docKeyTokens | Where-Object { $codeKeys -notcontains $_ })
Check 'K2 no documented connector key is absent from the code' `
      ($phantom.Count -eq 0) `
      ("documented but never read: {0} - an operator following this gets a connector that is silently unavailable" -f ($phantom -join ', '))

# ── K3: registration ─────────────────────────────────────────────────────────
Check 'K3 FirecrawlConnector is defined' ($src -match 'pub struct FirecrawlConnector')
Check 'K3 FirecrawlConnector is registered in default_router' `
      ($src -match 'FirecrawlConnector::new\(\s*std::env::var\("FIRECRAWL_API_KEY"\)')

# Every connector struct must appear in the router, or it is dead code.
$connectors = @([regex]::Matches($src, 'pub struct ([A-Za-z0-9]+Connector)') | ForEach-Object { $_.Groups[1].Value })
$routerStart = $src.IndexOf('pub fn default_router')
$routerBody = if ($routerStart -ge 0) { $src.Substring($routerStart) } else { '' }
$unregistered = @()
foreach ($c in $connectors) {
    # Vaquill/EurLex-style names are registered through `X::new(`; match the type.
    if ($routerBody -notmatch [regex]::Escape($c)) { $unregistered += $c }
}
Check 'K3 every connector struct is registered in default_router' `
      ($unregistered.Count -eq 0) `
      ("defined but never registered: {0}" -f ($unregistered -join ', '))

# ── K4: a missing key cannot break a machine ────────────────────────────────
# The property that makes per-machine keys safe. A connector whose is_available()
# returns true without a key would call the API and fail at request time.
$firecrawlImpl = [regex]::Match($src, 'impl DataSourceConnector for FirecrawlConnector\s*\{(?s)(.*?)\n\}')
Check 'K4 the Firecrawl impl was found' $firecrawlImpl.Success
if ($firecrawlImpl.Success) {
    Check 'K4 Firecrawl is_available is api_key.is_some()' `
          ($firecrawlImpl.Groups[1].Value -match 'fn is_available\(&self\) -> bool \{ self\.api_key\.is_some\(\) \}')
    Check 'K4 Firecrawl search returns empty without a key' `
          ($firecrawlImpl.Groups[1].Value -match 'None => return Vec::new\(\)')

    # Only `search` must never propagate an error - the router aggregates and one
    # dead source must not fail the whole call. `health_check` is the opposite: it
    # MUST be able to report Auth/RateLimited/Unavailable, which is its whole job.
    # Verified against the proposed impl: an unscoped `notmatch 'return Err'` fails
    # on health_check's own (correct) error returns.
    $searchFn = [regex]::Match($firecrawlImpl.Groups[1].Value, 'async fn search\(&self, query: &SearchQuery\) -> Vec<SearchResult> \{(?s)(.*?)\n    \}')
    Check 'K4 the search function was isolated' $searchFn.Success
    if ($searchFn.Success) {
        Check 'K4 search never propagates an error' `
              ($searchFn.Groups[1].Value -notmatch 'return Err\(') `
              'search must log and return an empty Vec; only health_check reports errors'
    }
}

# ── K5: source_level discipline ──────────────────────────────────────────────
# A web hit is not statutory text. Assert the value is one the enum derives.
$levels = @()
if (Test-Path $core) {
    $coreSrc = Get-Content $core -Raw
    $enumBody = [regex]::Match($coreSrc, 'pub enum SourceLevel\s*\{(?s)(.*?)\n\}')
    if ($enumBody.Success) {
        foreach ($v in [regex]::Matches($enumBody.Groups[1].Value, '^\s*([A-Z][A-Za-z0-9]+),', 'Multiline')) {
            # AuthorityVerified -> authority_verified, AuxiliaryDB -> auxiliary_db.
            #
            # The naive `(?<!^)([A-Z]) -> _$1` is WRONG here: it splits the trailing
            # acronym in AuxiliaryDB into `auxiliary_d_b`, which then never matches
            # the code's `auxiliary_db` and produces a false failure. Verified:
            #   naive      AuxiliaryDB -> auxiliary_d_b   (wrong)
            #   corrected  AuxiliaryDB -> auxiliary_db    (right)
            # Rust's serde rename_all = "snake_case" does the same two-step split:
            # boundary after a lowercase/digit, then before a Capitalised word.
            $snake = $v.Groups[1].Value -creplace '([a-z0-9])([A-Z])', '$1_$2' -creplace '([A-Z])([A-Z][a-z])', '$1_$2'
            $levels += $snake.ToLower()
        }
    }
}
Check 'K5 the SourceLevel variants were parsed' ($levels.Count -ge 3) "parsed: $($levels -join ', ')"

$usedLevels = @([regex]::Matches($src, 'source_level:\s*"([a-z_]+)"\.to_string\(\)') | ForEach-Object { $_.Groups[1].Value })
$usedLevels = @($usedLevels | Sort-Object -Unique)
$badLevels = @($usedLevels | Where-Object { $levels -notcontains $_ })
Check 'K5 every source_level is a real SourceLevel variant' `
      ($badLevels.Count -eq 0) `
      "not in the enum: $($badLevels -join ', ') (enum: $($levels -join ', '))"

Write-Host ''
$colour = if ($script:failed -gt 0) { 'Red' } else { 'Green' }
Write-Host "RESULT: $($script:passed) passed, $($script:failed) failed" -ForegroundColor $colour
if ($script:failed -gt 0) { exit 1 } else { exit 0 }
```

- [ ] **Step 2: Run it and confirm it passes once Task 1 and Task 2 are in**

```powershell
cd D:\users\joeyzh\github-pr\pacgate-ai-pr
pwsh -NoProfile -File scripts/test-connector-registry.ps1; "exit=$LASTEXITCODE"
```

Expected: `exit=0`, with K1 listing at least `FIRECRAWL_API_KEY`, `YUANDIAN_API_KEY`, `PKULAW_API_KEY`, `QCC_API_KEY`, `FYOPEN_API_KEY`, `COURTLISTENER_API_KEY`, `VAQUILL_API_KEY`, `OPENCORPORATES_API_KEY`.

- [ ] **Step 3: Red-check both directions**

```powershell
# (a) reintroduce the typo in a compose comment
$f = 'deploy/client-bundle/compose.prod.yaml'
Copy-Item $f "$env:TEMP\cp.bak" -Force
$c = [System.IO.File]::ReadAllText((Resolve-Path $f))
$c = $c.Replace('COURTLISTENER_API_KEY', 'COURT_LISTENER_API_KEY')
[System.IO.File]::WriteAllText((Resolve-Path $f), $c, [System.Text.UTF8Encoding]::new($false))
pwsh -NoProfile -File scripts/test-connector-registry.ps1 2>&1 | Select-String 'FAIL|RESULT'
"exit=$LASTEXITCODE"
Copy-Item "$env:TEMP\cp.bak" $f -Force

# (b) remove the Firecrawl registration
$f2 = 'pacgate-ai/crates/pacgate-search/src/lib.rs'
Copy-Item $f2 "$env:TEMP\lib.bak" -Force
$c2 = [System.IO.File]::ReadAllText((Resolve-Path $f2))
$c2 = $c2 -replace '(?s)\s*\.with_connector\(Arc::new\(FirecrawlConnector::new\(\s*std::env::var\("FIRECRAWL_API_KEY"\)\.ok\(\),\s*\)\)\)', ''
[System.IO.File]::WriteAllText((Resolve-Path $f2), $c2, [System.Text.UTF8Encoding]::new($false))
pwsh -NoProfile -File scripts/test-connector-registry.ps1 2>&1 | Select-String 'FAIL|RESULT'
"exit=$LASTEXITCODE"
Copy-Item "$env:TEMP\lib.bak" $f2 -Force
```

Expected: (a) `K2` fails naming `COURT_LISTENER_API_KEY`; (b) `K3` fails naming `FirecrawlConnector`. Both `exit=1`.

- [ ] **Step 4: Register the gate and commit**

Add to `scripts/run-all-checks.ps1` immediately after `'scripts/test-model-roster-consistency.ps1'`:

```powershell
    # CONNECTOR REGISTRY, registered 2026-10-31. The code reads COURTLISTENER_API_KEY
    # while both compose files and plans/013 told operators to set
    # COURT_LISTENER_API_KEY. Nothing read that name, so the connector reported
    # available=false forever and the only symptom was a source that never returned
    # results. This asserts every key the code reads is documented, and that no
    # documented key is one the code ignores - both directions of the same contract.
    'scripts/test-connector-registry.ps1'
```

```powershell
git add scripts/test-connector-registry.ps1 scripts/run-all-checks.ps1
git commit -m "test(search): gate connector key names against the code"
```

---

### Task 4: Register the legal journey, the real e2e gate

**Files:**
- Modify: `scripts/run-all-checks.ps1`

**Interfaces:**
- Consumes: `scripts/test-legal-journey.ps1` (already exists, passes 19/19).
- Produces: an entry in the live-stack gate group.

- [ ] **Step 1: Confirm it is genuinely absent and genuinely passing**

```powershell
cd D:\users\joeyzh\github-pr\pacgate-ai-pr
Select-String -Path scripts/run-all-checks.ps1 -Pattern 'legal-journey'
pwsh -NoProfile -File scripts/test-legal-journey.ps1 2>&1 | Select-String 'RESULT|connector health'
```

Expected: no match in `run-all-checks.ps1`, and `RESULT: full legal journey PASSED, all lanes verified.` with `connector health: 4 of 10 available`.

- [ ] **Step 2: Register it in the live-stack group**

Find the live-stack gate block (the `$liveGates`-style array containing `scripts/test-empty-extraction-gate.ps1`). Add:

```powershell
    # LEGAL JOURNEY, registered 2026-10-31. This is the closest thing to a real
    # acceptance test in the repo - matter -> upload -> extract -> sanitize ->
    # review gate -> KB search -> external search -> connector health -> deer-flow
    # auth -> qm -> OpenViking recall - and it was never in this list. It passed
    # 19/19 while unregistered, which means a release could have shipped with the
    # whole journey broken and the suite would have said "all green".
    #
    # It is a LIVE gate: exit 2 (CANNOT CHECK) when the stack or credentials are
    # absent, exit 1 only on a real broken step. It also names the first failing
    # step rather than collecting them, because after step N fails the rest is
    # noise, not evidence.
    'scripts/test-legal-journey.ps1'
```

- [ ] **Step 3: Prove the runner actually executes it now**

```powershell
cd D:\users\joeyzh\github-pr\pacgate-ai-pr
pwsh -NoProfile -File scripts/run-all-checks.ps1 -SkipOcrPull 2>&1 | Select-String 'legal-journey|GATE\(S\) FAILED'
```

Expected: a `PASS scripts/test-legal-journey.ps1` line. If it appears in the failure list, read the step it names — that is a real defect, not a gate problem.

- [ ] **Step 4: Commit**

```powershell
git add scripts/run-all-checks.ps1
git commit -m "test(e2e): register the legal journey in the gate suite"
```

---

### Task 5: An agent→MCP end-to-end gate

**Files:**
- Create: `scripts/test-agent-mcp-e2e.ps1`
- Modify: `scripts/run-all-checks.ps1`

**Interfaces:**
- Consumes: `deer-flow` on `:8001` (internal) or the nginx ingress; the pacgate-mcp tool surface (`test-mcp-tool-surface.ps1` derives the expected names from `deploy/pacgate-mcp/server.py`).
- Produces: exit 0/1/2. Asserts an agent run produced a tool call to a real MCP tool.

Context: `smoke-full-stack.ps1:188` states this gap verbatim — *"agent->MCP invocation NOT exercised: it needs a deer-flow session, and there is no committed agent-run E2E. Do not read this lane as fully verified."* This task closes it.

- [ ] **Step 1: Find the exact request shape a deer-flow run needs**

```powershell
cd D:\users\joeyzh\github-pr\pacgate-ai-pr
Select-String -Path scripts/test-model-picker-e2e.ps1 -Pattern 'runs|threads|headers|context|messages' | ForEach-Object { "$($_.LineNumber): $($_.Line.Trim())" } | Select-Object -First 18
```

Expected: the shape this gate must copy verbatim. Three details in it are not
guessable and are the reason a first draft of this gate would fail on a healthy
stack:

- deer-flow auth is a **cookie session** (`-WebSession`), not a bearer token, and
  `POST /api/threads` and `runs/wait` both require an **`X-CSRF-Token`** header read
  from the `csrf_token` cookie;
- the login body uses **`username`**, not `email`;
- an input message uses **`role = 'user'`**, not `type = 'human'`;
- and the run payload puts `messages` at the **top level** (`{messages, thread_data,
  title}`), while `/state` nests them under `.values` — accept both.

- [ ] **Step 2: Write the gate**

```powershell
# Guard: an agent run must actually INVOKE an MCP tool, end to end.
#
# WHY THIS EXISTS (measured 2026-10-31)
#
#
# smoke-full-stack.ps1:188 says so itself: "agent->MCP invocation NOT exercised: it
# needs a deer-flow session, and there is no committed agent-run E2E. Do not read
# this lane as fully verified."
#
# Everything below that gap was green while the gap existed:
#   test-mcp-tool-surface.ps1  proves pacgate-mcp ADVERTISES its tools. It never
#                              starts an agent, so a tool that advertises but
#                              cannot be CALLED passes.
#   test-mcp-argument-paths.ps1 proves MCP ARGUMENTS get path-translated. It drives
#                              a synthetic ToolNode, not the real graph.
#   test-document-generation-e2e.ps1 runs a workflow through pacgate-api, which is
#                              a different path from the agent's tool loop.
#
# The measured cost of that gap: a prompt change introduced a single unescaped brace
# into SYSTEM_PROMPT_TEMPLATE and EVERY agent run died at construction with
# KeyError: '"command"'. The full suite was green. Only a live chat run caught it.
# So this gate's real job is to make "the agent can still start and call a tool" an
# assertion rather than something a human happens to notice.
#
# WHERE THIS STOPPED BEING ABLE TO HELP: a 2026-10-30 defect where the template
# crashed on EVERY run - this gate would have caught it, and that is exactly why it
# exists.
#
# WHAT IS ASSERTED
#   E1 deer-flow is healthy and the pacgate MCP bridge is reachable from it
#   E2 an agent run completes rather than erroring at construction (the
#      KeyError-class defect)
#   E3 the run's tool calls include at least one REAL MCP tool name from the
#      advertised surface - not merely that it produced text
#   E4 a tool result came back (the call did not fail after being issued)
#
# Exit 2 means CANNOT CHECK (stack down / no credentials) and is never a pass.
[CmdletBinding()]
param(
    [string]$BaseUrl     = 'http://localhost:8089/pacgate',
    [string]$DeerFlowUrl = 'http://localhost:8001',
    [int]$TimeoutSec     = 240,
    [string]$ServerFile  = 'deploy/pacgate-mcp/server.py'
)

$ErrorActionPreference = 'Continue'
Set-Location (Split-Path -Parent $PSScriptRoot)

$script:passed = 0
$script:failed = 0
function Check($n, $ok, $d) {
    if ($ok) { $script:passed++; Write-Host "  [PASS] $n" -ForegroundColor Green }
    else { $script:failed++; Write-Host "  [FAIL] $n" -ForegroundColor Red; if ($d) { Write-Host "         $d" -ForegroundColor DarkGray } }
}
function CannotCheck($why) {
    Write-Host "[SKIP] CANNOT CHECK: $why" -ForegroundColor Yellow
    Write-Host "RESULT: $($script:passed) passed, $($script:failed) failed (CANNOT CHECK)" -ForegroundColor Yellow
    exit 2
}

Write-Host '=== agent -> MCP end to end ===' -ForegroundColor Cyan

# ── E1 ───────────────────────────────────────────────────────────────────────
try {
    $h = Invoke-RestMethod -Uri "$DeerFlowUrl/health" -TimeoutSec 15
} catch {
    CannotCheck "deer-flow /health is unreachable at $DeerFlowUrl ($($_.Exception.Message))"
}
Check 'E1 deer-flow answers /health' ($null -ne $h)

# The expected tool names come from the SERVER SOURCE, so adding a tool needs no
# edit here while removing one still fails - the same derivation
# test-mcp-tool-surface.ps1 uses.
if (-not (Test-Path $ServerFile)) { CannotCheck "server source not found: $ServerFile" }
$mcpTools = @([regex]::Matches((Get-Content $ServerFile -Raw),
    '(?m)^(?:async )?def\s+(pacgate_[a-z0-9_]+)\(') | ForEach-Object { $_.Groups[1].Value })
$mcpTools = @($mcpTools | Sort-Object -Unique)
Check 'E1 the pacgate MCP tool names were derived from source' `
      ($mcpTools.Count -ge 5) `
      "derived $($mcpTools.Count) tool name(s)"

# ── credentials ──────────────────────────────────────────────────────────────
# A deer-flow run needs the deer-flow admin credential, which differs from the
# pacgate-api principal. Resolve exactly as test-model-picker-e2e.ps1 does.
function Resolve-DeerFlowPassword {
    if ($env:PACGATE_DEERFLOW_PASSWORD) { return $env:PACGATE_DEERFLOW_PASSWORD }
    $f = Join-Path (Split-Path -Parent $PSScriptRoot) 'deploy/client-bundle/.deer-flow-credentials'
    if (Test-Path $f) {
        $line = (Get-Content $f | Where-Object { $_ -match '^\s*password\s*=' } | Select-Object -First 1)
        if ($line) { return ($line -split '=', 2)[1].Trim() }
    }
    return $null
}
$dfPassword = Resolve-DeerFlowPassword
if (-not $dfPassword) { CannotCheck 'no deer-flow credential (set PACGATE_DEERFLOW_PASSWORD or deploy/client-bundle/.deer-flow-credentials)' }

# deer-flow auth is a COOKIE SESSION plus a CSRF header, not a bearer token.
# Copying test-model-picker-e2e.ps1 exactly: it passes, and every one of these
# details (username=, WebSession, X-CSRF-Token from the csrf_token cookie) is
# load-bearing.
$session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
function Get-Csrf {
    ($session.Cookies.GetCookies($DeerFlowUrl) | Where-Object { $_.Name -eq 'csrf_token' } | Select-Object -First 1).Value
}
try {
    $null = Invoke-WebRequest -Uri "$DeerFlowUrl/api/v1/auth/login/local" -Method Post `
        -Body @{ username = 'admin@pacgate-law.com'; password = $dfPassword } `
        -WebSession $session -UseBasicParsing -TimeoutSec 25
} catch {
    CannotCheck "deer-flow local login failed ($($_.Exception.Message))"
}
Check 'E1 authenticated to deer-flow' ($null -ne (Get-Csrf))

# ── E2: an agent run completes ────────────────────────────────────────────────
$t = (Invoke-WebRequest -Uri "$DeerFlowUrl/api/threads" -Method Post -Body '{}' `
        -ContentType 'application/json' -Headers @{ 'X-CSRF-Token' = (Get-Csrf) } `
        -WebSession $session -UseBasicParsing -TimeoutSec 30).Content | ConvertFrom-Json
$threadId = $t.thread_id
if (-not $threadId) { CannotCheck 'POST /api/threads returned no thread_id' }

# The prompt is chosen to REQUIRE a tool: "list the connectors" has no answer the
# model can produce from its own weights, so a reply without a tool call means the
# tool loop is not working - which is precisely the thing under test.
# NOTE `role = 'user'`: an input message uses `role`, not `type` (see
# test-model-picker-e2e.ps1:189).
$body = @{
    input   = @{ messages = @(@{ role = 'user'; content = 'Call pacgate_list_connectors and tell me which connectors exist. You must call the tool; do not answer from memory.' }) }
    context = @{ thread_id = $threadId; recursion_limit = 1000 }
} | ConvertTo-Json -Depth 12 -Compress

try {
    $r = Invoke-WebRequest -Uri "$DeerFlowUrl/api/threads/$threadId/runs/wait" -Method Post -Body $body `
        -ContentType 'application/json' -Headers @{ 'X-CSRF-Token' = (Get-Csrf) } `
        -WebSession $session -UseBasicParsing -TimeoutSec $TimeoutSec
} catch {
    Check 'E2 an agent run completes (the KeyError-class defect)' $false `
          "the run failed: $($_.Exception.Message)"
    Write-Host ''
    $colour = if ($script:failed -gt 0) { 'Red' } else { 'Green' }
    Write-Host "RESULT: $($script:passed) passed, $($script:failed) failed" -ForegroundColor $colour
    exit 1
}
Check 'E2 an agent run completes (the KeyError-class defect)' ($r.StatusCode -eq 200) "got HTTP $($r.StatusCode)"

# ── E3/E4: it actually called an MCP tool ─────────────────────────────────────
# Accept both payload shapes: `messages` at the top level of a runs/wait response,
# or nested under `.values` from /state. Assuming one is how the sibling gate first
# reported a false FAIL.
$json = $null
try { $json = $r.Content | ConvertFrom-Json } catch { }
$msgs = @()
if ($json) {
    if ($json.messages) { $msgs = @($json.messages) }
    elseif ($json.values -and $json.values.messages) { $msgs = @($json.values.messages) }
}

# A text reply alone does NOT count - that is the exact state a broken tool loop
# produces. Look for a tool-call record whose name is one of the advertised tools.
$serialized = ($msgs | ConvertTo-Json -Depth 20)
if (-not $serialized) { $serialized = [string]$r.Content }
$called = @()
foreach ($tn in $mcpTools) {
    if ($serialized -match [regex]::Escape($tn)) { $called += $tn }
}
$called = @($called | Sort-Object -Unique)

Check 'E3 the run invoked at least one real MCP tool' `
      ($called.Count -ge 1) `
      "none of the advertised tool names appear in the run payload; the agent replied without calling a tool"

if ($called.Count -ge 1) {
    Write-Host ("         called: {0}" -f ($called -join ', ')) -ForegroundColor DarkGray
}
Check 'E4 a tool result came back (the call did not fail after issuance)' `
      ($serialized -match 'tool_call_id|tool_calls|ToolMessage|tool_result') `
      'a tool was named but no tool-call record is present - the call was issued and failed'

Write-Host ''
$colour = if ($script:failed -gt 0) { 'Red' } else { 'Green' }
Write-Host "RESULT: $($script:passed) passed, $($script:failed) failed" -ForegroundColor $colour
if ($script:failed -gt 0) { exit 1 } else { exit 0 }
```

- [ ] **Step 3: Run it**

```powershell
cd D:\users\joeyzh\github-pr\pacgate-ai-pr
pwsh -NoProfile -File scripts/test-agent-mcp-e2e.ps1; "exit=$LASTEXITCODE"
```

Expected: `E3 the run invoked at least one real MCP tool` PASS. If it reports `exit=2`, the credential path is missing — fix the credential resolution rather than weakening the gate.

- [ ] **Step 4: Red-check it against the known outage class**

Prove it fails the way it is supposed to, by reintroducing a broken prompt on the live container:

```powershell
cd D:\users\joeyzh\github-pr\pacgate-ai-pr
# Break the mounted prompt the same way the real defect did: one unescaped brace.
$f = 'deploy/client-bundle/patches/deer-flow-prompt.py'
Copy-Item $f "$env:TEMP\pr.bak" -Force
$c = [System.IO.File]::ReadAllText((Resolve-Path $f))
$c = $c.Replace('        [[{{"command":"add"', '        [{"command":"add"')
[System.IO.File]::WriteAllText((Resolve-Path $f), $c, [System.Text.UTF8Encoding]::new($false))
docker restart deer-flow | Out-Null
Start-Sleep -Seconds 30
pwsh -NoProfile -File scripts/test-agent-mcp-e2e.ps1 2>&1 | Select-String 'FAIL|RESULT'
"exit=$LASTEXITCODE"
Copy-Item "$env:TEMP\pr.bak" $f -Force
docker restart deer-flow | Out-Null
```

Expected: `E2` fails with the run error (`KeyError: '"command"'` class), `exit=1`. Then after the restore and restart, the gate passes again.

- [ ] **Step 5: Register and commit**

Add to the live-stack gate group in `scripts/run-all-checks.ps1`:

```powershell
    # AGENT -> MCP END TO END, registered 2026-10-31. smoke-full-stack.ps1 said so
    # itself: "agent->MCP invocation NOT exercised ... there is no committed
    # agent-run E2E". Every other MCP gate proves advertisement or argument
    # translation; none proves the agent can start and CALL. The cost of that gap
    # was measured: one unescaped brace in the prompt made EVERY run die at
    # construction and the full suite stayed green.
    'scripts/test-agent-mcp-e2e.ps1'
```

```powershell
git add scripts/test-agent-mcp-e2e.ps1 scripts/run-all-checks.ps1
git commit -m "test(e2e): assert an agent run actually invokes an MCP tool"
```

---

### Task 6: Record the decisions and verify the whole thing

**Files:**
- Modify: `deploy/AIPC-UPDATE-GAP-ANALYSIS.md`

- [ ] **Step 1: Append the record**

```markdown
## Firecrawl and e2e coverage (2026-10-31)

### Firecrawl is a connector, not an MCP server - and that is a safety decision

Each AIPC pastes its own `FIRECRAWL_API_KEY` into `.env`; until then the connector
reports `available=false` and /api/search simply returns no web results.

The alternative - a `firecrawl` entry in `deer-flow-extensions-config.json` - was
rejected on measurement, not preference:

- the pinned deer-flow image carries no `firecrawl-mcp` binary (only `npx`), so the
  entry would need a runtime install on an offline machine;
- the MCP template has never contained a firecrawl entry;
- and the image has NO per-server isolation. `get_mcp_tools()` awaits one
  `client.get_tools()` for all servers and its `except` handler logs and `return []`.
  A firecrawl entry with an empty key would not degrade web search, it would remove
  every MCP tool including `pacgate` and `officecli`.

As a `DataSourceConnector` the failure mode is one empty result set. Verified
contract: `POST https://api.firecrawl.dev/v1/search` with
`{"query","limit"}` returns `{"success",data:[{"url","title","description"}]}`;
`limit` is honored and CJK queries round-trip.

`source_level` is `auxiliary_db`. A web page is not statutory text and must not be
graded `authority_verified`.

### A connector key name was wrong for three releases

The code reads `COURTLISTENER_API_KEY`. Both compose files and `plans/013` said
`COURT_LISTENER_API_KEY`. Nothing reads the second spelling, so an operator who
followed the docs got a connector that reported `available=false` forever with no
error, no log line, and no symptom beyond "this source never returns results".
`test-connector-registry.ps1` now asserts the contract in both directions.

### Two coverage gaps closed

- The **legal journey** (matter -> upload -> extract -> sanitize -> review gate ->
  KB search -> external search -> connector health -> deer-flow auth -> qm ->
  OpenViking recall) passed 19/19 while being absent from `run-all-checks.ps1`. A
  release could have shipped with the entire journey broken and the suite would
  have said "all green".
- **No agent->MCP E2E existed.** `smoke-full-stack.ps1:188` said so in the file. The
  measured cost: an unescaped brace in the prompt made every agent run die at
  construction and the full suite stayed green. `test-agent-mcp-e2e.ps1` now starts a
  run that cannot be answered without a tool call and asserts a real MCP tool name
  appears in the payload, with a result.

### A second false "implemented" claim, and the `ansvar` key nobody reads

The registry has 27 catalog entries; 11 were marked `implemented: true` while only 10
have a `DataSourceConnector` impl. `ansvar` was the mismatch, and `ANSVAR_API_KEY` is
documented in `.env.example`, both compose files and the archived handoff for a
connector that cannot be called. `GET /api/search/registry` returned the claim while
`GET /api/search/connectors` omitted the name, so the two endpoints disagreed.
Task 7 flips the flag; it is inert on a pinned client until a new image is built.

### Baseline for the next release

Connector availability, measured: **4 of 11** before this work (`courtlistener`,
`sec_edgar`, `gleif`, `eur-lex`). Firecrawl is registered but unavailable without a
key. Adding `FIRECRAWL_API_KEY` makes it **5 available**. The remaining six
(`yuandian`, `pkulaw`, `qcc`, `fyopen`, `vaquill`, `opencorporates` — the last needs a
key too) require subscriptions only the client can provide. Re-measure with:

```powershell
pwsh -NoProfile -File scripts/test-legal-journey.ps1 2>&1 | Select-String 'connector health'
```

and correct this paragraph if the number differs — do not leave a claim you did not
measure.
```

- [ ] **Step 2: Verify the documented baseline against reality**

```powershell
cd D:\users\joeyzh\github-pr\pacgate-ai-pr
pwsh -NoProfile -File scripts/test-legal-journey.ps1 2>&1 | Select-String 'connector health'
```

Expected: `connector health: N of 11 available`. Correct the number in the doc if it differs — do not leave a claim you did not measure.

- [ ] **Step 3: Run the gates this plan touched**

```powershell
cd D:\users\joeyzh\github-pr\pacgate-ai-pr
foreach ($g in @('test-connector-registry','test-legal-journey','test-agent-mcp-e2e','test-mcp-tool-surface','test-mcp-argument-paths')) {
    pwsh -NoProfile -File "scripts/$g.ps1" *> "$env:TEMP\$g.log"
    "$g -> exit=$LASTEXITCODE"
}
```

Expected: `exit=0` for all five, or `exit=2` where the environment genuinely cannot check.

- [ ] **Step 4: Run the Rust workspace tests**

```powershell
cd D:\users\joeyzh\github-pr\pacgate-ai-pr
pwsh -NoProfile -File scripts/test-rust-workspace.ps1 2>&1 | Select-Object -Last 5; "exit=$LASTEXITCODE"
```

Expected: pass. A new connector must not break the existing workspace.

- [ ] **Step 5: Commit**

```powershell
git add deploy/AIPC-UPDATE-GAP-ANALYSIS.md
git commit -m "docs(aipc): record the Firecrawl connector decision and the closed e2e gaps"
```

---

### Task 7: Fix the two false "implemented" claims in the connector registry

**Files:**
- Modify: `pacgate-ai/crates/pacgate-search/src/lib.rs` (the `ConnectorMetadata` entry for `ansvar`, inside `ConnectorRegistry`)

**Interfaces:**
- Consumes: `ConnectorMetadata { implemented: bool, env_var: Option<String>, ... }`.
- Produces: `GET /api/search/registry` no longer claims an implementation that does not exist.

Context, measured 2026-10-31: the registry has **27 catalog entries**, of which **11 are marked `implemented: true`** — but only **10 have a `DataSourceConnector` impl**. The eleventh is `ansvar`:

```rust
name: "ansvar",
env_var: Some("ANSVAR_API_KEY".into()),
implemented: true,          // <- nothing implements this
```

`ANSVAR_API_KEY` is consequently documented in `.env.example:251`, both compose files, and the archived handoff — for a connector that cannot be called. This is user-visible: `GET /api/search/registry` returns the claim, and `GET /api/search/connectors` omits the name, so the two endpoints disagree.

- [ ] **Step 1: Confirm the disagreement from the running stack**

```powershell
cd D:\users\joeyzh\github-pr\pacgate-ai-pr
$env:HTTP_PROXY=''; $env:HTTPS_PROXY=''; $env:NO_PROXY='*'
# registry claims (this endpoint needs no auth)
curl.exe -s --max-time 20 http://localhost:8089/pacgate/api/search/registry 2>&1 |
  python -c "import json,sys; d=json.load(sys.stdin); imp=[e['name'] for e in d if e.get('implemented')]; print('implemented claims:', len(imp)); print(', '.join(imp))"
```

Expected: 11 names including `ansvar`. Compare against the actual `list_connectors` output (10 names) from the legal journey's `connector health` line.

- [ ] **Step 2: Flip the flag and record why**

In the `ConnectorMetadata` entry whose `name` is `"ansvar"`, change:

```rust
                implemented: true,
```

to:

```rust
                // Measured 2026-10-31: this flag was true with no
                // `impl DataSourceConnector for AnsvarConnector` anywhere in the crate,
                // so GET /api/search/registry claimed an implementation that could not
                // be called, while GET /api/search/connectors omitted the name. The two
                // endpoints disagreed about the same connector.
                //
                // Ansvar is a self-hosted MCP server (github.com/Ansvar-Systems/
                // EU_compliance_MCP) and is NOT deployed in this stack, so there is
                // nothing to point a client at. Catalogued and not implemented is the
                // honest state; flip this back only together with a real impl.
                implemented: false,
```

- [ ] **Step 3: Rebuild and prove the two endpoints now agree**

```powershell
cd D:\users\joeyzh\github-pr\pacgate-ai-pr
cargo build -p pacgate-api 2>&1 | Select-Object -Last 3
```

Deploy on a machine that builds locally, then:

```powershell
$env:HTTP_PROXY=''; $env:HTTPS_PROXY=''; $env:NO_PROXY='*'
curl.exe -s --max-time 20 http://localhost:8089/pacgate/api/search/registry 2>&1 |
  python -c "import json,sys; d=json.load(sys.stdin); imp=[e['name'] for e in d if e.get('implemented')]; print('implemented claims:', len(imp)); print(', '.join(imp))"
```

Expected: **10** names, and no `ansvar`. Note: the shipped `0.2.8` image still carries the old flag until a new image is built — this change is inert on a pinned client until then, which is why it is recorded in the gap analysis rather than presented as live.

- [ ] **Step 4: Commit**

```powershell
git add pacgate-ai/crates/pacgate-search/src/lib.rs
git commit -m "fix(search): stop claiming an Ansvar connector that was never implemented"
```

---

### Task 8: Prove the per-machine key path on a clean machine

**Files:** none. This is the test that decides whether the feature actually works for a client.

- [ ] **Step 1: Prove a machine with NO key is unaffected**

```powershell
cd D:\users\joeyzh\github-pr\pacgate-ai-pr\deploy\client-bundle
Select-String -Path .env -Pattern '^FIRECRAWL_API_KEY=' -ErrorAction SilentlyContinue
# If a key is present, temporarily comment it out, then:
docker compose -f compose.prod.yaml up -d --force-recreate --no-deps pacgate-api
Start-Sleep -Seconds 25
```

Then confirm the connector is present but unavailable, and that search still works:

```powershell
$env:HTTP_PROXY=''; $env:HTTPS_PROXY=''; $env:NO_PROXY='*'
pwsh -NoProfile -File ../../scripts/test-legal-journey.ps1 2>&1 | Select-String 'connector health|external search'
```

Expected: `connector health: N of 11 available` **without** `firecrawl` in the available list, and `external search returned N result(s)` with N > 0 — the free sources still answer. This is the property that matters for a client machine: no key, no breakage.

- [ ] **Step 2: Prove a machine WITH a key gains the source**

```powershell
# add YOUR key to .env (never commit it), then:
docker compose -f compose.prod.yaml up -d --force-recreate --no-deps pacgate-api
Start-Sleep -Seconds 25
$env:HTTP_PROXY=''; $env:HTTPS_PROXY=''; $env:NO_PROXY='*'
pwsh -NoProfile -File ../../scripts/test-legal-journey.ps1 2>&1 | Select-String 'connector health'
```

Expected: `firecrawl` appears in the available list and the count increases by exactly 1. If it does not move, the key is not reaching the process — check `docker compose config` and that `.env` has no BOM (both `docker` and the `.env` parser reject one).

- [ ] **Step 3: Confirm no key can leak into the repo**

```powershell
cd D:\users\joeyzh\github-pr\pacgate-ai-pr
git status --short
git check-ignore -v deploy/client-bundle/.env
pwsh -NoProfile -File scripts/detect-literal-credentials.ps1 2>&1 | Select-Object -Last 2
```

Expected: `.env` is ignored, `git status` shows no `.env`, and the detector reports `CLEAN`.

- [ ] **Step 4: Restore whichever state you found**

If Step 1 commented the key out, restore it (or leave it commented if the machine genuinely has none) and recreate `pacgate-api` so the running stack matches `.env`.

- [ ] **Step 5: Final full suite**

```powershell
cd D:\users\joeyzh\github-pr\pacgate-ai-pr
pwsh -NoProfile -File scripts/run-all-checks.ps1 -SkipOcrPull 2>&1 | Select-Object -Last 14
```

Expected: no NEW failures. Two are known and pre-existing/environmental:
`verify-delivery-state.ps1` needs the dead local proxy cleared
(`$env:HTTP_PROXY=''; $env:HTTPS_PROXY=''; $env:NO_PROXY='*'`), and it passes with
that cleared.
