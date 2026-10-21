# Multiplayer gameplay continuation handoff

**Main integration:** the multiplayer branch is now opt-in through
**Settings → Enable Experimental Features**, directly below Enable Developer
Features. The new switch defaults to off; enable it on both devices before the
flows below. Prior branch acceptance evidence remains historical evidence;
see `BOUND-EXPERIMENTAL-FEATURES.md` for current gate behavior and validation.

**Full-app simulator gameplay acceptance passed October 20, 2026.**
The earlier compiled checkpoint was `8612f98f854d707b125153bc066b549bf13ab8fa`;
this continuation verifies its gameplay paths and fixes native UI-test selectors.
See [the acceptance evidence](BOUND-MULTIPLAYER-GAMEPLAY-QA.md) for observed
results, aggregate counters and explicit limits.

## Current gameplay feature work

The user moved on from movement acceptance to battles and trades, with this
specific entry: stand on the tile next to a friend, face them and press A as
with a normal NPC. The new [interaction handoff](BOUND-MULTIPLAYER-INTERACTIONS.md)
documents the invitation protocol. Accepted Battles now use the native activity
adapter described in [native friend battles](BOUND-NATIVE-FRIEND-BATTLES.md);
the normal-app Agora knockout acceptance passed in 314.7 seconds with native
attacks, matching win/loss, and both original positions restored. Trades
remain invitations only. Do not repeat the
900-second presence run as a substitute for implementing gameplay.

## Checkout and ownership

The isolated continuation checkout is `/Users/evandev/dev/bound-multiplayer`
on branch `multiplayer`, remote `https://github.com/evanvonessen/bound.git`.
Inspect status/worktrees and fetch before further work; pull with `--ff-only`
only in a suitable clean `multiplayer` checkout. The original main checkout and
its unrelated Xcode edits, plus the speed1 worktree, were preserved.

The private transfer supplied copies of the launcher, exact ROM and seed,
helper source, policy instructions and original protected-file baseline.
All 14 files were checksum-verified before the user-requested deletion of
`/Users/evandev/Desktop/file`. The preserved transfer remains unchanged under
`.build/full-app-gameplay-validation/transfer-package/`, with private file
permissions and Git ignore coverage. It contains no transferred credentials.

Two fresh owned disposable iOS 27 simulators were created on this Mac:

- A: `C078381A-9AB4-4632-8713-A1821058830B`
- B: `88222DAB-CC82-4F4F-8FF2-665E3523E17B`

Both were shut down after acceptance and cleanup. Their identifiers are
recorded in private `simulators.json`. The source Mac's
old simulator IDs are not present here and were not reconstructed. Fixtures now
come directly from the preserved transfer; a third source simulator is unnecessary.
Leave all unrelated simulators, worktrees and normal app data alone.

## Changes in this continuation

- `BoundFullAppGameplayQA.swift` exposes read-only QA friend-selection and
  sharing-status observations, still DEBUG/simulator-only.
- `PairedFriendUITests.swift` waits for a ready friend list, touches the native
  friend-label area and verifies actual selection/sharing before closing Friends.
  Stop uses a lazy query covering both normal labels while scrolling the row
  into view. Failed native checkpoints retain hierarchy, screenshot and observation.
- Product auth, Agora/Supabase configuration, backend/schema/RLS/functions,
  SDK/dependency pins, signing settings and normal user-data behavior are unchanged.

The ordinary entry remains `Bound.xcodeproj`; no app-build wrapper was added.
The private launcher only prepares test inputs, coordinates the committed UI
coordinator and cleans up its own temporary relationship/session inputs.

## Actual results and preserved failures

- Run 8: the first local build disabled signing, and the simulator rejected
  the unsigned Agora framework at launch. Crash reports were preserved.
  Rebuilding with simulator ad hoc signing resolved this without project changes.
- Run 9: both native-only UI tests and coordinator passed. Both apps accepted
  native touches, exited the lab, created real states and restored the saved tiles.
- Run 10: initial center-row friend taps did not start sharing. The rehearsal
  was interrupted after preserving observations; all cleanup checks passed.
- Run 11: label-area taps connected over real Agora. Independent states, both
  exits, mismatch hiding, outside reunion, restores, background recovery and
  renewals passed. Stop failed because the test committed to the legacy label
  before the current row was scrolled into view; the query is now corrected.
- Run 12: Stop was found after scrolling, but sharing remained active after
  its element tap. The retained hierarchy showed all three sibling buttons
  using the row identifier. Native taps now freeze the chosen label's screen
  frame before synthesis and check that the control is enabled.
- Run 13: the rehearsal passed, followed by full >=900-second acceptance,
  including normal UI stop and successful Xcode exits. One temporary friendship spanned
  the two runs and was removed with original lists and input cleanup verified.

Debug test builds, the 61 focused integration tests, ordinary UI regression,
unsigned iPhone Release build, cloud-resource equality, Release QA-flag exclusion,
all 17,060 source pins and the source diff checks passed. The 57 present
protected files matched; the 58th baseline entry is the absent ignored source-Mac
CLI cache marker, explicitly recorded in receipts. Do not claim all 58 were read.

## Private local artifacts and reuse

All of these paths are ignored and must remain private:

- `.build/full-app-gameplay-validation/`: receipts, run logs, failed evidence,
  fingerprints, integration/UI results and Release verification.
- `paired-9/summary.json`, `paired-13-smoke/summary.json` and
  `paired-13-full/summary.json`: native, rehearsal and full acceptance results.
- `live-receipt-13.json`: final temporary-friend/input/baseline cleanup receipt.
- `tested-source-local-13.json`: hashes of the actual tested source and private
  launcher; refresh for changed source rather than reusing it as a new build proof.
- `.build/LivePresenceQA/`: Debug app and SDK 27.1 arm64 test specifications.
- `.build/LivePresenceRelease/`: ordinary unsigned iPhone Release product.

The transferred original launcher is preserved. The active ignored
`run-private.py` adapts ROOT/helper/fixture paths, discovers this Mac's built test
specification, records the missing CLI marker without altering the baseline,
and supports a rehearsal/full suite with one guaranteed-final-cleanup friendship.
Use a new run number and fresh output paths for every attempt.

The user's foreground setup populated only the exact development-account item
through the transferred approved helper. Continue using `/opt/homebrew/bin/python3`
and the protected public client key at `~/.cupcake-dev/publishable-key` (path only
in environment). Read the transferred credential policy before reuse. Never
enumerate Keychain items, export credentials, unlock automatically or relax ACLs.
Only the user enters secrets. Missing/denied access fails closed.

Selected tools are under `/Applications/Xcode.app/Contents/Developer/usr/bin/`.
The direct simulator tool is
`/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl`.
Do not change global Xcode selection or restart shared simulator services.

For Debug simulator builds, use the normal scheme with local ad hoc signing:
`CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES CODE_SIGNING_REQUIRED=YES`.
Use `CODE_SIGNING_ALLOWED=NO` for the unsigned generic iPhone Release build.
Both are invocation flags; committed signing settings remain unchanged.

For a future authorized repeat, the private launch recipe is:

```sh
umask 077
PATH='/Applications/Xcode.app/Contents/Developer/usr/bin:'"$PATH" \
  BOUND_QA_RUN=FRESH_NUMBER BOUND_GAMEPLAY_DURATION=900 BOUND_GAMEPLAY_SUITE=1 \
  PYTHONDONTWRITEBYTECODE=1 /opt/homebrew/bin/python3 -B \
  .build/full-app-gameplay-validation/run-private.py \
  > .build/full-app-gameplay-validation/run-FRESH_NUMBER.log 2>&1
```

Native-only remains available via `BOUND_GAMEPLAY_NATIVE=1` and duration 1,
without the suite flag; it skips friendship creation. The existing five-creates-
per-hour limit remains unchanged. Never rotate accounts or use another pairing
path to bypass it. Preserve receipts and use one scoped friendship across related
rehearsal/full work where possible.

Physical-device, separate-network, performance, interactive-login, push,
adverse-network and actual battle-playthrough coverage remain outside this proof.
The checked acceptance is full-app gameplay on two simulators over real Agora.
