# Final paired validation — October 26, 2026

This records the final review of Settings, Debug New Game, independent Screen
Share/Multiplayer, Friends multiview, nearby native Battle/Trade, History,
download patches and Clear ROMs. Earlier step reports retain their historical
ROM identities and local-only status; this report describes the final pair.

The exact bundled cartridge is SHA-256
`fcfaa8a9fb022656994a429be4cba5b9f14ba6c477ec813d2d6a2aa3878edc00`,
SHA-1 `51ebbe0108c0c18bb5bfcbef42ed3d19a4cfd606`, combined layout 12,
ABI 1/wire 2/settings 5, core `com.rileytestut.GBADeltaCore` state version 10.
Historical exact profiles remain separate. No raw state is converted across
ROMs, and no ordinary save or customization migration is inferred from ABI alone.

## Behavior and evidence

Artifacts use explicit paths under workspace
`artifacts/multiplayer-isolation/final-publication`, the existing isolation
worktrees, approved QA Python, and the dedicated Bound Multiplayer Isolation A/B
simulators. No shared simulator is refreshed.

- The Developer Tools model check covers all nine combinations of absent/false/
  true legacy preferences, unrelated keys, relaunch and subsequent opt-out.
  GitHub/ROM Updates controls remain removed; credentials, automatic bundled
  installation, backup and interrupted-update recovery remain intact.
- Hosted checks cover the four independent video/gameplay combinations,
  independent failure and reconnect, invitations/ownership/recovery, playable
  local input, hidden Friends canvases and media stop. Connections and Run Timeline
  visibility, fallback, controller navigation, saved choices and retained journals
  are tested independently of app Developer Tools versus game Debug Mode.
  Final broad selection: 551 tests, zero failures/skips. The final profile-only
  rerun also passes all seven tests after the capture buffer-lifetime guard.
- Three focused Settings/Friends UI cases pass. The build-12 reference is source
  history only; no exact archived build-12 binary was verified.
- Fresh ordinary and Debug cold boots pass for both roles. Native L-menu tests
  enable and disable Infinite Repel; unlocking leaves it off. New Debug starts
  use Easy and Game Over; old saved Normal/opt-out values remain authoritative.
- A new button-only Route 1 encounter on this exact ROM produces native healthy,
  fainted and blackout-healed party bytes, outcome 2, with zero gameplay RAM
  writes. Bound's real ledger/save policy records the loss durably, keeps Game
  Over after native blackout healing, excludes friendly battles and honors saved
  opt-outs. Historical natural-loss evidence remains bound to its original ROM.
- Twenty-seven native nearby/button scenarios and 471 compiled game-UI checks
  pass: original Select/L/R/Start, nearby Battle/Trade/Back, incoming accept/
  decline, B cancellation and no remote menu entry. Customized app mappings remain
  authoritative; the native R Debug warp stays removed.
- Actual native battle and trade pass on both isolated VBA-M cores using this
  exact ROM, including cold-core owner/queue restoration and a one-second cable
  interruption. Battle action/move/back response takes 7–9 local frames at 2×;
  parties and Soul history restore unchanged. Trade runs at 1×, exchanges native
  parties, and verifies both server-state and battery persistence. These are
  controlled loopback fixtures, separate from nearby interaction admission tests.
  Pre-offer cancellation preserves the complete original party and reopens its
  state on a fresh core. Two repeated final battle/reconnect runs pass after the
  storage-sanity fix.
- Eighteen game/UPS/package unit tests, seven SDK tests, nine app ROM bundler
  tests, 31 isolated compiled backend save tests, generated profile/catalogue
  checks and source/privacy integrity checks pass. Callback retained stack is
  16 bytes against a 32-byte limit. No backend is deployed.

## Native restoration failure and fix

The added current-ROM two-core battle exposed a rejected in-battle checkpoint:
the native heap reset clears both field snapshot pages. A standard gzip FEXTRA
field now records the exact admitted ROM identity, layout and compressed-state
SHA-256. The pinned core already supports skipping this field. Decompressed v10
state bytes, the core implementation, ROM, battery and save-package formats are
unchanged. An empty page requires that matching capture identity; wrong ROM,
layout, damaged compressed bytes and an unidentified empty state fail before
core mutation. Historical untagged field states retain their original complete
ruleset/layout admission. Existing saves are neither rewritten nor deleted.

The initial trade rerun caught a test assumption, not a second production defect:
trade preparation still has a complete field snapshot and must retain legacy
untagged admission. That assertion now applies only to the in-battle reset case.
Failed logs and checkpoints remain in isolated artifacts.

An additional pre-offer trade cancellation exposed the legacy battery-only
restart path. Native observation now permits the existing pre-trade checkpoint
restore only at initialization or the root party chooser, before any exchange
has started/completed. Later offer/exchange stages keep the existing conservative
recovery path; their parties are never rolled back by this exception. No protocol
fields or backend behavior change.

A repeated battle caught an intermittent temporary storage record entering the
Soul ledger. The decoder now requires native `hasSpecies` with `isBadEgg` clear,
instead of accepting both sanity bits together. This leaves cartridge bytes and
legitimate unhatched Eggs intact. Regression checks cover compressed box and
party structures, including the observed alternating `FF 03` pattern. The
[upstream sanity flags](https://github.com/pret/pokefirered/blob/master/include/pokemon.h)
identify these separate bits; the paired runtime tests validate the resulting
behavior with the supported ROM. A mistakenly selected broad QA invocation was
interrupted and is not counted as passing; the final focused selection is rerun.

## Release and limits

The app pin, contract and deterministic patch package identify the same ROM.
The final unsigned Release iPhone build passes; its resource is checked against
the exact ROM hash. Publication also verifies a build with an initially absent
ROM cache fetching the immutable release asset through authenticated GitHub.
Release `multiplayer-fcfaa8a9fb02` contains three ordered UPS stages, the alternative
combined UPS, both identical ROM aliases and hash/contract/source metadata.
Every patch is checked forward and backward; changed patches are generated twice;
both full routes reproduce the exact tested ROM. Base FireRed USA v1.0/revision 0
remains unavailable as a download because no verified base asset exists. The
combined UPS is distinct from the fully patched ROM. Prior releases and both
permanent ROM links are preserved.

Physical devices/controllers, phone performance parity, live Agora/Nakama WAN,
real network recovery and destructive cloud cleanup are untested. Native exchange
fixtures use fresh isolated games and a host loopback relay, not live accounts.
Dropbox permanent purge lacks the provider scope/capability required by the
current credentials; those deletions remain pending and are reported incomplete.
No cloud data or credentials were changed to bypass that restriction.

All unfinished progression/statepoints, backend implementation, fixtures and
dedicated tests remain preserved and uncertified. Reconstruction and complete
native encounter/campaign certification are not claimed. Existing original
checkouts and unrelated 4person work are preserved; automatic publishers remain
disabled and unloaded. Manual Fastlane delivery is a separately launched job;
a successful local build does not establish upload or processing success.
