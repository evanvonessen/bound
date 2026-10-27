# Debug New Game defaults

New games created with **Debug Mode** use Easy difficulty, Minimal Grinding,
the existing common cheats, and Game Over on Party Wipe enabled. Players can
still change the explicit party-wipe choice in the new-game draft. Ordinary
New Game retains its existing options and progression. This game preset is
separate from the app's Enable Developer Tools preference.

Infinite Repel is a native skill normally unlocked by defeating **Anne** in
Viridian Forest (native trainer4). Her post-battle script at `0x0905B7AD` sets
unlock flag `0x1057`; the native skill script at `0x09058607` checks that flag.
The separate `0x1045` flag controls whether repel is currently on. Fresh Debug
startup sets the unlock only. Press **L** and choose **Inf. Repel** to enable or
disable it through the original skills menu. No separate app control is added.

Only the fresh-game continuation applies this unlock. Continue/restoration does
not reapply defaults, enable repel, or rewrite saved settings. Existing Normal
Debug runs and saved Game Over opt-outs remain valid with their original ROM.
New Debug games require the matching bundled candidate ROM; older cartridges
remain usable for their existing runs.

## Exact local candidate

- ROM SHA-256: `34d2320d582a2a2791d2168ac07cfe3880a6af72a80b34f4e8557c4727f0ec3d`.
- SHA-1 library identity: `90a8077cd42c2d8f053e6412250e3276b7c45316`.
- Cooperative raw layout8; battery/save-package/settings versions remain1/1/5.
- Retained original ROM `8bf5b967…` uses layout5; retained stack-safe cooperative
  ROM `02f97ffa…` uses layout6. Each keeps exact restoration metadata and identity.
- Frozen historical cartridges and saves are preserved, with no state conversion.
  Updater enrollment must not reset either historical profile.

This candidate is unpublished. Local builds require `BOUND_DEVELOPMENT_ROM`
pointing to the exact candidate (or its verified ignored build cache).
`PrototypeTools/bundled-rom.json` marks it local-only and prevents attempted
release downloads. Do not treat its tag as a published GitHub release.

## Validation scope

The task artifacts under `artifacts/multiplayer-isolation/debug-native-defaults`
record cold boots for both roles, ordinary locked-skill starts, native L-menu
on/off choices, VBA-M raw-state round trips, and wrong-profile rejection.
A button-only Route1 wild encounter supplies real healthy, fainted and
blackout-healed party bytes to the app's Soul Link/Game Over policy tests.
Backend tests independently exercise the terminal protocol and retained opt-outs.
These checks do not certify two live devices, WAN terminal delivery, or all
native battle/trade categories. The unfinished15 statepoints, historical fixture
recipes and their empty certificate registry remain unfinished and unchanged;
old raw fixtures cannot certify the candidate.
