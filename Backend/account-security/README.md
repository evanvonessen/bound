# Optional Bound account MFA

TOTP is opt-in. A verified factor requires AAL2 for that account's Bound data,
RPCs, Storage and privileged Edge Function operations. Accounts without a
verified factor retain password sign-in and build 12's existing contracts.
Enabling MFA requires a current client for subsequent logins; build 12 cannot
enter an authenticator code. Supabase can revoke other sessions during enrollment.
There is no global MFA requirement and no signup/recovery/confirmation setting
change. Keep a second authenticator or a safely stored setup key: Supabase does
not issue recovery codes for this flow.

## Enforcement

`contract.sql` installs an invoker PostgREST pre-request hook backed by a private,
fixed-search-path definer that reads only the current caller's verified Auth
factors. It never trusts user-editable metadata or accepts a caller-selected user.
Existing hooks at role/database scope cause installation to abort for review.
Five restrictive policies compose with the existing owner policies: Storage
objects and the four public Bound catalogue/revision tables. These protect direct
table and Realtime access, which do not run the REST hook. Future client-readable
tables need the same restrictive guard. No existing RPC body or signature changes.

Service-role Edge Functions bypass client RLS by design. `delete-account` and
`bound-jiggle` now check verified factors and the AAL/sub claims of the exact
bearer already verified by Auth. The new email-change and Dropbox endpoints do
the same. The existing Agora issuer calls the caller-authorized account gate
and friend RPC, so the REST hook protects it. Preauthorized deletion resume
continues to use its existing unguessable capability after sign-out.

MFA token rotation updates the existing native session snapshot and device-only
Keychain. Password/passkey AAL1 login credentials remain in memory until MFA is
verified. Account switching, cancellation and sign-out fence old operations.
Setup secrets/codes are never persisted or logged. The app uses Auth's supported
factor APIs; it does not implement TOTP or store server factor secrets itself.

## Deployment recorded 2026-10-21

Applied `bound_optional_account_mfa` to `qevnxhngdtlyihhmvnjv`, after deploying
the two service-adapter guards (`delete-account` v5, `bound-jiggle` v4). Also
applied the additive email-change and encrypted-Dropbox-link contracts and
deployed `change-account-email` v1 and `bound-dropbox` v1. Global Auth settings
were not modified. Existing Agora issuer v5 was left unchanged.

`compatibility-baseline.json` records the read-only predeployment snapshot:
all 56 original function definitions/signatures and 24 original policies matched
afterward. Seven functions and five restrictive policies were added. No original
table or user data was removed. Live checks confirmed the hook, private-table RLS,
client RPC denial, legacy JWTs without an AAL claim, and public REST reachability.
Advisors reported no new exposed definer: the new policy-free private RLS tables
are intentionally inaccessible except through the service-only adapters.
Existing legacy public-definer/leaked-password advisories were not changed.

**Dropbox activation remains incomplete:** the value-redacted smoke check returns
`503 not_configured`. Configure the independent encryption key and matching
Dropbox app key through a secure secret-management channel as described in
`../dropbox-link/README.md`. The connector cannot set secrets; no existing secret
values were read. The broker fails closed until configured.

`rollback.sql` removes only this enforcement layer and preserves Auth factors.
It aborts if hook configuration changed. Do not roll it back while describing
MFA as protection to enrolled users; coordinate client enrollment availability.
Never remove old RPCs, change legacy arguments or require AAL2 for all users.

## Verification

- 105 native tests, including 21 security, 10 passkey and 18 friend/battle/settings regression tests.
- 83 backend/browser tests; 14 disposable SQL contract cases, including hook
  conflict/rollback atomicity, AAL1/AAL2, owner isolation and legacy access.
- Ordinary Bound Release iPhone build; 17,061 pinned sources verified.
- No real account enrollment, email mutation/delivery, biometric ceremony,
  two-device Dropbox exchange, physical-phone or network playback QA was run.

Current reference: [Supabase MFA](https://supabase.com/docs/guides/auth/auth-mfa).
