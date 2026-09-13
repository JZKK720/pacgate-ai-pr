//! pacgate-seed — idempotent RAG seed from the firm's asset corpus.
//!
//! Creates (or reuses) the default tenant + a seed matter, then uploads every
//! `.md`/`.txt` text file under the assets directory and ingests each into the
//! per-matter RAG knowledge base (kb_chunks) via `ChunkIngestor`.
//!
//! Usage (from repo root):
//!   cargo run -p pacgate-api --bin pacgate-seed -- \
//!       --db-url postgres://pacgate:pacgate@localhost:5432/pacgate \
//!       --assets ../pacgate-ai/pacgate-ai-assets/pacgate-ai/assets/assets \
//!       --tenant-slug default-firm \
//!       --matter-name "Firm Knowledge Base"
//!
//! Reversible: run `pacgate-seed --purge` to delete the seed matter's
//! documents + kb_chunks. Idempotent: re-running with the same matter name
//! reuses the matter and re-ingests (replacing chunks for re-uploaded docs).

use std::path::{Path, PathBuf};
use std::sync::Arc;

use pacgate_core::{DocumentStore, Jurisdiction, SourceLevel, UserId};
use pacgate_docx::FsDocumentStore;
use pacgate_rag::ChunkIngestor;
use pacgate_tenant::{MatterStore, TenantStore};

/// Files that must never enter the knowledge base.
/// OPERATOR.md holds real GitHub/RustDesk credentials; render.py and PDFs are
/// build artifacts; `*_converted.md` are machine-generated duplicates.
const EXCLUDE_FILENAMES: &[&str] = &["OPERATOR.md", "render.py"];
const EXCLUDE_SUFFIXES: &[&str] = &[".pdf", ".docx"];

#[derive(Debug)]
struct Options {
    db_url: String,
    assets_dir: PathBuf,
    tenant_slug: String,
    tenant_name: String,
    matter_name: String,
    matter_description: String,
    purge: bool,
    skip_uploads: bool,
}

fn parse_args() -> Options {
    let mut args = std::env::args().skip(1);
    let mut opts = Options {
        db_url: "postgres://pacgate:pacgate@localhost:5432/pacgate".to_string(),
        assets_dir: PathBuf::from("pacgate-ai/pacgate-ai-assets/pacgate-ai/assets/assets"),
        tenant_slug: "default-firm".to_string(),
        tenant_name: "Pacgate Law".to_string(),
        matter_name: "Firm Knowledge Base".to_string(),
        matter_description: "Seeded firm knowledge corpus (prompts, templates, plans).".to_string(),
        purge: false,
        skip_uploads: false,
    };

    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--db-url" => opts.db_url = args.next().unwrap_or_default(),
            "--assets" => opts.assets_dir = PathBuf::from(args.next().unwrap_or_default()),
            "--tenant-slug" => opts.tenant_slug = args.next().unwrap_or_default(),
            "--tenant-name" => opts.tenant_name = args.next().unwrap_or_default(),
            "--matter-name" => opts.matter_name = args.next().unwrap_or_default(),
            "--matter-description" => opts.matter_description = args.next().unwrap_or_default(),
            "--purge" => opts.purge = true,
            "--skip-uploads" => opts.skip_uploads = true,
            "--help" | "-h" => {
                eprintln!(
                    "pacgate-seed [--db-url URL] [--assets DIR] [--tenant-slug SLUG] \
                     [--tenant-name NAME] [--matter-name NAME] [--purge] [--skip-uploads]"
                );
                std::process::exit(0);
            }
            other => eprintln!("warning: ignoring unknown argument {other}"),
        }
    }
    opts
}

/// Collect all text (`.md`, `.txt`) files under `dir`, skipping excluded files.
fn collect_text_files(dir: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let mut stack = vec![dir.to_path_buf()];
    while let Some(current) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&current) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                stack.push(path);
            } else {
                let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
                let is_text = path
                    .extension()
                    .and_then(|e| e.to_str())
                    .map(|e| e.eq_ignore_ascii_case("md") || e.eq_ignore_ascii_case("txt"))
                    .unwrap_or(false);
                let excluded = EXCLUDE_FILENAMES.iter().any(|x| name == *x)
                    || EXCLUDE_SUFFIXES.iter().any(|s| name.to_lowercase().ends_with(s));
                if is_text && !excluded {
                    out.push(path);
                }
            }
        }
    }
    out.sort();
    out
}

fn slug_for_path(path: &Path, parent: &Path) -> String {
    // Use a stable name from the relative path so re-runs produce the same doc.
    let rel = path.strip_prefix(parent).unwrap_or(path);
    let joined = rel
        .components()
        .map(|c| c.as_os_str().to_string_lossy().to_string())
        .collect::<Vec<_>>()
        .join("_");
    // Trim the extension, collapse to a filesystem-safe stem.
    let name = joined
        .trim_end_matches(".md")
        .trim_end_matches(".txt")
        .replace(['/', '\\', ' ', ':'], "_");
    name
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    let opts = parse_args();
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    let pool = sqlx::postgres::PgPoolOptions::new()
        .max_connections(5)
        .connect(&opts.db_url)
        .await?;

    // Migrations — tenant schema, then RAG schema (kb_chunks + pgvector).
    pacgate_tenant::run_migrations(&pool).await?;
    pacgate_rag::RagStore::run_migrations(&pool).await?;

    let tenant_store = TenantStore::new(pool.clone());
    let matter_store = MatterStore::new(pool.clone());
    let data_dir = std::env::var("DATA_DIR").unwrap_or_else(|_| "./data/tenants".to_string());
    let doc_store = Arc::new(FsDocumentStore::new(pool.clone(), &data_dir));

    // Resolve or create the default tenant by slug.
    let tenant = match tenant_store.get_by_slug(&opts.tenant_slug).await {
        Ok(t) => {
            tracing::info!("reusing tenant {}", t.slug);
            t
        }
        Err(_) => {
            let t = tenant_store.create(&opts.tenant_name, &opts.tenant_slug).await?;
            tracing::info!("created tenant {}", t.slug);
            t
        }
    };

    // A seed needs a valid owner. Create/resolve a service account user.
    let user_store = Arc::new(pacgate_auth::AuthService::new(
        std::env::var("PACGATE_JWT_SECRET").unwrap_or_else(|_| "seed-secret".to_string()),
        pool.clone(),
    ));
    let owner_id: UserId = match user_store
        .register(
            &tenant.id,
            "seed@pacgate.local",
            "seed-password-123",
            "admin",
            Some("Seed Service Account"),
        )
        .await
    {
        Ok(id) => id,
        Err(_e) => {
            // Already exists — look it up.
            let row = sqlx::query_scalar::<_, uuid::Uuid>(
                "SELECT id FROM users WHERE tenant_id = $1 AND email = 'seed@pacgate.local'",
            )
            .bind(tenant.id.0)
            .fetch_one(&pool)
            .await?;
            UserId(row)
        }
    };

    // Resolve or create the seed matter.
    let matter = match matter_store
        .list(&tenant.id)
        .await?
        .into_iter()
        .find(|m| m.name == opts.matter_name)
    {
        Some(m) => {
            tracing::info!("reusing matter {}", m.name);
            m
        }
        None => {
            let m = matter_store
                .create(
                    &tenant.id,
                    &opts.matter_name,
                    Some(&opts.matter_description),
                    None,
                    None,
                    &owner_id,
                )
                .await?;
            tracing::info!("created matter {}", m.name);
            m
        }
    };

    if opts.purge {
        // Delete all documents for the matter (cascades to kb_chunks).
        let docs = doc_store
            .list_for_matter(&matter.id)
            .await?;
        for doc in &docs {
            doc_store.delete_document_family(&doc.id).await?;
        }
        tracing::info!("purged {} document(s) for matter {}", docs.len(), matter.name);
        return Ok(());
    }

    if opts.skip_uploads {
        tracing::info!("skip-uploads set; nothing to ingest");
        return Ok(());
    }

    // Ingest the corpus.
    let embed_svc = pacgate_rag::EmbeddingService::with_defaults();
    let ingestor = ChunkIngestor::new(pool.clone(), embed_svc);
    let files = collect_text_files(&opts.assets_dir);
    tracing::info!("found {} text file(s) in {}", files.len(), opts.assets_dir.display());

    let mut total_chunks = 0u32;
    let mut ingested = 0u32;

    for path in &files {
        let content = match std::fs::read_to_string(path) {
            Ok(c) => c,
            Err(e) => {
                tracing::warn!("skipping {}: {e}", path.display());
                continue;
            }
        };
        if content.trim().is_empty() {
            continue;
        }
        let name = slug_for_path(path, &opts.assets_dir);
        let filename = format!("{name}.md");

        // Upload as a document so the RAG JOIN on documents resolves.
        let doc = match doc_store
            .upload_bytes(&matter.id, &filename, content.as_bytes(), &owner_id)
            .await
        {
            Ok(d) => d,
            Err(e) => {
                tracing::warn!("upload failed for {}: {e}", path.display());
                continue;
            }
        };

        // Ingest into kb_chunks.
        let n = ingestor
            .ingest_with_data_level(
                &tenant.id,
                &matter.id,
                &doc.id,
                &content,
                &Jurisdiction::ChinaMainland,
                &SourceLevel::InternalTemplate,
                pacgate_core::DataLevel::T2RestrictedSeed,
            )
            .await?;
        total_chunks += n;
        ingested += 1;
        tracing::info!("ingested {} chunk(s) from {}", n, path.display());
    }

    tracing::info!(
        "seed complete: {} file(s), {} chunk(s) into matter {}",
        ingested,
        total_chunks,
        matter.name
    );

    Ok(())
}
