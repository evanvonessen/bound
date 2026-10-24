# Bound Nakama gameplay rooms

This server runtime replaces Agora's gameplay data path. It hosts a small room
for verified Bound accounts while each phone continues to emulate, accept input,
render and play audio locally. Agora remains available for ordinary friend video;
Ordinary game backups remain separate; multiplayer save data uses the permanent
Nakama run storage described below. The default legacy mode keeps the existing Supabase account bridge; the new self-hosted mode makes Nakama the account authority.

The runtime works with Nakama or Nakama Enterprise on Heroic Cloud. The native
transport uses secure WebSockets, which is also available in browsers. This
does not make browser gameplay or larger friend groups an implemented feature:
the current friend authorization service, ROM protocol and app interaction still
select a pair. The room runtime and wire envelope support two through eight
authorized members without relying on one globally selected remote user.

## Self-hosted account mode

`BOUND_ACCOUNT_MODE=nakama` enables the private account gateway in
`../selfhost/`. `BOUND_GATEWAY_SECRET` authorizes server-only account RPCs and
native session issuance; it must never reach the app. Nakama issues both access
and refresh tokens. The compatibility gateway reads the native `uid` and
`vrs.session_id` / `vrs.aal` claims and verifies every bearer with Nakama plus its
private revocation journal. Account UUIDs remain the Bound owner UUIDs.

Email confirmation, recovery capabilities, session rotation and encrypted TOTP
factors use Nakama private storage. The gateway sends email through Resend.
Self-hosted gameplay admission checks the Nakama UUID directly and does not
accept the legacy `bound:<owner>` custom-identity mapping. The legacy deployment
remains available until explicitly retired; do not set this mode on it.

Expose only `/ws` and the authenticated `/v2/rpc/bound_run_v1` and
`/v2/rpc/bound_independent_v2` paths from Nakama. Keep account RPCs, native REST
auth, gRPC and the console private. The account runtime denies player-session calls to the
private RPC even when a player knows its name. Use the deployment and import
instructions in `../selfhost/README.md` for the replacement server.

## Build and focused checks

```sh
cd Backend/nakama
npm ci --ignore-scripts --no-audit --no-fund
npm test
npm run export:heroic
```

TypeScript is pinned in the lockfile. Compile-time Nakama declarations are
vendored at an immutable upstream commit with their Apache-2.0 license in
`types/`. No executable npm package enters the deployed runtime.

`npm test` compiles the ES5 entry point and exercises it in a JavaScript VM with
Nakama API fixtures. It covers signed identity, broker interoperability,
concurrent allocation, membership/session isolation, targeted battle routing,
position coalescing, command order, eight-member rooms, rate limits, admission
renewal and expiry. This is not a real Nakama, Heroic Cloud or device test.

`npm run smoke:local` exercises the actual Nakama REST/JSON WebSocket protocol.
It requires an already running **isolated local server** on `127.0.0.1:57350`
with a disposable Nakama database, the synthetic bridge/server keys named in
`tools/local-smoke.mjs`, the compiled entry point and a 32768-byte socket limit.
All API, gRPC and console listeners must bind localhost. It refuses remote URLs;
the optional `BOUND_NAKAMA_SMOKE_URL` override also requires localhost HTTP.
The smoke creates synthetic accounts, rooms and sockets in that disposable DB.

Validation on October 22, 2026 used the official Nakama 3.41.0 Darwin arm64
binary (`3.41.0+cab8af58`), verified against its release SHA-256, and isolated
PostgreSQL 17.6. Nine real-server checks passed: denied alternate/unsigned/
impersonated auth, concurrent room allocation, three joined clients and roster,
denied client relay creation, trusted movement source and no self echo,
8192-byte targeted battle payloads, rejected outsiders, ticket renewal on the
existing socket with expiry of an unrenewed peer, and rejection of sender
forgery. The server and disposable database were stopped after validation.
This establishes local runtime/API compatibility, not WAN latency, iPhone frame
pacing, hosted deployment or live account authorization.

## Heroic Cloud deployment

Heroic Cloud's builder expects precompiled JavaScript in a server-only repository
and does not compile TypeScript. Bound's project rules prohibit committing build
output to the app repository. `export:heroic` therefore creates an ignored
`build/heroic/` handoff containing `index.js`, its SHA-256 manifest and a config
fragment. Publish that handoff to a dedicated server repository connected to the
authorized Heroic Cloud builder; do not connect the full app/assets repository.
The supplied Dockerfile is an alternative packaging path for local or compatible
container environments, and is not the Heroic Cloud builder configuration.

1. Use an existing authorized Heroic Cloud organization/title and a deployment
   region close to the players. This change has not provisioned paid resources.
2. Connect the dedicated runtime repository to a builder. Select a supported
   Nakama version compatible with the pinned declarations (the container example
   uses 3.41.0), with the highest available Heroic revision for that version.
3. Build the exact runtime commit and deploy the resulting image. Apply the
   fields in `heroic/nakama-config.yml` using the deployment's Nakama
   configuration editor, with `runtime.js_entrypoint: index.js`.
4. Set `BOUND_NAKAMA_BRIDGE_SECRET` as a **Runtime secret variable**, using the
   same high-entropy value (at least 32 characters) as the Supabase
   `nakama-session` broker. An ordinary container environment variable alone is
   not a Nakama runtime variable. The module refuses startup if it is missing.
5. Keep the Nakama server key, session encryption/refresh keys, runtime HTTP key,
   console password and database credentials in the platform's secret settings.
   Do not retain Nakama development defaults. Only the server-side broker needs
   the server key; clients receive an access token and short admission ticket.
6. Configure and deploy `../nakama-session/` and its authorized SQL RPC. Keep
   its `NAKAMA_HTTP_URL` pointed at this deployment's HTTPS origin. The broker
   builds the matching WSS URL and never accepts a client-selected upstream.
7. Verify two real accounts join the same authoritative match, one-way traffic
   and unauthorized attempts are rejected, ticket renewal stays connected,
   membership removal expires within 90 seconds, and battle interruption enters
   the existing recovery flow. Then measure frame pacing, packet age and battle
   waits on physical phones, with video both on and off.

No cloud account, deployment, billing agreement or credential is created by these
files. Successful compilation and fixture tests do not establish live delivery.

## Authentication and room allocation

The broker validates a live, confirmed, non-anonymous Supabase account, active
account fence and current friend room membership before it signs an admission
ticket. It rechecks membership immediately before returning credentials.

The ticket is `base64url(JSON UTF-8) + "." + hex(HMAC-SHA256(encodedPayload))`.
All UUIDs must be lowercase. Claims are exactly:

```json
{
  "version": 1,
  "protocol": "bound-room-v1",
  "ownerID": "11111111-1111-4111-8111-111111111111",
  "roomID": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
  "members": ["11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222"],
  "issuedAt": 1000,
  "expiresAt": 1090
}
```

`members` is sorted, unique and contains two through eight owners. Tickets last
at most 90 seconds. Custom authentication requires `id: "bound:" + ownerID`
and `vars.bound_ticket`. The hook verifies the ticket and replaces caller vars;
other built-in authentication methods and custom-ID linking/unlinking are
rejected. The Nakama user ID is a separate server identity and is never confused
with the Supabase owner ID. Match admission retrieves its protected account
custom ID and checks both identities.

Authenticated RPC `bound_room_v1` accepts `{"ticket":"..."}` and returns
`{"matchID":"...","roomID":"...","protocol":"bound-room-v1","nakamaUserID":"..."}`.
A server-only storage record maps room IDs to live authoritative matches.
Create-only/versioned storage writes select one winner under concurrent room
allocation. Losing candidate matches are terminated; stale records are replaced
using their observed storage version. Empty matches expire after 60 seconds.
The room's membership snapshot is fixed during that match. Changes require a
freshly authorized room lifecycle rather than a client extending its own roster.

Clients join the match with metadata `{"bound_ticket":"..."}`. One active
socket session is admitted per owner. The broker is called every 40 seconds and
the fresh ticket is sent on opcode 5. The match removes expired sessions even if
a valid Nakama access token remains. Revocation is therefore bounded by the
90-second admission lease; replaying an old ticket cannot extend its expiry.

## Wire and performance contract

Nakama match-data payloads are UTF-8 JSON envelopes. The Nakama JSON socket
protocol itself base64-encodes the envelope in `match_data_send.data`.

| Opcode | Client envelope | Delivery and limits |
| --- | --- | --- |
| 1, player position | `{ "v": 1, "body": "<base64>", "targetOwnerID": "<optional UUID>" }` | At most 768 decoded bytes; 30/s sustained, burst 60. Coalesced to newest per sender/target each 60 Hz server tick. |
| 2, shared events | Same envelope | At most 4096 decoded bytes; 30/s sustained, burst 60. Reliable and preserves arrival order. |
| 3, native battle | Same envelope, **targetOwnerID required** | At most 8192 decoded bytes; 120/s sustained, burst 240. Reliable and sent only to that owner. |
| 4, roster | Server only: `{ "v": 1, "members": [{ "ownerID": "...", "online": true }] }` | All authorized members are listed, including offline members. |
| 5, renew admission | `{ "v": 1, "ticket": "<fresh broker ticket>" }` | Validates owner, room, roster, signature and expiry. 0.2/s sustained, burst 3. |

Forwarded envelopes add `senderOwnerID`, derived from the admitted socket
session. Clients cannot select it. Broadcasts exclude the sender account;
targets outside the signed room or targeting oneself are rejected. Only
admitted, unexpired socket sessions may send. All traffic shares a 512 KiB/s
per-session ingress byte budget with a 768 KiB burst. Invalid or over-limit
reliable traffic disconnects the sender so the battle/recovery layer can fail
closed; excess position packets can be discarded.

The `reliable: false` position flag does **not** turn WebSockets into UDP.
TCP can still delay messages after loss. Position coalescing and bounded native
queues avoid intentionally replaying stale positions. No local game frame waits
for a server tick or a network send. Battles can still wait for peer commands
where the existing ROM protocol requires it. This runtime validates room access
and routing; it does not execute or prove the correctness of either ROM's game
state. Video, saves, screenshots and ROM images must not use these lanes.

References: [Nakama TypeScript runtime](https://heroiclabs.com/docs/nakama/server-framework/typescript-runtime/),
[match API](https://heroiclabs.com/docs/nakama/server-framework/typescript-runtime/match-handler/),
[server configuration](https://heroiclabs.com/docs/nakama/getting-started/configuration/),
[Heroic Cloud repository setup](https://heroiclabs.com/docs/heroic-cloud/concepts/titles/builders/repository-setup/),
[Heroic Cloud builders](https://heroiclabs.com/docs/heroic-cloud/concepts/builders/best-practices/).

## Independent progression protocol

`bound_independent_v2` uses the authenticated room ticket without requiring an
active match or partner socket. A CAS-protected setup document records one
chooser, ownership epoch, exact compatibility and distinct player seeds. Commit
validates native options, the rival and Debug preset. Explicit takeover requires
30 seconds of chooser absence and advances the epoch. Commitment is immutable.
Cancellation is idempotent and retains an absent-run tombstone.

Immutable events use run/origin/sequence identities. Server upload receipts and
client delivery receipts are distinct. Gap-aware cursors preserve reordered and
missing events, even with an offline backlog larger than one request batch.
Acknowledgements never grant permission to move or save. Each player's chunked
version-2 snapshot seals against its own expected head, independently of the
partner's progress. Snapshot upload and event polling run separately.

Version-1 records remain intact. Explicit migration verifies the original
server-owned configuration and exposes monotonic legacy bit history separately
from new event sequences. Clients merge it before emitting ordinary events.
Production activation must also deploy the Caddy route for this authenticated
RPC. Fixture validation does not establish WAN or physical-device behavior.


## Permanent shared save library

`src/saves.ts` extends `bound_independent_v2`; it does not introduce another
snapshot protocol or account backend. The permanent, server-generated UUID
`save_id` is the existing version-two run key and `identity.run`. Both accounts
use that same ID. Manual saves, automatic checkpoints and disconnect captures
use the existing `save`, `saveChunk`, `saveSeal` and `saveDownload` operations.
They never allocate another run.

The model is **one shared run with two independent player heads**. Its immutable
configuration contains the ROM compatibility hash, shared native settings,
participants, friendship room ID and two distinct server-generated seeds.
The creator can begin while the friend is offline. Both accounts see the run
immediately; the friend's first launch initializes their own character, and all
subsequent launches load their own latest sealed snapshot. Shared progression
continues through the existing per-origin event journal. One player's snapshot
cannot replace the other player's snapshot or roll the journal backwards.

| Server-owned storage | Content |
| --- | --- |
| `bound_independent_v2/<save_id>` | UUID, `game_id`, immutable participant list/configuration, per-account profiles, cursors/delivery receipts, independent snapshot heads, revision, UTC creation/update timestamps. |
| `bound_independent_v2/<save_id>/save/<owner>/<checkpoint>` and child chunks | Existing immutable snapshot descriptor, package, battery save, emulator checkpoint and accompanying recovery state. |
| `bound_events_v2/<save_id>/<owner>/<sequence>` | Existing immutable progression event identities and payloads. |
| `bound_save_requests_v1/<owner>/<request_id>` | Creation retry key → permanent UUID and configuration hash. No snapshot or profile is stored here. |

All objects have client read/write permissions zero. Authenticated RPCs enforce
ownership; clients cannot choose a different account or mutate storage directly.
The authorized `members` on the root are the participant relation. Listing
queries those roots in Nakama's PostgreSQL storage and filters by authenticated
account and game, avoiding a second index that could disagree with ownership.
The query selects keys only; a bounded `storageRead` batch decodes their values.
This avoids SQL-driver JSONB representations and preserves key order and the
pagination cursor even if a run is deleted during the read.
There are no expiry fields, TTLs, age-based deletions or retention jobs. Previous
sealed checkpoints, incomplete upload chunks and events remain until the user
explicitly clears the shared run or both players return to the menu after an
enabled full-party-wipe game over. Deployments must plan storage capacity and
backups accordingly. Older v1/v2 records remain intact; the library lists newly
server-created saves and does not silently import existing local runs.

### Library authorization and RPC contract

The existing `nakama-session` broker accepts `{"protocol":"bound-saves-v1"}`
for library access. For New Game it also accepts `roomID`, resolves its current
friendship and signs the derived `partnerID` and room. Neither path opens a live
match or requires the partner's socket. The broker returns `httpEndpoint`,
`accessToken`, `ownerID`, `expiresAt` and `saveTicket`, plus `partnerID`/`roomID`
when creation is authorized. The token uses the existing account authority.
No account migration or backend-default switch is part of this feature.

The HMAC envelope is unchanged. Save claims are exactly
`{version:1,protocol:"bound-saves-v1",ownerID,issuedAt,expiresAt}`, optionally
with **both** `partnerID` and `roomID`. Leases last at most 90 seconds. A renewed
save ticket verifies the account without requiring the original room to remain
open or the friendship to remain current; persisted participants control access.
This retains both participants' recovery access after a friendship ends. Such a
ticket cannot authorize live match entry. Live play still requires an ordinary
room ticket and the existing current-friendship checks.

All requests below go to `bound_independent_v2` with `saveTicket`. UUIDs in
request keys are lowercase. `save_id` aliases the existing `runID`; supplying
both with different values is rejected.

| Action | Additional request | Result |
| --- | --- | --- |
| `list` | `gameID`, optional `cursor` UUID | `{version:2,runs:[...],cursor}`; at most 100 UUID-ordered roots. Follow cursors until null, then sort presentation by `updated_at` if desired. Refresh restarts the listing. |
| `create` | Stable retry `request_id` UUID, authorized `partnerID`, `gameID`, `romSHA256`, version-four or version-five base64 `settings`, optional `profile` and `partnerProfile` | Complete version-two run state with a server-generated `save_id`; creates the root, both supplied trainer profiles and retry key atomically. |
| `get` | `save_id` | Existing version-two run state, including snapshot descriptors, event cursors, profiles and caller-oriented identity/seeds. |
| `profile` | `save_id`, `{name,gender}` | Updates only caller's profile before their first snapshot; name is 1–7 ASCII letters/digits, gender 0 or 1. Exact retries remain valid after saving. |
| `events` | `save_id`, existing `events` and `after` | Existing upload/delivery acknowledgements and gap-aware missing-event batches. |
| `save` / `saveChunk` / `saveSeal` / `saveDownload` | `save_id` plus existing snapshot fields | Existing independent snapshot protocol. |
| `delete` | `save_id`, `confirmSharedDeletion:true`, current `expectedRevision` | `{save_id,deleted:true}` after deleting both participants' snapshots and events. |
| `gameOver` | `save_id`, stable `eventID` UUID | Absorbs the run when its shared settings enable game over; concurrent triggers return the first event ID. |
| `gameOverReturn` | `save_id`, exact `eventID` | Requests both players return to the menu. |
| `gameOverMenu` | `save_id`, exact `eventID` | Records only the authenticated caller's receipt after their menu is presented; the second participant receipt tombstones the run and removes its children. |
| `gameOverStatus` | `save_id`, optional exact `eventID` | Reads terminal state, including after deletion, and retries interrupted child cleanup. |

Every listed root and managed run response includes `save_id`, `game_id`,
`roomID`, `participants`, `identity`, `revision`, `created_at`, `updated_at`,
`profiles` and `saves`. Times are ISO 8601 UTC strings. `updated_at` records creation or the latest
successfully sealed snapshot; no-op polls and identical retries do not change
it or churn the revision. `identity` is oriented to
the authenticated caller, while `settingsOwner` retains the original chooser.
An offline friend with no snapshot receives their own identity and seed rather
than the creator's save bytes.

New Bound runs collect both trainer names and characters before creation. The
creator's profile is keyed to the authenticated account; `partnerProfile` is
keyed only to the partner authorized by the creation ticket. Both become part
of the idempotency fingerprint. Clients that omit `partnerProfile` retain the
original fingerprint and first-join profile prompt. Later profile updates still
affect only the caller and remain locked after that player's first snapshot.

### Conflict resolution and deletion

Creation retries reuse `request_id`; reusing it with changed configuration is an
error. The root plus request mapping commit in a single Nakama storage batch, so
a lost response or concurrent request cannot create duplicate runs.

Snapshot chunks are immutable and checksum verified before publishing a head.
`saveSeal.expectedHead` must equal **that player's** current head; the snapshot's
predecessor must match. Different players may seal independently. Two devices
saving the same account from one predecessor have one CAS winner. The loser must
fetch the server head and restore/reconcile before a new capture; it must not
silently overwrite the winner by substituting a newer expected head. Retrying
the exact winning checkpoint is idempotent. A partial upload never replaces the
last valid head. Shared event identity conflicts similarly reject changed
payloads for the same `(save_id, origin, sequence)`.

Clear Server Saves is shared deletion: the confirmation must state that the run
is removed for **both** players. An authorized participant may confirm it; no
partner connection is required. A stale `expectedRevision` fails and requires a
refresh. Deletion first atomically replaces the run with a minimal participant
and UUID tombstone, then removes every snapshot/chunk/event under that UUID.
Each managed child write atomically checks the parent revision, fencing uploads
already in flight. Repeating deletion completes interrupted cleanup safely. The
tombstone and hashed creation retry mapping prevent delayed requests from
resurrecting deleted gameplay data.

Game over is a separate absorbing lifecycle. Version-five settings byte 21 is a
keep override: zero enables the flow, one disables it and is legal only with
Debug byte 20 set. New Debug presets default to the disabled flow; ordinary
presets enable it. Version-four settings retain the enabled policy. A terminal
run rejects saves, profile changes and new shared events; final reads and empty
event polls remain available. Both menu receipts are required before deletion,
including when one player is offline. The terminal event ID and participant
receipts remain in the minimal deletion tombstone so retries cannot target a
different run or resurrect its progress. Generic `delete` cannot bypass an
unfinished game-over menu barrier. Deploy the updated runtime before clients
start sending version-five settings or these lifecycle actions.

## Operation classes and recovery

| Class | Ordering, acknowledgement and retry | Validation / execution |
| --- | --- | --- |
| Local-only | No network sequence or acknowledgement. | Emulation, rendering and input stay on their current local paths. |
| Position / presence | Coalesce newest poses; discard stale updates. No per-pose durable acknowledgement. | Existing owner/room admission, packet bounds and client movement continuity. Tracking is independent of rendering distance. |
| Independent progression | Immutable per-account sequence IDs, server upload receipts, separate client delivery receipts, contiguous plus sparse gap cursors; retransmit identical unacknowledged events and poll missing operations. | Managed runs accept the existing `world` and `soul` event formats, validate their structure and origin, and reject unsupported/malformed operations or changed duplicate payloads. Nakama does not simulate Pokémon. |
| Synchronized gameplay | Existing reliable battle/trade control ordering and peer confirmation; retain interrupted battle recovery. | Existing targeted room membership, native protocol checks and synchronization; ordinary movement never waits for these acknowledgements. |
| Persistence | Atomic creation retry key, immutable chunks, checksum seal and per-account CAS head; retries keep the same run/checkpoint IDs. | Save-ticket authentication plus permanent participant authorization. Loading returns only caller's checkpoint bytes. Shared deletion is explicitly confirmed and revision checked. |
| Session | Refresh bounded leases; rejoin the authorized live room separately from restoring a persistent save. | Account/session revocation checks, live-room ticket renewal and independent permanent-save authorization. |

A reconnect refreshes save authorization, fetches `save_id`, downloads and
verifies the caller's latest sealed package, restores its checkpoint, then
continues the existing gap-aware event recovery. Lost event or seal responses
retry the original identities. No acknowledgement grants permission to execute
local frames. Unexpected disconnection can recover only the latest checkpoint
successfully received by the server; untransmitted progress cannot be recovered
by a server-only persistence design. Keep checkpoint upload and event polling
off the emulator frame worker.

For an intentional close, the client freezes its final package and RAM recovery
files before detaching the core. `BoundServerDisconnectSave` owns that immutable
package and the account session independently of the coordinator, waits for the
previous upload, and holds an iOS background task while draining pending events
and the last snapshot. Only event identities covered by a previously validated
local server receipt are skipped; current GET cursors alone do not establish
payload equality. Remaining events use the existing immutable batch protocol.
The final seal accepts only the expected old head, the already-pending own head,
or this task's exact checkpoint receipt. Changed ancestry gets a fresh checkpoint
UUID while preserving the shared `save_id` and captured bytes. Another device's
head is a conflict rather than overwrite permission. There are at most three
attempts for transient network failure. Cancellation, expiry or failure reports
an unconfirmed save; success is reported only after a matching server receipt.
The latest 32 run outcomes remain in account-scoped RAM so a detached view does
not lose the failure status. A confirmed retry or an explicit decision to use
the last server save clears its error; an older task cannot overwrite a newer
result.
This task and its journal remain in RAM, so an OS kill or unavailable network
still leaves only the last successfully confirmed server checkpoint recoverable.

Bounds: 16 MiB per snapshot package; 12,000 base64 characters per chunk; at most
16 uploaded events per request, 8,192 base64 characters per event, and 160,000
characters per RPC envelope; at most 4,096 sparse/gap events per origin. The
larger RPC bound accommodates a valid batch of 16 existing world snapshots.
Exceeding a bound rejects the operation rather than dropping durable progress.

### Validation limits

The focused runtime fixtures cover offline friend listing, immutable creation
retries and concurrent allocation, per-account snapshot isolation, same-account
concurrent save/event conflicts, malformed operations and bounds, delayed and
reordered events, missed acknowledgements, expiry-independent retention,
confirmation/authorization, upload versus deletion races, and interrupted
cleanup. Broker fixtures cover signed scopes, friendship rechecks, account
revocation and expiry without allocating matches. They do not establish real
PostgreSQL/Nakama deployment, WAN recovery, physical-device behavior, frame-time
parity, video delivery or battle correctness. Those require the deployed runtime
and broker and the two-device acceptance matrix in the feature documentation.
