# Multiplayer ROM distribution

Bundling has been retired. Follow [RRv4.1M server updates](SERVER-ROM-DISTRIBUTION.md).
Bound app archives must contain no multiplayer cartridge. The retired bundler
fails closed; the Xcode cleanup step removes stale resources only from the build
product. No GitHub ROM token or local cartridge is needed for an app release.

`PrototypeTools/bundled-rom.json` retains its historical filename solely as
exact-ROM compatibility metadata. It does not authorize embedding or importing
a cartridge. Game builds publish through GitHub Actions to private Linode storage;
developer-approved users confirm downloads in Bound Settings.
