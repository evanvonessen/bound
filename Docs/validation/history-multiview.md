# History multiview — local validation, October 26, 2026

History replaces the former Connections page using the same `connections` raw
preference identity. The segmented tabs have independent gates:

| Game Debug Mode | Enable Developer Tools | Visible tabs |
| --- | --- | --- |
| Off | Off | History absent |
| On | Off | Connections |
| Off | On | Run Timeline |
| On | On | Connections and Run Timeline |

A disappearing selected tab falls back to an allowed tab. Initial single-tab
selection is reconciled too, so enabling the second tab preserves the current
page. Portrait/split cycles, landscape variants and Mac routing omit History
when neither gate is allowed. The DEBUG statepoints page is removed from rendered
surfaces and navigation catalogs. Its raw value remains decodable but inert.
The implementation, backend, fixtures and dedicated tests are preserved.

The original timeline owner, journal, filters and event capture remain in use.
The new screen does not migrate, clear or recreate event history. Connection
events snapshot the friend-list username and service before the room is cleared
or replaced. Independent media events are forwarded into the bounded shared
feed while each session retains its own transition state. A server join reads
“Connection ready for …”; a confirmed peer join reads “evanator3000 connected ·
Multiplayer” or “… · Screen Share”. Disconnect records retain the previous
friend's username even when the other lane uses a different friend.

D-pad Left/Right switches the allowed tabs and the right stick scrolls the
visible Connections or Timeline list. Existing Back behavior remains. Saved
layout/assignment values are not rewritten by transient gates. Ordinary content
changes retain their original fallback persistence; registered default values
are not unnecessarily copied into user preferences.

## Validation and artifacts

All artifacts are outside the repositories under
`artifacts/multiplayer-isolation/history-multiview`.

- `host-04.xcresult`: 293 hosted tests passed, zero failures/skips. Includes
  all visibility combinations, retired preference handling, fallback and saved
  selection, controller routing, Mac geometry, landscape layouts, default
  registration/export, connection logs, both independent transport lanes, timeline
  persistence and 43 preserved Debug-session tests.
- `history-ui.xcresult`: all four final focused rendered-view tests passed; covers initial Timeline,
  both tabs, controller switching/scrolling, each gate disappearing, neither
  allowed and byte-identical existing journal contents after all transitions.
- `release-04.xcresult`: final unsigned Release iPhone build passed.
- Generated profile, SDK and app/game contract checks passed. No ROM behavior or
  contract changed. The paired cartridge remains SHA-256
  `fcfaa8a9fb022656994a429be4cba5b9f14ba6c477ec813d2d6a2aa3878edc00`, layout 12,
  ABI 1/wire 2/settings 5, Delta GBA core state 10. Exact historical profiles
  remain unchanged. The bundled simulator and Release cartridges are checked
  against that hash; version equality alone is not save compatibility evidence.
- `checkout-audit.json`: original checkout heads/statuses match the prior audit;
  the game worktree is unchanged. 58 statepoint/backend source, fixture and test
  files compared byte-for-byte with HEAD. Publishers remain disabled/unloaded.

## Failures retained and limits

The initial run had nine assertion failures: stale DEBUG/cycle and fixed-History
expectations, plus one real ordinary-layout fallback persistence regression.
Expectations were updated to the requested navigation and the persistence
regression was fixed. The expanded run exposed a separate unnecessary write of
an unchanged registered default; that was fixed without weakening the check.
Failed receipts/logs (`host` and `host-03`) remain in the artifact directory.

These checks use isolated simulator hosts, virtual controllers and local mocked
transports. Physical iPhones/Macs/controllers, authenticated network connections
and WAN reconnection are untested here. Statepoints remain unfinished and
uncertified. No backend deployment, ROM release, push, TestFlight delivery,
Xcode Cloud action or shared-simulator refresh was performed.

GitHub main was verified before editing: Bound
`a0d72ae24b0680cde1fbfb52fcc74c78ceb929b5`, multi_red
`15765782bc7e4ac96cca48aeb4426d43a39a9183`. Work stays on the existing paired
`codex/multiplayer-isolation` worktrees; multi_red needs no new commit for this
app-only step.
