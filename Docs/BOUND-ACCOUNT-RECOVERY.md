# Bound account recovery and password-protected email changes

Settings → Account & Sync and Friends use the same login form. **Forgot password?**
opens an email form below Sign in, prefilled with the address already entered.
**Send reset link** calls Supabase Auth's public recovery endpoint, with a one-minute
in-memory resend cooldown. Its success text deliberately does not disclose whether
an account exists. It does not sign in, modify a saved session, or save a password.
Signed-in accounts show their authenticated email in grey in both surfaces. Tap
it to open a new-email and current-password form. The server rechecks the current
password and live Bound session, confirms the new email for this operation, and
keeps the same account UUID and data. After confirmed success, Bound clears its
local session and asks the user to sign in with the new email and same password.

The sheet remains visible with a success receipt until the user taps **Sign in**.
Sign-out, cancellation, account switching and late responses cannot change another
account locally. Passwords are never persisted. Accounts with MFA must already
have an AAL2 session. See [the endpoint contract](../Backend/account-email/README.md)
for rate limits, temporary-session cleanup and in-flight Auth update limits.

Email display uses `user.email` from the authenticated login/signup/refresh
response, with the existing token's email claim for offline restoration. The typed
login address is never used as identity. Legacy sessions missing the email claim
can load it from the authenticated `/auth/v1/user` response, with owner/session
checks and late-response fencing. Sign-out clears the display. There is no new
plaintext email field in persisted session storage.

## Recovery email completion

The native recovery request uses exactly:

`https://evanvonessen.github.io/bound/reset-password.html`

The new static page in `Docs/site/` clears credential fragments/query strings
immediately, validates the recovered account, shows its email as grey text, and
submits only a new password. Credentials remain in memory, without analytics,
third-party assets or browser storage. Successful reset attempts to revoke the
browser's recovery session; the user then returns to Bound to sign in. Native
account sessions are never replaced by the browser's recovery credentials.

## Before enabling in a release

No recovery email has been sent or global Auth settings changed. The
password-protected email endpoint is deployed; live account mutation remains
unverified. Publish the new `reset-password.html`, `password-reset.js` and
`password-reset.css` through the existing Pages workflow, preserving unrelated
site edits. Confirm the exact HTTPS URL above is accepted by the project's
Supabase Auth redirect configuration and that its recovery email template links
through `ConfirmationURL` / the configured redirect. An invalid redirect can fall
back to the Site URL, whose existing landing page has no recovery handler.

Use an explicitly owned QA account to verify email delivery, the recovery link,
password update, expired/reused links, rate limits and subsequent native sign-in.
No private Auth/service keys are needed in the page; the public client key matches
`Delta/Bound/cloud-configuration.json` and is verified by the page tests.

References: [Supabase recovery flow](https://supabase.com/docs/reference/javascript/auth-resetpasswordforemail),
[Auth redirects](https://supabase.com/docs/guides/auth/redirect-urls), and
[Auth REST contract](https://github.com/supabase/auth/blob/master/openapi.yaml).

## Validation

- `node --test PrototypeTools/password-reset.test.mjs` exercises the actual browser
  controller and wiring with synthetic credentials and injected network responses.
- `BoundAccountSocialTests` covers native recovery requests, privacy, resend
  protection, errors/cancellation, owner changes, and authenticated email display.
- Account persistence and account-linked Dropbox tests guard shared auth behavior.
- Build the ordinary `Bound.xcodeproj` / Bound target for Release iPhone. Simulator
  checks do not establish physical-device or live mail-delivery behavior.

The combined account verification passed 105 focused native tests, 83 backend/
browser tests (14 browser-controller cases), 14 SQL contract cases, the unsigned
Release iPhone build, all 17,061 pinned source integrity checks, and diff checks.
Native evidence is in `.build/account-email/final-security-tests.xcresult`; logs are
in `.build/account-email/`. Native execution used an isolated, ad-hoc-signed
simulator. Live email delivery, hosted redirect and physical-device recovery
were not exercised. See [backend deployment details](../Backend/account-security/README.md).
