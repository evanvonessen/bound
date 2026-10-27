# Controller Multiview navigation

Controls includes **Allow Controller to Control Multiview**, off by default.
When enabled, a visible landscape Multiview takes the external controller's
D-pad, A/B and right stick. This is independent of the Controller Mode switch.
Portrait, hidden Multiview, and an unchecked switch retain gameplay controls.

| Input | Dex | Docs |
| --- | --- | --- |
| D-pad Down | Pokémon search, learnset search, learn-method tabs | Trainer row, Pokémon lineup |
| D-pad Up | Move focus back up | Return to trainer row |
| D-pad Left/Right | Change focused learn method, wrapping at either end | Previous/next trainer or lineup Pokémon, depending on focus |
| A | Open focused search or learnset; select a picker entry | Open boss selector or full team; select a picker entry |
| B | Close picker/search/expanded learnset | Close selector/details/full team |
| Right stick | Scroll the visible main or expanded view | Scroll the visible main or expanded view |
| Left trigger | Previous Multiview tab, wrapping | Previous Multiview tab, wrapping |

The left stick does not navigate Multiview. Held directional input repeats after
a short delay. Focus outlines follow the active control; Dex scrolls focused
controls into view. Pickers accept D-pad movement, A to choose, and B to return.

The left-trigger shortcut is supplied by the default mapping while this setting
is on and Multiview is active. Hiding Multiview restores its stock gameplay binding.
The right trigger retains the upstream standard r2 mapping (GBA Start); the right
bumper retains r1 (GBA R). The left bumper retains l1 (GBA L). Active focus capture
still routes its owned controls to Multiview. Existing saved mappings, including
an explicitly assigned Next View shortcut, remain authoritative.
Explicit None, Menu, and companion shortcuts remain available during capture.
The mapping editor displays the trigger defaults and can override them.

Opening Multiview releases previously held gameplay input before swapping the
receiver mapping. Hiding it swaps the mapping synchronously and restores any
still-held gameplay direction, without waiting for another layout pass.
Temporary repeated navigation stops on release, disconnect, capture ending,
or loss of eligibility. Gameplay receivers never receive the new focus actions
as game buttons.

Reset Settings to Default turns this switch off. Export All Config includes
its preference and the effective controller defaults.

Validation covers an unsigned Release iPhone build, hosted Dex/Docs views,
controller mapping and repeat behavior, settings reset/export, and the live
emulator input path through a virtual controller. Physical controller and
on-device behavior still require device testing.

History uses the former Connections screen identity. Its Connections tab requires
game Debug Mode; Run Timeline requires Enable Developer Tools independently.
D-pad Left/Right switches allowed history tabs, and the right stick scrolls the
visible feed or timeline. Back leaves the reference view as before. When a tab
becomes unavailable, the remaining allowed tab is selected. With neither allowed,
History is omitted from cycles and the current view falls back without rewriting
its saved placement. The DEBUG statepoints page is not a navigation choice.
