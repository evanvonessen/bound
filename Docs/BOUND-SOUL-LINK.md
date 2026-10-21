# Soul Link runs

Soul Link pairs two fresh Radical Red 4.1 games through the existing authenticated
Bound friend room. It uses the same experimental multiplayer switch and exact ROM
profile as live sprites and native friend battles. It adds no backend deployment,
account, credential or signing changes. Each player keeps their own game and save.

## Start

1. Both players enable **Settings → Enable Experimental Features**.
2. Start new games and receive your starters. Each save must own exactly one
   healthy non-egg Pokémon, with no boxed Pokémon. Start before catching others.
3. Open **Friends**, connect to your partner, and choose **Soul Link → Start Soul
   Link**. The partner accepts the invitation. The named area and both catches
   appear in the Soul Link list.
4. Stay connected while playing. A disconnect, missing heartbeat, account/room
   change or disabled experimental switch pauses this run. Reconnect to the same
   partner, exchange the current run state, then return to the game.

Invitations and accepted runs survive app restarts. Cancelling an unaccepted
invitation keeps its record in Cancelled Invitations. **End Soul Link run** ends
the challenge for both players, preserves the record/Pokémon, and restores normal
rules. Its terminal result is sent again after reconnecting. A subsequent run
archives the previous record in Finished Runs. Starting a new run requires the
same starter-only conditions.

## Encounter and egg rules

- An area is the game's native **met location**, such as Route 2 or Viridian
  Forest, rather than all of Kanto. Floors or encounter methods sharing that
  location share one slot. Display names are read from the user's verified ROM.
- The first Pokémon acquired in that area is eligible and links to the partner's
  eligible Pokémon from the same area. Grass, fishing, surfing, static encounters,
  non-egg gifts, and **raid-den catches** share this slot. Choose a den or another
  encounter method; there is no extra raid allowance.
- Further catches from an occupied area remain owned, but cannot battle or
  replace the original eligible catch. Releasing, boxing or trading away a
  Pokémon does not release its slot. This implementation limits successful
  acquisitions; it does not automatically consume a slot for a fled or failed
  encounter or add species/gender/duplicate-species clauses.
- Eggs are separate pairs: **Egg 1 ↔ Egg 1**, **Egg 2 ↔ Egg 2**, in acquisition
  order. They do not consume their gift or hatch area's encounter slot. Native
  hatching can replace the egg's original trainer; the journal retains the
  original identity and the hatched alias under the same egg ordinal.
- A faint permanently marks the pair's slot dead. Both owned linked Pokémon
  become unusable; if the other player has not caught that area's Pokémon yet,
  their later catch is already barred. A further catch cannot replace a dead pair.
- Friend battles and friend trades are unavailable during an active Soul Link
  run. Normal friend battles/trades remain available outside the run.

## Native enforcement and persistence

`BoundSoulProbe` reads on VBA-M's completed-frame owner. The exact profile has
100-byte party Pokémon and 25 PC boxes of 30 compressed 58-byte Pokémon. PC
contents are decoded only when their bytes change; temporary raid/NPC teams are
not enrolled while battle/script scenes are running. Party/box movements,
evolution, nickname changes and hatching retain the recorded identity/slot.
Day-care Pokémon retain their prior record when temporarily absent from party/PC.

Two original 8-byte entry thunks wrap native `GetMonData` and `SetMonData` in the
loaded ROM. The wrappers preserve the native ABI and forward unrelated fields;
barred Pokémon always report zero battle HP and native healing cannot restore
it. The frame owner also clamps party HP and any already-active battle Pokémon
matching a barred identity. The native attack-canceler rejects zero-HP attackers.
A bounded native faint latch catches zero-HP writes even when a raid or healing
routine restores HP during the same frame. Only owned, eligible identities can
kill a pair; enemy/NPC Pokémon and ineligible extra catches cannot.

The runtime shim and sorted policy occupy verified unused space below the native
friend-link region. The cartridge file is unchanged, native identity fields
are preserved, and closing the mode restores the original entry bytes and clears the policy.
The inert shim body stays resident until ROM unload so a paused CPU can safely
unwind an existing shim return address. Native
link admission verifies the original ROM with these owned patches normalized.
The policy stays outside save-state RAM. The monotonic run journal lives in app
Application Support/Soul Link, scoped to the game and bound to the account/friend
room. It commits acquisitions, aliases and local/remote deaths atomically before
the next frame can continue. Healing, restarting, or loading an older healthy
save state does not remove a death or free an encounter slot. A damaged/unwritable
journal pauses play and is preserved.

The existing authenticated, ordered/reliable Agora control stream carries a
separate bounded `BSL1` protocol. Each state includes the **complete 288-byte loss
bitmap** (all 256 areas and up to 2,048 egg ordinals), plus a rotating small set of
names for the list. Losses merge by union. New session challenges prevent an old
pre-disconnect alive packet from marking a reconnect ready. Run and local room
bindings prevent a different run/friend from changing the ledger. Deaths and end
results survive disconnects and are replayed. Pokémon identities/party bytes
remain local; the wire carries run/session IDs, slots, names and loss bits.

The ledger bounds the total identity/alias set at 2,048. Overflow or a native
faint-latch overrun pauses with a preserved record rather than dropping events.
It is a local challenge record, not a server anti-cheat service.

## Verification

- Focused rules cover shared grass/fishing/raid metadata slots, direct-to-PC
  metadata, duplicate exclusion, eggs/hatching/OT changes, same-frame healing,
  future catches of dead slots, older alive packets, run mismatch, persistence,
  invitation restart, corrupt-record preservation and paired reconnect challenges.
- An opt-in `NativeBattleRuntimeTests/testActualSoulLinkNativeHPAndStateRecovery`
  boots the actual verified ROM and a copy of the protected seed in VBA-M. It
  executes the native getter/setter through a guest script, faints and heals in
  one frame, proves the death latch and heal exclusion, reloads a real older
  healthy save state, reloads the journal, and verifies the Pokémon remains
  barred. The same check invokes the actual native `GiveMonToPlayer` routine
  for a further same-area catch, an egg, and a new-area catch with a full party;
  it verifies ineligibility, Egg 1, and the real compressed PC result respectively.
  Unhooking restores original ROM-hash/native-link admission. Original
  ROM and seed bytes are checked unchanged. QA fixture code is simulator Debug
  only and is absent from the Release shim.
- Local evidence: `.build/soul-regressions-final.xcresult` / `.log`: **60 checks
  passed, zero failures**, including the actual VBA-M fixture above and paired
  reconnect/loss propagation. Debug test build and unsigned iPhone Release build passed; no physical-device
  claim is made.
- `PrototypeTools/build-soul-link.py --check` and `--qa --check` reproduce both
  small original Thumb shims with devkitARM.

The checked-in validation is not a completed two-phone playthrough or a real
raid capture/egg-hatching playthrough. Physical-device gameplay/performance,
separate networks, late-game scripted parties and every raid variant still
need live acceptance. Targeted native/fixture checks do not establish these.

## Reference contracts

The upstream [CFRU party structures](https://github.com/Skeli789/Complete-Fire-Red-Upgrade/blob/b637a27898b14e25dd24d0f69a3e302f0069deb8/include/pokemon.h),
[PC compression](https://github.com/Skeli789/Complete-Fire-Red-Upgrade/blob/b637a27898b14e25dd24d0f69a3e302f0069deb8/src/pokemon_storage_system.c),
[capture routine](https://github.com/Skeli789/Complete-Fire-Red-Upgrade/blob/b637a27898b14e25dd24d0f69a3e302f0069deb8/src/catching.c),
[hatching routine](https://github.com/Skeli789/Complete-Fire-Red-Upgrade/blob/b637a27898b14e25dd24d0f69a3e302f0069deb8/src/daycare.c)
and [attack-canceler](https://github.com/Skeli789/Complete-Fire-Red-Upgrade/blob/b637a27898b14e25dd24d0f69a3e302f0069deb8/src/attackcanceler.c)
are reference contracts. Compatibility is admitted by the exact local ROM hash
and the targeted runtime checks; upstream source alone is not RR runtime proof.
