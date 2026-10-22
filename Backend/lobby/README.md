# Four-player lobby (4person branch)

This additive backend is implemented and locally verified. **It has not been deployed.** It does not change paired run leases, checkpoint history, friend rooms, account saves, or the existing two-person token contract. The lobby shares presence and interactions; each solo run or Soul Link pair retains its own save and progression authority.

The public authenticated RPC is `bound_lobby_v1(action, payload)`. It uses the caller's JWT, a live Auth session, confirmed nonanonymous account, and the existing account-deletion and moderation gates. Callers never supply an account owner ID. Client roles cannot read or mutate its private RLS-enabled tables. A public invoker wrapper calls one narrowly granted private dispatcher; all privileged functions pin an empty search path and all other helpers are denied to client roles.

## Contract

UUIDs are canonical UUID strings. All actions require an object payload and reject unknown keys. `runID` can be null before a cartridge run is created; `partnerRoomID` is null for `solo` and an active existing friend room UUID for `soulLink`. The backend resolves the partner account itself.

| Action | Payload |
| --- | --- |
| `create` | `requestID`, `runID`, `mode` (`solo` or `soulLink`), `partnerRoomID`, `roomIDs` (at most three existing friend room UUIDs) |
| `list` | `{}` |
| `get`, `decline` | `lobbyID` |
| `accept`, `rejoin` | `lobbyID`, `runID`, `mode`, `partnerRoomID` |
| `configure` | `lobbyID`, `memberToken`, `runID`, `mode`, `partnerRoomID` |
| `invite` | `lobbyID`, `memberToken`, `roomID` |
| `ready` | `lobbyID`, `memberToken`, `ready` (boolean) |
| `start`, `leave`, `heartbeat`, `room` | `lobbyID`, `memberToken` |

Successful mutations/get return `{ok:true,lobby,memberToken,serverTime,expiresAt}`. The lobby contains `lobbyID`, nullable `creatorID`, `state` (`waiting`/`started`), positive decimal-string `revision`, and up to four members. A member contains `ownerID`, `displayName`, `uid` (1–4), `state` (`invited`/`joined`/`left`/`declined`), `ready`, `mode`, nullable `runID`, nullable `partnerOwnerID`, `online`, positive decimal-string `generation`, and public UUID `sessionID`. The public session ID is independent of both the Auth session and the secret member token.

`list` returns `{ok:true,lobbies:[...]}` with at most 32 newest accessible lobbies, omitting declined invitations. `get`, `leave`, and `decline` return a null token. Other successful joined-member operations return the current token. Keep an existing token across `get`; clear it on departure or `fenced`/`membership_expired` errors. Never put it in shared save packages, packet bodies, logs, or public roster data.

Invitations need explicit acceptance; a declined invitation cannot be silently renewed. Slots are reserved for at most four distinct accounts for the life of a lobby, including pending invitations and departed/declined accounts. This keeps UIDs stable and prevents a new account receiving packets intended for an earlier occupant. Create a new lobby to replace a declined slot with someone else. Departed players can rejoin their original slots. Invites remain available after the group starts, and pending invitees do not block Start.

Only the current creator starts a waiting lobby, with at least two joined members all online and ready. On creator departure, launch coordination moves to the next joined member; ongoing gameplay does not depend on a creator. Presence lasts 90 seconds and is renewed by heartbeat or joined-member mutations. Expiry is pruned to departure during a subsequent lobby operation, with a revision increment. A returning player explicitly rejoins; this rotates both the secret token and public membership session while preserving UID and assigned run metadata. The first successful nonnull `runID` assignment permanently fixes that member's run ID, mode and partner within the lobby. Metadata does not itself authorize or modify any run/checkpoint.

`create` is idempotent by caller and `requestID`; use a new request ID for a new lobby. `accept`/`rejoin` retry with a still-live membership on the same Auth session returns the original token. A separate Auth session cannot steal live membership. The member token is bound to the joining Auth session. Expiry or departure requires rejoining, and old heartbeat/leave/configure requests are fenced by the rotated token. Per-lobby row locks serialize invitation capacity and state transitions; an owner advisory lock serializes creation/idempotency and the 64-created-lobby account cap.

## Agora token extension

The existing `agora-token` endpoint accepts an additional request shape `{lobbyID,memberToken}`. It verifies Supabase Auth and account activity, then calls `bound_lobby_v1('room', payload)` using the same caller JWT; it never uses a service credential. The server returns only joined, unexpired, socially authorized members. The issuer verifies unique UIDs, owners and public sessions and binds the local UID to the verified caller before signing a token lasting at most 60 seconds. Tokens cannot outlive the remaining membership authority; the complete RPC duration and a one-second margin are subtracted conservatively. A remaining grant of 30 seconds or less requires heartbeat/rejoin before token issuance.

The response retains `roomID` (equal to `lobbyID`), `ownerID`, `appID`, `channel`, `uid`, `remoteUID`, `token`, `issuedAt`, `expiresAt`; it adds `lobbyID`, `membershipRevision` and `members:[{ownerID,uid,sessionID,generation}]`. The channel is `bound_lobby_` followed by the lobby UUID without hyphens. `remoteUID` identifies the configured partner when present, otherwise the first other member, otherwise zero. Clients must derive targeted Soul Link traffic from the authenticated partner mapping, never infer that every lobby member is a partner. Apply every returned roster; natural expiry may change visibility even when a previously cached response carried the same revision.

The legacy `{roomID}` request follows the unchanged pair-only authorization and response shape. A staged deployment can apply the additive migration first and deploy the reviewed token handler second. Older released clients cannot opt into the new request shape. Keep the branch client gated until both pieces are verified in the target project. Rollback means deploying the previous token handler and leaving the new RPC/tables unused; never drop private lobby rows to undo a client rollout. No production deployment is included in local validation.

## Local verification

Use a disposable local PostgreSQL Unix socket under `/private/tmp`; the test refuses a TCP hostname and creates/drops only its randomly named fixture database. The fixture uses synthetic users and friendship rows and never contacts hosted Supabase.

```sh
PG_MODULE=/path/to/pg/esm/index.mjs \
BOUND_LOBBY_TEST_SOCKET=/private/tmp/bound-four-lobby/socket \
BOUND_LOBBY_TEST_PORT=54885 node --test Backend/lobby/lobby.test.mjs
node --test Backend/moderation/agora-handler.test.mjs
```

The SQL test covers explicit invitation/ready/start/decline, four-slot concurrent capacity using independent connections, separate run IDs, partner resolution, immutable assigned metadata, creator departure, expiry/rejoin, old-token rejection, account/session revocation, blocks/removed friendships, failed-create atomicity, and private privileges. Twenty-one token-handler cases retain the four existing pair cases and cover lobby ownership, routing, revocation and malformed or contradictory membership mappings. These establish local contracts, not hosted Auth, live Agora, or physical-device multiplayer.

The migration filename was generated with the installed Supabase CLI. Implementation checked the current Supabase [database function security](https://supabase.com/docs/guides/database/functions) and [Data API grants](https://supabase.com/docs/guides/api/securing-your-api) guidance. Live advisors and a rolled-back hosted contract smoke remain deployment checks.
