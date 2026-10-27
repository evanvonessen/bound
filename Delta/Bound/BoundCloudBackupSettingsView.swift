import SwiftUI

struct BoundCloudBackupSettingsView: View {
    @ObservedObject private var account = BoundFriendAccount.shared
    @ObservedObject private var backups = BoundServerBackupManager.shared
    @State private var selected = BoundServerBackupManager.Provider.none
    @State private var changing = false
    @State private var failure = ""

    var body: some View {
        Form {
            Section("Backup Provider") {
                Picker("Provider", selection: Binding(get: { selected }, set: changeProvider)) {
                    Text("Off").tag(BoundServerBackupManager.Provider.none)
                    Text("Dropbox").tag(BoundServerBackupManager.Provider.dropbox)
                    if backups.approved || selected == .server {
                        Text("Server Backups").tag(BoundServerBackupManager.Provider.server)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .disabled(changing || account.session == nil || account.deletionPending)
                .accessibilityIdentifier("bound.cloud-backup-provider")
                if changing { ProgressView("Changing provider…") }
            }
            if selected == .dropbox {
                Section {
                    NavigationLink("Dropbox Settings") {
                        SyncingServicesViewController.ViewRepresentable()
                            .navigationTitle("Dropbox")
                    }
                }
            } else if selected == .server {
                Section {
                    NavigationLink("Manage Server Backups") { BoundServerBackupView() }
                }
            }
            if account.session == nil { Text("Sign in to choose a backup provider.") }
            if !failure.isEmpty { Text(failure).foregroundStyle(.red) }
        }
        .navigationTitle("Cloud Backups")
        .task(id: account.session?.owner) {
            if BoundBackendConfiguration.bundled?.kind == .selfhost { await backups.refresh() }
            selected = SyncManager.shared.selectedCloudBackupProvider
        }
        .onChange(of: backups.provider) { _, _ in
            if !changing { selected = SyncManager.shared.selectedCloudBackupProvider }
        }
        .onAppear { selected = SyncManager.shared.selectedCloudBackupProvider }
        .onReceive(NotificationCenter.default.publisher(for: Settings.didChangeNotification)) { _ in
            if !changing { selected = SyncManager.shared.selectedCloudBackupProvider }
        }
    }

    private func changeProvider(_ provider: BoundServerBackupManager.Provider) {
        guard !changing, provider != selected else { return }
        changing = true; failure = ""
        Task { @MainActor in
            defer { changing = false; selected = SyncManager.shared.selectedCloudBackupProvider }
            do { try await SyncManager.shared.selectCloudBackupProvider(provider) }
            catch { failure = error.localizedDescription }
        }
    }
}

extension SyncManager {
    enum CloudBackupSelectionError: LocalizedError {
        case changing
        case saveOperation
        var errorDescription: String? {
            switch self {
            case .changing: return "Wait for the backup provider change to finish."
            case .saveOperation: return "Finish the save operation before changing backup providers."
            }
        }
    }
    @MainActor var selectedCloudBackupProvider: BoundServerBackupManager.Provider {
        if BoundServerBackupManager.serverEnabledForCurrentAccount { return .server }
        return Self.currentBoundService == .dropbox ? .dropbox : .none
    }

    /// Drain both engines before changing the single account-wide provider.
    @MainActor func selectCloudBackupProvider(_ provider: BoundServerBackupManager.Provider) async throws {
        guard !changingCloudBackupProvider else { throw CloudBackupSelectionError.changing }
        guard canChangeCloudBackupProvider else { throw CloudBackupSelectionError.saveOperation }
        changingCloudBackupProvider = true
        defer { changingCloudBackupProvider = false }
        let identity = BoundFriendAccount.shared.session
        guard let identity, !BoundFriendAccount.shared.deletionPending else { throw BoundDropboxOAuth.Failure.signIn }
        Settings.syncingService = nil
        await BoundServerBackupManager.shared.cancelPendingOperationsAndWait()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
            self.reset(for: nil) { continuation.resume(with: $0) }
        }
        guard identity.isSameSession(as: BoundFriendAccount.shared.session) else { throw BoundDropboxOAuth.Failure.changed }
        if BoundBackendConfiguration.bundled?.kind == .selfhost {
            try await BoundServerBackupManager.shared.setProvider(provider)
        } else if provider == .server { throw BoundDropboxOAuth.Failure.notConfigured }
        guard identity.isSameSession(as: BoundFriendAccount.shared.session) else { throw BoundDropboxOAuth.Failure.changed }
        if provider == .dropbox {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
                self.reset(for: .dropbox) { continuation.resume(with: $0) }
            }
            guard identity.isSameSession(as: BoundFriendAccount.shared.session) else { throw BoundDropboxOAuth.Failure.changed }
            Settings.syncingService = .dropbox
            sync()
        } else if provider == .server {
            await BoundServerBackupManager.shared.backupNow()
        }
    }
}
