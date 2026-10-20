# Bound 2 dependency inventory

Reviewed 2026-10-04 against the tracked native source tree. This is a provenance inventory, not a legal certification or an assertion that every bundled component is available under the app's root license. Keep the original notices in their original files.

## App and engine notices

The app's root `COPYING` contains GNU AGPL version 3. The Delta foundation revision is `c1d3d068e019e6493eed45654569db3cc5beb86a`. Changes are described in `LICENSES/BOUND2-MODIFICATIONS.md` and tracked Git history.

| Component | Exact snapshot | Local notice/evidence | Recorded status |
| --- | --- | --- | --- |
| Delta app foundation | `c1d3d068e019e6493eed45654569db3cc5beb86a` | `COPYING` | AGPL version 3 text retained at root; this does not settle each dependency permission. |
| VBA-M engine | `453fa0decf179360926fb417725a794aa496d6e3` | `Cores/GBADeltaCore/visualboyadvance-m/doc/License.txt` | GPL version 2 or later, with gb_apu, modified zlib and per-file exceptions in the notice. |
| VBA-M APU | `same VBA-M snapshot` | `Cores/GBADeltaCore/visualboyadvance-m/src/apu/Gb_Apu.cpp` | Header specifies LGPL 2.1 or later; this is separate from the main engine notice. |
| VBA-M zlib | `dependencies 33a0af6701313fed2219029a069c712740233a77` | `Cores/GBADeltaCore/visualboyadvance-m/dependencies/zlib/zlib.h` | zlib notice and alteration/origin restrictions; other bundled components retain their own notices. |
| Gambatte | `f8a810b103c4549f66035dd2be4279c8f0d95e77` | `Cores/GBCDeltaCore/gambatte/COPYING` | GPL version 2 license text present; inspect source headers for applicable version choices. |
| Nestopia | `contained in NESDeltaCore snapshot` | `Cores/NESDeltaCore/nestopia/COPYING` | GPL version 2 license text present; engine not separately revision-pinned in this manifest. |
| Snes9x | `c3fa4009a3ce9724d8d5dc7646b1eed20f91234b` | `Cores/SNESDeltaCore/snes9x/LICENSE` | Custom non-commercial/personal-use text; commercial permission discussion is a publication-review gate. |
| Genesis Plus GX | `58758aef3d8e12189899d67344db3b95c6379561` | `Cores/GPGXDeltaCore/Sources/GenesisPlusGX/Genesis-Plus-GX/LICENSE.txt` | Custom license restricts commercial products/activity and requires source for modified redistributions; compatibility is unresolved. |
| melonDS | `a53f9bab7b5c06efcbc6ecdf30ac0367555995aa` | `Cores/MelonDSDeltaCore/melonDS/LICENSE` | GPL version 3 license text present; nested teakra, libslirp and fatfs have separate notices. |
| Mupen64Plus core | `aa9903b5446a9b50b8f5a31f927ca98e5a33a230` | `Cores/N64DeltaCore/Mupen64Plus/mupen64plus-core/LICENSES` | Lists GPL version 2 and component authors; bundled doc/gpl-license and doc/lgpl-license are retained. |
| Mupen64Plus RSP HLE | `f01fed082abc2aeabd55c8fe685df4c83115e2c2` | `Cores/N64DeltaCore/Mupen64Plus/mupen64plus-rsp-hle/LICENSES` | Lists GPL version 2; additional per-file notices remain authoritative. |
| GLideN64 | `9669b94539d5862ac57a52d5b28bad1483f40a91` | `Cores/N64DeltaCore/Mupen64Plus/GLideN64/LICENSE` | Lists GPL version 2; licenses directory contains additional component notices. |
| ZIPFoundation (active) | `b979e8b52c7ae7f3f39fa0182e738e9e7257eb78 (0.9.18)` | `External/ZIPFoundation/LICENSE` | MIT notice retained. Historical DeltaCore/External/ZIPFoundation revision is excluded and not the active implementation. |
| RevenueCat | `3dd291434fd63594b8ada87bca960e001b708241` | `Vendor/RevenueCat/LICENSE` | MIT notice retained; local compiler compatibility patch recorded separately. |

## Standalone wrappers and integration libraries

All eight pinned core/framework repositories listed below lack a root LICENSE/COPYING file in this snapshot. Representative DeltaCore and GBADeltaCore headers retain Riley Testut copyright and “All rights reserved” text. This does not establish a permissive standalone reuse license, and the root app's AGPL notice alone is not treated as proof of dependency permission. Resolve the precise permission provenance for the integrated distribution before public release; this inventory neither declares reuse unlawful nor grants permission.

| Wrapper | Revision |
| --- | --- |
| `Cores/DeltaCore` | `633dfa86967816315fe19b482511dab1ce517f28` |
| `Cores/GBADeltaCore` | `869c34aeca9dd2b3fbd329092bb2743b0ae80c98` |
| `Cores/GBCDeltaCore` | `0871ccaad2bbd7cbd2de0ce06f9e26dc3d1bfdde` |
| `Cores/GPGXDeltaCore` | `4af2ff5d68cffd12121b63157ffb79267573bfcc` |
| `Cores/MelonDSDeltaCore` | `eb9b07ec17307cfd4986cb607f8ee5f6492d73cb` |
| `Cores/N64DeltaCore` | `56aefef59d947edbf2eb34b0a0288d751b006f30` |
| `Cores/NESDeltaCore` | `c88ef1e7c68ad723194d1b691362ac7d7394f968` |
| `Cores/SNESDeltaCore` | `35add3af36e6c42d777c554a277e098766a78995` |

Representative headers: `Cores/DeltaCore/DeltaCore/Protocols/Model/ControllerSkinProtocol.swift` and `Cores/GBADeltaCore/GBADeltaCore/Bridge/GBAEmulatorBridge.mm`. Harmony and Roxas local podspecs do not declare a license; their source/header provenance also needs review. CheatBase includes third-party database content whose permissions are not established by this inventory. AltKit has no root license file in the resolved checkout inspected here.

## Agora binary SDK and OperatorKit

The active Swift package pins AgoraRtcEngine_iOS **4.6.4**, revision `00b614b1ff1135565e45e9e4bf7d4ec33da7b67f`. Its repository LICENSE is MIT and is preserved verbatim in `LICENSES/Agora-Package-Wrapper-MIT.txt`. The matching Package.swift downloads binary frameworks from versioned URLs; the wrapper MIT notice is not treated as licensing those binary SDKs. Active app products are RtcBasic and VideoCodecEnc, including AgoraRtcKit, Agorafdkaac, Agoraffmpeg, AgoraSoundTouch, video_dec, AgoraVideoEncoderExtension and the AgoraInfra aosl dependency.

Official [pinned wrapper license](https://raw.githubusercontent.com/AgoraIO/AgoraRtcEngine_iOS/00b614b1ff1135565e45e9e4bf7d4ec33da7b67f/LICENSE).

Official [terms reference](https://www.agora.io/en/terms-of-service/) (reviewed 2026-10-04; page labels its update 06/02/2022). The actual account/SDK agreement governing this project and its compatibility with a future AGPL distribution remain unverified. No agreement is accepted or amended by this inventory; no account or service is created.

The app's DeltaOperator integration includes an OperatorKit binary. The arm64 framework identifies itself as **1.0 (1)**, bundle identifier `operatorkit.OperatorKit`, at `External/DeltaOperator/Frameworks/OperatorKit.xcframework/ios-arm64/OperatorKit.framework`. Its binary SHA-256 is `35dd687ddd6151753fda9ac70acd90befe9360ac59cf14e15a2cbc38f4244625`. The integration snapshot is `1fe5f5f2304c2440c18f74274eac5f69624d7aaf`; `External/DeltaOperator/README.md` describes the Epilogue-device bridge. No standalone OperatorKit source, distribution grant or governing SDK agreement was established in the inspected files. The wrapper's source availability does not establish rights for its binary dependency.

The pinned package manifests specify these active binary archive locations and SHA-256 checksums. These are download-integrity/provenance values, not license grants or hashes of a re-signed installed framework. Codec/embedded-component notices still need review.

| Active binary | Versioned archive URL | Package archive SHA-256 |
| --- | --- | --- |
| AgoraRtcKit | https://download.agora.io/swiftpm/AgoraRtcEngine_iOS/4.6.4/AgoraRtcKit.xcframework.zip | `9584bb7ce6c1c03ccee6fd0e71ba563d94099dc3dcd5b96acd9be7ec817ce91b` |
| Agorafdkaac | https://download.agora.io/swiftpm/AgoraRtcEngine_iOS/4.6.4/Agorafdkaac.xcframework.zip | `277ea54cc53de70a05ea7e08dd75037ab21936063ee2d32f1b004417d8305f77` |
| Agoraffmpeg | https://download.agora.io/swiftpm/AgoraRtcEngine_iOS/4.6.4/Agoraffmpeg.xcframework.zip | `6dbbccd98e1ebb528df5ebdb7d5b532da194cc833431453debc03d736e238241` |
| AgoraSoundTouch | https://download.agora.io/swiftpm/AgoraRtcEngine_iOS/4.6.4/AgoraSoundTouch.xcframework.zip | `613c26f96ae06bac3c03017b6492b32725a41557d42e89bacd17fb46d3ac0ba4` |
| video_dec | https://download.agora.io/swiftpm/AgoraRtcEngine_iOS/4.6.4/video_dec.xcframework.zip | `eeeca29224eaa54a530cd4c7cd61860529d9b31d4d868f272bd4fda7244f184b` |
| AgoraVideoEncoderExtension | https://download.agora.io/swiftpm/AgoraRtcEngine_iOS/4.6.4/AgoraVideoEncoderExtension.xcframework.zip | `a2a967833b75c31736c384e4a048c1db1f3892dc2254f1567d1b386209710dc0` |
| aosl | https://download.agora.io/swiftpm/AgoraInfra_iOS/1.3.5/aosl.xcframework.zip | `b941278231b91caea7c1aba4a68c75d800acd6a8e38aed2ab3b29f71c19f62d1` |

## Resolved Swift packages

The actual Xcode lockfile is `Bound.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`. Package URLs and revisions below are exact lockfile values. Resolved build checkout licenses are not included in the 16,879-file vendored-source hash set; retain their matching notices when packaging source or a binary.

| Package | Version/branch | Exact revision | Notice/status |
| --- | --- | --- | --- |
| agorainfra_ios | 1.3.5 | `0c21b485af8e64b2716632f2f7badab8705343b1` | Binary aosl dependency; no root LICENSE in inspected package checkout. |
| agorartcengine_ios | 4.6.4 | `00b614b1ff1135565e45e9e4bf7d4ec33da7b67f` | MIT package wrapper; binary SDK permissions unresolved. |
| altkit | revision-pinned | `2fd376df1c79ec06a5c80cc8933da027f65b3148` | No root LICENSE in inspected checkout; permission provenance unresolved. |
| keychainaccess | 4.2.2 | `84e546727d66f1adc5439debad16270d0fdd04e7` | MIT LICENSE in matching checkout. |
| rcheevos | main | `30848fc5a6ed563dc2c5abac6a750c6d3ba51c6b` | MIT LICENSE in matching checkout; nested component notices also retained. |
| showtouches | master | `1c32407861e20ee2b046e1119c36e9d6385b4ab0` | MIT LICENSE.md in matching checkout; contents include further notices. |

## CocoaPods and bundled assets

`Podfile.lock` records Alamofire 4.7.3, AppAuth 1.7.6, GoogleAPIClientForREST 1.3.11, GoogleSignIn 6.2.4, GTMAppAuth 1.3.1, GTMSessionFetcher 2.3.0, Harmony 0.1, Roxas 0.1, SDWebImage 3.8.3, SMCalloutView 2.1.5, SQLite.swift 0.12.2 and SwiftyDropbox 5.0.0, with podspec checksums. Tracked Pods sources and project inputs are present; ordinary Run does not require pod install. Generated `Pods/Target Support Files/Pods-Delta/Pods-Delta-acknowledgements.markdown` and `.plist` preserve notices for ten listed third-party packages. Those acknowledgements do not include Harmony/Roxas and do not replace a permission audit of the actual linked sources. Pods are not part of the vendored-source hash set below.

The supplied Pokémon chart is `Delta/Assets.xcassets/PokemonTypeChart.imageset/pokemon.png`. Its asset provenance/redistribution permission remains unresolved; availability inside the app is not a grant. Existing Delta controller artwork and branding also need their applicable permissions retained. Newly generated Bound 2 branding is recorded in the source tree; no trademark endorsement or Apple/Nintendo affiliation is claimed.

## Snapshot evidence and changes

`PrototypeConfiguration/vendored-sources.json` records **16,879** dependency file hashes: 11,807 under Cores, 2,594 under External, and 2,478 under Vendor. The manifest's source URLs/revisions and exclusion lists are authoritative; these counts do not claim all 16,879 files are source code or that app/Pods/Swift-package files are hashed there. Run `python3 PrototypeTools/verify_sources.py` for an offline comparison that preserves local edits.

The snapshots contain reviewed local compatibility changes; they are not claimed to be byte-for-byte unmodified upstream checkouts. `PrototypePatches` contains the native framework/controller hooks, SNES comparator, RevenueCat compiler compatibility, N64/GLide snapshot metadata/resource changes, GPGX/melonDS native builds, ZIPFoundation target adjustment and dependency-signing patch. Upstream revisions remain the origin pins; individual file hashes identify the modified snapshot.

| Source snapshot path | Origin revision | Upstream URL |
| --- | --- | --- |
| `Cores/DeltaCore` | `633dfa86967816315fe19b482511dab1ce517f28` | https://github.com/rileytestut/DeltaCore.git |
| `Cores/DeltaCore/External/ZIPFoundation` | `62d759a37857b44769f485391ca9c32242108d35` | https://github.com/rileytestut/ZIPFoundation.git |
| `Cores/GBADeltaCore` | `869c34aeca9dd2b3fbd329092bb2743b0ae80c98` | https://github.com/rileytestut/GBADeltaCore.git |
| `Cores/GBADeltaCore/visualboyadvance-m` | `453fa0decf179360926fb417725a794aa496d6e3` | https://github.com/visualboyadvance-m/visualboyadvance-m.git |
| `Cores/GBADeltaCore/visualboyadvance-m/dependencies` | `33a0af6701313fed2219029a069c712740233a77` | https://github.com/visualboyadvance-m/dependencies.git |
| `Cores/GBCDeltaCore` | `0871ccaad2bbd7cbd2de0ce06f9e26dc3d1bfdde` | https://github.com/rileytestut/GBCDeltaCore.git |
| `Cores/GBCDeltaCore/gambatte` | `f8a810b103c4549f66035dd2be4279c8f0d95e77` | https://github.com/sinamas/gambatte.git |
| `Cores/GPGXDeltaCore` | `4af2ff5d68cffd12121b63157ffb79267573bfcc` | https://github.com/rileytestut/GPGXDeltaCore.git |
| `Cores/GPGXDeltaCore/Sources/GenesisPlusGX/Genesis-Plus-GX` | `58758aef3d8e12189899d67344db3b95c6379561` | https://github.com/ekeeke/Genesis-Plus-GX.git |
| `Cores/MelonDSDeltaCore` | `eb9b07ec17307cfd4986cb607f8ee5f6492d73cb` | https://github.com/rileytestut/MelonDSDeltaCore.git |
| `Cores/MelonDSDeltaCore/melonDS` | `a53f9bab7b5c06efcbc6ecdf30ac0367555995aa` | https://github.com/rileytestut/melonDS.git |
| `Cores/N64DeltaCore` | `56aefef59d947edbf2eb34b0a0288d751b006f30` | https://github.com/rileytestut/N64DeltaCore.git |
| `Cores/N64DeltaCore/Mupen64Plus/GLideN64` | `9669b94539d5862ac57a52d5b28bad1483f40a91` | https://github.com/rileytestut/GLideN64.git |
| `Cores/N64DeltaCore/Mupen64Plus/libpng` | `8439534daa1d3a5705ba92e653eda9251246dd61` | git://git.code.sf.net/p/libpng/code |
| `Cores/N64DeltaCore/Mupen64Plus/mupen64plus-core` | `aa9903b5446a9b50b8f5a31f927ca98e5a33a230` | https://github.com/rileytestut/mupen64plus-core.git |
| `Cores/N64DeltaCore/Mupen64Plus/mupen64plus-rsp-hle` | `f01fed082abc2aeabd55c8fe685df4c83115e2c2` | https://github.com/mupen64plus/mupen64plus-rsp-hle.git |
| `Cores/NESDeltaCore` | `c88ef1e7c68ad723194d1b691362ac7d7394f968` | https://github.com/rileytestut/NESDeltaCore.git |
| `Cores/SNESDeltaCore` | `35add3af36e6c42d777c554a277e098766a78995` | https://github.com/rileytestut/SNESDeltaCore.git |
| `Cores/SNESDeltaCore/snes9x` | `c3fa4009a3ce9724d8d5dc7646b1eed20f91234b` | https://github.com/snes9xgit/snes9x.git |
| `Cores/SNESDeltaCore/snes9x/win32/libpng/src` | `b78804f9a2568b270ebd30eca954ef7447ba92f7` | https://git.code.sf.net/p/libpng/code |
| `Cores/SNESDeltaCore/snes9x/win32/zlib/src` | `cacf7f1d4e3d44d871b605da3b647f07d718623f` | https://github.com/madler/zlib.git |
| `External/CheatBase` | `df52576e6fd1185747f41b022d9664ad0593608a` | https://github.com/rileytestut/CheatBase.git |
| `External/DeltaOperator` | `1fe5f5f2304c2440c18f74274eac5f69624d7aaf` | https://github.com/epilogue-co/DeltaOperator.git |
| `External/Harmony` | `c7b68f6e9d33173e28124b0c8ca90bd5009ef938` | https://github.com/rileytestut/Harmony.git |
| `External/Harmony/Backends/Drive` | `1edd96720f532d8f6f3c7bc6ab6ed45d3d0439bb` | https://github.com/rileytestut/Harmony-Drive.git |
| `External/Harmony/Backends/Drive/Google/GoogleAPI` | `4cc6a1d63d35aa247d7def6dbf883a6a2c4d7044` | https://github.com/google/google-api-objectivec-client-for-rest.git |
| `External/Harmony/Backends/Drive/Google/GoogleAPI/Deps/gtm-session-fetcher` | `fd27f019ef29c3c24ad978298f577376847c1a0f` | https://github.com/google/gtm-session-fetcher.git |
| `External/Harmony/Backends/Dropbox` | `71a359fb3be5a63df30f1c82e09869f1852bec70` | https://github.com/rileytestut/Harmony-Dropbox.git |
| `External/Harmony/Backends/Dropbox/SwiftyDropbox` | `bae8f0ba1484f39758f1eaa7666037481a57c2f2` | https://github.com/dropbox/SwiftyDropbox.git |
| `External/Harmony/Backends/Dropbox/SwiftyDropbox/spec` | `097e9ba0d39ecf2f9e97e24ecd9874983d3cef1d` | https://github.com/dropbox/dropbox-api-spec.git |
| `External/Harmony/Backends/Dropbox/SwiftyDropbox/stone` | `4d2348cff28424f4bd4229cca2365a70e1d428ec` | https://github.com/dropbox/stone.git |
| `External/Harmony/External/CwlPreconditionTesting` | `e717563a609f1c875a9b14d957ea9b0d0321cbc1` | https://github.com/rileytestut/CwlPreconditionTesting.git |
| `External/Harmony/External/Roxas` | `a4f2e9f2ebaede881eef6fee12e1e5289ae12766` | https://github.com/rileytestut/Roxas.git |
| `External/Roxas` | `d07c467b6f65cbd08ba296d630986efafb830f95` | https://github.com/rileytestut/Roxas.git |
| `Vendor/RevenueCat` | `3dd291434fd63594b8ada87bca960e001b708241` | https://github.com/RevenueCat/purchases-ios-spm.git |
| `External/ZIPFoundation` | `b979e8b52c7ae7f3f39fa0182e738e9e7257eb78` | https://github.com/weichsel/ZIPFoundation.git |

## Release status

The user made [the Bound 2 source repository](https://github.com/evanvonessen/bound) public; its public status was verified on 2026-10-04. Public access to the tracked build sources is now available. This inventory describes the current working tree; modifications still awaiting publication must not be claimed to match an already downloadable binary until their exact release commit/version is verified. Public repository access does not establish full corresponding-source completeness, proprietary SDK rights or public/App Store clearance. See `COMPLIANCE-READINESS.md` for release matching and the remaining permission/source gates.

## Additional 2026-10-04 audit observations

The separate archive audit checked 22 pinned Agora 4.6.4 / AgoraInfra 1.3.5 downloads against their package checksums. No SDK license grant was identified inside those archives; AgoraAtomicOps.h and other SDK headers state proprietary/prior-written-permission terms. Seven Agora frameworks are dynamically loaded by the app. No Agora-specific Delta linking exception or project agreement was identified. Public distribution therefore remains gated on explicit compatible permission or a separately authorized replacement; this change does not replace Agora or make a legal determination.

Two expired 2013 SDL WinRT test-signing PFX files (loopwave/testthread VS2012 TemporaryKey) exactly matched the pinned upstream fixtures and were not live Bound credentials. They are omitted from the current snapshot because they are unused by the iOS build. Their paths are recorded in vendored-sources.json exclusions; the upstream revision and existing history are preserved.

## Notes pixel font (added 2026-10-04)

`Resources/Early GameBoy.ttf` is the exact unmodified font from the
[author's DaFont page](https://www.dafont.com/early-gameboy.font), credited there
to Jimmy Campbell. Its name table records copyright LDEJRuff 2012, Creative
Commons Attribution Share Alike and the CC BY-SA 3.0 license URI.
SHA-256: `fb84ef1d7f837c5993b80b9a3319284dc49883394d0def0c9c999b51b4683d13`.
The unchanged font retains that license separately from application source.
Attribution, provenance and full license are in
[EARLY-GAMEBOY-LICENSE.txt](EARLY-GAMEBOY-LICENSE.txt), also bundled in the app.
No conversion, subsetting or author endorsement is claimed. Normal text rendering
uses system Unicode fallback; no global font installation or font service is used.
