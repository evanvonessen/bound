# Live presence device acceptance

This is client-side preparation on `multiplayer`. Physical-device/Internet
acceptance is **pending**: two physical devices are not available for this run.
Simulator, build and offline account-contract checks do not close that gate.

Preparation validation passed: 59 focused integration tests, both peers in the
paired VBA-M simulator run, and three QA-tool tests. The paired reports captured
visible movement and identify their runtime as `simulator` and transport as
`fixture`. Normal and QA unsigned Release iPhone builds both succeeded; their
bundled cloud configuration is byte-identical. All 58 protected backend, auth,
sync and configuration files and 17,060 pinned source files passed integrity
checks. No physical install or real Agora Internet session was performed.

## Preserve the current Bound setup

No Agora app/certificate/channel settings, Supabase project configuration,
database schema/RLS, deployed functions, account contracts, SDK versions or
dependency pins are changed. Authentication and short-lived RTC tokens still
use the existing Friends flow. Diagnostic recording requests no additional
tokens, creates no connection and changes no reader demand or video settings.
It is off until explicitly started, retains at most 900 one-second samples,
and stops after 15 minutes, including elapsed background time.

The ordinary `Bound` scheme retains its existing app ID, plist, entitlements,
signing team and `Delta` module. The opt-in QA build uses
`com.evanvonessen.bound.multiplayerqa` and the display name **Bound Multiplayer
QA**. Its generated plist claims none of the normal app's OAuth/deep-link URL
schemes, and its empty entitlement source requests no shared app/keychain
groups or push registration. By default, separately signed app identifiers
have separate keychain access; signed QA artifacts are additionally checked
for access confined to their own app identifier.
[Apple's keychain access-group rules](https://developer.apple.com/documentation/security/sharing-access-to-keychain-items-among-a-collection-of-apps).

A QA install uses the existing cloud services. Use two dedicated test accounts
and their existing test friend room, separate from any active normal Bound
session. Joining the same RTC identity/room from another client can interrupt
that identity's existing connection. This preparation creates no accounts,
friend relationships, signing assets, deployments or device installs.

Do not copy the normal app's container or credentials into QA. Import only
copies of the supported ROM and disposable saves, and leave cloud save sync
off in the QA app. Each instance retains independent local gameplay/progress.
The QA recipe supports in-app email/password sign-in and Files import. Provider
OAuth callbacks and push reception are unavailable in QA. Selecting a test
friend can still make the existing Jiggle request; use the dedicated test pair.

## Prepare the separate app

Create a fresh ignored output directory:

```sh
python3 PrototypeTools/prepare-multiplayer-device-qa.py prepare \
  --output .build/multiplayer-device-qa-config
```

This only generates a plist, empty entitlements and three app-specific build
overrides. It records the base Git revision and whether the checkout was dirty.
Build through the ordinary project entry:

```sh
xcodebuild -project Bound.xcodeproj -scheme Bound -configuration Release \
  -destination 'generic/platform=iOS' \
  -xcconfig .build/multiplayer-device-qa-config/DeviceQA.xcconfig \
  -derivedDataPath .build/MultiplayerDeviceQABuild \
  CODE_SIGNING_ALLOWED=NO build
```

The command above produces an **unsigned** artifact. It cannot be installed on
a physical phone as-is. Device signing requires an existing suitable development
profile/team setup. No profile, device registration or certificate is created
by these tools. Keep the normal app installed, and verify the QA artifact before
any future install:

```sh
python3 PrototypeTools/prepare-multiplayer-device-qa.py verify \
  --app .build/MultiplayerDeviceQABuild/Build/Products/Release-iphoneos/Bound.app \
  --production-app /absolute/path/to/normal/Bound.app
```

Verification rejects the normal app ID, production URL callbacks, shared app
groups, push entitlements and non-private keychain groups. With a normal build
supplied, it also checks that the bundled cloud configuration is byte-identical
and reports when that resource is missing from both builds. A missing resource
is not proof of a usable cloud connection. Verification never installs an app.

## Record an Internet session when devices are available

1. Use the same QA build and supported ROM on both devices, with separate
   disposable saves and dedicated test accounts. Put one on Wi-Fi and the other
   on cellular or a different external network.
2. In Friends, expand **Live player sprites → Connection check** and choose
   **Record connection check** on both devices before connecting. Connect using
   the existing test friend pair, enable **Show friend on map** on both, and
   resume on-foot gameplay.
3. Walk independent routes in all four directions while both cameras scroll.
   Check animation, map/elevation mismatch hiding, pause/battle and resume.
4. Keep the session running for at least ten minutes, crossing multiple normal
   token renewals. Background/foreground one app; interrupt and restore one
   connection. Confirm that old sprites disappear and fresh movement returns.
   Exercise actual save-state loading using disposable saves.
5. Stop the checks and export each report through Files. Bound makes no
   automatic report upload; Files saves to your chosen destination, which may
   be a cloud provider. Keep A/B reports separate and record which network each
   device used. Inspect physical performance separately; resident-memory and
   thermal samples do not measure FPS, battery life or network latency.

Reports contain whitelisted counters/booleans and reader state, elapsed sample
time, app version/build, device-versus-simulator classification and optional
QA source provenance. They contain no tokens, keys, account/room/channel/UID
identifiers, raw coordinates, ROM artwork, memory banks, saves or story flags.
Clearing the report releases its retained samples/export document.

## Interpret the evidence

| Observation | What it establishes |
| --- | --- |
| `authenticated` and `authorizationReady` | The client uses the authenticated flow and holds an authorized configuration. |
| `joined` and `transport.kind = agora` | The real transport joined; this alone does not establish pose delivery. |
| `streamCreated`, successful SDK result and rising `acceptedSends` | Local SDK accepted presence messages. |
| Rising `receivedMessages` and reader `received` | Messages reached this client and passed pose/session admission. |
| `peerConfirmed`, map/elevation agreement, `frameResolved` | The current peer and local scene can resolve a sprite. |
| Rising `renderedTicks`, `movementChanges`, `facingChanges`, `animationChanges` with nonzero `visiblePixels` | Live sprite frames were displayed on this instance. |
| Rising `tokenRenewals` and recovery completions with fresh visible movement | Renewal/recovery occurred during the recorded interval. |

Counters are cumulative observations; compare their change between samples.
A nonzero first sample alone does not establish activity during this recording.

Successful physical acceptance requires reports from **both** actual devices
(`runtime = device`, `transport.kind = agora`), bidirectional visible movement,
observed interruption recovery, independent saves, and a sustained session.
Fixture/simulator reports are explicitly labeled and cannot prove that gate.

The existing backend/authentication/token/configuration/sync files are preserved
byte-for-byte. If a live test points to a required service change, stop at the
diagnosis and keep that change outside this milestone's authorized scope.
