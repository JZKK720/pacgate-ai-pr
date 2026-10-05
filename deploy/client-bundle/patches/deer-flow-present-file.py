from pathlib import Path
from typing import Annotated, Optional

import httpx
from langchain.tools import InjectedToolCallId, tool
from langchain_core.messages import ToolMessage
from langgraph.config import get_config
from langgraph.types import Command

from deerflow.config.paths import VIRTUAL_PATH_PREFIX, get_paths
from deerflow.runtime.user_context import get_effective_user_id
from deerflow.tools.types import Runtime

OUTPUTS_VIRTUAL_PREFIX = f"{VIRTUAL_PATH_PREFIX}/outputs"

# ══ Pacgate: matter-store publish (design-gap fix 2026-10-05) ════════════════
#
# WHY THIS EXISTS. The per-thread outputs dir that backs the Artifacts panel
# lives in deer-flow's own tree (host-persisted via the ./data/deer-flow
# mount) - so a presented file is durable. But it is INVISIBLE to the matter
# workspace: the pacgate tenants tree (`tenants/<t>/matters/<m>/docs/`) only
# holds explicitly uploaded/attached documents, so a deliverable a lawyer was
# shown in chat is not discoverable from the matter's own view, from any
# other user's session, or through the pacgate API at all.
#
# The remedy piggybacks on a pacgate lane that already exists and is tested:
# `POST /api/documents` (matter-attached upload, exercised by
# `pacgate_upload_document`). After the artifact is registered for the panel,
# this tool mirrors it into the matter document store, so every presented
# deliverable becomes part of the permanent tenant/matter tree and is
# browsable from the matter workspace endpoint alongside operator uploads.
#
# DESIGN RULES.
# - Publish is a COPY: the panel keeps serving the original file; the matter
#   store gains an independent, versioned copy. Deleting either side does not
#   disturb the other.
# - Publish is best-effort by design: if pacgate-api is unreachable, has no
#   matter configured (PACGATE_MATTER_ID empty), or refuses the upload, the
#   panel behavior is UNCHANGED - the user still gets their file. Failures are
#   logged and reported in the tool message, never thrown. The artifact must
#   never become hostage to the metadata lane.
# - The mirrored filename is prefixed `presented-` so matter documents stay
#   distinguishable from operator uploads in the workspace listing.
# ═════════════════════════════════════════════════════════════════════════════

PUBLISHED_FILE_PREFIX = "presented-"


def _pacgate_publish_config() -> dict[str, str]:
    """Read the publish targets from the process env (compose provides them).

    Returns a dict possibly containing:
        base_url    - pacgate-api base URL (PACGATE_API_URL)
        email       - service login email (PACGATE_API_EMAIL)
        password    - service login password (PACGATE_API_PASSWORD)
        jwt_token   - pre-issued token (PACGATE_JWT_TOKEN), used when set
        matter_id   - the matter to publish into (PACGATE_MATTER_ID)
        tenant_id   - the tenant slug (PACGATE_TENANT_ID)

    An empty dict (no PACGATE_API_URL) means publishing is simply disabled.
    """
    env = {
        "base_url": (Path.__module__ and __import__("os").environ.get("PACGATE_API_URL", "")),
        "email": __import__("os").environ.get("PACGATE_API_EMAIL", ""),
        "password": __import__("os").environ.get("PACGATE_API_PASSWORD", ""),
        "jwt_token": __import__("os").environ.get("PACGATE_JWT_TOKEN", ""),
        "matter_id": __import__("os").environ.get("PACGATE_MATTER_ID", ""),
        "tenant_id": __import__("os").environ.get("PACGATE_TENANT_ID", ""),
    }
    return {k: v.strip() for k, v in env.items() if v and v.strip()}


def _pacgate_login(base_url: str, email: str, password: str, timeout: float) -> str:
    """Exchange service credentials for a Bearer token (pacgate-api login)."""
    resp = httpx.post(
        f"{base_url}/api/auth/login",
        json={"email": email, "password": password},
        timeout=timeout,
    )
    resp.raise_for_status()
    token = resp.json().get("token", "")
    if not token:
        raise ValueError("pacgate-api login did not return a token")
    return token


def _pacgate_publish_file(
    file_path: Path,
    matter_id: str,
    timeout: float = 30.0,
) -> dict[str, object]:
    """Upload one presented file into the matter's permanent document store.

    Returns a small result dict:
        published  - True when the copy landed (2xx)
        document_id / version - set on success
        skipped    - present with a reason when publish was intentionally off
        error      - set when the attempt failed (best-effort: never raised)

    The mirrored document is named `presented-<filename>` so matter documents
    stay distinguishable from operator uploads in the workspace listing.
    """
    import base64
    import os

    cfg = _pacgate_publish_config()
    if not cfg:
        return {"published": False, "skipped": "pacgate-api not configured (no PACGATE_API_URL)"}
    if "matter_id" not in cfg:
        return {"published": False, "skipped": "no matter configured (PACGATE_MATTER_ID empty)"}

    try:
        data = file_path.read_bytes()
    except OSError as e:
        return {"published": False, "error": f"cannot read presented file: {e}"}

    b64 = base64.b64encode(data).decode("ascii")
    filename = f"{PUBLISHED_FILE_PREFIX}{file_path.name}"

    try:
        headers = {}
        if cfg.get("jwt_token"):
            headers["Authorization"] = f"Bearer {cfg['jwt_token']}"
        else:
            token = _pacgate_login(cfg["base_url"], cfg["email"], cfg["password"], timeout)
            headers["Authorization"] = f"Bearer {token}"

        # pacgate-api upload takes MULTIPART (axum::Multipart), not JSON - the
        # same contract pacgate_deerflow_adapter.client.upload() already uses
        # successfully. A JSON body gets rejected pre-auth with
        # "Invalid `boundary` for multipart/form-data request".
        resp = httpx.post(
            f"{cfg['base_url']}/api/documents",
            data={"matter_id": matter_id},
            files={"file": (filename, data)},
            headers=headers,
            timeout=timeout,
        )
        if resp.status_code in (401, 403) and cfg.get("email"):
            # One bounded re-login: token could be stale. (No retry loop.)
            token = _pacgate_login(cfg["base_url"], cfg["email"], cfg["password"], timeout)
            headers["Authorization"] = f"Bearer {token}"
            resp = httpx.post(
                f"{cfg['base_url']}/api/documents",
                data={"matter_id": matter_id},
                files={"file": (filename, data)},
                headers=headers,
                timeout=timeout,
            )
        resp.raise_for_status()
        body = resp.json()
        return {
            "published": True,
            "document_id": body.get("id"),
            "version": body.get("version"),
            "matter_document_name": filename,
            "matter_id": matter_id,
        }
    except Exception as e:  # noqa: BLE001 - best-effort by design
        return {"published": False, "error": f"pacgate publish failed: {e}"}


def _get_thread_id(runtime: Runtime) -> str | None:
    """Resolve the current thread id from runtime context or RunnableConfig."""
    thread_id = runtime.context.get("thread_id") if runtime.context else None
    if thread_id:
        return thread_id

    runtime_config = getattr(runtime, "config", None) or {}
    thread_id = runtime_config.get("configurable", {}).get("thread_id")
    if thread_id:
        return thread_id

    try:
        return get_config().get("configurable", {}).get("thread_id")
    except RuntimeError:
        return None


def _normalize_presented_filepath(
    runtime: Runtime,
    filepath: str,
) -> str:
    """Normalize a presented file path to the `/mnt/user-data/outputs/*` contract.

    Accepts either:
    - A virtual sandbox path such as `/mnt/user-data/outputs/report.md`
    - A host-side thread outputs path such as
      `/app/backend/.deer-flow/threads/<thread>/user-data/outputs/report.md`

    Returns:
        The normalized virtual path.

    Raises:
        ValueError: If runtime metadata is missing or the path is outside the
            current thread's outputs directory.
    """
    if runtime.state is None:
        raise ValueError("Thread runtime state is not available")

    thread_id = _get_thread_id(runtime)
    if not thread_id:
        raise ValueError("Thread ID is not available in runtime context or runtime config")

    thread_data = runtime.state.get("thread_data") or {}
    outputs_path = thread_data.get("outputs_path")
    if not outputs_path:
        raise ValueError("Thread outputs path is not available in runtime state")

    outputs_dir = Path(outputs_path).resolve()
    stripped = filepath.lstrip("/")
    virtual_prefix = VIRTUAL_PATH_PREFIX.lstrip("/")

    if stripped == virtual_prefix or stripped.startswith(virtual_prefix + "/"):
        try:
            actual_path = get_paths().resolve_virtual_path(thread_id, filepath, user_id=get_effective_user_id())
        except TypeError:
            actual_path = get_paths().resolve_virtual_path(thread_id, filepath)
    else:
        actual_path = Path(filepath).expanduser().resolve()

    try:
        relative_path = actual_path.relative_to(outputs_dir)
    except ValueError as exc:
        raise ValueError(f"Only files in {OUTPUTS_VIRTUAL_PREFIX} can be presented: {filepath}") from exc

    return f"{OUTPUTS_VIRTUAL_PREFIX}/{relative_path.as_posix()}"


@tool("present_files", parse_docstring=True)
def present_file_tool(
    runtime: Runtime,
    filepaths: list[str],
    tool_call_id: Annotated[str, InjectedToolCallId],
) -> Command:
    """Make files visible to the user for viewing and rendering in the client interface, and publish a copy to the matter's permanent document store.

    When to use the present_files tool:

    - Making any file available for the user to view, download, or interact with
    - Presenting multiple related files at once
    - After creating files that should be presented to the user

    When NOT to use the present_files tool:
    - When you only need to read file contents for your own processing
    - For temporary or intermediate files not meant for user viewing

    Notes:
    - You should call this tool after creating files and moving them to the `/mnt/user-data/outputs` directory.
    - This tool can be safely called in parallel with other tools. State updates are handled by a reducer to prevent conflicts.
    - Pacgate: each presented file is ALSO copied into the matter's permanent
      document store (PACGATE_MATTER_ID), making it discoverable from the
      matter workspace alongside operator uploads. The copy is named
      `presented-<filename>`; a failure there never blocks presenting.

    Args:
        filepaths: List of absolute file paths to present to the user. **Only** files in `/mnt/user-data/outputs` can be presented.
    """
    try:
        normalized_paths = [_normalize_presented_filepath(runtime, filepath) for filepath in filepaths]
    except ValueError as exc:
        return Command(
            update={"messages": [ToolMessage(f"Error: {exc}", tool_call_id=tool_call_id)]},
        )

    # ── Pacgate: best-effort mirror into the matter document store ──────────
    # Resolves each presented file's HOST-side path (the normalized virtual
    # path maps back to the per-thread outputs dir), then uploads a copy.
    publish_notes: list[str] = []
    cfg_matter = _pacgate_publish_config().get("matter_id", "")
    if cfg_matter:
        try:
            outputs_dir = Path(
                (runtime.state.get("thread_data") or {}).get("outputs_path", "")
            ).resolve()
        except Exception:  # noqa: BLE001 - resolve failures disable publishing
            outputs_dir = None

        for normalized in normalized_paths:
            try:
                relative = normalized.removeprefix(f"{OUTPUTS_VIRTUAL_PREFIX}/")
                host_path = outputs_dir / relative if outputs_dir else None
                if not host_path or not host_path.is_file():
                    publish_notes.append(f"pacgate: could not locate {relative} on host")
                    continue
                result = _pacgate_publish_file(host_path, cfg_matter)
                if result.get("published"):
                    publish_notes.append(
                        f"pacgate: {normalized.rsplit('/', 1)[-1]} -> matter "
                        f"document {result.get('document_id')} (v{result.get('version')})"
                    )
                elif result.get("skipped"):
                    publish_notes.append(f"pacgate: skipped ({result['skipped']})")
                else:
                    publish_notes.append(f"pacgate: {result.get('error')}")
            except Exception as e:  # noqa: BLE001 - never block presenting
                publish_notes.append(f"pacgate publish failed: {e}")

    message = "Successfully presented files"
    if publish_notes:
        message += "\n" + "\n".join(publish_notes)

    # The merge_artifacts reducer will handle merging and deduplication
    return Command(
        update={
            "artifacts": normalized_paths,
            "messages": [ToolMessage(message, tool_call_id=tool_call_id)],
        },
    )