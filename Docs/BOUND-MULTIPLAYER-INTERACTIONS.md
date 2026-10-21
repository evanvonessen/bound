# Friend interactions in the overworld

Accepted Battle requests now enter the supported game's native two-player
single battle through VBA-M. See [native friend battles](BOUND-NATIVE-FRIEND-BATTLES.md)
for entry, transport, recovery and current validation evidence. Accepted Trades
enter the native trade menu and save the exchange; see
[native friend trades](BOUND-NATIVE-FRIEND-TRADES.md). Both activities require the
Experimental Features switch.

## Player interaction

Connect to a friend in Friends and enable live sprites on both devices using
the supported Radical Red 4.1 ROM. Walk onto a tile directly beside your friend,
face their tile, and press **A**. The friend must be on the same map and elevation.
Diagonal positions, overlapping players, other maps, stale presence and sprites
in the middle of a step are excluded.

The interaction overlay offers Battle and Trade invitations. The other player
can accept or decline. Either player can cancel. A request expires after 30
seconds; acceptance confirmation expires after 10 seconds. Moving away, losing
presence, restoring a state or losing the connection invalidates the request.
Two simultaneous requests decline each other rather than silently choosing an
activity. An accepted Battle starts native connection setup; accepting Trade starts native save/link setup and the cartridge trade menu.

The invitation overlay leaves the local emulator running so presence stays fresh. It
releases held gameplay inputs and blocks further game inputs until closed.
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
- `BoundFriendInteractionPacket` is capped at 1,024 bytes and has a `BFI1`
  prefix, separate from movement JSON. It contains the activity, request/session
  identities and two map positions. It carries no RAM, battery save or party.
- Agora uses a second data stream created with **reliable=true, ordered=true**.
  The installed Agora 4.6.4 headers distinguish this API from the existing
  replaceable presence stream. SDK callbacks copy invitations into a FIFO of
  at most 64 messages. Movement updates cannot overwrite it. Overflow or a
  stream-delivery error aborts the invitation channel rather than continuing
  after losing a control message. A new sharing session resets it.
- Sharing stop/recovery, ROM binding and restored-state admission fence old
  invitations. The SDK callback accepts only the configured friend's remote UID.
- `BoundFriendInteractionPanel` is a scrollable native overlay with explicit
  friendly-battle and persistent-trade wording. `BoundFriendWorldInputGate` filters the same logical
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
consent, duplicate delivery, crossed invitations, cancel/decline/timeout,
connection and location invalidation, bounded FIFO behavior, and input filtering.

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
