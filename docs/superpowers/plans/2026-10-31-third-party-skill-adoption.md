# Third-Party Skills And Tools: Adopt, Extend, Or Build

Status: decision record, 2026-10-31.
Scope: whether five external repositories can be built into the Pacgate AIPC stack.

## The question, stated correctly

"Can we build these in?" has two different meanings and they have different
answers:

1. **Can they be installed into _my_ agent environment?** Several already are,
   at `~/.agents/skills`. That is development tooling and it changes nothing
   about the product.
2. **Should they ship in the client bundle?** This is the question that
   matters. It is a product decision with licensing, egress, and support
   consequences.

Everything below answers question 2. The distinction is the whole point: a
skill in my agent directory costs a client nothing and can never leak a
matter file, while a skill in `deploy/client-bundle/deer-flow-skills/` runs on
the client's on-prem machine against client documents.

## Verified facts per repository

| Repository | Language | Stars | License | Shippable unit |
|---|---|---|---|---|
| `wuyoscar/jev-skill` | Python | 663 | MIT | `skills/` - 5 skills |
| `ibelick/ui-skills` | TypeScript | 10391 | MIT | `skills/` - 9 skills |
| `cobusgreyling/loop-engineering` | TypeScript | 11672 | MIT | `skills/` - 7 skills, plus CLI and `.claude-plugin` |
| `wandb/openui` | TypeScript | 22717 | Apache-2.0 | Whole application, own backend and docker-compose |
| `CopilotKit/OpenIntelligentUI` | TypeScript | 4077 | MIT | Whole application, own agent runtime |

Frontmatter conformance checked against our E4/E5 gates for all 14 skills in
the first two repos: every `name` matches its directory, none declares
`allowed-tools`, and the only frontmatter keys used are
`name, description, license, metadata, version` - all five are members of
deer-flow's `ALLOWED_FRONTMATTER_PROPERTIES`. No `.py`, `.js`, `.mjs`, `.sh`,
or `.ps1` files ship inside any of the 14 skill directories, so
`_should_scan_support_file` has nothing executable to reject.

So the skills are structurally clean. That is not the blocker.

## The blocker: cloud dependency, not structure

Every `jev-*` skill references `TYPESAFE_API_KEY`, and three name `jev-mcp`
directly. `jkudish/jev-mcp` is not a local library - it is a metered
commercial judgment API ("roughly 150 to 500 ms, for a fraction of a cent").
`OpenIntelligentUI` requires `OPENAI_API_KEY` and `TYPESAFE_API_KEY`;
`openui` requires one of `OPENAI_API_KEY`, `GROQ_API_KEY`, `GEMINI_API_KEY`,
or `ANTHROPIC_API_KEY`.

For an on-prem legal deployment, mounting any of these converts a closed-box
matter into prompt egress to a third-party inference provider. That does not
fail a build. It fails the reason the client bought an on-prem box.

`ui-skills` has no egress at all - it is pure design guidance with static
references. It is excluded for a different reason: the product has no design
surface. The only frontend is `docs/`, which I maintain as development work.

## A second blocker nobody asked about: no scan on bundle-sealed seeds

`scan_skill_content` is imported only by `installer.py`, `skill_manage_tool.py`,
and `gateway/routers/skills.py` - that is, the *install* path and the *learn*
path. `deploy/client-bundle/deer-flow-skills/` is bind-mounted read-only
straight to `/app/backend/.deer-flow/skills/public:ro`, and the scanner has no
hook on the load path.

Consequence: a skill shipped in the bundle is executed with zero content
inspection. The scanner that protects a user-installed skill does not look at
it. Today that is acceptable only because we author all three seeds and they
contain no executable content. It stops being acceptable the moment someone
drops 14 third-party skills into that directory, which is exactly what "build
these tools in" would mean.

If bundle seeds are ever sourced from outside this repository, add an install-time
scan step to `package-bundle.ps1` first. Do not rely on the runtime scanner
that does not run.

## Verdict

| Repository | Verdict | Reason |
|---|---|---|
| `wuyoscar/jev-skill` | **Reject for product** | All 5 skills require `TYPESAFE_API_KEY`; 3 require the `jev-mcp` cloud server. Egress. |
| `ibelick/ui-skills` | **Reject for product** | Zero egress, but no design surface ships to clients. Keep at user level for `docs/` work. |
| `cobusgreyling/loop-engineering` | **Reject for product** | A methodology repo, not a library. Our loop primitives (`skill_manage`, self-evolution) already exist. Reference only. |
| `wandb/openui` | **Reject** | Competing application needing its own port and a cloud LLM key. Generative UI is unrelated to contract review. |
| `CopilotKit/OpenIntelligentUI` | **Reject** | Same: an application, requiring two cloud keys. |

None of the five is blocked for technical reasons. Four are blocked by cloud
egress and one by irrelevance. That is a useful result: it means the decision
is stable and does not need re-litigating when they ship new versions.

## What is actually worth building

The one idea worth taking is the *pattern*, not the dependency. `jev`'s value
is cheap mechanical judgment run on every claim rather than once per task -
`jev_verify` checks a claim against supplied evidence, `jev_gate` refuses a
"done" claim whose evidence does not support it.

That pattern can be reimplemented against the model already on the box
(`qwen3.8:27b`), with no egress, no API key, and no per-call cost. It would be
a real quality upgrade for contract review: every extracted obligation
re-checked against its source span before it reaches the review panel.

Prerequisites before that is worth planning:

- A measured baseline. We do not currently know the extraction error rate, so
  we cannot show a verifier improves it.
- A latency budget. A second pass per obligation on a 27B local model is not
  free, and the review panel is already the slow path.

Neither exists yet, so this is a candidate for a future plan, not a task now.

## Standing rule for third-party skills

Any skill added to `deploy/client-bundle/deer-flow-skills/` must pass
`test-skill-evolution.ps1` (E1-E6) and `test-skills-and-templates.ps1`, and
must additionally satisfy:

1. **No network dependency at skill runtime.** No API key, no external MCP
   server, no download. A skill that needs a key is a cloud feature.
2. **No executable support files.** Keeps the unscanned-bundle-seed problem
   from mattering.
3. **Frontmatter within `ALLOWED_FRONTMATTER_PROPERTIES`.** A key outside that
   set makes the loader reject the skill silently.
4. **Authored or reviewed in-repo.** Provenance matters more than the licence
   when the content becomes instructions an agent follows against client
   documents.

## Gate fix made alongside this analysis

E4 read the first physical line of `description:`. The loader parses with
`yaml.safe_load`, so `description: >` is valid and resolves to the full
folded text. `ui-skills/fixing-metadata` is written that way and resolves to
340 chars; E4 reported 1 and failed it.

Fixed in `scripts/test-skill-evolution.ps1` and verified: all 14 third-party
skills now pass E4, and a 19-char description still fails. This was a latent
false-failure that would have hit every externally authored skill.
