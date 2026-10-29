# Native battle-loss notification — October 29, 2026

The paired `ui-elements` branches move battle-loss presentation into the
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

## Pair and compatibility

Starting commits: Bound `35134fd87ca059dc0b800662b4209da689161ab2`, game
`9baa64971769f9773a6a34fdf489ce998b634b2c`.

Candidate ROM SHA-256:
`90a0bf2c6640b8c49521924072618f33990fe33344a28460b9ccd5d94d4c1855`.
Generated contract SHA-256:
`9a5ace164e8597eefdd3c6b6b88a650298bd64ccc950422f77c42d03dfca2fb1`.
Generated ABI header SHA-256:
`516439d6373a4747b2a9bcc5812889c604c75afd1a5a9a4cb41d778f2d3bfc97`.

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

Evidence lives under `artifacts/multiplayer-isolation/ui-elements` in the parent
workspace, outside Git:

- 36 native mGBA checks pass on the exact candidate, using the actual Swift
  encoder's six-pair fixture. Both Debug roles cold boot through native setup.
  Checks cover malformed data, held A, pagination, B, deferred menus, hidden
  presentation, exact-ROM open-state restoration, intact party bytes and the
  terminal callback barrier before/after durable acknowledgment. The rendered
  native page was visually inspected.
- 31 focused simulator integration tests pass, without failures or skips. The
  actual Delta/VBA-M test cold boots the candidate, publishes the real host page,
  verifies absence of the Bound card, uses native A, reopens the durable journal
  and checks that terminal presentation never advances gameplay callbacks.
  The final run also checks paused port retirement, stalled native presentation
  and refusal to resume for a notice that cannot be encoded natively.
  Existing terminal/recovery and legacy graphic cases also pass.
- 13 pure Swift native-page/metadata cases and 13 battle-journal/packet cases
  pass. Eleven cartridge composition tests pass. The production C++ runtime
  interface accepts the candidate and rejects wrong engines, layouts and
  cross-release restoration identities.
- Simulator build-for-testing and the final unsigned iPhone Release build pass.
  Final logs are `simulator-build-verified.log`, `release-build-recovery.log`
  and `recovery-tests.xcresult` / `recovery-summary.json`.

Failed early attempts remain in the artifact directory: missing SDK/cache
permissions, rejected wrong base-ROM input, freestanding C compiler repairs,
an obsolete battery-only cold-boot fixture and corrected UI assertions. They
are not counted as passing checks. Final native evidence is `native-05`.

The actual loss page is synthetic; no naturally played battle, complete
blackout, physical-device or WAN acceptance is claimed. There is no backend
deployment, ROM publication, permanent-link change or TestFlight upload. The
candidate must be used with this app branch to exercise the new native UI.
