# 🚨 OPERATOR ONLY — DO NOT COMMIT, DO NOT SHARE 🚨

> **This file is gitignored.** It contains real credentials for the PacGate GitHub account that the public handbook must never see. If you are reading this on a public clone, you are reading stale or fake data.
>
> The published handbook uses placeholders such as `{{GITHUB_EMAIL}}` and `{{GITHUB_PASSWORD}}` so the public handbook stays safe to commit and share.

---

## Real PacGate GitHub credentials

| Field | Value |
|---|---|
| **Email** | `pacgate.ai01@outlook.com` |
| **GitHub ID** | `pacgate-ai` |
| **Password** | `Cc_Pacgate@123` |

> ⚠️ Anyone holding these three values can sign in to the PacGate GitHub organization and authorize third-party OAuth apps (Tailscale, etc.) on its behalf. Treat this file like a root password.

---

## How to use this file

1. Read the placeholders in the published handbook (e.g. `{{GITHUB_EMAIL}}`).
2. Look up the real value in the table above.
3. Paste it into the sign-in form.

## After first-run Tailscale auth — record the machine

| Field | Value |
|---|---|
| Tailscale machine name | _(fill in after first sign-in — usually `pacgate-win01`)_ |
| Tailscale 100.x IP | _(fill in after `tailscale ip -4`)_ |
| Tailscale MagicDNS name | _(fill in after `tailscale status`)_ |
| RustDesk permanent ID | _(fill in from RustDesk main window)_ |
| RustDesk permanent password | _(set in step `08_rustdesk_permanent_password.md`; store in your password manager, not here)_ |

## After setup — rotate

- Change the GitHub password and remove the OAuth grant from <https://github.com/settings/applications> if this operator no longer needs access.
- Re-generate the RustDesk permanent password by re-entering Settings → Security.
