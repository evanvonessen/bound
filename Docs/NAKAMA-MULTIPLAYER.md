# Nakama multiplayer

Bound's authenticated experimental gameplay transport is Nakama, hosted on
Heroic Cloud. Supabase remains the account, friend authorization and run-lease
authority; existing paired save packages and Dropbox sync remain unchanged.
Agora is retained for explicitly requested friend video and spectating.

## Runtime

The app exchanges its current Bound session for a short-lived Nakama admission
ticket through `nakama-session`. The broker checks the live account, Auth
session, MFA, active friendship, both players' account status and block rules.
It repeats room authorization after contacting Nakama. Nakama verifies signed
tickets and binds their owner to its protected custom account ID.

Each client has one authenticated WebSocket to an authoritative room. Positions,
interactions, native battle bytes and admission renewals use distinct opcodes.
The server stamps the authenticated sender, enforces membership and lane limits,
and routes targeted battle messages only to their intended participant. The
client admits gameplay only from the selected authenticated partner.

Outgoing position updates use a bounded latest-value mailbox. Reliable messages
use a bounded queue; an overflow terminates the connection so battle recovery
can run. Encoding, sending and receiving run on the networking worker. Native
battle sends only enqueue bytes; no Agora pacing sleep runs on that frame path.
Emulator memory access stays on the completed-frame owner.

The room runs at 60 ticks per second and coalesces superseded positions each tick.
Nakama's WebSocket transport is TCP: marking a message unreliable does not give
it UDP delivery semantics. Positions can still be coalesced before sending;
messages already handed to TCP cannot bypass retransmission. This migration
does not assert a measured latency or frame-rate improvement.

The app renews membership through the broker every 40 seconds. Server membership
expires after at most 90 seconds without a valid signed renewal, independently
of the lifetime of the Nakama socket token. Missing configuration fails closed;
authenticated gameplay never falls back to Agora.

## Video and lifecycle

ROM-started multiplayer connects gameplay without starting the video engine or
capturing video frames. Opening partner video starts its separate authorization
and media connection. A video failure does not disconnect a healthy game room.
Ordinary manually selected friend sharing retains video. Gameplay and video
credentials renew independently.

Feature disable, backgrounding, sign-out and room changes fence old callbacks,
close gameplay channels and retain existing interrupted-battle recovery. The
paired-run ROM's intentional save, disconnect and recovery gates remain intact.
No account credentials, signed tickets or Nakama server secrets are written to
reports, save packages or source.

## More players and browsers

The server's signed member roster supports two through eight owners. Current
friend authorization, app sprite presentation, native battles and paired-save
rules still use two players. Larger rooms require an authorized group-membership
model and updates to those app/ROM rules; server capacity alone does not enable
more-than-two-player gameplay.

Browser clients can use Nakama's JSON socket protocol. Browser gameplay still
requires a compatible emulator, ROM bridge, input/audio/rendering and persistence.
The broker currently rejects browser Origin headers; a website needs an explicit
origin policy and its own integration tests before it is enabled.

## Deployment and validation

See [server runtime](../Backend/nakama/README.md) and
[session broker](../Backend/nakama-session/README.md). Configure a dedicated
Heroic Cloud title/runtime and matching private broker secrets before enabling
the service. The runtime deployment bundle contains server code only.

Focused checks cover ticket forgery/expiry, account and room binding, concurrent
room allocation, eight-member routing, lane limits, nonblocking client queues,
stale callback fencing, independent video and paired recovery boundaries. A
Release iPhone build and focused iOS integration tests are required before
publishing. Fixture or local-server results do not establish hosted delivery,
physical-device performance, browser play or multi-player ROM acceptance.
