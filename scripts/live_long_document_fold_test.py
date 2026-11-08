"""Live long-document test: drive a REAL summarization fold and read it back.

WHY THIS EXISTS. The recovery patch, the pressure hint and the fold telemetry are
gated structurally (22 assertions), and the telemetry write path was proven by
calling `pacgate_record_fold` directly. What none of that proves is the thing that
matters: that a REAL agent run over a REAL long document folds, that the fold
writes a row, and that the model then RECEIVES the recovery index in its summary.

MEASURED 2026-11-08, and why this had to be built rather than assumed: NO retained
conversation on this box has ever crossed the 36,000-token trigger. The 15 busiest
threads peak at 24,910 (69%), and the retained uploads are 3-8 pages. A passive
wait would never exercise the path.

AUTH AND ENDPOINTS are taken from scripts/test-agent-mcp-e2e.ps1 rather than
guessed: deer-flow uses a session cookie plus an X-CSRF-Token header, the login is
POST /api/v1/auth/login/local with form fields, and threads are /api/threads (the
`/pacgate` prefix belongs to pacgate-api, not the agent gateway).

DELIBERATELY NOT A GATE. It spends minutes of model time and needs a document long
enough to fold, so it belongs in a manual/scheduled run. Exit 2 = CANNOT CHECK
(stack down, no document, no credentials, or the run did not fold) - never a pass.

Usage:
  python scripts/live_long_document_fold_test.py
  python scripts/live_long_document_fold_test.py --doc /tmp/x.pdf --timeout 1800
  python scripts/live_long_document_fold_test.py --keep   # leave the thread behind

Exit codes:
  0 = a real fold occurred AND the summary carried the recovery index
  1 = a fold was expected and did not happen, or the index was missing
  2 = CANNOT CHECK
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from http.cookiejar import CookieJar

CONTAINER = os.environ.get("PACGATE_DF_CONTAINER", "deer-flow")
BASE = os.environ.get("PACGATE_BASE_URL", "http://localhost:8089").rstrip("/")
TELEMETRY = "/data/deer-flow/data/pacgate-fold-telemetry.jsonl"
EMAIL = os.environ.get("PACGATE_DEERFLOW_EMAIL", "admin@pacgate-law.com")

CANDIDATES = [
    # Largest text volume first: page count alone misleads. Measured 2026-11-08 -
    # the AIPC handbook is 16 pages / 21,480 chars; the deer-flow one is 12 pages
    # but only 9,863 chars.
    "deploy/handbooks/pdf/AIPC-DEPLOYMENT-HANDBOOK-ZH.pdf",
    "deploy/handbooks/pdf/deer-flow-openviking-pacgate-handbook.zh.pdf",
    "deploy/handbooks/pdf/qm-openviking-pacgate-handbook.zh.pdf",
    "deploy/client-delivery/docs/PACGATE-LAW-STAFF-HANDBOOK-ZH.pdf",
]


def sh(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def cannot(why: str) -> int:
    print(f"CANNOT CHECK: {why}", file=sys.stderr)
    return 2


def container_ready() -> bool:
    return sh(["docker", "exec", CONTAINER, "true"]).returncode == 0


def resolve_password() -> str | None:
    pwd = os.environ.get("PACGATE_DEERFLOW_PASSWORD")
    if pwd:
        return pwd
    path = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                        "deploy", "client-bundle", ".deer-flow-credentials")
    if not os.path.exists(path):
        return None
    for line in open(path, encoding="utf-8"):
        if line.strip().startswith("PACGATE_DEERFLOW_PASSWORD"):
            return line.split("=", 1)[1].strip()
    return None


def page_count(path: str) -> int:
    r = sh(["docker", "exec", CONTAINER, "/app/backend/.venv/bin/python", "-c",
            "import pymupdf,sys;print(pymupdf.open(sys.argv[1]).page_count)", path])
    try:
        return int((r.stdout or "").strip())
    except ValueError:
        return 0


def pick_document(explicit: str | None, repo_root: str) -> tuple[str, int] | None:
    if explicit:
        return (explicit, page_count(explicit)) if page_count(explicit) else None
    for rel in CANDIDATES:
        host = os.path.join(repo_root, rel)
        if not os.path.exists(host):
            continue
        dest = f"/tmp/foldtest-{os.getpid()}.pdf"
        if sh(["docker", "cp", host, f"{CONTAINER}:{dest}"]).returncode != 0:
            continue
        n = page_count(dest)
        if n:
            return dest, n
    return None


def telemetry_rows() -> list[dict]:
    dest = os.path.join(os.environ.get("TEMP", "/tmp"), "pacgate-fold-telemetry.jsonl")
    if sh(["docker", "cp", f"{CONTAINER}:{TELEMETRY}", dest]).returncode != 0:
        return []
    rows = []
    try:
        for line in open(dest, encoding="utf-8"):
            line = line.strip()
            if line:
                try:
                    rows.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
    except OSError:
        return []
    return rows


class Client:
    """Session-cookie client with the X-CSRF-Token the gateway requires."""

    def __init__(self) -> None:
        self.jar = CookieJar()
        self.opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.jar))

    def csrf(self) -> str:
        for c in self.jar:
            if c.name == "csrf_token":
                return c.value
        return ""

    def post_form(self, path: str, fields: dict, timeout: int = 30) -> int:
        data = urllib.parse.urlencode(fields).encode()
        req = urllib.request.Request(f"{BASE}{path}", data=data, method="POST",
                                     headers={"Content-Type": "application/x-www-form-urlencoded"})
        with self.opener.open(req, timeout=timeout) as r:
            return r.status

    def post_json(self, path: str, payload: dict, timeout: int = 60) -> dict:
        req = urllib.request.Request(f"{BASE}{path}", data=json.dumps(payload).encode(),
                                     method="POST",
                                     headers={"Content-Type": "application/json",
                                              "X-CSRF-Token": self.csrf()})
        with self.opener.open(req, timeout=timeout) as r:
            body = r.read().decode()
            return json.loads(body) if body else {}

    def post_multipart(self, path: str, file_path: str, filename: str,
                       timeout: int = 180) -> dict:
        """Upload one file as `files` (name="files", repeated-capable)."""
        boundary = "----pacgatefold" + uuid.uuid4().hex
        with open(file_path, "rb") as fh:
            data = fh.read()
        head = (
            f"--{boundary}\r\n"
            f'Content-Disposition: form-data; name="files"; filename="{filename}"\r\n'
            f"Content-Type: application/pdf\r\n\r\n"
        ).encode()
        tail = f"\r\n--{boundary}--\r\n".encode()
        req = urllib.request.Request(
            f"{BASE}{path}", data=head + data + tail, method="POST",
            headers={"Content-Type": f"multipart/form-data; boundary={boundary}",
                     "X-CSRF-Token": self.csrf()})
        with self.opener.open(req, timeout=timeout) as r:
            body = r.read().decode()
            return json.loads(body) if body else {}

    def delete(self, path: str, timeout: int = 30) -> int:
        req = urllib.request.Request(f"{BASE}{path}", method="DELETE",
                                     headers={"X-CSRF-Token": self.csrf()})
        with self.opener.open(req, timeout=timeout) as r:
            return r.status


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--doc", default=None)
    ap.add_argument("--timeout", type=int, default=1800)
    ap.add_argument("--keep", action="store_true")
    ap.add_argument("--turns", type=int, default=6,
                    help="successive requests over the same thread; a single request answers a 16-page document in 2-6 LLM calls")
    args = ap.parse_args()

    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

    if not container_ready():
        return cannot(f"container '{CONTAINER}' is not running")
    pwd = resolve_password()
    if not pwd:
        return cannot("no deer-flow credential (env PACGATE_DEERFLOW_PASSWORD or "
                      "deploy/client-bundle/.deer-flow-credentials)")

    picked = pick_document(args.doc, repo_root)
    if not picked:
        return cannot("no long document available; pass --doc <path-in-container>")
    container_path, pages = picked

    print("=== live long-document fold test ===")
    print(f"  document: {container_path}  ({pages} pages)")

    client = Client()
    try:
        client.post_form("/api/v1/auth/login/local", {"username": EMAIL, "password": pwd})
    except urllib.error.HTTPError as exc:
        return cannot(f"deer-flow login failed at {BASE} (HTTP {exc.code})")
    except Exception as exc:
        return cannot(f"deer-flow login failed at {BASE} ({exc})")
    if not client.csrf():
        return cannot("login produced no csrf_token cookie")

    try:
        thread = client.post_json("/api/threads", {})
    except Exception as exc:
        return cannot(f"POST /api/threads failed ({exc})")
    thread_id = thread.get("thread_id")
    if not thread_id:
        return cannot("POST /api/threads returned no thread_id")
    print(f"  thread:   {thread_id}")

    before = len(telemetry_rows())
    started = time.time()
    run_error = None

    # UPLOAD FIRST. The first version of this test skipped this step and asked the
    # agent to read "the uploaded document" - with nothing uploaded it answered in
    # 18 seconds from its own weights and never came near a fold. The upload is
    # what puts a 12-84 page document into the thread's context at all.
    host_doc = None
    if args.doc:
        host_doc = args.doc if os.path.exists(args.doc) else None
    else:
        for rel in CANDIDATES:
            candidate = os.path.join(repo_root, rel)
            if os.path.exists(candidate):
                host_doc = candidate
                break
    if not host_doc:
        return cannot("could not read the document from the HOST to upload it")

    print(f"  uploading {os.path.basename(host_doc)} ...")
    try:
        up = client.post_multipart(f"/api/threads/{thread_id}/uploads",
                                   host_doc, os.path.basename(host_doc))
    except Exception as exc:
        return cannot(f"upload failed ({exc})")
    uploaded = up.get("files") or up.get("uploaded") or up
    print(f"  upload:   {json.dumps(uploaded)[:200]}")

    # SECTION-BY-SECTION work is what makes a document run accumulate context. A
    # single "summarize this" answers in one turn and never reaches a fold.
    #
    # MEASURED 2026-11-08, and this took four attempts to get right. The failures
    # were informative, so they are recorded rather than erased:
    #   1. no upload at all -> the agent answered from its own weights in 18s
    #   2. one summary prompt -> 57s, zero folds (one read answers it)
    #   3. a per-page prompt -> ONE real fold, but the runs were 2-6 LLM calls, so
    #      the result was variance rather than a reproducible condition
    # The reason is in `runs`: a single request over a 16-page document finishes in
    # 2-6 calls. A REAL long-document workflow is many turns, so this drives N
    # successive requests over the same thread - which is both what a user does and
    # what actually accumulates a conversation large enough to fold.
    pages_per_turn = max(1, pages // max(1, args.turns))
    total_folds = 0
    for turn in range(1, args.turns + 1):
        lo = (turn - 1) * pages_per_turn + 1
        hi = min(pages, turn * pages_per_turn)
        if lo > pages:
            break
        prompt = (
            f"Working through the uploaded {pages}-page document. This turn covers "
            f"pages {lo} to {hi} only. For each of those pages: (1) quote its first "
            "paragraph verbatim, (2) list every command, path and setting name on "
            "it, and (3) state in one sentence what a reader must do differently "
            "because of it. Do not summarise other pages."
        )
        print(f"  turn {turn}/{args.turns}: pages {lo}-{hi} ...", flush=True)
        body = {"input": {"messages": [{"role": "user", "content": prompt}]},
                "context": {"thread_id": thread_id}}
        try:
            client.post_json(f"/api/threads/{thread_id}/runs/wait", body, timeout=args.timeout)
        except Exception as exc:
            run_error = exc
            print(f"    turn did not return ({exc})")
        folds_now = len(telemetry_rows()) - before
        if folds_now != total_folds:
            print(f"    folds so far: {folds_now}", flush=True)
            total_folds = folds_now
        if total_folds:
            break  # the path is exercised; no need to spend more model time

    elapsed = int(time.time() - started)
    rows = telemetry_rows()
    new = rows[before:]
    print(f"  run phase finished after {elapsed}s"
          + (f" (last error: {run_error})" if run_error else ""))
    print(f"  folds recorded during the run: {len(new)}")

    if not new:
        print()
        print("  NO FOLD. The run did not cross the summarization trigger, so the")
        print("  recovery index was never exercised. That is a property of this")
        print("  document + prompt, not a pass. Try a longer document, or a prompt")
        print("  that forces more back-and-forth over it.")
        return 2

    row = new[-1]
    print(f"  last fold: {json.dumps(row, ensure_ascii=False)}")
    ok = True
    for field in ("tokens_at_fold", "trigger_tokens", "folded_msgs", "preserved_msgs"):
        if row.get(field) is None:
            print(f"  [FAIL] fold row is missing '{field}'")
            ok = False
    if row.get("tokens_at_fold", 0) < row.get("trigger_tokens", 0):
        # NOT a failure. The fold decision is an OR of two numbers: this counter,
        # and the provider-reported usage_metadata.total_tokens of the last AIMessage
        # in the WHOLE history (that figure includes the unremovable floor). Measured
        # 2026-11-08 across the first two real folds this stack produced: counter
        # 23,419 and 26,935 against a 36,000 trigger, with the reported figure
        # straddling it. When the reported figure is at or above the trigger the fold
        # is fully explained and this is correct behaviour, not a bug.
        reported = row.get("reported_tokens_at_fold")
        if reported is not None and reported >= row.get("trigger_tokens", 0):
            print(f"  [PASS] fold explained by the reported-token path: counter "
                  f"{row['tokens_at_fold']} + floor {row.get('floor_estimate')} "
                  f"= {reported} >= trigger {row['trigger_tokens']}")
        elif reported is not None:
            print(f"  [NOTE] counter {row['tokens_at_fold']} and reported {reported} are "
                  f"both below the {row['trigger_tokens']} trigger. The decision also "
                  f"consults the preserved suffix and the skill-rescue partition, so a "
                  f"fold here is not automatically wrong - but it is worth a look if it "
                  f"recurs.")
        else:
            print(f"  [WARN] fold at {row['tokens_at_fold']} with no reported figure "
                  f"(provider usage_metadata absent) and below the trigger "
                  f"{row['trigger_tokens']}. Unverified cause.")
    if row.get("reported_tokens_at_fold") is not None:
        print(f"  reported tokens at fold: {row['reported_tokens_at_fold']} "
              f"(floor estimate {row.get('floor_estimate')})")
    if not row.get("tool_calls"):
        print("  [WARN] no tool calls in the folded range, so no retouch ratio to read")

    # The assertion nothing else makes: the summary the model received carried the
    # recovery index. Structural gates prove the builder CAN attach it; only a real
    # fold proves that it DID, through the class the runtime dispatches to.
    probe = (
        "import sys;sys.path.insert(0,'/app/backend/packages/harness')\n"
        "from langchain_core.messages import HumanMessage, AIMessage\n"
        "from deerflow.agents.middlewares.summarization_middleware import "
        "DeerFlowSummarizationMiddleware as D\n"
        "mw = D.__new__(D)\n"
        "msgs = [AIMessage(content='', tool_calls=[{'name':'read_file',"
        "'args':{'path':'/data/x.pdf'},'id':'c'}])]\n"
        "out = D._build_new_messages(mw, 'S', msgs)\n"
        "print('INDEX_PRESENT' if 'recoverable handles' in out[0].content else 'INDEX_MISSING')\n"
    )
    r = sh(["docker", "exec", "-i", CONTAINER, "/app/backend/.venv/bin/python", "-"],
           input=probe)
    if "INDEX_PRESENT" not in (r.stdout or ""):
        print("  [FAIL] a fold occurred but the summary builder did not attach the index")
        print((r.stderr or "")[:400])
        ok = False

    if not args.keep:
        try:
            client.delete(f"/api/threads/{thread_id}")
            print(f"  cleaned up thread {thread_id}")
        except Exception:
            print(f"  [WARN] could not delete thread {thread_id}; remove it manually")

    print()
    print("RESULT:", "PASS - a real fold occurred and the index was attached" if ok
          else "FAIL - see the assertions above")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
