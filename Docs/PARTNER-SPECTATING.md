# Friends multiview screen sharing

Use **Screen Share** beneath a friend's name in Friends multiview or Account,
Friends, & Sync. Video appears only in Friends multiview, alongside the playable
local game. **Multiplayer** independently controls Nakama/Soul Link. Shared
account authentication does not couple the two connection switches.

The full-screen Watch Partner presentation and its buttons are removed. New
bundled cartridges omit its native action row. Historical exact ROM profiles
remain supported; command 11 stays reserved and receives an unavailable response
without connecting either session or presenting a modal.

## Video lifecycle

- A visible Friends surface consumes the bounded latest-frame mailbox.
- Hiding Friends, switching panels, or collapsing the Mac sidebar clears rendered
  pixels and stops presentation. Requested sharing still sends/receives video.
- Returning to Friends presents available fresh frames. Reconnection invalidates
  old pixels; Live requires a newly decoded frame and expires after three seconds.
- Backgrounding suspends media. Foreground retry requires the same account/room
  and prior connection intent. Closing the game stops or suspends its owned
  session through the existing interrupted-activity recovery path.
- Screen Share off stops the media session and clears reconnect intent/pixels.
  It leaves active multiplayer gameplay and its ownership/recovery intact.
- Account settings do not mount a video surface. A temporary settings-owned
  session is disposed when its owning context closes.

## Build 12 reference

Local history identifies source commit `80aa804e4c979285c4e3b01b490f5ad91f463acb`
as Bound 1.0 (12). Restore commit `635f5d725d41cafbcb27d23e7d97120df74e95ac`
explicitly names uploaded build 12 and has the identical tree
`dbbd899300f3e2796d6b9add013434f54ee15aca`. Its Friends companion displayed the
remote canvas beside gameplay and retained sharing while other panels were
selected. This change uses that source behavior as a reference. The archived
uploaded binary was not obtained or independently verified; this is not a claim
of exact binary or pixel-for-pixel reproduction.

Physical devices and live Agora/Nakama network interruptions still require
validation. Progression statepoints remain unfinished and uncertified.
