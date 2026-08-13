import base64
import hashlib
import hmac
import html
import os
import time
import urllib.parse
from http import cookies
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


USERNAME = os.environ.get("PACGATE_VIEWER_USERNAME")
PASSWORD = os.environ.get("PACGATE_VIEWER_PASSWORD")
SESSION_SECRET = os.environ.get("PACGATE_SESSION_SECRET")
COOKIE_NAME = os.environ.get("PACGATE_SESSION_COOKIE", "pacgate_viewer_session")
COOKIE_MAX_AGE = int(os.environ.get("PACGATE_SESSION_MAX_AGE", "43200"))
COOKIE_SECURE = os.environ.get("PACGATE_COOKIE_SECURE", "false").lower() in {"1", "true", "yes", "on"}
PORT = int(os.environ.get("PORT", "3000"))


if not USERNAME or not PASSWORD or not SESSION_SECRET:
    raise RuntimeError("PACGATE_VIEWER_USERNAME, PACGATE_VIEWER_PASSWORD, and PACGATE_SESSION_SECRET are required")


def safe_next(raw_value):
    if not raw_value:
        return "/"
    if not raw_value.startswith("/"):
        return "/"
    if raw_value.startswith("//"):
        return "/"
    return raw_value


def sign_session(username, expires_at):
    payload = f"{username}:{expires_at}"
    signature = hmac.new(
        SESSION_SECRET.encode("utf-8"),
        payload.encode("utf-8"),
        hashlib.sha256,
    ).hexdigest()
    token = f"{payload}:{signature}".encode("utf-8")
    return base64.urlsafe_b64encode(token).decode("ascii").rstrip("=")


def verify_session(token):
    if not token:
        return None
    padded = token + ("=" * (-len(token) % 4))
    try:
        decoded = base64.urlsafe_b64decode(padded.encode("ascii")).decode("utf-8")
        username, expires_at, signature = decoded.split(":", 2)
        expected = hmac.new(
            SESSION_SECRET.encode("utf-8"),
            f"{username}:{expires_at}".encode("utf-8"),
            hashlib.sha256,
        ).hexdigest()
        if not hmac.compare_digest(signature, expected):
            return None
        if int(expires_at) < int(time.time()):
            return None
        return username
    except Exception:
        return None


def render_login(next_path, error_message=""):
    escaped_next = html.escape(next_path, quote=True)
    error_block = ""
    if error_message:
        error_block = f'<p class="error">{html.escape(error_message)}</p>'

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Pacgate AI Viewer Login</title>
  <style>
    :root {{
      --bg: #070b14;
      --surface: #0f1623;
      --surface-2: #141c2e;
      --border: #1e2d4a;
      --gold: #c8a84b;
      --gold-2: #e8c97a;
      --text: #e2e8f4;
      --muted: #7c8ba7;
      --danger: #d66b56;
      --shadow: 0 30px 80px rgba(0, 0, 0, 0.35);
    }}
    * {{ box-sizing: border-box; }}
    body {{
      margin: 0;
      min-height: 100vh;
      display: grid;
      place-items: center;
      background:
        radial-gradient(circle at top, rgba(200, 168, 75, 0.12), transparent 28%),
        linear-gradient(180deg, #0a1020 0%, var(--bg) 55%, #05070d 100%);
      color: var(--text);
      font-family: "Segoe UI", system-ui, -apple-system, BlinkMacSystemFont, sans-serif;
      padding: 24px;
    }}
    .shell {{
      width: min(960px, 100%);
      display: grid;
      grid-template-columns: 1.1fr 0.9fr;
      border: 1px solid var(--border);
      border-radius: 24px;
      overflow: hidden;
      background: rgba(15, 22, 35, 0.94);
      box-shadow: var(--shadow);
    }}
    .brand {{
      padding: 48px;
      background:
        linear-gradient(160deg, rgba(200, 168, 75, 0.10), transparent 42%),
        linear-gradient(180deg, rgba(61, 109, 232, 0.08), transparent 55%),
        var(--surface);
      border-right: 1px solid var(--border);
      display: flex;
      flex-direction: column;
      justify-content: space-between;
      gap: 24px;
    }}
    .eyebrow {{
      display: inline-flex;
      width: fit-content;
      padding: 6px 10px;
      border-radius: 999px;
      border: 1px solid rgba(200, 168, 75, 0.28);
      background: rgba(200, 168, 75, 0.10);
      color: var(--gold-2);
      font-size: 12px;
      font-weight: 700;
      letter-spacing: 0.08em;
      text-transform: uppercase;
    }}
    .brand h1 {{
      margin: 18px 0 12px;
      font-size: clamp(32px, 4vw, 46px);
      line-height: 1.05;
      letter-spacing: -0.03em;
    }}
    .brand p {{
      margin: 0;
      max-width: 34rem;
      color: var(--muted);
      font-size: 15px;
      line-height: 1.7;
    }}
    .meta {{
      display: grid;
      gap: 12px;
      padding-top: 12px;
    }}
    .meta-card {{
      padding: 14px 16px;
      border: 1px solid rgba(200, 168, 75, 0.14);
      border-radius: 16px;
      background: rgba(20, 28, 46, 0.70);
    }}
    .meta-card strong {{ display: block; margin-bottom: 6px; color: var(--gold-2); }}
    .panel {{
      padding: 40px;
      background: var(--surface-2);
      display: flex;
      flex-direction: column;
      justify-content: center;
    }}
    .panel h2 {{ margin: 0 0 10px; font-size: 28px; }}
    .panel p {{ margin: 0 0 24px; color: var(--muted); line-height: 1.65; }}
    form {{ display: grid; gap: 16px; }}
    label {{ display: grid; gap: 8px; font-size: 13px; color: var(--gold-2); font-weight: 600; }}
    input {{
      width: 100%;
      padding: 14px 15px;
      border-radius: 14px;
      border: 1px solid var(--border);
      background: rgba(7, 11, 20, 0.72);
      color: var(--text);
      font-size: 15px;
      outline: none;
    }}
    input:focus {{ border-color: rgba(200, 168, 75, 0.62); box-shadow: 0 0 0 3px rgba(200, 168, 75, 0.12); }}
    button {{
      margin-top: 4px;
      padding: 14px 16px;
      border: none;
      border-radius: 14px;
      background: linear-gradient(135deg, var(--gold), var(--gold-2));
      color: #070b14;
      font-size: 15px;
      font-weight: 800;
      letter-spacing: 0.02em;
      cursor: pointer;
    }}
    .error {{
      margin: -4px 0 4px;
      padding: 12px 14px;
      border-radius: 14px;
      border: 1px solid rgba(214, 107, 86, 0.3);
      background: rgba(214, 107, 86, 0.12);
      color: #ffd8cf;
      font-size: 14px;
    }}
    .foot {{ margin-top: 18px; color: var(--muted); font-size: 12px; }}
    @media (max-width: 860px) {{
      .shell {{ grid-template-columns: 1fr; }}
      .brand {{ border-right: none; border-bottom: 1px solid var(--border); padding: 32px; }}
      .panel {{ padding: 32px; }}
    }}
  </style>
</head>
<body>
  <div class="shell">
    <section class="brand">
      <div>
        <span class="eyebrow">Protected Access</span>
        <h1>Pacgate AI</h1>
        <p>This viewer hosts proposal materials, architecture reports, and build-plan deliverables prepared for Pacgate Law.</p>
      </div>
      <div class="meta">
        <div class="meta-card">
          <strong>Private Preview</strong>
          Viewer access is controlled before any documentation or diagram assets are served.
        </div>
        <div class="meta-card">
          <strong>Deployment Note</strong>
          Credentials are loaded from environment at container start, not from tracked repo config.
        </div>
      </div>
    </section>
    <section class="panel">
      <h2>Viewer Sign In</h2>
      <p>Enter the shared viewer credential to access the hosted Pacgate AI documentation set.</p>
      <form method="post" action="/login">
        <input type="hidden" name="next" value="{escaped_next}">
        {error_block}
        <label>
          Username
          <input type="text" name="username" autocomplete="username" required>
        </label>
        <label>
          Password
          <input type="password" name="password" autocomplete="current-password" required>
        </label>
        <button type="submit">Open Viewer</button>
      </form>
      <div class="foot">Cubecloud x Pacgate Law proposal preview</div>
    </section>
  </div>
</body>
</html>
"""


class AuthHandler(BaseHTTPRequestHandler):
    server_version = "PacgateAuth/1.0"

    def log_message(self, fmt, *args):
        return

    def _cookie_header(self, value, max_age):
        jar = cookies.SimpleCookie()
        jar[COOKIE_NAME] = value
        jar[COOKIE_NAME]["path"] = "/"
        jar[COOKIE_NAME]["httponly"] = True
        jar[COOKIE_NAME]["samesite"] = "Lax"
        jar[COOKIE_NAME]["max-age"] = str(max_age)
        if COOKIE_SECURE:
            jar[COOKIE_NAME]["secure"] = True
        return jar.output(header="").strip()

    def _current_user(self):
        raw_cookie = self.headers.get("Cookie")
        if not raw_cookie:
            return None
        jar = cookies.SimpleCookie()
        jar.load(raw_cookie)
        morsel = jar.get(COOKIE_NAME)
        if not morsel:
            return None
        return verify_session(morsel.value)

    def _send_html(self, content, status=200):
        encoded = content.encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(encoded)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(encoded)

    def _send_redirect(self, location, cookie_header=None):
        self.send_response(302)
        self.send_header("Location", location)
        self.send_header("Cache-Control", "no-store")
        if cookie_header:
            self.send_header("Set-Cookie", cookie_header)
        self.end_headers()

    def _send_status(self, status):
        self.send_response(status)
        self.send_header("Cache-Control", "no-store")
        self.end_headers()

    def do_HEAD(self):
      parsed = urllib.parse.urlparse(self.path)
      path = parsed.path

      if path == "/healthz":
        self._send_status(204)
        return

      if path == "/auth/check":
        if self._current_user():
          self._send_status(204)
        else:
          self._send_status(401)
        return

      if path == "/logout":
        self._send_redirect("/login", self._cookie_header("", 0))
        return

      if path == "/login":
        next_path = safe_next(urllib.parse.parse_qs(parsed.query).get("next", ["/"])[0])
        if self._current_user():
          self._send_redirect(next_path)
          return
        content = render_login(next_path).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(content)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        return

      self._send_status(404)

    def do_GET(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path

        if path == "/healthz":
            self._send_status(204)
            return

        if path == "/auth/check":
            if self._current_user():
                self._send_status(204)
            else:
                self._send_status(401)
            return

        if path == "/logout":
            self._send_redirect("/login", self._cookie_header("", 0))
            return

        if path == "/login":
            next_path = safe_next(urllib.parse.parse_qs(parsed.query).get("next", ["/"])[0])
            if self._current_user():
                self._send_redirect(next_path)
                return
            self._send_html(render_login(next_path))
            return

        self._send_status(404)

    def do_POST(self):
        parsed = urllib.parse.urlparse(self.path)
        path = parsed.path

        if path == "/logout":
            self._send_redirect("/login", self._cookie_header("", 0))
            return

        if path != "/login":
            self._send_status(404)
            return

        content_length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(content_length).decode("utf-8")
        form = urllib.parse.parse_qs(body)

        username = form.get("username", [""])[0]
        password = form.get("password", [""])[0]
        next_path = safe_next(form.get("next", ["/"])[0])

        if hmac.compare_digest(username, USERNAME) and hmac.compare_digest(password, PASSWORD):
            token = sign_session(username, int(time.time()) + COOKIE_MAX_AGE)
            self._send_redirect(next_path, self._cookie_header(token, COOKIE_MAX_AGE))
            return

        self._send_html(render_login(next_path, "Invalid username or password."), status=401)


if __name__ == "__main__":
    server = ThreadingHTTPServer(("0.0.0.0", PORT), AuthHandler)
    server.serve_forever()