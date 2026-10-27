# Friends multiview-only local validation — 2026-10-26

Build 12 source reference and lifecycle are documented in
[Friends multiview](../PARTNER-SPECTATING.md). No archived build binary was verified.

Candidate combined ROM SHA-256:
`395d8e6b67da9e6f287398cefc39dfc57c3b0b05c7e2b6b083f79a5a8c2b6316`.
The new layout is 10; prior exact profiles 5, 6 and 8 remain admitted separately.
Native VBA-M restore tests exercised each exact ROM, its own settings/state, and
cross-profile rejection with core `com.rileytestut.GBADeltaCore`, state version 10.

- 253 focused app integration tests passed, zero failures/skips. Includes all four
  independent connection combinations, media failure/recovery, hidden canvas
  lifecycle, ownership/invitations, update backups/recovery, and native input
  while a remote canvas is mounted.
- 23 game/SDK tests passed. Compiled UI checks execute all six action rows and
  wraparound. Native mGBA buttons select Timeline at the former Watch position;
  rendered menu was visually reviewed. No gameplay-memory writes were used.
- Fresh ordinary and Debug cold starts passed for both roles. Current-ROM native
  L-menu repel on/off and Easy defaults passed in the paired app. Callback stack
  retained 16 bytes (limit 32). Empty-cache build reproduced the exact ROM.
- Three UI cases passed: current portrait/landscape video, current show/hide plus
  rotation/foreground, and simulator-forced Mac sidebar resize/collapse. Screenshots
  were inspected. Native input reaches and releases the actual GBA bridge.
- Unsigned Release iPhone build passed; its bundled ROM matches the verified hash.
  Generated profile, SDK metadata and app/game contract checks passed.

Initial failures are retained in local artifacts: a real Experimental Multiplayer
video-disconnect bug was fixed; an outdated Debug Game Over expectation was
corrected; phone tests were updated from legacy PiP identifiers/visibility assumptions
to current multiview controls. Final relevant checks passed.

Evidence is under workspace `artifacts/multiplayer-isolation/friends-multiview-only`
(`validation.json`, logs, xcresults, screenshots and preservation audit). Original
checkout heads/status, including 4person work, match the pre-task snapshot.
Background publishers remain disabled/unloaded. No publication, backend deployment,
shared-simulator refresh, TestFlight or Cloud operation was performed.

No live Agora/Nakama WAN, two-phone, physical-controller or device-performance
claim. Mac UI evidence uses forced simulator layout. The prior native party-wipe
battle proof remains bound to the preserved `34d2320d…` profile, not the new ROM.
The full native battle/trade matrix was not rerun. Statepoints remain unfinished
and uncertified.
