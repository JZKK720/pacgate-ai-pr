# DEFECT: the legal workflow templates are mounted into the wrong service

**Found:** 2026-09-22, during the pre-2.1 stack hardening pass
**Severity:** client-visible. The product serves the WRONG workflow set.
**Status:** DIAGNOSED, NOT FIXED. Fix needs a decision (see bottom).

## The defect

`GET /api/workflows` is owned by **pacgate-api**. The firm's legal workflow
templates are bind-mounted into **deer-flow**, at a path nothing in deer-flow
reads. So the API falls back to its 10 built-in Rust definitions and the real
templates are dead weight in the wrong container.

Measured, not inferred:

| Probe | Result |
| --- | --- |
| `docker inspect pacgate-api` mounts | **only** `data -> /data` |
| `WORKFLOWS_DIR` in the live pacgate-api container | **empty / unset** |
| `/app/workflows` inside pacgate-api | **does not exist** |
| `/app/workflows` inside **deer-flow** | **exists, 15 files** |
| `GET /api/workflows` (live) | returns **10** |
| YAML templates in `deploy/client-bundle/workflows/` | **15** |

## The mechanism

`compose.prod.yaml` declares the mount at **L75**, inside the **`deer-flow`**
service block (L50-124):

    - ./workflows:/app/workflows:ro

The **`pacgate-api`** block (L19-49) declares `volumes:` but has **no workflows
mount at all**. Two independent faults, either of which alone would break it:

1. **Wrong service.** The mount is on deer-flow. deer-flow has no workflow-listing
   route; pacgate-api does.
2. **No `WORKFLOWS_DIR`.** Even with the files present, `workflows.rs:56-61` only
   reads from disk when `state.config.workflows_dir` is set:

       let workflows = state.config.workflows_dir.as_ref()
           .map(|dir| pacgate_workflow::list_all_workflows(Some(dir.as_path())))
           .unwrap_or_else(pacgate_workflow::list_workflows);

   With it unset it takes the `unwrap_or_else` branch - `list_workflows()`, the
   built-in set. Nothing in `compose.prod.yaml` sets `WORKFLOWS_DIR`.

## Why it matters

The built-ins are a small generic set ("Contract Review", "Contract Comparison",
"Due Diligence Review", "Legal Research Memo", "Tabular Document Review", ...).
The YAML set is the domain-specific library: `banking_general`,
`capital_markets`, `compliance_corporate`, `compliance_specialized`,
`archive_collection`, `daily_general`, `nonlitigation_extra`, and so on -
15 files in 8 groups, matching the practice areas a legal client would recognise.

A client opening the workflow list today does not see the firm's workflow library.
Nothing errors. It silently serves a different, smaller, generic set - the exact
failure shape this repo has been bitten by before (a thing that starts green and
is quietly not the thing you think it is).

## A claim that needs correcting

`plans/006-setup-guide.md:91` states:

> 220 legal workflow templates + 30 personas (pre-loaded in pacgate-api)

Neither number matches reality: **15** YAML templates ship, **10** are served, and
`pacgate-api` has no `personas` count verified anywhere in this pass. The 220/30
figures should be treated as unverified until someone can show the source. Do not
repeat them in client-facing material.

## Fix options (needs a decision, not a guess)

**Option 1 - move the mount, set the variable.** Add to the `pacgate-api` block:

    volumes:
      - ./workflows:/app/workflows:ro
    environment:
      WORKFLOWS_DIR: /app/workflows

Smallest change consistent with the existing architecture, and it matches how
`deer-flow` already consumes its config. Needs a compose edit plus a
`--force-recreate pacgate-api` (a volume/env change is not a bind-mount content
change, so `up -d` alone will not apply it - see install.ps1 step 7c's sibling
case at L661 which already uses `up -d --force-recreate` for exactly this).

**Option 2 - bake the templates into the image.** More robust (a fresh clone
without the mount still works) but needs a rebuild and a rebuild is currently
gated behind the same release that is frozen. Not preferred now.

**Option 3 - move the YAML set into the built-in list.** Rejected: it would trade
a data file for a recompile and lose the ability to add a template without a
release, which is most of the value of shipping them as YAML.

**Recommendation: Option 1**, delivered with the 0.1.x that carries the rest of
this hardening work, since it needs no image change.

## FIX PROVEN before applying

Run in a throwaway container from the SAME published image, with the same DB and
the mount added to the correct service:

    docker run -d --name pg-wf-probe --network client-bundle_default \
      -e DATABASE_URL=... -e DATA_DIR=/data/tenants \
      -e WORKFLOWS_DIR=/app/workflows \
      -v ./workflows:/app/workflows:ro -v ./data:/data \
      ghcr.io/jzkk720/pacgate-api:0.1.17

    WORKFLOWS_DIR=/app/workflows   ->  15 files visible
    GET /api/workflows             ->  222 workflows

Measured result, before and after:

| | live today | with `WORKFLOWS_DIR` set |
| --- | --- | --- |
| `WORKFLOWS_DIR` | *(empty)* | `/app/workflows` |
| `/app/workflows` | does not exist | 15 files |
| `GET /api/workflows` | **10** | **222** |

So the templates were never broken - they were mounted into a container that
does not serve them. The `220` figure in `plans/006` was essentially RIGHT all
along (222 = 15 YAML files expanding into their workflow groups, plus the
built-ins). The earlier note in this document saying the 220 claim was
unverified is now resolved in the claim's favour: the number is real, it just was
never reachable through the API.

The served workflows are the real firm library. It is **bilingual, not
Chinese-only**: Chinese template NAMES with English descriptions, e.g.
`项目档案初收（第一阶段）` with description "Phase 1 archive collection - claim
representative complete project/case/matter archives across the five business
modules", under category `archive_collection`.

That distinction matters for anyone re-checking this later: the 10 BUILT-INS also
have English names ("Contract Review", "Due Diligence Review"), so **title
language alone is not a reliable discriminator** - a quick glance at an English
title could look correct when it is the fallback. Use the COUNT.

## PROVEN IN THE LANE USERS ACTUALLY USE (MCP)

HTTP was not sufficient proof on its own, because per this repo's standing rule
the workflow templates have **no user-facing UI** - the ONLY path to them is MCP
(`pacgate_list_workflows` / `_get` / `_execute`) inside an agent chat. And MCP
calls the same endpoint (`deploy/pacgate-mcp/server.py:366` hits
`GET /api/workflows`), so the agent lane had also been serving the 10 built-ins.

Verified by CALLING the tool over MCP, not by listing tools:

    docker cp probe_wf.py pacgate-mcp:/tmp/probe_wf.py
    docker exec pacgate-mcp python3 /tmp/probe_wf.py

    WORKFLOWS VIA MCP: 222
    distinct categories: 46
    sample: ['项目档案初收（第一阶段）', '项目概况表编制', '文件目录表编制']

So the fix reaches the agent chat, which is the whole user-visible surface for
workflows. Before it, an agent asked to run a firm template could not see it.

## Two more reasons the fix is safe

1. **deer-flow does not use the mount.** Verified inside the container, not
   assumed: zero Python files under `/app/backend` reference `/app/workflows`, no
   router mentions workflows, and `config.yaml` does not mention them either. The
   15 files sit there unread. Moving the mount cannot break deer-flow.
2. **It is a compose change, so it needs a recreate, not a restart.** Adding a
   *volume* or an environment variable changes compose config, so `docker compose
   up -d` WILL apply it - unlike a bind-mounted file edit, which needs the
   step-7c restart. Worth knowing: the two cases fail in opposite directions.

## Verification required after the fix

- `WORKFLOWS_DIR` is non-empty in the container and `/app/workflows` lists 15
  files.
- `GET /api/workflows` returns **15**, not 10, and the ids are the YAML ids.
- A workflow can be **executed** end to end, not merely listed - listing proves
  the file was found; execution proves the steps parse and run.
- Re-check on a **fresh clone**, per the standing install-path rule.

## What this is NOT

Not an upstream/deer-flow problem, and not something the 2.1 upgrade would have
fixed. It is our own compose wiring, present on the current release, independent
of the pin.
