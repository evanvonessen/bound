# Radical Red 4.1 Default boss guide

Enabled only by Library Settings → Enable Experimental Features. The existing
Bound companion button cycles Friend → Notes → Types → Bosses in both portrait
and landscape. With experiments off, the original three-panel cycle is retained.
Disabling experiments while Bosses is selected returns to Friend and dismisses
guide sheets; saved guide and baseline preferences remain intact.

The native card follows Bound's system backgrounds and purple accent. It shows
the selected fight, earliest documented level cap when available, Pokémon,
level/scaling rule, ability, held item, four move slots, and previous/next controls.
The boss selector searches names, locations, variants and Pokémon across every
category. Full team includes nature, base stats, EVs, speed examples, conditions,
and variant notes. Guide information contains all 18 level caps, the 97-entry
trainer order, factual interpretation notes, and the original source link.
Selection is local to each ROM. No ROM/save/progress inspection or live download
is performed; players choose the upcoming fight themselves.

Source: [Default Mode Bosses v4.1 (with EVs) - Radical Red](https://docs.google.com/spreadsheets/d/1ES8L4OzeJ8rCuMWFNvrDaZKArqR7Vys2ytFxjx2pbwE/edit),
source modified time `2026-08-26T21:06:11.998Z`, retrieved October 13, 2026.
The bundled snapshot contains factual team records; it does not copy spreadsheet
artwork, sprites, logos, layout, or the hidden Dex support tab. Source locations,
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
