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
type matchups and learnsets. Import save automatically exports the current GBA
session's battery save, applies its ability and learnset randomizer configuration,
and deletes the temporary export. See `Docs/RADICAL-RED-DEX.md` for provenance,
save validation and coverage. Disabling experiments removes both reference panels
and dismisses their keyboard, sheets and alerts without erasing preferences.
Reference menus and import alerts keep the companion panel's position and size.
Notes and Dex text editing can expand the panel to make room for the keyboard.

Bound Settings includes **Companion views** when experiments are enabled. Friend,
Notes, Types, Bosses and RR Dex each have a switch, all on by default. The Bound
button and mapped cycle action skip disabled views in portrait and landscape.
Choices persist on this device across app launches. Turning the current view off
selects the first enabled view; turning every view off hides the companion while
leaving the Bound button and pause-menu Settings available. Turning experiments
off restores the Build 13 Friend/Notes/Types cycle without erasing these choices.

The **Reference layouts** section in Bound Settings has independent four-way
selectors for **RR Dex** and **Boss View**. Both default to **Layout 1**, preserving
the original presentation. Choices persist on this device across app launches
and remain saved when experiments are disabled. Layout 2 surfaces more reference
information; Layout 3 rearranges the portrait area from either side of the Dynamic
Island down to the game screen. Layout 4 refines that arrangement with larger
touch targets, clearer content groups and expandable secondary details.
Layout choices do not change the ROM, guide data
version, selected encounter, selected species, or imported randomizer settings.

With experiments enabled, the pause-menu Fast Forward toggle (and mapped
Toggle Fast Forward action) is remembered on this device for each ROM and
restored when the game opens again, using its existing preferred speed. Holding
a momentary Fast Forward input does not change the saved toggle. Turning
experiments off stops an automatically restored fast-forward session without
erasing the saved choice; ordinary manual fast forward remains available.

The Friends sheet also shows a clipboard button beside a generated invite code
when experiments are enabled. It copies just the code, ready to paste.

The same opt-in adds account usernames (Library Settings), Remove Friend and
Jiggle actions, and restoration of sharing that was active before backgrounding.
Restoration fetches a fresh room token, checks account and room ownership, and
retries temporary failures with backoff. Manual stop, account changes, removal,
or disabling experiments cancel restoration. It does not start a previously
inactive connection. Jiggle reception requires notification permission and a
per-account device opt-in; sound and vibration follow the device's notification
settings. Its new RPC and Edge Function are additive; Build 13's friend, token,
moderation and account-deletion endpoints retain their existing definitions.

Library Settings also exposes Delta Sync and Sync Status for Dropbox. Google
Drive is not offered in Bound's sync settings; its pinned backend remains for
compatibility. A previously saved Google selection is retained but ignored, so
sync stays inactive until Dropbox is selected. Bound-owned OAuth configuration is required before sign-in can run. See
`Docs/BOUND-CLOUD-SYNC.md` for setup and validation limits. Opting out cancels
active sync operations and stops the coordinator after they drain, retaining the
selected service and authentication for later use.

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
