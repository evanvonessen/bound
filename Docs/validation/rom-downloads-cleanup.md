# ROM downloads and Clear ROMs — local validation, October 26, 2026

Publication and the final paired checks are recorded in
[final publication validation](final-publication.md). The local-only release
status below describes this earlier preparation step.

This step prepares README controls and release assets locally, and adds the
manual Clear ROMs flow described in [Clear ROMs](../CLEAR-ROMS.md). The prior
multiview, settings, native interactions, saves and unfinished statepoint work
remain intact. No backend deployment is included.

## Release evidence and exact pair

The read-only GitHub inventory contained 82 releases including drafts, 17 distinct
published integrated-ROM hashes, and one published set of three UPS stages.
Every one of those 17 ROMs was downloaded and checked against its release asset's
SHA-256; SHA-1 identities were then derived from those verified bytes. Drafts
were excluded from recognition. Frozen local profiles add three newer identities.
No base download asset or other individually identified additional RR patch was
found. The base button is therefore unavailable. The one additional patch is
the verified supplied damage-calculator variant; its original author is unknown.

The README's three active patch buttons point to existing immutable release
assets. The base and newly generated combined patch remain unlinked with explicit
status. Both permanent fully-patched-ROM URLs remain unchanged. The new combined
patch is an alternative to the complete three-stage chain, never a `.gba` ROM.
The paired multi_red repository's `docs/multiplayer-release.md` contains exact
stage input/output and asset hashes.

| Item | SHA-256 |
| --- | --- |
| FireRed (USA) v1.0 / revision 0, 16 MiB | `3d0c79f1627022e18765766f6cb5ea067f6b5bf7dca115552189ad65a5c3a8ac` |
| Official RR 4.1, 32 MiB | `679d112cdfe699c2793d82c7e7999ac9dfca9e222ad5a85d4f8f1e457cd0283f` |
| Approved variant, 32 MiB | `689299664a954c12dad66e03c2d18446b348cb31bd98b395c87b9b514b288066` |
| Current tested combined ROM | `fcfaa8a9fb022656994a429be4cba5b9f14ba6c477ec813d2d6a2aa3878edc00` |
| Multiplayer UPS | `ebbd93ad54e16eece9c2fa3e057fb3be593e52487572df56ad2567c334918a3b` |
| Alternative combined UPS | `ac322d5cb1ee1533e53ea16312adb10fcb9dd076d3012f79af5136637b8b71b3` |

The app already admitted the newest validated ROM above; this step aligns the
package generator and intended bundled-release tag to it. No cartridge behavior,
ABI, contract or save layout changed. Current library SHA-1 is
`51ebbe0108c0c18bb5bfcbef42ed3d19a4cfd606`, combined layout 12, ABI 1/wire 2,
settings 5 and Delta GBA core state 10. All historical exact profiles remain.
Matching version numbers alone are not treated as save compatibility.

## Acceptance

Artifacts live in workspace `artifacts/multiplayer-isolation/rom-downloads-cleanup`.

- `host-08.xcresult`: 132 hosted tests passed, no failures/skips. The real library
  test recognizes a manually imported exact historical cartridge, deletes its
  ROM/save/state/thumbnail and metadata, and verifies the current bundle/entry/
  saves/states, current RAM copies and an unrelated misleadingly named game survive.
- Cleanup fixtures cover no mutation before confirmation, cancellation, active
  games, account changes, symlinks, changed files, interrupted cloud work,
  relaunch/retry, fixed scopes, download fences, retained completion revisions,
  and rejection of a competing Clear Saves operation. Rendered Settings and the
  single confirmation were inspected; the partner-loss warning appears first.
- Dropbox fixtures prove permanent-delete-only routing, frozen file IDs,
  changed-revision refusal and truthful permission-failure handling. No live
  personal Dropbox data was deleted.
- `backend-tests/saves.log`: 31 save-service tests passed against freshly compiled
  current backend sources in an isolated artifact directory. These include shared
  deletion consent, participant authorization, fresh revision checks, in-flight
  upload races, tombstones and interrupted purge retry. No backend was deployed.
- `bundler-tests.log`: nine packaging/cache tests passed. The Debug app build
  started with the explicit empty `empty-rom-cache` directory and populated it
  from the exact locally reviewed cartridge. `empty-cache-install.json` also
  verifies resource installation into the actual Release app from a second absent
  cache directory. Both cache and built-app ROM hashes are verified. Runtime bundled installation is exercised by the hosted tests.
- `package-tests-final.log`: five package unit tests passed. The real package
  checks every stage forward/backward, generates changed patches twice, and
  verifies that both the separate chain and combined UPS reproduce the exact
  tested ROM. Previous packages/releases are preserved; outputs use new folders.
- Final unsigned Release iPhone build and app-bundle hash verification are recorded
  in `release-02.xcresult` and `validation.json`.
- Generated catalogue/profile/contract/SDK checks passed. Original checkouts and
  4person work match the prior audit; publishers remain disabled and unloaded.
  Fifty-eight statepoint/backend source, fixture and dedicated test files were
  compared byte-for-byte with HEAD.

There were no unexpected test assertion failures in this step. A duplicate Core
Data model warning introduced by a fixture was corrected to reuse the app model;
all earlier logs are retained. Permission failure and revision-change tests are
expected negative cases, not claims of successful live cloud deletion.

## Limits and publication status

Live authenticated Nakama deletion, physical devices/controllers, adverse WAN,
and Dropbox Business permanent deletion were not exercised. Bound's current
Dropbox OAuth scopes cannot support the required permanent purge; a live attempt
must remain pending rather than claim completion. Changed Nakama revisions and
uncertain Dropbox purge responses similarly remain in the original retry scope.
Initial offline/signed-out cloud inventory fails before confirmation or deletion.
Statepoints remain unfinished and uncertified.

GitHub main was verified before starting: Bound
`a0d72ae24b0680cde1fbfb52fcc74c78ceb929b5`, multi_red
`15765782bc7e4ac96cca48aeb4426d43a39a9183`. Local paired commits and final package
revisions are recorded in `validation.json`. No push, release publication,
TestFlight job, Xcode Cloud action, backend deploy or shared-simulator refresh
is part of this local preparation.
