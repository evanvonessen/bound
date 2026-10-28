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
Build products remain in `.build/ReleaseDerivedData`; raw Xcode logs are saved
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
and checks that Xcode has a registered Apple Account, a usable distribution
private key for the Bound team, and an unexpired App Store profile containing
that certificate and the production push entitlement. Command Line Tools alone
cannot export the app. An explicit invalid `DEVELOPER_DIR` is rejected.

If signing checks fail, sign in through Xcode Settings → Accounts and refresh
the matching profile using automatic provisioning. Keep existing accounts,
credentials, certificates and profiles; do not sign out, clear the keychain or
revoke certificates to resolve a profile mismatch. These checks inspect local
registration and public signing metadata; Apple can still require renewed
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
