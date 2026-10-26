# Synthetic persistence compatibility fixtures

These frozen JSON records were produced through the compiled Nakama handlers at
Bound commit `00bb9324a28d473867d4d5be2c891bf7cefa298a`, using the existing local
in-memory storage adapter. `provenance.json` records identities and file digests.
The fixtures contain no player data, ROM bytes, playable battery saves, or raw
emulator states. The blobs are deliberately labeled synthetic marker text.

`storage-v2.json` preserves two independently owned checkpoint heads, exact
serialized payload bytes, an acquisition committed with its checkpoint, and a
permanent death at sequence 3 while sequence 2 is missing. The peer checkpoint
has received sequence 3 but has not applied it. Distinct device-owner fields and
opaque battle/trade recovery blobs survive storage/retrieval unchanged.

`storage-v1-partial.json` preserves a legacy paired run with one durable upload
and a missing partner upload. Its test completes the original transaction
without replacing the run or converting its stored version.

Tests exercise the compiled production handlers in fresh VM instances with a
disposable in-memory Nakama storage adapter. They do not connect to a service or
validate PostgreSQL transaction behavior, native restoration, device-transfer
authorization, battle/trade resumption, or physical devices. The backend treats
native recovery and `deviceOwner` as opaque package fields; their semantics are
enforced by the host, not established by byte-preservation tests here.

Host regression coverage remains in `MultiplayerSavePackageTests`,
`ServerDisconnectSaveTests`, `SoulLinkTests`, and the ordinary-feature model
tests. Run those independently; do not count this fixture suite as their pass.
In particular, legacy local-file preservation, native applied acknowledgements,
device leases, core/state-layout rejection, and actual interrupted activities
need their real host paths.

Run from the isolated `Backend/nakama` checkout after its audited TypeScript
build:

```sh
node --test test/multiplayer-isolation-regression.test.mjs
```

Regenerate only when deliberately reviewing a new compatibility baseline:

```sh
node test/fixtures/multiplayer-isolation/generate.mjs --write-reviewed-baseline
```

The tests never regenerate their own expected fixtures. Review every JSON and
digest change. Provider CAS version tokens are regenerated on import, and
managed-run wall-clock timestamps are normalized; immutable payload bytes,
server keys, run IDs, checkpoints, event origins, and sequences are retained.
