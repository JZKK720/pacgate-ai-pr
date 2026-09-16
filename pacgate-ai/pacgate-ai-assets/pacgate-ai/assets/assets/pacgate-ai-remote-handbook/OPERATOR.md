# 🚨 OPERATOR ONLY — DO NOT COMMIT, DO NOT SHARE 🚨

> **This file must never be committed.** It is meant to hold real credentials for
> the PacGate account that the public handbook must never see.
>
> **Correction (2026-09-15):** an earlier version of this note claimed *"This file
> is gitignored."* That was **false** — the file was tracked and published in a
> public repository, and the credential values it contained must be treated as
> **compromised and rotated**. See `plans/013-credential-rotation.md`.
>
> Real values are deliberately **not** stored here. Keep them in a password
> manager, and reference them by name only.
>
> The published handbook uses placeholders such as `{{GITHUB_EMAIL}}` and
> `{{GITHUB_PASSWORD}}` so the public handbook stays safe to commit and share.

---

## Real PacGate credentials

> ⚠️ **Not stored in this file.** Look these up in the password manager.

| Field | Value |
|---|---|
| **Email** | `[REDACTED - see password manager]` |
| **GitHub ID** | `[REDACTED - see password manager]` |
| **Password** | `[REDACTED - see password manager]` |

> ⚠️ Anyone holding these three values can sign in to the PacGate GitHub organization and authorize third-party OAuth apps (Tailscale, etc.) on its behalf. Treat this file like a root password.

---

## How to use this file

1. Read the placeholders in the published handbook (e.g. `{{GITHUB_EMAIL}}`).
2. Look up the real value in the **password manager** (not in this file).
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
