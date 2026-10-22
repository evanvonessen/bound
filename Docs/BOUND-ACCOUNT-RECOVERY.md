# Bound account recovery and password-protected email changes

Settings → Account & Sync and Friends use the same login form. **Forgot password?**
opens an email form below Sign in, prefilled with the address already entered.
**Send reset link** calls Supabase Auth's public recovery endpoint, with a one-minute
in-memory resend cooldown. Its success text deliberately does not disclose whether
an account exists. It does not sign in, modify a saved session, or save a password.

Signed-in accounts also expose **Reset password** directly in Settings → Account
& Sync, Friends, and Account security. The recovery form shows the authenticated
account email as read-only text and uses the same recovery endpoint and resend
cooldown. Requesting the email preserves the current login and sync session.
Legacy sessions without an email first resolve it from the authenticated user
endpoint, sharing any email lookup already in progress. Expired sessions first
renew their credentials; an unavailable refresh displays retry guidance instead
of silently ignoring the reset. A missing or mismatched identity never sends
recovery mail. Sign-out, account switching, and cancelled requests discard late
recovery responses.

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

The static page in `Docs/site/` clears credential fragments/query strings
immediately, validates the recovered account, shows its email as grey text, and
submits only a new password. Credentials remain in memory, without analytics,
third-party assets or browser storage. Successful reset attempts to revoke the
browser's recovery session; the user then returns to Bound to sign in. Native
account sessions are never replaced by the browser's recovery credentials.

## Live configuration and release verification

On October 21, 2026, the hosted `reset-password.html`, `password-reset.js`, and
`password-reset.css` all returned HTTP 200 without redirects and matched the local
recovery assets byte-for-byte. The page is already published.

The requested Resend sending domain, `auth.evanvonessen.com`, has been created in
North Virginia with ID `2798323b-2565-40fc-8da9-4e6ee5cd3e69`. At 6:42 p.m. PDT on
October 21, 2026, the Resend dashboard showed the domain verified and ready to
send, with Forge and sending enabled, receiving disabled, and tracking not
configured. All three DNS records below were saved in Squarespace after explicit
human confirmation, and live DNS queries returned the exact TXT value and CNAME
targets. Existing root website and Google mail records were left unchanged.
Supabase SMTP credentials and Auth URL configuration still await human action.
No test recovery email has been sent. The sending domain does not change the
recovery-page URL above.

Resend supplied these DNS records for the `evanvonessen.com` zone:

| Type | Host | Value |
| --- | --- | --- |
| TXT | `resend._domainkey.auth` | `p=MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDV8eoPAUcmYzxVHp2Eq35zOESlDOT/WfjayuX+L3AR0prCrjKenwwnDLiqLF1I0Uvr4IzdQ15LEt8KA4Ppm0eAsD3lFK+NwoozOMg4LlUYiwl8Xg6XxYMe+3npXpCZBYkZ1L1kAS9bE8h8XMfbtB9VNMm6hL/iohKpLO4SOxhmKwIDAQAB` |
| CNAME | `rsend.auth` | `rsend.forge.rmta.net` |
| CNAME | `send.auth` | `send.forge.rmta.net` |

These are public DNS values. Receiving remains disabled. Preserve the existing
website and Google records at the root domain; no root DMARC change is required.
Configure Supabase custom SMTP as follows:

| Setting | Value |
| --- | --- |
| Sender | `Bound <noreply@auth.evanvonessen.com>` |
| Host | `smtp.resend.com` |
| Port | `465` |
| Username | `resend` |
| Password | A new Resend sending API key scoped to this domain |

Enter the API key only in Supabase's secret SMTP password field, never in source,
documentation, app configuration or build settings. Keep email link tracking off.

The Supabase Auth dashboard still showed an empty redirect allowlist and
`http://localhost:3000` as the Site URL. Add the exact HTTPS recovery URL above to
the allowed redirects and replace the placeholder Site URL with the production
site. The default recovery email template was verified live to use
`{{ .ConfirmationURL }}`. Preserve that action link so Supabase verifies the link
before redirecting to the page with its recovery access token. The page does not
accept a direct `token_hash` or PKCE-code callback. An unapproved recovery redirect
falls back to the Site URL.

Custom SMTP was disabled at the latest dashboard check. Its non-secret fields
are prepared in a browser draft, but credentials and activation are not saved.
The Resend SMTP endpoint accepted a verified TLS 1.3 connection on port 465;
authenticated sending is not yet tested. Supabase's default email
service is limited to authorized project-team addresses. Domain verification and
published static assets alone do not establish working recovery delivery. The
password-protected email endpoint is deployed; live account mutation remains
unverified.

Use an explicitly owned QA account to verify email delivery, the recovery link,
password update, expired/reused links, rate limits and subsequent native sign-in.
No private Auth/service keys are needed in the page; the public client key matches
`Delta/Bound/cloud-configuration.json` and is verified by the page tests.

References: [Supabase recovery flow](https://supabase.com/docs/reference/javascript/auth-resetpasswordforemail),
[Auth redirects](https://supabase.com/docs/guides/auth/redirect-urls),
[SMTP delivery restrictions](https://supabase.com/docs/guides/auth/auth-smtp),
[Resend SMTP setup](https://resend.com/docs/send-with-supabase-smtp),
[Supabase email templates](https://supabase.com/docs/guides/auth/auth-email-templates), and
[Auth REST contract](https://github.com/supabase/auth/blob/master/openapi.yaml).

## Validation

The October 21 Resend setup checks passed all 14 browser recovery tests, verified
the three hosted assets against local bytes, built the ordinary `Bound.xcodeproj`
/ `Bound` target for Release iPhone, and verified all 17,061 pinned source files.
The Release log is `.build/resend-setup/release-iphone.log`. No email delivery,
real password change, subsequent native sign-in or physical-device recovery was
tested; provider activation remains pending as described above.

The 2026-10-21 recovery/sync fix passed 88 focused native tests, 36 browser/
Dropbox-handler tests, and the account recovery navigation UI test in both UI
versions. The unsigned Release iPhone build and all 17,061 pinned source checks
also passed. Evidence is under `.build/account-sync-fix/`, including
`final-native-tests.xcresult`, `recovery-ui-tests.xcresult`, and
`release-iphone.log`. The Simulator was isolated from personal app data.
No recovery email, real password change, Dropbox consent, cross-device save
restore, or physical-device validation was performed. Server activation remains
pending as described above; successful local tests do not activate the service.

- `node --test PrototypeTools/password-reset.test.mjs` exercises the actual browser
  controller and wiring with synthetic credentials and injected network responses.
- `BoundAccountSocialTests` covers native recovery requests, privacy, resend
  protection, signed-in session preservation, expired-session renewal, shared legacy
  email lookup, errors/cancellation,
  owner changes, and authenticated email display.
- `CompanionUITests.testLibraryAccountSettingsProvidesBoundSignInAndAccountCreation`
  checks the signed-out recovery entry and email prefill in both UI versions without
  sending recovery mail.
- Account persistence and account-linked Dropbox tests guard shared auth behavior.
- Build the ordinary `Bound.xcodeproj` / Bound target for Release iPhone. Simulator
  checks do not establish physical-device or live mail-delivery behavior.

The previous combined account verification passed 105 focused native tests, 83 backend/
browser tests (14 browser-controller cases), 14 SQL contract cases, the unsigned
Release iPhone build, all 17,061 pinned source integrity checks, and diff checks.
Native evidence is in `.build/account-email/final-security-tests.xcresult`; logs are
in `.build/account-email/`. Native execution used an isolated, ad-hoc-signed
simulator. That run did not exercise live email delivery, hosted redirects, or
physical-device recovery. The October 21 check above verifies static hosting only;
email delivery, authenticated recovery completion, and physical-device recovery
remain untested. See [backend deployment details](../Backend/account-security/README.md).
