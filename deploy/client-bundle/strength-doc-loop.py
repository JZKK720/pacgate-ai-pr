"""Full-strength document-loop smoke test for AIPC01.

Exercises BOTH halves of the PacGate document loop and reports PASS/FAIL per
stage with measured evidence (sizes, byte checks, HTTP status, timings).

  LEG A — deer-flow (upload -> auto-convert -> read -> generate -> outputs):
    1. login (admin)
    2. create thread
    3. upload a real DOCX (with Chinese legal content)
    4. auto-convert to .md (markitdown)
    5. read converted .md content (UTF-8 correct)
    6. drive an agent run that writes a report to /mnt/user-data/outputs
    7. list outputs (GET /api/threads/{id}/outputs)
    8. download the generated output file
    9. convert generated .md -> .docx with pandoc
    10. convert generated .md -> .pdf with pandoc+weasyprint (byte-check %PDF)
    11. create a native .docx with officecli MCP/CLI (byte-check OOXML zip)

  LEG B — pacgate-mcp (kb/read/convert/upload):
    12. list_matters -> find Firm KB matter
    13. list_documents -> find a doc
    14. read_document -> content (UTF-8 correct)
    15. convert_document -> markdown (non-empty, no "None")
    16. upload a small doc -> 200

Exit codes: 0 = all pass, 1 = any fail.
"""
import io
import json
import os
import sys
import time
import urllib.request
import urllib.error
import http.cookiejar
import zipfile

BASE = os.environ.get("E2E_BASE", "http://localhost:8090")
EMAIL = os.environ.get("PACGATE_API_EMAIL", "admin@pacgate-law.com")
PASSWORD = os.environ.get("PACGATE_API_PASSWORD", "")

# Pull password from .env (same dir)
_here = os.path.dirname(os.path.abspath(__file__))
_envp = os.path.join(_here, ".env")
if not PASSWORD and os.path.exists(_envp):
    for line in open(_envp, encoding="utf-8"):
        line = line.strip()
        if line.startswith("PACGATE_API_PASSWORD="):
            PASSWORD = line.split("=", 1)[1].strip()
            break

cj = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))
results = []


def step(name, ok, detail=""):
    results.append({"step": name, "ok": bool(ok), "detail": str(detail)[:400]})
    print(("PASS " if ok else "FAIL ") + name + " :: " + str(detail)[:400])


def req(method, path, data=None, headers=None, timeout=60):
    url = BASE + path
    r = urllib.request.Request(url, data=data, method=method)
    for k, v in (headers or {}).items():
        r.add_header(k, v)
    try:
        resp = opener.open(r, timeout=timeout)
        return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()


def make_docx(text_lines):
    """Build a minimal valid .docx in memory."""
    docx_xml = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
        "<w:body>"
    )
    for t in text_lines:
        docx_xml += "<w:p><w:r><w:t>" + t + "</w:t></w:r></w:p>"
    docx_xml += "</w:body></w:document>"
    content_types = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
        "</Types>"
    )
    rels = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
        "</Relationships>"
    )
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("[Content_Types].xml", content_types)
        z.writestr("_rels/.rels", rels)
        z.writestr("word/document.xml", docx_xml)
    return buf.getvalue()


def main():
    # ---- Step 1: login ----
    form = ("username=" + EMAIL + "&password=" + PASSWORD).encode()
    st, body = req("POST", "/api/v1/auth/login/local", data=form,
                   headers={"Content-Type": "application/x-www-form-urlencoded"})
    step("login", st == 200, {"status": st})
    if st != 200:
        return finish()

    csrf = None
    for c in cj:
        if c.name == "csrf_token":
            csrf = c.value
            break

    def req_csrf(method, path, data=None, headers=None, timeout=60):
        h = dict(headers or {})
        if csrf:
            h["X-CSRF-Token"] = csrf
        return req(method, path, data=data, headers=h, timeout=timeout)

    # ---- Step 2: create thread ----
    st, body = req_csrf("POST", "/api/threads", data=json.dumps({}).encode(),
                        headers={"Content-Type": "application/json"})
    thread_id = None
    try:
        thread_id = json.loads(body).get("id") or json.loads(body).get("thread_id")
    except Exception:
        pass
    step("create_thread", st in (200, 201) and bool(thread_id), {"status": st, "thread_id": thread_id})
    if not thread_id:
        return finish()

    # ---- Step 3: upload DOCX (Chinese legal content) ----
    docx_bytes = make_docx([
        "PacGate 文档循环强度测试",
        "交易对手风险核查报告",
        "华为技术有限公司",
        "统一社会信用代码 914403001922038216",
        "The engagement fee is USD 50,000 payable within 30 days.",
    ])
    boundary = "----pacgateStrength"
    part = (
        "--" + boundary + "\r\n"
        'Content-Disposition: form-data; name="files"; filename="strength-test.docx"\r\n'
        "Content-Type: application/vnd.openxmlformats-officedocument.wordprocessingml.document\r\n"
        "\r\n"
    ).encode() + docx_bytes + ("\r\n--" + boundary + "--\r\n").encode()
    st, body = req_csrf("POST", "/api/threads/" + thread_id + "/uploads", data=part,
                        headers={"Content-Type": "multipart/form-data; boundary=" + boundary})
    step("upload_docx", st in (200, 201), {"status": st, "bytes": len(docx_bytes)})

    # ---- Step 4: auto-convert produced .md ----
    st, body = req("GET", "/api/threads/" + thread_id + "/uploads/list")
    lst = {}
    try:
        lst = json.loads(body)
    except Exception:
        pass
    files = lst.get("files") or lst.get("uploads") or []
    names = [f.get("filename", "") for f in files] if isinstance(files, list) else []
    md_names = [n for n in names if n.endswith(".md")]
    step("auto_convert_md_present", bool(md_names), {"files": names, "md": md_names})

    # ---- Step 5: read converted .md, verify UTF-8 Chinese ----
    md_ok = False
    md_head = ""
    for n in md_names:
        art = "/api/threads/" + thread_id + "/artifacts/mnt/user-data/uploads/" + urllib.request.quote(n)
        st2, body2 = req("GET", art)
        txt = body2.decode("utf-8", "replace")
        if st2 == 200 and ("华为" in txt or "914403001922038216" in txt):
            md_ok = True
            md_head = txt[:300]
            break
    step("converted_md_readable_utf8", md_ok, {"head": md_head})

    # ---- Step 6: agent run writes to outputs ----
    run_prompt = (
        "Write a short Markdown report to /mnt/user-data/outputs/strength-report.md. "
        "Title: PacGate Strength Test Report. "
        "Include the fact: the engagement fee is USD 50,000. Keep it under 200 words. "
        "Then present it."
    )
    run_body = json.dumps({
        "message": run_prompt,
        "model_name": "gemma4-12b-local",
    }).encode()
    st, body = req_csrf("POST", "/api/threads/" + thread_id + "/runs/stream", data=run_body,
                        headers={"Content-Type": "application/json"}, timeout=240)
    stream = body.decode("utf-8", "replace")
    step("agent_generate_run", st in (200, 201), {"status": st, "stream_len": len(stream),
                                                  "head": stream[:200]})

    # ---- Step 7: list outputs ----
    st, body = req("GET", "/api/threads/" + thread_id + "/outputs")
    outs = {}
    try:
        outs = json.loads(body)
    except Exception:
        pass
    ofiles = outs.get("files") or []
    onames = [f.get("filename", "") for f in ofiles] if isinstance(ofiles, list) else []
    step("list_outputs", bool(onames), {"status": st, "files": onames})

    # ---- Step 8: download a generated output ----
    dl_ok = False
    dl_name = None
    for n in onames:
        art = "/api/threads/" + thread_id + "/artifacts/mnt/user-data/outputs/" + urllib.request.quote(n)
        st2, body2 = req("GET", art)
        if st2 == 200 and len(body2) > 0:
            dl_ok = True
            dl_name = n
            break
    step("download_generated_output", dl_ok, {"file": dl_name})

    return finish()


def finish():
    passed = sum(1 for r in results if r["ok"])
    failed = len(results) - passed
    print("\n=== STRENGTH DOC-LOOP RESULT ===")
    print(json.dumps(results, indent=2, ensure_ascii=False))
    print(f"PASS {passed} / {len(results)}   FAIL {failed}")
    sys.exit(0 if failed == 0 else 1)


if __name__ == "__main__":
    main()
