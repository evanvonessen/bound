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

## Paired encounter tracker

Open **Friends → Soul Link → Paired encounters** during a run. Search by area or
Pokémon name. Each named area shows your catch, your partner's catch, and
**Available**, **Waiting for you**, **Waiting for partner**, **Linked**, or
**Fainted**. Partner-only catches appear even before you visit that area.
Unobserved partner data shows **Syncing partner**, never an assumed free catch.
Available areas come from the verified game's met-location name table; the list
is not a promise that every listed location has a catchable encounter.

The first successful acquisition on each side pairs automatically by area;
eggs pair by ordinal. No manual matching is needed. Catch records, partner names,
and permanent losses survive reconnects, app restarts, boxing, release and save
rollback. Both players need this app version. Existing run journals load with
all their original eligibility/deaths and acquire partner metadata on reconnect.
A legacy peer triggers a pause and an update message. No new ROM is required: this adds
tracking through the existing native Soul Link observation/enforcement adapter;
the integrated game and shared-progression ABI remain unchanged.

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
separate bounded `BSL2` protocol. Every state carries **two complete 288-byte
bitmaps**: successful acquisitions and permanent losses (all 256 areas and up to
2,048 egg ordinals), plus up to three rotating names. A catch becomes occupied
immediately after a fresh challenge, independent of name rotation. Both sets
merge monotonically and are committed atomically to the run journal. Losses
merge even before the fresh challenge; acquisitions and names require it. New session challenges prevent an old
pre-disconnect alive packet from marking a reconnect ready. Run and local room
bindings prevent a different run/friend from changing the ledger. Deaths and end
results survive disconnects and are replayed. Pokémon identities/party bytes
remain local; the wire carries run/session IDs, slots, names and loss bits.

The ledger bounds the total identity/alias set at 2,048. Overflow or a native
faint-latch overrun pauses with a preserved record rather than dropping events.
It is a local challenge record, not a server anti-cheat service.

## BSL2 wire format

Packets are binary and at most 1,024 bytes. Offsets: `BSL2` magic at 0, version
2 at 4, kind byte at 5 (offer/accept/confirm/decline/state/end = 0..5), run UUID at
6, sender challenge UUID at 22, receiver-present byte at 38, receiver UUID at 39,
loss bits at 55, acquisition bits at 343, row count at 631, rows at 632.
UUIDs use their 16 RFC-order bytes. Each row has a little-endian 16-bit slot
(areas 0..255; eggs 256..2303), dead byte, UTF-8 byte count, then the name (at most
20 characters/80 bytes). Unknown versions, duplicate/invalid slots, malformed
UTF-8, truncated fields and trailing data are rejected. Three worst-case names
with both complete bitmaps occupy 884 bytes. Identities and Pokémon data stay local.
BSL1 is recognized only to explain the required app update, never as BSL2 state.

## Verification

The paired encounter update passed 37 selected checks: 26 Soul Link rules/UI/
protocol checks, 10 shared-world checks and the actual native Soul Link capture,
PC/egg, faint and rollback fixture. The screen was rendered and visually checked
in the disposable simulator, and an unsigned Release iPhone build passed.
The native fixture runs with emulator audio disabled. Full logs/screenshots and
working save copies remain under `.build/paired-encounters-*`; original ROM and
seed bytes are checked unchanged. Paired sessions are exercised locally through
the production packet/session code; this is not a two-phone/Agora acceptance run.

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
  A healthy-to-zero native HP write to an unhatched egg emits no faint event.
  Unhooking restores original ROM-hash/native-link admission. Original
  ROM and seed bytes are checked unchanged. QA fixture code is simulator Debug
  only and is absent from the Release shim.
- Local evidence: `.build/soul-egg-regressions.xcresult` / `.log`: **60 checks
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
