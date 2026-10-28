# Personal TestFlight delivery through Fastlane

The user explicitly permits the manual Fastlane `beta` workflow. Uploads through
other entry points and Xcode Cloud delivery remain prohibited. Never check Cloud
usage, minutes or capacity. Keep the existing Cloud workflow manual-only; do not
add push, schedule, pull-request or tag triggers.

## Setup and commands

Use the managed Ruby and Bundler installation described in
[`fastlane/README.md`](../fastlane/README.md). From the repository root:

```sh
PrototypeTools/fastlane-local --check-environment
PrototypeTools/fastlane-local beta check:true
PrototypeTools/fastlane-local beta archive_only:true
PrototypeTools/fastlane-local beta
```

`check:true` checks the remote and revision without building or uploading.
`--check-environment` only checks the locked installed gems and never starts
Fastlane. The wrapper selects the checkout's `.build/gems`, so a detached shell
does not lose the installed Fastlane executable. Missing dependencies stop before
starting a lane; install them explicitly using the setup instructions.

`archive_only:true` creates a signed local archive and exports its distribution
IPA without uploading or allowing provisioning updates. It checks the exported
binary's team/bundle identity, production APNs, `get-task-allow=false`, and exact
pinned ROM. The archive's development signing is not a distribution-signing test.
The plain `beta` command archives, signs and uploads for internal TestFlight
using this Mac's signed-in Xcode developer account. Xcode may manage signing
assets locally. No credentials or signing assets are committed.

Normal commits and pushes do not start TestFlight builds. Run focused checks
and Release iPhone validation, publish the intended changes, then manually invoke
Fastlane when a TestFlight delivery is wanted. Setting up the workflow does not
itself upload a build.

## Published source and internal scope

The lane reuses `PrototypeTools/deliver-testflight.py`. It verifies both origin
URLs and requires the requested commit to equal the live `origin/main` head.
The default revision is local `HEAD`; an explicit revision can be passed with
`revision:<commit>`. A temporary committed snapshot excludes unrelated working
changes, untracked personal files and app data.

The tool verifies pinned sources and privacy manifests, archives Release through
`Bound.xcodeproj` / `Bound`, validates the signature and archive privacy manifests,
validates a local distribution export, and rechecks remote main before uploading. Every new TestFlight upload must
automatically receive a build number higher than the previous upload. Keep
`manageAppVersionAndBuildNumber: true` in the export options so Xcode manages
upload numbering. The project's archive build number can remain unchanged;
the assigned upload number is recorded as `uploaded_build` when Xcode reports it.
Export is restricted to internal TestFlight testing. This does not resolve the
separate public distribution dependency/SDK licensing review.

The recorded destination is **Evan Only Internal Testing**, internal group
`165fa14a-3c1a-4c4c-ae90-0189de227adc`. Its automatic Xcode upload distribution
setting was configured previously; verify the current group and processed build
in App Store Connect when delivering. The local workflow does not add testers
or change groups.

## Receipts, processing and retries

Logs, archives and receipts stay under ignored `.build/testflight-delivery/`.
A per-revision upload receipt prevents repeat uploads after acceptance. Concurrent
local deliveries are blocked. If an upload is interrupted before a receipt is
written, inspect App Store Connect before retrying; do not delete receipts to
force another upload.

Failed commands retain a sanitized `*.failure.json` alongside the full local
log. `exportArchive Failed to Use Accounts` means Xcode could not authenticate
the App Store Connect account; it is not an Apple binary validation rejection.
Verify the existing account's access in Xcode Settings → Accounts. Preserve the
account and its credentials; do not remove the account, reset the keychain, or
delete upload receipts. Local export does not prove current online account access.
The next upload still requires explicit delivery authorization.

A successful upload means Apple accepted the binary. Apple processing and
availability in the internal testing group must be verified separately. The lane
does not claim delivery completion from an archive or upload receipt alone.

On each phone, the user can enable **TestFlight → Bound → App Information →
Automatic Updates**. Apple controls installation timing. This local build and
upload workflow does not establish physical-device gameplay, performance or live
networking parity.
