# Reversible Bound settings visibility

The request "bring back the features i told you to hide that one time" refers
to this exact set. Set `BoundFeatureVisibility.simplifiedSettings` to false in
`Delta/Bound/BoundAppearancePreferences.swift` to restore the retained controls.
No preferences are erased. Saved arrangement/theme values remain in storage;
effective presentation uses Bound arrangement and Classic appearance while the
flag is true. Emulator registration and core/dependency identities are intact.

- Library Settings: Controller Skins hidden; controller opacity slider remains
  directly accessible. Touch & Haptics, Video, Online Multiplayer and Credits
  hidden. Cores remains, with GBA as its sole visible entry; other supported
  systems still import/play through their existing cores.
- In-game Bound Settings: arrangement, appearance, Touch Feedback and both
  feedback toggles, Picture in Picture, Controls, Reset Appearance/Feedback,
  and the top-left Buttons settings action hidden. The presentation-only engine
  helper is removed. Gameplay buttons and stored PiP/control preferences remain.
- ROM long-press: Game Settings hidden; other existing actions remain.

About is now "About Bound" with the requested Delta attribution. Emulation
backend is grouped under it. Duplicate Delta source/license link removed;
actual Source and licenses remains accessible, including from Library Settings.
All bundled copyright and license terms are retained unchanged.
