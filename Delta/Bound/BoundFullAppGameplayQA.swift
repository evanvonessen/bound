#if DEBUG && targetEnvironment(simulator)
import Foundation
import UIKit
import DeltaCore

/// Explicit, simulator-only preparation/observation. All gameplay, input, friend
/// selection, save and load actions remain in Bound's ordinary UI and owners.
@MainActor
final class BoundFullAppGameplayQA {
    private struct Input: Decodable {
        let owner: UUID
        let key: String
        let token: String
        let peer: String
        let run: UUID
        let roomID: String
    }
    private final class MemoryStorage: BoundSessionStorage {
        var data: Data?
        init(_ data: Data? = nil) { self.data = data }
        func read() throws -> Data? { data }
        func write(_ data: Data) throws { self.data = data }
        func remove() throws { data = nil }
    }
    static let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("FullAppGameplayQA", isDirectory: true)
    static let current: BoundFullAppGameplayQA? = {
        guard ProcessInfo.processInfo.arguments.contains("--bound-ui-gameplay-qa") else { return nil }
        let input = root.appendingPathComponent("access-session.json")
        guard let bytes = try? Data(contentsOf: input) else { return nil }
        do { try FileManager.default.removeItem(at: input) }
        catch { return nil }
        guard bytes.count <= 16384, let value = try? JSONDecoder().decode(Input.self, from: bytes),
              ["A", "B"].contains(value.peer),
              let identity = try? AppCloudSession(owner: value.owner, key: value.key, token: value.token),
              identity.expiresAt.timeIntervalSinceNow > 1800 else { return nil }
        return try? BoundFullAppGameplayQA(value)
    }()

    let account: BoundFriendAccount
    let roomID: String
    private let peer: String
    private let run: UUID
    private var prepared = false
    private var timer: Timer?
    private weak var coordinator: BoundCompanionCoordinator?
    private weak var owner: GameViewController?
    private let observation = UIView()
    private var restores = 0
    private var lastSample: TimeInterval = 0
    private var samples: [[String: Any]] = []
    private var exportedReport = false
    private let started = ProcessInfo.processInfo.systemUptime

    private init(_ input: Input) throws {
        peer = input.peer; run = input.run; roomID = input.roomID
        // Access-only preparation, not a login/persistence test. The placeholder
        // cannot be sent to Auth: this QA account's refresh transport fails closed.
        let saved = BoundSavedSession(origin: BoundFriendAccount.origin, owner: input.owner,
            accessToken: input.token, refreshToken: "QA-access-only-no-refresh-capability")
        account = BoundFriendAccount(storage: MemoryStorage(try JSONEncoder().encode(saved)),
            deletionStorage: MemoryStorage(), automaticRefresh: false, configuration: { input.key },
            transport: { _ in throw BoundFriendError.unavailable })
        UserDefaults.standard.set(true, forKey: BoundPlayerStatePreferences.key)
    }

    func prepareLibrary() {
        guard !prepared else { return }; prepared = true
        do {
            let source = Self.root.appendingPathComponent("RadicalRed.gba")
            _ = try BoundPlayerROMProfile(rom: Data(contentsOf: source))
            let copy = Self.root.appendingPathComponent("Gameplay QA.gba")
            try FileManager.default.copyItem(at: source, to: copy)
            DatabaseManager.shared.importGames(at: [copy]) { games, errors in
                guard errors.isEmpty, let game = games.first else { return }
                game.managedObjectContext?.performAndWait {
                    // Only an empty, dedicated simulator receives a fixture seed.
                    guard !FileManager.default.fileExists(atPath: game.gameSaveURL.path) else { return }
                    try? Data(contentsOf: Self.root.appendingPathComponent("seed.sav"))
                        .write(to: game.gameSaveURL, options: .atomic)
                }
            }
        } catch { /* No fixture fallbacks, credential logging or ROM patching. */ }
    }

    func attach(_ coordinator: BoundCompanionCoordinator, owner: GameViewController) {
        self.coordinator = coordinator; self.owner = owner
        observation.isAccessibilityElement = true
        observation.accessibilityIdentifier = "bound.gameplay-qa-status"
        observation.accessibilityLabel = "Gameplay QA status"
        observation.accessibilityTraits = .staticText
        observation.frame = CGRect(x: 1, y: 1, width: 1, height: 1)
        observation.isUserInteractionEnabled = false
        owner.view.addSubview(observation)
        timer?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.observe() }
        }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
    }

    func didRestore() { restores += 1; observe() }

    private func observe() {
        guard let coordinator, let owner else { timer?.invalidate(); timer = nil; return }
        observation.frame = CGRect(x: owner.view.safeAreaInsets.left + 4, y: owner.view.safeAreaInsets.top + 4, width: 2, height: 2)
        owner.view.bringSubviewToFront(observation)
        let sharing = coordinator.sharing, display = coordinator.playerStateDisplay
        let reading = display.hud.reading
        let sample = sharing.livePresence.connectionCheck.snapshot?()
        var value: [String: Any] = ["peer": peer, "run": run.uuidString,
            "elapsed": ProcessInfo.processInfo.systemUptime - started,
            "reader": reading.status.rawValue, "frame": reading.frame,
            "core": owner.emulatorCore?.deltaCore.identifier ?? "none",
            "running": owner.emulatorCore?.state == .running,
            "joined": sharing.joined, "active": sharing.active,
            "transport": sample?.transport.kind.rawValue ?? "unavailable",
            "received": sample?.reader.received ?? 0,
            "videoReceived": sharing.receivedFrames, "renewals": sample?.tokenRenewals ?? 0,
            "visiblePixels": display.livePlayerOverlay.visiblePixels, "restores": restores]
        value["accountReady"] = coordinator.account.session != nil
        value["friendCount"] = coordinator.onboarding.rooms.count
        value["qaFriendListed"] = coordinator.onboarding.rooms.contains { $0.roomID.lowercased() == roomID.lowercased() }
        value["qaFriendLabel"] = coordinator.onboarding.rooms.first { $0.roomID.lowercased() == roomID.lowercased() }?.displayName
        value["friendsBusy"] = coordinator.onboarding.busy
        value["friendsMessage"] = coordinator.onboarding.message
        if let player = reading.player {
            value["map"] = [player.mapGroup, player.mapNumber]
            value["tile"] = [player.tile.x, player.tile.y]
            value["elevation"] = player.elevation
        }
        guard let bytes = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
        observation.accessibilityValue = String(data: bytes, encoding: .utf8)
        try? bytes.write(to: Self.root.appendingPathComponent("status.json"), options: .atomic)
        let now = ProcessInfo.processInfo.systemUptime
        if now - lastSample >= 1, samples.count < 1200 {
            samples.append(value); lastSample = now
            if let data = try? JSONSerialization.data(withJSONObject: samples, options: [.sortedKeys]) {
                try? data.write(to: Self.root.appendingPathComponent("observations.json"), options: .atomic)
            }
        }
        if !exportedReport, !sharing.active, !sharing.livePresence.connectionCheck.recording,
           sharing.livePresence.connectionCheck.sampleCount > 0,
           let report = try? sharing.livePresence.connectionCheck.export() {
            try? report.write(to: Self.root.appendingPathComponent("connection-report.json"), options: .atomic)
            exportedReport = true
        }
    }
}
#endif
