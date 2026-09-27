use axum::{
    extract::{Extension, Path, State},
    http::HeaderMap,
    Json,
};
use pacgate_auth::Claims;
use pacgate_core::{DocumentStore, Matter, MatterId, TenantId, UserId};
use pacgate_tenant::TenantError;
use serde::Deserialize;

use crate::{error::ApiError, state::AppState};

#[derive(Debug, Deserialize)]
pub struct CreateMatterRequest {
    pub name:        String,
    pub description: Option<String>,
    pub external_key: Option<String>,
    pub persona_id:  Option<String>,
}

/// Parse tenant_id and user_id from JWT Claims.
fn claims_to_ids(claims: &Claims) -> Result<(TenantId, UserId), ApiError> {
    let tenant_id: TenantId = claims
        .tenant_id
        .parse()
        .map_err(|e| ApiError::bad_request(format!("invalid tenant_id in token: {e}")))?;
    let user_id: UserId = claims
        .sub
        .parse()
        .map_err(|e| ApiError::bad_request(format!("invalid user_id in token: {e}")))?;
    Ok((tenant_id, user_id))
}

fn matter_memory_path(
    data_dir: &std::path::Path,
    tenant_id: &TenantId,
    matter_id: &MatterId,
) -> std::path::PathBuf {
    pacgate_tenant::matter_dir(data_dir, tenant_id, matter_id).join("memory.json")
}

/// Write `bytes` to `path` atomically: a reader sees either the old file or the
/// new one, never a partial one.
///
/// `std::fs::write` truncates the target before writing, so a crash, an out-of-
/// memory kill, or a full disk mid-write leaves a truncated or empty file. That is
/// unrecoverable here: `get_matter_memory` cannot parse it, there is no backup,
/// and `mem_limit: 4g` plus a restart policy makes an OOM kill during a write a
/// live path rather than a theoretical one.
///
/// Temp file in the SAME directory, so the rename is same-filesystem and
/// therefore atomic.
///
/// `sync_all` before the rename is deliberate: without it the rename can be
/// durable while the contents are not, so a power loss yields a valid-looking
/// file of the wrong length. One flush per memory write is affordable here.
fn write_atomic(path: &std::path::Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write;

    let dir = path.parent().unwrap_or_else(|| std::path::Path::new("."));
    // Include the pid so two processes writing the same matter cannot collide on
    // the temp name.
    let tmp = dir.join(format!(".memory.json.tmp-{}", std::process::id()));

    {
        let mut f = std::fs::File::create(&tmp)?;
        f.write_all(bytes)?;
        f.sync_all()?;
    }

    match std::fs::rename(&tmp, path) {
        Ok(()) => Ok(()),
        Err(e) => {
            // Do not leave a stray temp file behind on failure.
            let _ = std::fs::remove_file(&tmp);
            Err(e)
        }
    }
}

fn default_matter_memory() -> serde_json::Value {
    serde_json::json!({
        "version": "2.0",
        "revision": 0,
        "lastUpdated": "",
        "user": {},
        "history": {},
        "facts": []
    })
}

/// Read the `revision` counter out of a matter-memory object.
///
/// Absent, negative or non-numeric all read as 0. That is the fail-closed
/// choice for a *missing* value, and it matches a brand-new matter whose file
/// has never been written.
fn memory_revision(memory: &serde_json::Value) -> u64 {
    memory
        .get("revision")
        .and_then(|v| v.as_u64())
        .unwrap_or(0)
}

/// The revision a successful write should store.
///
/// Server-owned on purpose: the caller's `If-Match` is a claim about what it
/// *read*, never a value to store. Trusting a body field here would let a stale
/// client reset the counter, which is the failure this whole mechanism exists to
/// prevent.
///
/// Always strictly greater than what `memory_revision` read, including when the
/// stored value is absent or corrupt - a counter that can fail to advance is a
/// guard that can never reject.
fn next_revision(current: &serde_json::Value) -> u64 {
    memory_revision(current).saturating_add(1)
}

/// Parse the `If-Match` header into an expected revision.
///
/// `Ok(None)` means the header was absent: the caller opted out of the guard and
/// the write proceeds unconditionally. That is the deliberate decision recorded
/// on `check_revision` - requiring the header would break a caller that does not
/// send one.
///
/// A present-but-unparseable value is a **400**, never `Ok(None)`. Silently
/// ignoring a header the caller believes is protecting them is the worst possible
/// outcome: they think they are guarded while writing unconditionally.
fn if_match_revision(headers: &HeaderMap) -> Result<Option<u64>, ApiError> {
    let Some(raw) = headers.get(axum::http::header::IF_MATCH) else {
        return Ok(None);
    };
    let text = raw
        .to_str()
        .map_err(|_| ApiError::bad_request("If-Match header is not valid ASCII"))?;
    // Tolerate the quoted form (`If-Match: "7"`), which is legal HTTP.
    let text = text.trim().trim_matches('"');
    let value: u64 = text.parse().map_err(|_| {
        ApiError::bad_request(format!(
            "If-Match must be a revision number, got {text:?}"
        ))
    })?;
    Ok(Some(value))
}

/// Enforce optimistic concurrency on a memory write.
///
/// `expected` is the revision the caller believes it is updating, or `None`
/// for an unconditional write.
///
/// Two deliberate decisions, both recorded because they are judgement calls
/// rather than derivable:
///
/// 1. `None` is ALLOWED. Requiring `If-Match` would break the existing
///    deer-flow adapter, which does not send one. The fix for the silent-loss
///    defect must not itself break a working integration, so the stricter
///    behaviour is opt-in per caller. Task 4 makes the adapter opt in.
/// 2. A claim that matches neither the current revision nor the past is a
///    conflict, not a fast-forward. A caller claiming revision 99 against
///    revision 5 is confused, and guessing which of the two is right is how
///    data gets lost.
fn check_revision(current: &serde_json::Value, expected: Option<u64>) -> Result<(), ApiError> {
    let Some(expected) = expected else {
        return Ok(());
    };
    let actual = memory_revision(current);
    if expected == actual {
        return Ok(());
    }
    Err(ApiError::conflict(format!(
        "matter memory revision mismatch: file is at {}, caller expected {}",
        actual, expected
    )))
}
pub async fn create_matter(
    State(state):      State<AppState>,
    Extension(claims): Extension<Claims>,
    Json(req):         Json<CreateMatterRequest>,
) -> Result<Json<Matter>, ApiError> {
    if req.name.trim().is_empty() {
        return Err(ApiError::bad_request("matter name must not be empty"));
    }

    let (tenant_id, created_by) = claims_to_ids(&claims)?;
    let external_key = req
        .external_key
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(str::to_string);
    let persona_id = req
        .persona_id
        .as_deref()
        .and_then(|s| s.parse::<uuid::Uuid>().ok())
        .map(pacgate_core::PersonaId);

    let matter = state
        .matter_store
        .create(
            &tenant_id,
            &req.name,
            req.description.as_deref(),
            external_key.as_deref(),
            persona_id.as_ref(),
            &created_by,
        )
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;

    // Ensure the on-disk directory structure exists
    pacgate_tenant::ensure_dirs(&state.config.data_dir, &tenant_id, &matter.id)
        .map_err(|e| ApiError::internal(e.to_string()))?;

    Ok(Json(matter))
}

pub async fn list_matters(
    State(state):      State<AppState>,
    Extension(claims): Extension<Claims>,
) -> Result<Json<Vec<Matter>>, ApiError> {
    let (tenant_id, _) = claims_to_ids(&claims)?;
    let matters = state
        .matter_store
        .list(&tenant_id)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;
    Ok(Json(matters))
}

pub async fn get_matter(
    State(state):      State<AppState>,
    Extension(claims): Extension<Claims>,
    Path(id):          Path<String>,
) -> Result<Json<Matter>, ApiError> {
    let matter_id: MatterId = id
        .parse()
        .map_err(|e| ApiError::bad_request(format!("invalid matter id: {e}")))?;
    let (tenant_id, _) = claims_to_ids(&claims)?;
    let matter = state
        .matter_store
        .get(&tenant_id, &matter_id)
        .await
        .map_err(|e| match e {
            // A missing matter is a 404, not a 500. The store ALREADY
            // discriminates this: `From<sqlx::Error>` maps `RowNotFound` to
            // `TenantError::MatterNotFound`. Flattening every variant into
            // `internal` threw that distinction away, so an unknown matter id
            // and a broken database were indistinguishable to a caller.
            //
            // That mattered here: install.ps1 probes this endpoint to decide
            // whether a configured PACGATE_MATTER_ID is real, and a 500 reads
            // as "the API is down" rather than "that id does not exist".
            TenantError::MatterNotFound(_) => ApiError::not_found("matter not found"),
            other => ApiError::internal(other.to_string()),
        })?;
    Ok(Json(matter))
}

pub async fn delete_matter(
    State(state):      State<AppState>,
    Extension(claims): Extension<Claims>,
    Path(id):          Path<String>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let matter_id: MatterId = id
        .parse()
        .map_err(|e| ApiError::bad_request(format!("invalid matter id: {e}")))?;
    let (tenant_id, _) = claims_to_ids(&claims)?;
    state
        .matter_store
        .delete(&tenant_id, &matter_id)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;
    Ok(Json(serde_json::json!({"deleted": true, "id": id})))
}

pub async fn get_matter_memory(
    State(state): State<AppState>,
    Extension(claims): Extension<Claims>,
    Path(id): Path<String>,
) -> Result<Json<serde_json::Value>, ApiError> {
    let matter_id: MatterId = id
        .parse()
        .map_err(|e| ApiError::bad_request(format!("invalid matter id: {e}")))?;
    let (tenant_id, _) = claims_to_ids(&claims)?;

    state
        .matter_store
        .get(&tenant_id, &matter_id)
        .await
        .map_err(|_| ApiError::not_found("matter not found"))?;

    let path = matter_memory_path(&state.config.data_dir, &tenant_id, &matter_id);
    if !path.exists() {
        return Ok(Json(default_matter_memory()));
    }

    let bytes = std::fs::read(&path)
        .map_err(|e| ApiError::internal(format!("failed to read matter memory: {e}")))?;
    let memory = serde_json::from_slice(&bytes)
        .map_err(|e| ApiError::internal(format!("failed to parse matter memory: {e}")))?;

    Ok(Json(memory))
}

pub async fn save_matter_memory(
    State(state): State<AppState>,
    Extension(claims): Extension<Claims>,
    Path(id): Path<String>,
    headers: HeaderMap,
    Json(memory): Json<serde_json::Value>,
) -> Result<Json<serde_json::Value>, ApiError> {
    if !memory.is_object() {
        return Err(ApiError::bad_request("matter memory must be a JSON object"));
    }

    // Scope FIRST - before the matter lookup and before any filesystem access, so
    // a refused write cannot have touched anything.
    //
    // This is the mechanical half of "memory holds process, not matter facts".
    // The policy lives in memory_scope.rs; without this call it would be a
    // comment, which is exactly how the If-Match guard ended up dead at three
    // layers while six unit tests passed.
    crate::check_memory_scope(&memory).map_err(|v| match v {
        crate::MemoryScopeViolation::Identifier { entity, count } => ApiError::unprocessable(
            format!(
                "memory may hold process, not matter facts: {count} {entity} identifier(s) found. \
                 Matter facts belong in the RAG lane, which is sanitization-gated."
            ),
        ),
        crate::MemoryScopeViolation::TooLarge { bytes, limit } => ApiError::unprocessable(format!(
            "memory payload is {bytes} bytes, over the {limit}-byte limit: this looks like content \
             rather than a process summary"
        )),
    })?;

    let matter_id: MatterId = id
        .parse()
        .map_err(|e| ApiError::bad_request(format!("invalid matter id: {e}")))?;
    let (tenant_id, _) = claims_to_ids(&claims)?;

    state
        .matter_store
        .get(&tenant_id, &matter_id)
        .await
        .map_err(|_| ApiError::not_found("matter not found"))?;

    let path = matter_memory_path(&state.config.data_dir, &tenant_id, &matter_id);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| ApiError::internal(format!("failed to prepare matter memory dir: {e}")))?;
    }

    // Read the guard and the current revision BEFORE touching the file.
    //
    // A conflict must leave the file exactly as it was: a 409 that had already
    // truncated the file would be worse than no guard, because the caller would
    // believe nothing was written.
    let expected = if_match_revision(&headers)?;

    let current = if path.exists() {
        let existing = std::fs::read(&path)
            .map_err(|e| ApiError::internal(format!("failed to read matter memory: {e}")))?;
        serde_json::from_slice(&existing)
            .map_err(|e| ApiError::internal(format!("failed to parse matter memory: {e}")))?
    } else {
        // No file yet: revision 0, so `If-Match: 0` is correct and anything else
        // is a stale claim.
        default_matter_memory()
    };

    // THE GUARD. Defined at the top of this file since plan 018 Task 3 and
    // asserted by six unit tests - but never called from production code, which
    // made it dead and left every write unconditional.
    check_revision(&current, expected)?;

    // The server owns the counter. `If-Match` is a claim about what the caller
    // READ, never the value to store: trusting a body field here would let a
    // stale client reset the revision and defeat the guard on the next request.
    let mut memory = memory;
    if let Some(obj) = memory.as_object_mut() {
        obj.insert(
            "revision".to_string(),
            serde_json::Value::from(next_revision(&current)),
        );
    }

    let bytes = serde_json::to_vec_pretty(&memory)
        .map_err(|e| ApiError::internal(format!("failed to serialize matter memory: {e}")))?;
    write_atomic(&path, &bytes)
        .map_err(|e| ApiError::internal(format!("failed to write matter memory: {e}")))?;

    Ok(Json(memory))
}

pub async fn list_matter_documents(
    State(state): State<AppState>,
    Extension(claims): Extension<Claims>,
    Path(id):     Path<String>,
) -> Result<Json<Vec<pacgate_core::Document>>, ApiError> {
    let (tenant_id, _) = claims_to_ids(&claims)?;
    let matter_id: MatterId = id
        .parse()
        .map_err(|e| ApiError::bad_request(format!("invalid matter id: {e}")))?;

    state
        .matter_store
        .get(&tenant_id, &matter_id)
        .await
        .map_err(|_| ApiError::not_found("matter not found"))?;

    let docs = state
        .doc_store
        .list_for_matter(&matter_id)
        .await
        .map_err(|e| ApiError::internal(e.to_string()))?;
    Ok(Json(docs))
}

#[cfg(test)]
mod memory_concurrency_tests {
    use super::*;

    #[test]
    fn revision_defaults_to_zero_when_absent_or_unusable() {
        assert_eq!(memory_revision(&serde_json::json!({})), 0);
        assert_eq!(memory_revision(&serde_json::json!({"revision": 7})), 7);
        assert_eq!(memory_revision(&serde_json::json!({"revision": "nope"})), 0);
        assert_eq!(memory_revision(&serde_json::json!({"revision": -3})), 0);
    }

    #[test]
    fn an_unconditional_write_is_allowed() {
        // Backwards compatibility: an existing caller that sends no If-Match
        // must keep working. Deliberate, not an oversight - see the plan.
        let current = serde_json::json!({"revision": 5});
        assert!(check_revision(&current, None).is_ok());
    }

    #[test]
    fn a_matching_revision_is_allowed() {
        let current = serde_json::json!({"revision": 5});
        assert!(check_revision(&current, Some(5)).is_ok());
    }

    #[test]
    fn a_stale_revision_is_a_conflict() {
        let current = serde_json::json!({"revision": 5});
        let err = check_revision(&current, Some(4)).unwrap_err();
        assert_eq!(err.status, axum::http::StatusCode::CONFLICT);
    }

    #[test]
    fn a_future_revision_is_also_a_conflict() {
        // A caller claiming a revision that does not exist is confused, not
        // ahead. Treating it as a conflict is the fail-closed choice.
        let current = serde_json::json!({"revision": 5});
        assert_eq!(
            check_revision(&current, Some(99)).unwrap_err().status,
            axum::http::StatusCode::CONFLICT
        );
    }

    #[test]
    fn a_new_matter_with_no_file_conflicts_only_on_a_non_zero_claim() {
        // No file means revision 0. If-Match: 0 is correct; anything else is stale.
        let current = default_matter_memory();
        assert!(check_revision(&current, Some(0)).is_ok());
        assert!(check_revision(&current, Some(1)).is_err());
    }

    /// The counter must advance on a successful write, or the guard compares a
    /// constant against itself and can never reject a stale caller.
    ///
    /// This is the assertion whose ABSENCE let the guard be present in three
    /// places while doing nothing: nothing in the workspace incremented it, so
    /// `grep -r 'revision.*+=' pacgate-ai/crates` returned no match at all.
    #[test]
    fn the_next_revision_always_advances() {
        assert_eq!(
            next_revision(&serde_json::json!({})),
            1,
            "absent reads as 0, so the next value is 1"
        );
        assert_eq!(next_revision(&serde_json::json!({ "revision": 0 })), 1);
        assert_eq!(next_revision(&serde_json::json!({ "revision": 5 })), 6);
        // A corrupt stored value must not freeze the counter at a constant:
        // whatever it reads as, the next value is strictly greater.
        assert_eq!(next_revision(&serde_json::json!({ "revision": "nope" })), 1);
        assert_eq!(next_revision(&serde_json::json!({ "revision": -3 })), 1);
    }

    /// The property that makes the guard work, stated directly rather than
    /// inferred from the two halves being individually correct.
    #[test]
    fn a_stale_caller_is_rejected_after_a_write_advances_the_counter() {
        let before = serde_json::json!({ "revision": 4 });
        let after = serde_json::json!({ "revision": next_revision(&before) });

        // The client that read revision 4 is now stale: its claim must fail.
        assert!(
            check_revision(&after, Some(4)).is_err(),
            "a caller holding the PRE-write revision must be rejected after the write"
        );
        // A client holding the new revision succeeds.
        assert!(check_revision(&after, Some(5)).is_ok());
        // And an unconditional caller is still allowed (the opt-out path).
        assert!(check_revision(&after, None).is_ok());
    }

    /// A malformed If-Match must be a client error, not a silent unconditional
    /// write. Silently ignoring a header the caller believes is guarding them is
    /// the worst outcome: they think they are protected.
    #[test]
    fn a_malformed_if_match_is_rejected_not_ignored() {
        use axum::http::header::IF_MATCH;

        let mut h = HeaderMap::new();
        h.insert(IF_MATCH, "not-a-number".parse().unwrap());
        let err = if_match_revision(&h).unwrap_err();
        assert_eq!(err.status, axum::http::StatusCode::BAD_REQUEST);

        // Absent is allowed - the unconditional path stays.
        assert_eq!(if_match_revision(&HeaderMap::new()).unwrap(), None);

        // A well-formed value parses, including the legal quoted form.
        let mut ok = HeaderMap::new();
        ok.insert(IF_MATCH, "7".parse().unwrap());
        assert_eq!(if_match_revision(&ok).unwrap(), Some(7));

        let mut quoted = HeaderMap::new();
        quoted.insert(IF_MATCH, "\"7\"".parse().unwrap());
        assert_eq!(if_match_revision(&quoted).unwrap(), Some(7));
    }

    /// Read this file's source up to the test module.
    ///
    /// Scoped deliberately: searching the whole file makes the assertions below
    /// match their OWN string literals, which is the mistake made in P4 - an
    /// ordering assertion there failed against correct code for exactly this
    /// reason.
    fn production_source() -> String {
        let src = std::fs::read_to_string(
            std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("src/matters.rs"),
        )
        .expect("read own source");
        let end = src.find("#[cfg(test)]").expect("this file must have a test module");
        src[..end].to_string()
    }

    /// The guard must be reachable from the handler. If `save_matter_memory` does
    /// not read headers, `If-Match` is discarded and 409 is unreachable however
    /// correct `check_revision` is - which was the actual state of this code.
    #[test]
    fn the_save_handler_actually_reads_the_if_match_header() {
        let prod = production_source();
        let save = &prod[prod
            .find("pub async fn save_matter_memory")
            .expect("save_matter_memory must exist")..];

        assert!(
            save.contains("headers: HeaderMap"),
            "save_matter_memory must take a HeaderMap, or If-Match is discarded \
             and 409 is unreachable"
        );
        assert!(
            save.contains("if_match_revision("),
            "save_matter_memory must CALL if_match_revision"
        );
        assert!(
            save.contains("check_revision("),
            "save_matter_memory must CALL check_revision - defined-but-uncalled is \
             the exact state that let this guard be dead at three layers"
        );
        assert!(
            save.contains("next_revision("),
            "save_matter_memory must assign the revision server-side"
        );
        assert!(
            save.contains("write_atomic("),
            "save_matter_memory must write atomically"
        );
    }

    #[test]
    fn the_save_handler_enforces_the_memory_scope() {
        let prod = production_source();
        let save = &prod[prod
            .find("pub async fn save_matter_memory")
            .expect("save_matter_memory must exist")..];

        assert!(
            save.contains("check_memory_scope("),
            "save_matter_memory must CALL check_memory_scope - a correct rule the \
             handler never calls is the exact shape of the defect this codebase \
             already shipped once: defined, unit-tested, called from nowhere"
        );
        // 422, not 400 or 500: the body is well-formed JSON and the server is fine.
        assert!(
            save.contains("unprocessable"),
            "an out-of-scope memory must be refused with 422, not 400 or 500"
        );
        // Ordering: the scope check must precede any filesystem access, or a
        // refused write could already have modified the file.
        let scope_call = save.find("check_memory_scope(").expect("checked above");
        if let Some(fs) = save.find("std::fs::") {
            assert!(
                scope_call < fs,
                "the scope check must run BEFORE any filesystem access \
                 (scope at byte {scope_call}, fs at byte {fs})"
            );
        }
    }

    #[test]
    fn an_atomic_write_replaces_the_whole_file_and_leaves_no_temp() {        let dir = std::env::temp_dir().join(format!("pacgate-atomic-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("memory.json");

        // Replacing an existing file must yield the new content whole.
        std::fs::write(&path, b"{\"old\":true}").unwrap();
        write_atomic(&path, b"{\"new\":true}").unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), b"{\"new\":true}");

        // A fresh write works too.
        let fresh = dir.join("fresh.json");
        write_atomic(&fresh, b"{\"ok\":1}").unwrap();
        assert_eq!(std::fs::read(&fresh).unwrap(), b"{\"ok\":1}");

        // No temp file left behind.
        let leftovers: Vec<String> = std::fs::read_dir(&dir)
            .unwrap()
            .filter_map(|e| e.ok())
            .map(|e| e.file_name().to_string_lossy().to_string())
            .filter(|n| n.contains("tmp"))
            .collect();
        assert!(leftovers.is_empty(), "temp files left behind: {leftovers:?}");

        let _ = std::fs::remove_dir_all(&dir);
    }
}
