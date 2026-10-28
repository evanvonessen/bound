import Foundation
import Combine
import CoreData
import SwiftUI

struct BoundROMServerManifest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let buildNumber: Int
    let sha256: String
    let gameID: String
    let byteCount: Int
    var hostInterface: [String: Int]? = nil

    func validate() throws {
        func hex(_ value: String, count: Int) -> Bool {
            value.utf8.count == count && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        guard schemaVersion == 1, buildNumber >= 500, byteCount == 32 * 1024 * 1024,
              hex(sha256, count: 64), hex(gameID, count: 40) else { throw BoundROMUpdateError.invalidROM }
    }
    func validateCompatibility() throws {
        try validate()
        // Reject unsupported host functionality before downloading. The native
        // verifier separately proves engine bindings and save layout from bytes.
        if let hostInterface {
            guard hostInterface["version"] == 1, hostInterface["required_capabilities"] == 31,
                  hostInterface["native_binding_version"] == 1 else { throw BoundROMUpdateError.incompatibleROM }
        }
        // Discovery is release-independent. The downloaded cartridge must pass
        // native binding/capability verification before consent can delete data.
        // Exact hashes still identify this download and every saved raw state.
    }
}

private final class BoundROMNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor
final class BoundROMServerUpdates: ObservableObject {
    static let shared = BoundROMServerUpdates()
    @Published private(set) var approved = false
    @Published private(set) var latest: BoundROMServerManifest?
    @Published private(set) var busy = false
    @Published private(set) var upToDate = false
    @Published private(set) var message: String?
    private var identity: AppCloudSession?
    private var operation: Task<Void, Never>?
    private var revision = UUID()

    func sessionChanged(_ session: AppCloudSession?) {
        guard identity?.isSameSession(as: session) != true else { return }
        revision = UUID(); operation?.cancel(); operation = nil
        identity = session; approved = false; latest = nil; upToDate = false; busy = false; message = nil
        refresh()
    }
    private func check(_ session: AppCloudSession, revision: UUID) throws {
        try Task.checkCancellation()
        guard self.revision == revision, session.isSameSession(as: BoundFriendAccount.shared.session) else { throw BoundFriendError.signIn }
    }
    private func access(_ session: AppCloudSession) async throws -> Bool {
        let result = try await BoundAuthTransport.perform(session.romUpdateRequest(resource: "access"))
        if [401, 403].contains(result.status) { return false }
        guard result.status == 200 else { throw BoundFriendError.unavailable }
        struct Access: Decodable { let developerApproved: Bool }
        return try JSONDecoder().decode(Access.self, from: result.data).developerApproved
    }
    func refresh() {
        guard !busy, let session = BoundFriendAccount.shared.session else { return }
        identity = session; busy = true; message = nil
        let revision = revision
        operation = Task {
            defer { if self.revision == revision { busy = false; operation = nil } }
            do {
                let allowed = try await access(session)
                try check(session, revision: revision)
                approved = allowed
                guard allowed else { latest = nil; upToDate = false; return }
                // This only resumes a durable installation already confirmed by
                // this account. Discovering a new release never installs it.
                try await BoundROMServerInstaller.resume(session: session)
                let result = try await BoundAuthTransport.perform(session.romUpdateRequest(resource: "latest"))
                try check(session, revision: revision)
                guard result.status == 200 else {
                    if [401, 403].contains(result.status) { approved = false; latest = nil }
                    throw BoundFriendError.unavailable
                }
                let manifest = try JSONDecoder().decode(BoundROMServerManifest.self, from: result.data)
                try manifest.validate()
                latest = manifest
                let request = Game.fetchRequest()
                request.predicate = NSPredicate(format: "identifier == %@", manifest.gameID)
                let games = try DatabaseManager.shared.viewContext.fetch(request)
                if let game = games.first, games.count == 1, let bytes = try? Data(contentsOf: game.fileURL) {
                    upToDate = bytes.count == manifest.byteCount && BoundROMUpdateContent.hash(bytes) == manifest.sha256 &&
                        BoundROMServerInstaller.installedBuild(gameID: manifest.gameID) == manifest.buildNumber
                } else { upToDate = false }
            } catch {
                guard self.revision == revision else { return }
                latest = nil; upToDate = false; message = error.localizedDescription
            }
        }
    }
    /// Called only by the destructive confirmation button, with its frozen manifest.
    func downloadConfirmed(_ manifest: BoundROMServerManifest) {
        guard approved, !busy, manifest == latest, let session = identity,
              session.isSameSession(as: BoundFriendAccount.shared.session) else { return }
        busy = true; message = "Downloading…"
        let revision = revision
        operation = Task {
            defer { if self.revision == revision { busy = false; operation = nil } }
            do {
                try manifest.validateCompatibility()
                guard try await access(session) else { approved = false; latest = nil; return }
                try check(session, revision: revision)
                let request = try session.romUpdateRequest(resource: "download", build: manifest.buildNumber, sha256: manifest.sha256)
                let config = URLSessionConfiguration.ephemeral
                config.httpShouldSetCookies = false; config.httpCookieStorage = nil; config.urlCache = nil
                config.timeoutIntervalForRequest = 120; config.timeoutIntervalForResource = 300
                let client = URLSession(configuration: config, delegate: BoundROMNoRedirect(), delegateQueue: nil)
                defer { client.invalidateAndCancel() }
                let (file, response) = try await client.download(for: request)
                defer { try? FileManager.default.removeItem(at: file) }
                try check(session, revision: revision)
                guard let response = response as? HTTPURLResponse, response.url == request.url, response.statusCode == 200 else {
                    if let status = (response as? HTTPURLResponse)?.statusCode, [401, 403].contains(status) { approved = false; latest = nil }
                    throw BoundFriendError.unavailable
                }
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                guard (attributes[.size] as? NSNumber)?.intValue == manifest.byteCount else { throw BoundROMUpdateError.invalidROM }
                let data = try Data(contentsOf: file)
                let content = try BoundROMUpdateContent(data: data, expectedSHA256: manifest.sha256)
                guard content.gameID == manifest.gameID else { throw BoundROMUpdateError.incompatibleROM }
                guard try await access(session) else { approved = false; latest = nil; return }
                try check(session, revision: revision)
                message = "Installing…"
                try await BoundROMServerInstaller.install(data: data, manifest: manifest, session: session)
                try check(session, revision: revision)
                upToDate = true; message = nil
            } catch {
                guard self.revision == revision else { return }
                message = error.localizedDescription
            }
        }
    }
}

struct BoundROMServerUpdateControls: View {
    @ObservedObject private var updates = BoundROMServerUpdates.shared
    @ObservedObject private var account = BoundFriendAccount.shared
    @State private var confirming = false
    @State private var candidate: BoundROMServerManifest?
    var body: some View {
        Group {
            if updates.approved {
                if updates.latest != nil {
                    Text(updates.upToDate ? "RRv4.1M is up to date" : "Update available for RRv4.1M")
                        .accessibilityIdentifier("bound.rom-update-status")
                }
                Button("Refresh") { updates.refresh() }
                    .disabled(updates.busy)
                    .accessibilityIdentifier("bound.rom-update-refresh")
                if !updates.upToDate, let latest = updates.latest {
                    Button("Download Latest RRv4.1M Multiplayer Version") { candidate = latest; confirming = true }
                        .disabled(updates.busy)
                        .accessibilityIdentifier("bound.rom-update-download")
                }
                if let message = updates.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .onReceive(account.$session) { session in Task { @MainActor in updates.sessionChanged(session) } }
        .task { updates.sessionChanged(account.session); updates.refresh() }
        .confirmationDialog("Install RRv4.1M?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Download and Install", role: .destructive) {
                if let candidate { updates.downloadConfirmed(candidate) }
                candidate = nil
            }
            Button("Cancel", role: .cancel) { candidate = nil }
        } message: {
            Text("Installing this update permanently deletes previous multi_red ROMs and their saves from this device. Server saves and your partner’s progress are preserved.")
        }
    }
}
