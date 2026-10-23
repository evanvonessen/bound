# Bound Nakama gameplay rooms

This server runtime replaces Agora's gameplay data path. It hosts a small room
for verified Bound accounts while each phone continues to emulate, accept input,
render and play audio locally. Agora remains available for ordinary friend video;
Dropbox saves remain separate. The default legacy mode keeps the existing Supabase account bridge; the new self-hosted mode makes Nakama the account authority.

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

Only `/ws` is exposed from Nakama. Keep account RPCs, native REST auth, gRPC and
the console private. The account runtime denies player-session calls to the
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
