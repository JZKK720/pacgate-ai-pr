from __future__ import annotations

import argparse
import json
import os
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable
from urllib import error as urllib_error
from urllib import parse as urllib_parse
from urllib import request as urllib_request


JsonRequestor = Callable[["RuntimeConfig", str, str, str | None, dict[str, Any] | None], Any]


class PacgateToolError(RuntimeError):
    pass


@dataclass(frozen=True)
class RuntimeConfig:
    api_url: str
    token: str | None = None
    email: str | None = None
    password: str | None = None


@dataclass(frozen=True)
class ScopeContext:
    org_id: str
    org_name: str | None = None
    channel_id: str | None = None
    channel_name: str | None = None
    team_id: str | None = None
    team_name: str | None = None
    personal_user_id: str | None = None
    personal_email: str | None = None
    pacgate_matter_id: str | None = None


def normalize_api_url(url: str) -> str:
    return url.rstrip("/")


def load_config(environ: dict[str, str] | None = None) -> RuntimeConfig:
    env = environ or os.environ
    api_url = env.get("PACGATE_API_URL", "").strip()
    if not api_url:
        raise PacgateToolError("PACGATE_API_URL is required")

    token = env.get("PACGATE_API_TOKEN", "").strip() or None
    email = env.get("PACGATE_API_EMAIL", "").strip() or None
    password = env.get("PACGATE_API_PASSWORD", "").strip() or None

    if not token and not (email and password):
        raise PacgateToolError(
            "Set PACGATE_API_TOKEN, or set both PACGATE_API_EMAIL and PACGATE_API_PASSWORD"
        )

    return RuntimeConfig(
        api_url=normalize_api_url(api_url),
        token=token,
        email=email,
        password=password,
    )


def derive_matter_name(scope: ScopeContext) -> str:
    if scope.channel_name and scope.channel_name.strip():
        return scope.channel_name.strip()
    if scope.channel_id and scope.channel_id.strip():
        return f"QM Channel {scope.channel_id.strip()}"
    raise PacgateToolError("QM scope needs channel-name or channel-id to map to a Pacgate matter")


def build_matter_description(scope: ScopeContext, extra_description: str | None = None) -> str:
    lines = [
        "Linked QM scope",
        f"qm.orgId={scope.org_id}",
        f"qm.channelId={scope.channel_id or ''}",
        f"qm.teamId={scope.team_id or ''}",
        f"qm.personalUserId={scope.personal_user_id or ''}",
        f"qm.personalEmail={scope.personal_email or ''}",
    ]
    if extra_description and extra_description.strip():
        lines.extend(["", extra_description.strip()])
    return "\n".join(lines)


def matches_existing_matter(matter: dict[str, Any], scope: ScopeContext) -> bool:
    if scope.pacgate_matter_id and matter.get("id") == scope.pacgate_matter_id:
        return True
    if scope.channel_id and matter.get("external_key") == scope.channel_id:
        return True
    if not scope.channel_id and scope.channel_name and matter.get("name") == scope.channel_name.strip():
        return True
    return False


def request_json(
    config: RuntimeConfig,
    method: str,
    path: str,
    token: str | None,
    payload: dict[str, Any] | None = None,
) -> Any:
    url = f"{config.api_url}{path}"
    headers = {"Content-Type": "application/json"}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    data = json.dumps(payload).encode("utf-8") if payload is not None else None
    req = urllib_request.Request(url, data=data, headers=headers, method=method)

    try:
        with urllib_request.urlopen(req) as response:
            raw = response.read().decode("utf-8")
    except urllib_error.HTTPError as exc:
        body = exc.read().decode("utf-8", errors="replace")
        raise PacgateToolError(f"Pacgate API {exc.code} {path}: {body}") from exc
    except urllib_error.URLError as exc:
        raise PacgateToolError(f"Unable to reach Pacgate API at {url}: {exc.reason}") from exc

    if not raw:
        return None
    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        raise PacgateToolError(f"Pacgate API returned invalid JSON for {path}") from exc


def resolve_token(config: RuntimeConfig, requestor: JsonRequestor = request_json) -> str:
    if config.token:
        return config.token

    if not config.email or not config.password:
        raise PacgateToolError(
            "Missing Pacgate credentials: set PACGATE_API_TOKEN or PACGATE_API_EMAIL/PACGATE_API_PASSWORD"
        )

    response = requestor(
        config,
        "POST",
        "/api/auth/login",
        None,
        {"email": config.email, "password": config.password},
    )
    token = response.get("token") if isinstance(response, dict) else None
    if not token:
        raise PacgateToolError("Pacgate login response did not include a token")
    return token


def ensure_matter_for_scope(
    config: RuntimeConfig,
    scope: ScopeContext,
    *,
    persona_id: str | None = None,
    description: str | None = None,
    requestor: JsonRequestor = request_json,
) -> dict[str, Any]:
    token = resolve_token(config, requestor)
    matters = requestor(config, "GET", "/api/matters", token, None)
    if not isinstance(matters, list):
        raise PacgateToolError("Pacgate /api/matters response must be a JSON array")

    for matter in matters:
        if isinstance(matter, dict) and matches_existing_matter(matter, scope):
            return matter

    payload: dict[str, Any] = {
        "name": derive_matter_name(scope),
        "description": build_matter_description(scope, description),
    }
    if scope.channel_id and scope.channel_id.strip():
        payload["external_key"] = scope.channel_id.strip()
    if persona_id:
        payload["persona_id"] = persona_id

    created = requestor(config, "POST", "/api/matters", token, payload)
    if not isinstance(created, dict):
        raise PacgateToolError("Pacgate matter creation response must be a JSON object")
    return created


def list_workflow_categories(
    config: RuntimeConfig,
    *,
    requestor: JsonRequestor = request_json,
) -> Any:
    token = resolve_token(config, requestor)
    return requestor(config, "GET", "/api/workflows/categories", token, None)


def list_workflows(
    config: RuntimeConfig,
    *,
    category: str | None = None,
    search: str | None = None,
    requestor: JsonRequestor = request_json,
) -> Any:
    token = resolve_token(config, requestor)
    params: dict[str, str] = {}
    if category:
        params["category"] = category
    if search:
        params["search"] = search
    suffix = f"?{urllib_parse.urlencode(params)}" if params else ""
    return requestor(config, "GET", f"/api/workflows{suffix}", token, None)


def get_workflow(
    config: RuntimeConfig,
    workflow_id: str,
    *,
    requestor: JsonRequestor = request_json,
) -> Any:
    token = resolve_token(config, requestor)
    return requestor(config, "GET", f"/api/workflows/{workflow_id}", token, None)


def get_matter_memory(
    config: RuntimeConfig,
    matter_id: str,
    *,
    requestor: JsonRequestor = request_json,
) -> Any:
    token = resolve_token(config, requestor)
    return requestor(config, "GET", f"/api/matters/{matter_id}/memory", token, None)


def save_matter_memory(
    config: RuntimeConfig,
    matter_id: str,
    memory: dict[str, Any],
    *,
    requestor: JsonRequestor = request_json,
) -> Any:
    token = resolve_token(config, requestor)
    return requestor(config, "POST", f"/api/matters/{matter_id}/memory", token, memory)


def execute_workflow_for_scope(
    config: RuntimeConfig,
    scope: ScopeContext,
    *,
    workflow_id: str,
    persona_id: str | None = None,
    description: str | None = None,
    requestor: JsonRequestor = request_json,
) -> Any:
    token = resolve_token(config, requestor)
    matter = ensure_matter_for_scope(
        config,
        scope,
        persona_id=persona_id,
        description=description,
        requestor=requestor,
    )
    payload: dict[str, Any] = {"matter_id": matter["id"]}
    if persona_id:
        payload["persona_id"] = persona_id
    return requestor(config, "POST", f"/api/workflows/{workflow_id}/execute", token, payload)


def parse_memory_json(spec: str) -> dict[str, Any]:
    if spec == "-":
        text = sys.stdin.read()
    elif spec.startswith("@"):
        text = Path(spec[1:]).read_text(encoding="utf-8")
    else:
        text = spec

    data = json.loads(text)
    if not isinstance(data, dict):
        raise PacgateToolError("Memory payload must decode to a JSON object")
    return data


def add_scope_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--org-id")
    parser.add_argument("--org-name")
    parser.add_argument("--channel-id")
    parser.add_argument("--channel-name")
    parser.add_argument("--team-id")
    parser.add_argument("--team-name")
    parser.add_argument("--personal-user-id")
    parser.add_argument("--personal-email")
    parser.add_argument("--pacgate-matter-id")


def scope_from_args(args: argparse.Namespace) -> ScopeContext:
    org_id = (args.org_id or "").strip()
    if not org_id:
        raise PacgateToolError("--org-id is required for scope-based Pacgate commands")

    if not (args.channel_id or args.channel_name or args.pacgate_matter_id):
        raise PacgateToolError(
            "Provide at least one of --channel-id, --channel-name, or --pacgate-matter-id"
        )

    return ScopeContext(
        org_id=org_id,
        org_name=args.org_name,
        channel_id=args.channel_id,
        channel_name=args.channel_name,
        team_id=args.team_id,
        team_name=args.team_name,
        personal_user_id=args.personal_user_id,
        personal_email=args.personal_email,
        pacgate_matter_id=args.pacgate_matter_id,
    )


def matter_id_from_args(
    config: RuntimeConfig,
    args: argparse.Namespace,
    *,
    requestor: JsonRequestor = request_json,
) -> str:
    if args.matter_id:
        return args.matter_id
    matter = ensure_matter_for_scope(
        config,
        scope_from_args(args),
        persona_id=getattr(args, "persona_id", None),
        description=getattr(args, "description", None),
        requestor=requestor,
    )
    matter_id = matter.get("id")
    if not isinstance(matter_id, str) or not matter_id:
        raise PacgateToolError("Resolved Pacgate matter is missing an id")
    return matter_id


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="QM sandbox bridge for Pacgate workflows and matter memory")
    subparsers = parser.add_subparsers(dest="command", required=True)

    subparsers.add_parser("workflow-categories")

    workflows = subparsers.add_parser("workflows")
    workflows.add_argument("--category")
    workflows.add_argument("--search")

    workflow = subparsers.add_parser("workflow")
    workflow.add_argument("workflow_id")

    ensure = subparsers.add_parser("ensure-matter")
    add_scope_args(ensure)
    ensure.add_argument("--persona-id")
    ensure.add_argument("--description")

    memory_get = subparsers.add_parser("memory-get")
    memory_get.add_argument("--matter-id")
    add_scope_args(memory_get)
    memory_get.add_argument("--persona-id")
    memory_get.add_argument("--description")

    memory_save = subparsers.add_parser("memory-save")
    memory_save.add_argument("--matter-id")
    add_scope_args(memory_save)
    memory_save.add_argument("--persona-id")
    memory_save.add_argument("--description")
    memory_save.add_argument("--memory-json", required=True)

    execute = subparsers.add_parser("execute-workflow")
    add_scope_args(execute)
    execute.add_argument("--workflow-id", required=True)
    execute.add_argument("--persona-id")
    execute.add_argument("--description")

    return parser


def dispatch(args: argparse.Namespace, config: RuntimeConfig) -> Any:
    if args.command == "workflow-categories":
        return list_workflow_categories(config)
    if args.command == "workflows":
        return list_workflows(config, category=args.category, search=args.search)
    if args.command == "workflow":
        return get_workflow(config, args.workflow_id)
    if args.command == "ensure-matter":
        return ensure_matter_for_scope(
            config,
            scope_from_args(args),
            persona_id=args.persona_id,
            description=args.description,
        )
    if args.command == "memory-get":
        return get_matter_memory(config, matter_id_from_args(config, args))
    if args.command == "memory-save":
        return save_matter_memory(
            config,
            matter_id_from_args(config, args),
            parse_memory_json(args.memory_json),
        )
    if args.command == "execute-workflow":
        return execute_workflow_for_scope(
            config,
            scope_from_args(args),
            workflow_id=args.workflow_id,
            persona_id=args.persona_id,
            description=args.description,
        )
    raise PacgateToolError(f"Unknown command: {args.command}")


def main(argv: list[str] | None = None, environ: dict[str, str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    try:
        config = load_config(environ)
        result = dispatch(args, config)
    except PacgateToolError as exc:
        print(f"pacgate-qm: {exc}", file=sys.stderr)
        return 2

    print(json.dumps(result, ensure_ascii=False, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())