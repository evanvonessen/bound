# Friend interactions in the overworld

Accepted Battle requests now enter the supported game's native two-player
single battle through VBA-M. See [native friend battles](BOUND-NATIVE-FRIEND-BATTLES.md)
for entry, transport, recovery and current validation evidence. Accepted Trades
enter the native trade menu and save the exchange; see
[native friend trades](BOUND-NATIVE-FRIEND-TRADES.md). Both activities require the
Enable Experimental Multiplayer switch.

## Player interaction

Connect to a friend in Friends and enable live sprites on both devices using
the supported Radical Red 4.1 ROM. Walk onto a tile directly beside your friend,
face their tile, and press **A**. The friend must be on the same map and elevation.
Diagonal positions, overlapping players, other maps, stale presence and sprites
in the middle of a step are excluded.

The cartridge menu offers Battle, Trade and Cancel. The other player can accept
or decline. Either player can cancel. Menus and invitations have no waiting
deadline: missing position packets, roster gaps and socket reconnects retain
the menu, selection and consent. Failed or unacknowledged invitation messages
retry once per second while the connection permits them. Fresh verified
movement away, deliberate disconnect, cancellation, account/room changes or
disabling multiplayer end the interaction. An ended invitation leaves an
acknowledgement instead of silently dismissing its window.
Two simultaneous requests decline each other rather than silently choosing an
activity. An accepted Battle starts native connection setup; accepting Trade starts native save/link setup and the cartridge trade menu.

The native invitation leaves the local emulator running so presence stays fresh.
It releases held gameplay inputs and gives the cartridge window its normal controls.
The native menu and existing app shortcuts retain their mapping. A press used
to interact with a friend is an app-only input, which VBA-M ignores; it does
not also interact with a game NPC or sign. Native touches and mapped physical
controller A share the same path. External holds are admitted once per release.
Other emulation cores retain their normal mappings.

## Implementation

- `BoundLivePresenceSession.interactionContext` admits fresh, settled local
  and remote positions using the latest actual samples, not the interpolated
  rendering position. Both sides' current presence epochs bind the interaction.
- `BoundFriendInteractionSession` owns the request/accept/confirm/decline/cancel
  state machine. Request UUIDs, phase checks, location checks and a bounded
  retired-ID list reject duplicate and superseded messages. Incoming requests
  require the sender to be facing the local player's adjacent tile.
  Freshness is required to open or admit a new invitation, but missing samples
  do not prove that a player moved. A reconnect rebinds the retained invitation
  to new authenticated presence epochs only after both players still occupy
  its verified adjacent positions. Lost cancel/decline messages are replayed
  when the other peer retries; repeated consent cannot launch an activity twice.
- `BoundFriendInteractionPacket` is capped at 1,024 bytes and has a `BFI1`
  prefix, separate from movement JSON. It contains the activity, request/session
  identities and two map positions. It carries no RAM, battery save or party.
- Agora uses a second data stream created with **reliable=true, ordered=true**.
  The installed Agora 4.6.4 headers distinguish this API from the existing
  replaceable presence stream. SDK callbacks copy invitations into a FIFO of
  at most 64 messages. Movement updates cannot overwrite it. Overflow or a
  stream-delivery error suspends invitations while transport and fresh presence
  recover. Nakama uses the same invitation state machine. Pending messages are
  retried from their consent state, independently of the transport FIFO.
- Explicit sharing stop, ROM binding and restored-state admission fence old
  invitations. The SDK callback accepts only the configured friend's remote UID.
- `BoundFriendInteractionPanel` owns a completed-frame mailbox for native cartridge
  windows; it draws no app overlay. Reconnection preserves the current window
  request and cursor. `BoundFriendWorldInputGate` filters the same logical
  mapping before both the app and emulator receive a controller input.

Cloud setup, backend, authentication, signing configuration, SDK versions and
core identities remain unchanged. The native battle adapter temporarily modifies
the loaded ROM and game RAM for the exact supported profile, then restores a
private pre-battle state. The cartridge file itself is never rewritten. Native command transport leaves the pinned VBA-M sources and manifest unchanged.

## Remaining trade work

Trade completion must use the game's own behavior and preserve each player's
save ownership, including interrupted-operation recovery. An accepted Trade
invitation does not transfer a Pokémon.

## Focused validation

Use `BoundIntegrationQA` with `BattleCableTests`, `FriendInteractionTests`,
`LivePresenceTests` and
`ControllerNavigationTests`. The interaction tests cover adjacency/facing,
consent, duplicate delivery, crossed invitations, lost request/accept/confirm and
cancel/decline messages, prolonged position gaps, reconnect epochs, verified
location invalidation, bounded FIFO behavior, and input filtering.

`FriendInteractionTests.testNativeChooserAndTradeInvitationStayOpenAcrossDisconnects`
uses the current integrated private cartridge in the isolated simulator's
`Documents/MultiplayerValidation/RadicalRed.gba`. It creates a disposable New Game,
operates the cartridge's actual chooser and invitation with A/B/D-pad input,
checks that the cursor and windows survive simulated connection loss, and checks
that cancellation releases native script locks. `PlaybackSharingTests` also
injects roster, socket and interaction-stream interruptions through the real
sharing coordinator. These checks do not establish physical-device network
reliability or seamless continuation of an already active native cable session;
existing battle/trade interruption and save-recovery rules still apply there.

`FullAppGameplayUITests.testFriendWorldInvitations` runs two ordinary Bound UIs
with native controller touches and real Agora. The existing private launcher
can opt into `BOUND_GAMEPLAY_INTERACTIONS=1`; the public coordinator selects this
short flow with `--interactions-only --duration 1`. It checks facing away does
not open the panel, facing the adjacent friend plus A does, battle invitation
decline reaches both apps, and a trade invitation can be declined.
The separate `testActualFriendBattle` / `--battles-only` flow exercises actual
battle entry, native touches for moves, damage, matching outcomes and world restore.

The earlier full-app movement/save-state 900-second acceptance is recorded in
`BOUND-MULTIPLAYER-GAMEPLAY-QA.md` at checkpoint `ec35f9cb`. It need not be repeated
for invitation UI work. Build/test logs and runtime artifacts stay in ignored
`.build/full-app-gameplay-validation/`; ROMs and credentials remain private.

## Persistent invitation validation — October 24, 2026

- 54 focused tests passed without failures or skips: 20 invitation tests,
  25 presence tests, four cable protocol tests and five sharing/reconnect tests.
- The current integrated cartridge's Battle/Trade/Cancel chooser kept the same
  native window and cursor during a simulated outage. Both outgoing and incoming
  trade prompts remained available, and A/B cancellation returned to an unlocked
  field. Button readiness now distinguishes finished text from text still printing.
- Protocol checks cover hour-long simulated waits, dropped messages, fresh
  reconnect epochs, duplicate delivery and no repeated activity launch.
- The unsigned Release iPhone build passed. All 17,061 pinned sources, 99
  integration hashes and two SDK privacy manifests verified unchanged.
- Physical-device, separate-network and active native cable reconnection remain
  outside this validation. No phone performance parity is claimed.

## Invitation checkpoint results — October 20, 2026

- Final focused suite: **39 passed, no failures or skips** (nine interaction,
  twelve presence and eighteen controller-navigation tests).
- Real Agora paired runs 14 and 15 passed in both ordinary Bound simulator UIs.
  Run 15 exercised the final held-input fix and completed in
  **43.3 seconds**. Native touches reached adjacent positions,
  facing away left A with the game, facing the friend plus A opened the panel,
  both peers confirmed battle consent, and trade decline reached the requester.
  The retained run-14 screenshot also passed visual inspection.
- Final unsigned Release iPhone build passed. Its cloud resource matches the
  source and Debug resource exactly, and simulator-only QA entry is absent.
- All 17,060 pinned source files verified unchanged. All 57 present protected
  setup/auth/config/sync files matched; the original source Mac's ignored
  `Backend/social/supabase/.temp/cli-latest` remains absent, as before.
- Both runs removed their temporary development-account friendship and one-use
  session inputs, restored the original friend lists and preserved fixture ROM
  and seed hashes. Both owned QA simulators were shut down afterward.
- This evidence proves invitation UI/transport, not an actual native battle or
  Pokémon exchange. No physical-device or separate-network claim is made.

Private evidence: `paired-15/summary.json`, `live-receipt-15.json`,
`friend-interaction-unit-2.log` / `.xcresult`,
`friend-interaction-release-2.log`, and
`friend-interaction-verification-15.json` under the ignored validation folder.

The subsequent native-battle acceptance and current limits are recorded in
[Native friend battles](BOUND-NATIVE-FRIEND-BATTLES.md#observed-results--october-20-2026).
