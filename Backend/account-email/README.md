# Bound password-authorized email change

The native account email opens a form for a new address and the **current
password**. This endpoint changes the existing Bound user's email; it never
chooses a different owner or moves account data. The server confirms only this
new email through the Auth administrator API. Signup confirmations, recovery,
secure email-change settings and every other global Auth setting stay as they
are. No email-ownership challenge is sent for this operation, as requested.
The current password proves authority over the Bound account; it does not prove
the user owns the entered mailbox, so a typo can affect future login/recovery.

## Endpoint contract

Deploy `index.ts` and `handler.mjs` as **change-account-email** for project
`qevnxhngdtlyihhmvnjv`, with `verify_jwt=false`. The handler verifies the exact
bearer with Auth getUser and checks its original live `auth.sessions` row through
the private SQL operation before privileged work. Keep existing server-only
`SUPABASE_SERVICE_ROLE_KEY` and `CUPCAKE_SUPABASE_PUBLISHABLE_KEY` configuration.
The service-role key never belongs in the app. No new secret is required.

`POST /functions/v1/change-account-email`, JSON content type, bearer session:

```json
{"newEmail":"next@example.com","currentPassword":"the exact current password"}
```

Those are the only accepted fields. Password whitespace is preserved; empty,
NUL-containing or over-1024-byte values are rejected. Request bodies are capped
at 8192 bytes; upstream JSON is bounded and timed. Native requests must have no
browser `Origin` header. Responses use `Cache-Control: no-store`.

Success: `200 {"ok":true,"email":"next@example.com"}`. Native UI clears the
saved Bound login after confirmed success and asks the user to sign in with the
new address. Account owner ID, content and account-linked Dropbox grant retain
their existing ownership.

Errors contain only `{"error":"code"}`:

| Status | Codes |
| --- | --- |
| 400 | `invalid_request` |
| 401 | `unauthorized` |
| 403 | `invalid_password`, `forbidden` (browser origin) |
| 405 | `method_not_allowed` |
| 409 | `email_unavailable`, `account_changed`, `change_in_progress` |
| 429 | `rate_limited` |
| 503 | `not_configured`, `unavailable` |

Wrong passwords and owner/email mismatches never disclose raw Auth errors.
Email collisions use a generic error. Unsupported upstream errors remain
`unavailable`; responses never contain a password, refresh token, temporary
access token, administrative credential or upstream diagnostic body.

## Authorization and concurrency

1. Auth getUser must report an authenticated, confirmed, non-anonymous account.
   The owner and current email come from this response, never caller input. The
   already-verified JWT must contain the matching owner and a session ID.
   Accounts with verified MFA factors require an existing AAL2 caller session;
   an AAL1 bearer plus a password cannot bypass their second factor.
2. `bound_account_email` checks the original live session, current Auth email,
   deletion marker and an account-wide two-minute operation lease. It limits
   password attempts to five per account per 15 minutes, across devices. It is
   service-only; clients cannot read the private table or invoke the RPC.
3. A password grant uses the **actual current email** and supplied password. Its
   returned owner/email must match. Its distinct temporary session is revoked
   with `scope=local` before proceeding. No native bearer or other device is
   signed out by this server proof step. A missing/reused temporary session ID
   fails closed without calling logout, because upstream can otherwise fall
   back to a global logout. Cleanup failures block the update and are retried
   once in `finally`; no temporary token is exposed or retained by Bound.
4. The server fetches the bearer user again, then checks original session,
   email, deletion marker and lease immediately before the administrative PUT
   for that exact owner, with `{email:newEmail,email_confirm:true}`. A stale
   operation, account switch, revoked/expired session or pending deletion fails.
5. The response must contain the exact owner, confirmed new email and valid
   account. After a lost admin response, an administrative lookup reconciles
   actual state. A retry already targeting the current email still requires
   fresh matching current-password proof and the same live checks; it returns
   success without another PUT. The release clears transient email/session
   fields and preserves the rate counter. Owner deletion cascades the row.

The deletion RPC's advisory lock coordinates each database authorization check.
The final Auth HTTP request and that SQL check are separate transactions. Once
fully authorized, an in-flight Auth update cannot be rolled back just because
another device signs out or account deletion starts at the same instant. This
implementation deliberately does not claim atomic revocation/deletion across
HTTP and SQL, add triggers to managed Auth tables, or change Auth's own flows.
Physical Auth deletion still prevents an update from recreating a user. A
pending deletion retains its original owner/capability and remains resumable.

When a password-grant response itself is lost, the server cannot recover a
temporary token it never received. Auth expiration/session policy controls
that unreachable session; it is never returned to the app. Native cancellation
does not roll back an already-accepted update. After an uncertain result, retry
with the intended new address/current password to reconcile, or sign in using
the new address.

## Deployment and verification

The private contract and `change-account-email` v1 were deployed on 2026-10-21.
The unauthenticated endpoint rejects requests with 401, and live SQL confirmed
RLS and client RPC denial. Existing function definitions and policies remained
unchanged. No real user email change, password proof or email delivery was run.
Global Auth settings were not modified. See `../account-security/README.md`.

1. Inspect the live deletion contract and Auth session columns against the SQL
   dependencies. Apply `contract.sql` transactionally, then deploy the two Edge
   Function files under the exact endpoint name above. No managed Auth table or
   trigger is modified. This is a reviewable SQL contract, not a generated
   Supabase migration-history entry.
2. Run database advisors for the target project. Confirm private schema access
   remains revoked, table RLS enabled, and RPC execution service-only.
3. With a separately authorized disposable account, verify old/new sign-in,
   duplicate address, whitespace password, rate limits, AAL1/AAL2 behavior,
   temporary-session cleanup and original-session preservation. Verify that
   email-change confirmation mail is absent, signup/recovery remain intact,
   and previously issued recovery/email-change tokens cannot take over the
   updated account on the deployed Auth version. Test lost response and retry,
   account switching, sign-out and account deletion during a request.
4. Ship the native app only after its focused checks and Release iPhone build.
   Local injected-network/SQL tests are not live email/Auth or phone validation.

Local checks:

```sh
node --test Backend/account-email/handler.test.mjs
PGLITE_MODULE=/absolute/path/to/@electric-sql/pglite/dist/index.js node --test Backend/account-email/contract.test.mjs
```

Official references checked during implementation: [Admin user updates](https://supabase.com/docs/reference/javascript/auth-admin-updateuserbyid),
[sign-out scopes](https://supabase.com/docs/reference/javascript/auth-signout),
and the [Auth admin implementation](https://github.com/supabase/auth/blob/master/internal/api/admin.go).
The changelog Markdown fetch was attempted, but the available network paths
rejected its content type or lacked DNS; the current API docs and upstream Auth
source were reachable. Hosted Auth compatibility still needs the live checks
above.
