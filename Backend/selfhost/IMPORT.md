# Import existing Bound accounts

`import-legacy.mjs` is a separate, one-time operator tool. It does not run during deployment. It never modifies or retires the existing backend, and does not configure backups.

Set `SOURCE_DATABASE_URL` to the existing PostgreSQL database and `DATABASE_URL` to a fresh Nakama database with the Bound schema already migrated. Supply credentials through protected environment variables, not command arguments or committed files. The source connection uses certificate-verified TLS except on loopback, a read-only repeatable-read transaction, and disables RLS filtering so insufficient access fails instead of producing a partial copy.

For a scoped reader using private export views, set `SOURCE_AUTH_SCHEMA` to their schema. This explicit mode requires `users`, `identities`, `mfa_factors`, and every passkey/WebAuthn table discovered in the original Auth catalog to have corresponding views. Missing views block import. It never treats inaccessible security credentials as absent.

From `Backend/selfhost/`:

```sh
node import-legacy.mjs --check
```

The default check reads counts and schema information and verifies any staged file manifest and bytes. Its report contains counts, table names and blockers, never account data or credentials. It makes no changes on either database.

After resolving every blocker and arranging the intended migration snapshot:

```sh
node import-legacy.mjs --apply
```

Apply preserves account UUIDs, compatible bcrypt passwords, email confirmation, profile names, friendships, blocks/moderation, device registrations, run/checkpoint records and Dropbox grant ciphertext. Original metadata is retained in private Nakama storage. Use the original `DROPBOX_APP_KEY` and `DROPBOX_ENCRYPTION_KEY`; apply verifies grant decryption in memory without exporting tokens. All destination changes commit together. Existing destination accounts or data cause refusal; the tool never merges or overwrites them.

When new Dropbox keys and reconnection have been explicitly authorized, add `--reset-dropbox-links` to both check and apply. This imports Dropbox rows with no grant ciphertext and fresh connection revisions, preserving their other fields. Users reconnect Dropbox on the new backend; existing source grants and provider tokens remain untouched. Without this flag, missing or incorrect original keys still block import.

Historical `cup041_private`, `cup041_v3_private`, catalogue, ROM, note and autosave rows use an explicit 19-table preservation list. The private archive retains original primary keys, column types and exact PostgreSQL text values, including bigint, bytea, arrays and SQL NULL versus JSON null. Account deletion removes that owner's archived rows.

Completed legacy deletion tombstones and their hashed capability receipts are retained in a separate private archive without an account foreign key. Their completed deletion fences are preserved; old capabilities are never installed as executable deletion jobs. Pending deletions, remaining accounts, mismatched receipts or existing destination deletion records block import.

For historical Storage objects, set `LEGACY_ARCHIVE_MANIFEST` to a protected absolute JSON path. Its version-1 envelope is `{version:1,projectRef,objects:[...]}`; each object uses the `validateArchiveEntry` shape in `archive.mjs`. Place verified bytes beside it at `objects/<id>`. Preserve each complete original `storage.objects` row as `sourceRowText` without JavaScript reserialization. The importer requires the complete source inventory and exact metadata/version match, checks SHA-256 and size, then copies and rechecks bytes under `FILE_DIRECTORY/archive/<id>` (default `/var/lib/bound/files/archive`). Ready manifests commit with the account import. These durable files have no transfer expiry and are removed on account deletion. A failed import removes only files it created; an ambiguous COMMIT response retains them for inspection.

`node stage-legacy-files.mjs` prepares that manifest using the same source database,
`SOURCE_PROJECT_REF`, and `SOURCE_STORAGE_KEY_FILE` pointing to a private existing
Storage key. It only reads source metadata and downloads files, checks source
ETags where available, and refuses a changed inventory. Use the database CA from
the Supabase dashboard with `NODE_EXTRA_CA_CERTS`; never disable TLS verification.
Remove temporary migration credentials, export views and staging copies after
the destination is verified. Do not revoke an existing provider key used by the
original backend.

MFA factors, passkeys, OAuth-only identities, unsupported password hashes, pending account operations, differing active-table layouts, populated unknown business tables and missing or mismatched Storage manifests block import. Do not remove security factors merely to pass the check. The tool deliberately does not copy old sessions or password-reset links. Users sign in again on the new backend.

A repeatable snapshot is not ongoing replication: later writes to the old backend will not appear in this copy. Keep the new deployment isolated until a coordinated cutover and validation are explicitly authorized. A rehearsal must use a fresh destination; do not rerun over an existing import. Retain the old backend until the user explicitly authorizes retirement.

Compatibility is checked against Nakama's pinned [v3.41.0 users/storage schema](https://github.com/heroiclabs/nakama/blob/v3.41.0/migrate/sql/20180103142001_initial_schema.sql) and [bcrypt authentication implementation](https://github.com/heroiclabs/nakama/blob/v3.41.0/server/core_authenticate.go). Supabase [also supports non-bcrypt imported hashes](https://github.com/supabase/auth/blob/master/internal/models/user.go); the importer rejects those instead of assuming compatibility.
