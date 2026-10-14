# Bound experimental features

Build 13 is preserved on the `build-13` branch at
`27d90bceb4d4c49219378ba0ef88f710e19b8113`.

The ROM library's Settings screen contains **Enable Experimental Features**.
It defaults to off and persists on this device. Off keeps the build 13 feature
set, with the switch as the only new control. Enabling it adds the Radical Red
4.1 Default boss guide as the fourth companion panel, after Friend, Notes and
Types. It does not restore older hidden Delta controls. The guide is bundled
for offline use, includes all nine boss tabs, and remembers the selected team
and Pokémon per ROM. See `Docs/RADICAL-RED-BOSS-GUIDE.md` for source coverage.

RRDex is the fifth panel, after Bosses. It includes the Radical Red 4.1 Normal
dex, live Pokémon suggestions, sprites, base stats, abilities, evolution methods,
type matchups and learnsets. A local battery-save import applies the ability and
learnset randomizer configuration. See `Docs/RADICAL-RED-DEX.md` for provenance,
save validation and coverage. Disabling experiments removes both reference panels
and dismisses their keyboard, sheets and importer without erasing preferences.

With experiments enabled, the pause-menu Fast Forward toggle (and mapped
Toggle Fast Forward action) is remembered on this device for each ROM and
restored when the game opens again, using its existing preferred speed. Holding
a momentary Fast Forward input does not change the saved toggle. Turning
experiments off stops an automatically restored fast-forward session without
erasing the saved choice; ordinary manual fast forward remains available.

The Friends sheet also shows a clipboard button beside a generated invite code
when experiments are enabled. It copies just the code, ready to paste.

Every new feature added after this switch must check
`BoundFeatureVisibility.experimentalFeaturesEnabled` before making its UI or
behavior accessible. Gate navigation destinations, actions and background work
as well as visible controls. Turning the switch off must immediately return to
the baseline behavior without erasing either baseline or experimental settings.

SwiftUI views should use
`@AppStorage(BoundExperimentalFeaturesPreferences.enabledKey)` with a false
default so the gate responds to changes. Use
`BoundExperimentalFeaturesPreferences().isEnabled` when changing the preference
so UIKit listeners receive `BoundExperimentalFeaturesPreferences.didChangeNotification`.
UIKit owners should observe that notification and re-evaluate the shared gate.
The existing `BoundFeatureVisibility.simplifiedSettings` flag remains separate.

For each experimental addition, verify access with the switch both on and off,
including turning it off while the feature is active. The preference tests
cover the off default, persistence, change notifications, and preservation of
baseline preferences. The focused Library UI test covers the real switch,
relaunch persistence, and retention of the existing settings presentation.
