# Partner battle spectating

Branch: `codex/partner-spectating`, based on `54fa4691013fa3e5dd804513dce9c454a2b352f1`.

Friends → Partner battle → Watch partner opens a read-only, silent full-screen
view of the current sharing partner. It displays the existing game stream,
including trainer and wild battles, without requiring a Soul Link run or a ROM
change. It does not announce battle entry automatically or expose remote inputs.
Closing the view leaves sharing and the companion screen intact.

Production Agora and the simulator loopback transport render the same decoded
frame into separate companion and spectator canvases. No additional publisher,
decoder, audio session, or emulator callback is created. Receiving continues
on the existing display link even when the viewer's emulation is paused.

The Live label requires advancing received-frame counts. Three seconds without
a frame hides the frozen image and shows a waiting status. Reconnection and
peer departure invalidate freshness immediately. Stopping sharing closes the
watch view and detaches its canvas. The watch view is available alongside normal
friend video sharing, independently of experimental game interaction features.

Validation:
- Debug simulator build-for-testing.
- 69 simulator checks passed: 18 LivePresenceTests, 3 PlaybackSharingTests,
  38 SoulLinkTests and 10 SharedWorldTests. This includes actual decoded spectator
  pixels with a hidden companion, reconnect freshness, independent canvas teardown,
  and unchanged Soul Link behavior.
- Pixel-routing integration test passed: hidden companion, reconnect freshness,
  independent close. The first host launch was killed before test startup; retry
  passed. Both result bundles are preserved.
- Dependency verifier: 17,061 pinned source files unchanged.
- Unsigned Release iPhone build (see local build receipt).

Local evidence is preserved under `.build/spectating-*`. Tests used the dedicated
Integrated Multiplayer QA simulator and did not start emulator audio. These
checks do not establish real two-device Agora latency, physical-device UI,
or a live partner's battle performance. Those remain device/network validation.
No ROM replacement is required. Publication and internal delivery status are
reported separately after verification.
