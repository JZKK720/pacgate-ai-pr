# qm secret-drop: a one-character signature difference is corruption, not a key mismatch

**Date:** 2026-11-24
**Symptom:** the Pacgate-API credential link from the qm agent returned
`404 This link has expired` for a signed-in owner, while a second link minted the
same way worked.
**Verdict:** the link was **not** expired and the key was **not** wrong. One
character of the HS256 signature was corrupted when the URL was transcribed.

---

## 1. What the drop route actually requires

`/drop/:id/form` is NOT a self-contained secret form. It is gated on a signed-in
qm user, and the recipient must be the drop owner:

```
dropForm()
  peek(id)                            -> 404 "expired" page if the record is gone
  dropLinkClaims(id, rec)             -> 404 "expired" page if the token fails
  samePerson(x-drop-owner, ownerId)   -> 403 "not yours"
```

`dropLinkClaims` (`secret-drop.ts:168`) accepts the token only when **all** of
these hold:

| Condition | Value for this drop |
| --- | --- |
| `verifyCapabilityToken(t, capSecret)` | signature + shape |
| `claims.aud === "secret-drop"` | ok |
| `claims.drop === dropId` | ok |
| `samePerson(claims.actorId, rec.ownerId)` | both `admin@pacgate-law.com` |
| `claims.scopeId === rec.audienceScopeId` | both `personal:admin@pacgate-law.com` |

So a `404 expired` means the **token** failed, even when the record is present and
unused. That is misleading: the page says "single-use, ask the agent for a fresh
one", which sends the reader looking for a new link instead of at the link they
have.

## 2. What was actually wrong

The signing secret is `CAPABILITY_SECRET`, not `AUTH_TOKEN_SECRET`
(`secret-drop.ts:174` reads `deps.capabilitySecret ?? ctx.secret`, and
`config.ts:594` maps `CAPABILITY_SECRET` into it). Its `kid` fingerprint is
`M_ZJA9fg`, which matched the token's header — so the secret was right.

Recomputing the HMAC over the exact signing input gave a signature identical to
the token's in **42 of 43 characters**:

```
token sig : Liwob2TLF2uS7fKUpvR IKPpDjgicTFai71OymNOwK94
computed  : Liwob2TLF2uS7fKUpvF IKPpDjgicTFai71OymNOwK94
                               ^ one character: 'R' vs 'F'
```

That is the decisive measurement. HMAC-SHA256 is deterministic and
avalanche-sensitive: a wrong key or a different signing input changes roughly half
the output, not one character. A single-character difference can only come from
**the signature string being altered in transit** — a transcription slip.

The second link, minted by the same agent with the same secret, verified
**byte-for-byte** and rendered its form (`HTTP 200`, field `OpenViking Root API
Key`). So the mechanism is sound; one URL was damaged.

## 3. How to tell these apart, in one command

```powershell
# compute what the live secret produces for the token's own signing input
$p = $token.Split('.')
$si = "$($p[0]).$($p[1])"
$hm = [System.Security.Cryptography.HMACSHA256]::new(
        [Text.Encoding]::UTF8.GetBytes($capabilitySecret))
$mine = [Convert]::ToBase64String($hm.ComputeHash([Text.Encoding]::UTF8.GetBytes($si)))
          .Replace('+','-').Replace('/','_').TrimEnd('=')

$mine -eq $p[2]        # exact match  -> the link should work
# differ in 1-3 chars  -> the pasted URL was altered; re-mint or copy again
# differ in ~half      -> genuinely a different secret or a different payload
```

## 4. The fix applied

The drop record was intact (`usedAt` empty, owner correct), so the link was
re-minted against the same record with the same claims and the same `exp`. It
renders:

```
HTTP 200   form id=f   field: "Pacgate API Token (Bearer)"
```

The original broken URL and the corrected one differ only inside the signature,
which is the proof that nothing else was wrong.

**Nothing was redeemed.** `secret_drops.usedAt` is still empty for both links, so
the credential can be submitted once, normally, by the owner.

## 5. Traps worth remembering

1. **`404 This link has expired` is the wrong message for a bad signature.** It
   conflates "record gone" with "token invalid" and pushes the reader toward
   re-minting. `dropFormHtml(id, null)` is the single path for both.
2. **The signing secret is `CAPABILITY_SECRET`.** Testing `AUTH_TOKEN_SECRET` or
   `AUTH_CLIENT_SECRET` looks plausible and is wrong; the `kid` in the token header
   tells you which secret produced it (`signingKeyId = HMAC(secret,
   "qm-signing-key-id")[0..8]`).
3. **A drop link is a bearer URL.** It is single-use and bound to one owner. Treat
   it like a credential in chat logs, and do not paste a fresh one into a channel
   others can read.
4. **`/drop/...` redirects to `/auth/login` when anonymous.** That 302 is correct
   behaviour, not a broken link; the failure only appears after sign-in, which is
   why a logged-out copy/paste looks fine.
