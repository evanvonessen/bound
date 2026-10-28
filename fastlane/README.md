# Local Bound builds and TestFlight

Install dependencies using a managed Ruby (not macOS system Ruby) and Bundler:

```sh
bundle config set --local path .build/gems
bundle install
```

Use `PrototypeTools/fastlane-local --check-environment` to check the installed
locked gems without starting Fastlane. The wrapper selects this checkout's
`Gemfile` and `.build/gems`, including in detached/non-login shells. It never
installs dependencies automatically. An explicit `BUNDLE_PATH` remains supported.

From the repository root, run:

```sh
PrototypeTools/fastlane-local ios verify
```

This builds `Bound.xcodeproj` / `Bound` in Release for a generic arm64 iPhone.
Build products use `.build/fastlane/DerivedData/<location-key>`; the key includes
the real checkout and Xcode developer paths so relocated caches are not reused.
Existing `.build/ReleaseDerivedData` is preserved but no longer used by `verify`.
Raw Xcode logs are saved
under `.build/fastlane/logs`. Swift package versions stay pinned to
`Package.resolved`. The lane does not sign, install, archive, or upload the app,
and does not require Apple credentials.

Running this command directly in Terminal uses no Codex tokens. Asking Codex to
run it still uses tokens for the request, tool calls, and interpreting results;
there is no fixed savings percentage. Keeping repetitive commands and full
build logs outside chat reduces the work Codex needs to do.

This lane covers compilation only. Run checks relevant to each change before
publishing. It does not validate physical-device performance or live networking.
No CI trigger or Xcode Cloud change is configured.

## Personal internal TestFlight

For the latest validated commit already published to `origin/main`:

```sh
PrototypeTools/fastlane-local beta check:true
PrototypeTools/fastlane-local beta
```

`beta` reuses `PrototypeTools/deliver-testflight.py`: it checks the remote,
archives a clean snapshot of the published commit, verifies pinned sources,
privacy manifests and signing, then uploads for internal TestFlight testing.
The archive must also contain the exact `multiplayer.gba` pinned by the source
revision. Builds download the immutable private game release when a verified
local cartridge is not supplied. Startup installs that matching cartridge under
its own content identity, preserving previous cartridges, names and saves.
Uncommitted and untracked files are excluded. Xcode uses its existing signed-in
Apple developer account and automatic distribution signing. No new API key,
password file, or signing repository is required. Xcode automatically manages
upload numbering with `manageAppVersionAndBuildNumber: true`; each new TestFlight
upload must have a higher build number than the previous upload. The local
project/archive number does not need a manual bump for each upload.

Before archiving, delivery selects a full Xcode installation for its subprocesses
and checks for a usable distribution
private key for the Bound team, and an unexpired App Store profile containing
that certificate and the production push entitlement. Command Line Tools alone
cannot export the app. An explicit invalid `DEVELOPER_DIR` is rejected.

If signing checks fail, sign in through Xcode Settings → Accounts and refresh
the matching profile using automatic provisioning. Keep existing accounts,
credentials, certificates and profiles; do not sign out, clear the keychain or
revoke certificates to resolve a profile mismatch. These checks inspect local
public signing metadata; Apple can still require renewed
authentication or account agreements at export/upload time.

To validate signing without uploading:

```sh
PrototypeTools/fastlane-local beta archive_only:true
```

Archive-only validation also exports an App Store distribution IPA locally,
checks its actual production entitlements and pinned ROM, and never uploads.
That local export uses installed signing material without allowing provisioning
updates. A successful archive alone does not establish distribution signing or
current App Store Connect account access.

Receipts and logs remain under `.build/testflight-delivery/`. An accepted upload
still needs Apple processing; it is not confirmation of TestFlight availability.
Check the processed build in the existing personal internal testing group.
Inspect App Store Connect before retrying an uncertain upload. Do not delete
receipts to force a retry. See [delivery details](../Docs/TESTFLIGHT-DELIVERY.md).

Both lanes default to `/Applications/Developer/Xcode.app/Contents/Developer` without changing global Xcode selection. An explicit `DEVELOPER_DIR` overrides that default. Account preferences are not read as authentication proof; Xcode determines account access during export/upload.

### Diagnosing upload account selection

`Failed to Use Accounts` means Xcode could not select an account with App Store
Connect access for the requested team. A successful local export verifies signing,
but does not verify that upload account selection works. The error alone cannot
distinguish an account session issue from team/app access or an Xcode account
mapping issue. Do not infer sign-out from private Xcode preference keys.

The distribution log bundle path is printed in the attempt's `upload.log`.
Inspect `IDEDistribution.standard.log` for the failing step and
`DVTITunesSoftwareService.log` for any service response. An empty service log
provides no server-side authentication diagnosis. Verify the intended team and
Bound app access in App Store Connect; upload roles are Account Holder, Admin,
App Manager, or Developer (see Apple's [upload documentation](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds)).
Do not remove accounts, clear credentials, or revoke certificates to investigate.

### Explicit team API-key authentication

Create a Team Key in App Store Connect → Users and Access → Integrations →
App Store Connect API → Team Keys. Select the Developer role for build uploads.
Team keys apply across the team's apps. These shared ASC_API_* settings can be
used by other app delivery scripts once configured to read them.
Save the downloaded .p8 outside all repositories with owner-only permissions.
Never paste its contents into chat, commit it, or put its contents in shell config.

Set these in your Terminal before invoking beta (or in your personal shell config
if you want your testlane alias to inherit them):

```sh
export ASC_API_KEY_PATH="$HOME/.config/app-store-connect/AuthKey_YOURKEYID.p8"
export ASC_API_KEY_ID="YOURKEYID"
export ASC_API_ISSUER_ID="YOUR-ISSUER-UUID"
```

Replace the placeholders with your Team Key's ID, Issuer ID and actual path.
The uploader passes these to xcodebuild's authenticationKeyPath,
authenticationKeyID and authenticationKeyIssuerID options during export/upload.
It never reads/copies the private-key contents or imports them into Keychain.
Missing, partial, malformed or insecure configuration fails before archiving.
API-key authentication is required for beta; there is no Apple-account fallback. `verify` and
archive-only do not use this key. Signing still uses the installed certificates
and profiles, and existing upload receipts/build-number management are preserved.
Live key authentication must be verified by a user-run upload; offline tests
cannot establish API permissions or Apple acceptance.
