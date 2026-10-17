# Radical Red 4.1 Default boss guide

Enabled only by Library Settings → Enable Experimental Features. The existing
Bound companion button cycles Friend → Notes → Types → Bosses → Dex in both portrait
and landscape. With experiments off, the original three-panel cycle is retained.
Disabling experiments while Bosses is selected returns to Friend and dismisses
guide sheets; saved guide and baseline preferences remain intact.

The native card follows Bound's system backgrounds and purple accent. It shows
the selected fight, earliest documented level cap when available, Pokémon,
level/scaling rule, Pokémon picture and types, a compact row of HP, Attack,
Defense, Special Attack, Special Defense and Speed base stats, and four move slots with the source
guide's type icons and PhysA./SpA./Status damage categories. Ability and held-item
descriptions appear inline below the moves. The body scrolls inside the panel;
boss selection and previous/next controls stay visible. Changing Pokémon resets
the scroll position. Both reference panels fill the full-width area above gameplay
in Bound portrait, applying safe top clearance to their content.
The boss selector searches names, locations, variants and Pokémon across every
category. Full team includes nature, base stats, EVs, speed examples, conditions,
and variant notes. Guide information contains all 18 level caps, the 97-entry
trainer order, factual interpretation notes, and the original source link.
Selection is local to each ROM. No ROM/save/progress inspection or live download
is performed; players choose the upcoming fight themselves.

Choose boss uses a black background and white text, with an offline trainer icon
beside each name. Alternate teams and conditions are grouped in collapsible
encounters, including rival starter choices, weather teams and repeat phases.
Separate fights at different locations or explicitly numbered source encounters
stay separate. Search opens matching groups while keeping their alternatives
available; the currently selected encounter opens when the picker returns.
Unlabeled source alternatives retain neutral Team 1/2/3 labels.

**Bound Settings → Reference layouts → Boss View** chooses between eight saved
presentations independently of RR Dex. Layout 1 preserves the original card and
is the default. Layout 2 adds source-derived battle-condition badges, a tappable
opposing-team strip, ability and item description buttons, a typing-matchup
shortcut, location/variant context, and the trainer portrait. Layout 3 uses a
compact arrangement with controls beside the Dynamic Island, flexible scrolling
details and navigation at the game edge. Short panels keep content reachable by
scrolling, and landscape uses an enhanced compact card. Layout 4 refines that
portrait arrangement with larger team sprite buttons and paging arrows together
at the game edge, tappable ability/item cards, and an expandable Stats section
below the moves. Matchups use the selected
opponent's published typing, with explicit warnings that abilities, items and
battle conditions may change damage. They never use the player's randomized
save configuration.
Layout 5 adds a Moves/Stats button, labeled ability and held-item tiles,
and keeps the selected-team strip, island shortcuts and game-edge navigation
available while switching detail sections. That detail choice follows the
selected team member and returns to moves when choosing a different encounter.
The boss name has a chevron to make the encounter chooser easier to recognize.
Layout 6 keeps moves and base stats visible together, places battle-condition
badges beside the encounter heading, and fits all six team members between the
navigation arrows in the standard portrait panel. Smaller panels can scroll
without shrinking the touch targets. Ability/item descriptions and the island
shortcuts remain available.
Layout 7 starts from Layout 1, removes the version banner and bottom paging
controls, and places the trainer portrait, boss name and cap on one row. All team
sprites sit beside the selected Pokémon's name and level and select a member
directly. Full team moves to the right of the Dynamic Island (or a top toolbar
on other displays). Base-stat numbers use the source workbook's color scale;
the selected member's speed and boost rows appear immediately below, including
the workbook's player-level assumption for scaling encounters. Ability and item
descriptions remain inline, and the details scroll independently of team selection.
Panels too short for pinned controls scroll the whole card.
The source bar palette is red below 30, orange at 30–59, yellow at 60–89,
lime at 90–119, green at 120–149 and cyan from 150. The supplied screenshots
provide the higher bands; a live Kanto Leaders PDF export confirms the red
Speed 20 bar beside Geodude-A's orange Special Attack 30 bar.
Layout 8 moves the trainer portrait and encounter selector to the left of the
Dynamic Island, opposite Full Team. Its diagonal expand icon and label follow
the system text color: white in dark mode and black in light mode. Removing the
old encounter row lifts the Pokémon and details. The cap appears on the right
of the speed and conditional-level notes, and the selected Pokémon's nature
appears below its moves and above the ability and held item. Displays without
an Island keep both controls in a top toolbar.

Trainer icons are unchanged original game sprites from the
[Pokémon Showdown trainer directory](https://play.pokemonshowdown.com/sprites/trainers/).
Named main trainers use their portraits; generic opponents use trainer-class
icons, with an Ace Trainer fallback for custom characters without a matching
portrait. Paired opponents retain both icons where appropriate. Per-team
mappings, source URLs, SHA-256 hashes and PNG bytes are bundled in
`BoundBossReference-v1.json`; no icon download occurs during play. Rebuild them
with `PrototypeTools/import_radical_red_trainer_icons.py` using the catalog,
reference resource and a local cache directory. The existing artwork and public
distribution review still applies.

Source: [Default Mode Bosses v4.1 (with EVs) - Radical Red](https://docs.google.com/spreadsheets/d/1ES8L4OzeJ8rCuMWFNvrDaZKArqR7Vys2ytFxjx2pbwE/edit),
source modified time `2026-08-26T21:06:11.998Z`, retrieved October 13, 2026.
The 78 player-level assumptions were recovered from a fresh export on October 16,
2026; its hash is recorded separately as `speedContextSourceSHA256`. The baseline
snapshot and all its existing factual fields remain unchanged. The source's live
modified time was not reverified for this supplementary export.
The team snapshot contains factual records. Pictures, types, move categories,
and descriptions are resolved offline through the existing RR 4.1 Dex snapshot;
the guide's type icons come from PokeSprite. Source locations,
scaling levels (including the source's level 250 creator battle), speed examples,
empty move slots, alternate teams, partner teams and battle conditions are kept.
No additional per-Pokémon IVs or progression signals are invented.

Coverage: Kanto Leaders 8, Kanto Rematch 4, Johto Leaders 10, Rivals 17,
Team Rocket 14, Mini Bosses 42, Optional Bosses 10, Indigo League 11,
Postgame 51: **167 team variants and 792 Pokémon**. The source's Main and
Trainer Order tabs provide caps and progression. Trainer-order links are resolved
against the exported workbook's actual target rows; unsupported progression
variants retain their scaling level rule without a guessed cap.

Reproduce the data using an XLSX export of that exact source workbook:

```sh
python3 PrototypeTools/import_radical_red_bosses.py source.xlsx \
  --output Delta/Bound/Resources/RadicalRedDefaultBosses-v4.1.json \
  --source-modified-time 2026-08-26T21:06:11.998Z
```

The importer uses cached cell values and internal hyperlinks, verifies every
team block and all six stat rows, and rejects coverage drift. It never writes
to Google Sheets. The workbook hash and per-team source row remain in the JSON
for audit. A future source update requires reviewing the expected coverage and
rerunning data, gate, preference, orientation and Release checks.

## Reference details

`BoundBossReference-v1.json` supplements the existing team and Dex resources.
It records source revisions, exact override cells and icon hashes. Explicit form
aliases cover all 473 distinct boss species; no unknown form silently falls back
to another Pokémon. The reference never reads the Dex's imported randomizer save:
the opponent's listed ability, item and moves remain those of the Default guide.

Descriptions and canonical move metadata use the pinned RR Dex `data.js` at
`488a0918194d567b5f7b02c396118d51fb9c81ce`. Supplemental standard ability/item
mechanics and two missing move categories use the RR Showdown source at
`54955790eb71a0fb0a881850f1e8afed3bfe25bd`. The resource identifies those sources.
The descriptions cover every listed ability and item, including both alternatives
where the guide lists multiple abilities and the explicit No Item case.

All 3,104 populated type-icon formulas in the nine source team tabs were checked
against the unchanged source modification time above. The 53 encounter-specific
differences from generic Dex typing are retained per team, Pokémon and move slot,
including weather, abilities, masks and drives. The source leaves one Shell Smash
icon empty (`Postgame!M39`); that entry uses the pinned Dex's Normal type.
Seven typed Hidden Power labels and Disarming Voice/Supercell Slam have explicit
metadata overrides, with source cells recorded in the resource.

The 18 exact `misc/types/gen8` PNG icons are from PokeSprite revision
`c5aaa610ff2acdf7fd8e2dccd181bca8be9fcb3e`; its MIT license text is bundled in the
reference resource. Pokémon art is reused from the existing Dex resource.
The existing third-party/public-distribution licensing review still applies.

Focused checks cover all 792 Pokémon slots, every type/category/description,
regional forms, contextual move-type overrides and all 18 PNGs. Live UI checks
cover scrolling descriptions with pinned navigation, portrait width, and gameplay
resuming after Full team closes. Hosted renders exercise portrait and landscape
panel sizes; a Release iPhone build is required before publication.
