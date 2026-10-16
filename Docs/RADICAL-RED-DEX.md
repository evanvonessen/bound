# Radical Red Pokédex

The experimental companion cycle is Friend → Notes → Types → Bosses → Dex.
With experiments off it remains Friend → Notes → Types. Native controller B
input is unchanged; this uses the existing Bound companion button.

The native card follows the boss guide's system backgrounds, purple tint,
rounded cells and portrait/landscape PiP presentation. Pokémon search updates
case-insensitive substring suggestions with each keystroke, like the upstream
dex. It also folds punctuation and accents. Autocorrection, capitalization and
predictive spell correction are disabled. Choosing a suggestion closes the
keyboard. The content scrolls for larger evolution families and form branches.
Weaknesses and learnsets open native sheets; editing and presentations use the
existing input cancellation and emulation pause/resume coordinator.

## Source and refresh

Primary source: <https://dex.radicalred.net/>, JwowSquared's
<https://github.com/JwowSquared/Radical-Red-Pokedex>.
Snapshot retrieved 2026-10-14 at revision
`488a0918194d567b5f7b02c396118d51fb9c81ce`.
The deployed site points to this repository's `master/data.js`. Its live data
matched the snapshot byte for byte (SHA-256
`04c9dc94b6a7e3d33f5dcb5e804487466e7a249f4d340cf19853d70f37596df9`).
Its deployed `src/abilityRandomizer.js` also matched the repository (SHA-256
`9ee88817ddab2ec77b3d23d49f97baf54a89b07f83f85d61ec21b4677ea1bc97`).

`PrototypeTools/import_radical_red_dex.py SOURCE_CHECKOUT OUTPUT_JSON` produces
`Delta/Bound/Resources/RadicalRedDex-v4.1.json`: 1,343 species/forms, 1,003 moves,
18 types, all supplied learnsets, evolution edges and form-specific sprites.
The source stat order (HP/Atk/Def/Spe/SpA/SpD) is normalized to
HP/Atk/Def/SpA/SpD/Spe. Empty TM/tutor slots (move 0) are omitted just as on the
site. Evolution descriptors cover every method present in the snapshot,
including stone, friendship, time, gender, known move, party, weather, nature,
mega and primal transformations. Data and pictures work offline.

Source credit is available in the card's information sheet. The upstream
repository has no license file at this revision. Its publication does not
establish redistribution rights to Pokémon artwork or other third-party
content; this remains part of the repository's existing public-distribution
licensing review in `AGENTS.md`. No claim of ownership is made.

## Save import

While playing **Radical Red 4.1 Normal**, tap **Import save**. Bound briefly pauses
the active GBA core and exports its live battery buffer to a unique temporary
`.sav`, reads it locally, then deletes the export and its directory on success
or failure. Only a core paused by this operation is resumed afterward; existing
search or sheet pauses remain under the presentation coordinator. The button
does not open Files. **Save loaded** repeats the operation to refresh the Dex.

Browsing the standard dex works before import. There is no network request,
ROM modification, or loading a save back into the emulator. Normal emulator
pause behavior can flush the managed battery file, but only the temporary
export is deleted. A new run must have a complete in-game save first: battery
export cannot commit unsaved game RAM or newly changed settings to save slots.
Only the trainer seed and randomizer flags are persisted, isolated per ROM.
Raw save bytes, trainer names, party/box data and filenames are not retained.
“Use standard dex” removes the imported configuration while retaining selection.

The parser accepts 112 KiB or 128 KiB raw saves, scans both fourteen-sector
rotating slots, verifies sector signatures and unique sector IDs, and selects
the latest complete consistent save index (including counter rollover).
An interrupted newer slot falls back to the previous complete slot. It rejects
incomplete saves, unsupported sizes, save-state data and Hardcore or
Restricted flags. The GBA save container does not identify the ROM version:
the active game must be RR 4.1 Normal. Sector checksums are not used because
the upstream dex's RR-specific format does not validate them; signature/slot
validation cannot prove every payload byte is intact.

Trainer ID at sector 0 + `0xA`, randomizer flags at sector 0 + `0xF2C`, Hardcore
at sector 4 + `0xDB2` bit `0x10`, Restricted at sector 4 + `0xDC3` bit `0x40`.
The native Normal-mode randomizer follows the upstream integer formulas and
ordered ability/move pools. Independent JavaScript reference vectors cover
zero, ordinary and maximum UInt32 seeds. As upstream, level-up and supplied
pre-evolution moves randomize; TM/HM, tutor, egg and event entries retain their
standard move. Unrandomized ability name variants are preserved. The source
stores Hidden/Primary/Secondary slots in that order; the card displays Primary,
Secondary, then the explicitly labeled Hidden ability.

Type matchups reflect dual typing, including 4×, ¼× and immunities. The sheet
explicitly labels these as type-only: abilities, held items and battle effects
can alter damage. Stats are base stats, rather than calculated party stats.

## Validation

Focused model checks cover complete dataset decoding and PNG data, live-search
narrowing, RR-specific types and evolutions, dual-type matchups, upstream
randomizer vectors, rotating/torn save slots, rejected formats/difficulties,
per-ROM persistence and clearing configuration. Export checks cover fresh data,
temporary-file cleanup after success, export failure and parse failure, and
preserving the managed save and previous Dex configuration. A native GBA bridge
test changes battery RAM after startup to prove capture reads the live buffer.
Hosted coordinator checks cover
the five-panel cycle, immediate off-gate fallback and native card rendering at
portrait and landscape PiP sizes. Native UI checks cover
progressive lowercase search, selection, pictures/stats/evolution, matchup and
learnset sheets, automatic current-game import, refresh, error recovery, persistence
and the three-panel off cycle. The Release iPhone build is required before
publication. Simulator/synthetic-save checks do not establish physical-device
coverage or validation with a player's real randomized RR save.

The UI test `testExperimentalRRDexSearchDetailsSaveImportPersistenceAndOffGate`
automatically imports the active `BoundRRDexDiagnostic` fixture game's synthetic
battery save, verifies Bulbasaur's randomized Limber/Friend Guard abilities,
refreshes it and checks gameplay resumes and configuration persists after relaunch.
Import the original generated diagnostic ROM with an appended `FLASH1M_V103`
marker as `BoundRRDexDiagnostic.gba`, then stage the synthetic save at that ROM's
managed battery path in the dedicated QA app before launching gameplay.
Generate the save with
`python3 PrototypeTools/generate_rrdex_save_fixture.py .build/fixtures/BoundRRDexSeedQA.sav`.
It contains only parser-test metadata and is never suitable for gameplay.

The separate landscape UI test waits for the app window to rotate. It reports
a skip if the runtime keeps its display in portrait, rather than treating the
GBA screen's naturally wide aspect ratio as proof of landscape. Hosted snapshots
also cover the native landscape panel's rendering.

Initial catalog validation: 71 model tests, 10 hosted companion tests and both portrait
UI regressions passed. The landscape rotation UI test skipped for the runtime
limitation above. The unsigned Release iPhone build and the 16,879-file pinned
source check passed. Every one of the 1,343 normalized forms was compared with
the live source for names, stats, typing, abilities, pictures, learnsets and
evolution targets. No player-owned save or physical device was used.

Current-save automation validation (2026-10-15): eight RR Dex model tests, the
native GBA bridge export/cleanup test, one-tap import/refresh/relaunch UI coverage,
and unsupported-save playback recovery pass. The unsigned Release iPhone build
passes. Runtime checks use an original generated diagnostic ROM and synthetic
battery metadata; no player-owned save or physical device was used.
