# Local SDK privacy manifest backports

Reviewed 2026-10-06 against commit `4b971847ef6af8960e64a3bb446acb9bc7de3a29`. These are locally maintained declarations for the exact pinned sources, not manifests published by those SDK versions. No SDK version or runtime source changes accompany them.

Rechecked 2026-10-28 for retired-ROM deletion. The change in
`GameCollectionViewController.swift` uses a separate deletion-conflict query
while retaining the existing confirmation, revision checks, and per-game
deletion path. It adds no required-reason API calls and does not change
SDWebImage request/cache handling. Only that integration hash is refreshed;
manifest declarations and dependency pins are unchanged.

Rechecked 2026-10-27 for the audio mute change in `84b8cd0a`.
`AudioManager.swift` adds an in-memory playback mute flag and applies it to the
existing AVAudio mixer output-volume path. The change adds no required-reason
API calls, persistence, data collection, or transmission. Its reviewed source
hash is updated. The follow-up bug sweep also rechecks the mute flag when
choosing the existing audio-session category and preserves disabled audio
buffers/engines during route resets. These changes use the existing AVAudio
paths and add no required-reason API calls or new data flows. The existing
privacy declarations and broader review limits remain unchanged.

Rechecked 2026-10-21 against `b433394b5d6c241dc01c50b67da8cb60adc8e313`
when enabling personal TestFlight delivery. Compared all changes since the
original audit in `MFiGameController.swift`, `ControllerSkinTraits.swift`,
`ControllerView.swift`, `GameView.swift`, and
`GameCollectionViewController.swift`. The changes add physical controller button
mapping, update scene/trait APIs and import type identifiers, remove pressed
artwork animation/cache work, adjust Core Image intermediate caching, and update
game preview/error/save-state UI handling. They do not change the audited
required-reason API accesses, elapsed-time scheduling, or SDWebImage request/cache
call sites. Refreshed only these five source hashes. Manifest declarations,
dependency pins, runtime source, and the broader review limits below are unchanged.

Rechecked 2026-10-22 for the iCloud ROM update launch guard. The change to
`GameCollectionViewController.swift` adds an in-memory update-state check and an
error alert. It adds no required-reason API access and does not change SDWebImage
request or cache handling. Refreshed that integration hash only; the SDK manifest
declarations and dependency pins remain unchanged.

Rechecked 2026-10-23 against `c0efb29efb45726241523def6ee4b7c2673b3f32`
for the per-ROM Clear Saves menu. Compared the menu actions, confirmation alert,
and active save-state selection with the previously audited integration. These
changes call the app's save manager and add no required-reason API accesses to
this file. SDWebImage request/cache call sites and DeltaCore elapsed-time
scheduling are unchanged. Refreshed only this integration hash; SDK declarations
and dependency pins remain unchanged. This is not a broader privacy attestation.

Rechecked 2026-10-23 against `95e8db11c22fe9187a477a03dd9ce54ac65d48b7`
for the completed Clear Saves launch lock and retry controls. Compared
`GameCollectionViewController.swift` with the integration recorded by
`d321b054596fbd7702ff49f62dc3523957dfda0b`: the additions track the selected game,
check save-clear state/revision, close matching previews, and update confirmation,
progress, and retry actions. They add no direct required-reason API access in
this integration file and do not change its SDWebImage request/cache call sites.
Refreshed only its source hash. SDK declarations and dependency pins remain
unchanged; this is not a broader privacy or data-collection attestation.

## SDWebImage 3.8.3

The committed CocoaPods lock identifies 3.8.3. The required-reason API scan of `Pods/SDWebImage/SDWebImage` found file-metadata access in `SDImageCache.m`:

- `makeDiskCachePath:` selects the app's user-domain cache directory (line 195). The shared manager initializes the shared cache; all three Bound integration files use this shared manager. No Bound call site supplies a custom disk-cache directory or read-only cache path.
- `cleanDiskWithCompletionBlock:` (lines 509–580) enumerates that cache, reads modification dates and allocated sizes, removes expired files, and sorts remaining files by age to enforce a size limit. These metadata values stay in the local cleanup operation.
- `getSize` (lines 608–620) reads attributes for the same cache; `calculateSizeWithCompletionBlock:` (lines 632–655) reports aggregate cache size and count to a caller. Bound does not call these APIs or transmit these values.
- `SDWebImageDownloader.m` constructs requests from caller-provided URLs and headers. Cache modification times and filesystem attributes do not flow into those requests. This finding is limited to required-reason API data; it is not a claim that image downloads collect no information.

Declare `NSPrivacyAccessedAPICategoryFileTimestamp` with `C617.1`: metadata access within the app container. File-size queries here do not query device free disk space. Copy `SDWebImage_Privacy.bundle` through the app's Resources phase because this pinned SDK is statically linked. The bundle contains no executable and requires no separate signing identity. Its identifier belongs only to the resource bundle; it does not change the app identity.

## DeltaCore

Upstream pin: `633dfa86967816315fe19b482511dab1ce517f28`, unchanged. The required-reason API scan of `Cores/DeltaCore/DeltaCore` found `mach_absolute_time()` in `Extensions/Thread+RealTime.swift:21`. Its only callers are the initial and current time reads in `Emulator Core/EmulatorCore.swift:472,518`. `runGameLoop` compares elapsed time against frame duration, limits skipped frames, and waits until the next frame. The raw timestamps stay within this scheduling loop; they are not published, serialized, or sent over a network.

Declare `NSPrivacyAccessedAPICategorySystemBootTime` with `35F9.1` for elapsed-time scheduling. The DeltaCore Resources phase copies its manifest inside `DeltaCore.framework` before the app's existing framework signing step. The project-only compatibility patch is recorded in `PrototypePatches/dependency-privacy.patch`; only its corresponding project checksum changes in the vendored-source inventory. Emulator, audio, and scheduler implementation files remain byte-identical.

## Evidence and limits

`source-audit.json` records the scanned source trees, hashes for all 95 source/header files in those trees, the three Bound integration files, and the CocoaPods lock. The scan covered defaults/preferences, elapsed boot time, file metadata, disk capacity, and active keyboard APIs. Data-flow review focused on the matches and their callers described above. Hashes identify the examined snapshot; they do not themselves prove a complete privacy review. Integration changes elsewhere also require review.

Neither manifest declares `NSPrivacyTracking`, tracking domains, or collected-data types. Those omissions mean this bounded review does not attest to them. Newer upstream manifests were not copied because later SDK implementations and collection behavior may differ. These additions do not resolve other SDK gaps, Apple SDK-signature requirements, App Store privacy answers, or licensing/distribution approval; see [remaining blockers](../TESTFLIGHT-READINESS.md).

Run `python3 PrototypeTools/verify_privacy_manifests.py` to detect drift in the reviewed snapshot and declarations. After archiving, add `--archive .build/testflight-readiness/Bound.xcarchive` to check the actual destination bundles. Run the existing vendored-source verifier separately.

References: Apple's [required-reason APIs](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api), [approved reasons](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitypereasons), and [SDK requirements](https://developer.apple.com/support/third-party-SDK-requirements/). The official [SDWebImage 5.18.7 release](https://github.com/SDWebImage/SDWebImage/releases/tag/5.18.7) documents newer CocoaPods manifest packaging; it is not the source of this 3.8.3 declaration.
