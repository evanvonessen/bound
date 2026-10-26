# Debug Connections view

A Debug game or Settings → Enable Developer Features adds Connections
as the fourth available iPhone companion view. If a custom configuration has
fewer than three other views, Connections follows those views. It uses the
existing timestamped connection feed, including background and foreground
events, and does not add gameplay or emulator tracing.

The companion button can reach it even when the saved split-button assignments
predate Connections. Its temporary assignment goes on the final split button;
the existing choices retain their relative order. Ordinary cycling and
controller navigation use the same available-view configuration.

This configuration is computed in memory. Turning Debug off restores the saved
order and assignments, including intentionally empty buttons and an explicitly
assigned Connections view. Switching games clears the previous game's Debug
state. The existing Mac Log tab and landscape Multiview Log tab remain available.

Validation on October 25, 2026: 74 focused companion, live-feed view and ROM
contract tests passed without failures or skips. They exercise the fourth-view
position, ordinary split-button cycling, both split-button styles, Debug
transitions, custom order, empty assignments and live feed scrolling/updates.
The UI-only source snapshot also passed the Release iPhone build, 17,061
pinned-source checks and 99 source/integration hashes plus two privacy manifests.
The final Release iPhone build also passed against current main with the native
text-ownership fix included.
Receipt: `.build/debug-feed-acceptance.xcresult`. Physical iPhone interaction
and live two-device validation remain pending.
