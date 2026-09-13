"""E2E audit: upload -> auto-convert -> agent generate -> read back.

Runs against the live deer-flow gateway (port 8001 inside container, exposed
via frontend proxy 8090 / nginx 8089). Uses the admin account from .env.
"""
import io
import json
import os
import sys
import time
import urllib.request
import urllib.error
import http.cookiejar

BASE = os.environ.get("E2E_BASE", "http://localhost:8090")
EMAIL = os.environ.get("PACGATE_API_EMAIL", "admin@pacgate-law.com")
PASSWORD = os.environ.get("PACGATE_API_PASSWORD", "")
if not PASSWORD:
    envp = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env")
    if os.path.exists(envp):
        for line in open(envp, encoding="utf-8"):
            line = line.strip()
            if line.startswith("PACGATE_API_PASSWORD="):
                PASSWORD = line.split("=", 1)[1].strip()
                break

cj = http.cookiejar.CookieJar()
opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))

results = {"steps": []}


def step(name, ok, detail):
    results["steps"].append({"step": name, "ok": ok, "detail": detail})
    print(("PASS " if ok else "FAIL ") + name + " :: " + str(detail)[:400])


def req(method, path, data=None, headers=None, timeout=30):
    url = BASE + path
    r = urllib.request.Request(url, data=data, method=method)
    for k, v in (headers or {}).items():
        r.add_header(k, v)
    try:
        resp = opener.open(r, timeout=timeout)
        body = resp.read()
        return resp.status, body
    except urllib.error.HTTPError as e:
        return e.code, e.read()


# ---- Step 1: login ----
form = ("username=" + EMAIL + "&password=" + PASSWORD).encode()
st, body = req("POST", "/api/v1/auth/login/local", data=form,
               headers={"Content-Type": "application/x-www-form-urlencoded"})
step("login", st == 200, {"status": st, "body": body[:200].decode("utf-8", "replace")})
if st != 200:
    print(json.dumps(results, indent=2))
    sys.exit(1)

# ---- CSRF token from login response cookie (double-submit pattern) ----
csrf = None
for c in cj:
    if c.name == "csrf_token":
        csrf = c.value
        break


def req_csrf(method, path, data=None, headers=None, timeout=30):
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
step("create_thread", st in (200, 201) and bool(thread_id), {"status": st, "body": body[:300].decode("utf-8", "replace"), "thread_id": thread_id})
if not thread_id:
    print(json.dumps(results, indent=2))
    sys.exit(1)

# ---- Step 3: build a small DOCX in-memory (valid OOXML zip) ----
import zipfile

docx_xml = (
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
    "<w:body>"
    "<w:p><w:r><w:t>PacGate E2E Audit Document</w:t></w:r></w:p>"
    "<w:p><w:r><w:t>This DOCX was generated in-memory to test the upload and conversion pipeline.</w:t></w:r></w:p>"
    "<w:p><w:r><w:t>Key term: the engagement fee is USD 50,000 payable within 30 days.</w:t></w:r></w:p>"
    "</w:body></w:document>"
)
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
docx_bytes = buf.getvalue()

# ---- Step 4: upload DOCX to thread ----
boundary = "----pacgateE2E"
part = (
    "--" + boundary + "\r\n"
    'Content-Disposition: form-data; name="files"; filename="e2e-audit.docx"\r\n'
    "Content-Type: application/vnd.openxmlformats-officedocument.wordprocessingml.document\r\n"
    "\r\n"
).encode() + docx_bytes + ("\r\n--" + boundary + "--\r\n").encode()
st, body = req_csrf("POST", "/api/threads/" + thread_id + "/uploads", data=part,
                    headers={"Content-Type": "multipart/form-data; boundary=" + boundary})
up = {}
try:
    up = json.loads(body)
except Exception:
    pass
step("upload_docx", st in (200, 201), {"status": st, "body": body[:500].decode("utf-8", "replace")})

# ---- Step 5: check auto-convert produced a .md alongside ----
st, body = req("GET", "/api/threads/" + thread_id + "/uploads/list")
lst = {}
try:
    lst = json.loads(body)
except Exception:
    pass
files = lst.get("files") or lst.get("uploads") or []
names = [f.get("filename", "") for f in files] if isinstance(files, list) else []
md_names = [n for n in names if n.endswith(".md")]
step("auto_convert_md_present", bool(md_names), {"status": st, "files": names, "md": md_names})

# ---- Step 6: read the converted markdown content ----
md_ok = False
md_head = ""
for n in md_names:
    # uploads live under /mnt/user-data/uploads/<name>; artifact route serves them
    art_path = "/api/threads/" + thread_id + "/artifacts/mnt/user-data/uploads/" + urllib.request.quote(n)
    st2, body2 = req("GET", art_path)
    txt = body2.decode("utf-8", "replace")
    if st2 == 200 and ("PacGate E2E Audit" in txt or "engagement fee" in txt):
        md_ok = True
        md_head = txt[:300]
        break
step("converted_md_readable", md_ok, {"head": md_head})

print(json.dumps(results, indent=2, ensure_ascii=False))