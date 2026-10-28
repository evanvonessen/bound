import Foundation
import SwiftUI

/// A game marker selects the server-save flow; ROM compatibility is verified
/// separately before any gameplay. New adapters can use the same marker.
extension Game {
    var boundUsesServerMultiplayer: Bool {
        if (gameSettings as? [String: Any])?["bound.multiplayer"] as? Bool == true { return true }
        guard type == .gba, let file = try? FileHandle(forReadingFrom: fileURL) else { return false }
        defer { try? file.close() }
        do {
            try file.seek(toOffset: 33_513_216)
            return try file.read(upToCount: 8) == Data("RRMPI001".utf8)
        } catch { return false }
    }
}

struct BoundMultiplayerSetupOptions {
    var name = "RED"
    var gender = 0
    var partnerName = "BLUE"
    var partnerGender = 0
    var rival = "BLUE"
    var difficulty = 0
    var minimalGrinding = false
    var species = 0
    var randomMoves = false
    var randomAbilities = false
    var cheats = false
    var nicknames = true
    var debug = false
    var deleteSaveOnGameOver = true
    var profile: BoundNakamaRunService.PlayerProfile { .init(name: name, gender: gender) }
    var partnerProfile: BoundNakamaRunService.PlayerProfile { .init(name: partnerName, gender: partnerGender) }
    static func nativeName(_ value: String) -> Data {
        var result = Data(repeating: 0xFF, count: 8)
        for (i, c) in value.utf8.prefix(7).enumerated() {
            result[i] = (65...90).contains(c) ? c - 65 + 0xBB : (97...122).contains(c) ? c - 97 + 0xD5 : (48...57).contains(c) ? c - 48 + 0xA1 : 0xAC
        }
        return result
    }
    var valid: Bool { profile.valid && partnerProfile.valid && BoundNakamaRunService.PlayerProfile(name: rival, gender: 0).valid }
    /// The shared run settings carry the choice across both players and devices.
    /// Older formats have no override. Invalid settings cannot authorize deletion.
    @MainActor static func deletesSaveOnGameOver(settings: Data) -> Bool? {
        guard BoundROMMultiplayerCoordinator.validSettings(settings) else { return nil }
        return settings[0] < 5 || settings[21] == 0
    }
    var settings: Data {
        if debug {
            var result = Data([5,1,1,0,0,0,0,0,0,0,1,0]) + Self.nativeName("Gary") + Data([1, deleteSaveOnGameOver ? 0 : 1])
            result.append(Data(repeating: 0, count: 10)); return result
        }
        var result = Data(repeating: 0, count: 32); result[0] = 5
        result[1] = minimalGrinding ? 1 : 0
        if difficulty > 0 { result[1 + difficulty] = 1 }
        result[5] = difficulty == 2 ? 1 : 0
        if species > 0 { result[5 + species] = 1 }
        result[8] = randomMoves ? 1 : 0; result[9] = randomAbilities ? 1 : 0
        result[10] = cheats ? 1 : 0; result[11] = nicknames ? 1 : 0
        result.replaceSubrange(12..<20, with: Self.nativeName(rival)); result[20] = debug ? 1 : 0
        return result
    }
}

struct BoundMultiplayerSetupView: View {
    @ObservedObject var coordinator: BoundROMMultiplayerCoordinator
    var openSettings: () -> Void
    var close: () -> Void
    @AppStorage(BoundMultiplayerFeatures.key) private var multiplayerEnabled = false
    @AppStorage(BoundDirectionalFriendArrow.key) private var directionalFriendArrow = true
    @AppStorage(BoundDamageCalculations.key) private var damageCalculations = true
    @State private var stage = 0
    @State private var room: FriendRoom?
    @State private var options = BoundMultiplayerSetupOptions()
    @State private var requestID = UUID()
    @State private var confirmingClear = false
    @State private var confirmingDiscard = false
    @State private var profileRun: UUID?
    var body: some View {
        NavigationStack {
            Form {
                Section("ROM Settings") {
                    Toggle("Enable Directional Friend Arrow", isOn: $directionalFriendArrow)
                        .accessibilityIdentifier("bound.directional-friend-arrow")
                        .onChange(of: directionalFriendArrow) { _, _ in
                            NotificationCenter.default.post(name: BoundDirectionalFriendArrow.didChange, object: nil)
                        }
                    Toggle("Enable Damage Calculations", isOn: $damageCalculations)
                        .accessibilityIdentifier("bound.damage-calculations")
                        .onChange(of: damageCalculations) { _, _ in coordinator.refreshROMPreferences() }
                }
                if let message = coordinator.serverMenuError { Text(message).foregroundStyle(.red) }
                if coordinator.hasUnconfirmedServerSave && !coordinator.observationRecoveryRequired {
                    Button("Retry Save") { Task { await coordinator.retryFinalServerSave() } }
                    Button("Use Last Server Save", role: .destructive) { confirmingDiscard = true }
                }
                if coordinator.observationRecoveryRequired {
                    Button("Retry") { Task { await coordinator.retryObservationRecovery() } }
                        .disabled(!multiplayerEnabled)
                        .accessibilityIdentifier("bound.multiplayer.retry-observations")
                } else if !multiplayerEnabled {
                    Text("Enable Experimental Multiplayer in Settings to play.")
                } else if stage == 0 {
                    Section("Server Saves") {
                        ForEach(coordinator.serverRuns) { run in
                            Button { Task { if await coordinator.selectServerRun(run.save_id) == false { profileRun = run.save_id; stage = 3 } } } label: {
                                VStack(alignment: .leading) {
                                    Text(coordinator.serverFriendName(roomID: run.identity.roomID))
                                    Text(String(run.updated_at.prefix(10)) + " · " + run.save_id.uuidString.prefix(8)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Button("New Game") { requestID = UUID(); stage = 1; coordinator.beginServerGameSetup() }
                        Button("Refresh", systemImage: "arrow.clockwise") { Task { await coordinator.refreshServerRuns() } }
                    }
                    Button("Clear Server Saves", role: .destructive) { confirmingClear = true }.disabled(coordinator.serverRuns.isEmpty)
                } else if stage == 1 {
                    Section("Choose a Friend") {
                        ForEach(coordinator.serverFriends) { value in
                            Button(value.displayName) { room = value; stage = 2 }
                        }
                        Button("Refresh", systemImage: "arrow.clockwise") { coordinator.refreshServerFriends() }
                    }
                } else {
                    Section("Your Player") {
                        TextField("Name", text: $options.name).textInputAutocapitalization(.characters).autocorrectionDisabled()
                        Picker("Character", selection: $options.gender) { Text("Boy").tag(0); Text("Girl").tag(1) }
                    }
                    if stage == 2 {
                        Section("Friend's Player") {
                            TextField("Name", text: $options.partnerName).textInputAutocapitalization(.characters).autocorrectionDisabled()
                            Picker("Character", selection: $options.partnerGender) { Text("Boy").tag(0); Text("Girl").tag(1) }
                        }
                        Section("Game") {
                            TextField("Rival's Name", text: $options.rival).textInputAutocapitalization(.characters).autocorrectionDisabled()
                            Picker("Difficulty", selection: $options.difficulty) {
                                Text("Normal").tag(0); Text("Easy").tag(1); Text("Hardcore").tag(2); Text("Restricted").tag(3)
                            }
                            Toggle("Minimal Grinding", isOn: $options.minimalGrinding)
                            Picker("Pokémon Randomizer", selection: $options.species) { Text("Off").tag(0); Text("Random").tag(1); Text("Scaled").tag(2) }
                            Toggle("Random Moves", isOn: $options.randomMoves)
                            Toggle("Random Abilities", isOn: $options.randomAbilities)
                            Toggle("Common Cheats", isOn: $options.cheats)
                            Toggle("Nickname Prompts", isOn: $options.nicknames)
                            Toggle("Debug Mode", isOn: $options.debug)
                            if options.debug {
                                Toggle("Game Over on Party Wipe", isOn: $options.deleteSaveOnGameOver)
                                    .accessibilityIdentifier("bound.multiplayer.delete-on-game-over")
                            }
                        }
                    }
                    Button("Start Game") {
                        Task {
                            if let profileRun { _ = await coordinator.selectServerRun(profileRun, profile: options.profile) }
                            else if let room { await coordinator.createServerRun(room: room, options: options, requestID: requestID) }
                        }
                    }.disabled(stage == 2 ? !options.valid : !options.profile.valid)
                }
                if coordinator.serverMenuBusy { ProgressView() }
            }
            .safeAreaInset(edge: .bottom) {
                Text("RRv4.1M Build #\(coordinator.installedROMBuild.map(String.init) ?? "—")")
                    .font(.caption).foregroundStyle(.gray)
                    .frame(maxWidth: .infinity).padding(.vertical, 8)
                    .background(.bar)
                    .accessibilityIdentifier("bound.multiplayer-rom-build")
            }
            .disabled(coordinator.serverMenuBusy)
            .navigationTitle(stage == 0 ? "Multiplayer" : stage == 1 ? "Choose a Friend" : "New Game")
            .toolbar {
                ToolbarItem(placement: .primaryAction) { Button("Settings", action: openSettings) }
                ToolbarItem(placement: .cancellationAction) {
                    if stage > 0 { Button("Back") { stage = 0; profileRun = nil } }
                    else { Button("Close", action: close).disabled(coordinator.observationRecoveryRequired) }
                }
            }
        }
        .interactiveDismissDisabled()
        .confirmationDialog("Clear all server saves for this game?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Delete Shared Saves", role: .destructive) { Task { await coordinator.clearServerRuns() } }
        } message: { Text("This permanently deletes both players' progress in these runs. Your friends will lose access too.") }
        .confirmationDialog("Discard unconfirmed progress?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Use Last Server Save", role: .destructive) { coordinator.discardUnconfirmedServerSave(); stage = 0 }
        } message: { Text("Progress since the last confirmed server save will be lost.") }
        .task { await coordinator.refreshServerRuns() }
    }
}
