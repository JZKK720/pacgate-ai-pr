import logging
import mimetypes
import zipfile
from pathlib import Path
from urllib.parse import quote

from fastapi import APIRouter, HTTPException, Request
from fastapi.responses import FileResponse, PlainTextResponse, Response

from app.gateway.authz import require_permission
from app.gateway.path_utils import resolve_thread_virtual_path
from deerflow.config.paths import VIRTUAL_PATH_PREFIX, get_paths
from deerflow.runtime.user_context import get_effective_user_id
from deerflow.uploads.manager import list_files_in_dir

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/api", tags=["artifacts"])

ACTIVE_CONTENT_MIME_TYPES = {
    "text/html",
    "application/xhtml+xml",
    "image/svg+xml",
}

MAX_SKILL_ARCHIVE_MEMBER_BYTES = 16 * 1024 * 1024
_SKILL_ARCHIVE_READ_CHUNK_SIZE = 64 * 1024

OUTPUTS_VIRTUAL_PREFIX = f"{VIRTUAL_PATH_PREFIX}/outputs"


def _build_content_disposition(disposition_type: str, filename: str) -> str:
    """Build an RFC 5987 encoded Content-Disposition header value."""
    return f"{disposition_type}; filename*=UTF-8''{quote(filename)}"


def _build_attachment_headers(filename: str, extra_headers: dict[str, str] | None = None) -> dict[str, str]:
    headers = {"Content-Disposition": _build_content_disposition("attachment", filename)}
    if extra_headers:
        headers.update(extra_headers)
    return headers


def _outputs_artifact_url(thread_id: str, filename: str) -> str:
    """Build the artifact URL for a generated output file.

    *filename* is percent-encoded so that spaces, ``#``, ``?`` etc. are safe.
    """
    return f"/api/threads/{thread_id}/artifacts{OUTPUTS_VIRTUAL_PREFIX}/{quote(filename, safe='')}"


def _outputs_virtual_path(filename: str) -> str:
    """Build the virtual path for a generated output file."""
    return f"{OUTPUTS_VIRTUAL_PREFIX}/{filename}"


def _enrich_outputs_listing(result: dict, thread_id: str) -> dict:
    """Add virtual paths and artifact URLs on an outputs listing result."""
    for f in result["files"]:
        filename = f["filename"]
        f["virtual_path"] = _outputs_virtual_path(filename)
        f["artifact_url"] = _outputs_artifact_url(thread_id, filename)
    return result


@router.get(
    "/threads/{thread_id}/outputs",
    summary="List Generated Outputs",
    description="List all files the AI agent has generated in the thread's outputs "
    "directory (mounted as /mnt/user-data/outputs). Returns filenames, sizes, "
    "virtual paths, and artifact URLs for direct access/download.",
)
@require_permission("threads", "read", owner_check=True)
async def list_outputs(thread_id: str, request: Request) -> dict:
    """List all generated output files for a thread.

    Mirrors the uploads listing API but reads from ``sandbox_outputs_dir``
    (``/mnt/user-data/outputs``) where the ``present_files`` tool writes
    agent-generated documents (docx, pdf, md, csv, etc.).
    """
    try:
        outputs_dir = get_paths().sandbox_outputs_dir(thread_id, user_id=get_effective_user_id())
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e))

    result = list_files_in_dir(outputs_dir)

    # Drop internal tool-result scratch files (e.g. .tool-results/*) from the
    # user-facing listing so only real deliverables are surfaced.
    files = [
        f for f in result["files"]
        if not f["filename"].startswith(".") and "/.tool-results/" not in f["path"]
    ]
    result["files"] = files
    result["count"] = len(files)

    _enrich_outputs_listing(result, thread_id)
    return result


def is_text_file_by_content(path: Path, sample_size: int = 8192) -> bool:
    """Check if file is text by examining content for null bytes."""
    try:
        with open(path, "rb") as f:
            chunk = f.read(sample_size)
            # Text files shouldn't contain null bytes
            return b"\x00" not in chunk
    except Exception:
        return False


def _read_skill_archive_member(zip_ref: zipfile.ZipFile, info: zipfile.ZipInfo) -> bytes:
    """Read a .skill archive member while enforcing an uncompressed size cap."""
    if info.file_size > MAX_SKILL_ARCHIVE_MEMBER_BYTES:
        raise HTTPException(status_code=413, detail="Skill archive member is too large to preview")

    chunks: list[bytes] = []
    total_read = 0
    with zip_ref.open(info, "r") as src:
        while chunk := src.read(_SKILL_ARCHIVE_READ_CHUNK_SIZE):
            total_read += len(chunk)
            if total_read > MAX_SKILL_ARCHIVE_MEMBER_BYTES:
                raise HTTPException(status_code=413, detail="Skill archive member is too large to preview")
            chunks.append(chunk)
    return b"".join(chunks)


def _extract_file_from_skill_archive(zip_path: Path, internal_path: str) -> bytes | None:
    """Extract a file from a .skill ZIP archive.

    Args:
        zip_path: Path to the .skill file (ZIP archive).
        internal_path: Path to the file inside the archive (e.g., "SKILL.md").

    Returns:
        The file content as bytes, or None if not found.
    """
    if not zipfile.is_zipfile(zip_path):
        return None

    try:
        with zipfile.ZipFile(zip_path, "r") as zip_ref:
            # List all files in the archive
            infos_by_name = {info.filename: info for info in zip_ref.infolist()}

            # Try direct path first
            if internal_path in infos_by_name:
                return _read_skill_archive_member(zip_ref, infos_by_name[internal_path])

            # Try with any top-level directory prefix (e.g., "skill-name/SKILL.md")
            for name, info in infos_by_name.items():
                if name.endswith("/" + internal_path) or name == internal_path:
                    return _read_skill_archive_member(zip_ref, info)

            # Not found
            return None
    except (zipfile.BadZipFile, KeyError):
        return None


@router.get(
    "/threads/{thread_id}/artifacts/{path:path}",
    summary="Get Artifact File",
    description="Retrieve an artifact file generated by the AI agent. Text and binary files can be viewed inline, while active web content is always downloaded.",
)
@require_permission("threads", "read", owner_check=True)
async def get_artifact(thread_id: str, path: str, request: Request, download: bool = False) -> Response:
    """Get an artifact file by its path.

    The endpoint automatically detects file types and returns appropriate content types.
    Use the `download` query parameter to force file download for non-active content.
    """
    # Check if this is a request for a file inside a .skill archive (e.g., xxx.skill/SKILL.md)
    if ".skill/" in path:
        skill_marker = ".skill/"
        marker_pos = path.find(skill_marker)
        skill_file_path = path[: marker_pos + len(".skill")]
        internal_path = path[marker_pos + len(".skill"):]

        actual_skill_path = resolve_thread_virtual_path(thread_id, skill_file_path)

        if not actual_skill_path.exists():
            raise HTTPException(status_code=404, detail=f"Skill file not found: {skill_file_path}")

        if not actual_skill_path.is_file():
            raise HTTPException(status_code=400, detail=f"Path is not a file: {skill_file_path}")

        content = _extract_file_from_skill_archive(actual_skill_path, internal_path)
        if content is None:
            raise HTTPException(status_code=404, detail=f"File '{internal_path}' not found in skill archive")

        mime_type, _ = mimetypes.guess_type(internal_path)
        cache_headers = {"Cache-Control": "private, max-age=300"}
        download_name = Path(internal_path).name or actual_skill_path.stem
        if download or mime_type in ACTIVE_CONTENT_MIME_TYPES:
            return Response(content=content, media_type=mime_type or "application/octet-stream", headers=_build_attachment_headers(download_name, cache_headers))

        if mime_type and mime_type.startswith("text/"):
            return PlainTextResponse(content=content.decode("utf-8"), media_type=mime_type, headers=cache_headers)

        try:
            return PlainTextResponse(content=content.decode("utf-8"), media_type="text/plain", headers=cache_headers)
        except UnicodeDecodeError:
            return Response(content=content, media_type=mime_type or "application/octet-stream", headers=cache_headers)

    actual_path = resolve_thread_virtual_path(thread_id, path)

    logger.info(f"Resolving artifact path: thread_id={thread_id}, requested_path={path}, actual_path={actual_path}")

    if not actual_path.exists():
        raise HTTPException(status_code=404, detail=f"Artifact not found: {path}")

    if not actual_path.is_file():
        raise HTTPException(status_code=400, detail=f"Path is not a file: {path}")

    mime_type, _ = mimetypes.guess_type(actual_path)

    if download:
        return FileResponse(path=actual_path, filename=actual_path.name, media_type=mime_type, headers=_build_attachment_headers(actual_path.name))
    # Always force download for active content types to prevent script execution
    # in the application origin when users open generated artifacts.
    if mime_type in ACTIVE_CONTENT_MIME_TYPES:
        return FileResponse(path=actual_path, filename=actual_path.name, media_type=mime_type, headers=_build_attachment_headers(actual_path.name))
    if mime_type and mime_type.startswith("text/"):
        return PlainTextResponse(content=actual_path.read_text(encoding="utf-8"), media_type=mime_type)
    if is_text_file_by_content(actual_path):
        return PlainTextResponse(content=actual_path.read_text(encoding="utf-8"), media_type=mime_type)
    return Response(content=actual_path.read_bytes(), media_type=mime_type, headers={"Content-Disposition": _build_content_disposition("inline", actual_path.name)})
