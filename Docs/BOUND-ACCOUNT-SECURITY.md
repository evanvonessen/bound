# Bound account security

Settings → Account & Sync → Account and Security and Friends → Account and
Security group username changes, email changes, password recovery and optional
authenticator-based two-factor authentication. Add Bound to an authenticator
using the QR code or manual key, then enter a code to enable it. Users can add a
backup authenticator and remove factors after verification. Keep the setup key
private and recoverable; no recovery codes are generated.

After password or passkey authentication, users with a verified factor enter
their authenticator code before Bound publishes or saves the session. Cancelling
clears that pending sign-in. Successful verification rotates the refresh token
and saves it using the existing device-only Keychain policy. Sign-out clears
pending work and stops account-linked Dropbox credentials from crossing accounts.

Enabling two-factor authentication can sign other devices out. Use the updated
Bound app on every device for an account with 2FA. Accounts that do not enable
2FA keep build 12's password/session/data behavior. Existing RPC definitions,
signatures and owner policies are preserved, with optional MFA enforcement added.

See [backend deployment and compatibility evidence](../Backend/account-security/README.md)
and [recovery/email changes](BOUND-ACCOUNT-RECOVERY.md).

## Passkeys: support prepared, activation intentionally pending

The native AuthenticationServices bridge supports passkey registration, sign-in,
listing and removal. Platform private keys stay with the system credential
provider. Challenges are pinned to an explicitly configured relying-party domain
and validated before opening the system prompt. There is no dependency upgrade.
Passkey sign-in still requires TOTP when that account has MFA enabled.

Per the user's choice, `passkeyRelyingPartyID` remains absent from
`Delta/Bound/cloud-configuration.json`, so passkey actions remain unavailable.
Activation requires all of:

1. A stable owned RP domain and Supabase's passkey/WebAuthn RP configuration.
2. HTTPS `/.well-known/apple-app-site-association` at that domain's root, with
   `webcredentials.apps` containing `3N83BX5M9G.com.evanvonessen.bound`.
3. The matching `webcredentials:<domain>` associated-domains entitlement in the
   app's active entitlement file and distribution provisioning profile.
4. The same domain in public `passkeyRelyingPartyID`, followed by signed-device QA.

The current `evanvonessen.github.io/bound/` project Pages path cannot host this
domain-root association. Do not enable a guessed domain or change the RP ID after
enrollment. Supabase's currently documented passkey API is experimental, so
recheck the official contract before activation. The Bound capability remains
part of the normal account UI; no experimental-feature setting gates it.

References: [Supabase passkeys](https://supabase.com/docs/guides/auth/passkeys),
[Apple passkey service association](https://developer.apple.com/documentation/authenticationservices/connecting-to-a-service-with-passkeys).
