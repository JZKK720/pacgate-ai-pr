# DEFECT: the agent MCP gate could never pass on a run that called a pacgate tool

**Found:** 2026-11-08, running `scripts/test-agent-mcp-e2e.ps1` against the freshly upgraded
0.2.32 stack during the upstream sync.

**Status:** FIXED in `scripts/test-agent-mcp-e2e.ps1` (E1c added, E3 matcher widened).
Red-checked: the fixed gate reports `3 passed` less one assertion (E3 FAIL, exit 1) when the
server-qualified names are removed from the accepted set, and `9 passed, 0 failed` when restored.

## What happened

The gate reported:

```
[FAIL] E3 the run invoked at least one real MCP tool
       no assistant tool_calls record names an advertised MCP tool - the agent replied
       without calling one (a tool name appearing only in the prompt does not count)
```

Everything about that message points at a broken tool loop. The tool loop was working. The
deer-flow log for the same run showed:

```
deerflow.agents.middlewares.deferred_tool_filter_middleware - INFO -
  Auto-promoting deferred tool 'pacgate_pacgate_list_connectors' on first call
httpx - INFO - HTTP Request: POST http://pacgate-mcp:8000/mcp "HTTP/1.1 200 OK"
```

## Root cause

deer-flow records MCP tool calls **server-qualified** as `<serverName>_<toolName>`. The server is
named `pacgate` (in `deer-flow-extensions-config.json`), and the tool is `pacgate_list_connectors`
(in `deploy/pacgate-mcp/server.py`), so the recorded name is the doubled
`pacgate_pacgate_list_connectors`.

E3 compared that recorded name against a list of **bare** names derived from the server source with
`-contains` (exact match). A bare list and a qualified name never intersect, so E3 was
**structurally incapable of passing** on any run that called a pacgate tool.

## Why this is worse than a gate that cannot fail

A gate that always passes hides regressions. This one always FAILED, and its failure message
asserts the exact opposite of the truth - "the agent replied without calling one" - which is the
same sentence a genuine tool-loop regression produces. Anyone reading it would start debugging
the agent instead of the gate.

It also arrived with the 2026-11-05 fix (E3 was correctly tightened then to read `tool_calls` from
non-human messages instead of scanning free text). That tightening was right and remains right:
before it, the gate matched its own prompt and was green on a 404. What was missed is that the
tightened matcher now compares against live-recorded names, which carry a prefix the source
derivation does not have.

## The fix

1. **E1c** reads the server names from `deploy/client-bundle/deer-flow-extensions-config.json` and
   asserts `pacgate` is present. The prefix is read from live config, not hardcoded, so renaming
   the server changes the accepted names with it, and a config that loses the server fails loudly.
2. **E3** accepts both the qualified (`pacgate_<tool>`) and bare (`<tool>`) forms. Bare is kept so
   the gate still works against a deer-flow that does not namespace, and so a future upstream
   change back to bare names does not produce a false FAIL.

The structured-record discipline from 2026-11-05 is untouched: a call is still read only from
`tool_calls` on a non-human message, never from free text.

## What was checked before calling it a gate defect, not a regression

| Question | Evidence |
|---|---|
| Is the tool loop actually running? | deer-flow log: tool auto-promoted, pacgate-mcp returned 200 for `tools/call` |
| Is this new in 0.2.32? | No - the prefix convention is in the extensions config and the mount, not in the image |
| Are the tools loaded at all? | `Total tools loaded: 7, built-in tools: 3, MCP tools: 42` |
| Is the model refusing to call tools? | No - `called: pacgate_pacgate_list_connectors` once the matcher accepted the real name |
| Is it a residency/CPU problem? | No - `test-ollama-gpu-residency.ps1` reports 100% GPU, and the run completed in ~59 s |
