# Approved game-save backups

The Bound gateway stores approved users' save archives in the persistent `files`
Docker volume under `backups/<Nakama owner UUID>/<server-generated version UUID>`.
Nakama remains the account authority. These are durable save backups; temporary
multiplayer transfers and imported historical files use their existing stores.
The client includes saves and save states, never ROMs. The server treats ZIPs as
opaque bytes, verifies their ZIP signature and SHA-256, and never extracts them.
It does not inspect or enforce the individual files inside an archive.

This is not an off-server copy: loss of the Linode or its volume can lose these
backups. No paid backup service or external provider is configured by this feature.

## Approving friends and staff

Run the following from the active backend release directory on the server. No
approval endpoint is public, and ordinary users cannot edit approval records.
Use the account's verified email, not a user-editable display name or username.

```sh
docker compose exec -T gateway node backup-access.mjs approve friend@example.com
```

An account that has not yet been created or verified requires an explicit
pending grant. The grant binds to its Nakama UUID only after that email is
verified:

```sh
docker compose exec -T gateway node backup-access.mjs approve friend@example.com --pending
```

Revoke access with:

```sh
docker compose exec -T gateway node backup-access.mjs revoke friend@example.com
```

Revocation takes effect in the database before waiting for active owner
operations to drain. In-flight uploads recheck approval before publishing;
downloads finish or time out before this command returns. If Server Backups was
selected, revocation switches the authoritative provider to `none`. Existing
backup files remain private and can be deleted by their owner even after
revocation. Account deletion drains operations and removes all stored versions
and filesystem receipts before reporting complete. An account's bound approval
is removed when that account is deleted, including an unclaimed grant for its
verified email; re-created accounts need new approval. Pending grants for people
who have no account remain intact.
Never commit specific users' email grants to source control.

## Provider exclusivity

Each account has one server-authoritative provider: `none`, `dropbox`, or
`server`. Provider changes use an opaque revision for compare-and-swap and share
an owner lock with uploads, downloads, and Dropbox token issuance. A stale
second device receives `409 provider_conflict` and must refresh status.

An account with no explicit preference defaults to `dropbox` for existing-client
compatibility; this does not turn on a device's local Cloud Backups switch.
Server requires approval. The Dropbox token/link broker denies token issuance
when the selected provider is `none` or `server`; unlink is always available.
Existing upstream Dropbox access tokens may remain valid until they expire, so
updated clients must stop all old-provider work and discard cached tokens when
changing providers. The provider preference cannot control unsupported old
clients already holding a Dropbox token.

Switching providers preserves each provider's prior files. Server DELETE is
allowed for the active authenticated owner with any provider or approval state,
so Clear Saves can remove historical server versions after a switch.

## HTTP contract

All routes require a current, verified, active Nakama account and session.
Browser-origin requests are rejected. All replies use `Cache-Control: no-store`.
Game IDs contain 1–128 ASCII letters, digits, underscores, or hyphens.

| Method and route | Contract |
| --- | --- |
| `GET /backups/v1/status` | `{approved, provider, revision}`. Revision is opaque text; preserve it unchanged. |
| `PUT /backups/v1/provider` | JSON `{provider, expectedRevision}`; returns updated status. Stale revision is 409. |
| `GET /backups/v1/saves` | `{saves:[{gameID,name,version,sha256,size,modifiedAt}]}`; newest version per game. Requires approved server mode. |
| `PUT /backups/v1/saves/:gameID` | Raw `application/zip`. Requires `X-Content-SHA256` (lowercase hex), `If-Match` (current version or `*` only if absent), optional percent-encoded `X-Backup-Name`. Returns metadata. Requires approved server mode. |
| `GET /backups/v1/saves/:gameID` | Newest ZIP with `X-Backup-Version` and `X-Content-SHA256`. Requires approved server mode. |
| `DELETE /backups/v1/saves/:gameID` | Removes every version owned by this account for this game; returns `{ok:true}`. |

`Content-Length` is verified when supplied. Chunked uploads reserve the maximum
package size before receiving bytes. Failed uploads remove partial files and
reservations. Completed bytes and their directory entry are synchronized to disk
before metadata is published. Account/session/approval are rechecked after the
upload and before publication. A stale version produces `409 backup_conflict`;
clients must resolve it explicitly rather than overwrite with a fresh token.

Default limits are 64 MiB per archive, 256 MiB per owner, 2 GiB total, three
versions per game, and four active backup/provider operations per gateway.
Reservations count against quotas, including while uploads are incomplete.
There must be quota headroom for the replacement archive before old versions
are pruned. Transfers time out after 120 seconds; the front-end HTTP server may
apply its shorter request limit. Exhausted quotas return 413 and service
concurrency returns 429. Limits can be lowered or raised explicitly through
`BACKUP_MAX_BYTES`, `BACKUP_OWNER_BYTES`, `BACKUP_TOTAL_BYTES`, and
`BACKUP_VERSIONS`; storage defaults to `FILE_DIRECTORY/backups` and can be
relocated with `BACKUP_DIRECTORY` only to another persistent private mount.

Cleanup also erases orphan receipts and files after native Nakama console/account
deletion, using the same owner lock and I/O drain. It removes abandoned upload
reservations older than ten minutes. Completed saves never expire due to age. The
file-store volume must be writable only by the gateway/operator and preserved
across deployments.

## Validation

`node --test test/*.test.mjs` covers provider CAS, verified pending grants,
private owner isolation, version conflicts/retention, checksums, ZIP signatures,
quotas, revocation during upload, provider changes during download, Dropbox
broker gating, and account-deletion cleanup. The opt-in PostgreSQL integration
fixture additionally applies the actual migration and exercises the service in
a newly created disposable database:

```sh
BOUND_BACKUP_TEST_DATABASE_URL=postgresql://... node --test test/backups.database.test.mjs
```

Keep that connection URL in the process environment; do not put credentials in
committed files or command logs. The fixture creates/drops only a randomly named
`bound_backup_test_*` database and a temporary directory. It assumes the cluster
already has the normal `anon`, `authenticated`, and `service_role` roles.
