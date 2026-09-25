// Print the workflow tier tags exactly as `pacgate-api` resolves them.
//
// WHY THIS EXISTS
//
// Which local model fills each workflow tier is a property of the MACHINE, not of
// this crate. It was once compiled in, and the Rust values drifted from what the
// AIPCs actually had installed -- all three returned HTTP 404, and since a tag no
// local Ollama serves 404s with no fallback, every `/api/workflows/:id/execute`
// returned 500. All 222 templates down, from a value nothing validated.
//
// The tier tags now come from the environment (`PACGATE_MODEL_MAIN`, `_MID`,
// `_LOW`), set in the client compose files. This example prints what those
// variables resolve to, so an operator can check a machine's roster WITHOUT
// rebuilding an image, running the API, or reading any Rust:
//
//   # what this box would use right now
//   cargo run -p pacgate-core --example print_tiers
//
//   # what a different roster would produce, before committing it to compose
//   PACGATE_MODEL_MID=ornith-1.5:35b cargo run -p pacgate-core --example print_tiers
//
// Then confirm each printed tag is actually served by this machine's Ollama:
//
//   ollama show <tag>          # exit 0 = present, non-zero = would 404
//
// A tag printed here that `ollama show` rejects is exactly the defect this file
// exists to make visible. It reads the environment the same way `main.rs` does,
// so it cannot drift from the API's behaviour.

use pacgate_core::ModelConfig;

fn main() {
    let url = std::env::var("OLLAMA_BASE_URL")
        .unwrap_or_else(|_| "http://localhost:11434".to_string());

    println!("OLLAMA_BASE_URL = {url}");
    println!();
    for cfg in ModelConfig::from_env(&url) {
        println!("  {:?} = {}", cfg.tier, cfg.model_name);
    }
    println!();
    println!(
        "Overrides read: {} / {} / {}",
        ModelConfig::ENV_MAIN_TAG,
        ModelConfig::ENV_MID_TAG,
        ModelConfig::ENV_LOW_TAG
    );
    println!("Unset or blank variables fall back to the crate defaults:");
    println!(
        "  Main {}  Mid {}  Low {}",
        ModelConfig::DEFAULT_MAIN_TAG,
        ModelConfig::DEFAULT_MID_TAG,
        ModelConfig::DEFAULT_LOW_TAG
    );
}
