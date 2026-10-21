# Bound TestFlight preparation

For the current authorized personal internal delivery process, Cloud post-action,
local quota fallback, and device update settings, see
[TestFlight delivery](Docs/TESTFLIGHT-DELIVERY.md). The dated preparation evidence
below remains historical; its earlier upload/signing restrictions do not replace
the current user-authorized personal delivery procedure. Public distribution
review limits remain unresolved.

Review date: 2026-10-06. The user authorized preparation and TestFlight upload to the existing Bound record (Apple ID 6815926598, SKU bound-ios), using existing signing assets. Final submission remains with the user. New credentials, profiles, agreements, and unsupported attestations are not authorized.

## Identity

| Setting | Current value |
| --- | --- |
| iPhone display label | Bound (explicitly authorized change from Bound 2) |
| Project / scheme / product | Bound.xcodeproj / Bound / Bound.app |
| Internal target / module | Delta (preserved for upstream compatibility) |
| Bundle ID | com.evanvonessen.bound (approved permanent release identity) |
| Existing team | 3N83BX5M9G |
| Version / build | 1.0 / 173 (matches the existing App Store Connect 1.0 version) |
| Deployment target | iOS 17.0; iPhone and iPad |

The bundle ID and version now match the explicitly approved existing App Store Connect record, which showed no builds during preparation. Team, module/core identities, capabilities, and dependency pins remain unchanged. This is a different installation identity from the prototype: local ROMs, saves, notes, preferences, and the bundle-scoped friend-account Keychain session are not automatically migrated. Friend sign-in restores server-side friend connections, not local game progress. Export saves from the old app and verify their import before removing it. The current Bound settings hide upstream Delta Sync; its inherited implementation is not a verified backup path for this release.

## Approved release identity verification

The 1.0 (173) archive uses `com.evanvonessen.bound` and the pre-existing development profile `2eb68dbb-7f56-4a34-bd8d-32099e5b218a` (expires 2027-09-25). Its embedded profile matches the cached file byte-for-byte. App deep/strict signature verification, all 19 embedded framework signature checks, binary/dSYM UUID matching, the 16,879-file pinned-source check, and the 99-hash/two-manifest privacy check pass. The Release executable has no checked diagnostic, fixture, or XCTest workaround strings, and the archive contains no loose ROM/save files. This is development signing (`get-task-allow=true`), not an uploadable distribution export.

Native upgrade testing reproduced a blank window when iOS restored an unnamed scene from an earlier SwiftUI Bound installation. The release restores that scene's native main window using public UIKit APIs. Named native scenes and external-display scenes retain their existing paths. The same simulator installation reopened its native library after the repair; no app uninstall, container clearing, or game-data migration was performed. Changing from the prototype bundle ID is a separate installation; an older app already using the approved release ID is an in-place update and needs its own save backup before updating.

Manual backup in this build: save in-game, return to the library, long-press the game, then choose **Manage Save File → Export Save File**. Save the exported copy through Files. Import the matching game in the destination app, then use **Manage Save File → Import Save File**; importing replaces its current in-game save. **View Save States** also exposes Import/Export in each state's context menu. Notes and layout preferences are local; friend login does not back them up. Neither the current SwiftUI settings form nor the older settings controller exposes cloud-sync setup.

Current local evidence is under ignored `.build/verification/release-identity/`. The actual Files-picker cancel/retry/import test passed, followed by both Release UI tests (zero failures): library/settings/license checks, playback, Menu/B, Notes/Types, rotation, and three original-cartridge screenshots. Xcode 27 missed animation-idle notifications on both simulator runtimes, so the final run opted into runner-only explicit waits; app animations and the Release executable were unchanged. Screenshot provenance records the original fixture and untouched native attachments. Physical-device behavior and live friend transport were not revalidated. No new signing assets, agreement acceptance, final submission, or live-account validation is included.

## Earlier prototype preparation and verification

The ordinary Bound scheme archives its native app in Release. The local archive uses Xcode 27.0 (27A266a), iOS 27.0 SDK, arm64, and the existing Apple Development identity. Existing Apple Development and Apple Distribution certificates were inspected read-only. Only development provisioning profiles are cached; no matching App Store distribution profile was found. No provisioning updates or new signing assets were requested.

The final local archive succeeded and contains one application product. Deep/strict app signature verification and individual checks for all 19 embedded frameworks passed. Its effective entitlements match the existing bundle ID and team; `get-task-allow` is true, and its device-provisioned profile has no beta-reports entitlement. This confirms development signing, not TestFlight distribution signing. The profile expires 2027-09-30. The bundled app privacy manifest matches the committed source, and the checked Debug fixture launch arguments are absent from the Release executable. Local evidence is under ignored `.build/testflight-readiness/` (latest: `archive-privacy.log`, `archive-privacy-audit.json`, `models-privacy.log`, `source-integrity-privacy.log`, and `privacy-negative-checks.log`).

The original Bound icon is 1024 × 1024 without an alpha channel and is referenced by the Icon Composer asset. The compiled app includes its primary icon metadata. The selected app entitlements source is the empty `Delta/Delta.entitlements`. The pre-existing non-exempt-encryption flag is false; it was not changed or treated as a completed export-compliance review.

The app now bundles `Delta/Supporting Files/PrivacyInfo.xcprivacy` for verified app-owned required-reason API uses:

| Category | Reasons | Source evidence |
| --- | --- | --- |
| User defaults | CA92.1 | Local appearance, panel, controller, and account logout preferences |
| System boot time | 35F9.1 | Frame throttling and elapsed-time scheduling in BoundDeltaFrameTap and FriendSharingSession; sharing timestamps use a stream-relative epoch |
| File metadata | C617.1, 3B52.1 | Local files and user-selected BIOS import size validation in MelonDSCoreSettingsViewController |

This manifest intentionally makes no unverified data-collection declarations. It is not a substitute for SDK manifests, the backend/SDK data-flow review, or App Store privacy answers. All 47 model tests and the 16,879-file pinned-source integrity check passed. No personal ROMs or live accounts were used. This metadata preparation does not add new physical-device or live-network validation.

## Audited SDK backports

The [source audit and provenance](PrivacyManifests/README.md) cover two narrow backports: SDWebImage 3.8.3 declares file-metadata access for app-cache cleanup (`C617.1`), and DeltaCore declares elapsed-time frame scheduling (`35F9.1`). The former is packaged in `Bound.app/SDWebImage_Privacy.bundle`; the latter in `Bound.app/Frameworks/DeltaCore.framework`. No data-collection or tracking declarations were inferred. Dependency versions, runtime code, app identity, and signing configuration remain unchanged. The checked source inventory includes 99 files, including the three Bound SDWebImage integration files and the CocoaPods lock. The new Release archive passed: both SDK manifests match their reviewed declarations at those exact paths, and app/19-framework strict signature checks passed. All 47 model tests and 16,879 pinned-source checks passed. The manifest verifier rejected missing archive resources, altered reviewed source, newly added SDK source, and an unreviewed tracking declaration in temporary fixtures. No physical-device or live-network test was added for this metadata-only change.

## Remaining blockers

1. **Distribution rights:** The recorded Agora proprietary binary SDK versus Delta AGPL compatibility question remains unresolved. Standalone core/framework permission provenance, OperatorKit, and the supplied type-chart artwork also remain open in [the dependency inventory](LICENSES/DEPENDENCY-INVENTORY.md). Agora remains unchanged. The user has authorized TestFlight upload; that authorization does not resolve or attest to these third-party permissions.
2. **SDK privacy coverage:** The linked app still contains Alamofire 4.7.3, GoogleSignIn 6.2.4, GTMAppAuth 1.3.1, and GTMSessionFetcher 2.3.0 without corresponding bundled privacy manifests. All four appear on Apple's required-SDK list. SDWebImage 3.8.3 now has a locally source-audited required-reason API manifest in its own resource bundle; this is not a complete SDK collection/tracking attestation. The archive does include manifests for AppAuth, RevenueCat, ZIPFoundation, and AgoraRtcKit. Review the required-reason API usage of each embedded core/framework too. Preserve the pinned sources until a reviewed dependency update or accurately supported manifest integration is authorized; do not invent SDK declarations.
3. **Distribution provisioning:** The Apple account owner verified the existing Bound record (6815926598), bundle ID `com.evanvonessen.bound`, version 1.0, and no uploaded builds. The local machine has an existing Apple Distribution identity, but only development profiles are installed. A matching App Store distribution profile is still required for an uploadable export. No automatic export or provisioning updates have been requested; no signing assets were created.
4. **Submission information:** Review the privacy policy and disclosures for account identity, friend relationships, gameplay video, backend retention, and SDK diagnostics. Confirm export-compliance answers, applicable age-rating responses, beta description, feedback/review contact, and reviewer access using authorized test data. Internal versus external tester scope and any submission must be explicitly approved. External testing may require beta review.

The binary import audit also found missing per-framework manifest coverage for file-metadata APIs in Agoraffmpeg and GBADeltaCore; file-metadata/defaults APIs in MelonDSDeltaCore; file-metadata/boot-time APIs in N64DeltaCore and aosl; and defaults APIs in OperatorKit. Imports identify review targets; correct reasons still require source or vendor evidence. No vendor declarations were fabricated. DeltaCore now includes a locally audited boot-time declaration through a project-only resource packaging patch; its upstream revision and runtime source remain unchanged.

## Device identifier cleanup

Removed the hardcoded `ALTDeviceID` from the app Info.plist. This was a device-specific value for AltKit, not the app's bundle ID or signing team. Release already disables AltJIT in `Settings.registerDefaults()`, and no renderer, scheduler, core, transport, entitlement, or dependency implementation changed. A future separately authorized sideloading workflow must supply its own device metadata rather than distribute one developer device's identifier.

An independent unsigned archive succeeded from an isolated checkout based on `986ed021` with this cleanup, using Xcode 27.0 / iOS 27.0. The app and all 19 embedded frameworks are arm64, the app's dSYM UUID matches, the primary icon metadata is present, and the app manifest matches source. The SDK verifier passed all 99 source/integration hashes and both locally audited manifests in source and archive. All 47 model tests and 16,879 pinned-source checks passed. No `ALTDeviceID`, loose ROM/save files, provisioning profile, or private signing-key files were found in the resulting app. Checked QA launch-argument strings were absent from its Release executable. Physical-device and live-network behavior were not revalidated for this plist-only change.

Evidence is under ignored `.build/readiness/` (`archive-final.log`, `archive-audit.json`, `models-latest.log`, `sources-latest.log`), with the local artifact at `.build/Bound-readiness-final.xcarchive`. The archive command below can also be run with `CODE_SIGNING_ALLOWED=NO` to avoid using any signing identity. An unsigned archive is engineering evidence only and cannot be uploaded as a TestFlight distribution package. The approved release identity section above supersedes this earlier prototype identity review.

## Local archive command

From the repository root, with existing authorized signing assets:

```sh
xcodebuild -project Bound.xcodeproj -scheme Bound -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath .build/testflight-readiness/Bound.xcarchive \
  CLANG_ENABLE_EXPLICIT_MODULES=NO SWIFT_ENABLE_EXPLICIT_MODULES=NO archive
```

This command only archives locally. Do not add `-allowProvisioningUpdates`, export/upload commands, or account credentials as part of this preparation. Local logs, archives, and signing material are ignored by Git and must remain out of commits.

## Apple references checked

- [Current upload requirements](https://developer.apple.com/news/upcoming-requirements/): Xcode 26 or later with the iOS 26 SDK or later; iOS deployment target 13 or later. The local toolchain and deployment target exceed those minimums; server-side validation was not performed.
- [Upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds/): build association uses the bundle ID and version, and builds must be processed by Apple before testing.
- [Third-party SDK requirements](https://developer.apple.com/support/third-party-SDK-requirements/): listed SDKs require manifests, with signatures additionally required for relevant binary dependencies.
- [Required-reason APIs](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api) and [approved reasons](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitypereasons): declarations must match actual usage; an app manifest does not cover a dynamic SDK's own API use.
- [TestFlight](https://developer.apple.com/testflight/) and [creating an app record](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-a-new-app/): account setup, test information, and any review are separate from a successful local archive.
