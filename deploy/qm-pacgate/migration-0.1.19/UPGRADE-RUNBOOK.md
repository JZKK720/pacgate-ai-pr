# qm 0.1.18 → 0.1.19: verified upgrade path

**Date:** 2026-11-23
**Live:** `@yc-software/qm` 0.1.18, core `988ce509…`, stable (`readyz ok`, agent turns pass)
**Target:** 0.1.19, core `fd3482d2…`
**Verdict: a DIGEST SWAP. No config change, no schema migration, no patch work.**

Everything below was executed against a clone of the live 0.1.18 database, not a fresh
deploy — which is the only way to know whether the upgrade path itself works.

---

## 1. The config does not change at all

The single most useful finding. Our `qm.config.jsonc` — written for 0.1.18 — passes `check`
under 0.1.19 **byte-for-byte, with zero edits**:

```
$ node node_modules/@yc-software/qm/dist/bin/qm.js check --config qm.config.jsonc
· required secrets: ADMIN_GRANTS, AUTH_ALLOWED_EMAILS, AUTH_CLIENT_SECRET, AUTH_SIGNING_JWK, ...
· sign-in email: disabled; use qm admin-login for administrator access
✓ check passed — config, sandbox layer, and plugins are valid.
```

This is the opposite of the 0.1.4 → 0.1.18 hop, where the topology collapsed 5 services to 2
and `check` rejected the config outright. 0.1.18 and 0.1.19 share the **same topology**:

| | 0.1.18 | 0.1.19 |
| --- | --- | --- |
| `manifest.services` | `core`, `egress-proxy` | `core`, `egress-proxy` |
| core digest | `988ce509…` | `fd3482d2…` |
| sandboxBase | `56eae686…` | `4ddeeb8e…` |
| runs migration chain | `…0010 → 0015` | `…0010 → 0015` |

## 2. The database upgrades in place

Tested properly: `pg_dump` of the live 0.1.18 database → restore into a scratch DB → boot
the 0.1.19 core against it.

- `/readyz` → `{"ok":true}`
- **no migration errors at all** — 0.1.19 accepted the 0.1.18 schema as-is

One thing that is NOT optional and cost a cycle to find:

```
[failed] run-results: tenant … Error: database belongs to org pacgate, not pacgate-v19
```

`ORG_ID` must match the org recorded in the database. A clone cannot be booted under a
different org name. This is correct security behaviour (it stops a database being adopted by
another deployment), and it means **an upgrade must keep `orgId` unchanged** — which our
runbook does anyway.

## 3. The model lane is identical

`register-ollama-provider.ps1` ran unmodified against 0.1.19:

```
[ok] provider 'ollama' registered (200)
[ok] org base model -> custom/ollama/minimax-m3.1-flash:cloud (200)
```

The bare-id / `custom/<provider>/<id>` convention, the `PRIVATE_NETWORK_ALLOWED_ORIGINS`
requirement, and `/v1/admin/custom-providers` are all unchanged.

## 4. A real agent turn passes on 0.1.19

```
{"status":"ok","reply":"V19-OK",
 "runtime":{"modelId":"custom/ollama/minimax-m3.1-flash:cloud", ...}}
```

---

## The upgrade, in order

Nothing here is speculative — each step is what the proof run actually needed.

1. **Back up the database.** `pg_dump -Fc`. Non-negotiable.
2. **Bump the pin** in `deploy/qm-pacgate/package.json` to `0.1.19`, then `npm install` for
   BOTH `deploy/qm-pacgate/` and the staged `deploy/client-bundle/qm-pacgate/`, so the
   lockfile and the installed CLI agree. (Skipping this is what made a spike validate with
   the *old* CLI and pass a config the new one rejects — see the 0.1.18 rebuild notes.)
3. **Copy the new digests from the manifest**, do not invent them:
   - `core` → `fd3482d26dafb5e70801561968a91fad1022e9940994c2e9cd083e7008530c6f`
   - `sandboxBase` → `4ddeeb8e9ec6099f6e9484b26715d75864ff8db382fa376ecf10dc27af94f685`
     (repin `sandbox/Dockerfile` — `qm check` does NOT read the `FROM` line, so a stale
     base builds silently on the wrong image.)
4. **Leave `qm.config.jsonc` alone.** Only update it if `check` complains.
5. **Keep `orgId`, `publicUrl`, `basePort` unchanged.** `publicUrl` must stay `basePort+2`
   and must stay `localhost` or HTTPS — `qm admin-login` refuses an HTTP non-localhost URL.
6. **Recreate core only.** Postgres and its volume stay up; the schema needs no reset:
   `docker compose -f compose.qm.yaml up -d --force-recreate core`
7. **Verify, in this order:**
   - `/readyz` → `{"ok":true}` and `RestartCount` stays 0
   - `qm check` with the *installed* CLI
   - `/auth/login` → 302 to `localhost:<publicPort>/idp/authorize` (NOT slack.com)
   - `register-ollama-provider.ps1` → both PUTs 200
   - one agent turn returns `status: ok`

## What NOT to carry over from the 0.1.4 → 0.1.18 rebuild

That migration needed real surgery, and none of it applies here — do not repeat it:

- **No schema reset.** No dropping `sessions`, `runs`, `directory`, `participants`.
- **No manual migration stamping.** No inserting into `qm_schema_migrations`.
- **No tenant consolidation.** The single-tenant state we ended up with stays as it is.
- **No CSV exports.** A `pg_dump` backup is sufficient for a digest swap.
- **No retired-service removal.** `web-ui`/`portal`/`admin`/`auth`/`mailpit` are already gone.

If any of those steps appear necessary, the upgrade is not behaving like the one proven here
and should be stopped and investigated rather than forced.

## Preconditions to check before starting

- [ ] `AUTH_SIGNING_JWK` is P-256 EC with a private `d` (unchanged by 0.1.19, still required)
- [ ] `ADMIN_GRANTS` carries `:org_admin` — without it `qm admin-login` refuses
- [ ] `PRIVATE_NETWORK_ALLOWED_ORIGINS` lists the Ollama origin
- [ ] the docker socket is mounted with `group_add: ["0"]`
- [ ] `dist-tags` checked at the time of the upgrade (`latest` was 0.1.18 and `next` 0.1.19
      when 0.1.19 was a prerelease — **confirm which channel it is on before pinning**)

## Rollback

Cheap, because the schema is compatible in both directions for a digest swap:

1. `pg_restore` the pre-upgrade dump if 0.1.19 wrote anything incompatible (it did not in the
   proof run)
2. revert the pin + digests in `compose.qm.yaml` and `sandbox/Dockerfile`
3. `docker compose up -d --force-recreate core`

Keep the 0.1.18 core digest (`988ce509…`) recorded — it is the rollback target.

---

## 5. Lessons from the 0.1.18 rebuild that will apply again

Recorded because they cost hours and are not obvious from any documentation:

| Symptom | Real cause |
| --- | --- |
| `check` fails with "unknown service web-ui" | the *installed* CLI was a different version than the pin — `node_modules` had not been refreshed |
| `/auth/login` redirects to `slack.com/...client_id=` | `OIDC_AUTH_ENDPOINT` unset; `portal/src/index.ts:169` defaults it to Slack's endpoint |
| `admin probe returned HTTP 401`, then 503 on POST | `admin_grants` bound to a tenant other than the one `deployment_identity` names |
| `qm admin-login` refuses | `ADMIN_GRANTS` lacks `:org_admin` |
| core restart-loops on a migration guard | the DB predates a migration the new release needs an intermediate for — check `qm_schema_migrations` for the id the error names |
| `CREATE DATABASE` fails after `DROP` | Postgres collation-version mismatch on `template1`; `ALTER DATABASE template1 REFRESH COLLATION VERSION` |

None of these should appear in a 0.1.18 → 0.1.19 upgrade, because the proof run hit none of
them. They are here so that if one does appear, it is recognised rather than re-diagnosed.
