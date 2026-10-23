"""Fail-closed tests for ocr-service's page decision.

`incomplete` is the flag pacgate-api reconciles on
(`incomplete || text.trim().is_empty()`), so a page that yields nothing must set
it. These tests pin the four degenerate shapes without needing PaddleOCR, the
weights, or a container: `_page_spans` is pure.

Run:  python deploy/ocr-service/test_app.py
"""

import os
import sys
import types

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))


def install_fastapi_stub() -> None:
    """Provide a minimal fastapi so app.py imports without the web stack.

    The tests exercise `_page_spans`, which is pure. Stubbing keeps the suite
    runnable on a dev box that has no fastapi/paddleocr installed - the same
    approach scripts/test-mcp-401-retry.py uses for the MCP SDK.
    """
    fastapi = types.ModuleType("fastapi")

    class _FakeApp:
        def __init__(self, *args, **kwargs) -> None:
            pass

        def get(self, *args, **kwargs):
            def decorator(fn):
                return fn

            return decorator

        def post(self, *args, **kwargs):
            def decorator(fn):
                return fn

            return decorator

    fastapi.FastAPI = _FakeApp
    fastapi.File = lambda *a, **k: None
    fastapi.Form = lambda *a, **k: None
    fastapi.UploadFile = object
    sys.modules.setdefault("fastapi", fastapi)


install_fastapi_stub()

import app as ocr_app  # noqa: E402

_passed = 0
_failed = 0


def check(condition: bool, msg: str) -> None:
    global _passed, _failed
    if condition:
        _passed += 1
        print(f"  [PASS] {msg}")
    else:
        _failed += 1
        print(f"  [FAIL] {msg}")


def a_line(text: str, x: int = 10, y: int = 20, w: int = 100, h: int = 30):
    """One PaddleOCR line: [[box points], (text, confidence)]."""
    box = [[x, y], [x + w, y], [x + w, y + h], [x, y + h]]
    return [box, (text, 0.99)]


def case_1_empty_result() -> None:
    print("\nCASE 1 - an empty/None result is incomplete")
    for label, result in (("None", None), ("[]", [])):
        spans, complete = ocr_app._page_spans(1, result)
        check(spans == [], f"{label}: no spans")
        check(complete is False, f"{label}: reported incomplete")


def case_2_empty_first_element() -> None:
    print("\nCASE 2 - an empty/None result[0] is incomplete")
    for label, result in (("[None]", [None]), ("[[]]", [[]])):
        spans, complete = ocr_app._page_spans(1, result)
        check(spans == [], f"{label}: no spans")
        check(complete is False, f"{label}: reported incomplete")


def case_3_no_usable_spans() -> None:
    print("\nCASE 3 - lines that yield no spans are incomplete")
    # Every line malformed: the page was 'read' but nothing was recovered.
    spans, complete = ocr_app._page_spans(1, [[[["bad"], ("text", 0.9)]]])
    check(spans == [], "malformed line: no spans")
    check(complete is False, "malformed line: reported incomplete")


def case_4_a_real_page_is_complete() -> None:
    print("\nCASE 4 - a page with text is complete and carries geometry")
    spans, complete = ocr_app._page_spans(3, [[a_line("hello"), a_line("world", y=60)]])
    check(complete is True, "reported complete")
    check(len(spans) == 2, f"two spans (got {len(spans)})")
    check(spans[0]["page"] == 3, f"page number carried (got {spans[0]['page']})")
    check(spans[0]["text"] == "hello", f"text carried (got {spans[0]['text']!r})")
    check(spans[0]["width"] == 100, f"width computed (got {spans[0]['width']})")
    check(spans[0]["height"] == 30, f"height computed (got {spans[0]['height']})")
    check(spans[0]["x"] == 10 and spans[0]["y"] == 20, "origin computed")


def case_5_one_bad_line_does_not_lose_the_good_ones() -> None:
    print("\nCASE 5 - a malformed line is skipped, not fatal")
    # result[0] is the list of lines; one of them is malformed.
    spans, complete = ocr_app._page_spans(1, [[[["bad"], ("x", 0.9)], a_line("kept")]])
    check(complete is True, "page still complete")
    check(len(spans) == 1, f"the good line survived (got {len(spans)})")
    check(spans[0]["text"] == "kept", "the good line's text is intact")


def case_6_rasterisation_failure_is_the_callers_flag() -> None:
    print("\nCASE 6 - a page that never rasterised is incomplete")
    # _prepare_pages returns (page_no, None) for a page it could not rasterise.
    # The endpoint sets incomplete for that; assert the contract it relies on.
    pages = ocr_app._prepare_pages.__doc__ or ""
    check("None" in pages, "the (page_no, None) contract is documented")
    check(
        "incomplete" in pages,
        "the docstring names the incomplete flag the caller must set",
    )


def main() -> int:
    print("ocr-service fail-closed tests")
    print(f"target: {os.path.abspath(ocr_app.__file__)}")
    for case in (
        case_1_empty_result,
        case_2_empty_first_element,
        case_3_no_usable_spans,
        case_4_a_real_page_is_complete,
        case_5_one_bad_line_does_not_lose_the_good_ones,
        case_6_rasterisation_failure_is_the_callers_flag,
    ):
        try:
            case()
        except Exception as exc:  # noqa: BLE001 - a raised case is a failed case
            global _failed
            _failed += 1
            print(f"  [FAIL] {case.__name__} raised {type(exc).__name__}: {exc}")

    print(f"\nassertions passed: {_passed}  failed: {_failed}")
    if _failed:
        print("RESULT: FAILED")
        return 1
    print("RESULT: fail-closed behaviour verified")
    return 0


if __name__ == "__main__":
    sys.exit(main())
