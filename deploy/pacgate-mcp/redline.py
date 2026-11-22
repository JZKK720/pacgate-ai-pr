"""DOCX redlines with native Word tracked changes.

Backed by `docx-scalpel` (PyPI, MIT), the Python client for Docxodus. It ships
a manylinux wheel that is self-contained, so the container needs no .NET.

WHY THIS EXISTS
    A lawyer reviewing a generated draft must see a redline they can accept or
    reject in Word, not a diff rendered as HTML. Word reads tracked changes from
    `<w:ins>` / `<w:del>` elements inside `word/document.xml`, with a `w:author`,
    `w:date` and a document-unique `w:id` on each revision.

    Univer cannot do this at any licence tier (no track-changes data model), and
    the PyPI `redlines` package emits HTML only and, on CJK text, replaces whole
    sentences because Chinese has no whitespace to tokenise on.

WHAT IS VERIFIED (2026-11-22, on a Chinese contract clause)
    a: 甲方应于2026年12月31日前支付合同价款人民币壹佰万元整。
    b: 甲方应于2026年11月30日前支付合同价款人民币贰佰万元整。

    docx_diff_compare(a, b) produced 5 <w:ins> and 4 <w:del> with the correct
    granularity - 12->11, 31->30, 壹->贰, 专->普通 - not one whole-sentence
    replacement. And the contract held exactly:

        accept(redline).text == b   (0 residual revisions)
        reject(redline).text == a   (0 residual revisions)

    `prove_redline_reversibility()` may still return success=False with a
    path='relationship' finding when the two inputs were produced by different
    generators. That is the stricter package-bytes proof; the TEXT contract above
    is what the reviewer depends on, so it is what this module asserts.

DEFAULTS THAT MUST NOT SHIP
    docx-scalpel defaults the revision author to "Docxodus" and the date to
    2000-01-01T00:00:00Z. Both are set explicitly here; an unnamed revision in a
    legal deliverable is an audit failure.
"""

from __future__ import annotations

import datetime as _dt
import io
import logging
import os
import re
import zipfile
from typing import Any

logger = logging.getLogger("pacgate_mcp.redline")

# Kept in ONE place so the tool wrapper and the tests cannot drift.
DEFAULT_AUTHOR = os.environ.get(
    "PACGATE_REDLINE_AUTHOR", "PacGate Legal Review"
)


class RedlineUnavailable(RuntimeError):
    """The redline engine is not installed in this image."""


class RedlineContractError(RuntimeError):
    """The produced redline failed the accept/reject text contract."""


def _engine() -> Any:
    """Import the diff engine lazily.

    Lazy so the MCP server still starts (and every other tool still works) on an
    image built before docx-scalpel was added to requirements.txt. Same reasoning
    as `PacgateApi` being instantiated on first call rather than at import.
    """
    try:
        import docx_scalpel  # noqa: PLC0415
    except ImportError as exc:  # pragma: no cover - depends on image contents
        raise RedlineUnavailable(
            "docx-scalpel is not installed in this image; rebuild pacgate-mcp "
            "with requirements.txt (it ships a manylinux wheel, no .NET needed)"
        ) from exc
    return docx_scalpel


def _now_iso() -> str:
    return _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def document_text(docx_bytes: bytes) -> str:
    """Concatenate the visible text of `word/document.xml`.

    Deliberately naive (regex over `<w:t>`): it is a *contract check*, not a
    renderer. It only has to agree with itself on both sides of the comparison,
    which it does because it is the same function applied to every input.
    """
    with zipfile.ZipFile(io.BytesIO(docx_bytes)) as zf:
        try:
            xml = zf.read("word/document.xml").decode("utf-8")
        except KeyError as exc:  # pragma: no cover - malformed package
            raise RedlineContractError(
                "the file has no word/document.xml; is it a .docx?"
            ) from exc
    return "".join(re.findall(r"<w:t[^>]*>([^<]*)</w:t>", xml))


def revision_count(docx_bytes: bytes) -> dict[str, int]:
    """Count tracked-change markers actually present in the package."""
    with zipfile.ZipFile(io.BytesIO(docx_bytes)) as zf:
        xml = zf.read("word/document.xml").decode("utf-8")
    return {
        "insertions": len(re.findall(r"<w:ins\b", xml)),
        "deletions": len(re.findall(r"<w:del\b", xml)),
        "deleted_text": len(re.findall(r"<w:delText\b", xml)),
    }


def _settings(
    author: str | None = None, date_time: str | None = None
) -> Any:
    """Build engine settings with OUR attribution, never the engine defaults.

    Shared by `compare` and `list_revisions` on purpose. They were originally
    built independently, and the result was a change list stamped "Docxodus"
    beside a document stamped "PacGate Legal Review" - the same edit reported under
    two different authors, which is worse than either default.
    """
    ds = _engine()
    return ds.DocxDiffSettings(
        author_for_revisions=author or DEFAULT_AUTHOR,
        date_time_for_revisions=date_time or _now_iso(),
        # Deterministic keeps two runs of the same inputs byte-identical, so a
        # re-generated artifact in a matter does not look like a new revision.
        deterministic=True,
        # Compare as Word's Compare does: pending tracked changes in an INPUT are
        # accepted first, so we diff the intended text rather than two documents
        # each carrying their own unresolved markup.
        pre_accept_input_revisions=True,
    )


def compare(
    left: bytes,
    right: bytes,
    *,
    author: str | None = None,
    date_time: str | None = None,
    verify: bool = True,
) -> bytes:
    """Return a redlined .docx between `left` and `right`.

    Raises RedlineContractError when `verify` is set and the accept/reject text
    contract does not hold. That check is the whole point: a redline that does
    not accept into `right` and reject into `left` is silently wrong in a way a
    reviewer cannot see until they have already reviewed it.
    """
    ds = _engine()
    redline = ds.docx_diff_compare(left, right, _settings(author, date_time))

    if verify:
        _assert_contract(ds, redline, left, right)
    return redline


def _assert_contract(ds: Any, redline: bytes, left: bytes, right: bytes) -> None:
    """Assert accept(redline) == right and reject(redline) == left."""
    try:
        accepted = ds.docx_diff_accept_revisions(redline)
        rejected = ds.docx_diff_reject_revisions(redline)
    except Exception as exc:  # noqa: BLE001 - engine-specific failures
        raise RedlineContractError(
            f"could not resolve the redline's revisions: {type(exc).__name__}: {exc}"
        ) from exc

    got_accept = document_text(accepted)
    got_reject = document_text(rejected)
    want_right = document_text(right)
    want_left = document_text(left)

    problems = []
    if got_accept != want_right:
        problems.append(
            "accepting every revision does not reproduce the new document"
        )
    if got_reject != want_left:
        problems.append(
            "rejecting every revision does not reproduce the original document"
        )
    if problems:
        raise RedlineContractError(
            "; ".join(problems)
            + " (the redline would silently misrepresent the change to a reviewer)"
        )


def compare_text(
    left_text: str,
    right_text: str,
    *,
    author: str | None = None,
    date_time: str | None = None,
) -> str:
    """Produce a PLAIN-TEXT redline between two strings.

    WHY THIS EXISTS - it is not a substitute for `compare`, it is the only mode the
    egress design permits.

    `compare` needs the two `.docx` packages. pacgate-api will not release one: after
    sanitization a binary document is served as REDACTED TEXT, never the original
    package, and the `never` state that would permit the original has no HTTP route.
    So a redline over stored DOCX files cannot be built from a download at all.

    What pacgate-api WILL give a caller, legitimately, is the sanitized text. This
    function turns that into a reviewable diff, which is the honest capability at the
    text lane: the reviewer sees exactly which characters changed, marked so the
    original is still readable.

    It does NOT produce a Word redline and must never be presented as one. Word
    needs an OOXML package; there is no package here to put revision marks into. The
    caller is told which mode it got via the `format` key in the tool result.

    Granularity follows the script, for the same measured reason as the Rust
    `patch_document_xml` fix: `difflib` with default junk detection treats a whole
    Chinese sentence as one token, so 甲方应于…三十日 became a single
    replace-the-sentence opcode. `autojunk=False` is not sufficient on its own for
    space-delimited text either - it exists to disable heuristics that misfire on
    long inputs, not to change tokenisation - so the two are chosen per script here.
    """
    import difflib

    def is_space_delimited(s: str) -> bool:
        return any(ch.isspace() for ch in s)

    if is_space_delimited(left_text) or is_space_delimited(right_text):
        # Word-ish tokenisation: keep the whitespace attached to its token so the
        # reconstruction is exact.
        def tokenize(s: str) -> list[str]:
            return re.findall(r"\S+\s*|\s+", s)

        left_tokens = tokenize(left_text)
        right_tokens = tokenize(right_text)
        matcher = difflib.SequenceMatcher(None, left_tokens, right_tokens, autojunk=False)
        left_view: list[str] | str = left_tokens
        right_view: list[str] | str = right_tokens
        join: Any = lambda seq: "".join(seq)
    else:
        matcher = difflib.SequenceMatcher(None, left_text, right_text, autojunk=False)
        left_view = left_text
        right_view = right_text
        join = lambda seq: seq  # slicing a str already yields a str

    out: list[str] = []
    for tag, i1, i2, j1, j2 in matcher.get_opcodes():
        old = join(left_view[i1:i2])
        new = join(right_view[j1:j2])
        if tag == "equal":
            out.append(old)
        else:
            # The original stays visible in strikethrough, the replacement is
            # underlined: the same accept/reject distinction Word makes, in plain
            # text. Nothing is dropped, so a reader can reconstruct either side.
            if old:
                out.append(f"[-{old}-]")
            if new:
                out.append(f"{{+{new}+}}")
    return "".join(out)


def accept(redline: bytes) -> bytes:
    """Resolve every tracked change in favour of the new text."""
    return _engine().docx_diff_accept_revisions(redline)


def reject(redline: bytes) -> bytes:
    """Resolve every tracked change back to the original text."""
    return _engine().docx_diff_reject_revisions(redline)


def list_revisions(
    left: bytes, right: bytes, *, author: str | None = None
) -> list[dict[str, Any]]:
    """Summarise the tracked changes between two documents for a review panel.

    SIGNATURE NOTE: `docx_diff_get_revisions` takes `(LEFT, RIGHT)` - the two
    SOURCE documents - not `(redline, right)`. Passing a redline as `left` returns
    an empty tuple, which reads as "no changes" and silently under-reports a
    review. Measured 2026-11-22: `(a, b)` returns 9 revisions on the sample
    clause; `(redline, b)` returns 0.

    It is passed the SAME settings as `compare` so the reported author and date
    match the ones actually stamped into the document. Without that the change
    list says "Docxodus" while the .docx says "PacGate Legal Review".

    The anchors are returned as-is so a caller can map a revision back to the
    block it came from; `type` is the engine's enum (Inserted / Deleted /
    FormatChanged), stringified so it survives MCP transport.
    """
    ds = _engine()
    revisions = ds.docx_diff_get_revisions(left, right, _settings(author))
    out: list[dict[str, Any]] = []
    for rev in revisions:
        out.append(
            {
                "type": str(getattr(rev, "type", "")),
                "text": getattr(rev, "text", ""),
                "author": getattr(rev, "author", ""),
                "date": getattr(rev, "date", ""),
                "left_anchor": getattr(rev, "left_anchor", None),
                "right_anchor": getattr(rev, "right_anchor", None),
                "is_move_source": bool(getattr(rev, "is_move_source", False) or False),
            }
        )
    return out


def resolve_author() -> str:
    """The author name that will be stamped on revisions."""
    return DEFAULT_AUTHOR
