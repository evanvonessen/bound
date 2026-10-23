# Import existing Bound accounts

`import-legacy.mjs` is a separate, one-time operator tool. It does not run during deployment. It never modifies or retires the existing backend, and does not configure backups.

Set `SOURCE_DATABASE_URL` to the existing PostgreSQL database and `DATABASE_URL` to a fresh Nakama database with the Bound schema already migrated. Supply credentials through protected environment variables, not command arguments or committed files. The source connection uses certificate-verified TLS except on loopback, a read-only repeatable-read transaction, and disables RLS filtering so insufficient access fails instead of producing a partial copy.

From `Backend/selfhost/`:

```sh
node import-legacy.mjs --check
```

The default check reads counts and schema information only. Its report contains counts, table names and blockers, never account data or credentials. It makes no changes on either database.

After resolving every blocker and arranging the intended migration snapshot:

```sh
node import-legacy.mjs --apply
```

Apply preserves account UUIDs, compatible bcrypt passwords, email confirmation, profile names, friendships, blocks/moderation, device registrations, run/checkpoint records and Dropbox grant ciphertext. Original metadata is retained in private Nakama storage. Use the original `DROPBOX_APP_KEY` and `DROPBOX_ENCRYPTION_KEY`; apply verifies grant decryption in memory without exporting tokens. All destination changes commit together. Existing destination accounts or data cause refusal; the tool never merges or overwrites them.

When new Dropbox keys and reconnection have been explicitly authorized, add `--reset-dropbox-links` to both check and apply. This imports Dropbox rows with no grant ciphertext and fresh connection revisions, preserving their other fields. Users reconnect Dropbox on the new backend; existing source grants and provider tokens remain untouched. Without this flag, missing or incorrect original keys still block import.

MFA factors, passkeys, OAuth-only identities, unsupported password hashes, pending account operations, differing table layouts, populated unmapped business tables and Supabase Storage files block import. Complete a reviewed transfer for those items first; do not remove security factors merely to pass the check. The tool deliberately does not copy old sessions or password-reset links. Users sign in again on the new backend.

A repeatable snapshot is not ongoing replication: later writes to the old backend will not appear in this copy. Keep the new deployment isolated until a coordinated cutover and validation are explicitly authorized. A rehearsal must use a fresh destination; do not rerun over an existing import. Retain the old backend until the user explicitly authorizes retirement.

Compatibility is checked against Nakama's pinned [v3.41.0 users/storage schema](https://github.com/heroiclabs/nakama/blob/v3.41.0/migrate/sql/20180103142001_initial_schema.sql) and [bcrypt authentication implementation](https://github.com/heroiclabs/nakama/blob/v3.41.0/server/core_authenticate.go). Supabase [also supports non-bcrypt imported hashes](https://github.com/supabase/auth/blob/master/internal/models/user.go); the importer rejects those instead of assuming compatibility.
