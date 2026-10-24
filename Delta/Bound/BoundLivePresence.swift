import Foundation
import SwiftUI

/// Small presence-only wire format. No RAM banks, input, save, camera, image or
/// progression payload. The receiver resolves the frame from its verified ROM.
struct BoundPresencePose: Codable, Equatable, Sendable {
    let mapGroup: Int
    let mapNumber: Int
    let elevation: Int
    var x: Double
    var y: Double
    let facing: Int
    let frameAddress: Int
    let palette: Data
    let flipX: Bool
    let flipY: Bool
    let priority: Int

    init?(reading: BoundPlayerStateReading) {
        guard reading.status == .live, let player = reading.player,
              let scene = player.scene, let address = scene.appearance.romAddress,
              scene.appearance.width == 16, scene.appearance.height == 32 else { return nil }
        mapGroup = player.mapGroup; mapNumber = player.mapNumber; elevation = player.elevation
        x = Double(scene.worldFoot.x); y = Double(scene.worldFoot.y)
        facing = ["South": 1, "North": 2, "West": 3, "East": 4][player.facing] ?? 0
        frameAddress = address; palette = scene.appearance.palette
        flipX = scene.appearance.flipX; flipY = scene.appearance.flipY; priority = scene.appearance.priority
    }

    var isValid: Bool {
        (0...255).contains(mapGroup) && (0...255).contains(mapNumber) && (0...15).contains(elevation)
        && x.isFinite && y.isFinite && (0...1_048_592).contains(x) && (0...1_048_592).contains(y)
        && (1...4).contains(facing) && (0...3).contains(priority) && palette.count == 32
        && (0x08000000...0x09FFFF00).contains(frameAddress)
    }

    func rendered(profile: BoundPlayerROMProfile, viewer: BoundPlayerState) -> BoundRecordedPlayerPose? {
        guard isValid, viewer.scene != nil, viewer.mapGroup == mapGroup,
              viewer.mapNumber == mapNumber, viewer.elevation == elevation,
              let tiles = profile.bytes(at: frameAddress, count: 256) else { return nil }
        return .init(mapGroup: mapGroup, mapNumber: mapNumber, elevation: elevation, x: x, y: y,
            appearance: .init(width: 16, height: 32, tiles: Data(tiles), palette: palette,
                              flipX: flipX, flipY: flipY, priority: priority, romAddress: frameAddress))
    }
}

/// Occupancy comes from the newest authenticated sample, never the delayed
/// drawing interpolation. A walking sprite occupies both ends of its step.
struct BoundPresenceCollision: Equatable, Sendable {
    let mapGroup: Int
    let mapNumber: Int
    let elevation: Int
    let current: BoundPlayerState.Point
    let previous: BoundPlayerState.Point

    init?(pose: BoundPresencePose) {
        guard pose.isValid else { return nil }
        let x = (pose.x - 8) / 16, y = (pose.y - 16) / 16
        let low = BoundPlayerState.Point(x: Int(floor(x)), y: Int(floor(y)))
        let high = BoundPlayerState.Point(x: Int(ceil(x)), y: Int(ceil(y)))
        guard [low.x, low.y, high.x, high.y].allSatisfy({ (-7...1030).contains($0) }),
              abs(high.x - low.x) + abs(high.y - low.y) <= 1 else { return nil }
        mapGroup = pose.mapGroup; mapNumber = pose.mapNumber; elevation = pose.elevation
        current = low; previous = high
    }
}

struct BoundPresencePacket: Codable, Equatable, Sendable {
    static let maximumBytes = 768
    let version: Int
    let rom: String
    let sender: UUID
    let receiver: UUID?
    let sequence: UInt64
    let time: TimeInterval
    let pose: BoundPresencePose?
    var withdrawn: Bool? = nil

    func encoded() -> Data? {
        guard let data = try? JSONEncoder().encode(self), data.count <= Self.maximumBytes else { return nil }
        return data
    }
    static func decode(_ data: Data) -> Self? {
        guard !data.isEmpty, data.count <= maximumBytes,
              let packet = try? JSONDecoder().decode(Self.self, from: data), packet.version == 1,
              packet.rom.count == 64, packet.sequence > 0, packet.time.isFinite,
              packet.time >= 0, packet.pose?.isValid ?? true else { return nil }
        return packet
    }
}

/// Main-actor, bounded receive buffer driven by a monotonic wall clock, never by
/// the viewer's emulated frame counter. Each transport/binding/restore gets a new
/// challenge; live samples must acknowledge it before granting any authority.
/// Server-retained presentation never participates in that handshake.
@MainActor
final class BoundLivePresenceSession: ObservableObject {
    let connectionCheck = BoundPresenceConnectionCheck()
    static let interval: TimeInterval = 0.05
    static let timeout: TimeInterval = 0.75
    static let visibilityGrace: TimeInterval = 60
    @Published private(set) var enabled = false
    @Published private(set) var connected = false
    @Published private(set) var status = "Connect to a friend, then enable live sprites on both devices."
    private(set) var epoch = UUID()
    private(set) var receivedPackets = 0
    private(set) var sentPackets = 0
    private(set) var rejectedPackets = 0
    private(set) var peerEpoch: UUID?
    private(set) var bufferedSamples = 0
    var demandChanged: (() -> Void)?
    var retainsNativeDialoguePose: (() -> Bool)?
    var presentationChanged: (() -> Void)?
    var needsReader: Bool { BoundMultiplayerFeatures.isEnabled && enabled && (connected || retainedPose != nil) }
    private var retainedPose: BoundPresencePose?
    private var retainedAt: TimeInterval?
    private var send: ((Data) -> Bool)?
    private var sequence: UInt64 = 0
    private var lastSent: TimeInterval?
    private var lastReceived: TimeInterval?
    private var lastSequence: UInt64 = 0
    private var lastSenderTime: TimeInterval?
    private var clockOffset: TimeInterval?
    private var retired: [UUID] = []
    private var proposedPeer: UUID?
    private var proposalAt: TimeInterval?
    private var localPose: BoundPresencePose?
    private var romVerified = false
    private var localAt: TimeInterval?
    private var settledLocal: BoundFriendWorldPosition?
    private var settledLocalAt: TimeInterval?
    private var readerStatus = "waiting"
    private var presentationCheck = BoundPresenceReaderCheck()
    private var lastPresentationAt: TimeInterval?
    private var lastPresentedPose: BoundPresencePose?
    private struct Sample { let time: TimeInterval; let pose: BoundPresencePose }
    private var samples: [Sample] = []

    func setEnabled(_ requested: Bool) {
        let value = requested && BoundMultiplayerFeatures.isEnabled
        guard value != enabled else { return }
        enabled = value; resetTimeline()
        updateStatus(); demandChanged?(); presentationChanged?()
        // Disabled peers explicitly withdraw their last sprite, best effort.
        if !value { publish(at: ProcessInfo.processInfo.systemUptime, force: true) }
    }
    func start(send: @escaping (Data) -> Bool) {
        guard BoundMultiplayerFeatures.isEnabled else { return }
        self.send = send; connected = true; resetTimeline(keepPresentation: true)
        updateStatus(); demandChanged?(); presentationChanged?()
    }
    func stop(keepPresentation: Bool = false) {
        localPose = nil
        if connected && enabled { publish(at: ProcessInfo.processInfo.systemUptime, force: true, withdrawn: !keepPresentation) }
        connected = false; send = nil; resetTimeline(keepPresentation: keepPresentation)
        updateStatus(); demandChanged?(); presentationChanged?()
    }
    func invalidateLocal() {
        resetTimeline(); updateStatus(); presentationChanged?()
    }
    func peerGone() {
        resetTimeline(keepPresentation: true); updateStatus(); presentationChanged?()
    }
    private func resetTimeline(keepPresentation: Bool = false) {
        if !keepPresentation { retainedPose = nil; retainedAt = nil }
        epoch = UUID(); sequence = 0; lastSent = nil
        localPose = nil; localAt = nil; settledLocal = nil; settledLocalAt = nil
        peerEpoch = nil; proposedPeer = nil; proposalAt = nil; clearPeer()
    }
    private func clearPeer() {
        samples.removeAll(keepingCapacity: true); bufferedSamples = 0
        lastReceived = nil; lastSequence = 0; lastSenderTime = nil; clockOffset = nil
    }
    private func restartHandshakeKeepingLocal() {
        let local = localPose, at = localAt
        resetTimeline(keepPresentation: true); localPose = local; localAt = at
    }

    /// A server snapshot is presentation only. It never refreshes collision,
    /// interaction freshness, or the authenticated peer handshake.
    func restorePresentation(_ data: Data, age: TimeInterval, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard enabled, romVerified, age.isFinite, age >= 0, age < Self.visibilityGrace,
              let packet = BoundPresencePacket.decode(data), packet.rom == BoundPlayerROMProfile.supportedSHA256,
              packet.withdrawn != true, let pose = packet.pose, retainedAt.map({ now - age >= $0 }) ?? true else { return }
        retainedPose = pose; retainedAt = now - age; presentationChanged?()
    }

    func consume(_ reading: BoundPlayerStateReading, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        readerStatus = reading.status.rawValue
        let previousPose=localPose
        localPose=needsReader && romVerified ? BoundPresencePose(reading:reading):nil
        if localPose==nil,needsReader,romVerified,retainsNativeDialoguePose?()==true,
           reading.status == .live,let player=reading.player,let previousPose,
           let position=BoundFriendWorldPosition(pose:previousPose),
           position.mapGroup==player.mapGroup,position.mapNumber==player.mapNumber,
           position.elevation==player.elevation,position.x==player.tile.x,position.y==player.tile.y,
           previousPose.facing==["South":1,"North":2,"West":3,"East":4][player.facing] {
            // Native field windows temporarily make the sprite frame unavailable.
            // Fresh, independently decoded world coordinates still prove this is
            // the same stationary player. Never retain across a move/fade/menu.
            localPose=previousPose
        }
        localAt = now
        if let position = localPose.flatMap(BoundFriendWorldPosition.init(pose:)) {
            if settledLocal.map({ position.occupiesSameTile(as: $0) }) != true { settledLocalAt = now }
            settledLocal = position
        } else { settledLocal = nil; settledLocalAt = nil }
        if localPose == nil { presentationChanged?() }
    }
    func setROMVerified(_ value: Bool) {
        guard value != romVerified else { return }
        romVerified = value; invalidateLocal()
    }

    func tick(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard BoundMultiplayerFeatures.isEnabled, connected, now.isFinite, now >= 0 else { return }
        if let proposalAt, now - proposalAt > 0.3 { proposedPeer = nil; self.proposalAt = nil }
        if let lastReceived, now - lastReceived > Self.timeout {
            // A new challenge prevents queued pre-timeout poses reviving a peer.
            restartHandshakeKeepingLocal()
            setStatus("Waiting for fresh friend presence"); presentationChanged?()
        }
        guard enabled else { return }
        publish(at: now)
    }
    private func publish(at now: TimeInterval, force: Bool = false, withdrawn: Bool = false) {
        guard connected, let send, force || lastSent.map({ now - $0 >= Self.interval - 0.0001 }) ?? true else { return }
        lastSent = now; sequence &+= 1
        let fresh = enabled && localAt.map { now - $0 <= 0.5 } ?? false
        var packet = BoundPresencePacket(version: 1,
            rom: romVerified ? BoundPlayerROMProfile.supportedSHA256 : String(repeating: "0", count: 64),
            sender: epoch, receiver: proposedPeer ?? peerEpoch, sequence: sequence, time: now, pose: fresh ? localPose : nil)
        if withdrawn || !enabled { packet.withdrawn = true }
        guard let data = packet.encoded() else { return }
        if send(data) { sentPackets += 1 }
        else { setStatus("Live sprite transport unavailable") }
    }

    func receive(_ data: Data, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard BoundMultiplayerFeatures.isEnabled, enabled, connected, now.isFinite, now >= 0,
              let packet = BoundPresencePacket.decode(data) else { rejectedPackets += 1; return }
        guard packet.sender != epoch, packet.receiver == nil || packet.receiver == epoch,
              !retired.contains(packet.sender) else { rejectedPackets += 1; return }
        guard packet.rom == BoundPlayerROMProfile.supportedSHA256 else {
            if packet.receiver == nil, peerEpoch != nil, packet.sender != peerEpoch {
                rejectedPackets += 1; return
            }
            retainedPose = nil; retainedAt = nil
            restartHandshakeKeepingLocal()
            setStatus(packet.rom == String(repeating: "0", count: 64) ? "Friend reader is not ready" : "Friend ROM is incompatible")
            presentationChanged?(); return
        }
        if packet.receiver == nil {
            // A delayed hello must not retire an already verified live peer.
            // Acknowledge one short-lived proposal; replace the peer only after
            // that sender acknowledges our current challenge in return.
            if packet.sender != peerEpoch, proposedPeer == nil {
                proposedPeer = packet.sender; proposalAt = now
            }
            if samples.isEmpty { setStatus("Checking friend session") }
            return
        }
        if peerEpoch != packet.sender {
            if let peerEpoch { retired.append(peerEpoch); if retired.count > 16 { retired.removeFirst() } }
            peerEpoch = packet.sender; clearPeer()
        }
        if proposedPeer == packet.sender { proposedPeer = nil; proposalAt = nil }
        guard packet.sequence > lastSequence, lastSenderTime.map({ packet.time > $0 }) ?? true else {
            rejectedPackets += 1; return
        }
        let offset = min(clockOffset ?? (now - packet.time), now - packet.time)
        guard now - packet.time - offset <= 0.3 else { rejectedPackets += 1; return }
        clockOffset = offset; lastSequence = packet.sequence; lastSenderTime = packet.time; lastReceived = now
        receivedPackets += 1
        if packet.withdrawn == true {
            retainedPose = nil; retainedAt = nil
            samples.removeAll(keepingCapacity: true); bufferedSamples = 0
            presentationChanged?(); return
        }
        guard let pose = packet.pose else {
            samples.removeAll(keepingCapacity: true); bufferedSamples = 0
            setStatus("Friend sprite unavailable or paused"); presentationChanged?(); return
        }
        retainedPose = pose; retainedAt = now
        if let previous = samples.last, !Self.continuous(previous.pose, pose)
            || packet.time - previous.time > 0.2 { samples.removeAll(keepingCapacity: true) }
        samples.append(.init(time: packet.time, pose: pose))
        if samples.count > 8 { samples.removeFirst(samples.count - 8) }
        bufferedSamples = samples.count; setStatus("Receiving live friend sprite")
    }

    /// Invitation admission uses fresh settled samples, never the interpolated
    /// rendering pose. A second sample prevents targeting a walking sprite.
    func interactionDiagnostic(at now:TimeInterval=ProcessInfo.processInfo.systemUptime)->String {
        "reader=\(readerStatus) local=\(localPose != nil) samples=\(samples.count) localAge=\(localAt.map { now-$0 } ?? -1) peerAge=\(lastReceived.map { now-$0 } ?? -1) settledAge=\(settledLocalAt.map { now-$0 } ?? -1)"
    }
    func interactionContext(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> BoundFriendInteractionSession.Context? {
        guard needsReader, romVerified, let peerEpoch, let localPose,
              let settledLocalAt, now >= settledLocalAt, now - settledLocalAt >= 0.05,
              let localAt, now >= localAt, now - localAt <= 0.2,
              let lastReceived, now >= lastReceived, now - lastReceived <= 0.2,
              samples.count >= 2, let last = samples.last,
              let local = BoundFriendWorldPosition(pose: localPose),
              let peer = BoundFriendWorldPosition(pose: last.pose),
              let previous = BoundFriendWorldPosition(pose: samples[samples.count - 2].pose),
              peer.occupiesSameTile(as: previous) else { return nil }
        return .init(localSession: epoch, peerSession: peerEpoch, local: local, peer: peer)
    }

    func pose(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> BoundPresencePose? {
        guard needsReader, let lastReceived, now >= lastReceived, now - lastReceived <= Self.timeout,
              let offset = clockOffset, let first = samples.first, let last = samples.last else {
            guard enabled, romVerified, let retainedAt, now >= retainedAt,
                  now - retainedAt < Self.visibilityGrace else { return nil }
            return retainedPose
        }
        let target = now - offset - 0.1
        if target <= first.time { return first.pose }
        for index in 1..<samples.count where target <= samples[index].time {
            let a = samples[index - 1], b = samples[index]
            guard Self.continuous(a.pose, b.pose), b.time - a.time <= 0.2 else { return nil }
            var pose = a.pose
            let fraction = (target - a.time) / (b.time - a.time)
            pose.x += (b.pose.x - pose.x) * fraction; pose.y += (b.pose.y - pose.y) * fraction
            return pose
        }
        // Freeze at the last confirmed position during a short packet gap.
        // The session deadline above and explicit withdrawals still remove it.
        return last.pose
    }
    func collision(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> BoundPresenceCollision? {
        // Each cartridge owns its puzzle objects and story state. A remote
        // avatar is presentation only, including while both peers are fresh:
        // occupying a doorway or a differently solved puzzle cannot block play.
        nil
    }

    private static func continuous(_ a: BoundPresencePose, _ b: BoundPresencePose) -> Bool {
        a.mapGroup == b.mapGroup && a.mapNumber == b.mapNumber && a.elevation == b.elevation
        && abs(a.x - b.x) + abs(a.y - b.y) <= 32
    }
    private func updateStatus() {
        setStatus(!enabled ? "Live sprites are off" : connected ? "Waiting for friend presence" : "Connect to your friend in Friends")
    }
    private func setStatus(_ value: String) { if status != value { status = value } }

    func observePresentation(pose: BoundPresencePose?, viewer: BoundPlayerState?, frameResolved: Bool,
                             visiblePixels: Int, at now: TimeInterval) {
        guard connectionCheck.recording else { return }
        presentationCheck.peerPoseAvailable = pose != nil
        presentationCheck.mapMatches = pose.flatMap { pose in viewer.map { $0.mapGroup == pose.mapGroup && $0.mapNumber == pose.mapNumber } }
        presentationCheck.elevationMatches = pose.flatMap { pose in viewer.map { $0.elevation == pose.elevation } }
        presentationCheck.frameResolved = frameResolved
        presentationCheck.visiblePixels = visiblePixels
        if visiblePixels > 0, let pose {
            presentationCheck.renderedTicks += 1
            if let previous = lastPresentedPose {
                if previous.x != pose.x || previous.y != pose.y { presentationCheck.movementChanges += 1 }
                if previous.facing != pose.facing { presentationCheck.facingChanges += 1 }
                if previous.frameAddress != pose.frameAddress || previous.flipX != pose.flipX || previous.flipY != pose.flipY {
                    presentationCheck.animationChanges += 1
                }
            }
            lastPresentedPose = pose
        } else { lastPresentedPose = nil }
        lastPresentationAt = now
    }

    func connectionReaderCheck(at now: TimeInterval) -> BoundPresenceReaderCheck {
        var check = presentationCheck
        check.romVerified = romVerified; check.status = readerStatus
        check.localPoseFresh = needsReader && localPose != nil && localAt.map({ now - $0 <= 0.5 }) ?? false
        check.peerConfirmed = peerEpoch != nil
        check.sent = sentPackets; check.received = receivedPackets; check.rejected = rejectedPackets; check.buffered = bufferedSamples
        check.lastReceiveAgeMS = lastReceived.map { Int(min(1_000_000, max(0, (now - $0) * 1000))) }
        if !needsReader || !check.localPoseFresh || lastPresentationAt.map({ now - $0 > 0.5 }) ?? true {
            check.visiblePixels = 0; check.frameResolved = false
        }
        return check
    }
}

struct BoundLivePresenceControls: View {
    @ObservedObject var session: BoundLivePresenceSession
    @AppStorage(BoundMultiplayerFeatures.key) private var experimentalFeaturesEnabled = false
    @AppStorage(BoundDeveloperFeatures.key) private var developerFeaturesEnabled = false
    var body: some View {
        if experimentalFeaturesEnabled && developerFeaturesEnabled { controls }
    }
    private var controls: some View {
        Section("Live Player Sprites") {
            Toggle("Show friend on map", isOn: Binding(get: { session.enabled }, set: { session.setEnabled($0) }))
                .accessibilityIdentifier("bound.live-presence-enabled")
            Text(session.status).font(.footnote).foregroundStyle(.secondary)
                .accessibilityIdentifier("bound.live-presence-status")
            BoundPresenceConnectionCheckControls(check: session.connectionCheck)
        }
    }
}
