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
        Section("Radical Red") {
            Toggle("Player state display", isOn: $enabled)
                .accessibilityIdentifier("bound.player-state-enabled")
                .onChange(of: enabled) { _, _ in
                    NotificationCenter.default.post(name: BoundPlayerStatePreferences.didChange, object: nil)
                }
            Text("Show the local map, position, facing and reader status during GBA playback. Supports the validated Radical Red 4.1 ROM.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

/// Configuration and latest-value mailbox are shared; decoder/tracker work is
/// serialized separately. Main never waits on the memory-copy/decoding lock.
final class BoundVBAPlayerStateProbe: @unchecked Sendable {
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
        if let memory = BoundGBAMemorySnapshot.capture(readMemory: readMemory) {
            reading = tracker.update(BoundPlayerStateDecoder.read(profile: currentProfile, memory: memory, frame: frame, includeScene: includeScene))
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
        for name in [BoundPlayerStatePreferences.didChange, BoundMultiplayerFeatures.didChange, Settings.didResetNotification] {
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
    func attachPresence(_ session: BoundLivePresenceSession) {
        presence?.demandChanged = nil; presence?.presentationChanged = nil
        presence = session
        session.setROMVerified(profile != nil && supportsCore)
        session.demandChanged = { [weak self] in self?.refreshPreference() }
        session.presentationChanged = { [weak self] in self?.livePlayerOverlay.show(pose: nil, scene: nil) }
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

    private var enabled: Bool { BoundMultiplayerFeatures.isEnabled && UserDefaults.standard.bool(forKey: BoundPlayerStatePreferences.key) }
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
                    return (try BoundPlayerROMProfile(rom: rom), .waiting, "Waiting for the overworld")
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
        presence?.setROMVerified(profile != nil && supportsCore)
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
        lastFrameAt = nil
        refreshDisplay()
    }

    func didLoadSaveState() {
        recordingSession.suspend(); recordingSession.stop(); presence?.invalidateLocal(); refreshState()
    }

    func refreshDisplay() {
        if let reading = probe.takeLatest() {
            currentReading = reading
            let changed = hud.update(reading)
            recordingSession.consume(reading)
            presence?.consume(reading)
            recordedPlayerOverlay.show(pose: recordingSession.pose, scene: reading.player?.scene)
            lastFrameAt = reading.frame > 0 ? ProcessInfo.processInfo.systemUptime : nil
            if changed { owner?.view.setNeedsLayout() }
        } else if let lastFrameAt, ProcessInfo.processInfo.systemUptime - lastFrameAt > 0.5 {
            let stale = BoundPlayerStateReading.inactive(.waiting, "No recent emulated frames")
            currentReading = stale; presence?.consume(stale)
            if hud.update(stale) { owner?.view.setNeedsLayout() }
            recordingSession.consume(stale); recordedPlayerOverlay.show(pose: nil, scene: nil)
            self.lastFrameAt = nil
        }
        let now = ProcessInfo.processInfo.systemUptime
        if let presence, let reading = currentReading, reading.status == .live,
           let lastFrameAt, now - lastFrameAt <= 0.5, let profile, let viewer = reading.player {
            let pose = presence.pose(at: now), rendered = pose?.rendered(profile: profile, viewer: viewer)
            livePlayerOverlay.show(pose: rendered, scene: viewer.scene)
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
