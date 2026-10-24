# Multiplayer save packages

Bound keeps each player's cartridge save and randomization seed separate. A run
manifest binds that save to its account, partner, room, settings owner, immutable
settings, distinct player seeds, exact ROM SHA-256 and protocol/save versions.
The original solo battery is copied before a new run manifest is created.

`BoundMultiplayerSaveStore` stores content-hashed immutable checkpoints under
Application Support/Soul Link Packages. Preparing a checkpoint captures the
131072-byte cartridge battery, Soul Link journal, timeline, optional internal
emulator snapshot and matching native battle/trade recovery journals and states.
Only a receipt for the same run, checkpoint and shared-event digest from the
partner account can complete it. Preparation and completion are separate files;
repeated messages are idempotent. Previous completed checkpoints remain on disk.
The exported cloud package includes the latest three complete checkpoints.
An explicit ROM End Soul Link action must first persist the ledger's ended flag.
The store then marks the manifest ended, keeps its packages and permits ordinary
solo saving. Starting a different run archives the entire finished package folder
under its immutable run UUID. Disabling multiplayer does not perform this action.

The session must pause the core, flush its battery and capture the internal
snapshot before preparing. It must exchange both receipts and finish committing
before resuming. On reopen it checks prepared checkpoints as well as the last
complete one. A package's internal `checkpoint.state` is available to the session
for exact-ROM recovery; the store never silently loads emulator states.
The session also updates `GameSave.modifiedDate` when a checkpoint completes,
including when its battery bytes have not changed.

Local suspension captures preserve exact emulator state, current battery, journal,
timeline and native recovery before backgrounding or disconnecting. They are kept
separately from paired checkpoints and retain earlier captures. Reopening validates
the exact ROM/account/device and matching personal files before using that state;
newer recorded deaths cannot be overwritten by an older suspension. A later paired
checkpoint supersedes a local suspension. Uncommitted suspensions are never cloud
exports. Partner history is reconciled after local validation and before gameplay.
Routine suspension retention follows capture order and keeps the latest three.
Older captures with native recovery content absent or changed in the current
capture remain intact. A personal-history revision includes journal, timeline and
native recovery journal changes, including victories and memorial updates that do
not change the shared acquisition/death bitsets.

The device also persists the last server-acknowledged acquisition/death bitsets
and any submitted update before its request leaves the app. Reopening accepts
either acknowledged result only when local history includes every recorded bit.
A legacy run can bootstrap from an exact current or completed-checkpoint digest;
unknown server history remains a conflict. These local recovery records contain
no lease credentials and do not grant authority on another device.

Harmony/Dropbox uploads one completed archive and its frozen battery. Each upload
gets immutable copies, so a simultaneous checkpoint cannot mix file generations.
Solo saves retain their ordinary battery behavior. Multipart downloads go into a
version-specific inbox before Harmony replaces any files; they never directly
replace an active game's battery or metadata. An incoming package without its
manifest prevents fallback to solo uploading or starting a different linked run.
Cloud errors do not prevent local preparation or completion.
Uploads also match the package owner to SyncManager's current Bound account owner,
so switching accounts cannot back up a different player's linked run.

Restore requires an inactive game and a fully validated archive. Account, run,
ROM, save/protocol versions, ancestry, file hashes and shared history must agree.
Recorded deaths and history cannot disappear, a changed working battery is not
silently replaced, and pending native recovery cannot be discarded. Divergent,
incomplete and incompatible archives remain in the inbox. Original files are
copied into a restore transaction before replacement. Interrupted transactions
block play and can be replayed from their validated package; completed restore
originals remain in `Restored Originals`.
Restore preparation is staged completely before atomic activation. An older
interruption without a replay package is preserved aside without changing the
originals, allowing retry; a present but corrupt package still blocks recovery.
Explicit Last complete checkpoint recovery installs that exact head's battery,
personal files and RAM together. It preserves the replaced suspension and rejects
an unfinished successor, newer encounters/deaths/events, or native recovery that
would otherwise be lost. It cannot validate one checkpoint and load another.
A newer run can replace a different ended run only with an authenticated ownership
grant for its account and exact ROM. The ended package folder and its current
battery, journal and timeline are archived first. Delayed downloads for that same
ended run are ignored, and unresolved native recovery still blocks replacement.

Device ownership uses a device-only Keychain identity. A foreign device cannot
adopt a run from a downloaded file or a timestamp. Adoption accepts only the
lease client's typed, current grant for the account, run and local device. The
grant must also represent an explicit transfer when the package belongs to another
device. Incoming versions are selected by checkpoint ancestry, never timestamps.
Foreign-device and replacement-run imports must also match the authoritative
lease's checkpoint and both checkpoint/history digests. A newer anchored death
history therefore rejects an older cloud package even on a fresh device.
The session must obtain and renew the authoritative lease while advancing and stop
before expiry. Package files do not themselves constitute a distributed lock.
The immutable original package remains unchanged after adoption; subsequent
checkpoints capture the new local owner. The authenticated lease, history-anchor
and permanent end-run migrations are deployed; their concurrency and expiry tests
passed against PostgreSQL. Signed-in hosted acquisition and competing physical
devices still require live validation.

Adopting locally restored app data preserves and retags the current suspension
before publishing the new manifest owner. The coordinator reloads that manifest
and validates the adopted suspension before resuming. Native soft reset revokes
save authority before capture and enters recovery; only a validated snapshot and
Retry can authorize the working game again. Snapshot restores rebase command IDs
from a fresh emulator sample so saved commands are not executed twice.

`MultiplayerSavePackageTests` covers local durability, both-party receipts,
retry/ancestry behavior, immutable upload snapshots, tampering, owner/ROM/device
checks, active-game rejection, death/progress rollback prevention and native
recovery inclusion. These filesystem tests do not establish Dropbox network
behavior, two-emulator checkpoint coordination, ROM safe points or native device
playback parity.
The two-store replay test covers a lost final commit receipt and repeated receipt
delivery across process reopen without rewriting either player's battery or death
journal. ABI tests exercise the actual cartridge packet decoder, bounded menu
encoder and freshness channel. The integrated transfer test uses the real lease
client with a synthetic server reply; it is not a live service test.
