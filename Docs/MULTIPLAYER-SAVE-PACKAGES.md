# Multiplayer server saves

Games marked `bound.multiplayer`, including the integrated Multi Red cartridge,
open Bound's server-save menu. A compatible ROM adapter is required before play.
Existing local multiplayer batteries, save states and legacy packages are ignored
and preserved; they are never imported automatically. Unmarked games retain
ordinary Delta saving. Experimental Multiplayer remains off by default.

## Two players, one permanent run

Nakama creates one UUID `save_id` after validating the creator's authenticated
friend room. Both participants see that ID in their server catalog even when the
friend is offline. Creation records immutable participants, room, ROM hash,
shared settings and separate nonzero randomization seeds. A stable creation
request ID makes a retry return the same run. Each participant chooses a personal
name and character; the creator chooses the shared options in Bound.

Each participant has an independent snapshot head under that shared ID. A manual,
automatic or disconnect save replaces only its owner's head. Checkpoint UUIDs
identify immutable snapshots, not additional runs. Save data includes the
cartridge battery, emulator state, Soul Link ledger, timeline, shared-event
journal/cursors and native battle/trade recovery records. Nakama's existing
private storage and independent snapshot protocol provide persistence; no second
save database or network framework was introduced.

The catalog has no TTL and is not tied to live-match lifetime. **Clear Server
Saves** is the client deletion path. Its confirmation explicitly covers both
players; the server requires membership, explicit shared-deletion confirmation
and the revision shown to the user. A changed run must be refreshed and confirmed
again. A durable tombstone fences late chunks, old writers and creation retries.
See [Nakama persistence and operation classes](../Backend/nakama/README.md).

## Conflict rules

### Checkpoint capture and gameplay pacing

The checkpoint boundary pauses the core, drains ordered progression events,
then copies the native v10 state, battery, memory files and history cursor from
that stopped execution. The state copy uses stored DEFLATE blocks, preserving
the existing VBA/gzip format without doing compression search during the pause.
The exact ROM/layout binding is captured with those bytes. After the normal
resume gate, a separate zlib stream recompresses only the owned copy and updates
its compressed-content digest. It never reads a resumed core or uses the core's
global gzip dispatch functions. A stored stream remains a valid recovery
fallback if recompression fails.

Checkpoint construction stays synchronous on the coordinator actor, preserving
final-save ordering, checkpoint ancestry and upload coalescing. The existing
15-second automatic interval and pending-save admission remain unchanged.
Failed ordered drains retain their existing pause/recovery behavior. Final or
background saves do not resume when the existing lifecycle gate forbids it.
This reduces the state-serialization part of gameplay pauses; journal drains,
pause admission and copying still require a stopped core. Package construction
still runs synchronously after that boundary.

Instruments signposts in `com.evanvonessen.bound` / `Checkpoint` expose
`StateCapture` (including whether compression ran) and `StateCompression`.
`ServerFinalSaveLifecycleTests` compares the native capture times and verifies
decompressed-byte identity, restore compatibility and corruption rejection.
The current-ROM adapter test also checks preservation of the ROM/layout tag.

### Authority and recovery

* Different players may save independently; their snapshot slots never overlap.
* Two devices for one player use compare-and-swap against the last known server
  head. The first valid seal wins. The other device stops and asks to refresh and
  reopen; timestamps never choose a winner or silently discard an account's head.
* Upload retries preserve immutable bytes and checkpoint identity. A final
  disconnect snapshot may rebase only onto the previously known head or its own
  in-flight upload. A rebase gets a new checkpoint UUID and checksum, retaining
  the same `save_id` and frozen game contents.
* Restoring requires the authenticated participant, exact game/ROM, valid content
  hashes and a fixed initial shared-history target. Gaps and permanent losses
  are reconciled before gameplay resumes. A partner's continuing progress cannot
  indefinitely extend that initial target.

## RAM working state and recovery

Marked games intercept native battery and state-file access before the core is
bound. Their working battery, state, journal, ledger and recovery files exist
only in memory. Manual state loading, local autosaves, legacy Dropbox GameSave
sync and general server-backup import/export cannot bypass this policy. Existing
files are untouched. The server remains the only persistent multiplayer store.

Pokémon's normal Save action schedules a server checkpoint. Automatic checkpoints
run about every 15 seconds at a safe boundary; a pending upload is retried before
another is created. Local emulator execution does not wait for the network or a
partner acknowledgment. The core briefly pauses to copy a consistent state,
battery and journal into RAM, then resumes before encoding and network upload.
This capture cost requires physical frame-pacing measurement; it is not a claim
of zero pause time or parity with upstream Delta.

During native battles/trades, the last safe world snapshot travels with current
transaction recovery data; temporary battle RAM is not saved as the world. Exit
and suspension retain an immutable final package in an independent task, drain
unacknowledged events, await any in-flight upload and attempt a final seal using
an iOS background assertion. Bounded retries never write a fallback to disk.
Failure/expiry retains the frozen package in RAM and offers Retry Save or a
confirmed Use Last Server Save action. A retry may use a renewed session for the
same owner; switching runs cannot silently discard a failed final save. The
Pokédex's current-save reader also uses the RAM battery, never an old local file.
Reopening always downloads the latest confirmed server snapshot. A network outage
or OS termination can lose changes since that checkpoint; the phone cannot make
an unreachable server durable.

The existing `(origin, sequence)` event IDs, contiguous/sparse acknowledgments,
deduplication, missing-event replay and Soul Link tombstones remain in use.
Presence is coalesced and freshness-bound, not strictly sequenced gameplay.
Battles and trades retain their reliable consent/transaction protocol. Nakama
validates authentication, ownership, schemas and event identities; it does not
simulate Pokémon game logic.

## Validation limits

Native and protocol tests cover local-write suppression, RAM round trips,
independent ownership, duplicate creation, event gaps/reordering, immutable
uploads, CAS conflicts, permanent catalog access and deletion fencing. Release
compilation is separate from runtime validation. Live backend deployment and
two-physical-device checks are pending. Test distance at 1/3/5/10+ tiles,
offscreen/reentry, maps/elevations, offline partner creation, two-account resume,
same-owner device conflicts, manual/automatic/disconnect saves, battle/trade
recovery, video, authentication and frame pacing before claiming device parity.

Local validation recorded October 24, 2026:

| Check | Result |
| --- | --- |
| Nakama runtime fixtures | 81 passed |
| Account broker and self-hosted service fixtures | 105 passed |
| Swift save-package tests | 49 passed |
| Swift Nakama client / ROM contract / disconnect tests | 12 / 27 / 7 passed |
| Presence / recorded-player / Soul Link suites | 25 / 11 / 51 passed |
| Cooperative contract and recorded-player follow-up | 24 passed |
| Native RAM state + battery roundtrip and disk-write suppression | Passed |
| multi_red full reconstruction gate | 452 passed; 23 retained stages, 40 gameplay segments, 102 rendered snapshots |
| Source/dependency integrity | 17,061 pinned files unchanged |
| SDK privacy integration checks | 99 hashes and 2 manifests verified |
| Raw state sync/file preservation and ordinary preference regression | 2 passed |
| Unsigned Release iPhone build | Passed |

The matching integrated cartridge SHA-256 is
`15f7be08ae295828ae95e2b7ede00e553ac5cbbea2b2e5789ad9a98494fe7707`.
These suite counts overlap and are not an aggregate test total. PostgreSQL/live
Nakama, physical phones and WAN/performance acceptance are not claimed.
