# Reversible Bound settings visibility

The request "bring back the features i told you to hide that one time" refers
to this exact set. Set `BoundFeatureVisibility.simplifiedSettings` to false in
`Delta/Bound/BoundAppearancePreferences.swift` to restore the retained controls.
No preferences are erased. Saved arrangement/theme values remain in storage;
effective presentation uses Bound arrangement and Classic appearance while the
flag is true. Emulator registration and core/dependency identities are intact.

- Library → Settings and the in-game pause menu → Settings share one settings
  home. Controls retains the controller opacity slider and hides Skins and Touch
  & Haptics. Audio & Emulation hides Video and online multiplayer settings;
  Cores remains there with GBA as its sole visible entry. Other supported
  systems still import and play through their existing cores. Credits remains
  hidden. Interface & Companion hides legacy screen-arrangement, appearance,
  feedback and Picture in Picture controls.
- In-game presentation-only engine helpers and the top-left Buttons settings
  action remain hidden. Gameplay buttons and stored PiP/control preferences
  remain.
- ROM long-press: Game Settings hidden; other existing actions remain.

The shared home groups Interface & Companion, Controls, Audio & Emulation,
Account & Sync, General, and About. About Bound keeps the requested Delta
attribution; Source and licenses remains accessible there. All bundled
copyright and license terms are retained unchanged.
