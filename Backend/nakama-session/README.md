# Nakama session broker

`nakama-session` exchanges a verified Bound account session and authorized friend
room for a short Nakama room lease. It preserves Supabase accounts, existing
friend/block/deletion rules and the separate save and video services.

The native request is `POST /functions/v1/nakama-session` with the existing
Supabase bearer and `{"roomID":"<lowercase UUID>","protocol":"bound-room-v1"}`.
The caller cannot supply an owner, member list, server host or Nakama identity.
Every request checks the live Auth identity, the account deletion gate and
`bound_nakama_room_v1`. The room RPC is checked again after Nakama issuance so a
racing block, logout or account deletion does not return credentials. Origin
headers are denied; an eventual website requires an explicit CORS origin policy.

The response contains `endpoint` (complete WSS URL with `format=json`),
`httpEndpoint`, `accessToken`, `expiresAt` (Unix seconds), `matchID`, `roomID`,
`ownerID`, `nakamaUserID`, `members`, `peerOwnerID` and `joinTicket`. It contains
no Nakama server key, bridge secret, refresh token or Supabase bearer. Clients
renew through the broker every 40 seconds and send the new `joinTicket` to the
existing match using opcode 5. Tickets expire after at most 90 seconds; server
membership expires even if the underlying Nakama access token lasts longer.

## Deployment

1. Review and deploy `contract.sql` to the existing Bound Supabase project,
   preserving other APIs. Its room RPC must return the authenticated owner and
   authorized members, with live Auth session, account and moderation checks.
2. Deploy the runtime in `../nakama/` to Heroic Cloud. Configure a strong custom
   Nakama server key and the same `BOUND_NAKAMA_BRIDGE_SECRET` on both services.
3. Configure these Edge Function secrets through the secure dashboard or secret
   manager: existing `CUPCAKE_SUPABASE_PUBLISHABLE_KEY`, `NAKAMA_HTTP_URL` (the
   public HTTPS root origin, without paths or query parameters),
   `NAKAMA_SERVER_KEY` (at least 16 printable characters, never `defaultkey`), and
   `BOUND_NAKAMA_BRIDGE_SECRET` (at least 32 random bytes, represented as a secret
   string). No service-role credential is required by this broker. Do not put
   secrets in source, build settings, command arguments or logs.
4. Deploy `index.ts` and `handler.mjs` as `nakama-session`. JWT validation is
   performed by the handler with Auth getUser and the live-session room RPC;
   use `verify_jwt=false` if required by the project's signing-key configuration,
   consistent with the existing authenticated Bound brokers. Never remove the
   handler's identity or room checks.
5. Check configuration, authenticate an owned QA account and join the same room
   from two clients. Confirm match reuse, renewal, revoked membership expiry,
   blocked-peer rejection, sign-out, deletion, reconnect and packet sequencing.
   Keep tokens and signed tickets out of logs and artifacts.

Missing/unsafe configuration returns `503 not_configured` to a syntactically
authenticated request. Upstream error bodies are discarded. Fetch redirects,
insecure endpoints, endpoint credentials, endpoint query strings and IP/local
hosts are rejected. Responses and request bodies are size/time bounded.

## Shared authentication contract

The ticket claims are `{version:1,protocol:"bound-room-v1",ownerID,roomID,members,
issuedAt,expiresAt}`. UUIDs are lowercase; members are sorted and unique, with
2–8 authorized owners. The ticket is the base64url-encoded UTF-8 JSON, followed
by `.` and lowercase hex HMAC-SHA256 of that encoded payload using the bridge
secret. The broker calls Nakama custom authentication with `id:"bound:"+ownerID`
and `vars:{bound_ticket:ticket}`, then calls `bound_room_v1` with `{ticket}`.
The room RPC response's `nakamaUserID` must match the access token's `uid`.

## Local validation

Run `node --test Backend/nakama-session/handler.test.mjs` from the repository root.
Tests cover ticket signing, identity/room binding, omitted secrets, membership
renewal and revalidation, live account gates, endpoint restrictions, expiration,
malformed responses and redacted network failures. These tests use synthetic
accounts and mocked upstream services; they do not establish Heroic Cloud
deployment, real-device latency, browser play or more-than-two-player gameplay.

`contract.test.mjs` exercises `contract.sql` in a disposable database on a local
PostgreSQL server using its Unix socket. It loads the existing checked-in MFA
functions, deletion guard and run-lease migrations, verifies API definitions stay
identical and tests real permissions, account/session gates and concurrent
block/revocation behavior. It requires `pg` (validated with 8.23.1) and PostgreSQL
(validated with 17.6). Set `PG_MODULE` if `pg` is outside normal module resolution,
`BOUND_NAKAMA_TEST_SOCKET` to a disposable server socket under `/private/tmp/`,
and `BOUND_NAKAMA_TEST_PORT` if its port differs from 54923. Then run
`node --test Backend/nakama-session/contract.test.mjs`. The test provisions local
fixture roles and creates and drops a randomly named fixture database. It does
not contact Supabase or Heroic.
