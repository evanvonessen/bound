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

The first successful ordinary wild or raid acquisition on each side pairs automatically by area;
eggs, gifts and static encounters each pair by their own acquisition ordinal. No manual matching is needed. Catch records, partner names,
and permanent losses survive reconnects, app restarts, boxing, release and save
rollback. Both players need this app version. Existing run journals load with
all their original eligibility/deaths and acquire partner metadata on reconnect.
A legacy peer triggers a pause and an update message. No new ROM is required: this adds
tracking through the existing native Soul Link observation/enforcement adapter;
the integrated game and shared-progression ABI remain unchanged.

## Shared team dashboard

Open **Friends → Soul Link → Shared team**. Both six-Pokémon parties appear
side by side with bundled species sprites, nicknames, levels and HP bars. Each
encounter pair shows **In party**, **Boxed**, **Off team**, **Waiting for catch**,
or **Fainted** on each side. The dashboard links directly to Paired encounters
and Graveyard. Extra ineligible catches are displayed as unusable; an unlinked
entry never claims another encounter slot. Eggs hide species, levels and HP.

Team reads come from the existing completed-frame Soul Link probe, with cached
PC decoding. Only verified native overworld snapshots are published as current;
battle/menu/paused data and snapshots older than three seconds show **Last seen**.
Party/box labels also carry that marker when stale. Losses immediately override
healthy-looking cached HP. Ending the run removes the live designation.
Disconnect, room/game change and a new challenge clear the partner snapshot;
replayed packets cannot replace newer team data. Team data is transient and
never written into either player's game or rule journal.

The optional **BST1** channel carries a complete party and a 288-byte bitmap of
currently boxed eligible slots at most once per second. It has its own increasing
sequence and must match the active BSL3 run, both fresh challenges and the local
room binding. Its maximum valid six-member packet is 897 bytes, within the
existing 1,024-byte reliable mailbox limit. The header is `BST1` at 0, version 1
at 4, run UUID at 5, sender UUID at 21, receiver UUID at 37, 64-bit little-endian
sequence at 53, field-current byte at 61, party count at 62, boxed bits at 63,
and member records at 351. Each member has 16-bit slot (65535 means unlinked),
16-bit species, level byte, 16-bit HP/maxHP, egg/barred flag byte, UTF-8 name
length and bounded name. BSL3 area/egg bits, BSE1 category bits and durable shared events remain the authority;
BST1 never acquires slots or changes deaths. An older BSL2 peer requires an update before the updated Soul Link session can pair. No new ROM or game ABI is needed.

## Death moments and graveyard

A newly committed local or partner loss queues a silent **SOUL LINK BROKEN**
card over gameplay with both linked names and their encounter area. It fades in,
can be dismissed, and clears after seven visible seconds. Gameplay and controller
inputs continue. Reduced Motion removes the transition, and VoiceOver receives
an announcement. Cards wait while Friends/settings/text editing obscure the game
or the app loses focus; hidden time never consumes their display time.

Each device acknowledges its own presentation in the existing atomic run journal.
Multiple losses queue separately. An unseen moment survives restart; dismissal,
repeated packets, healing and old emulator states cannot replay an acknowledged
loss or revive the pair. A failed journal write pauses the run and keeps the
moment pending. Existing pre-feature losses enter the graveyard quietly rather
than replaying every old death.

**Friends → Soul Link → Graveyard** retains every lost area/egg pair, both names
and the time this device first recorded the loss. That time is not a synchronized
server death time; historical losses have no invented date. Names freeze when
known; a delayed partner name or later catch can fill a missing one. The graveyard
remains accessible after ending the run and is preserved in its finished-run
archive. No new ROM is required; the updated peers use BSL3 plus complete BSE1
gift/static facts. Existing area/egg loss meanings remain unchanged. All memorial metadata stays in the local journal.

## Encounter and egg rules

- An area is the game's native **met location**, such as Route 2 or Viridian
  Forest, rather than all of Kanto. Floors or encounter methods sharing that
  location share one slot. Display names are read from the user's verified ROM.
- The first ordinary wild Pokémon caught in that area is eligible and links to
  the partner's ordinary wild Pokémon from the same area. Grass, fishing,
  surfing, caves, and **raid-den catches** share this slot. Choose a den or
  another encounter method; there is no extra raid allowance. All dens in the
  same native named area share the allowance. Failed/fled encounters spend none.
- Fixed scripted overworld encounters (such as Zapdos) and non-egg gifts (such as
  Eevee, Magikarp, and gifted shiny Magikarp) do not consume or replace an area
  pair. They form their own pairs: **Gift 1 ↔ Gift 1**, **Gift 2 ↔ Gift 2**,
  and separately **Static 1 ↔ Static 1**, **Static 2 ↔ Static 2**. A faint
  permanently disables that separate pair, never the area or egg pair. Their original one-time availability is unchanged. Ordinary
  wild shinies use the ordinary allowance.
- The Celadon prize room allows **one Pokémon total**, across its entire species
  selection, separately from city catches. It appears as **Celadon Prize Pokémon**
  in paired encounters and links to the partner's one prize selection. Item/TM
  prizes remain native. Releasing, boxing, fainting or restoring an older save
  never makes another prize selection available.
- Occupied-area catches are blocked by the native bag and quick-ball eligibility
  checks before spending a ball. A defensive acquisition gate also refuses a
  second catch or prize. Pre-existing extra catches remain owned but cannot
  battle or replace the original eligible catch. Releasing, boxing or trading away a
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
- Friendly battles do not create permanent losses. Bound restores the prebattle
  state before normal death observation resumes, including after interruption.
  Existing legitimate deaths stay enforced. Friend trades remain unavailable
  during an active Soul Link run.

## Native enforcement and persistence

`BoundSoulProbe` reads on VBA-M's completed-frame owner. The exact profile has
100-byte party Pokémon and 25 PC boxes of 30 compressed 58-byte Pokémon. PC
contents are decoded only when their bytes change; temporary raid/NPC teams are
not enrolled while battle/script scenes are running. Party/box movements,
evolution, nickname changes and hatching retain the recorded identity/slot.
Day-care Pokémon retain their prior record when temporarily absent from party/PC.

Runtime entry thunks wrap native `GetMonData`, `SetMonData`, successful acquisition,
and catch eligibility in the loaded ROM. The wrappers preserve the native ABI and forward unrelated fields;
barred Pokémon always report zero battle HP and native healing cannot restore
it. The frame owner also clamps party HP and any already-active battle Pokémon
matching a barred identity. The native attack-canceler rejects zero-HP attackers.
An additional identity/source receipt ring records successful party/PC placement,
including acquisitions during scripts. The worker persists those receipts before
acknowledging their exact bytes and releasing the frame fence. The area bitmap
is applied outside save-state RAM, so a rollback cannot reopen an allowance.
Egg receipts allocate ordinals in actual acquisition order rather than party/PC
scan order. Existing journals keep their prior catches and losses; the new rule
never retrospectively frees a slot or reclassifies an old catch whose source was
not recorded. The three ordinal counters advance independently and cannot be
rewound by loading an older native save. Both participants should use the updated app.

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
separate bounded `BSL3` protocol. Every state carries **two complete 288-byte
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

## BSL3 wire format

Packets are binary and at most 1,024 bytes. Offsets: `BSL3` magic at 0, version
3 at 4, kind byte at 5 (offer/accept/confirm/decline/state/end = 0..5), run UUID at
6, sender challenge UUID at 22, receiver-present byte at 38, receiver UUID at 39,
loss bits at 55, acquisition bits at 343, row count at 631, rows at 632.
UUIDs use their 16 RFC-order bytes. Each row has a little-endian 16-bit slot
(areas 0..255; eggs 256..2303; gifts 2304..4351; statics 4352..6399), dead byte, UTF-8 byte count, then the name (at most
20 characters/80 bytes). Unknown versions, duplicate/invalid slots, malformed
UTF-8, truncated fields and trailing data are rejected. Three worst-case names
with both complete bitmaps occupy 884 bytes. Identities and Pokémon data stay local.
BSL1 is recognized only to explain the required app update, never as BSL3 state.

## Verification

The shared team update passed **49 selected checks**: 38 Soul Link tests,
10 shared-world tests and the silent native runtime fixture. They cover bounded
six-member packets, full boxed-slot data, replay/wrong-run/challenge rejection,
reconnect/expiry and ended-run labels, actual native level/HP and PC metadata,
and rendered local/two-peer dashboards. All encounter, death and shared-world
regressions passed. Debug simulator and unsigned iPhone Release builds passed;
17,061 pinned sources, game ABI import and native shim checks are unchanged.
Full screenshots, result bundles and working save copies remain under
`.build/shared-team-*`. The two-peer dashboard check uses production session/
packet code with controlled team observations; the native party/PC check uses
one actual VBA-M instance. It is not a physical two-phone/Agora acceptance run.

The death-moment update passed **44 selected checks**: 33 Soul Link tests,
10 shared-world tests and the silent native faint/catch/rollback fixture. These
cover paired announcements, persistence and acknowledgement, quiet legacy
history, late names, queued display time, failure preservation and rendered
card/graveyard screenshots. Debug simulator and unsigned iPhone Release builds
passed. All 17,061 pinned source files, the game ABI import and native Soul Link
shim checks are unchanged. Evidence and working save copies remain under
`.build/death-moments-*`. This is simulator/local-session validation, not a
physical two-phone/Agora acceptance run.

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

## Additional gift/static facts

BSL3 retains the existing 288-byte area/egg bitmaps and advertises the updated
peer capability. Older BSL1/BSL2 peers require an app update, so neither client
can report a complete link while silently missing gift/static deaths. BSE1
supplements each BSL3 state with a separate packet for each category. Each has
complete acquisition, loss and boxed-status bitmaps for up to 2,048 ordinals,
plus at most two rotating names. Maximum packet size is 990 bytes. Egg ordinals
keep all 2,048 existing positions. The existing total owned identity bound remains.

BSE1 facts require the current run, room binding and fresh peer challenges.
Both category baselines must arrive durably before the session reports paired.
Acquisitions and losses merge monotonically; party/boxed data is presentation
only. Losses still apply when received after offline play. Reconnect clears
transient team status and requires fresh baselines. The existing authenticated
server event journal carries every gift/static acquisition and death, including
checkpoint dependencies and owner-specific restore. The 864-byte legacy history
anchor remains unchanged for migration; it is not the new categories' authority.
