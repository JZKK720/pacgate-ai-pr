# Pacgate Repo Guidelines

Pacgate AI is currently a proposal-heavy repository with static presentation pages, supporting scripts, and a Rust workspace. Work from the nearest concrete file, symbol, or behavior instead of mapping the whole repo first.

## Execution Baseline

- Start with one local hypothesis and one cheap check before the first edit on non-trivial tasks.
- Make the smallest reviewable change that solves the request. Do not add abstractions, frameworks, or config layers unless the task requires them.
- Validate the touched slice immediately after the first substantive edit. Prefer focused checks over broad repo-wide commands.
- Keep unrelated cleanup out of the diff. If you notice a separate issue, mention it instead of folding it into the same patch.

## Current Surface Priorities

- Treat `docs/` as the primary presentation surface. Default to static HTML, CSS, and light JavaScript for those pages.
- Treat proposal, quote, appendix, and clarification artifacts as business materials, not generic startup marketing pages.
- Keep temporary Q&A workboards, client clarification forms, and other working materials separate from the public landing or onboarding flow unless the user explicitly asks to integrate them.

## Proposal And Copy Rules

- Keep business copy grounded in real Pacgate surfaces, delivery scope, and commercial logic.
- Prefer procurement, partner, OEM, investor, and client-deployment language over education or training positioning.
- Avoid generic SaaS hype, invented product claims, placeholder metrics, and decorative labels that weaken credibility.
- Use hyphenated punctuation instead of em-dashes in visible copy unless the user explicitly asks otherwise.

## Bilingual And Presentation Rules

- Preserve English and Chinese parity on mirrored proposal surfaces.
- Maintain the established full-block bilingual structure when a page already uses separate `.en` and `.zh` wrappers.
- Protect Chinese typography, spacing, and line-break quality. Do not make font choices or layout changes that degrade Chinese rendering.
- Keep long-form proposal pages readable on desktop, mobile, and PDF export paths.

## Technology Expectations

- For docs work, do not assume React, Next.js, Tailwind, or build tooling. Stay within the existing static stack unless the task says otherwise.
- For Rust work, keep changes scoped to the owning crate when possible and validate the touched crate or module instead of the entire workspace first.
- When adapting outside guidance or reusable skills, translate it into Pacgate-specific rules instead of copying generic upstream conventions verbatim.

## Deployment Ground Truth (AIPC / client install)

- The client install is by our on-site engineer, and the runtime images are public
  on GHCR by design. Do not propose `docker login ghcr.io` for the client path.
  Verify state instead of assuming: anonymous HEAD on the GHCR manifest returns 200
  when public, 401 when still private. Flipping personal-account package visibility
  is UI-only; the API `/visibility` route 404s even with `write:packages`.
- Ollama `:cloud` tags are not local. Models like `deepseek-*-cloud` have no weight
  layers on disk (empty manifest `layers`) and route inference through ollama.com.
  They need no API key — auth rides the `ollama signin` OAuth session — so no-key
  does not mean local; verify with `ollama ps` (cloud tags never appear loaded) and
  the manifest, not by which endpoint was called. Only tags such as
  `gemma4`, `qwen3.8`, and `nomic-embed-text` run on-device. Flag any cloud-routed
  model that sits on a client-data path (deer-flow active model, qm `MODEL_NAME`);
  for law-firm data residency, prefer the local set. The RAG pipeline itself
  (nomic embeddings, OpenViking extraction via gemma4, local Postgres) is fully
  on-device — the exposure surface is only generation prompts sent through
  cloud-routed chat models.
- The local Ollama model choice belongs to the user and can change per machine.
  Do not treat a tier set as a fixed repo constant; when a decision depends on it,
  check the current set (`ollama list`, `deer-flow-config.yaml`, `qm.config.jsonc`)
  and keep `deploy/client-bundle/ollama-models.txt` in sync with what configs use.
- A fresh clone is the only valid test for install-path changes. This dev box
  accumulates credentials, pulled models, and rendered gitignored configs, which
  hides failures a clean AIPC would hit. Prove installer and compose changes in a
  clean temp clone before claiming deploy readiness.