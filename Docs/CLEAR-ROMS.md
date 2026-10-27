# Clear ROMs

Main Settings → **Clear ROMs** prepares one itemized confirmation. It is a manual
action and never runs as automatic cartridge cleanup. The app first verifies its
bundled ROM and installed current library entry against the current exact hash.
It preserves that cartridge, its entry, saves/states and working memory.

Recognition uses SHA-256 and the corresponding verified SHA-1 library identity
from `PrototypeConfiguration/recognized-multi-red-roms.json`. Seventeen distinct
published ROMs were downloaded and checked against GitHub release asset digests;
three newer validated local profiles complete the 20-identity catalogue. Library
names never establish recognition. Manually imported matching bytes qualify;
unidentified or mismatching files remain untouched.

Preparation requires a signed-in account and fresh authorized cloud inventory.
Unavailable services fail preparation without deleting anything. A signed-out
cloud inventory is never displayed as zero records. Close all games, including
paused games and previews, and finish pending saves first. Existing ROM-update
recovery and save-clear operations must finish before their files are eligible.

The confirmation lists each selected identity, exact local paths/hashes/bytes,
Dropbox file names/IDs, Nakama run IDs and account-owned server-backup namespaces.
A warning above the list says shared run deletion removes the partner's progress
as well as the current user's. Nothing is deleted before confirmation.

After confirmation, an atomic fsynced metadata journal freezes the account,
protected identity, game IDs, local file hashes, Dropbox IDs/revisions and Nakama
run IDs/revisions. Local bytes and database entries are deleted directly; no ROM
or save archive is created. Existing recognized save-clear copies and known
recovery/finished-run files are included only through explicit per-game source
maps or manifests. Unknown archives remain untouched. Per-game working-memory
copies and cached managed-run heads are discarded without enabling local saves
for marked cartridges. The existing preview-invalidation notification is reused.

Cloud deletion uses existing authenticated APIs. Server backups are limited to
the signed-in owner's selected game namespaces. Nakama deletion uses the frozen
run ID, expected revision and explicit shared-deletion flag. A tombstone prevents
recreation and permits an interrupted server purge to finish. A revision change
stays pending; the app never silently refreshes the confirmed revision or adopts
newly discovered runs.

Dropbox retries use only the frozen file IDs. Metadata must still match the
recorded revision, or a deleted record must have its original path. The app calls
`files/permanently_delete`; it never substitutes `delete_v2` or claims that trash
is permanent erasure. **Dropbox documents this API as Business-app-only and
requires `files.permanent_delete`; Bound's current OAuth request does not include
that scope.** Such purges are expected to fail with current credentials and remain
incomplete. No credentials, scopes or provider preferences are silently changed.
See the [Dropbox permanent-delete API](https://docs.dropboxapi.com/dropbox-api/api-reference/user-endpoints/files/permanently-delete).

Pending receipts fence gameplay, previews, save imports, cloud downloads,
restores and uploads for the selected old identities. Sync work drains through
the existing ROM-update barrier. The older Clear Saves action refuses to start a
second cleanup for those identities. Late callbacks retain per-game completion
revisions even after a later cleanup job starts. Other games, including the
current cartridge, continue to use their existing save and sync behavior.

A partial failure leaves the original scope and completed stages durable. Press
Clear ROMs again to retry that scope; it does not re-enumerate targets or display a
new confirmation for already authorized work. Sign back into the original
account before retrying. New versions/files/runs discovered later are not added.
The UI reports incomplete cleanup rather than claiming cloud success. Permission
failures, changed revisions and uncertain permanent-purge responses can continue
to require service-side resolution; the app does not relax the original scope.
