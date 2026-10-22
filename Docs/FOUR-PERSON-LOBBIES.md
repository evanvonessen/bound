# Four-person lobbies

The `4person` branches of Bound and multi_red add a shared social lobby with
independent progress. A lobby admits at most four accounts, including pending
invitations. It can contain two Soul Link pairs, a pair and two solos, or four
solo Nuzlocke players. Lobby membership never supplies a partner save, changes
another run's randomizer seed, or merges permanent losses across pairs.

## Native flow

Oak's Soul Link choice leads to Duos / Multi. Duos keeps the existing paired
setup. Multi selects a Soul Link partner and then additional Bound friends.
Each invitation needs acceptance. The native lobby displays solo/pair membership,
readiness, Start, Add Friends and Leave. Solo Nuzlocke has its own Solo / Multi
choice and keeps its own native difficulty, cheats and nickname options.

Start waits for joined players to be ready; unanswered invitations do not block
it. Players joining an already started lobby resume their own run. The launch
coordinator is a lobby role, not a gameplay host. Leaving does not end a Nuzlocke
or Soul Link. Returning membership is available explicitly through Select, rather
than repeatedly opening an invitation after a player leaves.

Bound owns authentication, invitations, membership, transport and persistence.
The cartridge owns its menus, native settings and gameplay. A versioned LBY1
extension occupies unused bytes of the existing data-only UI mailbox; the guest
never receives networking credentials. The added native menu state uses save-state
layout 3; battery-save format remains 1. Use the matching branch ROM and app.
Older raw emulator states are not compatible with the new reserved heap layout.
Active run manifests also retain their original ROM hash. Use a separate game
entry and new runs for this branch; keep main's ROM and existing run files together.

## Isolation and lifecycle

Each account has one stable lobby UID and a changing public membership session.
Private membership tokens remain in memory. Authenticated roster changes update
the live channel without replacing the pair's room identity. Recipient-addressed
RDT envelopes bind lobby ID, sender UID/session and recipient UID/session. The
receiver also checks the transport-authenticated UID. Old packets cannot reappear
after leaving and rejoining a slot.

Presence has a bounded freshness/interpolation buffer per peer and renders up to
three remote characters using the verified cartridge's sprite data. Pressing A
targets a nearby player. Battle traffic goes only to that opponent; Soul Link,
checkpoint and progression traffic goes only to the player's actual partner.
Friendly battles remain one-versus-one and restore temporary damage without
creating permanent losses. A departing opponent ends and restores that battle.

A guest leaving does not pause unrelated solos or pairs. Losing one's own Soul
Link partner retains the existing paired pause and recovery behavior. A solo run
does not require a connected lobby peer. Pair saves, two-party checkpoints and
server history anchors retain their existing rules. Leaving during a friendly
battle first restores the prebattle world; an unsuccessful restore remains blocked.

## Solo persistence

A solo manifest owns the account, game, run UUID, original ROM hash, nonzero seed
and immutable native settings. The original battery is preserved separately.
The durable Nuzlocke journal uses native catch/death enforcement and explicitly
marks its solo owner; it never merges peer loss packets. Missing or inconsistent
records stop continuation rather than silently starting a fresh journal.

Solo Nuzlocke storage is currently local to its device. Harmony sync is blocked
for active, incomplete or corrupt solo metadata, because an ordinary battery
upload cannot safely transfer its death journal and run identity. Ending a valid
solo run releases that guard. This branch does not claim safe solo cloud transfer.

## Backend and validation

The additive lobby RPC and backwards-compatible token endpoint extension are in
[Backend/lobby](../Backend/lobby/README.md). A feature-branch push is not a live
backend deployment. The released pair endpoint remains usable before the lobby
extension is activated; an unavailable lobby service reports an error without
replacing a saved run.

Focused tests cover authenticated four-member admission, concurrent capacity,
membership expiry/rejoin, sender/session isolation, independent presence buffers,
solo identity/settings/backup preservation, and native menu handling. Actual
cartridge UI checks execute the compiled ARM code and native emulator flow.
Release iPhone compilation is required before branch publication. Local tests
do not establish hosted authentication, live Agora delivery, four physical-device
performance or cloud transfer. No TestFlight delivery is implied.

The matching branch ROM has SHA-256
`75eb6c453d1ce1b50019550367980036aebbb8e89c7af21e8cc0338432714f2a`.
Validation on October 22, 2026 passed the Release iPhone build and 153 focused app
tests, including actual VBA-M rendering of three independent remote sprites,
continued movement after one departure, native mailbox/pause behavior, and solo
and paired native faint/rollback protection. The four-session routing test uses
the production session protocol with synthetic authorized transports. The sprite
test runs one actual core with synthetic peers; neither represents four phones
connected through the hosted service.

A full native friendly battle and production-session cancellation passed on two
dedicated QA simulators through a local command relay. Both worlds restored, and
both active Soul Link journals remained unchanged after temporary battle damage
and faints. This validates the native battle/recovery path, not Internet latency.

ROM checks passed 160 compiled ARM UI assertions, 67 world assertions, eight
deterministic build/ABI tests, 22 native Multi/solo setup assertions, and the
existing native Duo setup/recovery tests. The variant was built against the
verified, unchanged original ROM. A fresh rebuild of the original reconstruction
remains unavailable because the pinned x86 compiler is absent on this machine.
