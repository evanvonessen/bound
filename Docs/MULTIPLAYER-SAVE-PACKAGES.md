# Multiplayer save packages

Each run binds an account-owned cartridge save to its partner, room, setup owner,
immutable shared settings, distinct seeds, exact ROM hash and protocol/save
versions. Original solo batteries and prior recovery files are preserved.

Version 2 completes a player's content-hashed snapshot locally, without a partner
receipt. Native Save flushes that player's battery, Soul Link ledger, timeline,
shared-event cursor and internal snapshot, together with any required native
transaction recovery. Each player has an independent checkpoint ancestry.
Server and Dropbox uploads use immutable copies in the background and cannot
reopen or delay gameplay. Version 1 paired packages remain readable for existing
exact-build recovery; they are not silently discarded.

Local suspension retains the most recent working state before app closure.
Normal reopening checks the local account/device, exact ROM, file hashes and
transaction integrity. It requires neither a partner connection nor matching
checkpoint IDs or equal progress. Cross-build raw emulator states remain
unsupported. A damaged local save has an explicit recovery path.

The shared journal records stable `(origin, sequence)` identities before sending.
Received events persist before effects, and effects persist before their applied
cursor. Duplicate/reordered delivery is harmless; contiguous and sparse per-origin
receipts ensure that a later sequence cannot hide a missing earlier one. Missing
messages retry after reconnect. Acknowledgements report durable synchronization;
they never authorize native frames or Save.

Soul Link death tombstones, used encounter slots, egg ordinals, pending events
and sequence counters are monotonic history. Restoring an older native save merges
that history rather than rolling it backward. A recorded death continues to bar
a corresponding Pokemon caught later. Older packages and replaced local files
remain available in restore originals. Restore transactions are staged before
activation, and interrupted native trade/battle recovery remains protected.

Shared journals remain addressable by run and owner after explicit end or a new
run archives a game folder, so a final queued event is not lost. Archived outboxes
can upload and receive durable acknowledgements without reopening their games.

Cloud imports and device transfers continue to validate account ownership, ROM
compatibility, content hashes and explicit ownership transfer. They never choose
between incompatible saves solely by timestamp. A transfer/recovery operation may
need its authoritative server records; an already validated local game does not
need continuous server or partner permission to progress.
An explicitly imported save first reconciles a fixed authoritative history
target, including its owner's earlier events. This finite local recovery step
preserves deaths and spent encounter slots before the first restored frame;
new partner progress cannot keep extending its target. Snapshot uploads renew
their own device authority between chunks without holding the gameplay loop.

Validation must cover different towns/badges, a closed partner app, offline saves
and reopen, delayed/duplicate/reordered events, gaps in acknowledgement cursors,
death before catch, and older-save loading without resurrecting a lost pair.
Runtime/device/network evidence limits are recorded with each published change.
