import Foundation
import SwiftUI

/// Small presence-only wire format. No RAM banks, input, save, camera, image or
/// progression payload. The receiver resolves the frame from its verified ROM.
struct BoundPresencePose: Codable, Equatable, Sendable {
    var mapGroup: Int
    var mapNumber: Int
    let elevation: Int
    var x: Double
    var y: Double
    let facing: Int
    let frameAddress: Int
    let palette: Data
    let flipX: Bool
    let flipY: Bool
    let priority: Int
    var follower:BoundPresenceFollower? = nil
    var mapInstance:UInt64? = nil
    var passing:Bool? = nil
    var collisionTiles:UInt64? = nil
    var collisionElevation:Int? = nil
    enum CodingKeys:String,CodingKey {
        case mapGroup,mapNumber,elevation,x,y,facing,frameAddress,palette,flipX,flipY,priority
        case follower="f",mapInstance="m",passing="p"
        case collisionTiles="c",collisionElevation="z"
    }

    init?(reading: BoundPlayerStateReading) {
        guard reading.status == .live, let player = reading.player,
              let scene = player.scene, let address = scene.appearance.romAddress,
              scene.appearance.width == 16, scene.appearance.height == 32 else { return nil }
        mapGroup = player.mapGroup; mapNumber = player.mapNumber; elevation = player.elevation
        x = Double(scene.worldFoot.x); y = Double(scene.worldFoot.y)
        facing = ["South": 1, "North": 2, "West": 3, "East": 4][player.facing] ?? 0
        frameAddress = address; palette = scene.appearance.palette
        flipX = scene.appearance.flipX; flipY = scene.appearance.flipY; priority = scene.appearance.priority
        follower=BoundPresenceFollower(reading:reading);mapInstance=player.mapInstance
    }

    var isValid: Bool {
        (0...255).contains(mapGroup) && (0...255).contains(mapNumber) && (0...15).contains(elevation)
        && x.isFinite && y.isFinite && (-104...1_048_592).contains(x) && (-96...1_048_592).contains(y)
        && (1...4).contains(facing) && (0...3).contains(priority) && palette.count == 32
        && (0x08000000...0x09FFFF00).contains(frameAddress)
        && (follower?.isValid ?? true) && (mapInstance == nil || mapInstance!>0)
        && (collisionTiles.map(Self.validCollisionTiles) ?? true) && (collisionElevation.map{(0...15).contains($0)} ?? true)
    }
    static func validCollisionTiles(_ value:UInt64)->Bool {
        let p=(0..<4).map{Int((value>>(11*$0))&2047)-7}
        return value>>44==0 && p.allSatisfy{(-7...1030).contains($0)} && abs(p[0]-p[2])+abs(p[1]-p[3])<=2
    }

    func isSpatiallyComparable(to viewer: BoundPlayerState) -> Bool {
        viewer.mapGroup == mapGroup && viewer.mapNumber == mapNumber && viewer.elevation == elevation
    }

    func rendered(profile: BoundPlayerROMProfile, viewer: BoundPlayerState) -> BoundRecordedPlayerPose? {
        rendered(viewer: viewer, rom: profile.bytes, assets: profile.sceneAssets)
    }

    func rendered(viewer: BoundPlayerState, rom: (Int, Int) -> [UInt8]?,
                  assets: BoundPlayerSceneAssets) -> BoundRecordedPlayerPose? {
        // Elevation controls native collision and drawing priority, not whether
        // two players occupy the same visible map. Stairs, bridges and map
        // borders can put visible players on different elevations.
        guard isValid, viewer.scene != nil,
              let offset = assets.mapOffset(fromGroup: viewer.mapGroup, number: viewer.mapNumber,
                  toGroup: mapGroup, number: mapNumber, rom: rom),
              let tiles = rom(frameAddress, 256) else { return nil }
        return .init(mapGroup: viewer.mapGroup, mapNumber: viewer.mapNumber, elevation: elevation,
            x: x + Double(offset.x * 16), y: y + Double(offset.y * 16),
            appearance: .init(width: 16, height: 32, tiles: Data(tiles), palette: palette,
                              flipX: flipX, flipY: flipY, priority: priority, romAddress: frameAddress))
    }
}

/// The newest authenticated sample supplies current and departure tiles for
/// overlap recovery. The frame port makes only the current tile solid.
struct BoundPresenceCollision: Equatable, Sendable {
    let mapGroup: Int
    let mapNumber: Int
    let elevation: Int
    let current: BoundPlayerState.Point
    let previous: BoundPlayerState.Point

    init?(pose: BoundPresencePose) {
        guard pose.isValid else { return nil }
        if let packed=pose.collisionTiles {
            mapGroup=pose.mapGroup;mapNumber=pose.mapNumber;elevation=pose.collisionElevation ?? pose.elevation
            current = .init(x:Int(packed&2047)-7,y:Int((packed>>11)&2047)-7)
            previous = .init(x:Int((packed>>22)&2047)-7,y:Int((packed>>33)&2047)-7)
            return
        }
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

/// Preserve the 20 Hz schedule through display callback jitter. A late callback
/// publishes only the newest sample and skips missed slots; it never bursts.
struct BoundPresencePublicationCadence: Sendable {
    static let interval: TimeInterval = 0.05
    private var next: TimeInterval?
    mutating func reset() { next = nil }
    mutating func admit(at now: TimeInterval, force: Bool = false) -> Bool {
        guard now.isFinite, now >= 0,
              force || next.map({ now >= $0 - 0.0001 }) ?? true else { return false }
        if force || next == nil { next = now + Self.interval }
        else if let deadline = next {
            // A missed slot within the admission tolerance is also consumed;
            // repeated callbacks at this time must not publish a second sample.
            let skipped = floor(max(0, now - deadline + 0.0001) / Self.interval)
            next = deadline + (skipped + 1) * Self.interval
        }
        return true
    }
}

struct BoundPresencePresentationSample: Sendable {
    let time: TimeInterval
    let pose: BoundPresencePose
    let followerPresentation: BoundPresenceFollower?
    var presentation: BoundPresencePose {
        var value = pose; value.follower = followerPresentation; return value
    }
}

/// A bounded immutable copy crosses from the main-actor transport to the native
/// video owner. Sample its interpolation clock for each presented emulator frame;
/// a delayed UI timer must never freeze a moving peer between otherwise live frames.
/// This contains presentation evidence only, never collision or interaction authority.
struct BoundPresencePresentationSnapshot: Sendable {
    static let timeout: TimeInterval = 0.75
    static let visibilityGrace: TimeInterval = 60
    let needsReader: Bool, enabled: Bool, romVerified: Bool
    let lastPoseReceived: TimeInterval?, clockOffset: TimeInterval?
    let samples: [BoundPresencePresentationSample]
    let retainedPose: BoundPresencePose?, retainedAt: TimeInterval?
    let sceneProfile: BoundPlayerROMProfile?
    func pose(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> BoundPresencePose? {
        guard needsReader, let lastPoseReceived, now >= lastPoseReceived, now - lastPoseReceived <= Self.timeout,
              let offset = clockOffset, let first = samples.first, let last = samples.last else {
            guard enabled, romVerified, let retainedAt, now >= retainedAt,
                  now - retainedAt < Self.visibilityGrace else { return nil }
            return retainedPose
        }
        let target = now - offset - 0.1
        if target <= first.time { return first.presentation }
        for index in 1..<samples.count where target <= samples[index].time {
            let a = samples[index - 1], b = samples[index]
            // Discontinuity changes smoothing only. A confirmed position must
            // never disappear because a movement step exceeds two tiles.
            guard var pose = comparable(a.presentation, to: b.presentation), Self.continuous(pose, b.pose),
                  b.time - a.time <= 0.2 else { return b.presentation }
            let fraction = (target - a.time) / (b.time - a.time)
            pose.x += (b.pose.x - pose.x) * fraction; pose.y += (b.pose.y - pose.y) * fraction
            pose.follower=b.followerPresentation
            if pose.follower?.identity != last.followerPresentation?.identity {pose.follower=last.followerPresentation}
            // A missing follower observation is not a stationary observation.
            // Interpolate between its real samples on the trainer's existing
            // presentation clock, skipping brief reader gaps without adding
            // latency or turning borrowed presentation into collision authority.
            if let identity=pose.follower?.identity {
                let followers=samples.compactMap { sample -> (TimeInterval, BoundPresenceFollower)? in
                    guard let value=comparable(sample.pose,to:pose)?.follower,value.identity==identity else { return nil }
                    return (sample.time,value)
                }
                for (before,after) in zip(followers,followers.dropFirst()) where before.0<=target && target<=after.0 {
                    guard after.0>before.0,after.0-before.0<=0.3,
                          abs(before.1.x-after.1.x)+abs(before.1.y-after.1.y)<=32 else { break }
                    let weight=(target-before.0)/(after.0-before.0)
                    var follower=after.1
                    follower.x=before.1.x+(after.1.x-before.1.x)*weight
                    follower.y=before.1.y+(after.1.y-before.1.y)*weight
                    pose.follower=follower;break
                }
            }
            pose.passing=last.pose.passing
            return pose
        }
        // Freeze at the last confirmed position during a short packet gap.
        // The session deadline above and explicit withdrawals still remove it.
        return last.presentation
    }
    /// Smooth through real cardinal seams in one coordinate basis. A map ID
    /// change alone must not jump ahead of the normal interpolation delay.
    fileprivate func comparable(_ pose: BoundPresencePose, to target: BoundPresencePose) -> BoundPresencePose? {
        if pose.mapGroup == target.mapGroup && pose.mapNumber == target.mapNumber { return pose }
        guard let profile = sceneProfile,
              let offset = profile.sceneAssets.mapOffset(fromGroup: target.mapGroup, number: target.mapNumber,
                toGroup: pose.mapGroup, number: pose.mapNumber, rom: profile.bytes) else { return nil }
        var result = pose
        result.mapGroup = target.mapGroup; result.mapNumber = target.mapNumber
        result.mapInstance=target.mapInstance
        result.x += Double(offset.x * 16); result.y += Double(offset.y * 16)
        if var follower=result.follower {
            follower.x += Double(offset.x*16);follower.y += Double(offset.y*16)
            follower.current = .init(x:follower.current.x+offset.x,y:follower.current.y+offset.y)
            follower.previous = .init(x:follower.previous.x+offset.x,y:follower.previous.y+offset.y)
            result.follower=follower
        }
        return result
    }

    /// Compares successive peer samples, never distance from the local player.
    /// Discontinuous samples replace the interpolation buffer, not presence.
    fileprivate static func continuous(_ a: BoundPresencePose, _ b: BoundPresencePose) -> Bool {
        a.mapGroup == b.mapGroup && a.mapNumber == b.mapNumber && a.elevation == b.elevation && a.mapInstance==b.mapInstance
        && abs(a.x - b.x) + abs(a.y - b.y) <= 32
    }
}

/// Main-actor, bounded receive buffer driven by a monotonic wall clock, never by
/// the viewer's emulated frame counter. Each transport/binding/restore gets a new
/// challenge; live samples must acknowledge it before granting any authority.
/// Server-retained presentation never participates in that handshake.
@MainActor
final class BoundLivePresenceSession: ObservableObject {
    let movement=BoundWorldMovementSession()
    let connectionCheck = BoundPresenceConnectionCheck()
    static let interval = BoundPresencePublicationCadence.interval
    static let timeout = BoundPresencePresentationSnapshot.timeout
    static let visibilityGrace = BoundPresencePresentationSnapshot.visibilityGrace
    @Published private(set) var enabled = false
    @Published private(set) var connected = false
    @Published private(set) var status = "Join a ROM server"
    private(set) var epoch = UUID()
    private(set) var receivedPackets = 0
    private(set) var sentPackets = 0
    private(set) var rejectedPackets = 0
    private(set) var peerEpoch: UUID?
    private(set) var bufferedSamples = 0
    var demandChanged: (() -> Void)?
    var retainsNativeDialoguePose: (() -> Bool)?
    var presentationChanged: (() -> Void)?
    var peerWithdrew: (() -> Void)?
    var needsReader: Bool { BoundMultiplayerFeatures.isEnabled && enabled && (connected || retainedPose != nil) }
    private var retainedPose: BoundPresencePose?
    private var retainedAt: TimeInterval?
    private var send: ((Data) -> Bool)?
    private var sequence: UInt64 = 0
    private var publicationCadence = BoundPresencePublicationCadence()
    private var lastReceived: TimeInterval?
    private var lastPoseReceived: TimeInterval?
    private var peerPoseAvailable = false
    private var lastSequence: UInt64 = 0
    private var lastSenderTime: TimeInterval?
    private var clockOffset: TimeInterval?
    private var retired: [UUID] = []
    private var proposedPeer: UUID?
    private var proposalAt: TimeInterval?
    private var localPose: BoundPresencePose?
    private var romVerified = false
    private var admittedProfile: BoundGameProfile?
    private var sceneProfile: BoundPlayerROMProfile?
    private var localAt: TimeInterval?
    private var settledLocal: BoundFriendWorldPosition?
    private var settledLocalAt: TimeInterval?
    private var readerStatus = "waiting"
    private var presentationCheck = BoundPresenceReaderCheck()
    private var lastPresentationAt: TimeInterval?
    private var lastPresentedPose: BoundPresencePose?
    private typealias Sample = BoundPresencePresentationSample
    private var samples: [Sample] = []
    private var lastFollowerPose: BoundPresencePose?
    private var lastFollowerAt: TimeInterval?

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
        movement.reset()
        if !keepPresentation { retainedPose = nil; retainedAt = nil }
        epoch = UUID(); sequence = 0; publicationCadence.reset()
        localPose = nil; localAt = nil; settledLocal = nil; settledLocalAt = nil
        peerEpoch = nil; proposedPeer = nil; proposalAt = nil; clearPeer()
    }
    private func clearPeer() {
        movement.reset()
        samples.removeAll(keepingCapacity: true); bufferedSamples = 0
        lastFollowerPose = nil; lastFollowerAt = nil
        lastReceived = nil; lastPoseReceived = nil; peerPoseAvailable = false
        lastSequence = 0; lastSenderTime = nil; clockOffset = nil
    }
    private func restartHandshakeKeepingLocal() {
        let local = localPose, at = localAt
        resetTimeline(keepPresentation: true); localPose = local; localAt = at
    }

    /// A server snapshot is presentation only. It never refreshes collision,
    /// interaction freshness, or the authenticated peer handshake.
    func restorePresentation(_ data: Data, age: TimeInterval, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard enabled, romVerified, age.isFinite, age >= 0, age < Self.visibilityGrace,
              let packet = BoundPresencePacket.decode(data), packet.rom == admittedProfile?.romSHA256,
              packet.withdrawn != true, let pose = packet.pose, retainedAt.map({ now - age >= $0 }) ?? true else { return }
        retainedPose = pose; retainedAt = now - age; presentationChanged?()
    }

    func consume(_ reading: BoundPlayerStateReading, at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        readerStatus = reading.status.rawValue
        let previousPose=localPose
        localPose=needsReader && romVerified ? BoundPresencePose(reading:reading):nil
        if var pose=localPose,let native=movement.probe.read(),native.flags&1 != 0,native.instance==pose.mapInstance,
           native.group==pose.mapGroup,native.number==pose.mapNumber {
            let coordinates=[native.current.x,native.current.y,native.previous.x,native.previous.y]
            if coordinates.allSatisfy({(-7...1030).contains($0)}) {
                pose.collisionTiles=coordinates.enumerated().reduce(UInt64(0)){$0|UInt64($1.element+7)<<(11*$1.offset)}
                pose.collisionElevation=native.elevation;localPose=pose
            }
        }
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
    func setROMVerified(_ value: Bool, profile: BoundPlayerROMProfile? = nil) {
        let next = value ? (profile?.gameProfile ?? BoundGameProfiles.current) : nil
        let changed = next != admittedProfile
        admittedProfile = next; sceneProfile = value ? profile : nil
        guard value != romVerified || changed else { return }
        romVerified = value; invalidateLocal()
    }

    func tick(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard BoundMultiplayerFeatures.isEnabled, connected, now.isFinite, now >= 0 else { movement.reset();return }
        if let proposalAt, now - proposalAt > 0.3 { proposedPeer = nil; self.proposalAt = nil }
        if let lastReceived, now - lastReceived > Self.timeout {
            // A new challenge prevents queued pre-timeout poses reviving a peer.
            restartHandshakeKeepingLocal()
            setStatus("Waiting for fresh friend presence"); presentationChanged?()
        }
        guard enabled else { return }
        movement.update(movementContext(at:now),at:now)
        publish(at: now)
    }
    private func publish(at now: TimeInterval, force: Bool = false, withdrawn: Bool = false) {
        guard connected, let send, publicationCadence.admit(at: now, force: force) else { return }
        sequence &+= 1
        let fresh = enabled && localAt.map { now - $0 <= 0.5 } ?? false
        let outgoing=fresh ? localPose:nil
        var packet = BoundPresencePacket(version: 1,
            rom: romVerified ? (admittedProfile?.romSHA256 ?? String(repeating: "0", count: 64)) : String(repeating: "0", count: 64),
            sender: epoch, receiver: proposedPeer ?? peerEpoch, sequence: sequence, time: now, pose: outgoing)
        if packet.pose != nil { packet = BoundPresencePacket(version:packet.version,rom:packet.rom,sender:packet.sender,receiver:packet.receiver,sequence:packet.sequence,time:(now*1000).rounded()/1000,pose:packet.pose) }
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
        guard packet.rom == admittedProfile?.romSHA256 else {
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
            lastFollowerPose = nil; lastFollowerAt = nil
            movement.reset()
            retainedPose = nil; retainedAt = nil; peerPoseAvailable = false; lastPoseReceived = nil
            samples.removeAll(keepingCapacity: true); bufferedSamples = 0
            peerWithdrew?(); presentationChanged?(); return
        }
        guard let pose = packet.pose else {
            movement.reset()
            // A transient reader gap must not throw away presentation history
            // and snap the next sample ahead of its interpolation delay.
            // It immediately revokes interaction authority and never renews
            // the last valid pose's visibility deadline.
            peerPoseAvailable = false
            setStatus("Friend sprite unavailable or paused"); presentationChanged?(); return
        }
        var presentation = pose
        if pose.follower != nil {
            lastFollowerPose = pose; lastFollowerAt = now
        } else if let prior = lastFollowerPose, let at = lastFollowerAt,
                  now >= at, now - at <= 0.25,
                  prior.mapGroup == pose.mapGroup, prior.mapNumber == pose.mapNumber,
                  prior.mapInstance == pose.mapInstance {
            // A brief native reader/packet gap must not blink a confirmed
            // follower. Only presentation borrows it: raw samples below still
            // govern collision and interaction, and never refresh this deadline.
            presentation.follower = prior.follower
        } else {
            lastFollowerPose = nil; lastFollowerAt = nil
        }
        retainedPose = presentation; retainedAt = now; lastPoseReceived = now; peerPoseAvailable = true
        if let previous = samples.last,
           comparable(previous.pose, to: pose).map({ Self.continuous($0, pose) }) != true
            || packet.time - previous.time > 0.2 { samples.removeAll(keepingCapacity: true) }
        samples.append(.init(time: packet.time, pose: pose, followerPresentation: presentation.follower))
        if samples.count > 8 { samples.removeFirst(samples.count - 8) }
        bufferedSamples = samples.count; setStatus("Receiving live friend sprite")
    }

    /// Invitation admission uses fresh settled samples, never the interpolated
    /// rendering pose. A second sample prevents targeting a walking sprite.
    func interactionDiagnostic(at now:TimeInterval=ProcessInfo.processInfo.systemUptime)->String {
        "reader=\(readerStatus) local=\(localPose != nil) samples=\(samples.count) localAge=\(localAt.map { now-$0 } ?? -1) peerAge=\(lastReceived.map { now-$0 } ?? -1) settledAge=\(settledLocalAt.map { now-$0 } ?? -1)"
    }
    func interactionContext(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> BoundFriendInteractionSession.Context? {
        guard needsReader, romVerified, peerPoseAvailable, let peerEpoch, let localPose,
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

    func presentationSnapshot() -> BoundPresencePresentationSnapshot {
        .init(needsReader: needsReader, enabled: enabled, romVerified: romVerified,
              lastPoseReceived: lastPoseReceived, clockOffset: clockOffset, samples: samples,
              retainedPose: retainedPose, retainedAt: retainedAt, sceneProfile: sceneProfile)
    }
    func pose(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> BoundPresencePose? {
        presentationSnapshot().pose(at: now)
    }
    func collision(at now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> BoundPresenceCollision? {
        // Exact occupancy and overlap recovery have one owner: the frame
        // movement port. The legacy UI port must not add a second blocker.
        return nil
    }

    /// Retained/interpolated images never supply collision or social authority.
    func movementContext(at now:TimeInterval)->BoundWorldMovementSession.Context? {
        guard enabled,connected,romVerified,peerPoseAvailable,let peerEpoch,let own=localPose,let peer=samples.last?.pose,
              let key=own.mapInstance,key==peer.mapInstance,own.mapGroup==peer.mapGroup,own.mapNumber==peer.mapNumber,
              peer.collisionTiles != nil,let localAt,let lastPoseReceived,let lastReceived,
              now>=localAt,now-localAt<=0.2,now>=lastReceived,now-lastReceived<=0.2,
              now>=lastPoseReceived,now-lastPoseReceived<=0.2,
              let native=movement.probe.read(),native.flags&1 != 0,native.instance==key,
              BoundMovementElevation.compatible(native.elevation,peer.collisionElevation ?? peer.elevation) else{return nil}
        let ownTrainer=BoundMovementActor(current:native.current,previous:native.previous,elevation:native.elevation,kind:0,identity:0)
        guard let peerTiles=BoundPresenceCollision(pose:peer) else{return nil}
        let peerTrainer=BoundMovementActor(current:.init(peerTiles.current),previous:.init(peerTiles.previous),elevation:peerTiles.elevation,kind:0,identity:0)
        func follower(_ f:BoundPresenceFollower?)->[BoundMovementActor] {
            guard let f,f.isValid else{return []}
            return [.init(current:.init(f.current),previous:.init(f.previous),elevation:f.elevation,kind:1,identity:f.identity)]
        }
        return .init(local:epoch,peer:peerEpoch,instance:key,group:own.mapGroup,number:own.mapNumber,elevation:native.elevation,
            own:[ownTrainer]+follower(own.follower),other:[peerTrainer]+follower(peer.follower))
    }

    func followerInteractionContext(inbound:Bool=false,at now:TimeInterval=ProcessInfo.processInfo.systemUptime)->BoundFollowerInteractionSession.Context? {
        guard let c=movementContext(at:now),let own=localPose,let peer=samples.last?.pose,
              let trainer=(inbound ? c.other:c.own).first,
              trainer.current==trainer.previous,let f=(inbound ? own:peer).follower,
              f.current==f.previous else{return nil}
        let actor=BoundFriendWorldPosition(mapGroup:c.group,mapNumber:c.number,elevation:trainer.elevation,
            x:trainer.current.x,y:trainer.current.y,facing:(inbound ? peer:own).facing)
        let target=BoundFriendWorldPosition(mapGroup:c.group,mapNumber:c.number,elevation:f.elevation,x:f.current.x,y:f.current.y,facing:f.facing)
        guard actor.isFacing(target) else{return nil}
        return .init(localEpoch:epoch,peerEpoch:c.peer,mapInstance:c.instance,actor:actor,target:target,followerID:f.identity,generation:f.generation)
    }

    private func comparable(_ pose: BoundPresencePose, to target: BoundPresencePose) -> BoundPresencePose? {
        presentationSnapshot().comparable(pose, to: target)
    }
    private static func continuous(_ a: BoundPresencePose, _ b: BoundPresencePose) -> Bool {
        BoundPresencePresentationSnapshot.continuous(a, b)
    }
    private func updateStatus() {
        setStatus(!enabled ? "Live sprites are off" : connected ? "Waiting for friend presence" : "Join a ROM server")
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
