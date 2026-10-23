# Bundled development cartridge

The shared Bound target embeds `rrbin-integrated.gba` for iPhone and Designed for iPad on Mac.
`PrototypeTools/bundled-rom.json` pins the verified private release and its hash.
The ROM is deliberately absent from the public Bound source repository. The build
uses its ignored SHA256 cache, `BOUND_DEVELOPMENT_ROM` pointing to a private local
copy, an authenticated `gh` CLI, or `BOUND_ROM_GITHUB_TOKEN` in the private build
environment. Tokens are never committed. A Cloud build without the cached file
needs one of those authenticated inputs configured before it can archive.

The build checks the cartridge size and committed multiplayer contract and
verifies the copy inside the application. A missing or mismatched cartridge fails
the build. When advancing the ROM contract, update the pin to the newly verified
private release. The app itself requires no GitHub credentials.


On launch after the library starts, Bound verifies the included cartridge and
imports it if that content-addressed game is absent. Existing imports are not
replaced, and older cartridges and saves remain in the library. The latest
included entry is named `Multi Red <hash>`. No network access is needed on the
phone or Mac to install it. Removing the included game causes it to be imported
again on the next app launch. This is the private development distribution path.

Clear Saves is available in each game's Manage Save File menu and the paused-game
Resume/Restart prompt. It requires confirmation, closes that game's controllers,
serializes against sync/manual restore, and removes its battery/RTC, save states,
Soul Link package/ledger and matching battle recovery. The ROM, cheats, settings
and other games remain. Verified copies are retained outside sync under
Application Support/ROM Updates/Cleared Saves; these are recovery backups rather
than active saves. A database commit failure restores the removed files.

Clear Saves removes local recovery; it does not send an authenticated End Run to
a partner or delete their data. Use the ROM's End Soul Link/New Game flow when
ending a shared run with the server and partner is required.

Validation: `python3 PrototypeTools/test-bundled-rom.py` checks empty-cache and
cached builds, incompatible pins and incomplete resources. The integration suites
BoundROMUpdateTests and BoundROMUpdateLifecycleTests cover the bundled cartridge,
automatic import without duplicates, isolated save clearing, rollback and sync
serialization. Builds use the same iOS target on iPhone and Designed for iPad on Mac.
