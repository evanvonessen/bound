# Bound feature baseline

Bound permanently provides the feature set that was previously available after
enabling Experimental Features. The old preference may exist on upgraded devices,
but it has no authority over app behavior. The historical Build 13 branch remains
available in Git history.

Interface & Companion has a new **Enable experimental features** checkbox, off
by default. It reveals UI Version, Landscape Options, Bound button style and
assignments, companion view choices/order, and RR Dex/Boss layout customization.
Controller Mode is available regardless of this checkbox. The checkbox only
controls settings visibility: disabling it preserves saved choices and keeps the
features themselves available. It uses a new key
(`bound.experimental-settings.enabled.v1`); the old runtime gate remains inert.

New installations use UI Option 2, Landscape Option 7, Bound button Option 4,
and Layout 12 for both RR Dex and Boss View. Button 1 (top) contains only Friend;
Button 2 (bottom) contains only Types, Bosses and RR Dex. Controller Mode remains
off by default, with Mode 1 preselected when enabled. Controller Mode 3 shows only
the Menu button at the bottom-left of the landscape screen. It retains the
landscape companion views and Arrange Views access through Menu. Existing saved
preferences take priority over these defaults.

In landscape Controller Modes 1 and 2, open **Menu → Arrange Views** to drag
the Friend, Multiview, and Menu buttons in Options 6/7, then tap **Done**.
Horizontal and vertical alignment gives a brief snap and haptic feedback;
continuing the drag releases the snap. Button positions save separately for
each controller mode. Mode 3 keeps its Menu button fixed at the bottom-left.
Controller-mode choices and button positions do not apply while the mode is
off or in portrait. Bound retains normal touch controls in those states even
with a wireless controller assigned. Reset Settings to Default clears these
positions and returns Controller Mode to Off with Mode 1 preselected.

Controller Mode is also available in **Settings → Controls**. The pause-menu
Controller Mode tile shows its current state and cycles **Off → Mode 1 → Mode 2
→ Mode 3 → Off**. Turning it on from Off always starts at Mode 1.

**Controller View Navigation** is a non-experimental, default-off setting in
Settings → Controls. Enabling it adds view actions to the controller mapping
editor: four-way scrolling, previous/next Pokémon or item, Select/Choose, Back,
Details, direct Dex/Bosses/Types selection, and explicit
Hide Friend/Hide Multiview actions. Existing toggle actions remain available.
These actions apply only to the active landscape controller view; disabled
Controller Mode, portrait, settings and arrangement editors do not receive them.
Select opens a Pokémon or boss chooser, previous/next changes its highlighted
candidate, and Select confirms it. Back closes the chooser or detail view.
Reset Settings to Default turns navigation off and resets custom mappings.

**Previous Multiview Tab** and **Next Multiview Tab** are separate controller
bindings available alongside Toggle Multiview, without enabling Controller View
Navigation. They follow the visible tab order and wrap from either end to the
other. Existing saved previous/next bindings retain their identifiers. An open
Dex or Boss sheet dismisses before the tab changes so gameplay resumes normally.

Controller mapping exposes Xbox Share and left/right thumbstick clicks (L3/R3).
**None** is an explicit saved binding, distinct from **Default**. **Menu** opens
Bound's pause menu. The physical Home button also offers **Overlay**, which
leaves its Apple system gesture enabled. Share keeps its system capture behavior
until assigned; assigning an action or None requests that iOS disable capture
for that button. Existing mapping identifiers remain compatible.

The Home button remains subject to Apple's system policy. On iOS 27 and later,
**Home Button Settings** opens Apple's controller settings for the user to allow
the app's Home-button handling. Bound cannot silently change that system setting.
See Apple's [Home button settings API](https://developer.apple.com/documentation/gamecontroller/gccontrollerhomebuttonsettingsmanager)
and [system gesture preference](https://developer.apple.com/documentation/gamecontroller/gccontrollerelement/preferredsystemgesturestate).

Companion navigation ignores left-stick directional bindings, including older
saved bindings; right-stick directions and ordinary buttons remain configurable.
L3 is a separate button and may still be assigned. Dex/Boss content and sheets
use scoped controller-event hosts so UIKit does not independently scroll or move
focus with the left stick. Touch scrolling remains available.

Controller mapping includes **Toggle Friend** and **Toggle Multiview** as normal
Game Actions, alongside the existing **Menu** mapping. These choices do not
require the experimental customization checkbox. In landscape Controller Mode
1, 2 or 3, Toggle Friend shows/hides the friend screen; Toggle Multiview
shows/hides the Option 6/7 panel without changing its selected view. The new
toggles are inactive in portrait, with Controller Mode off, or while arranging views.
Menu retains its existing pause/resume behavior. Bindings use the existing
per-player, per-system controller mapping storage.

Controller-toggle validation passed 53 focused integration checks and an unsigned
Release iPhone build. Tests cover mapping serialization and receiver delivery,
independent press/release handling, blocked holds and disconnect cleanup, both
controller layouts, portrait/mode-off/editing guards, and selected-tab preservation.
Physical Bluetooth/wired controllers were not exercised.

The Library settings button and pause-menu Settings tile open the same grouped
home: Interface & Companion, Controls, Audio, Account & Sync, and About.
Context Menu Previews and Pause Menu Button Placement are in Interface &
Companion and remain available without experimental features. About uses concise
source labels in Sources & Licenses while retaining attribution and bundled
license documents. Audio opens its controls directly; About includes the Game
Boy Advance core information. The shared screen has one navigation stack and one Done
action. Done and swipe dismissal run cleanup and close-time sync once; opening
a detail page does neither. In-game Settings returns to the paused menu.
The navigation area ends above the Done bar so long forms and embedded UIKit
menus can scroll their last content fully into view in either orientation.

`BoundCompanionSettingsModel` observes the existing preference stores without
creating an emulator or sharing session. Library edits update an existing
gameplay session, and in-game edits are available from the Library. Only active
emulation details and gameplay actions require the optional gameplay context.

The companion includes Friend, Notes, Types, Bosses and RR Dex. Users can disable
individual views, reorder them where supported, and keep the Bound button and
pause-menu Settings available even when every view is disabled. Button type,
assignments and companion layout choices persist across launches. RR Dex and
Boss View keep independent layout selections. Layout previews do not import a
live save or change the selected per-ROM reference. See
`Docs/RADICAL-RED-BOSS-GUIDE.md` and `Docs/RADICAL-RED-DEX.md` for details.

UI Version remains a separate saved preference. Fresh installs use Option 2;
upgraded installations keep their saved choice. Option 2 retains its saved view
order, live read-only layout previews, and alternate companion behavior.
The `simplifiedSettings` visibility rules remain in effect, and Release builds
continue to hide unrelated upstream developer and experimental controls.

Account usernames, username-based friend operations, Jiggles, sharing restoration,
per-ROM remembered fast-forward, source attribution and the supported Dropbox
sync option are part of the normal Bound experience. Their existing safeguards
remain active: account and emulator state checks, notification permission and
per-account Jiggles choice, explicit sharing state, configured sync provider,
and cancellation/error handling. Account & Sync supports Bound sign-in and sign-out
in both UI versions, independently of the customization checkbox. Sync stays inactive until a supported provider
is configured and selected. Existing unsupported provider selections remain
saved without being started.

Existing UI Version, button, view, ordering, Dex/Boss layout, per-ROM reference,
fast-forward, controller, account, sync, notification, ROM, save, note and
randomizer preferences remain intact when either experimental preference is
missing, false or true. The obsolete key can remain as inert legacy data; the new
checkbox changes only the visibility of interface customization controls.

## Default preset and account settings validation — October 19, 2026

Focused validation passed 110 integration checks, two Simulator UI checks, and
an unsigned Release iPhone build. The checks cover unset defaults, legacy and
explicit saved choices, customization visibility and relaunch persistence,
the default split-button assignments, Landscape Option 7 with touch controls,
and the Account & Sync sign-in form in both UI versions. Existing synthetic
account tests verify sign-out clears the session and stored credentials.

The separate PrototypeTests Swift package could not build because its existing
source list omits the account social types used by BoundFriendAccount. The iOS
integration target includes those types and passed. Physical-device behavior
and live sign-in/sign-out services were not exercised.

## Unified Settings validation — October 17, 2026

Focused validation passed 54 model tests, 72 integration tests, and four Simulator
UI tests. Coverage includes legacy preference values, shared settings propagation,
independent layouts, account/sharing cancellation, provider selection, per-ROM
fast-forward, both Settings entry points, Done/swipe dismissal, pause/resume,
rotation, background/foreground, relaunch persistence, and Layout 12 interactions.
An unsigned Release iPhone build also passed.

The live Dropbox OAuth test was skipped because disposable QA credentials were
not supplied. These checks establish model, Simulator, and build evidence; they
do not establish physical-device behavior, live network/account operations,
notification delivery, or Release UI runtime validation.

## Settings categories and scrolling follow-up — October 17, 2026

Audio now opens directly from the settings home, and About includes the Game Boy
Advance core information. The previous layout reproduced a last license-notice
row extending 12 points beneath the Done bar. The navigation area now reserves
space above that bar, and embedded UIKit destinations retain their bottom safe
area.

Focused Simulator checks passed for both settings entry points and for small-screen
portrait and landscape on iPhone SE (3rd generation, iOS 26.3). The latter checks
verify Audio, the About core destination, the last source notice, the final line
of the embedded license text, the Interface footer, and the layout gallery footer
are reachable above Done. An unsigned Release iPhone build passed. Physical-device
and live network/service behavior were not exercised by this follow-up.
