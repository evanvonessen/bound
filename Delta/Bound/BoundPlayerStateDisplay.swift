import Foundation
import UIKit
import SwiftUI
import DeltaCore

enum BoundPlayerStatePreferences {
    static let key = "bound.multiplayer.player-state.enabled.v1"
    static let didChange = Notification.Name("BoundPlayerStateDisplayChanged")
}

struct BoundPlayerStateSetting: View {
    @AppStorage(BoundPlayerStatePreferences.key) private var enabled = false
    var body: some View {
        Section {
            Toggle("Player State Display", isOn: $enabled)
                .accessibilityIdentifier("bound.player-state-enabled")
                .onChange(of: enabled) { _, _ in
                    NotificationCenter.default.post(name: BoundPlayerStatePreferences.didChange, object: nil)
                }
        }
    }
}

/// Composite the peer in the same presentation buffer as the native map, before
/// Delta copies that buffer. UIKit timers must never position a sprite over an
/// independently presented emulator frame. Core RAM and the source pixels are
/// unchanged after forwarding; only Delta's immutable output contains the peer.
final class BoundPresenceFrameCompositor: @unchecked Sendable {
    private let lock = NSLock()
    private var profile: BoundPlayerROMProfile?
    private var pose: BoundPresencePose?
    private var coreID: ObjectIdentifier?
    private var renderer: BoundPresenceVideoRenderer?
    private let followerCache=BoundNativeFollowerCache()
    #if DEBUG
    // QA installs this while the core is paused; callbacks stay on its owner.
    var observeFrame: ((BoundPlayerStateReading, BoundRecordedPlayerPose?, Int) -> Void)?
    #endif
    func configure(profile: BoundPlayerROMProfile?, pose: BoundPresencePose?, coreID: ObjectIdentifier? = nil) {
        lock.lock(); self.profile = profile; self.pose = pose; self.coreID = coreID; lock.unlock()
    }
    // Exclusively on the emulator owner, including after core restart replaces
    // its renderer. Retain the wrapper because bridges may weakly own delegates.
    func receive(_ core: EmulatorCore) {
        lock.lock(); let enabled = profile != nil && coreID == ObjectIdentifier(core); lock.unlock()
        let bridge = core.deltaCore.emulatorBridge
        if enabled {
            if let renderer, bridge.videoRenderer === renderer { return }
            guard let downstream = bridge.videoRenderer else { return }
            let wrapper = BoundPresenceVideoRenderer(core: core, downstream: downstream, compositor: self)
            renderer = wrapper; bridge.videoRenderer = wrapper
        } else if let renderer {
            if bridge.videoRenderer === renderer { bridge.videoRenderer = renderer.downstream }
            self.renderer = nil
        }
    }
    fileprivate func process(_ core: EmulatorCore, downstream: VideoRendering) {
        lock.lock(); let profile = self.profile, pose = self.pose, expected = coreID; lock.unlock()
        guard expected == ObjectIdentifier(core), let profile,let pose,
              var memory = BoundGBAMemorySnapshot.capture(readMemory: { core.deltaCore.emulatorBridge.readMemory?(at: $0, size: $1) }) else {
            downstream.processFrame()
            #if DEBUG
            // Frame-level QA must count a missing configured pose too; otherwise
            // a brief disappearance could evade its presentation observer.
            observeFrame?(.inactive(.waiting, "Presence frame unavailable"), nil, 0)
            #endif
            return
        }
        memory.followerObservation = .init(cache:followerCache,scope:.init(core:ObjectIdentifier(core),profile:ObjectIdentifier(profile),
            timeline:BoundVBABattleBridge.worldMovementTimeline()))
        let reading = profile.adapter.readPlayer(profile, memory: memory, frame: 1, includeScene: true, presentationOnly: true)
        func fade(_ actor:BoundRecordedPlayerPose?,passing:Bool)->BoundRecordedPlayerPose? {
            guard var actor else { return nil };actor.opacity=passing ? 0.45:1;return actor
        }
        let rendered = fade(reading.player.flatMap { viewer in pose.rendered(profile: profile, viewer: viewer) },passing:pose.passing==true)
        let follower=fade(reading.player.flatMap { viewer in pose.follower?.rendered(profile:profile,viewer:viewer,mapGroup:pose.mapGroup,mapNumber:pose.mapNumber) },passing:pose.passing==true)
        var pixels = 0
        if let scene = reading.player?.scene, let buffer = downstream.videoBuffer {
            let actors=(rendered.map { [$0] } ?? [])+(follower.map { [$0] } ?? [])
            let counts=Self.composite(actors,scene:scene,into:buffer) { downstream.processFrame() }
            pixels = rendered != nil ? counts.first ?? 0 : 0
        } else { downstream.processFrame() }
        #if DEBUG
        observeFrame?(reading, rendered, pixels)
        #endif
    }
    @discardableResult
    static func composite(_ pose: BoundRecordedPlayerPose, scene: BoundPlayerScene,
                          into buffer: UnsafeMutablePointer<UInt8>, present: () -> Void) -> Int {
        composite([pose],scene:scene,into:buffer,present:present).first ?? 0
    }
    @discardableResult
    static func composite(_ poses: [BoundRecordedPlayerPose], scene: BoundPlayerScene,
                          into buffer: UnsafeMutablePointer<UInt8>, present: () -> Void) -> [Int] {
        let images=BoundRecordedPlayerRasterizer.rgba(poses:poses,scene:scene)
        var saved: [(Int, UInt32)] = []
        saved.reserveCapacity(poses.reduce(0) { $0+$1.appearance.width*$1.appearance.height })
        var counts=Array(repeating:0,count:poses.count)
        for actor in BoundRecordedPlayerRasterizer.backToFront(poses) {
          let pose=poses[actor]
          let (rgba,origin)=images[actor]
          for y in 0..<pose.appearance.height {
            for x in 0..<pose.appearance.width {
                let src = (y * pose.appearance.width + x) * 4
                guard rgba[src + 3] != 0 else { continue } // Rasterizer clips/masks.
                let dst = ((origin.y + y) * 240 + origin.x + x) * 4
                let old = UInt32(buffer[dst]) | UInt32(buffer[dst+1]) << 8 | UInt32(buffer[dst+2]) << 16 | UInt32(buffer[dst+3]) << 24
                saved.append((dst, old))
                let alpha=Int(rgba[src+3])
                for (out,input) in [(0,2),(1,1),(2,0)] {
                    buffer[dst+out]=UInt8((Int(rgba[src+input])*alpha+Int(buffer[dst+out])*(255-alpha)+127)/255)
                }
                buffer[dst+3] = 255 // VBA-M BGRA8.
                counts[actor]+=1
            }
          }
        }
        present()
        for (dst, old) in saved.reversed() { for byte in 0..<4 { buffer[dst+byte] = UInt8(truncatingIfNeeded: old >> (byte * 8)) } }
        return counts
    }
}

private final class BoundPresenceVideoRenderer: NSObject, VideoRendering {
    weak var core: EmulatorCore?
    let downstream: VideoRendering
    weak var compositor: BoundPresenceFrameCompositor?
    init(core: EmulatorCore, downstream: VideoRendering, compositor: BoundPresenceFrameCompositor) {
        self.core = core; self.downstream = downstream; self.compositor = compositor
    }
    var videoBuffer: UnsafeMutablePointer<UInt8>? { downstream.videoBuffer }
    var viewport: CGRect { get { downstream.viewport } set { downstream.viewport = newValue } }
    func prepare() { downstream.prepare() }
    func processFrame() {
        autoreleasepool {
            if let core, let compositor { compositor.process(core, downstream: downstream) }
            else { downstream.processFrame() }
        }
    }
}

/// Configuration and latest-value mailbox are shared; decoder/tracker work is
/// serialized separately. Main never waits on the memory-copy/decoding lock.
final class BoundVBAPlayerStateProbe: @unchecked Sendable {
    let compositor = BoundPresenceFrameCompositor()
    private let lock = NSLock()
    private let workerLock = NSLock()
    private var generation: UInt64 = 0
    private var coreID: ObjectIdentifier?
    private var profile: BoundPlayerROMProfile?
    private var active = false
    private var sceneEnabled = false
    private var latest: BoundPlayerStateReading?
    private var workerGeneration: UInt64?
    private var frame: UInt64 = 0
    private var tracker = BoundPlayerPresenceTracker()
    private let followerCache=BoundNativeFollowerCache()

    func configure(coreID: ObjectIdentifier?, profile: BoundPlayerROMProfile?, active: Bool,
                   status: BoundPlayerStateReading.Status, detail: String, sceneEnabled: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        generation &+= 1
        self.coreID = coreID; self.profile = profile; self.active = active
        self.sceneEnabled = sceneEnabled
        latest = .inactive(status, detail)
    }

    func takeLatest() -> BoundPlayerStateReading? {
        lock.lock(); defer { lock.unlock() }
        let result = latest; latest = nil; return result
    }

    @discardableResult func receive(_ core: EmulatorCore) -> BoundPlayerStateReading? {
        guard core.deltaCore.identifier == "com.rileytestut.GBADeltaCore" else { return nil }
        compositor.receive(core)
        return receive(coreID: ObjectIdentifier(core)) { address, count in
            core.deltaCore.emulatorBridge.readMemory?(at: address, size: count)
        }
    }

    /// Also used by adapter tests with borrowed buffers. Production callers are
    /// exclusively Delta's frame callback, before the next VBA-M frame executes.
    @discardableResult func receive(coreID: ObjectIdentifier, readMemory: (Int, Int) -> Data?) -> BoundPlayerStateReading? {
        lock.lock()
        let epoch = generation, expectedID = self.coreID, currentProfile = profile, shouldRead = active
        let includeScene = sceneEnabled
        lock.unlock()
        guard shouldRead, coreID == expectedID, let currentProfile else { return nil }
        guard workerLock.try() else { return nil }
        defer { workerLock.unlock() }
        if workerGeneration != epoch {
            workerGeneration = epoch; frame = 0; tracker = BoundPlayerPresenceTracker()
        }
        frame &+= 1
        let reading: BoundPlayerStateReading
        if var memory = BoundGBAMemorySnapshot.capture(readMemory: readMemory) {
            memory.followerObservation = .init(cache:followerCache,scope:.init(core:coreID,profile:ObjectIdentifier(currentProfile),
                timeline:BoundVBABattleBridge.worldMovementTimeline()))
            reading = tracker.update(currentProfile.adapter.readPlayer(currentProfile, memory: memory, frame: frame, includeScene: includeScene))
        } else {
            reading = tracker.update(.inactive(.invalidMemory, "RAM capture unavailable", frame: frame))
        }
        lock.lock(); defer { lock.unlock() }
        guard generation == epoch, active, self.coreID == coreID else { return nil }
        latest = reading
        return reading
    }
}

@MainActor
final class BoundPlayerStateHUD: UIView {
    private(set) var reading = BoundPlayerStateReading.inactive(.disabled, "Player state display is off")
    private let label = UILabel()
    var text: String? { label.text }
    init() {
        super.init(frame: .zero)
        label.numberOfLines = 0
        label.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        addSubview(label)
        backgroundColor = UIColor.black.withAlphaComponent(0.84)
        layer.cornerRadius = 8; layer.masksToBounds = true
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityIdentifier = "bound.player-state"
        update(reading)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use init()") }
    override func layoutSubviews() {
        super.layoutSubviews()
        label.frame = bounds.insetBy(dx: 9, dy: 7)
    }
    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let inner = label.sizeThatFits(CGSize(width: max(1, size.width - 18), height: size.height))
        return CGSize(width: min(size.width, inner.width + 18), height: inner.height + 14)
    }
    @discardableResult func update(_ reading: BoundPlayerStateReading) -> Bool {
        self.reading = reading
        let rows: String
        if let player = reading.player {
            rows = "Map \(player.mapGroup):\(player.mapNumber)\nPosition \(player.tile.x), \(player.tile.y)\nFacing \(player.facing)"
        } else { rows = "Map —   Position —   Facing —\n\(reading.detail)" }
        let text = "VBA-M · \(reading.status.title)\n\(rows)"
        accessibilityValue = reading.status.rawValue
        // Idle frames keep the liveness clock fresh without repeatedly laying
        // out Bound's controller and companion hierarchy for identical text.
        guard label.text != text else { return false }
        label.text = text; accessibilityLabel = text
        setNeedsLayout()
        return true
    }
}

/// Read-only VBA-M scenes feed the local HUD, recording and presence renderer.
@MainActor
final class BoundPlayerStateDisplay {
    let probe = BoundVBAPlayerStateProbe()
    let hud = BoundPlayerStateHUD()
    let recordingSession = BoundRecordedPlayerSession()
    let recordedPlayerOverlay = BoundRecordedPlayerOverlay(frame: .zero)
    let livePlayerOverlay = BoundRecordedPlayerOverlay(frame: .zero)
    private weak var presence: BoundLivePresenceSession?
    private var friendName: () -> String = { "Friend" }
    private var currentReading: BoundPlayerStateReading?
    private weak var owner: UIViewController?
    private weak var core: EmulatorCore?
    private var profile: BoundPlayerROMProfile?
    private var profileStatus: BoundPlayerStateReading.Status = .checkingROM
    private var profileDetail = "Checking the loaded ROM"
    private var loadTask: Task<Void, Never>?
    private var stateObservation: NSKeyValueObservation?
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var lastFrameAt: TimeInterval?
    private var suspended = false

    init() {
        for name in [BoundPlayerStatePreferences.didChange, BoundMultiplayerFeatures.didChange, BoundDeveloperFeatures.didChange, BoundDirectionalFriendArrow.didChange, Settings.didResetNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if name == Settings.didResetNotification || !BoundMultiplayerFeatures.isEnabled {
                        if name == Settings.didResetNotification { self?.recordingSession.clear() }
                        else { self?.recordingSession.stop() }
                        self?.presence?.setEnabled(false)
                    }
                    self?.refreshPreference()
                }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.suspended = true; self?.refreshState() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.suspended = false; self?.refreshState() }
        })
        recordingSession.demandChanged = { [weak self] in self?.refreshPreference() }
        livePlayerOverlay.accessibilityIdentifier = "bound.live-player"
    }
    deinit {
        timer?.invalidate(); loadTask?.cancel()
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    func install(in owner: UIViewController) {
        self.owner = owner
        owner.view.addSubview(hud)
        refreshPreference()
    }
    func attachPresence(_ session: BoundLivePresenceSession, friendName: @escaping () -> String = { "Friend" }) {
        presence?.demandChanged = nil; presence?.presentationChanged = nil
        presence = session
        self.friendName = friendName
        session.setROMVerified(profile != nil && supportsCore, profile: profile)
        session.demandChanged = { [weak self] in self?.refreshPreference() }
        session.presentationChanged = { [weak self] in self?.renderLivePresence() }
        refreshPreference()
    }
    func bind(core: EmulatorCore?) {
        guard self.core !== core else { return }
        loadTask?.cancel(); loadTask = nil; stateObservation = nil
        self.core = core; profile = nil; profileStatus = .checkingROM
        presence?.setROMVerified(false)
        currentReading = nil; presence?.invalidateLocal()
        recordingSession.clear()
        profileDetail = "Checking the loaded ROM"
        lastFrameAt = nil
        if let core {
            let expectedID = ObjectIdentifier(core)
            stateObservation = core.observe(\.state, options: [.new]) { [weak self] _, _ in
                let update: @MainActor @Sendable () -> Void = { [weak self] in
                    guard let self, self.core.map(ObjectIdentifier.init) == expectedID else { return }
                    self.refreshState()
                }
                if Thread.isMainThread { MainActor.assumeIsolated { update() } }
                else { DispatchQueue.main.async(execute: update) }
            }
        }
        refreshPreference()
    }

    private var enabled: Bool { BoundMultiplayerFeatures.isEnabled && UserDefaults.standard.bool(forKey: BoundDeveloperFeatures.key) && UserDefaults.standard.bool(forKey: BoundPlayerStatePreferences.key) }
    private var supportsCore: Bool { core?.deltaCore.identifier == "com.rileytestut.GBADeltaCore" }
    var supportsRecording: Bool { supportsCore }
    private var needsScene: Bool { recordingSession.needsReader || presence?.needsReader == true }

    private func refreshPreference() {
        hud.isHidden = !enabled || !supportsCore
        timer?.invalidate(); timer = nil
        if enabled || needsScene, supportsCore {
            if profile == nil, loadTask == nil, profileStatus == .checkingROM { loadProfile() }
            let timer = Timer(timeInterval: needsScene ? 1.0 / 60 : 0.1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshDisplay() }
            }
            RunLoop.main.add(timer, forMode: .common); self.timer = timer
        }
        refreshState()
        owner?.view.setNeedsLayout()
    }

    private func loadProfile() {
        guard let core else { return }
        let coreID = ObjectIdentifier(core), url = core.game.fileURL
        loadTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { () -> (BoundPlayerROMProfile?, BoundPlayerStateReading.Status, String) in
                do {
                    let rom = try Data(contentsOf: url, options: .mappedIfSafe)
                    let profile = try BoundPlayerROMProfile(rom: rom)
                    profile.sceneAssets.prepareFriendRoutes(rom: profile.bytes)
                    return (profile, .waiting, "Waiting for the overworld")
                } catch BoundPlayerROMProfile.ProfileError.unsupportedROM {
                    return (nil, .unsupportedROM, "Requires the validated Radical Red 4.1 ROM")
                } catch { return (nil, .unavailable, "Cannot read the loaded ROM") }
            }.value
            guard !Task.isCancelled, let self, self.core.map(ObjectIdentifier.init) == coreID else { return }
            self.profile = result.0; self.profileStatus = result.1; self.profileDetail = result.2
            self.loadTask = nil
            self.refreshState()
        }
    }

    private func refreshState() {
        presence?.setROMVerified(profile != nil && supportsCore, profile: profile)
        let status: BoundPlayerStateReading.Status, detail: String
        var active = false
        if !enabled && !needsScene { status = .disabled; detail = "Player state display is off" }
        else if !supportsCore { status = .unavailable; detail = "Requires the VBA-M GBA core" }
        else if suspended { status = .paused; detail = "App is inactive" }
        else if core?.state == .paused { status = .paused; detail = "Playback is paused" }
        else if core?.state == .stopped { status = .stopped; detail = "Playback is stopped" }
        else if profile == nil { status = profileStatus; detail = profileDetail }
        else { status = .waiting; detail = "Waiting for consecutive overworld frames"; active = true }
        if status == .paused || status == .stopped { recordingSession.suspend() }
        if (status == .unsupportedROM || status == .unavailable), recordingSession.needsReader {
            recordingSession.unavailable(detail)
        }
        probe.configure(coreID: core.map(ObjectIdentifier.init), profile: profile, active: active, status: status, detail: detail,
                        sceneEnabled: needsScene)
        if !needsScene || status == .stopped || status == .unsupportedROM || status == .unavailable {
            lastFrameAt = nil; currentReading = nil
        }
        refreshDisplay()
    }

    func didLoadSaveState() {
        recordingSession.suspend(); recordingSession.stop(); presence?.invalidateLocal(); refreshState()
    }

    func refreshDisplay() {
        if let reading = probe.takeLatest() {
            if reading.status == .live, reading.player?.scene != nil {
                currentReading = reading
            } else if reading.status == .live,
                      reading.player?.mapGroup != currentReading?.player?.mapGroup || reading.player?.mapNumber != currentReading?.player?.mapNumber || reading.player?.elevation != currentReading?.player?.elevation {
                currentReading = nil
            } else if reading.status != .live && reading.status != .waiting && reading.status != .paused {
                currentReading = reading
            }
            let changed = hud.update(reading)
            recordingSession.consume(reading)
            presence?.consume(reading)
            recordedPlayerOverlay.show(pose: recordingSession.pose, scene: reading.player?.scene)
            if reading.status == .live, reading.player?.scene != nil, reading.frame > 0 {
                lastFrameAt = ProcessInfo.processInfo.systemUptime
            }
            if changed { owner?.view.setNeedsLayout() }
        } else if let lastFrameAt, ProcessInfo.processInfo.systemUptime - lastFrameAt > 0.5 {
            let stale = BoundPlayerStateReading.inactive(.waiting, "No recent emulated frames")
            // Keep the last verified camera/map for presentation while the
            // emulator stalls. Stale data cannot grant interaction authority.
            presence?.consume(stale)
            if hud.update(stale) { owner?.view.setNeedsLayout() }
            recordingSession.consume(stale); recordedPlayerOverlay.show(pose: nil, scene: nil)
        }
        renderLivePresence()
    }

    private func renderLivePresence() {
        let enabled = presence?.needsReader == true && !suspended && core?.state == .running
        probe.compositor.configure(profile: enabled ? profile : nil, pose: enabled ? presence?.pose() : nil,coreID:core.map(ObjectIdentifier.init))
        let now = ProcessInfo.processInfo.systemUptime
        if let presence, let reading = currentReading, reading.status == .live,
           let lastFrameAt, now - lastFrameAt < BoundLivePresenceSession.visibilityGrace, let profile, let viewer = reading.player {
            let pose = presence.pose(at: now), rendered = pose?.rendered(profile: profile, viewer: viewer)
            let target = BoundDirectionalFriendArrow.isEnabled ? pose.flatMap {
                profile.sceneAssets.friendRouteTarget(viewer: viewer, friendGroup: $0.mapGroup,
                    friendNumber: $0.mapNumber, friendInstance: $0.mapInstance, friendX: $0.x, friendY: $0.y)
            } : nil
            livePlayerOverlay.show(pose: rendered, scene: viewer.scene,
                offscreenName: target == nil ? nil : friendName(),
                drawsSprite: false, directionTarget: target)
            presence.observePresentation(pose: pose, viewer: viewer, frameResolved: rendered != nil,
                                         visiblePixels: livePlayerOverlay.visiblePixels, at: now)
        } else {
            livePlayerOverlay.show(pose: nil, scene: nil)
            presence?.observePresentation(pose: nil, viewer: nil, frameResolved: false, visiblePixels: 0, at: now)
        }
    }

    func layout(in owner: UIViewController, gameView: UIView) {
        if recordedPlayerOverlay.superview !== gameView {
            recordedPlayerOverlay.removeFromSuperview(); gameView.addSubview(recordedPlayerOverlay)
            recordedPlayerOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        }
        recordedPlayerOverlay.frame = gameView.bounds
        gameView.bringSubviewToFront(recordedPlayerOverlay)
        if livePlayerOverlay.superview !== gameView {
            livePlayerOverlay.removeFromSuperview(); gameView.addSubview(livePlayerOverlay)
            livePlayerOverlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        }
        livePlayerOverlay.frame = gameView.bounds
        gameView.bringSubviewToFront(livePlayerOverlay)
        guard !hud.isHidden else { return }
        let safe = owner.view.bounds.inset(by: owner.view.safeAreaInsets)
        let game = gameView.convert(gameView.bounds, to: owner.view).intersection(safe)
        let bounds = game.isNull || game.width < 100 || game.height < 80 ? safe : game
        let size = hud.sizeThatFits(CGSize(width: min(270, max(1, bounds.width - 16)), height: .greatestFiniteMagnitude))
        hud.frame = CGRect(x: bounds.maxX - size.width - 8, y: bounds.minY + 8, width: size.width, height: size.height)
        owner.view.bringSubviewToFront(hud)
    }

    func stop() {
        probe.compositor.configure(profile: nil, pose: nil)
        timer?.invalidate(); timer = nil
        loadTask?.cancel(); loadTask = nil
        stateObservation = nil; core = nil; profile = nil
        presence?.setROMVerified(false)
        currentReading = nil; presence?.invalidateLocal(); presence?.consume(.inactive(.stopped, "Playback is stopped"))
        livePlayerOverlay.show(pose: nil, scene: nil)
        recordingSession.clear(); recordedPlayerOverlay.show(pose: nil, scene: nil)
        probe.configure(coreID: nil, profile: nil, active: false, status: .stopped, detail: "Playback is stopped")
        hud.update(.inactive(.stopped, "Playback is stopped")); hud.isHidden = true
    }
}
