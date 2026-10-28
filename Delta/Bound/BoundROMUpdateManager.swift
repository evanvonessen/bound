import Foundation
import Combine
import CoreData
import UIKit
import DeltaCore
import Harmony

@MainActor
final class BoundROMUpdateManager: ObservableObject {
    static let shared = BoundROMUpdateManager()
    static let saveClearBegan = Notification.Name("BoundSaveClearBegan")
    @Published private(set) var clearingSaveGameIDs: Set<String> = []
    struct GameChoice: Identifiable, Sendable { let id: String; let name: String }
    @Published private(set) var enrollmentChoices: [GameChoice] = []
    @Published private(set) var needsGameSelection = false
    private var enrollmentGameID: String?
    private var enrollmentSelectionMade = false
    @Published private(set) var suggestedEnrollmentGameID: String?
    @Published private(set) var canChooseEnrollmentGame = true
    private var stagedBookmark: Data?
    private var stagedName: String?
    private var configuration = UUID()
    private var checkAgain = false
    @Published private(set) var folderName: String?
    @Published private(set) var status = "Choose an iCloud folder."
    @Published private(set) var isEnabled = false
    @Published private(set) var isChecking = false
    @Published private(set) var isApplying = false
    /// Installed by app lifecycle integration; paused emulators also count as active.
    var canApply: () -> Bool = { false }
    private let defaults: UserDefaults
    private let storage: BoundROMUpdateStorage
    private var bundledImportInProgress = false
    private var bundledImportStarted = false
    private var started = false
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private static let bookmarkKey = "bound.rom-updates.folder-bookmark.v1"
    private static let enabledKey = "bound.rom-updates.enabled.v1"
    private static let nameKey = "bound.rom-updates.folder-name.v1"
    private static let enrollmentKey = "bound.rom-updates.enrollment-game.v1"
    init(defaults: UserDefaults = .standard, storage: BoundROMUpdateStorage = .live) {
        self.defaults = defaults; self.storage = storage
        folderName = defaults.string(forKey: Self.nameKey)
        if let selected = defaults.string(forKey: Self.enrollmentKey) {
            enrollmentSelectionMade = true; enrollmentGameID = selected.isEmpty ? nil : selected
        }
        isEnabled = defaults.bool(forKey: Self.enabledKey) && defaults.data(forKey: Self.bookmarkKey) != nil
        isApplying = FileManager.default.fileExists(atPath: storage.journalURL.path)
        if isApplying { status = "Finishing the previous ROM update…" }
        else if isEnabled { status = "Waiting to check for updates." }
        else if folderName != nil { status = "Automatic updates are off." }
    }
    func start() {
        guard !started else { return }; started = true
        for name in [UIApplication.didBecomeActiveNotification, DatabaseManager.didStartNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.checkNow() }
            })
        }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkNow() }
        }
        RunLoop.main.add(timer, forMode: .common); self.timer = timer
        checkNow()
    }
    func selectFolder(_ url: URL) {
        guard !isApplying else { status = "Finish the ROM update, then choose the folder again."; return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw BoundROMUpdateError.unsafePath }
            let bookmark = try url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
            configuration = UUID(); stagedBookmark = bookmark; stagedName = url.lastPathComponent
            folderName = url.lastPathComponent
            enrollmentGameID = nil; enrollmentSelectionMade = false; needsGameSelection = false
            if isChecking { checkAgain = true } else { checkNow() }
        } catch { status = error.localizedDescription }
    }
    func selectGameForUpdates(_ gameID: String?) {
        guard needsGameSelection, gameID == nil || enrollmentChoices.contains(where: { $0.id == gameID }) else { return }
        enrollmentGameID = gameID; enrollmentSelectionMade = true; needsGameSelection = false
        if let bookmark = stagedBookmark {
            defaults.set(bookmark, forKey: Self.bookmarkKey); defaults.set(stagedName, forKey: Self.nameKey)
        }
        defaults.set(gameID ?? "", forKey: Self.enrollmentKey)
        stagedBookmark = nil; stagedName = nil
        defaults.set(true, forKey: Self.enabledKey); isEnabled = true; configuration = UUID()
        if isChecking { checkAgain = true } else { checkNow() }
    }
    func cancelEnrollment() {
        guard !isApplying else { return }
        configuration = UUID(); stagedBookmark = nil; stagedName = nil; needsGameSelection = false
        folderName = defaults.string(forKey: Self.nameKey)
        let selected = defaults.string(forKey: Self.enrollmentKey)
        enrollmentSelectionMade = selected != nil; enrollmentGameID = selected.flatMap { $0.isEmpty ? nil : $0 }
        status = isEnabled ? "Waiting to check for updates." : "Automatic updates are off."
    }
    func enable() {
        guard defaults.data(forKey: Self.bookmarkKey) != nil, !isApplying else { return }
        defaults.set(true, forKey: Self.enabledKey); isEnabled = true; checkNow()
    }
    func disable() {
        guard !isApplying else { return }
        cancelEnrollment()
        defaults.set(false, forKey: Self.enabledKey); isEnabled = false
        status = "Automatic updates are off."
    }
    static func bundledROMName(buildNumber: String?) -> String {
        guard let buildNumber, !buildNumber.isEmpty else { return "0" }
        return buildNumber
    }
    static func isAutomaticBundledROMName(_ name: String, sha256: String, previousAutomaticName: String? = nil) -> Bool {
        name == previousAutomaticName || name == "Multi Red" || name == "Multi Red " + String(sha256.prefix(8)) ||
        name.range(of: #"^Multi Red — Build [0-9]+(?:\.[0-9]+){0,2}$"#, options: .regularExpression) != nil
    }
    private func refreshBundledROMName(_ content: BoundROMUpdateContent, name: String, imported: Bool = false) throws {
        let context = DatabaseManager.shared.newBackgroundContext()
        try context.performAndWait {
            for game in try self.games(matching: [content.gameID], context: context) {
                var settings = (game.gameSettings as? [String: Any]) ?? [:]
                let key = "bound.bundled-rom.automatic-name.v1"
                let previous = settings[key] as? String
                if Self.isAutomaticBundledROMName(game.name, sha256: content.sha256, previousAutomaticName: previous)
                    || (imported && game.name == name) {
                    game.name = name
                    settings[key] = name
                    game.gameSettings = settings as NSDictionary
                }
            }
            if let cover = Bundle.main.url(forResource: "firered-cover", withExtension: "png") {
                for game in try self.games(matching: [content.gameID], context: context) where game.artworkURL == nil {
                    let destination = DatabaseManager.gamesDirectoryURL.appendingPathComponent(content.gameID + "-firered.png")
                    try Data(contentsOf: cover).write(to: destination, options: .atomic)
                    game.artworkURL = destination
                }
            }
            if context.hasChanges { try context.save() }
        }
    }
    /// Each cartridge keeps its content-addressed identity and existing saves.
    /// Never enroll an older cartridge in the reset-on-update folder workflow.
    private func installBundledROMIfNeeded() {
        guard !bundledImportStarted, !isApplying, !isChecking, DatabaseManager.shared.isStarted,
              UIApplication.shared.applicationState == .active,
              let url = Bundle.main.url(forResource: "multiplayer", withExtension: "gba") else { return }
        bundledImportStarted = true
        bundledImportInProgress = true
        Task { @MainActor in
            var installed = false
            defer { bundledImportInProgress = false; if installed, isEnabled { checkNow() } }
            do {
                // Read the installed bundle at runtime: App Store export can renumber the archive.
                let name = Self.bundledROMName(buildNumber: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
                try await installBundledROM(from: url, name: name)
                installed = true
            } catch {
                // A transient library/foreground condition retries through the
                // existing timer, without entering the reset-on-update flow.
                bundledImportStarted = false
                status = error.localizedDescription
            }
        }
    }

    /// Install the exact bundled cartridge without retiring another identity,
    /// migrating its saves, or changing a user-assigned library name.
    func installBundledROM(from url: URL, name: String) async throws {
        let data = try await Task.detached(priority: .utility) {
            let data = try Data(contentsOf: url)
            _ = try BoundROMUpdateContent(data: data, expectedSHA256: BoundPlayerROMProfile.supportedSHA256)
            _ = try BoundPlayerROMProfile(rom: data)
            return data
        }.value
        let content = try BoundROMUpdateContent(data: data, expectedSHA256: BoundPlayerROMProfile.supportedSHA256)
        let existing = try games(matching: [content.gameID])
        guard existing.count <= 1 else { throw BoundROMUpdateError.storage }
        if let game = existing.first {
            let file = game.fileURL
            if FileManager.default.fileExists(atPath: file.path) {
                // A corrupt file with this identity is not an older save to
                // convert. Retain it and fail closed for explicit recovery.
                _ = try await Task.detached(priority: .utility) {
                    try BoundROMUpdateContent(data: Data(contentsOf: file), expectedSHA256: content.sha256)
                }.value
            } else {
                guard canApply(), !hasPendingSaveClear(for: content.gameID) else { throw BoundROMUpdateError.busy }
                try data.write(to: file, options: .atomic)
            }
            try refreshBundledROMName(content, name: name)
            return
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = folder.appendingPathComponent(name + ".gba")
        try data.write(to: copy, options: .atomic)
        let succeeded = await withCheckedContinuation { continuation in
            DatabaseManager.shared.importGames(at: [copy]) { games, errors in
                continuation.resume(returning: errors.isEmpty && games.contains { $0.identifier == content.gameID })
            }
        }
        guard succeeded else { throw BoundROMUpdateError.storage }
        try refreshBundledROMName(content, name: name, imported: true)
    }

    func hasPendingSaveClear(for gameID: String) -> Bool {
        clearingSaveGameIDs.contains(gameID) || storage.hasPendingSaveClear(gameID: gameID)
    }

    func clearSaves(for game: Game, completion: @escaping (Error?) -> Void) {
        clearSaves(gameID: game.identifier, gameName: game.name, completion: completion)
    }

    private func clearSaves(gameID: String, gameName: String, completion: @escaping (Error?) -> Void) {
        guard !BoundROMCleanupJournal(storage: storage).blocks(gameID) else {
            completion(BoundROMUpdateError.clearingROMs); return
        }
        guard !isApplying, !isChecking, !bundledImportInProgress, !clearingSaveGameIDs.contains(gameID) else {
            completion(BoundROMUpdateError.busy); return
        }
        clearingSaveGameIDs.insert(gameID)
        SyncManager.shared.performROMUpdate { finish in
            Task { @MainActor in
                var failure: Error?
                do {
                    let pending: BoundROMUpdateStorage.SaveClear
                    if let saved = try self.storage.pendingSaveClear(gameID: gameID) { pending = saved }
                    else {
                        let cloud = try await SyncManager.shared.prepareSaveClearCloudContext(gameID: gameID)
                        pending = try self.storage.beginSaveClear(gameID: gameID, gameName: gameName,
                            cloudContext: JSONEncoder().encode(cloud))
                    }
                    let cloud = try JSONDecoder().decode(BoundSaveClearCloudContext.self, from: pending.cloudContext)
                    NotificationCenter.default.post(name: Self.saveClearBegan, object: gameID)
                    guard BoundROMUpdateActivity.close(gameID: gameID) else { throw BoundROMUpdateError.busy }
                    try await SyncManager.shared.deleteCloudSaves(gameID: gameID, context: cloud)
                    try self.clearLocalSaves(gameID: gameID)
                    try await SyncManager.shared.removeLocalSaveSyncRecords(gameID: gameID, context: cloud)
                    try self.storage.completeSaveClear(pending)
                } catch { failure = error }
                // On failure the durable receipt keeps this ROM blocked, even after relaunch.
                self.clearingSaveGameIDs.remove(gameID)
                finish()
                completion(failure)
            }
        }
    }

    private func clearLocalSaves(gameID: String) throws {
        let context = DatabaseManager.shared.newBackgroundContext()
        try context.performAndWait {
            guard let record = try self.games(matching: [gameID], context: context).first else { throw BoundROMUpdateError.storage }
            let stem = BoundMultiplayerSaveStore.hash(Data(record.identifier.utf8))
            var paths = [record.gameSaveURL,
                record.gameSaveURL.deletingPathExtension().appendingPathExtension("rtc"),
                DatabaseManager.saveStatesDirectoryURL.appendingPathComponent(record.identifier),
                BoundMultiplayerSaveStore.shared.directory(gameID: record.identifier),
                self.storage.support.appendingPathComponent("Soul Link/" + stem + ".json"),
                self.storage.support.appendingPathComponent("Soul Link/" + stem + ".timeline.json")]
            let recovery = self.storage.support.appendingPathComponent("Friend Battles")
            if FileManager.default.fileExists(atPath: recovery.path) {
                for journal in try FileManager.default.contentsOfDirectory(at: recovery, includingPropertiesForKeys: nil) where journal.pathExtension == "json" {
                    let values = try JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [String: String]
                    guard values?["gameID"] == record.identifier else { continue }
                    guard let name = values?["state"], UUID(uuidString: URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent) != nil,
                          name == URL(fileURLWithPath: name).lastPathComponent, name.hasSuffix(".state") else { throw BoundROMUpdateError.unsafePath }
                    paths += [journal, recovery.appendingPathComponent(name)]
                }
            }
            paths += try self.storage.cooperativeRecoveryFiles(gameID:record.identifier)
            try self.storage.clearSaveFiles(paths,cooperativeGameSaveURL:record.gameSaveURL) {
                record.previewSaveState = nil
                for state in record.saveStates { context.delete(state) }
                if let save = record.gameSave { context.delete(save); record.gameSave = nil }
                do { try context.save() } catch { context.rollback(); throw error }
            }
        }
    }

    private func resumePendingSaveClears() -> Bool {
        do {
            let pending = try storage.pendingSaveClears()
            for item in pending where !clearingSaveGameIDs.contains(item.gameID) {
                clearSaves(gameID: item.gameID, gameName: item.gameName) { [weak self] error in
                    if let error { self?.status = error.localizedDescription }
                }
            }
            return !pending.isEmpty || !clearingSaveGameIDs.isEmpty
        } catch {
            status = error.localizedDescription
            return true
        }
    }

    func checkNow() {
        guard DatabaseManager.shared.isStarted, UIApplication.shared.applicationState == .active else { return }
        guard !resumePendingSaveClears() else { return }
        installBundledROMIfNeeded()
        guard !bundledImportInProgress, !isChecking, !needsGameSelection, UIApplication.shared.applicationState == .active,
              isEnabled || stagedBookmark != nil || FileManager.default.fileExists(atPath: storage.journalURL.path) else { return }
        guard DatabaseManager.shared.isStarted else { status = "Waiting for the game library."; return }
        isChecking = true
        let operation = configuration
        Task { @MainActor in
            defer {
                self.isChecking = false
                if self.checkAgain { self.checkAgain = false; self.checkNow() }
            }
            do {
                if let pending = try storage.pending() {
                    guard canApply() else { status = BoundROMUpdateError.busy.localizedDescription; return }
                    try await apply(pending: pending, candidate: nil)
                    // Recovery finishes the already accepted content even after
                    // an app upgrade. A subsequent check validates the new file.
                    self.checkAgain = true
                    return
                }
                let candidate = try await readCandidate()
                guard configuration == operation else { return }
                if stagedBookmark != nil {
                    let available = try await availableEnrollmentGames()
                    guard configuration == operation else { return }
                    if let current = try storage.state().current {
                        canChooseEnrollmentGame = false
                        enrollmentChoices = available.filter { $0.id == current.gameID }
                        suggestedEnrollmentGameID = enrollmentChoices.first?.id
                    } else {
                        canChooseEnrollmentGame = true
                        enrollmentChoices = available
                        suggestedEnrollmentGameID = available.contains(where: { $0.id == candidate.content.gameID }) ? candidate.content.gameID : nil
                    }
                    needsGameSelection = true; status = "Choose the game to update."; return
                }
                guard isEnabled else { status = "Automatic updates are off."; return }
                if try await alreadyInstalledBundledROM(candidate.content) {
                    guard configuration == operation else { return }
                    // Bundled releases install alongside older cartridges.
                    // A legacy folder enrollment must not turn that successful
                    // installation into a fresh reset/retirement transaction.
                    status = "Included ROM is up to date."; return
                }
                guard configuration == operation else { return }
                if try storage.state().current == candidate.content {
                    status = "ROM is up to date."; return
                }
                if try storage.state().current == nil, !enrollmentSelectionMade,
                   try games(matching: [candidate.content.gameID]).isEmpty {
                    enrollmentChoices = try await availableEnrollmentGames()
                    needsGameSelection = true; status = "Choose the game to update."
                    return
                }
                guard canApply() else { status = "Update ready. Close the game to install."; return }
                try await apply(pending: nil, candidate: candidate)
            } catch {
                guard configuration == operation else { return }
                if stagedBookmark != nil { cancelEnrollment() }
                status = error.localizedDescription
            }
        }
    }
    private func alreadyInstalledBundledROM(_ content: BoundROMUpdateContent) async throws -> Bool {
        guard let bundle = Bundle.main.url(forResource: "multiplayer", withExtension: "gba"),
              let game = try games(matching: [content.gameID]).first else { return false }
        let installed = game.fileURL
        return try await Task.detached(priority: .utility) {
            let bundled = try BoundROMUpdateContent(data: Data(contentsOf: bundle), expectedSHA256: BoundPlayerROMProfile.supportedSHA256)
            guard bundled == content else { return false }
            // A database row alone is not proof that the matching cartridge is
            // installed. Missing/corrupt bytes fail closed without resetting it.
            return try BoundROMUpdateContent(data: Data(contentsOf: installed), expectedSHA256: bundled.sha256) == content
        }.value
    }
    private struct Candidate { let content: BoundROMUpdateContent; let data: Data }
    static func candidateFile(in folder: URL) -> URL {
        let current = folder.appendingPathComponent("multiplayer.gba")
        return FileManager.default.fileExists(atPath: current.path) ? current : folder.appendingPathComponent("rrbin-integrated.gba")
    }
    private func readCandidate() async throws -> Candidate {
        guard let bookmark = stagedBookmark ?? defaults.data(forKey: Self.bookmarkKey) else { throw BoundROMUpdateError.unsafePath }
        var stale = false
        let folder = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        if stale {
            let refreshed = try folder.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
            if stagedBookmark != nil { stagedBookmark = refreshed } else { defaults.set(refreshed, forKey: Self.bookmarkKey) }
        }
        let file = Self.candidateFile(in: folder)
        let values = try file.resourceValues(forKeys: [.isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey])
        if values.isUbiquitousItem == true, values.ubiquitousItemDownloadingStatus != .current {
            try FileManager.default.startDownloadingUbiquitousItem(at: file)
            status = "Downloading ROM from iCloud…"
        } else { status = "Checking ROM…" }
        return try await Task.detached(priority: .utility) {
            var coordinatedError: NSError?, readError: Error?, data: Data?
            NSFileCoordinator().coordinate(readingItemAt: file, options: [.withoutChanges], error: &coordinatedError) { url in
                do {
                    let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                    guard values.isRegularFile == true, values.isSymbolicLink != true,
                          values.fileSize == BoundROMUpdateContent.byteCount else { throw BoundROMUpdateError.invalidROM }
                    data = try Data(contentsOf: url) // owned bytes; never retain a mapping into the provider's changing file
                } catch { readError = error }
            }
            if let error = coordinatedError ?? readError as NSError? { throw error }
            guard let data else { throw BoundROMUpdateError.invalidROM }
            let content = try BoundROMUpdateContent(data: data, expectedSHA256: BoundPlayerROMProfile.supportedSHA256)
            _ = try BoundPlayerROMProfile(rom: data)
            return Candidate(content: content, data: data)
        }.value
    }
    private func apply(pending: BoundROMUpdateStorage.Transaction?, candidate: Candidate?) async throws {
        isApplying = true
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                SyncManager.shared.performROMUpdate { finish in
                    Task { @MainActor in
                        defer { finish() }
                        do {
                            guard self.canApply() else { throw BoundROMUpdateError.busy }
                            let transaction: BoundROMUpdateStorage.Transaction
                            if let pending { transaction = pending }
                            else if let candidate { transaction = try self.prepare(candidate) }
                            else { throw BoundROMUpdateError.storage }
                            let storage = self.storage
                            if try storage.finishCompleted(transaction) {
                                self.isApplying = false; self.status = "ROM is up to date."
                                continuation.resume(); return
                            }
                            self.status = "Backing up saves…"
                            let completedFiles = try await Task.detached(priority: .utility) {
                                var value = transaction
                                let data = try Data(contentsOf: storage.incomingURL(value))
                                let verified = try BoundROMUpdateContent(data: data, expectedSHA256: value.content.sha256)
                                guard verified == value.content else { throw BoundROMUpdateError.storage }
                                try storage.makeBackup(&value)
                                try storage.resetFiles(&value)
                                try storage.installROM(value, destination: storage.documents.appendingPathComponent("Database/Games/" + value.content.gameID + ".gba"))
                                return value
                            }.value
                            guard self.canApply() else { throw BoundROMUpdateError.busy }
                            self.status = "Updating game library…"
                            try self.updateLibrary(completedFiles)
                            try self.storage.complete(completedFiles)
                            self.isApplying = false
                            self.status = completedFiles.resetGameIDs.isEmpty ? "Automatic ROM updates are on." : "ROM updated. Previous saves are backed up."
                            continuation.resume()
                        } catch {
                            self.isApplying = FileManager.default.fileExists(atPath: self.storage.journalURL.path)
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }
        } catch {
            isApplying = FileManager.default.fileExists(atPath: storage.journalURL.path)
            throw error
        }
    }
    private func games(matching identifiers: Set<String>, context: NSManagedObjectContext? = nil) throws -> [Game] {
        guard !identifiers.isEmpty else { return [] }
        let request: NSFetchRequest<Game> = Game.fetchRequest()
        request.predicate = NSPredicate(format: "%K IN %@", #keyPath(Game.identifier), Array(identifiers))
        return try (context ?? DatabaseManager.shared.viewContext).fetch(request)
    }
    private func availableEnrollmentGames() async throws -> [GameChoice] {
        let request: NSFetchRequest<Game> = Game.fetchRequest()
        request.predicate = NSPredicate(format: "%K == %@", #keyPath(Game.type), GameType.gba.rawValue)
        let records = try DatabaseManager.shared.viewContext.fetch(request).map { ($0.identifier, $0.name, $0.fileURL) }
        return await Task.detached(priority: .utility) {
            records.compactMap { id, name, url in
                guard let data = try? Data(contentsOf: url),
                      (try? BoundROMUpdateContent.enrollment(data: data, gameID: id)) != nil else { return nil }
                return GameChoice(id: id, name: name)
            }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }.value
    }
    private func prepare(_ candidate: Candidate) throws -> BoundROMUpdateStorage.Transaction {
        let previous = try storage.state()
        var old = previous.current
        if old == nil, let selected = enrollmentGameID {
            guard let game = try games(matching: [selected]).first else { throw BoundROMUpdateError.storage }
            old = try BoundROMUpdateContent.enrollment(data: Data(contentsOf: game.fileURL), gameID: selected)
        }
        let resetIDs = try BoundROMUpdateContent.resetGameIDs(previous: old, incoming: candidate.content)
        let relevant = Set([candidate.content.gameID] + (old.map { [$0.gameID] } ?? []))
        let records = try games(matching: relevant)
        var preservedIncoming = BoundROMUpdateStorage.PreservedIncoming()
        if resetIDs.contains(candidate.content.gameID), let incoming = records.first(where: { $0.identifier == candidate.content.gameID }) {
            preservedIncoming = try incomingPreservation(incoming, content: candidate.content)
        }
        if let old {
            let oldROM = DatabaseManager.gamesDirectoryURL.appendingPathComponent(old.gameID + ".gba")
            if FileManager.default.fileExists(atPath: oldROM.path), BoundROMUpdateContent.hash(try Data(contentsOf: oldROM)) != old.sha256 {
                throw BoundROMUpdateError.changedBackup
            }
        }
        var sources = [BoundROMUpdateStorage.Source]()
        for gameID in relevant.sorted() {
            let reset = resetIDs.contains(gameID)
            let game = records.first { $0.identifier == gameID }
            let rom = game?.fileURL ?? DatabaseManager.gamesDirectoryURL.appendingPathComponent(gameID + ".gba")
            sources.append(try storage.source(for: rom, remove: reset && gameID != candidate.content.gameID))
            let battery = game?.gameSaveURL ?? DatabaseManager.gamesDirectoryURL.appendingPathComponent(gameID + ".sav")
            let preserveBattery = gameID == candidate.content.gameID && preservedIncoming.battery
            for url in [battery, battery.deletingPathExtension().appendingPathExtension("rtc"),
                        BoundMultiplayerSaveStore.shared.directory(gameID: gameID)] {
                sources.append(try storage.source(for: url, remove: reset && !preserveBattery))
            }
            let statesDirectory = DatabaseManager.saveStatesDirectoryURL.appendingPathComponent(gameID)
            if reset, gameID == candidate.content.gameID, !preservedIncoming.stateIDs.isEmpty, let game {
                let preservedFiles = Set(game.saveStates.filter { preservedIncoming.stateIDs.contains($0.identifier) }
                    .flatMap { [$0.fileURL.standardizedFileURL.path, $0.imageFileURL.standardizedFileURL.path] })
                for file in try FileManager.default.contentsOfDirectory(at: statesDirectory, includingPropertiesForKeys: nil) {
                    sources.append(try storage.source(for: file, remove: !preservedFiles.contains(file.standardizedFileURL.path)))
                }
            } else {
                sources.append(try storage.source(for: statesDirectory, remove: reset))
            }
            let stem = BoundMultiplayerSaveStore.hash(Data(gameID.utf8))
            for suffix in [".json", ".timeline.json"] {
                sources.append(try storage.source(for: storage.support.appendingPathComponent("Soul Link/" + stem + suffix), remove: reset && !preserveBattery))
            }
        }
        let recovery = storage.support.appendingPathComponent("Friend Battles", isDirectory: true)
        for journal in (try? FileManager.default.contentsOfDirectory(at: recovery, includingPropertiesForKeys: nil)) ?? [] where journal.pathExtension == "json" {
            guard let values = try JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [String: String] else { throw BoundROMUpdateError.storage }
            guard let gameID = values["gameID"], relevant.contains(gameID) else { continue }
            guard let name = values["state"], name == URL(fileURLWithPath: name).lastPathComponent,
                  UUID(uuidString: URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent) != nil,
                  URL(fileURLWithPath: name).pathExtension == "state" else { throw BoundROMUpdateError.unsafePath }
            let resetRecovery = resetIDs.contains(gameID) && !(gameID == candidate.content.gameID && preservedIncoming.battery)
            sources.append(try storage.source(for: journal, remove: resetRecovery))
            sources.append(try storage.source(for: recovery.appendingPathComponent(name), remove: resetRecovery))
        }
        let metadata: [[String: Any]] = records.map { game in
            ["identifier": game.identifier, "filename": game.filename, "name": game.name,
             "favorite": game.isFavorite, "saveStates": game.saveStates.map { state in
                ["identifier": state.identifier, "filename": state.filename, "name": state.name ?? "",
                 "type": state.type.rawValue, "core": state.coreIdentifier ?? "", "coreVersion": state.coreVersion ?? ""] as [String: Any]
             }, "cheats": game.cheats.map { ["name": $0.name, "code": $0.code, "type": $0.type.rawValue] }]
        }
        return try storage.begin(content: candidate.content, data: candidate.data, sources: sources,
            metadata: JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]), resetGameIDs: resetIDs, enrollment: old, preservedIncoming: preservedIncoming)
    }
    private func incomingPreservation(_ game: Game, content: BoundROMUpdateContent) throws -> BoundROMUpdateStorage.PreservedIncoming {
        guard let controller = SyncManager.shared.recordController else { return .init() }
        func preserves(_ object: NSManagedObject) throws -> Bool {
            let records = try controller.fetchRecords(for: [object])
            let proofs = records.map { record in
                BoundROMUpdateResetPolicy.Proof(generation: record.remoteMetadata?[HarmonyMetadataKey("boundROMGeneration")],
                    localNormal: record.localStatus == .normal, remoteNormal: record.remoteStatus == .normal,
                    conflicted: record.isConflicted, locked: record.perform { $0.remoteRecord?.isLocked ?? true })
            }
            switch BoundROMUpdateResetPolicy.incoming(generation: content.sha256, objectCount: 1, proofs: proofs) {
            case .resetLocal: return false
            case .adopt:
                if let save = object as? GameSave {
                    let packages = BoundMultiplayerSaveStore.shared
                    let unresolved: Bool
                    let manifest: BoundMultiplayerRunManifest?
                    do {
                        unresolved = try packages.inspectIncoming(gameID: game.identifier) != nil
                        manifest = try packages.manifest(gameID: game.identifier)
                    } catch { throw BoundROMUpdateError.multiplayerPending }
                    let activeManifest = manifest?.ended == false ? manifest : nil
                    try BoundROMUpdateResetPolicy.validateCanonicalBattery(try? Data(contentsOf: game.gameSaveURL),
                        expectedSHA1: save.sha1, unresolvedImport: unresolved,
                        interruptedRestore: packages.hasInterruptedRestore(gameID: game.identifier),
                        remoteRun: records.first?.remoteMetadata?[HarmonyMetadataKey("boundMultiplayerRun")],
                        canonicalRun: activeManifest?.identity.run.uuidString,
                        canonicalROM: activeManifest?.identity.romSHA256, generation: content.sha256)
                }
                return true
            case .waitForSync: throw BoundROMUpdateError.syncPending
            }
        }
        var result = BoundROMUpdateStorage.PreservedIncoming()
        if let save = game.gameSave, try preserves(save) { result.battery = true }
        // Auto/quick states never have Harmony records. Reset them locally;
        // individually preserve only verified current-generation manual states.
        for state in game.saveStates where state.isSyncingEnabled {
            if try preserves(state) { result.stateIDs.insert(state.identifier) }
        }
        return result
    }
    private func updateLibrary(_ transaction: BoundROMUpdateStorage.Transaction) throws {
        let context = DatabaseManager.shared.newBackgroundContext()
        try context.performAndWait {
        let identifiers = transaction.resetGameIDs.union([transaction.content.gameID])
        let existing = try self.games(matching: identifiers, context: context)
        let old = existing.first { $0.identifier != transaction.content.gameID }
        let game = existing.first { $0.identifier == transaction.content.gameID } ?? Game(context: context)
        if game.isInserted {
            game.identifier = transaction.content.gameID; game.type = .gba
            game.name = old?.name ?? "Multi Red"
            game.isFavorite = old?.isFavorite ?? false
            game.gameSettings = old?.gameSettings
            game.artworkURL = old?.artworkURL
        }
        game.filename = transaction.content.gameID + ".gba"
        if game.gameCollection == nil {
            let request: NSFetchRequest<GameCollection> = GameCollection.fetchRequest()
            request.predicate = NSPredicate(format: "%K == %@", #keyPath(GameCollection.identifier), GameType.gba.rawValue)
            let collection = try context.fetch(request).first ?? GameCollection(context: context)
            collection.identifier = GameType.gba.rawValue; collection.index = 2001
            game.gameCollection = collection
        }
        for item in existing where transaction.resetGameIDs.contains(item.identifier) {
            let preserved = item === game ? transaction.preservedIncoming.stateIDs : []
            if let preview = item.previewSaveState, !preserved.contains(preview.identifier) { item.previewSaveState = nil }
            for state in item.saveStates where !preserved.contains(state.identifier) { context.delete(state) }
            if item !== game {
                if BoundROMUpdateResetPolicy.deletesGameSave(gameID: item.identifier, incomingID: transaction.content.gameID), let save = item.gameSave {
                    context.delete(save); item.gameSave = nil
                }

                // Files already have a verified recovery copy and were removed
                // by the journal. Avoid Game's eager, separately saving cleanup.
                item.filename = ""; context.delete(item)
            }
        }
        do { try context.save() }
        catch { context.rollback(); throw error }
        }
    }
}
