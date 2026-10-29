# Native friend interactions — October 28, 2026

## Behavior and ownership

Let Pass and its settings toggle are removed. The retired preference is inert;
old pass-protocol messages cannot disable collision. The existing occupied-tile
collision and overlap recovery remain independent of UI. Trainer prediction,
the presentation clock, and ordinary movement admission remain unchanged.

The follower reader now distinguishes camera culling from explicit native
invisibility. Follower presentation bridges brief missing observations for at
most 250 ms, interpolates real observations on the trainer's existing clock,
and clears on map/identity changes or withdrawal. Borrowed presentation never
becomes collision or interaction authority.

Friend feeding enters the original RR follower feeding branch at `0x09049C30`.
On this cartridge, talking to a follower offers **an Oran Berry, Yes/No**; it does
not offer the Berry Pouch picker. The original script checks and removes the
item, displays its dialogue, and calls its original friendship effect. That
effect adds 70 below friendship 100, 60 below 200, or 30 otherwise, capped at
255; it does not heal HP. A scoped target adapter redirects only the target and
local-object animation. It restores borrowed memory and ROM operands before
capturing a clean continuation. The donor's own party is never substituted.

Bound's continuation store journals the native before/after states and the
authenticated transaction. Recipient eligibility and the exact preimage are
rechecked before preparation. The donor persists its decision before sending
commit; the recipient persists completion before acknowledging it. Repeated
messages restore the agreed result rather than applying another effect.
Interrupted pre-decision feeding refunds its native preimage. A durable commit
is retained for reconnection and cannot be retracted by an old abort. Failed
durable writes hold the core and retry; confirmed server checkpoints settle the
continuation. These records are scoped to owner, room, run and exact cartridge.

The reproducible battle deadlock was acceptance arriving while a native
dialogue was open. The agreed interaction blocked A/B while waiting for that
same dialogue to finish. Pending native cleanup now retains native input until
the field is ready. Startup also exposes the existing cancellation control and
maps B to cancellation when the startup owns input. Native dialogues retain
their own B behavior. Fast-forward is preserved.

## Exact pair

- Game commit: `9baa64971769f9773a6a34fdf489ce998b634b2c`, RRv4.1M build 503.
- ROM SHA-256: `a215add233d8d2f119e29b435605d3af99d063180d6b77310f178dfcdebf0ba2`.
- Game build identity: `6f70ce7b70d142cee2fbcaa197f48c58fc18f2f2`.
- Normalized native base SHA-256: `689299664a954c12dad66e03c2d18446b348cb31bd98b395c87b9b514b288066`.
- Generated contract: ABI 1.0, wire 2, checkpoint/battery 1, state layout 16.
  App native runtime: pinned Delta/GBADeltaCore VBA-M state version 10.
- No game source, cartridge, dependency pin, or save format changes are included.
  Native fixtures are generated from this exact cartridge; old emulator states
  are not assumed compatible merely because their ABI matches.

## Evidence

Local artifacts are under
`artifacts/multiplayer-isolation/native-friend-interactions/` in the parent
workspace. They contain disposable ROM/state fixtures and remain outside Git.

| Check | Result / artifact |
| --- | --- |
| Focused app regressions, including transport, movement, follower and transaction models | 194 tests passed, zero failures: `regressions.log` |
| Final affected app suites, including startup B cancellation | 145 passed, zero failures; four fixture-gated movement tests skipped in this invocation: `final-regressions.log` |
| Native own-vs-friend feeding | Original script and adapter have identical bag/mon results at friendship 0, 99, 100, 199, 200, 250 and 255; decline, missing berry, donor-party preservation, recipient commit and forged effects checked |
| Transaction ordering/recovery | Ten model tests, including either donor, retries/duplicates, disconnect, cold restore, context fencing and durable-write failures; eight write boundaries are exercised inside the fault matrix |
| Battle regression before/after | `battle-dialogue-before` reproduced zero A input reaching the native dialogue and no handoff; `battle-dialogue-fixed` passed the same native regression |
| Invitations | Either initiator at 1× and 8×; decline, cancellation, cleanup and connection interruption covered by production-session tests |
| Two native simulator battle instances | Entry/cancel, full battle, native Run and restored parties passed; field/dialogue/movement services and production input gate enabled; A at 8×/B at 1× and B at 8×/A at 1× covered |
| Native interrupted battle | `battle-b-fast-interrupted`: B initiates at 8×, three-second packet blackhole, reconnect, native Run, both owner states and parties restored |
| Original follower service | 15 native checks plus source decoder/presentation checks: `native-follower-03`; enable through native dialogue, walking, Oak Lab warp, identity retention and initially-disabled state |
| Solid collision and movement | `collision-native-02`: 215 checks, 248 actual native movement actions, Let Pass absent; 40 occupied-tile blocks, 208 open-space actions with zero added native input-start frames, 96 running actions; overlap, immediate separation, same-direction overlap, all four approaches and adjacent passes for trainer/follower occupancy |
| Actual app VBA movement port | `movement-runtime-06`: four tests passed, zero skips/failures; occupied-tile blocking/revocation, immediate overlap escape, adjacent open movement, atomic host validation, TTL, map/Bag transition, frame revocation and retired-packet/input isolation |
| Release iPhone | Manual `PrototypeTools/fastlane-local ios verify` passed: `release.log` |

Native collision uses two exact-ROM mGBA instances driven by production Swift
collision decisions and native directional input. Follower occupancy in that
matrix is a declared synthetic peer pose; actual native follower appearance and
movement have separate service/decoder tests. Feeding's native effect tests and
two-owner transaction fault tests are complementary; they are not a claim of a
physical two-phone feeding session. Native battle pairs use host loopback with
the production command relay, not the live authenticated WAN service.

The reported “two players facing each other while fast-forwarding” phone freeze
was not reproduced as a separate fast-forward engine failure. A native-dialogue
handoff deadlock was reproduced and fixed, and fast-forward entry/return passed
with either initiator. Physical-device/WAN verification remains outstanding.
The optional follower enabled-to-disabled dialogue navigation was not exercised;
explicit disabled-state decoding, map transitions and disconnect expiry were.

Initial follower verification stopped at an obsolete source-extraction marker;
the repaired presentation harness then passed. The additional VBA movement
fixture initially skipped without its explicit opt-in, then exposed an obsolete
map assumption and legacy negotiation expectations/flags. Its final run uses a
fresh exact-ROM bedroom snapshot, the cartridge's native Pallet warp opcode,
and the same non-negotiating host flags as production. Earlier failures are
retained alongside the successful final logs.

Apple upload acceptance, processing and TestFlight availability are separate
delivery stages. Record their observed results after the authorized manual
Fastlane upload; a successful archive or accepted upload alone is not proof of
TestFlight availability.
