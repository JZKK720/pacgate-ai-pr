"""Live CJK regression probe for pacgate-api.

This is the regression gate for the 0.1.27 release-blocking defect. It proves,
end-to-end over HTTP through nginx (port 8089), that Chinese text survives every
byte-slicing surface Pacgate exposes on the document path:

  * a CJK filename survives multipart upload (filename -> storage -> DB)
  * text extract returns the CJK body byte-for-byte
    (text_extract.rs lane -- /extract)
  * PUT /edit patches CJK text BOTH without and WITH context, exercising the
    fragile `xml.find(&anchor).map(|i| i + xml_escape(cb).len())` arithmetic in
    docx::diff::replace_first_in_xml (the second byte-slicing surface)
  * tracked-change markup is correct: the original CJK text stays in <w:delText>
    and the replacement lands in an inserted <w:t> run
  * POST /accept strips the <w:del> blocks and unwraps the <w:ins> blocks
    WITHOUT mangling either the surviving CJK or the inserted CJK
  * none of it emits a Rust char-boundary panic in any container

Isolation: each run creates its own matter, so document versions are always
1 (upload), 2 (first edit), 3 (second edit), 4 (accept). The earlier revision
targeted a fixed matter and asserted absolute version numbers, which rotted as
soon as the previous run's document family persisted.

Run sequences are joined by a SINGLE space by text_extract.rs, so the expected
post-accept body is a pure string substitution on the fixture -- asserted as
byte equality, not substring presence. No XML fragment ever crosses a run
boundary.

Source is deliberately ASCII-only: every CJK literal is a \\uXXXX escape, so
this file is safe to transmit, patch and diff under any host encoding.

Not wired into run-all-checks.ps1: it needs a live stack. It removes the matter
and the document family it creates -- via atexit, so it also cleans up when an
assertion aborts the run -- so it is safe to re-run against a shared box.

CJK_BASE overrides the base URL; PACGATE_API_EMAIL and PACGATE_API_PASSWORD
override the credentials, and the password otherwise comes from
deploy/client-bundle/.env.

Usage:  python scripts/cjk-live-probe.py
Exit 0 = all assertions pass, 1 = a real assertion failed, 2 = could not check.
"""
import atexit
import io
import json
import os
import sys
import zipfile

import httpx

BASE = os.environ.get("CJK_BASE", "http://localhost:8089/pacgate")
EMAIL = os.environ.get("PACGATE_API_EMAIL", "admin@pacgate-law.com")

envp = os.path.join(
    os.path.dirname(os.path.abspath(__file__)), "..", "deploy", "client-bundle", ".env"
)
PASSWORD = os.environ.get("PACGATE_API_PASSWORD", "")
if not PASSWORD:
    # repo-relative first, then cwd and the legacy temp-compose location, so the
    # probe works from the repo and from a scratch checkout of the compose copy.
    _here = os.path.dirname(os.path.abspath(__file__))
    cands = [
        envp,
        os.path.join(_here, "..", ".env"),
        os.path.join(".env",),
        os.path.join(_here, "..", "..", "pacgate-e2e-up", ".env"),
    ]
    for cand in cands:
        if os.path.exists(cand):
            for line in open(cand, encoding="utf-8"):
                line = line.strip()
                if line.startswith("PACGATE_API_PASSWORD="):
                    PASSWORD = line.split("=", 1)[1].strip()
                    break
        if PASSWORD:
            break
if not PASSWORD:
    print("FATAL: PACGATE_API_PASSWORD not set and no .env found")
    sys.exit(2)

# ---- CJK fixture (escapes only) --------------------------------------------
# Assembled from named parts so no assertion depends on a hardcoded character
# offset. Renders:
#   本合同项下的服务费用为人民币伍万元整，乙方应在收到发票后三十日内付清
#   全部款项。甲方应提供常年法律顾问支持，包含合同审查、合规咨询以及争议解决等事项。
P_A = "\u672c\u5408\u540c\u9879\u4e0b\u7684"                # 本合同项下的
FIND1 = "\u670d\u52a1\u8d39\u7528"                          # 服务费用
REPL1 = "\u987e\u95ee\u670d\u52a1\u8d39"                    # 顾问服务费
P_B = "\u4e3a"                                              # 为
CTX_BEFORE = "\u4eba\u6c11\u5e01"                           # 人民币
FIND2 = "\u4f0d\u4e07\u5143\u6574"                          # 伍万元整
REPL2 = "\u4f0d\u62fe\u4e07\u5143\u6574"                    # 伍拾万元整
CTX_AFTER = "\uff0c\u4e59\u65b9"                            # ，乙方
P_C = (
    "\u5e94\u5728\u6536\u5230\u53d1\u7968\u540e\u4e09\u5341\u65e5\u5185"
    "\u4ed8\u6e05\u5168\u90e8\u6b3e\u9879\u3002"
)                                                            # 应在收到发票后三十日内付清全部款项。
P_D = (
    "\u7532\u65b9\u5e94\u63d0\u4f9b\u5e38\u5e74\u6cd5\u5f8b\u987e\u95ee"
    "\u652f\u6301\uff0c\u5305\u542b\u5408\u540c\u5ba1\u67e5\u3001\u5408"
    "\u89c4\u54a8\u8be2\u4ee5\u53ca\u4e89\u8bae\u89e3\u51b3\u7b49\u4e8b"
    "\u9879\u3002"
)                                                            # 甲方应提供常年法律顾问支持，包含合同审查、合规咨询以及争议解决等事项。

RUN1 = P_A + FIND1 + P_B + CTX_BEFORE + FIND2 + CTX_AFTER + P_C + P_D
RUN2 = P_A + REPL1 + P_B + CTX_BEFORE + REPL2 + CTX_AFTER + P_C + P_D
RUN3 = P_A + REPL1 + P_B + CTX_BEFORE + REPL2 + CTX_AFTER + P_C + P_D

FILENAME = "\u5408\u7ea6\u6d4b\u8bd5.docx"                  # 合约测试.docx
STEM = "\u5408\u7ea6\u6d4b\u8bd5"                           # 合约测试

# Fixture invariants: every find/anchor string must be unique so the
# "replace the FIRST occurrence" contract is unambiguous.
_uniq = (("FIND1", FIND1, 1), ("FIND2", FIND2, 1),
         ("CTX_BEFORE+FIND2", CTX_BEFORE + FIND2, 1),
         ("FIND2+CTX_AFTER", FIND2 + CTX_AFTER, 1),
         ("P_B+CTX_BEFORE", P_B + CTX_BEFORE, 1),
         ("REPL1", REPL1, 0), ("REPL2", REPL2, 0))
for _name, _needle, _want in _uniq:
    _got = RUN1.count(_needle)
    assert _got == _want, "fixture drift: %s occurs %d times" % (_name, _got)
assert len(FILENAME.split(".")[0]) == len(STEM)
assert RUN3.encode("utf-8") != RUN1.encode("utf-8")

results = []
failures = []


def step(name, ok, detail):
    results.append({"step": name, "ok": bool(ok), "detail": detail})
    print(("PASS " if ok else "FAIL ") + name + " :: " + str(detail)[:600])
    if not ok:
        failures.append(name)


def build_docx(cjk_text):
    """Minimal single-run OOXML package.

    Exactly ONE <w:t> run on purpose: text_extract.rs joins successive runs
    with a space, and diff.rs matches on literal XML, so the whole fixture must
    live inside one run or a find/anchor string would straddle a run boundary
    and never be found.
    """
    doc = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
        "<w:body>"
        "<w:p><w:r><w:t>" + cjk_text + "</w:t></w:r></w:p>"
        "</w:body></w:document>"
    )
    types = (
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
        z.writestr("[Content_Types].xml", types)
        z.writestr("_rels/.rels", rels)
        z.writestr("word/document.xml", doc)
    return buf.getvalue(), doc


def jbody(r):
    try:
        return r.json()
    except Exception:
        return {}


def extract(c, doc_id, headers):
    """POST /extract and return (status, json)."""
    r = c.post(BASE + "/api/documents/" + doc_id + "/extract", headers=headers)
    return r.status_code, jbody(r)


# Ids this run created, so every exit path -- including an early sys.exit on a
# failed setup step -- can remove them.
created = {"matter_id": None, "doc_id": None, "headers": None}


def cleanup():
    """Best-effort removal of everything this run created.

    Documents BEFORE the matter: delete_document_family drops the files AND
    every version row for that document name, whereas MatterStore::delete is a
    bare `DELETE FROM matters` with no cascade, so deleting the matter first
    would strand its document rows.

    Registered with atexit, so a failed assertion, an early sys.exit and an
    unhandled exception all still clean up. Idempotent: ids are cleared as they
    are deleted, so the safety net is a no-op once the normal path has run.
    """
    out = {}
    if not (created["doc_id"] or created["matter_id"]):
        return out
    try:
        with httpx.Client(timeout=httpx.Timeout(30.0)) as c:
            h = created["headers"] or {}
            if created["doc_id"]:
                r = c.delete(BASE + "/api/documents/" + created["doc_id"], headers=h)
                out["document"] = r.status_code
                created["doc_id"] = None
            if created["matter_id"]:
                r = c.delete(BASE + "/api/matters/" + created["matter_id"], headers=h)
                out["matter"] = r.status_code
                created["matter_id"] = None
    except Exception as exc:
        out["error"] = str(exc)
    return out


atexit.register(cleanup)


with httpx.Client(timeout=httpx.Timeout(120.0, read=120.0)) as c:
    # ---- 1. login (JSON body; response carries `token`) --------------------
    r = c.post(BASE + "/api/auth/login", json={"email": EMAIL, "password": PASSWORD})
    tok = jbody(r)
    token = tok.get("token")
    step("login_json_token", r.status_code == 200 and bool(token),
         {"status": r.status_code, "role": tok.get("role"),
          "tenant_id": tok.get("tenant_id"),
          "body": "" if token else r.text[:200]})
    if not token:
        print(json.dumps({"results": results}, indent=2, ensure_ascii=False))
        sys.exit(1)
    H = {"Authorization": "Bearer " + token}
    created["headers"] = H

    # ---- 2. per-run matter (version numbers must be deterministic) ---------
    matter_name = "\u5c65\u7ea6\u6d4b\u8bd5"                 # 履约测试
    r = c.post(BASE + "/api/matters", json={"name": matter_name}, headers=H)
    matter = jbody(r)
    matter_id = matter.get("id")
    step("create_matter_per_run", r.status_code in (200, 201) and bool(matter_id),
         {"status": r.status_code, "name": matter.get("name"),
          "body": r.text[:300] if not matter_id else None})
    if not matter_id:
        print(json.dumps({"results": results}, indent=2, ensure_ascii=False))
        sys.exit(1)
    step("matter_name_cjk_preserved", matter.get("name") == matter_name,
         {"expected": matter_name, "actual": matter.get("name")})
    created["matter_id"] = matter_id

    # ---- 3. upload with a CJK filename ------------------------------------
    docx_bytes, doc_xml = build_docx(RUN1)
    step("fixture_cjk_body_over_200_bytes", len(RUN1.encode("utf-8")) > 200,
         {"utf8_bytes": len(RUN1.encode("utf-8")), "chars": len(RUN1)})
    step("fixture_single_run", doc_xml.count("<w:t>") == 1,
         {"w_t_runs": doc_xml.count("<w:t>")})

    r = c.post(
        BASE + "/api/documents",
        files={"file": (FILENAME, docx_bytes,
                        "application/vnd.openxmlformats-officedocument.wordprocessingml.document")},
        data={"matter_id": matter_id},
        headers=H,
    )
    doc = jbody(r)
    doc_id = doc.get("id")
    created["doc_id"] = doc_id
    v_upload = doc.get("version")
    step("upload_cjk_filename", r.status_code in (200, 201) and bool(doc_id),
         {"status": r.status_code, "name": doc.get("name"),
          "format": doc.get("format"), "version": v_upload,
          "body": r.text[:300] if not doc_id else None})
    if not doc_id:
        print(json.dumps({"results": results}, indent=2, ensure_ascii=False))
        sys.exit(1)
    step("upload_version_is_1", v_upload == 1, {"version": v_upload})
    step("cjk_filename_stem_preserved", doc.get("name") == STEM,
         {"expected": STEM, "actual": doc.get("name")})

    # ---- 4. extract the pristine upload ------------------------------------
    st, ex = extract(c, doc_id, H)
    text = ex.get("text") or ""
    step("extract_status_ok", st == 200,
         {"status": st, "body": ex if st != 200 else None})
    step("extract_cjk_exact_substring", RUN1 in text,
         {"incomplete": ex.get("incomplete"), "pages": ex.get("pages"),
          "spans": len(ex.get("spans") or []),
          "text_len_chars": len(text),
          "text_utf8_bytes": len(text.encode("utf-8")),
          "roundtrip_bytes_match": text.encode("utf-8") == RUN1.encode("utf-8")})
    step("extract_not_incomplete", ex.get("incomplete") is False,
         {"incomplete": ex.get("incomplete")})

    # ---- 5. PUT /edit, no context (diff.rs simple branch) ------------------
    r = c.put(BASE + "/api/documents/" + doc_id + "/edit",
              json={"find": FIND1, "replace": REPL1}, headers=H)
    v2 = jbody(r)
    id2 = v2.get("id")
    step("edit_cjk_no_context",
         r.status_code == 200 and v2.get("version") == 2 and bool(id2),
         {"status": r.status_code, "version": v2.get("version"), "id": id2,
          "body": r.text[:300] if r.status_code != 200 else None})

    # ---- 6. PUT /edit WITH context (diff.rs anchor-arithmetic branch) ------
    # Anchor on the v2 id: apply_edit_to_family resolves latest_doc_in_family,
    # so the anchor arithmetic must be re-exercised on the already-patched XML.
    v3 = {}
    id3 = None
    if id2:
        r = c.put(BASE + "/api/documents/" + id2 + "/edit",
                  json={"find": FIND2, "replace": REPL2,
                        "context_before": CTX_BEFORE, "context_after": CTX_AFTER},
                  headers=H)
        v3 = jbody(r)
        id3 = v3.get("id")
        step("edit_cjk_with_context_anchor",
             r.status_code == 200 and v3.get("version") == 3 and bool(id3),
             {"status": r.status_code, "version": v3.get("version"), "id": id3,
              "body": r.text[:300] if r.status_code != 200 else None})
    else:
        step("edit_cjk_with_context_anchor", False, {"skipped": "no id2"})

    # ---- 7. the edit response's NEW id is the live tip --------------------
    # apply_edit_to_family inserts a NEW row per version; the upload id keeps
    # pointing at the original bytes. Reading back through the upload id is the
    # exact defect that made the previous revision report a false failure.
    if id3:
        st3, ex3 = extract(c, id3, H)
        t3 = ex3.get("text") or ""
        step("edit_response_id_is_tip", id3 not in (doc_id, id2),
             {"upload_id": doc_id, "v2_id": id2, "v3_id": id3})
        step("edited_tip_is_running_text", RUN2 in t3,
             {"status": st3, "text_len_chars": len(t3),
              "roundtrip_bytes_match": t3.encode("utf-8") == RUN2.encode("utf-8")})
        step("edited_tip_contains_replacements", REPL1 in t3 and REPL2 in t3,
             {"has_repl1": REPL1 in t3, "has_repl2": REPL2 in t3})
        step("edited_tip_context_preserved",
             CTX_BEFORE in t3 and CTX_AFTER in t3 and P_A in t3 and P_C in t3
             and P_D in t3,
             {"has_ctx_before": CTX_BEFORE in t3, "has_ctx_after": CTX_AFTER in t3,
              "has_head": P_A in t3, "has_tail": P_C in t3, "has_tail2": P_D in t3})
        step("edited_tip_not_incomplete", ex3.get("incomplete") is False,
             {"incomplete": ex3.get("incomplete")})
        # Tracked changes are NON-DESTRUCTIVE: the original text stays in
        # <w:delText> until /accept, and text_extract.rs reads w:delText on
        # purpose (deleted text still egresses). Asserting the old text is gone
        # here would be wrong -- that is asserted after /accept instead.
        step("edited_tip_retains_original_until_accept",
             FIND1 in t3 and FIND2 in t3,
             {"has_find1": FIND1 in t3, "has_find2": FIND2 in t3,
              "note": "w:delText is retained by design until /accept"})
    else:
        for nm in ("edit_response_id_is_tip", "edited_tip_is_running_text",
                   "edited_tip_contains_replacements", "edited_tip_context_preserved",
                   "edited_tip_not_incomplete",
                   "edited_tip_retains_original_until_accept"):
            step(nm, False, {"skipped": "no id3"})

    # ---- 8. versions list shows every step, CJK stem intact ---------------
    r = c.get(BASE + "/api/documents/" + doc_id + "/versions", headers=H)
    vs = jbody(r)
    names = [v.get("name") for v in vs] if isinstance(vs, list) else []
    vers = [v.get("version") for v in vs] if isinstance(vs, list) else []
    step("versions_after_two_edits",
         r.status_code == 200 and len(vs) == 3 and sorted(vers) == [1, 2, 3]
         and all(n == STEM for n in names),
         {"status": r.status_code, "count": len(vs), "versions": vers,
          "names": names})

    # ---- 9. POST /accept: strip <w:del>, unwrap <w:ins>, keep the CJK -----
    id4 = None
    if id3:
        r = c.post(BASE + "/api/documents/" + id3 + "/accept", headers=H)
        v4 = jbody(r)
        id4 = v4.get("id")
        step("accept_cjk_returns_200",
             r.status_code == 200 and v4.get("version") == 4 and bool(id4),
             {"status": r.status_code, "version": v4.get("version"), "id": id4,
              "body": r.text[:300] if r.status_code != 200 else None})
    else:
        step("accept_cjk_returns_200", False, {"skipped": "no id3"})

    if id4:
        st4, ex4 = extract(c, id4, H)
        t4 = ex4.get("text") or ""
        # Decisive: after /accept the deleted CJK is gone AND the inserted CJK
        # is the running text, byte-for-byte. A byte-slicing bug in
        # remove_tag_blocks/strip_tag_wrappers would truncate or split a CJK
        # sequence and fail one of these.
        step("accepted_text_is_exact", RUN3 in t4 and t4.encode("utf-8") == RUN3.encode("utf-8"),
             {"status": st4, "text_len_chars": len(t4),
              "expected_chars": len(RUN3),
              "expected_bytes": len(RUN3.encode("utf-8")),
              "actual_bytes": len(t4.encode("utf-8")),
              "roundtrip_bytes_match": t4.encode("utf-8") == RUN3.encode("utf-8")})
        step("accepted_deleted_cjk_removed", FIND1 not in t4 and FIND2 not in t4,
             {"has_find1": FIND1 in t4, "has_find2": FIND2 in t4})
        step("accepted_cjk_survives_intact", REPL1 in t4 and REPL2 in t4,
             {"has_repl1": REPL1 in t4, "has_repl2": REPL2 in t4})
        step("accepted_not_incomplete", ex4.get("incomplete") is False,
             {"incomplete": ex4.get("incomplete")})
    else:
        for nm in ("accepted_text_is_exact", "accepted_deleted_cjk_removed",
                   "accepted_cjk_survives_intact", "accepted_not_incomplete"):
            step(nm, False, {"skipped": "no id4"})

    # ---- 9b. remove what this run created ----------------------------------
    # Cleanup also runs from atexit, so a crash earlier still cleans up. Here
    # it runs on the happy path so its status is asserted rather than silent.
    cleanup_status = cleanup()
    step("cleanup_document_deleted",
         cleanup_status.get("document") in (200, 204, 404),
         {"status": cleanup_status.get("document"), "doc_id": doc_id})
    step("cleanup_matter_deleted",
         cleanup_status.get("matter") in (200, 204, 404),
         {"status": cleanup_status.get("matter"), "matter_id": matter_id})

# ---- 10. panic scan across every container that touched this flow ----------
PANIC_MARKERS = ("char boundary", "byte index", "panicked at",
                 "not a char boundary", "Utf8Error", "invalid utf-8")
panics = {}
try:
    import subprocess
    for svc in ("pacgate-api", "deer-flow", "pacgate-mcp", "pacgate-nginx"):
        p = subprocess.run(["docker", "logs", svc], capture_output=True, text=True,
                           errors="replace", timeout=90)
        blob = (p.stdout or "") + (p.stderr or "")
        hits = [ln for ln in blob.splitlines()
                if any(m.lower() in ln.lower() for m in PANIC_MARKERS)]
        panics[svc] = hits[-5:]
except Exception as exc:  # docker unavailable -- report, do not fake a pass
    panics["_error"] = str(exc)

step("no_char_boundary_panics_in_logs",
     bool(panics) and "_error" not in panics
     and all(len(v) == 0 for v in panics.values()),
     {k: (v if v else "clean") for k, v in panics.items()})

out_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cjk_out.json")
with open(out_path, "w", encoding="utf-8") as fh:
    json.dump({"results": results, "failures": failures, "matter_id": matter_id,
               "doc_ids": [doc_id, id2, id3, id4]}, fh, indent=2, ensure_ascii=False)

print(json.dumps({"results": results, "failures": failures,
                  "matter_id": matter_id,
                  "doc_ids": [doc_id, id2, id3, id4]},
                 indent=2, ensure_ascii=False))
sys.exit(1 if failures else 0)
