# Nearby-only interactions — local acceptance, October 26, 2026

The standalone Select multiplayer menu is removed. Nearby interactions offer
Battle, Trade and Back, preserving incoming accept/decline, B cancellation,
consent, native activity selection and interrupted-activity recovery. Bound also
rejects remote Battle/Trade requests from legacy menus unless the friend is
already connected and has a fresh facing/adjacent context. Run setup remains in
the existing app interface. The Friends developer sheet no longer mounts the
old Soul Link run controls or Run Timeline entry point. Durable history,
protocol IDs, legacy setup and recovery handlers remain available to old saves.
Watch Partner remains removed by the preceding revision.

## Original bindings and customization

The imported upstream MFi mapping at `03c3cc97` maps rightShoulder to standard
r1 (native GBA R), rightTrigger to r2 (GBA Start), and leftShoulder to l1 (GBA L).
Bound had overridden rightTrigger with Next View and added a Debug R return warp
in `0da653e410405ce63d4aa24987ec6744a950e035`. Those overrides are removed.
Saved maps still take precedence, including custom Next View, explicit None and
custom bumper assignments. The existing optional Multiview focus navigation
remains. Native L opens the cartridge skills menu; R is passed through without
an app-injected warp. The unrelated stopped-music field recovery remains.

## Exact pair and save admission

- GitHub main verified before edits: Bound `a0d72ae24b0680cde1fbfb52fcc74c78ceb929b5`,
  multi_red `15765782bc7e4ac96cca48aeb4426d43a39a9183`.
- Combined ROM SHA-256:
  `fcfaa8a9fb022656994a429be4cba5b9f14ba6c477ec813d2d6a2aa3878edc00`.
- Library SHA-1: `51ebbe0108c0c18bb5bfcbef42ed3d19a4cfd606`.
- Independent ROM SHA-256:
  `48e52a7dc3a5dee8da66248be1405ebed04908fc816dbd7f76d94073999cf8c9`.
- Independent/combined layouts 11/12. ABI 1, wire 2, settings 5, Delta GBA core
  state 10 remain unchanged; equal versions alone never authorize a restore.
- Previous exact Friends multiview ROM profile (layout 10) is frozen alongside
  prior layouts 5, 6 and 8. All five exact profiles passed native load/capture/
  restore and cross-profile rejection checks. No existing settings are migrated.
- Debug simulator and unsigned Release app bundles contain the exact candidate
  ROM. Clean-cache reproduction produced identical bytes.

## Results

Artifacts are under `artifacts/multiplayer-isolation/nearby-only-interactions`
in the workspace, outside both repositories.

| Check | Result |
| --- | --- |
| Hosted app integration (`host-02.xcresult`) | 275 passed; zero failures/skips |
| Unsigned Release iPhone build (`release.xcresult`) | Passed |
| Game unit suite (`game-tests.log`) | 23 passed |
| Compiled native UI (`game-ui.json`) | 471 checks passed |
| Native button scenarios (`native-actions-04/verification.json`) | 27 checks passed |
| Normal and Debug cold startup | Both roles passed |
| Callback stack | 16 bytes retained, 32-byte maximum |
| Profile, imported SDK and generated contract checks | Passed |
| Clean-cache ROM reproduction and both app bundle hashes | Exact match |

The hosted suite includes native invitation windows/cursors/cancellation,
proximity and all cardinal-facing admission, consent/reconnect/cancel behavior,
independent Screen Share/Multiplayer combinations, controller defaults and saved
maps, native L/Infinite Repel toggling, old-profile recovery, and Debug/normal R
inside Viridian Mart with stopped-music fault recovery. Existing run settings
remain owned by their saved profile. Prior party-wipe evidence is not relabeled
as a new play-through of this candidate.

Native screenshots were inspected for Battle/Trade/Back, normal Start,
registered-item Select, L skills, and the chooser after button-driven walking.
Only ordinary buttons and declared host service data are injected in these
mGBA scenarios; no gameplay RAM writes. The nearby peer is declared fixture data,
not a live network avatar. App model tests separately validate proximity.

## Actual failures and limits

The initial hosted run exposed a video-presenter scheduling race in its test;
a bounded wait for the presenter was added and the full 275-test selection passed.
Two walk-up fixture attempts pressed A from a path that entered a native script
and was not interaction-safe. The guard correctly kept the chooser closed.
The final fixture walks left into an unobstructed tile before admitting the peer;
it verifies the native position changed and the chooser opened. Failed logs are
retained as `host.log`, `native-actions-final.log` and `native-actions-03.log`.

No physical controller, iPhone pair, authenticated live network, WAN recovery,
or full new battle/trade session was exercised in this step. Simulator/native
fixture results do not certify those behaviors. Statepoints remain unfinished
and uncertified. Original checkouts (including dirty 4person work) were unchanged;
both background publishers remain disabled and unloaded. Nothing was published,
deployed, uploaded to TestFlight or sent to Xcode Cloud.
