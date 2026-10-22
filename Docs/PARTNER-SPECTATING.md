# Partner battle spectating

Connect to a friend, open Friends, and choose **Watch partner** in Partner battle.
The full-screen view follows the friend's normal game video, including wild and
trainer battles. Close returns to Friends without stopping sharing. No new ROM
is required. This is view-only and adds no microphone or audio playback.

The viewer has its own retained canvas; it never reparents the companion canvas.
It continues receiving when the companion video is hidden or local gameplay is
paused. Live status requires a newly received frame after opening/reconnecting,
and expires after three seconds without another frame. Reconnects hide retained
pixels immediately. Stopping sharing or backgrounding closes the viewer.

The feature reuses authenticated, expected-peer video routing. It does not
control the partner's game, emulate another core, or alter Soul Link rules.
