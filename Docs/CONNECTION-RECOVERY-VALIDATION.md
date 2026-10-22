# Connection and recovery

Friend companion video and full-screen spectating now expire three seconds after
the last usable decoded frame. Incoming packets or failed/busy frame conversions
do not keep Live status alive. Peer departure and reconnect invalidate visibility
immediately. Rejoining requires a new decoded frame, and the receiving display
loop preserves Reconnecting status until the connection recovers. Existing
foreground token renewal, same-account/same-room checks, manual-stop behavior,
backoff and native interrupted-battle recovery remain in place. No enforcement
or game save behavior was added or changed.

## Local verification

77 silent simulator checks passed: 19 LivePresenceTests, 6 focused
PlaybackSharingTests, 41 SoulLinkTests, 10 SharedWorldTests and the actual native
Soul Link HP/state-recovery test. Coverage includes arrival without decoding,
decode stalls, peer departure, reconnect/rejoin, hidden companion spectating,
publication backpressure, fresh tokens after foreground, owner/room changes,
manual stop and authorization retry backoff. Evidence stays in ignored
`.build/connection-recovery*` outputs. The 17,061 pinned dependency files and
both generated enforcement shim checks passed. The unsigned Release iPhone build passed.

## Two physical devices: pending

Discovery on October 22 found one paired available iPhone; the paired iPad was
unavailable. Simulator checks do not satisfy two-device verification. No personal
device app, ROM or save was replaced. No TestFlight build was started.

When both devices are connected and unlocked:

1. Use the same validated Bound commit and compatible integrated ROM on both,
   with separate friend accounts. Preserve existing saves before installation;
   use disposable QA games for battle/trade interruption scenarios.
2. Establish friend sharing and verify movement/video in both directions and
   full-screen spectating, with audio disabled. Record both device models,
   app commit/build, ROM hash, connection type and observed recovery times.
3. Interrupt one connection. Confirm stale video disappears, spectator shows
   waiting/reconnecting, and shared sessions stop treating the peer as fresh.
   Restore connectivity and require fresh video before Live returns.
4. Lock/background and foreground each device in turn. Verify fresh authorization,
   room continuity and no sharing restart after a manual stop. Switching rooms or
   accounts must not reconnect the previous session.
5. Interrupt a friendly battle using QA saves. Verify the protected pre-battle
   state is restored before normal play resumes. Interrupt a trade separately;
   verify native saved trade recovery, never a battle-style state rollback.
6. Repeat while viewing the companion, while it is hidden, and while spectating.
   Verify ordinary local gameplay and the partner session remain responsive.

Record pass/fail evidence for each case on both devices before calling this
hardware-verified or adding further enforcement on that basis. Do not substitute
an archive, successful simulator run, push or upload for these observations.
