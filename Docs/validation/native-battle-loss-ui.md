# Native battle-loss notification — October 29, 2026

The paired UI integration moves battle-loss presentation into the
cartridge's existing Links renderer. A advances through two lost pairs per
page and closes the last page; directional controls review pages. A held before
arrival cannot skip a page. Each device keeps its own Pokémon on the left.
Both the native view and the older-cartridge fallback use a symmetric red X.

Ordinary notices wait for an idle field, including closed native menus and
finished text printers. Hiding gameplay closes presentation without recording
an acknowledgment. The host durably acknowledges only the exact UUID returned
by native A input. Repeated pages, reconnects and journal rollback retain that
acknowledgment. Loss authority, acquisition records and Pokémon records remain
owned by the existing ledger.

Game Over installs a terminal presentation barrier while the core is paused.
Frames can then render the notification and sample A while the cartridge skips
all gameplay callbacks. Retiring the notice preserves that barrier until the
existing Game Over/menu handoff. The durable terminal record, account scope,
save-deletion barrier and explicit return action remain in their existing path.
Paused memory-replacement boundaries clear the ROM presentation port so that
its transient terminal barrier cannot freeze a restored or restarted execution.
If a terminal native view cannot open within two seconds, the core returns to
the existing paused Game Over/card path and keeps the loss unacknowledged.
An exact native A acknowledgment is excluded from that timeout even when the
coordinator polls before the session persists it. Paused preparation refreshes
the native snapshot so a late A cannot turn successful dismissal into fallback.

## Pair and compatibility

Integrated UI tips: Bound `56a750b508643ae5fe447831be05ae6b69107da7`, game
`e1fec26fc4c1287f0acc5ede3592e599c13317c7`. Main bases were Bound
`56be48fc2e546653d28fe1661a8bd6796c487efd` and game
`4381eaef81afe48de73e58452d4d4f3450c3738c`. The checkpoint and collision
slowdown fixes remain included.

Candidate ROM SHA-256:
`70b9d94c1d83f34f0d022a95f14ebc4865556e4f2d067bf2adc61736ef5bbd6b`.
Generated contract SHA-256:
`9a5ace164e8597eefdd3c6b6b88a650298bd64ccc950422f77c42d03dfca2fb1`.
Generated ABI header SHA-256:
`ad06af7834c3dbd1d6ebd3c6235142e658aba62a38acc2d8f147c58b0ca66236`.

The ABI remains 1.0, battery and checkpoint formats remain 1, cartridge state
layout remains 16 and reserved heap remains `0x2100`. The existing versioned
runtime interface admits this candidate and restores the original native
engine. Matching these versions does not authorize cross-ROM raw states: the
candidate requires its own exact ROM identity. Earlier cartridges and their
frozen profiles retain the Bound card and their own save bindings.

The unchanged core identifier is `com.rileytestut.GBADeltaCore`; its tracked
subtree is `c4a9cf4a90be88e62af5951cba5a5962cc49a70a`. The VBA-M native state
version remains `SAVE_GAME_VERSION_10`. No core or dependency pin changes.

The optional `BLS1` presentation extends the existing 1,024-byte BLN1 port at
byte 160: a 32-byte header followed by at most six existing 64-byte rows. The
header carries a notice UUID, row count and terminal-barrier flag. Native
capability, modal state and acknowledged/current UUIDs occupy bytes 168–211 of
the already reserved 256-byte UI output. No memory allocation or save-format
region was added. Unknown/unsupported cartridges do not receive this extension.

## Validation

Final integration evidence lives under
`artifacts/multiplayer-isolation/ui-elements-integration-20261029` in the parent
workspace, outside Git. Native UI output is at
`artifacts/multiplayer-isolation/ui-elements/main-merge-idle-native-01`.

- 55 native UI checks pass on the exact candidate using the Swift encoder's
  six-pair fixture. Both Debug roles cold boot through native setup. Checks
  cover malformed data, held A, pagination, B, deferred menus, hidden views,
  exact-ROM open-state restoration, intact party bytes, terminal callback
  barriers, ordinary Links lifecycle and bounded idle work. Rendered native
  and fallback pages were visually inspected.
- All 31 focused simulator tests pass without failures or skips, including
  actual Delta/VBA-M native A, durable journal acknowledgment and terminal
  callback isolation. Delayed A after the watchdog deadline is exercised before
  the session persists it: coordinator-first handling preserves acknowledgment
  instead of showing a duplicate fallback. Genuine stalls, paused retirement,
  unencodable notices and existing terminal/recovery cases remain covered.
- 13 pure Swift page/metadata tests and 13 battle-journal/packet tests pass.
  The combined cartridge passes 39 focused composition/distribution tests,
  497 presence checks, 41 field checks and 20 ledge/bicycle/surfing checks.
  The production runtime-interface verifier accepts the candidate and rejects
  incompatible engines/layouts and cross-release restoration identities.
- Fresh simulator build-for-testing and unsigned iPhone Release build pass.
  The app tests use the final candidate with fresh saves and state. Logs,
  `focused-summary.json`, and `focused-tests.xcresult` are under `app-qa`.
- Eight 960-frame movement cases retain 72 tile transitions at 1x and 3x, with
  distant collision active and inactive. This game-execution comparison reuses
  the validated Bound 35134fd8 harness/core and a newly generated exact-ROM
  anchor with the native follower; the new-app tests above separately validate
  the integrated presentation path. Presence still incurs extra guest work,
  so this does not establish identical engine cost or phone frame timing.

The first merged ROM's idle notification work produced 71 active-collision
steps versus 72 inactive. Its evidence remains in `movement-first`. The final
candidate checks optional presence cheaply when no view is active and publishes
capability with aligned words inside the existing UI seqlock. Actual notices,
active menus, terminal barriers and every authority check remain intact.

Loss fixtures are synthetic: naturally played blackout, physical-device and
WAN acceptance remain unverified. ROMs, saves, states and build outputs stay
outside Git. The game publishes through its existing main workflow; app uploads
remain separately authorized manual deliveries.
