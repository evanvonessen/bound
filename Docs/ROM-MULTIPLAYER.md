# Bound-managed experimental multiplayer

Enable Experimental Multiplayer remains off by default. It activates supported
multiplayer games, presence, invitations, battles and replay controls. Ordinary
Bound friend accounts and video remain independent.

## Setup outside the ROM

Opening a multiplayer-marked game presents Bound's Server Saves menu. Refresh
loads the current account's catalog. New Game selects an existing friend, then
collects the player's name/character, rival name, difficulty, grinding mode,
randomizers, common cheats and nickname prompts. There is no solo/Nuzlocke choice.
The friend can be offline and sees the new shared run on their next refresh.
Their first load asks only for their own name/character.

The server commits settings and distinct seeds before Bound releases the ROM.
A fresh cartridge receives the external-setup ABI flag and personal profile;
the native initialization applies the configuration and advances through the
stock introduction to the bedroom without input. Bound hides the cartridge until
its settings-applied and safe-field acknowledgments arrive. The flag is cleared
then and is never reapplied to a restored game. A fresh run resets the core so it
cannot inherit another run's RAM.

Debug Preset uses Gary, Minimal Grinding, normal difficulty, default randomizers,
all five common cheats (Woyaopp, SO2Toxic, DexAll, TeamPreview, EZCatch), and no
nickname prompts. The player's identity remains personal. Existing in-field
friend interactions remain available; obsolete in-ROM setup/end/new-game commands
receive an unavailable acknowledgment and cannot create or delete server runs.

## Independent play and shared events

Each cartridge owns story flags, trainer defeats, badges, puzzles, inventory and
rewards. Peer progress does not gate walking, native battles or map transitions.
Remote avatars remain presentation only and do not create collision obstacles.
Local movement never waits for network acknowledgment.

The existing event journal uses account-origin/sequence identities with separate
receipt and application cursors. Sparse acknowledgments retain gaps, duplicates
are harmless, and missing events retry. World history affects presentation,
not the recipient's story flags or rewards. Soul Link's encounter slots, egg
ordinals and permanent death tombstones survive history replay; remote losses
apply at the next safe native field boundary. A disconnected phone cannot receive
an instantaneous remote faint.

## Saving and reconnecting

All marked-game persistence is server-owned. One server UUID identifies the
shared run and each account owns a separate snapshot head. Normal Pokémon saves,
automatic safe checkpoints and exit attempts update that same run. Working state,
ledger, timeline and transaction recovery live in RAM only. Old local saves are
preserved but ignored, and ordinary local/cloud save controls cannot import them.
Reopening downloads the account's latest confirmed snapshot and reconciles a
fixed shared-history target. No partner connection or repeated shared setup is
required. See [save structure and conflict rules](MULTIPLAYER-SAVE-PACKAGES.md).

Trades, friendly battles and cooperative battles retain mutual consent, bounded
invitations and recovery journals. The safe world state and transaction records
are included in server checkpoints. Disabling the feature closes services safely
and preserves recovery in the last confirmed server package.

## Visibility and verification

Presence persists independently of distance. Onscreen sprites use the same
world/camera projection as offscreen chevron, name and tile-distance indicators.
Different maps or incompatible elevations suppress rendering without deleting
presence. See [visibility findings and regression coverage](BOUND-MULTIPLAYER-VISIBILITY.md).
The 240×160 native viewport remains; expanding it needs ROM renderer work.

Local protocol, native ROM and Release checks do not establish real-device
network behavior or upstream Delta frame pacing. Two physical devices were not
available. Server deployment, long-distance movement, reconnects, battle/trade
recovery, video and frame-pacing acceptance remain pending.
