# RRv4.1M server updates

Bound no longer embeds a multiplayer ROM in its app releases or imports one at
startup. The Xcode build removes stale generated multiplayer resources from its
own build product; archive/export verification rejects them. The homebrew demo,
user library, existing build caches and saves are outside that build step.

The existing Linode gateway serves private metadata and bytes only to
developer-approved account sessions. One transactional migration grants the
existing non-system account cohort once. Future accounts default denied.
Approval is separate from Developer Tools, Experimental Multiplayer and backup
approval. See [backend contract](../Backend/selfhost/ROM-UPDATES.md).

Approved users see the RRv4.1M status and Refresh below Enable Experimental
Multiplayer, above the Bound build footer. An available release shows Download
Latest RRv4.1M Multiplayer Version. Its destructive confirmation precedes the
download and explains removal of previous multi_red ROMs and their device saves.
Cancellation does nothing. Authentication and approval are rechecked, the
requested build/digest must remain current, redirects are refused, and the
complete downloaded file must match its exact supported SHA-256 and SHA-1.

Installation requires the library to be idle. It verifies the original FireRed
cover image before any deletion, then records an owner-bound immutable deletion
scope. It deletes only exact recognized multi_red identities, their local
battery saves/states/recovery/backups, and corresponding local sync records.
It never deletes Dropbox payloads, Linode backups, shared Nakama runs or a
partner's progress. The incoming identity is also reset when already present.
A durable deletion-complete phase prevents a retry from deleting the newly
installed replacement. Retired identities and stale callbacks remain fenced.
The installed library name is RRv4.1M; its multiplayer menu shows
`RRv4.1M Build #500` (or the installed independent build), centered in gray.

Legacy folder bookmarks/preferences are retained but cannot initiate new
unattended updates. Previously durable transactions retain their recovery path.
An old cartridge without a server installation receipt has an unknown build,
displayed as `RRv4.1M Build #—`; Bound's app build number is never substituted.

multi_red owns `distribution/build.json`, initially next build 500, and
`.github/workflows/publish-multiplayer-rom.yml`. It compiles maintained sources,
integrates the multiplayer cartridge, validates it, atomically publishes the
single private current `.gba`, reads it back, and records the successful build
through a repository-file compare-and-swap. A successful later publication
increments by exactly one. Counter retries and superseded queued events cannot
reuse a published number. App-only releases do not increment the game counter.
See the game repository's `docs/rom-distribution.md` for runner, compiler,
restricted SSH helper, pinned host-key, and counter-recovery requirements.

## Acceptance boundary

This is local implementation, not a live rollout. Active workspace instructions
prohibit pushing, backend deployment, production approval changes, ROM
publication, TestFlight jobs and shared-simulator refreshes. None are required
for the local tests and none have been performed.

Exact-ROM compatibility remains required: an unrecognized new native-address or
save-layout build requires a matching Bound game profile/runtime update. ABI
agreement alone never admits a cartridge or converts an old save. This version
does not implement downloading new native adapters. Unknown historical ROMs and
orphan files are retained rather than inferred from a filename and deleted.

Before live activation: provision the dedicated GitHub runner and restricted
Linode publisher; review and deploy the approval migration and read-only ROM
mount; run the main workflow; verify build 500 and exact downloaded hashes; test
approved, unapproved, anonymous and revoked sessions; test confirmation cancel,
device cleanup, same-hash reinstall, interrupted recovery, artwork, footer,
refresh/up-to-date status and next build 501 on a physical device. Preserve
ordinary games and cloud/shared progress throughout. Physical-device and WAN
acceptance are separate from simulator checks.

Final removal of historical bundling/public-download instructions is deferred
until the requested live acceptance passes. The new AGENTS distribution sections
already supersede those delivery commands so future agents cannot accidentally
invoke the retired path. Historical changelog entries remain historical records.
