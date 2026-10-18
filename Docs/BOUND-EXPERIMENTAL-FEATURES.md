# Bound feature baseline

Bound permanently provides the feature set that was previously available after
enabling Experimental Features. The old preference may exist on upgraded devices,
but it has no authority over app behavior. Fresh installs and upgrades behave
the same. The historical Build 13 branch remains available in Git history.

The Library settings button and pause-menu Settings tile open the same grouped
home: Interface & Companion, Controls, Audio & Emulation, Account & Sync,
General, and About. The shared screen has one navigation stack and one Done
action. Done and swipe dismissal run cleanup and close-time sync once; opening
a detail page does neither. In-game Settings returns to the paused menu.

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

UI Version remains a separate saved preference. Fresh installs use Option 1;
upgraded installations keep their saved choice. Option 2 retains its saved view
order, live read-only layout previews, and alternate companion behavior.
The `simplifiedSettings` visibility rules remain in effect, and Release builds
continue to hide unrelated upstream developer and experimental controls.

Account usernames, username-based friend operations, Jiggles, sharing restoration,
per-ROM remembered fast-forward, source attribution and the supported Dropbox
sync option are part of the normal Bound experience. Their existing safeguards
remain active: account and emulator state checks, notification permission and
per-account Jiggles choice, explicit sharing state, configured sync provider,
and cancellation/error handling. Sync stays inactive until a supported provider
is configured and selected. Existing unsupported provider selections remain
saved without being started.

Existing UI Version, button, view, ordering, Dex/Boss layout, per-ROM reference,
fast-forward, controller, account, sync, notification, ROM, save, note and
randomizer preferences remain intact when the old experimental preference is
missing, false or true. The obsolete key can remain as inert legacy data.

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
