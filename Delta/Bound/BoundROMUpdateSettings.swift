import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum BoundDebuggingFeatures {
    static let key = "bound.debugging-features.enabled.v1"
    static let didChangeNotification = Notification.Name("BoundDebuggingFeaturesChanged")
}

private struct BoundROMUpdateSettingsActions {
    let chooseFolder: () -> Void
    let enableUpdates: () -> Void
}

private struct BoundROMUpdateSettingsActionsKey: EnvironmentKey {
    static let defaultValue: BoundROMUpdateSettingsActions? = nil
}

private extension EnvironmentValues {
    var boundROMUpdateSettingsActions: BoundROMUpdateSettingsActions? {
        get { self[BoundROMUpdateSettingsActionsKey.self] }
        set { self[BoundROMUpdateSettingsActionsKey.self] = newValue }
    }
}

/// Shared by the iPhone and Mac UI versions through their common Settings page.
struct BoundROMUpdateSettingsSection: View {
    @ObservedObject private var updates = BoundROMUpdateManager.shared
    @Environment(\.boundROMUpdateSettingsActions) private var actions

    var body: some View {
        Section("ROM Updates") {
            if let folder = updates.folderName {
                LabeledContent("Folder", value: folder)
                    .accessibilityIdentifier("bound.rom-updates-folder")
            }
            Button(updates.folderName == nil ? "Choose iCloud Folder" : "Change Folder") {
                actions?.chooseFolder()
            }
            .disabled(updates.isApplying || updates.isChecking)
            .accessibilityIdentifier("bound.rom-updates-choose-folder")

            if updates.isEnabled {
                Button("Check for Updates") { updates.checkNow() }
                    .disabled(updates.isChecking || updates.isApplying)
                    .accessibilityIdentifier("bound.rom-updates-check")
                Button("Stop Automatic Updates") { updates.disable() }
                    .disabled(updates.isApplying)
                    .accessibilityIdentifier("bound.rom-updates-disable")
            } else if updates.folderName != nil {
                Button("Enable Automatic Updates") { actions?.enableUpdates() }
                    .disabled(updates.isApplying)
                    .accessibilityIdentifier("bound.rom-updates-enable")
            }
            if !updates.status.isEmpty {
                Text(updates.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("bound.rom-updates-status")
            }
        }
    }
}

/// Own presentations on the Form, never its Section: Section modifiers are
/// distributed across lazy rows and can create several simultaneous pickers.
private struct BoundROMUpdateSettingsPresentation: ViewModifier {
    @ObservedObject private var updates = BoundROMUpdateManager.shared
    @State private var choosingFolder = false
    @State private var folderPickerAttempt = UUID()
    @State private var folderPickerDismissed = false
    @State private var confirmingFolder = false
    @State private var selectedFolder: BoundROMUpdateFolderSelection?

    func body(content: Content) -> some View {
        content
            .environment(\.boundROMUpdateSettingsActions, BoundROMUpdateSettingsActions(
                chooseFolder: {
                    folderPickerAttempt = UUID()
                    selectedFolder = nil
                    folderPickerDismissed = false
                    choosingFolder = true
                },
                enableUpdates: { confirmingFolder = true }))
            .sheet(isPresented: $choosingFolder, onDismiss: folderPickerDidDismiss) {
                let attempt = folderPickerAttempt
                BoundROMUpdateFolderPicker { url in
                    guard attempt == folderPickerAttempt else { return }
                    selectedFolder = url.map(BoundROMUpdateFolderSelection.init)
                    if folderPickerDismissed {
                        handOffSelectedFolder()
                    } else {
                        choosingFolder = false
                    }
                }
            }
            .confirmationDialog("Enable Automatic ROM Updates?", isPresented: $confirmingFolder, titleVisibility: .visible) {
                Button("Enable Automatic Updates") { updates.enable() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("New ROM versions start a new save. Your previous ROM and saves are backed up.")
            }
            .navigationDestination(isPresented: Binding(
                get: { updates.needsGameSelection },
                set: { if !$0 && updates.needsGameSelection { updates.cancelEnrollment() } })) {
                    BoundROMUpdateGameSelection(
                        choices: updates.enrollmentChoices,
                        canChooseGame: updates.canChooseEnrollmentGame,
                        suggestedGameID: updates.suggestedEnrollmentGameID,
                        confirm: { updates.selectGameForUpdates($0) },
                        cancel: { updates.cancelEnrollment() })
                    .onDisappear {
                        if updates.needsGameSelection { updates.cancelEnrollment() }
                    }
                }
    }

    private func folderPickerDidDismiss() {
        folderPickerDismissed = true
        handOffSelectedFolder()
    }

    private func handOffSelectedFolder() {
        // UIKit may send its selected URL before or after the sheet finishes
        // dismissing. Wait for both events, then consume the selection once.
        guard folderPickerDismissed, let selection = selectedFolder else { return }
        selectedFolder = nil
        // The manager captures its retained bookmark synchronously. Keep the
        // picker-provided access alive until that handoff has completed.
        withExtendedLifetime(selection) { updates.selectFolder(selection.url) }
    }
}

extension View {
    func boundROMUpdateSettingsPresentation() -> some View {
        modifier(BoundROMUpdateSettingsPresentation())
    }
}

private final class BoundROMUpdateFolderSelection {
    let url: URL
    private let accessing: Bool
    init(url: URL) {
        self.url = url
        accessing = url.startAccessingSecurityScopedResource()
    }
    deinit { if accessing { url.stopAccessingSecurityScopedResource() } }
}

private struct BoundROMUpdateFolderPicker: UIViewControllerRepresentable {
    let finished: (URL?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(finished: finished) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let finished: (URL?) -> Void
        private var completed = false
        init(finished: @escaping (URL?) -> Void) { self.finished = finished }
        private func finish(_ url: URL?) {
            guard !completed else { return }
            completed = true
            finished(url)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish(nil) }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            finish(urls.first)
        }
    }
}

private struct BoundROMUpdateGameSelection: View {
    let choices: [BoundROMUpdateManager.GameChoice]
    let canChooseGame: Bool
    let suggestedGameID: String?
    let confirm: (String?) -> Void
    let cancel: () -> Void
    @State private var selectedGameID: String?
    @State private var confirming = false

    var body: some View {
        Form {
            if canChooseGame {
                Picker("Game to Update", selection: $selectedGameID) {
                    Text("Add New Game").tag(String?.none)
                    ForEach(choices) { game in
                        Text(game.name).tag(Optional(game.id))
                    }
                }
                .pickerStyle(.inline)
                .accessibilityIdentifier("bound.rom-updates-game-picker")
            } else {
                LabeledContent("Game", value: choices.first(where: { $0.id == suggestedGameID })?.name ?? "Current Game")
                    .accessibilityIdentifier("bound.rom-updates-managed-game")
            }
        }
        .navigationTitle(canChooseGame ? "Game to Update" : "ROM Updates")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: cancel)
                    .accessibilityIdentifier("bound.rom-updates-cancel-setup")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Continue") { confirming = true }
                    .accessibilityIdentifier("bound.rom-updates-confirm-game")
            }
        }
        .confirmationDialog("Enable Automatic ROM Updates?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Enable Automatic Updates") { confirm(selectedGameID) }
                .accessibilityIdentifier("bound.rom-updates-confirm-enrollment")
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("New ROM versions start a new save. Your previous ROM and saves are backed up.")
        }
        .onAppear { selectedGameID = suggestedGameID }
    }
}

struct BoundDebuggingSettingsRows: View {
    @AppStorage(BoundDebuggingFeatures.key) private var enabled = false
    @ObservedObject private var github = BoundGitHubAccount.shared
    @Environment(\.openURL) private var openURL
    @State private var copiedCode = false

    var body: some View {
        Toggle("Debugging Features", isOn: $enabled)
            .accessibilityIdentifier("bound.settings-debugging-features")
            .onChange(of: enabled) { _, enabled in
                if !enabled { github.cancelSignIn() }
                NotificationCenter.default.post(name: BoundDebuggingFeatures.didChangeNotification, object: nil)
            }
            .onChange(of: github.userCode) { _, _ in copiedCode = false }
            .task(id: enabled) {
                if enabled { github.refresh() }
                else { github.cancelSignIn() }
            }
        if enabled {
            if github.needsCredentialRemoval {
                Button("Retry Sign Out") { github.signOut() }
                    .accessibilityIdentifier("bound.github-retry-sign-out")
            } else if let username = github.username {
                LabeledContent("GitHub", value: username)
                    .accessibilityIdentifier("bound.github-account")
                Button("Sign Out of GitHub") { github.signOut() }
                    .accessibilityIdentifier("bound.github-sign-out")
            } else {
                Button("Sign In to GitHub") {
                    github.signIn { url in openURL(url) }
                }
                .disabled(github.isSigningIn)
                .accessibilityIdentifier("bound.github-sign-in")
            }
            if let code = github.userCode {
                LabeledContent("Code") {
                    Text(code).monospaced().lineLimit(1).minimumScaleFactor(0.8).textSelection(.enabled)
                }
                .accessibilityIdentifier("bound.github-device-code")
                Button(copiedCode ? "Copied" : "Copy Code") {
                    UIPasteboard.general.string = code
                    copiedCode = true
                }
                .accessibilityIdentifier("bound.github-copy-code")
            }
            if github.isSigningIn {
                if let url = github.verificationURL {
                    Button("Open GitHub") { openURL(url) }
                        .accessibilityIdentifier("bound.github-open")
                }
                Button("Cancel Sign In") { github.cancelSignIn() }
                    .accessibilityIdentifier("bound.github-cancel")
            }
            if !github.status.isEmpty {
                Text(github.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("bound.github-status")
            }
        }
    }
}
