# ROM-driven experimental multiplayer

Enable Experimental Multiplayer activates the ROM service, friend roster,
authenticated room transport, presence, shared progression and automatic reconnect.
The switch remains off by default. Friend accounts and ordinary Agora video remain
independent. Connection checks, player-state displays, recorded movement and the
older gameplay controls are available only with Developer Features enabled.

In the integrated cartridge, Oak offers Soul Link, vanilla Radical Red v4.1 and
Back using native multichoice windows. Selecting Soul Link opens the Bound friend
roster. Both players must choose each other from a new game. A durable run proposal
chooses the settings player randomly and generates distinct, nonzero player seeds.
The selected player uses Radical Red's native difficulty and randomization options;
both cartridges apply the same verified option flags. The persisted trainer-ID seed
feeds the native species, ability and move randomizers. Continuing never generates
replacement seeds or changes the settings owner into a permanent host.

Press Select in the overworld for the friend/action menu. It includes Soul Link,
battle, trade, Watch partner, Run timeline and explicit End Soul Link. Nearby battle
and trade invitations retain the existing native dialogue and native link services.
Battle/trade requests wait for the ROM menu to close before opening those services.
The existing restriction on friendly battles and trades during an active Soul Link
is retained: transient PvP deaths and traded encounter identities cannot yet be
reconciled safely with permanent linked records. The native dialogue states this
restriction. Watch partner opens the existing live video viewer from the ROM action.

A callback gate in the cartridge freezes both main callbacks, including battles
and scripts, while its native disconnect/recovery dialogue remains responsive.
The service publishes a short frame lease; an expired lease, disabled switch,
missing partner, incompatible history or expired server authority keeps the gate
closed. Cold recovery also has a native screen before Continue is initialized.
The exact snapshot is restored only after local and server-anchor validation and a
fresh peer challenge. Battery writes and native Soul Link observation remain
blocked until that working state is authorized. Both players must agree on the
run, checkpoint and shared history
before gameplay resumes. Disabling or backgrounding preserves a local suspension;
it does not end the run. Independent emulator save-state loading is blocked for
active or unresolved linked saves.

The in-game Save success callback requests a paired checkpoint. Automatic requests
follow timeline events and periodically while playing. Both cartridges freeze
before negotiating the shared digest, flush separate batteries and persist separate
snapshots/receipts. Both durable receipts are required for completion. Lost commit
messages can be replayed after reopening. Local suspension snapshots preserve more
recent working progress without becoming incomplete cloud backups. See
[MULTIPLAYER-SAVE-PACKAGES.md](MULTIPLAYER-SAVE-PACKAGES.md).

The authenticated backend grants one device per player/run. Its monotonically
fenced checkpoint and history anchors reject a stale cloud archive on a replacement
device, including when both players select the same older checkpoint. A transfer
requires a native confirmation, expired/released previous authority and a complete
package matching current server anchors. If newer progress has not reached Dropbox,
keep using the original device until a compatible complete package is available.
Network failure delays publication/renewal and pauses advancement when necessary;
local suspension and checkpoint persistence do not depend on Dropbox. See
[backend lease contract](../Backend/multiplayer/README.md).

End Soul Link first records a local pending-end receipt, then permanently ends that
player's run UUID on the server before completing the local end. A lost response
can be recovered after reopening. Older cloud packages cannot reactivate an ended
UUID; a new game uses a different run identity.

## Compatibility and evidence

Bound imports the data-only ABI exported by `multi_red`; it does not embed a second
game implementation. The UI ports are separate from BWP2 shared-world data. The new
reserved heap/save-state layout is version 2; original battery saves remain version
1. Exact integrated-ROM admission, data sizes and descriptor bytes are checked
before publishing host data. Old solo batteries and completed/working recovery
originals are preserved.

Validation includes native ARM execution of callback freezes, native Save detection,
option flags and all three randomizer consumers; native mGBA runs of Oak, both
settings roles and cold recovery; focused iOS integration tests of account/video
services, wire challenges, local packages, lost receipts and anchored transfer;
and PostgreSQL concurrency, session revocation, expiry, transfer and stale-anchor
checks. An unsigned Release iPhone build is required before publication.

These checks do not establish a complete physical two-device session, live Agora
packet-loss recovery, signed-in hosted lease acquisition or live Dropbox transfer.
Those network/device paths remain to be exercised together. No TestFlight release
or Xcode Cloud run is part of this change.
