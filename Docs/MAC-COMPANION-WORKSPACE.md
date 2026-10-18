# Mac Companion workspace

The existing iOS app selects the workspace when `ProcessInfo.processInfo.isiOSAppOnMac` is true. This is the Designed for iPad app on Apple silicon, not a new macOS or Catalyst target. Ordinary iPhone and iPad launches retain the existing companion interface.

During gameplay, the workspace reserves a game viewport, a library/navigation sidebar, and a companion inspector. The inspector keeps the real friend video view mounted while switching between RR Dex, Boss, Notes, and Types. Library opens the existing game chooser; Game menu opens the existing pause, save-state, and fast-forward controls. Friends and Settings use the existing screens, with explicit pause/resume handling for direct presentation from the workspace.

RR Dex and Boss are the same `BoundRRDexView` and `BoundBossGuideView` used by iPhone, with their existing catalogs, per-game selections, separate saved layouts, and UI Version setting. They are hosted at normal size without the floating-PiP scaler or Dynamic Island inset. There is no separate Mac dataset or extra reference information. Notes and the type chart also reuse their existing views.

The coordinator continues to own one `FriendSharingSession`. Its remote view is mounted only once, and remote presentation stays enabled when a reference tab is selected. Account, transport, frame publication, backend schema, save synchronization, and emulator-core sources are unchanged. The desktop uses Delta's existing touch-only controller skin so keyboard/controller input and DS touchscreen input retain their normal receivers.

## Working alongside iPhone changes

This implementation is isolated on `codex/mac-companion-workspace`, based on `884e7c63`. Most UI code is in the new `BoundMacWorkspaceView.swift` and `BoundMacWorkspaceGeometry.swift`. Integration touches the companion coordinator, game view controller, and Xcode source membership. Merge those small integration sections deliberately if iPhone work changes the same files; the reference view implementations themselves are unchanged.

## Verification

Debug builds accept `--bound-ui-mac-workspace` to exercise the desktop layout on a dedicated iPad Simulator. Release builds ignore that override. `MacWorkspaceGeometryTests` covers layout containment and default routing; `MacWorkspaceUITests` covers the persistent friend viewport, existing reference controls, and menu/sheet navigation. The ordinary-iOS test runs without the override on a separate iPhone Simulator.

Verified on October 17, 2026: all three geometry tests passed, the forced-Mac workspace UI test passed on a dedicated iPad Simulator, and the ordinary-iPhone regression test passed on a separate iPhone Simulator. The workspace test checks all four reference tabs, the stable friend viewport, and animated gameplay after closing Friends, Settings, and the game menu. The final unsigned arm64 iOS Release build passed. Source-integrity verification confirmed all 16,879 pinned source files unchanged. Test results and build logs are retained locally under `.build/mac-workspace/`.

Simulator video fixtures verify presentation only. A real Apple-silicon Mac session, hardware keyboard/controller input, and a live two-account friend connection remain separate acceptance checks. An unsigned iOS Release build is not a signed Mac installation or TestFlight upload.
