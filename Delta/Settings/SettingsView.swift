//
//  SettingsView.swift
//  Delta
//
//  Created by Caroline Moore on 3/31/26.
//  Copyright © 2026 Riley Testut. All rights reserved.
//

import SwiftUI

import DeltaCore
import Harmony

private struct SettingsBadge: View
{
    let text: String
    var color: Color = .accentColor

    var body: some View {
        Text(text)
            .font(.caption.bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color, in: Capsule())
            .foregroundStyle(.white)
    }
}

/// Optional actions and information that belong to an already-running game.
struct BoundSettingsGameplayContext {
    let emulationDetails: BoundEmulationDetails?
    var editControls: (() -> Void)? = nil
    var showCompanion: (() -> Void)? = nil
    var recordedPlayer: BoundRecordedPlayerSession? = nil
    var livePresence: BoundLivePresenceSession? = nil
}

/// Both entry points use this owner so closing and interactive dismissal share
/// one completion. Navigating to a detail page never runs presentation cleanup.
final class BoundSettingsHostingController: UIHostingController<SettingsView>, UIAdaptivePresentationControllerDelegate {
    private let closed: () -> Void
    private let syncOnClose: () -> Void
    private var finished = false
    private var closing = false

    init(model: BoundCompanionSettingsModel? = nil, gameplay: BoundSettingsGameplayContext? = nil,
         syncOnClose: @escaping () -> Void = { SyncManager.shared.sync() },
         closed: @escaping () -> Void = {}) {
        self.closed = closed
        self.syncOnClose = syncOnClose
        super.init(rootView: SettingsView(model: model, gameplay: gameplay))
        rootView.close = { [weak self] in self?.closeSettings() }
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("Use the shared Settings initializer") }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        presentationController?.delegate = self
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil { finishPresentation() }
    }
    func closeSettings() {
        guard !closing, !finished else { return }
        closing = true
        dismiss(animated: true) { [weak self] in self?.finishPresentation() }
    }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { finishPresentation() }
    func finishPresentation() {
        guard !finished else { return }
        finished = true
        syncOnClose()
        closed()
    }
}

private struct BoundSettingsCloseActionKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var boundSettingsCloseAction: (() -> Void)? {
        get { self[BoundSettingsCloseActionKey.self] }
        set { self[BoundSettingsCloseActionKey.self] = newValue }
    }
}

private struct BoundSettingsPageModifier: ViewModifier {
    @Environment(\.boundSettingsCloseAction) private var close

    func body(content: Content) -> some View {
        content.toolbar {
            if let close {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: close)
                        .accessibilityIdentifier("bound.settings-close")
                }
            }
        }
    }
}

extension View {
    /// Each pushed page owns its native toolbar. Standalone screens keep their
    /// existing dismissal controls when there is no shared Settings presenter.
    func boundSettingsPage() -> some View { modifier(BoundSettingsPageModifier()) }
}

struct SettingsView: View {
    @StateObject private var model: BoundCompanionSettingsModel
    @State private var resetting = false
    @State private var resetFailed = false
    @State private var resetRevision = 0
    @AppStorage(BoundMultiplayerFeatures.key) private var experimentalFeaturesEnabled = false
    @AppStorage(BoundDeveloperFeatures.key) private var developerFeaturesEnabled = false
    @State private var configurationExportFile: BoundConfigurationFile?
    @State private var pendingConfigurationExportFile: BoundConfigurationFile?
    @State private var exportingConfiguration = false
    @State private var configurationExportFailed = false
    var gameplay: BoundSettingsGameplayContext?
    var close: () -> Void = {}

    init(model: BoundCompanionSettingsModel? = nil, gameplay: BoundSettingsGameplayContext? = nil) {
        _model = StateObject(wrappedValue: model ?? BoundCompanionSettingsModel())
        self.gameplay = gameplay
    }

    var body: some View {
        VStack(spacing: 0) {
            NavigationStack {
                Form {
                    Section {
                        NavigationLink {
                            Form {
                                ControlsSection()
                                if experimentalFeaturesEnabled {
                                    BoundPlayerStateSetting()
                                    if let session = gameplay?.recordedPlayer { BoundRecordedPlayerControls(session: session) }
                                    if let session = gameplay?.livePresence { BoundLivePresenceControls(session: session) }
                                }
                                BoundCompanionControlsSections(model: model, gameplay: gameplay)
                                if !BoundFeatureVisibility.simplifiedSettings, let edit = gameplay?.editControls {
                                    Section { Button("Button placement") { edit(); close() } }
                                }
                            }.navigationTitle("Controls").navigationBarTitleDisplayMode(.inline)
                                .boundSettingsPage()
                        } label: {
                            SettingsRow(label: Text("Controls"), systemImage: "gamecontroller", color: .pink)
                        }.accessibilityIdentifier("bound.settings-controls")
                        NavigationLink {
                            AudioSettingsView().boundSettingsPage()
                        } label: {
                            SettingsRow(label: Text("Audio"), systemImage: "speaker.wave.2", color: .green)
                        }.accessibilityIdentifier("bound.settings-audio")
                        NavigationLink {
                            VideoSettingsView().boundSettingsPage()
                        } label: {
                            SettingsRow(label: Text("Video"), systemImage: "display", color: .teal)
                        }.accessibilityIdentifier("bound.settings-video")
                        NavigationLink {
                            Form { BoundAccountSocialSettings(); DeltaSyncSettingsSection() }
                                .navigationTitle("Account & Sync").navigationBarTitleDisplayMode(.inline)
                                .boundSettingsPage()
                        } label: {
                            SettingsRow(label: Text("Account & Sync"), systemImage: "person.crop.circle", color: .indigo)
                        }.accessibilityIdentifier("bound.settings-account")
                        NavigationLink {
                            Form {
                                BoundAppearanceSettings(emulationDetails: gameplay?.emulationDetails, includeAppearance: false)
                                Section("Cores") { CoreSettingsLinks() }
                                Section("Links") {
                                    Link(destination: URL(string: "https://evanvonessen.github.io/bound/current/")!) {
                                        SettingsRow(label: Text("Website"), systemImage: "globe", color: .blue) {
                                            Image(systemName: "arrow.up.right")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .accessibilityIdentifier("bound.website-link")
                                    Link(destination: URL(string: "https://evanvonessen.github.io/bound/current/changelog.html")!) {
                                        SettingsRow(label: Text("Changelog"), systemImage: "list.bullet.rectangle", color: .blue) {
                                            Image(systemName: "arrow.up.right")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .accessibilityIdentifier("bound.changelog-link")
                                    Link(destination: URL(string: "https://evanvonessen.github.io/bound/current/privacy.html")!) {
                                        SettingsRow(label: Text("Privacy Policy"), systemImage: "hand.raised", color: .blue) {
                                            Image(systemName: "arrow.up.right")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .accessibilityIdentifier("bound.privacy-policy-link")
                                    Link(destination: URL(string: "https://evanvonessen.github.io/bound/current/moderation.html")!) {
                                        SettingsRow(label: Text("Rules & Contact"), systemImage: "book.closed", color: .orange) {
                                            Image(systemName: "arrow.up.right")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    .accessibilityIdentifier("bound.rules-and-contact-link")
                                }
                                if !BoundFeatureVisibility.simplifiedSettings {
                                    OnlineMultiplayerSection()
                                }
                                if !BoundFeatureVisibility.simplifiedSettings { CreditsSection() }
                                #if DEBUG
                                Section("Developer") {
                                    NavigationLink("Advanced") { AdvancedSettingsView().boundSettingsPage() }
                                }
                                #endif
                            }.navigationTitle("About").navigationBarTitleDisplayMode(.inline)
                                .boundSettingsPage()
                        } label: {
                            SettingsRow(label: Text("About"), systemImage: "info.circle", color: .cyan)
                        }.accessibilityIdentifier("bound.settings-about")
                    }
                    Section {
                        Button("Reset Settings to Default") {
                            resetting = true
                            Task { @MainActor in
                                do {
                                    try await Settings.resetToDefaults()
                                    model.refresh()
                                    resetRevision += 1
                                } catch {
                                    resetFailed = true
                                }
                                resetting = false
                            }
                        }
                        .disabled(resetting)
                        .accessibilityIdentifier("bound.settings-reset-defaults")

                        Toggle("Enable Developer Features", isOn: $developerFeaturesEnabled)
                            .accessibilityIdentifier("bound.settings-developer-features")

                        Toggle("Enable Experimental Features", isOn: $experimentalFeaturesEnabled)
                            .accessibilityIdentifier("bound.settings-experimental-features")
                            .onChange(of: experimentalFeaturesEnabled) { _, enabled in
                                BoundMultiplayerFeatures.setEnabled(enabled)
                            }

                        if developerFeaturesEnabled {
                            Button("Export All Config") {
                                exportingConfiguration = true
                                Task { @MainActor in
                                    do {
                                        let file = try await BoundConfigurationExport.file()
                                        pendingConfigurationExportFile = file
                                        configurationExportFile = file
                                    } catch {
                                        exportingConfiguration = false
                                        configurationExportFailed = true
                                    }
                                }
                            }
                            .disabled(exportingConfiguration)
                            .accessibilityIdentifier("bound.settings-export-all-config")
                        }
                    }
                }
                .safeAreaPadding(.top, 8)
                .navigationTitle("Settings")
                .accessibilityIdentifier("bound.settings-root")
                .boundSettingsPage()
            }
            .environment(\.boundSettingsCloseAction, close)
            .id(resetRevision)
            .alert("Unable to Reset Settings", isPresented: $resetFailed) {
                Button("OK", role: .cancel) {}
            }
            .alert("Unable to Export Configuration", isPresented: $configurationExportFailed) {
                Button("OK", role: .cancel) {}
            }
            .sheet(item: $configurationExportFile, onDismiss: {
                pendingConfigurationExportFile?.removeTemporaryFile()
                pendingConfigurationExportFile = nil
                exportingConfiguration = false
            }) { file in
                BoundConfigurationFilePicker(file: file) {
                    configurationExportFile = nil
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Let navigation bars and backgrounds fill the side safe areas in landscape.
            .ignoresSafeArea(.container, edges: .horizontal)
        }
    }

}

// MARK: - Controls

private struct ControlsSection: View
{
    @SwiftUI.State
    private var gameControllerManager: ExternalGameControllerManager = .shared

    @SwiftUI.State private var opacity = Double(Settings.translucentControllerSkinOpacity)
    @SwiftUI.State private var controllerModeEnabled = BoundControllerModePreferences().isEnabled
    @SwiftUI.State private var controllerMultiviewEnabled = BoundControllerMultiviewPreferences().isEnabled

    var body: some View {
        Section("Controls") {
            Toggle("Controller Mode", isOn: $controllerModeEnabled)
                .accessibilityIdentifier("bound.controller-mode-enabled")
                .onChange(of: controllerModeEnabled) { _, enabled in
                    BoundControllerModePreferences().isEnabled = enabled
                }

            Toggle("Allow Controller to Control Multiview", isOn: $controllerMultiviewEnabled)
                .accessibilityIdentifier("bound.controller-multiview")
                .onChange(of: controllerMultiviewEnabled) { _, enabled in
                    BoundControllerMultiviewPreferences().isEnabled = enabled
                }

            NavigationLink {
                ControllerSettingsView().boundSettingsPage()
            } label: {
                SettingsRow(label: Text("Controllers"), systemImage: "gamecontroller", color: .purple) {
                    if !gameControllerManager.connectedControllers.isEmpty
                    {
                        Text("\(gameControllerManager.connectedControllers.count) Connected")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !BoundFeatureVisibility.simplifiedSettings {
            NavigationLink {
                SkinSettingsView().boundSettingsPage()
            } label: {
                SettingsRow(label: Text("Skins"), systemImage: "paintpalette", color: .pink)
            }

            NavigationLink {
                TouchHapticsView().boundSettingsPage()
            } label: {
                SettingsRow(label: Text("Touch & Haptics"), systemImage: "hand.tap", color: .red)
            }
            }
            if BoundFeatureVisibility.simplifiedSettings {
                VStack(alignment: .leading) {
                    LabeledContent("Controller opacity", value: "\(Int(opacity * 100))%")
                    Slider(value: $opacity, in: 0...1, step: 0.05)
                        .onChange(of: opacity) { _, value in Settings.translucentControllerSkinOpacity = value }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: BoundAppearancePreferences.didChangeNotification)) { _ in
            controllerModeEnabled = BoundControllerModePreferences().isEnabled
            controllerMultiviewEnabled = BoundControllerMultiviewPreferences().isEnabled
        }
    }
}


// MARK: - Online Multiplayer

private struct OnlineMultiplayerSection: View
{
    var body: some View {
        Section {
            NavigationLink {
                OnlineMultiplayerView().boundSettingsPage()
            } label: {
                SettingsRow(label: Text("Online Multiplayer"), systemImage: "globe", color: .orange)
            }
        }
    }
}

// MARK: - Online Multiplayer Detail

struct OnlineMultiplayerView: View
{
    @SwiftUI.State
    private var preferredWFCServer: String? = Settings.preferredWFCServer

    @SwiftUI.State
    private var isConfirmingReset: Bool = false

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    WFCServersView().boundSettingsPage()
                } label: {
                    LabeledContent {
                        if let serverName = preferredServerName
                        {
                            Text(serverName)
                        }
                    } label: {
                        Text("WFC Server")
                    }
                }

                if preferredWFCServer != nil
                {
                    Button("Reset Online Settings", role: .destructive) {
                        isConfirmingReset = true
                    }
                    .confirmationDialog("Are you sure you want to reset your online settings?", isPresented: $isConfirmingReset, titleVisibility: .visible) {
                        Button("Reset Online Settings", role: .destructive) {
                            WFCManager.shared.resetWFCConfiguration()
                        }
                    } message: {
                        Text("You may need to re-add any friend codes you’ve previously registered.")
                    }
                }
            } header: {
                Text("Nintendo DS")
            } footer: {
                Text("Choose the 3rd-party Nintendo WFC server Delta should use for online play in Nintendo DS games.")
            }
        }
        .navigationTitle("Online Multiplayer")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(NotificationCenter.default.publisher(for: Settings.didChangeNotification)) { notification in
            guard let name = notification.userInfo?[Settings.NotificationUserInfoKey.name] as? Settings.Name,
                  name == .preferredWFCServer else { return }

            preferredWFCServer = Settings.preferredWFCServer
        }
        .onAppear {
            preferredWFCServer = Settings.preferredWFCServer
        }
    }

    private var preferredServerName: String? {
        guard let preferredWFCServer else { return nil }

        if let servers = UserDefaults.standard.wfcServers, let knownServer = servers.first(where: { $0.dns == preferredWFCServer })
        {
            return knownServer.name
        }

        return preferredWFCServer
    }
}

// MARK: - Services

private struct DeltaSyncSettingsSection: View
{
    @SwiftUI.State
    private var syncingServiceName: String? = SyncManager.currentBoundService?.localizedName
    
    @SwiftUI.State
    private var syncConflictsCount: Int = 0
    
    @SwiftUI.State
    private var isAccountConnected: Bool = SyncManager.shared.coordinator?.account != nil

    var body: some View {
        Section {
            NavigationLink {
                SyncingServicesViewController.ViewRepresentable()
                    .ignoresSafeArea(.container, edges: [.top, .horizontal])
                    .boundSettingsPage()
            } label: {
                SettingsRow(label: Text("Delta Sync"), systemImage: "arrow.triangle.2.circlepath", color: .indigo) {
                    if let name = syncingServiceName {
                        Text(name).foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityIdentifier("bound.delta-sync-settings")

            if isAccountConnected
            {
                NavigationLink {
                    SyncStatusViewController.ViewRepresentable()
                        .ignoresSafeArea(.container, edges: [.top, .horizontal])
                        .boundSettingsPage()
                } label: {
                    SettingsRow(label: Text("Sync Status"), systemImage: "checkmark.icloud", color: .indigo) {
                        if syncConflictsCount > 0
                        {
                            SettingsBadge(text: "\(syncConflictsCount) conflicts", color: .red)
                        }
                        else
                        {
                            SettingsBadge(text: "Up-to-date", color: .green)
                        }
                    }
                }
            }

        } header: {
            Text("Cloud Sync")
        }
        .onReceive(NotificationCenter.default.publisher(for: Settings.didChangeNotification)) { notification in
            guard let name = notification.userInfo?[Settings.NotificationUserInfoKey.name] as? Settings.Name,
                  name == .syncingService else { return }
            
            refreshSyncStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: SyncCoordinator.didFinishSyncingNotification).receive(on: DispatchQueue.main)) { _ in
            refreshSyncStatus()
        }
        .onAppear {
            refreshSyncStatus()
        }
    }

    private func refreshSyncStatus()
    {
        syncingServiceName = SyncManager.currentBoundService?.localizedName
        isAccountConnected = SyncManager.shared.coordinator?.account != nil

        do {
            let records = try SyncManager.shared.recordController?.fetchConflictedRecords() ?? []
            syncConflictsCount = records.count
        } catch {
            Logger.main.error("Failed to refresh sync conflicts. \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - Patreon

private struct PatreonSection: View
{
    var body: some View {
        if PurchaseManager.shared.supportsExternalPurchases
        {
            Section {
                NavigationLink {
                    PatreonViewController.ViewRepresentable()
                        .ignoresSafeArea(.container, edges: [.top, .horizontal])
                        .boundSettingsPage()
                } label: {
                    SettingsRow(
                        label: Text(PurchaseManager.shared.isActivePatron
                            ? "Manage Subscription" : "Become a Patron"),
                        systemImage: "heart",
                        color: .accentColor
                    )
                }
            } footer: {
                Text("Get early access to new features and unlock exclusive app icons.")
            }
        }
    }
}

// MARK: - App Icon

private struct DisplaySection: View
{
    var body: some View {
        Section("Display") {
            NavigationLink {
                AltAppIconsViewController.ViewRepresentable()
                    .navigationBarTitleDisplayMode(.large)
                    .ignoresSafeArea(.container, edges: [.top, .horizontal])
                    .boundSettingsPage()
            } label: {
                SettingsRow(label: Text("App Icon"), systemImage: "square.grid.2x2", color: .blue)
            }
        }
    }
}

// MARK: - Credits

private struct CreditsSection: View
{
    var body: some View {
        Section("Credits") {
            NavigationLink {
                ContributorsView().boundSettingsPage()
            } label: {
                Text("Contributors")
            }

            NavigationLink {
                LicensesViewController.ViewRepresentable()
                    .ignoresSafeArea(.container, edges: [.top, .horizontal])
                    .boundSettingsPage()
            } label: {
                Text("Software Licenses")
            }
        }
    }
}

// MARK: - Support

private struct SupportSection: View
{
    @Environment(\.openURL)
    var openURL
    
    @SwiftUI.State
    private var showMailError = false

    var body: some View {
        Section {
            Button("Contact Us") {
                // TODO: support attachments
                let email = "support@altstore.io"
                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
                let subject = "Delta \(version) Feedback"
                let urlString = "mailto:\(email)?subject=\(subject)"
                
                if let url = URL(string: urlString)
                {
                    openURL(url) { success in
                        if !success { showMailError = true }
                    }
                }
            }
            .alert("Cannot Send Mail", isPresented: $showMailError) {}
            
            Link("Privacy Policy", destination: URL(string: "https://altstore.io/privacy")!)
            
            Link("Terms of Use", destination: URL(string: "https://altstore.io/terms")!)
        } header: {
            Text("Support")
        } footer: {
            RepresentedFooterView()
                .containerRelativeFrame(.horizontal)
        }
    }
}

// MARK: - Footer

private struct RepresentedFooterView: UIViewRepresentable
{
    func makeUIView(context: Context) -> FollowUsFooterView
    {
        let view = FollowUsFooterView(prefersFullColorIcons: false)
        view.stackView.spacing = 20
        view.stackView.isLayoutMarginsRelativeArrangement = true
        view.stackView.directionalLayoutMargins.top = 8
        view.stackView.directionalLayoutMargins.bottom = 20
        return view
    }

    func updateUIView(_ uiView: FollowUsFooterView, context: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: FollowUsFooterView, context: Context) -> CGSize?
    {
        guard let width = proposal.width ?? uiView.window?.bounds.width else { return nil }

        return uiView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
    }
}

#Preview {
    SettingsView()
}
