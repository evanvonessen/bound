# Nakama multiplayer

Bound's authenticated experimental gameplay transport is Nakama, with deployment
support for Heroic Cloud. Supabase remains the account, friend authorization and run-lease
authority; existing paired save packages and Dropbox sync remain unchanged.
Agora is retained for explicitly requested friend video and spectating.

## Runtime

The app exchanges its current Bound session for a short-lived Nakama admission
ticket through `nakama-session`. The broker checks the live account, Auth
session, MFA, active friendship, both players' account status and block rules.
It repeats room authorization after contacting Nakama. Nakama verifies signed
tickets and binds their owner to its protected custom account ID.

Each client has one authenticated WebSocket to an authoritative room. Positions,
interactions, native battle bytes and admission renewals use distinct opcodes.
The server stamps the authenticated sender, enforces membership and lane limits,
and routes targeted battle messages only to their intended participant. The
client admits gameplay only from the selected authenticated partner.

Outgoing position updates use a bounded latest-value mailbox. Reliable messages
use a bounded queue; an overflow terminates the connection so battle recovery
can run. Encoding, sending and receiving run on the networking worker. Native
battle sends only enqueue bytes; no Agora pacing sleep runs on that frame path.
Emulator memory access stays on the completed-frame owner.

The room runs at 60 ticks per second and coalesces superseded positions each tick.
Nakama's WebSocket transport is TCP: marking a message unreliable does not give
it UDP delivery semantics. Positions can still be coalesced before sending;
messages already handed to TCP cannot bypass retransmission. This migration
does not assert a measured latency or frame-rate improvement.

The app renews membership through the broker every 40 seconds. Server membership
expires after at most 90 seconds without a valid signed renewal, independently
of the lifetime of the Nakama socket token. Missing configuration fails closed;
authenticated gameplay never falls back to Agora.

## Video and lifecycle

ROM-started multiplayer connects gameplay without starting the video engine or
capturing video frames. Opening partner video starts its separate authorization
and media connection. A video failure does not disconnect a healthy game room.
Ordinary manually selected friend sharing retains video. Gameplay and video
credentials renew independently.

Feature disable, backgrounding, sign-out and room changes fence old callbacks,
close gameplay channels and retain existing interrupted-battle recovery. The
paired-run ROM's intentional save, disconnect and recovery gates remain intact.
No account credentials, signed tickets or Nakama server secrets are written to
reports, save packages or source.

## More players and browsers

The server's signed member roster supports two through eight owners. Current
friend authorization, app sprite presentation, native battles and paired-save
rules still use two players. Larger rooms require an authorized group-membership
model and updates to those app/ROM rules; server capacity alone does not enable
more-than-two-player gameplay.

Browser clients can use Nakama's JSON socket protocol. Browser gameplay still
requires a compatible emulator, ROM bridge, input/audio/rendering and persistence.
The broker currently rejects browser Origin headers; a website needs an explicit
origin policy and its own integration tests before it is enabled.

## Deployment and validation

See [server runtime](../Backend/nakama/README.md) and
[session broker](../Backend/nakama-session/README.md). Configure a dedicated
Heroic Cloud title/runtime and matching private broker secrets before enabling
the service. The runtime deployment bundle contains server code only.

The private [runtime deployment repository](https://github.com/evanvonessen/bound-nakama-runtime)
contains the compiled server entry point, configuration fragment and digest
manifest. It excludes the app, game assets and secrets. Re-export and verify its
digest whenever server source changes before deploying a new runtime image.

On October 22, 2026, the Bound Heroic Cloud title was created and Supabase
migration `20261023032413_bound_nakama_room_authorization_v1` and
`nakama-session` version 1 were deployed. The paid Nakama server, repository
connection and private server secrets remain pending activation. Until those
steps are complete, the broker returns `503 not_configured`; hosted gameplay
is not available.

Focused checks cover ticket forgery/expiry, account and room binding, concurrent
room allocation, eight-member routing, lane limits, nonblocking client queues,
stale callback fencing, independent video and paired recovery boundaries. A
Release iPhone build and focused iOS integration tests are required before
publishing. Fixture or local-server results do not establish hosted delivery,
physical-device performance, browser play or multi-player ROM acceptance.

The combined main revision passed a Release iPhone build and 74 focused iOS
Simulator tests. Backend validation passed 65 broker tests, 39 runtime and
interoperability tests, 11 real PostgreSQL authorization groups and nine checks
against a local Nakama 3.41.0 server with three clients. Live Supabase readback
matched the reviewed SQL and function files, existing API definitions stayed
unchanged and anonymous, missing-session and browser-origin requests were denied.

## Persistent runs and manual saves

The `bound_run_v1` authenticated RPC stores logical run membership, immutable
configuration, monotonic shared-history bitsets, latest ROM-owned world snapshots, and the checkpoint head in
Nakama storage. These records outlive match shutdowns and socket reconnects.
The existing account/run ownership leases remain enforced; no account migration
or replacement of an existing lease is implied by a room connection.

A cartridge Save action starts one server-allocated checkpoint. Both cartridges
pause at a safe point, reserve the capture with Nakama, capture their own battery/recovery package, and upload it
in immutable 12,000-character base64 chunks. The server verifies the full payload
hash, run, owner, configuration, history and predecessor. It changes the head with
a conditional storage write only after both uploads have been sealed. Retried
requests are idempotent. A completed server checkpoint can be downloaded into the
existing validated incoming-package path; network data never directly replaces a
running game's files. Each player payload is limited to 16 MiB. Original local
packages and the existing optional cloud exports remain available.

There are no timed, timeline-event, or changed-working-state checkpoints during
play. The ordinary Delta automatic save-state path is disabled for a protected
multiplayer run. Lifecycle suspension may only capture an already-paused core;
it cannot interrupt running gameplay to save. Native battle/trade recovery
journals and shared history remain separate from manual game-save checkpoints.
Unsaved emulator progress remains on the device until an explicit save.

Room actors retain the last accepted pose separately from transport membership.
They checkpoint this small presence record at most once every five seconds and
on leave/termination, and restore it on room recreation. Opcode 6 carries these
server snapshots as presentation-only data, with their original age. The client
keeps a last-known avatar for up to 60 seconds, including reader stalls and socket
recovery, while the existing 750 ms authority timeout and stricter interaction
checks remain in force. No stale snapshot grants collision, trade, battle, or
progression authority. ROM changes, local state restores and explicit withdrawal
invalidate presentation. No emulator RAM or input simulation runs in Nakama.

Self-hosted Caddy exposes exactly `/v2/rpc/bound_run_v1` alongside `/ws`; all other
native Nakama endpoints remain private. Deploy the runtime and proxy route before
using a client that requires durable runs. Session polling alone never allocates
or captures a game save. Test real device/network interruption separately from
unit and simulator results.
