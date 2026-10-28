# Following Pokémon and friend collision

The Viridian City Pokémon Center NPC controls the original game’s following
Pokémon service. Bound reads the actual selected Pokémon and its native sprite;
it does not automatically enable a follower or draw a second local copy.
The friend sees its current appearance, movement and visibility alongside the
existing trainer sprite. Older cartridges retain their original behavior.

Face a friend’s settled follower and press A to open **Offer berry**. The berry
and heart reaction are cosmetic messages. No bag, Pokémon, friendship, stat,
save or battle mutation is available to this interaction. Moving away, changing
follower, changing map or losing the connection dismisses the interaction.

Connected trainers and followers occupy their current and previous native tiles
on the same map and collision elevation. Remote images retained during a
disconnect never keep collision authority. The native game continues to decide
terrain, ledges, scripts and progression. A separate reliable exchange resolves
nearby competing steps before the game starts moving; it does not rewind,
teleport or correct positions. Ledge jumps reserve the midpoint and landing.

**Let pass** appears when a connected friend is nearby. Both clients acknowledge
the request before temporarily allowing passage for two seconds. The remote
sprites fade during passage. If characters already overlap, steps may reduce
that overlap; steps into a new occupied tile remain blocked afterward.

Map loads, menus, fades, stale control messages, reconnects and restored states
revoke old movement grants. The host port is cleared before native state loads.
Rendering still uses the existing interpolation and disconnect persistence;
collision uses fresh native tiles independently of animated sprite positions.

A native publication can span a video frame. Readers retain only the last
committed result for up to three interrupted observations, rechecking the
current follower’s identity and visibility each time. The frame callback leaves
the host transaction untouched while the native writer may be scanning it.
An expired lease, a revoked context or a changed load timeline still clears it
immediately. Old UI callbacks cannot republish permissions after a state load.
An atomic revocation request and a 150 ms real-time deadline are checked before
each native frame, including the first frame after a pause. They prevent a
pending disconnect from leaving a stale blocker or grant on resume.

The paired candidate uses save layout16, battery version1 and core-state
version10. Layout equality alone is insufficient: the exact ROM hash, generated
contract and native core must match. The frozen layout15 elimination profile is
retained separately; old saves are not relabeled as current saves.

This local-only checkout pins SHA-256
`723924890b6f912e7f8cf6bca72773fb5bea3d449caefd5abb9d82d22c2144f6`.
For local builds set `BOUND_GAME_SOURCE` to the isolated game checkout and
`BOUND_DEVELOPMENT_ROM` to the reviewed `candidate-05/multiplayer.gba` in
`artifacts/multiplayer-isolation/follower-collision`. The bundler verifies and
embeds that exact image. The candidate is not published, and ROM bytes are not
committed. Keep local generated output and QA fixtures outside tracked source.

Validation evidence is kept in the same isolated artifact directory and in
`follower-presence`. Controlled coordinator tests cover transport loss,
reordering, simultaneous targets, swaps, overlaps, passage and state rollback.
Native tests separately exercise the collision hooks, walking, map transitions,
ledge animation and original follower dialogue. Simulator tests cover the
production bridge and input filter. These checks do not establish two-phone,
WAN latency or physical-device performance.

Final local acceptance passed 139 follower/presence/movement/transport tests,
122 Soul Link/gameplay tests and 120 native compatibility/save tests, with no
failures or skips. The four actual app runtime cases include full paused-RAM
comparison for berry offers and first-frame host revocation/expiration. Native
acceptance separately passed 134 checks, the actual two-core cooperative fight,
and original follower enable, walking, warp and return-to-ball dialogue.
The unsigned Release iPhone build and empty-cache ROM embedding check passed.

Delivery tooling now selects the locked local gems and validates a local
distribution export before claiming it is ready to upload. Previous completed
failures included Xcode App Store Connect account access; this work does not
claim that online Apple authorization is repaired. No Fastlane, archive, upload,
ROM publication, backend deployment or shared-simulator refresh was started.
The current workspace instructions keep these paired commits local.
