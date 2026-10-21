# Local SDK privacy manifest backports

Reviewed 2026-10-06 against commit `4b971847ef6af8960e64a3bb446acb9bc7de3a29`. These are locally maintained declarations for the exact pinned sources, not manifests published by those SDK versions. No SDK version or runtime source changes accompany them.

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
