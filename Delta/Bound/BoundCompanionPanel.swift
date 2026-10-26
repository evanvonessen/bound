import SwiftUI
import UIKit
import AVFoundation
import Combine
import DeltaCore

/// Persistent companion configuration, usable without an emulator or sharing session.
@MainActor
final class BoundCompanionSettingsModel: ObservableObject {
    struct Configuration: Equatable {
        let uiVersion: BoundUIVersion
        let buttonType: BoundCompanionButtonType
        let availableContents: [BoundPiPContent]
        let orderedContents: [BoundPiPContent]
        let assignments: [[BoundPiPContent]]
        let enabled: [Bool]
        let opacities: [Double]
    }
    let preferences: BoundPiPPreferences
    @Published private(set) var configuration: Configuration
    private var observations = Set<AnyCancellable>()
    private var debugGame = false
    var uiVersion: BoundUIVersion { configuration.uiVersion }
    var buttonType: BoundCompanionButtonType { configuration.buttonType }
    var availableContents: [BoundPiPContent] { configuration.availableContents }

    init(preferences: BoundPiPPreferences? = nil) {
        self.preferences = preferences ?? BoundPiPPreferences()
        self.configuration = Self.read(self.preferences)
        for name in [BoundPiPPreferences.didChangeNotification, BoundUIVersionPreferences.didChangeNotification,
                     BoundCompanionButtonPreferences.didChangeNotification, BoundDeveloperFeatures.didChange] {
            NotificationCenter.default.publisher(for: name).receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.refresh() }.store(in: &observations)
        }
    }
    private static func read(_ preferences: BoundPiPPreferences, debugGame: Bool = false) -> Configuration {
        let buttonType = preferences.buttonType
        var assignments = (0..<buttonType.splitButtonCount).map {
            preferences.assignedContents(for: $0, buttonType: buttonType)
        }
        let assigned = Set(assignments.flatMap { $0 })
        var available = buttonType.splitButtonCount > 0
            ? preferences.orderedContents.filter(assigned.contains)
            : preferences.enabledContents(uiVersion: preferences.uiVersion)
        if debugGame || preferences.developerFeaturesEnabled {
            available.removeAll { $0 == .connections }
            available.insert(.connections, at: min(3, available.count))
            if !assignments.isEmpty {
                if !assignments.contains(where: { $0.contains(.connections) }) {
                    assignments[assignments.count - 1].append(.connections)
                }
                assignments = assignments.map { choices in available.filter(choices.contains) }
            }
        }
        return Configuration(uiVersion: preferences.uiVersion, buttonType: buttonType,
            availableContents: available, orderedContents: preferences.orderedContents,
            assignments: assignments, enabled: BoundPiPContent.allCases.map(preferences.isEnabled),
            opacities: BoundPiPContent.allCases.map(preferences.opacity))
    }
    func refresh() {
        let next = Self.read(preferences, debugGame: debugGame)
        if configuration != next { configuration = next }
    }
    func setDebugGame(_ enabled: Bool) {
        guard debugGame != enabled else { return }
        debugGame = enabled; refresh()
    }
    func setButtonType(_ type: BoundCompanionButtonType) { preferences.buttonType = type; refresh() }
    func setAssigned(_ enabled: Bool, content: BoundPiPContent, for button: Int) {
        var contents = preferences.assignedContents(for: button, buttonType: buttonType).filter { $0 != content }
        if enabled { contents.append(content) }
        preferences.setAssignedContents(contents, for: button, buttonType: buttonType); refresh()
    }
    func setContentOrder(_ contents: [BoundPiPContent]) {
        guard uiVersion == .option2 else { return }
        preferences.setContentOrder(contents); refresh()
    }
    func setContentEnabled(_ enabled: Bool, for content: BoundPiPContent) {
        preferences.setEnabled(enabled, for: content); refresh()
    }
}

@MainActor
final class BoundCompanionState: ObservableObject {
    @Published var selected = 0
    @Published private(set) var configuration: BoundCompanionSettingsModel.Configuration
    let settings: BoundCompanionSettingsModel
    private var settingsObservation: AnyCancellable?
    private var rememberedButtonViews: [BoundCompanionButtonType: [Int: BoundPiPContent]] = [:]
    private var activeButtons: [BoundCompanionButtonType: Int] = [:]
    var uiVersion: BoundUIVersion { configuration.uiVersion }
    var buttonType: BoundCompanionButtonType { configuration.buttonType }
    @Published var landscape = false
    @Published var chartTopInset: CGFloat = 0
    @Published var referenceTopInset: CGFloat = 0
    @Published var hidden = false
    @Published var showingFriends = false {
        didSet { if showingFriends { macControllerFocused = false } }
    }
    @Published var showingSettings = false {
        didSet { if showingSettings { macControllerFocused = false } }
    }
    // Controller focus is a session choice, independent of sidebar visibility.
    @Published var macControllerFocused = false {
        didSet { if oldValue != macControllerFocused { changed?() } }
    }
    // Desktop reference selection is separate from the iPhone PiP cycle.
    @Published var macReference: BoundPiPContent = .dex {
        didSet {
            if macReference == .dex || macReference == .bosses { macMidReference = macReference }
            if [.notes, .types, .connections].contains(macReference) { macBottomReference = macReference }
            if oldValue != macReference { changed?() }
        }
    }
    @Published var macMidReference: BoundPiPContent = .dex
    @Published var macBottomReference: BoundPiPContent = .types
    @Published var macSidebarVisible = true {
        didSet {
            if !macSidebarVisible { macControllerFocused = false }
            if oldValue != macSidebarVisible { changed?() }
        }
    }
    @Published var macSidebarWidth: CGFloat = 420 { didSet { if oldValue != macSidebarWidth { changed?() } } }
    @Published var macTopFraction: CGFloat = 0.44
    @Published var macFriendVisible = true { didSet { if oldValue != macFriendVisible { changed?() } } }
    @Published var macReferenceVisible = true {
        didSet {
            if !macReferenceVisible { macControllerFocused = false }
            if oldValue != macReferenceVisible { changed?() }
        }
    }
    @Published var revision = 0
    @Published var emulationDetails: BoundEmulationDetails?
    #if DEBUG
    @Published var fixtureVideo = false
    #endif
    var displaysFixtureVideo: Bool {
        #if DEBUG
        return fixtureVideo
        #else
        return false
        #endif
    }
    let preferences: BoundPiPPreferences
    init(preferences: BoundPiPPreferences? = nil) {
        self.preferences = preferences ?? BoundPiPPreferences()
        self.settings = BoundCompanionSettingsModel(preferences: self.preferences)
        self.configuration = settings.configuration
        reconcileButtonSelections()
        settingsObservation = settings.$configuration.dropFirst().sink { [weak self] configuration in
            guard let self else { return }
            var nextContent = self.content
            let changesButtonStyle = self.buttonType != configuration.buttonType
            self.configuration = configuration
            // Returning to a split style restores that style's active button,
            // without replacing its remembered icon with the other style's view.
            if changesButtonStyle, let button = self.activeButtons[self.buttonType],
               configuration.assignments.indices.contains(button),
               let remembered = self.rememberedButtonViews[self.buttonType]?[button],
               configuration.assignments[button].contains(remembered) {
                nextContent = remembered
            }
            self.reconcileSelection(previousContent: nextContent)
            self.refresh()
        }
    }
    var changed: (() -> Void)?
    var pendingControlEditor = false
    var editControls: (() -> Void)?
    var sharingChanged: ((Bool) -> Void)?
    var selectionChanged: (() -> Void)?
    var usesAssignedButtons: Bool { buttonType.splitButtonCount > 0 }
    var availableContents: [BoundPiPContent] { configuration.availableContents }
    var content: BoundPiPContent { availableContents.indices.contains(selected) ? availableContents[selected] : .friend }
    var displayedButtonContents: [BoundPiPContent?] {
        configuration.assignments.enumerated().map { button, choices in
            if let remembered = rememberedButtonViews[buttonType]?[button], choices.contains(remembered) {
                return remembered
            }
            return choices.first
        }
    }
    func updateButtonType() {
        settings.refresh()
    }
    func setButtonType(_ type: BoundCompanionButtonType) {
        settings.setButtonType(type)
    }
    func setAssigned(_ enabled: Bool, content: BoundPiPContent, for button: Int) {
        settings.setAssigned(enabled, content: content, for: button)
    }
    func advanceButton(_ button: Int) {
        guard usesAssignedButtons, configuration.assignments.indices.contains(button),
              let remembered = displayedButtonContents[button] else { return }
        let contents = configuration.assignments[button]
        let next: BoundPiPContent
        if !hidden, activeButtons[buttonType] == button, let index = contents.firstIndex(of: content) {
            next = contents[(index + 1) % contents.count]
        } else { next = remembered }
        guard let index = availableContents.firstIndex(of: next) else { return }
        selectionChanged?()
        activeButtons[buttonType] = button
        rememberedButtonViews[buttonType, default: [:]][button] = next
        selected = index
        hidden = false
        refresh()
    }
    func updateUIVersion() {
        settings.refresh()
    }
    func setContentOrder(_ contents: [BoundPiPContent]) {
        settings.setContentOrder(contents)
    }
    func setContentEnabled(_ enabled: Bool, for content: BoundPiPContent) {
        settings.setContentEnabled(enabled, for: content)
    }
    private func reconcileSelection(previousContent: BoundPiPContent) {
        if let index = availableContents.firstIndex(of: previousContent) {
            selected = index
        } else {
            selectionChanged?(); selected = 0; hidden = false
        }
        reconcileButtonSelections()
    }
    private func reconcileButtonSelections() {
        guard usesAssignedButtons else { return }
        var remembered = rememberedButtonViews[buttonType] ?? [:]
        remembered = remembered.filter { configuration.assignments.indices.contains($0.key) }
        for (button, choices) in configuration.assignments.enumerated() {
            if let previous = remembered[button], choices.contains(previous) { continue }
            remembered[button] = choices.first
        }
        let currentButton = activeButtons[buttonType]
        let active = currentButton.flatMap { button in
            configuration.assignments.indices.contains(button) && configuration.assignments[button].contains(content) ? button : nil
        } ?? configuration.assignments.firstIndex(where: { $0.contains(content) })
        activeButtons[buttonType] = active
        if let active { remembered[active] = content }
        rememberedButtonViews[buttonType] = remembered
    }
    func advancePanel() {
        guard !availableContents.isEmpty else { return }
        if !hidden { selected = (selected + 1) % availableContents.count }
        reconcileButtonSelections()
        hidden = false
        refresh()
    }
    func resetPresentation() {
        macControllerFocused = false
        settings.refresh()
        rememberedButtonViews.removeAll()
        activeButtons.removeAll()
        selected = 0
        hidden = false
        reconcileButtonSelections()
        refresh()
    }
    func refresh() { revision += 1; changed?() }
}

/// The overlay yields native button touches even if a moved PiP crosses a button.
final class BoundOverlayView: UIView {
    var yieldsTouch: (@MainActor (CGPoint) -> Bool)?
    var forwardedTouch: (@MainActor (CGPoint, UIEvent?) -> UIView?)?
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, alpha > 0.01, isUserInteractionEnabled else { return nil }
        if let forwarded = forwardedTouch?(point, event) { return forwarded }
        if yieldsTouch?(point) == true { return nil }
        return super.hitTest(point, with: event)
    }
}

@MainActor
enum BoundMacControllerActionRouting {
    static let referenceContents: [BoundPiPContent] = [.dex, .bosses, .notes, .types, .connections]

    static func inputMapping(_ mapping: BoundControllerInputMapping) -> BoundControllerInputMapping {
        var mapping = mapping
        // Automatic focus uses gamepad inputs. Keep Mac keyboard gameplay and
        // any explicitly assigned keyboard companion shortcuts available.
        if mapping.gameControllerInputType == .keyboard { mapping.multiviewActive = false }
        return mapping
    }

    static func isEnabled(multiview: Bool, showingFriends: Bool, showingSettings: Bool) -> Bool {
        multiview && !showingFriends && !showingSettings
    }

    static func canToggleFocus(multiview: Bool, state: BoundCompanionState) -> Bool {
        isEnabled(multiview: multiview, showingFriends: state.showingFriends, showingSettings: state.showingSettings)
            && state.macSidebarVisible && state.macReferenceVisible
    }

    static func allowsPanelAction(_ action: ActionInput, controllerType: GameControllerInputType,
                                  multiview: Bool, state: BoundCompanionState) -> Bool {
        guard isEnabled(multiview: multiview, showingFriends: state.showingFriends,
                        showingSettings: state.showingSettings) else { return false }
        if action == .toggleBoundMultiview { return canToggleFocus(multiview: multiview, state: state) }
        // Keyboard gameplay remains independent; only explicitly assigned
        // keyboard shortcuts can operate references without gamepad focus.
        return controllerType == .keyboard || state.macControllerFocused
    }

    static func apply(_ action: ActionInput, to state: BoundCompanionState) {
        switch action {
        case .toggleBoundFriend: state.macFriendVisible.toggle()
        case .boundHideFriend: state.macFriendVisible = false
        case .toggleBoundMultiview: state.macControllerFocused.toggle()
        case .boundHideMultiview: state.macReferenceVisible = false
        case .boundShowDex: show(.dex, in: state)
        case .boundShowBosses: show(.bosses, in: state)
        case .boundShowTypes: show(.types, in: state)
        case .cycleBoundPanels: advanceReference(direction: 1, in: state)
        case .boundNextView: advanceReference(direction: 1, in: state)
        case .boundPreviousView: advanceReference(direction: -1, in: state)
        default: break
        }
    }

    private static func show(_ content: BoundPiPContent, in state: BoundCompanionState) {
        state.macReference = content
        state.macReferenceVisible = true
        state.macSidebarVisible = true
    }

    private static func advanceReference(direction: Int, in state: BoundCompanionState) {
        guard let index = referenceContents.firstIndex(of: state.macReference), !referenceContents.isEmpty else { return }
        let next = (index + (direction > 0 ? 1 : -1) + referenceContents.count) % referenceContents.count
        show(referenceContents[next], in: state)
    }
}

@MainActor
final class BoundCompanionCoordinator {
    let sharing: FriendSharingSession
    #if DEBUG && targetEnvironment(simulator)
    private let usesLocalPairedFixture: Bool
    #endif
    let onboarding: FriendOnboarding
    let account: BoundFriendAccount
    let state: BoundCompanionState
    lazy var romMultiplayer = BoundROMMultiplayerCoordinator(sharing: sharing, onboarding: onboarding, account: account)
    init(state: BoundCompanionState? = nil) {
        self.state = state ?? BoundCompanionState()
        #if DEBUG && targetEnvironment(simulator)
        if let qa = BoundFullAppGameplayQA.current {
            account = qa.account
            onboarding = FriendOnboarding(sendJiggle: { _, _ in "QA notifications disabled" })
        } else {
            account = .shared; onboarding = FriendOnboarding()
        }
        #else
        account = .shared; onboarding = FriendOnboarding()
        #endif
        #if DEBUG && targetEnvironment(simulator)
        let environment = ProcessInfo.processInfo.environment
        if ProcessInfo.processInfo.arguments.contains("--bound-ui-paired-transport"),
           let peer = environment["BOUND_PAIR_PEER"], ["A", "B"].contains(peer),
           let rawPort = environment["BOUND_PAIR_PORT"], let port = Int(rawPort), (1024...65535).contains(port) {
            sharing = FriendSharingSession(configuration: .init(appID: String(repeating: "0", count: 32), channel: "localpair", uid: peer == "A" ? 1 : 2, remoteUID: peer == "A" ? 2 : 1, token: "offline-fixture-not-an-RTC-token"),
                transport: BoundLocalPairedTransport(peer: peer, port: port), authenticatedMode: false)
            usesLocalPairedFixture = true
        } else { sharing = FriendSharingSession(authenticatedMode: true); usesLocalPairedFixture = false }
        #else
        sharing = FriendSharingSession(authenticatedMode: true)
        #endif
    }
    private var host: UIHostingController<BoundCompanionPresentation>?
    private let landscapeCompanion = BoundLandscapeCompanionModel()
    private lazy var landscapeArrangement = BoundLandscapeArrangementModel()
    private lazy var arrangementLayers = BoundLandscapePanelLayers(model: landscapeArrangement)
    private var arrangementEditorHost: UIHostingController<BoundLandscapeArrangementOverlay>?
    private var arrangementEditorOverlay: BoundOverlayView?
    private var arrangementOpacityGesture: BoundLandscapeOpacityGesture?
    private var multiviewSwipeGesture: BoundLandscapeMultiviewSwipeGesture?
    private var macHost: UIHostingController<BoundMacWorkspaceView>?
    private var controls: BoundCompanionCycleButton?
    private var subscriptions = Set<AnyCancellable>()
    private var nativeMenuAccessibility: BoundNativeMenuAccessibilityElement?
    private weak var settingsPresenter: UIViewController?
    private var overlay: BoundOverlayView?
    private weak var owner: GameViewController?
    private weak var boundCore: EmulatorCore?
    private var gameID = ""
    private var notesPaused = false
    private var notesDismissalTask: Task<Void, Never>?
    private var pendingControllerReferenceAction: ActionInput?
    private var lastControllerFocusContent: BoundPiPContent?
    private var macSheetPaused = false
    private weak var macSheetCore: EmulatorCore?
    private(set) var isEditingNotes = false
    private var isEditingText = false
    private var keyboardHeight: CGFloat = 0
    private var observers: [NSObjectProtocol] = []
    private var foregroundTask: Task<Void, Never>?
    private var multiplayerServicesForeground = true
    private var gestures: BoundPiPGestures?
    private var geometry: BoundPiPLayout?
    private var previousScreenLayout: BoundScreenLayout?
    private var translation = CGSize.zero
    private var pinchScale: CGFloat = 1
    private var initialScale = 1.0
    private var initialOpacity = 1.0
    private var liveOpacity: Double?
    private var fadingContent: BoundPiPContent?
    private var resizingContent: BoundPiPContent?
    #if DEBUG
    private let fixturePresenter = FriendSharingCanvasPresenter()
    #endif
    private lazy var tap = BoundDeltaFrameTap { [weak self] frame in self?.sharing.receivePlaybackFrame(frame) }
    let playerStateDisplay = BoundPlayerStateDisplay()
    private var friendInteractionPanel: BoundFriendInteractionPanel?
    #if DEBUG && targetEnvironment(simulator)
    var friendDialogueReading: BoundFriendDialogueProbe.Reading { friendInteractionPanel?.probe.read() ?? .init() }
    #endif
    func install(in owner: GameViewController) {
        guard host == nil, macHost == nil else { return }
        self.owner = owner
        let friendPanel = BoundFriendInteractionPanel(session: sharing.interactions)
        friendPanel.frame = owner.view.bounds; owner.view.addSubview(friendPanel)
        friendPanel.name = { [weak self] in self?.onboarding.selected?.displayName ?? "Friend" }
        friendPanel.willOpen = { [weak owner] in owner?.releaseBoundFriendGameplayInputs() }
        friendInteractionPanel = friendPanel
        let soulBanner = BoundSoulBanner()
        owner.view.addSubview(soulBanner); soulBanner.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            soulBanner.centerXAnchor.constraint(equalTo: owner.view.safeAreaLayoutGuide.centerXAnchor),
            soulBanner.topAnchor.constraint(equalTo: owner.view.safeAreaLayoutGuide.topAnchor, constant: 8),
            soulBanner.widthAnchor.constraint(lessThanOrEqualTo: owner.view.safeAreaLayoutGuide.widthAnchor, constant: -24)
        ])
        sharing.soulLink.bannerChanged = { [weak soulBanner] message in soulBanner?.show(message) }
        let deathNotice = UIHostingController(rootView: BoundSoulDeathNotice(session: sharing.soulLink))
        deathNotice.sizingOptions = [.intrinsicContentSize]
        deathNotice.view.backgroundColor = .clear
        owner.addChild(deathNotice); owner.view.addSubview(deathNotice.view); deathNotice.didMove(toParent: owner)
        deathNotice.view.translatesAutoresizingMaskIntoConstraints = false
        let deathWidth = deathNotice.view.widthAnchor.constraint(equalTo: owner.view.safeAreaLayoutGuide.widthAnchor, constant: -32)
        deathWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            deathWidth,
            deathNotice.view.topAnchor.constraint(equalTo: owner.view.safeAreaLayoutGuide.topAnchor, constant: 40),
            deathNotice.view.centerXAnchor.constraint(equalTo: owner.view.safeAreaLayoutGuide.centerXAnchor),
            deathNotice.view.widthAnchor.constraint(lessThanOrEqualToConstant: 400)
        ])
        sharing.soulLink.canPresentDeathMoment = { [weak self, weak owner, weak noticeView = deathNotice.view] in
            guard let self, let owner else { return false }
            let visible = owner.view.window?.windowScene?.hasKeyboardFocus == true && owner.presentedViewController == nil
                && !self.state.showingFriends && !self.state.showingSettings && !self.isEditingNotes && !self.isEditingText
            if visible, let noticeView { owner.view.bringSubviewToFront(noticeView) }
            return visible
        }

        sharing.interactions.canPresent = { [weak self, weak owner] in
            guard let self, let owner else { return false }
            return owner.emulatorCore?.state == .running && owner.view.window?.windowScene?.hasKeyboardFocus == true
                && owner.presentedViewController == nil && !self.state.showingFriends && !self.state.showingSettings
                && !self.isEditingNotes && !self.isEditingText
        }
        sharing.interactions.changed = { [weak friendPanel] in friendPanel?.render() }
        playerStateDisplay.attachPresence(sharing.livePresence, friendName: { [weak self] in
            self?.onboarding.selected?.displayName ?? "Friend"
        })
        playerStateDisplay.install(in: owner)
        #if DEBUG && targetEnvironment(simulator)
        BoundFullAppGameplayQA.current?.attach(self, owner: owner)
        #endif
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--bound-ui-reset-layout") {
            UserDefaults.standard.removeObject(forKey: BoundControllerModePreferences.key)
            UserDefaults.standard.removeObject(forKey: BoundControllerModePreferences.layoutKey)
            UserDefaults.standard.removeObject(forKey: BoundControllerNavigationPreferences.key)
            UserDefaults.standard.removeObject(forKey: BoundControllerMultiviewPreferences.key)
            UserDefaults.standard.removeObject(forKey: BoundControllerButtonGridPreferences.enabledKey)
            UserDefaults.standard.removeObject(forKey: BoundControllerButtonGridPreferences.spacingKey)
            UserDefaults.standard.removeObject(forKey: "bound.landscape.buttons.v1")
            UserDefaults.standard.removeObject(forKey: BoundUIVersionPreferences.key)
            UserDefaults.standard.removeObject(forKey: BoundExperimentalSettingsPreferences.key)
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("bound.delta.pip.v1.") || key.hasPrefix("bound.delta.pip.v2.") || key.hasPrefix("bound.controls.v1.") || key.hasPrefix("bound.landscape.v1.") || key.hasPrefix("bound.landscape.option3.") || key.hasPrefix("bound.landscape.option4.") || key.hasPrefix("bound.landscape.option5.") || key.hasPrefix("bound.landscape.option6.") || key.hasPrefix("bound.landscape.option7.") || key.hasPrefix("bound.landscape.controller-mode.") || key.hasPrefix("bound.landscape.controller-mode2.") || key.hasPrefix("bound.landscape.controller-mode3.") || key.hasPrefix("bound.landscape.controller-unified.") || key == "bound.landscape.game-screen.v1" { UserDefaults.standard.removeObject(forKey: key) }
        }
        #endif
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--bound-ui-screen-layout-bound") { BoundAppearancePreferences().screenLayout = .bound }
        if ProcessInfo.processInfo.arguments.contains("--bound-ui-reset-screen-layout") { UserDefaults.standard.removeObject(forKey: BoundAppearancePreferences.screenLayoutKey) }
        #endif
        state.changed = { [weak self, weak owner] in
            owner?.view.setNeedsLayout()
            self?.refreshControllerMultiviewRouting()
        }
        state.editControls = { [weak self] in self?.editControls() }
        state.selectionChanged = { [weak self] in self?.cancelInteractions() }
        state.sharingChanged = { [weak self] in self?.tap.setEnabled($0) }
        for name in [BoundMultiplayerFeatures.didChange, Settings.didResetNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshMultiplayerServices() }
            })
        }
        // Every observer below explicitly requests OperationQueue.main. The main-queue
        // contract is synchronous, so assume MainActor isolation inside the callback
        // to preserve immediate controller handoffs and lifecycle updates.
        observers.append(NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let owner = self.owner, let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
                let local = owner.view.convert(frame, from: nil)
                self.keyboardHeight = owner.presentedViewController == nil ? max(0, owner.view.bounds.maxY - local.minY) : 0
                owner.view.setNeedsLayout()
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: BoundAppearancePreferences.didChangeNotification, object: nil, queue: .main) { [weak self, weak owner] notification in
            MainActor.assumeIsolated {
                self?.cancelInteractions()
                owner?.view.setNeedsLayout()
                if notification.userInfo?[BoundControllerMultiviewPreferences.key] != nil {
                    owner?.refreshBoundControllerPreferences()
                }
                self?.refreshControllerMultiviewRouting()
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: BoundControllerNavigationEvent.hideMultiviewNotificationName, object: nil, queue: .main) { [weak self] notification in
            MainActor.assumeIsolated {
                guard let self, let content = self.controllerReferenceContent,
                      BoundControllerNavigationEvent.hideMultiviewRequestMatches(
                        notification, gameID: self.gameID, content: content,
                        available: self.automaticControllerMultiviewAvailable
                      ) else { return }
                if self.macHost != nil { self.resetMacControllerFocus() }
                else if self.landscapeArrangement.active { self.landscapeArrangement.toggleReference() }
                else if self.landscapeCompanion.active { self.landscapeCompanion.hideReference() }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: Settings.didResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.cancelInteractions()
                let controllerMode = BoundControllerModePreferences()
                self.landscapeArrangement.reload(option: self.landscapeCompanion.preferences.option,
                    controllerModeEnabled: controllerMode.isEnabled, controllerModeLayout: controllerMode.layout)
                self.landscapeCompanion.reload()
                self.state.resetPresentation()
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: BoundCompanionButtonPreferences.didChangeNotification, object: nil, queue: .main) { [weak self, weak owner] _ in
            MainActor.assumeIsolated {
                self?.cancelInteractions()
                self?.controls?.isHighlighted = false
                self?.state.updateButtonType()
                owner?.view.setNeedsLayout()
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: BoundUIVersionPreferences.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.cancelInteractions()
                self?.state.updateUIVersion()
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: BoundAccountSocialSettings.stopSharingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sharing.stop()
                self?.onboarding.signOut()
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resetMacControllerFocus() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.background() }
        })
        // The sharing session restores only a previously active connection.
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.foreground() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleNotesDismissalIfNeeded() }
        })
        if BoundMacWorkspacePlatform.isEnabled {
            installMacWorkspace(in: owner)
        } else {
            landscapeCompanion.reload()
            landscapeCompanion.needsLayout = { [weak self, weak owner] in
                owner?.view.setNeedsLayout()
                self?.refreshControllerMultiviewRouting()
            }
            landscapeCompanion.beforeSwitch = { [weak self, weak owner] in
                owner?.view.endEditing(true)
                self?.gestures?.cancel()
                owner?.controllerView.cancelTouchInputs()
            }
            landscapeCompanion.beginArrangement = { [weak self, weak owner] in
                guard let self, let owner, !self.isEditingNotes, owner.presentedViewController == nil,
                      !self.state.showingFriends, !self.state.showingSettings else { return false }
                self.notesEditing(true)
                return true
            }
            landscapeCompanion.endArrangement = { [weak self] resume in self?.notesEditing(false, allowResume: resume) }
            let alignmentFeedback = UISelectionFeedbackGenerator()
            landscapeArrangement.buttonDidAlign = {
                guard Settings.isButtonHapticFeedbackEnabled else { return }
                alignmentFeedback.selectionChanged()
                alignmentFeedback.prepare()
            }
            landscapeArrangement.needsLayout = { [weak self, weak owner] in
                owner?.view.setNeedsLayout()
                self?.refreshControllerMultiviewRouting()
            }
            landscapeArrangement.beforeSwitch = { [weak self, weak owner] in
                owner?.view.endEditing(true)
                owner?.controllerView.cancelTouchInputs()
                self?.gestures?.cancel()
            }
            landscapeArrangement.beginArrangement = { [weak self, weak owner] in
                guard let self, let owner, self.landscapeArrangement.active,
                      owner.presentedViewController == nil, !self.state.showingFriends, !self.state.showingSettings else { return false }
                owner.view.endEditing(true)
                self.notesEditing(true)
                return true
            }
            landscapeArrangement.endArrangement = { [weak self] resume in self?.notesEditing(false, allowResume: resume) }
            arrangementOpacityGesture = BoundLandscapeOpacityGesture(view: owner.view, model: landscapeArrangement)
            arrangementLayers.owner = owner
            arrangementLayers.controller = owner.controllerView
            let panel = BoundCompanionPresentation(sharing: sharing, state: state, landscape: landscapeCompanion, arrangement: landscapeArrangement, layers: arrangementLayers, gameID: (owner.game as? Game)?.identifier ?? "", editingChanged: { [weak self] in
                guard let self, !self.landscapeCompanion.editing, !self.landscapeArrangement.editing else { return }
                self.notesEditing($0)
            }, textEditingChanged: { [weak self] in self?.textEditing($0) }, currentSave: { [weak self] gameID in
                guard let self else { throw BoundRRDexSave.ImportError.currentGameUnavailable }
                return try self.importCurrentRRDexSave(gameID: gameID)
            })
            let host = UIHostingController(rootView: panel)
            arrangementLayers.presentationHost = host
            // The coordinator positions the overlay and applies portrait top insets.
            // A second inherited home-indicator inset would shrink the visible video
            // and shift the bottom-corner content above its actual PiP frame.
            host.safeAreaRegions = []
            host.view.backgroundColor = .clear
            let overlay = BoundOverlayView()
            overlay.accessibilityIdentifier = "bound.companion-container"
            overlay.yieldsTouch = { [weak self, weak overlay] point in
                guard let self, let owner = self.owner, let overlay else { return false }
                if self.arrangementLayers.active {
                    return !(self.landscapeArrangement.isButtonVisible(.friend) && self.landscapeArrangement.layout.friendButton.contains(point))
                        && !(self.landscapeArrangement.isButtonVisible(.multiview) && self.landscapeArrangement.layout.viewsButton.contains(point))
                }
                if self.landscapeArrangement.active { return !self.landscapeArrangement.receivesTouch(at: point) }
                if self.landscapeCompanion.active { return !self.landscapeCompanion.receivesTouch(at: point) }
                guard !self.isEditingNotes else { return false }
                let local = owner.controllerView.convert(point, from: overlay)
                return owner.controllerView.controlHitFrames.contains { $0.contains(local) }
            }
            overlay.forwardedTouch = { [weak self] point, event in
                self?.arrangementLayers.referenceHit(at: point, event: event)
            }
            owner.addChild(host); owner.view.addSubview(overlay); overlay.addSubview(host.view); host.didMove(toParent: owner)
            self.overlay = overlay; self.host = host
            arrangementLayers.overlay = overlay
            let editorHost = UIHostingController(rootView: BoundLandscapeArrangementOverlay(model: landscapeArrangement, showsButtons: false))
            editorHost.safeAreaRegions = []
            editorHost.view.backgroundColor = .clear
            let editorOverlay = BoundOverlayView()
            editorOverlay.isHidden = true
            editorOverlay.backgroundColor = .clear
            owner.addChild(editorHost)
            owner.view.addSubview(editorOverlay)
            editorOverlay.addSubview(editorHost.view)
            editorHost.didMove(toParent: owner)
            arrangementEditorHost = editorHost
            arrangementEditorOverlay = editorOverlay
            arrangementLayers.editor = editorOverlay
            multiviewSwipeGesture = BoundLandscapeMultiviewSwipeGesture(view: owner.view, model: landscapeArrangement,
                isButtonPoint: { [weak self] point in
                    self?.arrangementLayers.buttonFrames.contains(where: { $0.contains(point) }) ?? false
                })
            let controls = BoundCompanionCycleButton()
            controls.cycle = { [weak self] in
                self?.cyclePanels()
            }
            controls.activateSegment = { [weak self] button in
                guard let self, self.state.usesAssignedButtons else { return }
                self.owner?.view.endEditing(true)
                self.cancelInteractions()
                self.state.advanceButton(button)
            }
            owner.view.addSubview(controls); self.controls = controls
        }
        sharing.$joined.combineLatest(sharing.$active, sharing.$videoPublishing).sink { [weak self] joined, active, video in
            self?.tap.setEnabled(joined && active && video)
        }.store(in: &subscriptions)
        if macHost == nil {
            gestures = BoundPiPGestures(view: owner.view, shouldReceive: { [weak self] touch in self?.shouldReceive(touch) ?? false },
                moved: { [weak self] phase, offset, endX in self?.move(phase, offset: offset, endX: endX) },
                magnified: { [weak self] phase, scale in self?.resize(phase, scale: scale) },
                opacityChanged: { [weak self] phase, dy in self?.fade(phase, dy: dy) },
                allowsOpacity: { [weak self] in self?.allowsOpacityGesture ?? false },
                isCenteredTouch: { [weak self] touch in self?.isCenteredTouch(touch) ?? false },
                isPiPTouch: { [weak self] touch in
                    guard let self, let overlay = self.overlay else { return false }
                    return overlay.bounds.contains(touch.location(in: overlay))
                })
        }
        bind(core: owner.emulatorCore, gameID: (owner.game as? Game)?.identifier ?? "")
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--bound-ui-friend-fixture") {
            // Original generated pixels, offline only. No account/SDK/network/capture.
            var bytes = Data(count: SharingFrame.byteCount)
            bytes.withUnsafeMutableBytes { raw in
                let p = raw.bindMemory(to: UInt8.self)
                for y in 0..<160 { for x in 0..<240 {
                    let i = (y * 240 + x) * 4
                    p[i] = x < 80 ? 255 : 0; p[i + 1] = x >= 80 && x < 160 ? 255 : 0
                    p[i + 2] = x >= 160 ? 255 : 0; p[i + 3] = 255
                } }
            }
            fixturePresenter.present(bytes, in: sharing.remoteView); state.fixtureVideo = true
        }
        #endif
    }
    private func installMacWorkspace(in owner: GameViewController) {
        let workspace = BoundMacWorkspaceView(sharing: sharing, onboarding: onboarding, state: state,
            geometry: BoundMacWorkspaceGeometry(bounds: owner.view.bounds),
            gameID: (owner.game as? Game)?.identifier ?? "", gameTitle: (owner.game as? Game)?.name ?? "Bound",
            editingChanged: { [weak self] in self?.notesEditing($0) },
            textEditingChanged: { [weak self] in self?.textEditing($0) },
            currentSave: { [weak self] gameID in
                guard let self else { throw BoundRRDexSave.ImportError.currentGameUnavailable }
                return try self.importCurrentRRDexSave(gameID: gameID)
            },
            showLibrary: { [weak owner] in owner?.showBoundMacLibrary() },
            showMenu: { [weak owner] in
                guard let owner else { return }
                owner.view.endEditing(true)
                owner.gameViewController(owner, handleMenuInputFrom: owner.controllerView)
            },
            showFriends: { [weak self, weak owner] in
                guard let self, let owner, owner.presentedViewController == nil else { return }
                owner.view.endEditing(true)
                self.presentFriends(from: owner)
            },
            showSettings: { [weak self, weak owner] in
                guard let self, let owner, owner.presentedViewController == nil else { return }
                owner.view.endEditing(true)
                self.presentSettings(from: owner)
            })
        let host = UIHostingController(rootView: workspace)
        host.safeAreaRegions = []
        host.view.backgroundColor = .clear
        let overlay = BoundOverlayView()
        overlay.yieldsTouch = { [weak self] point in
            guard let geometry = self?.macHost?.rootView.geometry else { return false }
            return geometry.gameplay.contains(point) && !geometry.controls.contains(point)
        }
        owner.addChild(host)
        owner.view.addSubview(overlay)
        overlay.addSubview(host.view)
        host.didMove(toParent: owner)
        owner.view.backgroundColor = UIColor(white: 0.055, alpha: 1)
        self.overlay = overlay
        macHost = host
    }
    func bind(core: EmulatorCore?, gameID: String) {
        defer { refreshMultiplayerServices() }
        let preservingNative=sharing.nativeBattle.hasSavedContinuation || sharing.cooperativeDoubles.hasSavedContinuation
        if (owner?.game as? Game)?.boundUsesServerMultiplayer != true {
            sharing.nativeBattle.continuationContext=nil
            sharing.cooperativeDoubles.continuationContext=(account.session?.owner).flatMap { owner in
                sharing.configuredRoomID.map { BoundNativeContinuationContext(owner:owner,roomID:$0,runID:nil) }
            }
        }
        sharing.nativeBattle.continuationContextProvider = { [weak self] in
            guard let self,let owner=self.account.session?.owner,let room=self.sharing.configuredRoomID else { return nil }
            return BoundNativeContinuationContext(owner:owner,roomID:room,runID:nil)
        }
        sharing.nativeBattle.bind(core: core, gameID: gameID, interactions: sharing.interactions)
        sharing.soulLink.bind(core: core, gameID: gameID)
        sharing.cooperativeDoubles.bind(core:core,gameID:gameID,soul:sharing.soulLink.probe)
        state.settings.setDebugGame(core != nil && romMultiplayer.probe.read()?.debugSetup == true)
        romMultiplayer.debugModeChanged = { [weak self] enabled in self?.state.settings.setDebugGame(enabled) }
        romMultiplayer.bind(core: core, game: owner?.game as? Game)
        romMultiplayer.watch = { [weak self, weak owner] in
            guard let self, let owner, owner.presentedViewController == nil else { return }
            self.sharing.watchPartner()
            guard self.sharing.watchingPartner else { return }
            owner.present(UIHostingController(rootView: BoundPartnerSpectatorView(sharing: self.sharing)), animated: true)
        }
        romMultiplayer.didRestoreSnapshot = { [weak owner] in
            guard let owner, let core = owner.emulatorCore else { return }
            owner.boundRRDexDidLoadSaveState(core: core)
        }
        romMultiplayer.didCompleteCheckpoint = { [weak owner] in owner?.boundDidCompleteMultiplayerCheckpoint() }
        sharing.nativeBattle.tradeCompleted = { [weak soul = sharing.soulLink] id, count in
            soul?.probe.timeline.append(id: "trade:" + id.uuidString, kind: .trade,
                                        title: count == 1 ? "Trade completed" : "\(count) trades completed")
        }
        sharing.sharedWorld.bind(core: core)
        sharing.nativeBattle.restored = { [weak self, weak owner] in
            self?.romMultiplayer.didRestoreAuthorizedSnapshot()
            guard let owner, let core = owner.emulatorCore else { return }
            owner.boundRRDexDidLoadSaveState(core: core)
        }
        sharing.nativeBattle.canResume = { [weak owner] in
            guard let owner else { return false }
            return UIApplication.shared.applicationState == .active && owner.view.window?.windowScene?.hasKeyboardFocus == true
                && owner.boundCanResumeEmulation(resumingNativeActivity:true)
        }
        sharing.nativeBattle.releaseGameplayInputs = { [weak owner] in owner?.releaseBoundFriendGameplayInputs() }
        sharing.cooperativeDoubles.releaseGameplayInputs = { [weak owner] in owner?.releaseBoundFriendGameplayInputs() }
        sharing.cooperativeDoubles.canResume = { [weak owner] in
            guard let owner else { return false }
            return UIApplication.shared.applicationState == .active && owner.view.window?.windowScene?.hasKeyboardFocus == true
                && owner.boundCanResumeEmulation(resumingNativeActivity:true)
        }
        playerStateDisplay.bind(core: core)
        friendInteractionPanel?.bind(core: core)
        guard boundCore !== core || self.gameID != gameID else { return }
        notesDismissalTask?.cancel(); notesDismissalTask = nil; pendingControllerReferenceAction = nil
        cancelInteractions(); tap.setEnabled(false)
        if preservingNative { sharing.background() } else { sharing.stop() }
        notesPaused = false; isEditingNotes = false; isEditingText = false; owner?.controllerView.isUserInteractionEnabled = true; self.gameID = gameID
        host?.rootView.gameID = gameID
        macHost?.rootView.gameID = gameID
        macHost?.rootView.gameTitle = (owner?.game as? Game)?.name ?? "Bound"
        guard let core else { boundCore = nil; state.emulationDetails = nil; return }
        state.emulationDetails = BoundEmulationDetails(packageName: core.deltaCore.name, packageIdentifier: core.deltaCore.identifier, packageVersion: core.deltaCore.version)
        boundCore = core
        let previous = core.updateHandler, tap = self.tap, reader = playerStateDisplay.probe, battle = sharing.nativeBattle.probe, soul = sharing.soulLink.probe, world = sharing.sharedWorld.probe, dialogue = friendInteractionPanel?.probe, romService = romMultiplayer.probe, cooperative = sharing.cooperativeDoubles.probe, cooperativeCable = sharing.cooperativeDoubles.cable
        #if DEBUG && targetEnvironment(simulator)
        let tradeQA = BoundFullAppGameplayQA.current?.tradeProbe
        BoundFullAppGameplayQA.current?.configureTrade(core:core)
        #endif
        core.updateHandler = { [weak tap, weak reader, weak battle, weak soul, weak world, weak dialogue, weak romService, weak cooperative, weak cooperativeCable] core in
            BoundFrameMemory.perform {
                previous?(core)
                romService?.receive(core)
                world?.receive(core)
                dialogue?.receive(core)
                reader?.receive(core)
                tap?.receive(core)
                cooperativeCable?.receive(core)
                cooperative?.receive(core)
                soul?.receive(core)
                battle?.receive(core)
                #if DEBUG && targetEnvironment(simulator)
                tradeQA?.receive(core)
                #endif
            }
        }
        #if DEBUG && targetEnvironment(simulator)
        if usesLocalPairedFixture { sharing.start() }
        #endif
    }
    private func refreshMultiplayerServices(temporary: Bool = false) {
        if !BoundMultiplayerFeatures.isEnabled { romMultiplayer.suspend() }
        onboarding.setMultiplayerServiceActive(multiplayerServicesForeground && boundCore != nil,
            sharing: sharing, existing: { [weak account] in account?.session }, temporary: temporary)
    }
    func layout(in bounds: CGRect, safeArea: UIEdgeInsets, controllerSize: CGSize) -> CGRect? {
        guard let owner else { return nil }
        defer { refreshControllerMultiviewRouting() }
        if let macHost, let overlay {
            let safeBounds = bounds.inset(by: safeArea)
            let geometry = BoundMacWorkspaceGeometry(bounds: CGRect(origin: .zero, size: safeBounds.size),
                                                     sidebarVisible: state.macSidebarVisible,
                                                     preferredSidebarWidth: state.macSidebarWidth)
            if macHost.rootView.geometry != geometry { macHost.rootView.geometry = geometry }
            overlay.frame = safeBounds
            macHost.view.frame = overlay.bounds
            let gameplay = geometry.gameplay.offsetBy(dx: safeBounds.minX, dy: safeBounds.minY)
            owner.gameScreenLayoutBounds = gameplay
            owner.controllerLayoutBounds = gameplay
            if var skin = owner.controllerView.controllerSkin as? TouchControllerSkin {
                let axis: TouchControllerSkin.LayoutAxis = gameplay.width > gameplay.height ? .horizontal : .vertical
                if skin.screenLayoutAxis != axis {
                    skin.screenLayoutAxis = axis
                    owner.controllerView.controllerSkin = skin
                }
            }
            return gameplay
        }
        let screenLayout = BoundAppearancePreferences().effectiveScreenLayout
        if previousScreenLayout != screenLayout { previousScreenLayout = screenLayout; cancelInteractions() }
        let landscape = bounds.width > bounds.height
        if state.landscape != landscape { state.landscape = landscape; cancelInteractions() }
        let controllerPreferences = BoundControllerModePreferences()
        let savedOption = landscapeCompanion.preferences.option
        let controllerModeEnabled = controllerPreferences.isEnabled && screenLayout == .bound && landscape
        // The additional controller modes always pair Friend with Multiview.
        let usesControllerMultiview = controllerModeEnabled
        let arrangementOption = usesControllerMultiview ? (savedOption == .option7 ? .option7 : .option6) : savedOption
        let usesLandscapeOption2 = landscape && arrangementOption == .option2
        let controllerModeLayout = controllerModeEnabled ? controllerPreferences.layout : .mode1
        let usesLandscapeArrangement = landscape && arrangementOption.supportsArrangement
        if usesLandscapeOption2 != landscapeCompanion.active || usesLandscapeArrangement != landscapeArrangement.active
            || (usesLandscapeArrangement && (landscapeArrangement.option != arrangementOption
                || landscapeArrangement.controllerModeEnabled != controllerModeEnabled
                || landscapeArrangement.controllerModeLayout != controllerModeLayout)) {
            owner.view.endEditing(true)
            textEditing(false)
            notesEditing(false)
            keyboardHeight = 0
        }
        landscapeCompanion.setActive(usesLandscapeOption2)
        if usesLandscapeArrangement {
            landscapeArrangement.useOption(arrangementOption, controllerModeEnabled: controllerModeEnabled,
                controllerModeLayout: controllerModeLayout)
        }
        landscapeArrangement.setActive(usesLandscapeArrangement)
        if usesLandscapeArrangement { landscapeArrangement.setContents(state.availableContents) }
        gestures?.setEnabled(!landscapeCompanion.active && !landscapeArrangement.active)
        let referenceTopInset = screenLayout == .bound && !landscape ? safeArea.top : 0
        if state.referenceTopInset != referenceTopInset { state.referenceTopInset = referenceTopInset }
        if screenLayout == .delta {
            owner.gameScreenLayoutBounds = nil
            return nil // Native Delta must lay out first; companion positioning follows it.
        }
        let horizontal = CGRect(x: safeArea.left, y: 0, width: max(1, bounds.width - safeArea.left - safeArea.right), height: bounds.height)
        if landscape {
            // The native game and controls must finish layout before placing PiP.
            let fullGame = AVMakeRect(aspectRatio: owner.emulatorCore?.preferredRenderingSize ?? CGSize(width: 3, height: 2), insideRect: horizontal)
            owner.gameScreenLayoutBounds = usesLandscapeArrangement
                ? landscapeArrangement.configuredGameFrame(baseFrame: fullGame, canvas: horizontal) : horizontal
            return bounds
        }
        let geometry = BoundPortraitScreenGeometry(bounds: bounds, safeTop: safeArea.top,
            controllerSize: controllerSize, gameAspect: owner.emulatorCore?.preferredRenderingSize ?? CGSize(width: 3, height: 2))
        overlay?.frame = geometry.friend
        if state.content == .notes {
            overlay?.frame = CGRect(x: bounds.minX, y: geometry.friend.minY, width: bounds.width, height: geometry.friend.height)
        }
        if [.bosses, .dex].contains(state.content) {
            overlay?.frame = geometry.referencePanel
        }
        if state.content == .types {
            overlay?.frame = BoundTypeChartGeometry.portraitViewport(bounds: bounds, gameFrame: geometry.game)
            if state.chartTopInset != safeArea.top { state.chartTopInset = safeArea.top }
        }
        if isEditingText && state.content != .dex {
            overlay?.frame.size.height = max(geometry.friend.height, min(220, bounds.height - keyboardHeight - geometry.friend.minY - 8))
        }
        overlay?.isHidden = state.availableContents.isEmpty; overlay?.alpha = 1
        host?.view.frame = overlay?.bounds ?? .zero
        owner.gameScreenLayoutBounds = geometry.game
        owner.view.bringSubviewToFront(overlay!); layoutCycleButton(bounds: bounds, safeArea: safeArea)
        return nil // Native Delta's full-viewport controller layout remains untouched.
    }
    func bringControlsToFront() {
        guard let owner else { return }
        defer {
            playerStateDisplay.layout(in: owner, gameView: owner.gameView)
            if let panel = friendInteractionPanel, !panel.isHidden { owner.view.bringSubviewToFront(panel) }
        }
        if !arrangementLayers.active { arrangementLayers.apply() }
        if macHost != nil, let overlay {
            owner.view.bringSubviewToFront(overlay)
            sharing.setRemotePresentationEnabled(!overlay.isHidden)
            return
        }
        layoutCycleButton(bounds: owner.view.bounds, safeArea: owner.view.safeAreaInsets)
        if landscapeArrangement.active {
            layoutLandscapeArrangement()
            sharing.setRemotePresentationEnabled(landscapeArrangement.friendVisible || landscapeArrangement.editing)
            return
        }
        if landscapeCompanion.active {
            layoutLandscapeCompanion()
            sharing.setRemotePresentationEnabled(landscapeCompanion.friendVisible)
            return
        }
        if state.landscape || BoundAppearancePreferences().effectiveScreenLayout == .delta {
            layoutFloatingPanel()
        }
        sharing.setRemotePresentationEnabled(state.content == .friend && overlay?.isHidden == false)
        if let controls { owner.view.bringSubviewToFront(controls) }
    }
    func controllerMenuFrame(defaultFrame: CGRect, canvas: CGRect) -> CGRect? {
        guard landscapeArrangement.movableControllerButtons,
              landscapeArrangement.controllerModeEnabled || landscapeArrangement.hasButtonPlacement(.menu) else { return nil }
        return landscapeArrangement.controllerButtonFrame(.menu, defaultFrame: defaultFrame, canvas: canvas, screenBounds: owner?.view.bounds)
    }

    private func layoutLandscapeArrangement() {
        guard let owner, let overlay, let controls,
              let skin = owner.controllerView.controllerSkin, let traits = owner.controllerView.controllerSkinTraits,
              let menu = skin.items(for: traits)?.first(where: { $0.inputs.allInputs.contains(where: { $0.stringValue == "menu" }) }) else { return }
        geometry = nil
        let canvas = owner.view.bounds.inset(by: owner.view.safeAreaInsets)
        let native = owner.controllerView.controlHitFrames.map { owner.controllerView.convert($0, to: owner.view) }
        let buttonDefaults = landscapeArrangement.controllerModeEnabled ? owner.boundControllerModeButtonDefaults() : nil
        let menuFrame = buttonDefaults?[.menu] ?? owner.boundLandscapeTouchMenuDefaultFrame() ?? owner.controllerView.convert(menu.frame.applying(.init(scaleX: owner.controllerView.bounds.width,
                                                                              y: owner.controllerView.bounds.height)), to: owner.view)
        let occupied = native + (controls.isHidden ? [] : [controls.frame])
        let game = owner.gameView.convert(owner.gameView.bounds, to: owner.view).intersection(canvas)
        var defaults: [BoundPiPContent: CGRect] = [:]
        for content in BoundPiPContent.allCases {
            let width = game.width * ([BoundPiPContent.bosses, .dex].contains(content) ? 0.42 : 0.36)
            let pip = BoundPiPLayout(viewport: game, baseSize: companionBaseSize(width: width, content: content),
                scale: CGFloat(state.preferences.scale(for: content)), occupied: occupied)
            let center = pip.center(state.preferences.corner(for: content))
            defaults[content] = CGRect(x: center.x - pip.size.width / 2, y: center.y - pip.size.height / 2,
                                       width: pip.size.width, height: pip.size.height)
        }
        landscapeArrangement.updateLayout(canvas: canvas, occupied: occupied, menuFrame: menuFrame,
            boundFrame: buttonDefaults?[.multiview] ?? (!controls.isHidden || landscapeArrangement.multiview ? controls.frame : .zero), defaults: defaults,
            keyboardHeight: max(0, keyboardHeight - owner.view.safeAreaInsets.bottom), screenBounds: owner.view.bounds,
            friendButtonFrame: buttonDefaults?[.friend],
            viewsButtonFrame: buttonDefaults?[.multiview])
        overlay.frame = owner.view.bounds
        overlay.isHidden = false; overlay.alpha = 1
        host?.view.frame = overlay.bounds
        owner.view.bringSubviewToFront(overlay)
        owner.view.bringSubviewToFront(controls)
        arrangementEditorOverlay?.frame = owner.view.bounds
        arrangementEditorHost?.view.frame = owner.view.bounds
        let companionButtonFrames = [BoundControllerButton.friend, .multiview].filter { landscapeArrangement.isButtonVisible($0) }.map { landscapeArrangement.buttonFrame($0) }.filter { !$0.isEmpty }
        arrangementLayers.buttonFrames = native + companionButtonFrames
        arrangementLayers.apply()
        #if DEBUG && targetEnvironment(simulator)
        let obstacles = occupied + companionButtonFrames
        owner.gameView.accessibilityValue = "pip-hit-obstacles=" + obstacles.map { rect in
            let screen = owner.view.convert(rect, to: nil)
            return String(format: "%.2f,%.2f,%.2f,%.2f", screen.minX, screen.minY, screen.width, screen.height)
        }.joined(separator: "|")
        #endif
    }
    private func layoutLandscapeCompanion() {
        guard let owner, let overlay else { return }
        controls?.isHidden = true
        geometry = nil
        let canvas = owner.view.bounds.inset(by: owner.view.safeAreaInsets)
        let occupied = owner.controllerView.controlHitFrames.map { owner.controllerView.convert($0, to: owner.view) }
        var shoulder: CGRect?
        if let skin = owner.controllerView.controllerSkin, let traits = owner.controllerView.controllerSkinTraits,
           let item = skin.items(for: traits)?.first(where: { $0.inputs.allInputs.contains(where: { $0.stringValue == "l" }) }) {
            shoulder = owner.controllerView.convert(item.extendedFrame.applying(.init(scaleX: owner.controllerView.bounds.width,
                                                                                     y: owner.controllerView.bounds.height)), to: owner.view)
        }
        landscapeCompanion.updateLayout(canvas: canvas, occupied: occupied, leftShoulder: shoulder,
            keyboardHeight: max(0, keyboardHeight - owner.view.safeAreaInsets.bottom))
        overlay.frame = owner.view.bounds
        overlay.isHidden = false; overlay.alpha = 1
        host?.view.frame = overlay.bounds
        owner.view.bringSubviewToFront(overlay)
        #if DEBUG && targetEnvironment(simulator)
        let obstacles = occupied + [landscapeCompanion.layout.friendButton, landscapeCompanion.layout.viewsButton]
        owner.gameView.accessibilityValue = "pip-hit-obstacles=" + obstacles.map { rect in
            let screen = owner.view.convert(rect, to: nil)
            return String(format: "%.2f,%.2f,%.2f,%.2f", screen.minX, screen.minY, screen.width, screen.height)
        }.joined(separator: "|")
        #endif
    }
    /// One final placement, using the settled native viewport and actual hit regions.
    private func layoutFloatingPanel() {
        guard let owner, let overlay, let controls else { return }
        guard !state.availableContents.isEmpty else { overlay.isHidden = true; geometry = nil; return }
        let game = owner.gameView.convert(owner.gameView.bounds, to: owner.view)
        let viewport = game.intersection(owner.view.bounds.inset(by: owner.view.safeAreaInsets))
        guard !viewport.isNull, viewport.width > 0, viewport.height > 0 else { overlay.isHidden = true; return }
        var occupied = owner.controllerView.controlHitFrames.map { owner.controllerView.convert($0, to: owner.view) }
        if !controls.isHidden { occupied.append(controls.frame) }
        #if DEBUG && targetEnvironment(simulator)
        owner.gameView.accessibilityValue = "pip-hit-obstacles=" + occupied.map { rect in
            let screen = owner.view.convert(rect, to: nil)
            return String(format: "%.2f,%.2f,%.2f,%.2f", screen.minX, screen.minY, screen.width, screen.height)
        }.joined(separator: "|")
        #endif
        let layout = BoundPiPLayout(viewport: viewport,
            baseSize: companionBaseSize(width: viewport.width * ([BoundPiPContent.bosses, .dex].contains(state.content) ? 0.42 : 0.36)),
            scale: CGFloat(state.preferences.scale(for: state.content)) * pinchScale, occupied: occupied)
        geometry = layout
        let corner = state.preferences.corner(for: state.content)
        // Follow the finger continuously; collision-free corner placement happens
        // on release. The overlay always yields touches to native controls.
        let center = translation == .zero ? layout.center(corner) : layout.dragCenter(from: corner, translation: translation)
        var panel = CGRect(x: center.x - layout.size.width / 2, y: center.y - layout.size.height / 2,
                           width: layout.size.width, height: layout.size.height)
        if isEditingText {
            let available = owner.view.bounds.inset(by: owner.view.safeAreaInsets)
            let top = available.minY + (state.landscape ? 4 : 48)
            panel = CGRect(x: available.midX - min(400, available.width) / 2, y: top,
                           width: min(400, available.width),
                           height: max(100, min(230, owner.view.bounds.height - keyboardHeight - top - 8)))
        }
        overlay.frame = panel
        host?.view.frame = overlay.bounds
        overlay.isHidden = state.hidden || layout.size.width == 0 || layout.size.height == 0
        overlay.alpha = isEditingText ? 1 : liveOpacity ?? state.preferences.opacity(for: state.content)
        owner.view.bringSubviewToFront(overlay)
    }
    private func layoutCycleButton(bounds: CGRect, safeArea: UIEdgeInsets) {
        guard let owner, let controls, let controllerView = owner.controllerView, let skin = controllerView.controllerSkin,
              let traits = controllerView.controllerSkinTraits,
              let menu = skin.items(for: traits)?.first(where: { $0.inputs.allInputs.contains(where: { $0.stringValue == "menu" }) }) else { controls?.isHidden = true; return }
        let local = menu.frame.applying(.init(scaleX: controllerView.bounds.width, y: controllerView.bounds.height))
        let frame = controllerView.convert(local, to: owner.view)
        let menuAccessibility = nativeMenuAccessibility ?? BoundNativeMenuAccessibilityElement(accessibilityContainer: controllerView)
        menuAccessibility.accessibilityIdentifier = "bound.native-menu"
        menuAccessibility.accessibilityLabel = landscapeArrangement.editing ? (landscapeArrangement.editingGameScreen ? "Next: arrange views and buttons" : "Done arranging views") : "Menu"
        menuAccessibility.accessibilityTraits = .button
        menuAccessibility.accessibilityFrameInContainerSpace = local
        menuAccessibility.activate = { [weak owner, weak controllerView] in
            guard let owner, let controllerView else { return false }
            controllerView.cancelTouchInputs()
            owner.gameViewController(owner, handleMenuInputFrom: controllerView)
            return true
        }
        var accessibleControls: [UIAccessibilityElement] = [menuAccessibility]
        for input in ["l", "r"] {
            guard let item = skin.items(for: traits)?.first(where: { $0.inputs.allInputs.contains(where: { $0.stringValue == input }) }) else { continue }
            let element = UIAccessibilityElement(accessibilityContainer: controllerView)
            element.accessibilityIdentifier = "bound.native-" + input
            element.accessibilityLabel = input.uppercased() + " shoulder control"
            element.accessibilityFrameInContainerSpace = item.frame.applying(.init(scaleX: controllerView.bounds.width, y: controllerView.bounds.height))
            accessibleControls.append(element)
        }
        #if DEBUG && targetEnvironment(simulator)
        if BoundFullAppGameplayQA.current != nil {
            for input in ["up", "down", "left", "right", "a", "b", "start", "select"] {
                guard let item = skin.items(for: traits)?.first(where: { $0.inputs.allInputs.contains { $0.stringValue == input } }) else { continue }
                var rect = item.frame.applying(.init(scaleX: controllerView.bounds.width, y: controllerView.bounds.height))
                if ["up", "down", "left", "right"].contains(input) {
                    let x = input == "left" ? 0.15 : input == "right" ? 0.85 : 0.5
                    let y = input == "up" ? 0.15 : input == "down" ? 0.85 : 0.5
                    rect = CGRect(x: rect.minX + rect.width * x - 6, y: rect.minY + rect.height * y - 6, width: 12, height: 12)
                }
                let element = UIAccessibilityElement(accessibilityContainer: controllerView)
                element.accessibilityIdentifier = "bound.qa-input-" + input
                element.accessibilityLabel = input; element.accessibilityTraits = .button
                element.accessibilityFrameInContainerSpace = rect
                accessibleControls.append(element)
            }
        }
        #endif
        controllerView.accessibilityElements = accessibleControls
        nativeMenuAccessibility = menuAccessibility
        let controller = controllerView.convert(controllerView.bounds, to: owner.view)
        let occupied = controllerView.controlHitFrames.map { controllerView.convert($0, to: owner.view) }
        controls.isHidden = false
        let right = skin.items(for: traits)?.first(where: { $0.inputs.allInputs.contains(where: { $0.stringValue == "r" }) })
        let rightFrame = right.map { controllerView.convert($0.extendedFrame.applying(.init(scaleX: controllerView.bounds.width, y: controllerView.bounds.height)), to: owner.view) }
        let menuHitSize = menu.extendedFrame.applying(.init(scaleX: controllerView.bounds.width, y: controllerView.bounds.height)).size
        let boundPortrait = !state.landscape && BoundAppearancePreferences().effectiveScreenLayout == .bound
        let select = skin.items(for: traits)?.first { $0.inputs.allInputs.contains { $0.stringValue == "select" } }
        let selectArtwork = boundPortrait && BoundAppearancePreferences().effectiveTheme != .minimal
            ? select.flatMap { skin.image(for: $0, traits: traits, preferredSize: .large)?.0 } : nil
        controls.configure(menuFrame: frame, controllerFrame: controller, landscape: state.landscape,
            minimal: BoundAppearancePreferences().effectiveTheme == .minimal,
            content: landscapeArrangement.active ? landscapeArrangement.referenceContent : state.content,
            canvas: bounds.inset(by: safeArea), occupied: occupied, rightShoulderFrame: rightFrame, menuHitSize: menuHitSize, boundPortrait: boundPortrait, selectArtwork: selectArtwork,
            rightControlGutter: owner.boundLandscapeControlGutter(),
            menuHitFrame: controllerView.convert(menu.extendedFrame.applying(.init(scaleX: controllerView.bounds.width, y: controllerView.bounds.height)), to: owner.view),
            buttonType: landscapeArrangement.active ? .option1 : BoundCompanionButtonPreferences().effectiveButtonType)
        controls.configureSegments(contents: landscapeArrangement.active ? [] : state.configuration.assignments,
                                   displayedContents: landscapeArrangement.active ? [] : state.displayedButtonContents)
        if landscapeArrangement.active {
            // Multiview uses this same position for its X/book toggle, rendered
            // by the arrangement overlay. Keep the measured frame for layout.
            controls.isHidden = landscapeArrangement.multiview
            controls.accessibilityValue = landscapeArrangement.contents.isEmpty ? "No views enabled" : landscapeArrangement.referenceContent.title
            controls.accessibilityHint = "Cycles selected views, excluding Friend"
            owner.view.bringSubviewToFront(controls)
            return
        }
        if state.availableContents.isEmpty {
            controls.accessibilityValue = "No views enabled"
            controls.accessibilityHint = "Enable companion views in Settings"
        } else {
            controls.accessibilityHint = state.hidden ? "Restores the hidden panel" : "Cycles " + state.availableContents.map(\.title).joined(separator: ", ")
        }
        owner.view.bringSubviewToFront(controls)
    }
    func presentFriends(from presenter: UIViewController) {
        cancelInteractions(); state.showingFriends = true
        beginMacSheet(from: presenter)
        let host = UIHostingController(rootView: BoundFriendsSheet(sharing: sharing, onboarding: onboarding, account: account, closed: { [weak self] in
            self?.state.showingFriends = false
            self?.finishMacSheet()
        }))
        presenter.present(host, animated: true)
    }
    func presentSettings(from presenter: UIViewController) {
        cancelInteractions(); state.showingSettings = true; settingsPresenter = presenter
        beginMacSheet(from: presenter)
        let context = BoundSettingsGameplayContext(emulationDetails: state.emulationDetails,
            editControls: { [weak self] in self?.state.pendingControlEditor = true },
            showCompanion: { [weak self] in self?.state.hidden = false; self?.state.refresh() },
            recordedPlayer: playerStateDisplay.supportsRecording ? playerStateDisplay.recordingSession : nil,
            livePresence: playerStateDisplay.supportsRecording ? sharing.livePresence : nil,
            friends: BoundAccountFriendsContext(sharing: sharing, onboarding: onboarding, account: account))
        let host = BoundSettingsHostingController(model: state.settings, gameplay: context, closed: { [weak self] in
            guard let self else { return }; self.state.showingSettings = false
            self.cancelInteractions()
            self.state.settings.refresh()
            self.state.refresh()
            self.finishMacSheet()
            if self.state.pendingControlEditor { self.state.pendingControlEditor = false
                DispatchQueue.main.async { [weak self] in
                    guard let self, let presenter = self.settingsPresenter else { return }
                    if let modal = presenter.presentedViewController, let transition = modal.transitionCoordinator {
                        transition.animate(alongsideTransition: nil) { [weak self, weak presenter] _ in
                            guard let presenter else { return }; self?.owner?.showBoundControlPlacement(from: presenter)
                        }
                    } else { self.owner?.showBoundControlPlacement(from: presenter) }
                }
            }
        })
        presenter.present(host, animated: true)
    }
    var canArrangeLandscapeViews: Bool {
        guard macHost == nil, let owner else { return false }
        return owner.view.bounds.width <= owner.view.bounds.height || landscapeArrangement.active
    }
    func beginLandscapeArrangementFromMenu() {
        guard canArrangeLandscapeViews, let owner,
              owner.view.bounds.width > owner.view.bounds.height,
              !state.showingSettings, !state.showingFriends,
              UIApplication.shared.applicationState == .active else { return }
        owner.view.endEditing(true)
        notesEditing(true)
        // Closing the pause menu normally resumes gameplay. Hold that resume
        // until Done, keeping the editor paused while the menu dismisses.
        if owner.emulatorCore?.state == .paused { notesPaused = true }
        owner.returnToGameViewController { [weak self, weak owner] in
            guard let self, let owner else { return }
            owner.view.setNeedsLayout(); owner.view.layoutIfNeeded()
            guard self.landscapeArrangement.active, UIApplication.shared.applicationState == .active else {
                self.notesEditing(false)
                return
            }
            self.landscapeArrangement.arrange()
            if !self.landscapeArrangement.editing { self.notesEditing(false) }
        }
    }
    func finishLandscapeArrangementIfNeeded() -> Bool {
        guard landscapeArrangement.active, landscapeArrangement.editing else { return false }
        landscapeArrangement.advanceArrangement()
        return true
    }
    private func beginMacSheet(from presenter: UIViewController) {
        guard macHost != nil, let owner, presenter === owner, let core = owner.emulatorCore else { return }
        macSheetCore = core
        macSheetPaused = core.state == .running && owner.pauseEmulation()
        owner.controllerView.resignFirstResponder()
    }
    private func finishMacSheet() {
        guard macHost != nil, let owner, let core = macSheetCore else { return }
        let shouldResume = macSheetPaused
        macSheetPaused = false
        macSheetCore = nil
        let finish: @MainActor @Sendable () -> Void = { [weak owner, weak core] in
            guard let owner, let core, owner.emulatorCore === core,
                  owner.view.window != nil, UIApplication.shared.applicationState == .active,
                  owner.gameViewControllerShouldResumeEmulation(owner) else { return }
            if shouldResume && core.state == .paused { owner.resumeEmulation() }
            owner.controllerView.becomeFirstResponder()
        }
        if let transition = owner.presentedViewController?.transitionCoordinator {
            transition.animate(alongsideTransition: nil) { _ in finish() }
        } else {
            DispatchQueue.main.async(execute: finish)
        }
    }
    func resetMacControllerFocus() {
        guard macHost != nil else { return }
        pendingControllerReferenceAction = nil
        state.macControllerFocused = false
    }
    func cancelInteractions() {
        resetMacControllerFocus()
        pendingControllerReferenceAction = nil
        landscapeArrangement.finish(save: false)
        landscapeCompanion.finishArrangement(save: false)
        gestures?.cancel(); translation = .zero; pinchScale = 1; liveOpacity = nil
        fadingContent = nil; resizingContent = nil
        owner?.controllerView.cancelTouchInputs()
    }
    func cyclePanels() {
        if landscapeArrangement.active { landscapeArrangement.cycleReference(); return }
        if landscapeCompanion.active { landscapeCompanion.cycleViews(); return }
        owner?.view.endEditing(true)
        if macHost != nil {
            BoundMacControllerActionRouting.apply(.cycleBoundPanels, to: state)
            return
        }
        cancelInteractions()
        state.advancePanel()
    }
    func toggleControllerPanel(_ action: ActionInput) {
        if macHost != nil {
            guard macControllerNavigationEnabled else { return }
            if action == .toggleBoundMultiview {
                guard BoundMacControllerActionRouting.canToggleFocus(
                    multiview: BoundControllerMultiviewPreferences().isEnabled, state: state) else { return }
                if dismissReferenceBeforeControllerAction(action) { return }
            }
            BoundMacControllerActionRouting.apply(action, to: state)
            return
        }
        guard state.landscape,
              BoundControllerModePreferences().isEnabled || BoundControllerMultiviewPreferences().isEnabled,
              BoundAppearancePreferences().effectiveScreenLayout == .bound else { return }
        switch action {
        case .toggleBoundFriend:
            if landscapeArrangement.active, !landscapeArrangement.editing { landscapeArrangement.toggleFriend() }
            else if landscapeCompanion.active { landscapeCompanion.toggleFriend() }
        case .toggleBoundMultiview:
            if dismissReferenceBeforeControllerAction(action) { return }
            if landscapeArrangement.active, landscapeArrangement.multiview, !landscapeArrangement.editing {
                landscapeArrangement.toggleReference()
            } else if landscapeCompanion.active {
                if landscapeCompanion.referenceVisible { landscapeCompanion.hideReference() }
                else { landscapeCompanion.selectReference(landscapeCompanion.referenceContent) }
            }
        default: break
        }
    }
    var controllerNavigationAvailable: Bool {
        if macHost != nil { return macControllerNavigationEnabled }
        return controllerCompanionAvailable && (BoundControllerMultiviewPreferences().isEnabled
            || BoundControllerModePreferences().isEnabled)
    }
    private var macControllerNavigationEnabled: Bool {
        BoundMacControllerActionRouting.isEnabled(
            multiview: BoundControllerMultiviewPreferences().isEnabled,
            showingFriends: state.showingFriends, showingSettings: state.showingSettings)
    }
    var isMacWorkspace: Bool { macHost != nil }
    func allowsControllerPanelAction(_ action: ActionInput, controllerType: GameControllerInputType) -> Bool {
        guard isMacWorkspace else { return true }
        return BoundMacControllerActionRouting.allowsPanelAction(action, controllerType: controllerType,
            multiview: BoundControllerMultiviewPreferences().isEnabled, state: state)
    }
    var automaticControllerMultiviewAvailable: Bool {
        if macHost != nil {
            return state.macControllerFocused && BoundMacControllerActionRouting.canToggleFocus(
                multiview: BoundControllerMultiviewPreferences().isEnabled, state: state)
        }
        return BoundControllerMultiviewPreferences().isEnabled && controllerCompanionAvailable
            && controllerReferenceContent != nil
    }
    private func refreshControllerMultiviewRouting() {
        if macHost != nil, state.macControllerFocused,
           !BoundMacControllerActionRouting.canToggleFocus(
               multiview: BoundControllerMultiviewPreferences().isEnabled, state: state) {
            state.macControllerFocused = false
        }
        let content = automaticControllerMultiviewAvailable ? controllerReferenceContent : nil
        if let oldContent = lastControllerFocusContent, oldContent != content {
            BoundControllerNavigationEvent.post(command: .clearFocus, gameID: gameID, content: oldContent)
        }
        lastControllerFocusContent = content
        owner?.refreshBoundMultiviewInputRouting()
    }
    private var controllerCompanionAvailable: Bool {
        if macHost != nil { return macControllerNavigationEnabled }
        return state.landscape
            && BoundAppearancePreferences().effectiveScreenLayout == .bound
            && !state.showingFriends && !state.showingSettings
            && !landscapeArrangement.editing && !landscapeCompanion.editing
            && (landscapeArrangement.active || landscapeCompanion.active)
    }
    var controllerMultiviewTabCyclingAvailable: Bool {
        if macHost != nil {
            return macControllerNavigationEnabled && macControllerTabContents.count > 1
        }
        return controllerCompanionAvailable
            && (BoundControllerModePreferences().isEnabled || BoundControllerMultiviewPreferences().isEnabled)
            && (landscapeArrangement.active ? landscapeArrangement.contents.count > 1 : landscapeCompanion.referenceContents.count > 1)
    }
    var controllerReferenceContent: BoundPiPContent? {
        if macHost != nil { return state.macSidebarVisible && state.macReferenceVisible ? state.macReference : nil }
        if landscapeArrangement.active {
            return landscapeArrangement.referenceVisible ? landscapeArrangement.referenceContent : nil
        }
        if landscapeCompanion.active {
            return landscapeCompanion.referenceVisible ? landscapeCompanion.referenceContent : nil
        }
        return nil
    }
    var allowsControllerNavigationWhilePaused: Bool {
        controllerNavigationAvailable && isEditingNotes
            && controllerReferenceContent.map { $0 == .dex || $0 == .bosses } == true
    }
    var allowsControllerTabCyclingWhilePaused: Bool {
        controllerMultiviewTabCyclingAvailable && isEditingNotes
            && controllerReferenceContent.map { $0 == .dex || $0 == .bosses } == true
    }
    private func dismissReferenceBeforeControllerAction(_ action: ActionInput) -> Bool {
        let canDismissForAction = action.isMultiviewTabAction
            ? allowsControllerTabCyclingWhilePaused
            : allowsControllerNavigationWhilePaused
        guard canDismissForAction, let content = controllerReferenceContent else { return false }
        // Keep the reference active until its presentation has dismissed and
        // returned the gameplay pause; hiding it first loses that callback.
        pendingControllerReferenceAction = action
        BoundControllerNavigationEvent.post(command: .back, gameID: gameID, content: content)
        return true
    }
    func navigateControllerView(_ action: ActionInput) {
        let isAvailable = action.isMultiviewTabAction
            ? controllerMultiviewTabCyclingAvailable
            : controllerNavigationAvailable
        guard isAvailable else { return }
        if let command = action.navigationCommand {
            guard let content = controllerReferenceContent else { return }
            if command == .back, [.types, .connections].contains(content),
               BoundControllerMultiviewPreferences().isEnabled {
                if macHost != nil { resetMacControllerFocus() }
                else if landscapeArrangement.active { landscapeArrangement.toggleReference() }
                else if landscapeCompanion.active { landscapeCompanion.hideReference() }
                return
            }
            guard [.dex, .bosses, .connections].contains(content) else { return }
            BoundControllerNavigationEvent.post(command: command, gameID: gameID, content: content)
            return
        }
        if [.boundHideMultiview, .boundShowDex, .boundShowBosses, .boundShowTypes,
            .boundNextView, .boundPreviousView, .toggleBoundMultiview].contains(action),
           dismissReferenceBeforeControllerAction(action) { return }
        if macHost != nil {
            BoundMacControllerActionRouting.apply(action, to: state)
            return
        }
        switch action {
        case .boundHideFriend:
            if landscapeArrangement.active, landscapeArrangement.friendVisible { landscapeArrangement.toggleFriend() }
            else if landscapeCompanion.active, landscapeCompanion.friendVisible { landscapeCompanion.toggleFriend() }
        case .boundHideMultiview:
            if landscapeArrangement.active, landscapeArrangement.referenceVisible { landscapeArrangement.toggleReference() }
            else if landscapeCompanion.active { landscapeCompanion.hideReference() }
        case .boundShowDex: showControllerReference(.dex)
        case .boundShowBosses: showControllerReference(.bosses)
        case .boundShowTypes: showControllerReference(.types)
        case .boundNextView, .boundPreviousView:
            let contents = landscapeArrangement.active ? landscapeArrangement.contents : landscapeCompanion.referenceContents
            guard !contents.isEmpty else { return }
            let current = landscapeArrangement.active ? landscapeArrangement.referenceContent : landscapeCompanion.referenceContent
            let index = contents.firstIndex(of: current) ?? 0
            let direction = action == .boundNextView ? 1 : -1
            guard let nextIndex = BoundMultiviewTabCycling.index(current: index, direction: direction, count: contents.count) else { return }
            showControllerReference(contents[nextIndex])
        default: break
        }
    }
    private func showControllerReference(_ content: BoundPiPContent) {
        if landscapeArrangement.active, landscapeArrangement.contents.contains(content) {
            landscapeArrangement.select(content)
            if !landscapeArrangement.referenceVisible { landscapeArrangement.toggleReference() }
        } else if landscapeCompanion.active { landscapeCompanion.selectReference(content) }
    }
    private var macControllerTabContents: [BoundPiPContent] { BoundMacControllerActionRouting.referenceContents }
    var allowsOpacityGesture: Bool { !state.availableContents.isEmpty && state.landscape && state.content != .types && !isEditingNotes }
    private func companionBaseSize(width: CGFloat, content: BoundPiPContent? = nil) -> CGSize {
        let content = content ?? state.content
        if content == .dex { return CGSize(width: width, height: width * 300 / 360) }
        if content == .bosses { return CGSize(width: width, height: width * 260 / 360) }
        let image = state.landscape && content == .types ? UIImage(named: "PokemonTypeChart")?.size : nil
        let aspect = image.map { $0.width / max(1, $0.height) } ?? 1.5
        return CGSize(width: width, height: width / max(0.001, aspect))
    }
    private func isCenteredTouch(_ touch: UITouch) -> Bool {
        guard let owner, let overlay else { return false }
        let point = touch.location(in: owner.view)
        let game = owner.gameView.convert(owner.gameView.bounds, to: owner.view)
        return game.insetBy(dx: game.width * 0.2, dy: game.height * 0.15).contains(point)
            && !overlay.frame.contains(point)
    }
    private func shouldReceive(_ touch: UITouch) -> Bool {
        guard !landscapeCompanion.active, !landscapeArrangement.active, !state.availableContents.isEmpty, (state.landscape || (BoundAppearancePreferences().effectiveScreenLayout == .delta && state.content != .types)), !isEditingNotes, !state.showingFriends, !state.showingSettings,
              let owner, let controls, !state.hidden else { return false }
        let p = touch.location(in: owner.view)
        guard !controls.frame.contains(p), owner.gameView.convert(owner.gameView.bounds, to: owner.view).contains(p) else { return false }
        var target = touch.view
        while let view = target, view !== owner.view {
            if view is UITextView || view is UITextField || view is UIControl { return false }
            target = view.superview
        }
        let local = touch.location(in: owner.controllerView)
        if owner.controllerView.controlHitFrames.contains(where: { $0.contains(local) }) { return false }
        return true
    }
    private func move(_ phase: UIGestureRecognizer.State, offset: CGSize, endX: CGFloat) {
        guard let geometry else { return }
        if phase == .began || phase == .changed { translation = offset }
        if phase == .ended {
            let corner = state.preferences.corner(for: state.content)
            state.hidden = geometry.hiddenSide(from: corner, translation: offset, endX: endX) != nil
            state.preferences.setCorner(geometry.destination(from: corner, translation: offset), for: state.content)
            translation = .zero
        } else if phase == .cancelled || phase == .failed { translation = .zero }
        state.refresh()
    }
    func resize(_ phase: UIGestureRecognizer.State, scale: CGFloat) {
        if phase == .began { resizingContent = state.content; initialScale = state.preferences.scale(for: state.content); pinchScale = 1 }
        guard let content = resizingContent, content == state.content else { pinchScale = 1; resizingContent = nil; return }
        // UIKit may recognize a short gesture immediately before its release.
        // Consume the valid begin/end sample too, even with no changed callback.
        if [.began, .changed, .ended].contains(phase), scale.isFinite {
            pinchScale = min(1.4 / initialScale, max(0.65 / initialScale, Double(scale)))
        }
        if phase == .ended { state.preferences.setScale(initialScale * Double(pinchScale), for: content); pinchScale = 1; resizingContent = nil }
        if phase == .cancelled || phase == .failed { pinchScale = 1; resizingContent = nil }
        state.refresh()
    }
    func fade(_ phase: UIGestureRecognizer.State, dy: CGFloat) {
        guard allowsOpacityGesture else { liveOpacity = nil; fadingContent = nil; return }
        if phase == .began { fadingContent = state.content; initialOpacity = state.preferences.opacity(for: state.content); liveOpacity = initialOpacity }
        guard let content = fadingContent, content == state.content else { liveOpacity = nil; fadingContent = nil; return }
        if [.began, .changed, .ended].contains(phase) {
            let height = (geometry?.size.height ?? 160) / CGFloat(state.preferences.scale(for: state.content))
            liveOpacity = BoundPiPPreferences.opacity(start: initialOpacity, verticalTranslation: dy, panelHeight: height)
        }
        if phase == .ended { state.preferences.setOpacity(liveOpacity ?? initialOpacity, for: content); liveOpacity = nil; fadingContent = nil }
        if phase == .cancelled || phase == .failed { liveOpacity = nil; fadingContent = nil }
        state.refresh()
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    func foreground() {
        romMultiplayer.setServiceActive(true)
        multiplayerServicesForeground = true
        foregroundTask?.cancel()
        scheduleNotesDismissalIfNeeded()
        if state.content == .dex || (macHost != nil && state.macSidebarVisible
            && state.macReferenceVisible && state.macMidReference == .dex)
            || (landscapeCompanion.active && landscapeCompanion.referenceContent == .dex)
            || (landscapeArrangement.active && landscapeArrangement.referenceContent == .dex) {
            BoundRRDexSaveRefreshEvent.post(gameID: gameID)
        }
        if sharing.authenticatedMode {
            foregroundTask = Task { [weak self] in
                guard let self else { return }
                await self.account.refreshIfNeeded()
                guard !Task.isCancelled else { return }
                self.sharing.foreground()
                self.refreshMultiplayerServices()
                self.foregroundTask = nil
            }
            return
        }
        sharing.foreground()
        refreshMultiplayerServices()
        #if DEBUG && targetEnvironment(simulator)
        if usesLocalPairedFixture { sharing.start() }
        #endif
    }
    @discardableResult func preserveNativeActivity()->Bool {
        if !romMultiplayer.serverOnly {
            guard sharing.nativeBattle.protectLocalLifecycle(),sharing.cooperativeDoubles.protectLocalLifecycle() else { return false }
        }
        if sharing.nativeBattle.isActive { return sharing.nativeBattle.checkpointForContinuation() }
        if sharing.cooperativeDoubles.blocksAutoSave { return sharing.cooperativeDoubles.checkpointForContinuation() }
        return true
    }
    func background() {
        _=preserveNativeActivity()
        romMultiplayer.setServiceActive(false, temporary: true)
        multiplayerServicesForeground = false
        foregroundTask?.cancel(); foregroundTask = nil
        landscapeArrangement.finish(save: false, resume: false); landscapeCompanion.finishArrangement(save: false, resume: false)
        notesDismissalTask?.cancel(); notesDismissalTask = nil
        let pendingAction = macHost == nil ? pendingControllerReferenceAction : nil
        cancelInteractions(); pendingControllerReferenceAction = pendingAction
        tap.setEnabled(false); sharing.background(); refreshMultiplayerServices(temporary: true); onboarding.close()
    }
    @discardableResult func stop()->Bool {
        let preserving=sharing.nativeBattle.isActive || sharing.cooperativeDoubles.blocksAutoSave
        if preserving,!romMultiplayer.serverOnly {
            _=preserveNativeActivity()
            if sharing.nativeBattle.isActive { sharing.nativeBattle.showLocalExitUnavailable() }
            else { sharing.cooperativeDoubles.showLocalExitUnavailable() }
            return false
        }
        guard !preserving || preserveNativeActivity() else { return false }
        romMultiplayer.setServiceActive(false, temporary:preserving)
        multiplayerServicesForeground = false
        refreshMultiplayerServices(temporary:preserving)
        playerStateDisplay.stop()
        foregroundTask?.cancel(); foregroundTask = nil
        notesDismissalTask?.cancel(); notesDismissalTask = nil; pendingControllerReferenceAction = nil
        macSheetPaused = false; macSheetCore = nil
        landscapeArrangement.finish(save: false, resume: false)
        landscapeCompanion.finishArrangement(save: false, resume: false)
        cancelInteractions(); tap.setEnabled(false)
        if preserving { sharing.background() } else { sharing.stop() }
        onboarding.close()
        notesPaused = false; isEditingNotes = false; isEditingText = false; owner?.controllerView.isUserInteractionEnabled = true; host?.view.endEditing(true); macHost?.view.endEditing(true)
        return true
    }
    func importCurrentRRDexSave(gameID: String) throws -> BoundRRDexSave {
        guard let owner, let core = owner.emulatorCore, core === boundCore,
              let game = owner.game as? Game, game.identifier == gameID, self.gameID == gameID,
              core.game.type == .gba, core.state == .running || core.state == .paused else {
            throw BoundRRDexSave.ImportError.currentGameUnavailable
        }
        if romMultiplayer.serverOnly {
            return try captureRestoredRRDexSave(owner: owner, core: core, gameID: gameID)
        }
        return try owner.boundRRDexSaveCache.value(completedSave: {
            try BoundRRDexCurrentSaveImport.readCompletedSave(at: game.gameSaveURL)
        }, restoredSave: {
            try self.captureRestoredRRDexSave(owner: owner, core: core, gameID: gameID)
        })
    }
    private func captureRestoredRRDexSave(owner: GameViewController, core: EmulatorCore, gameID: String) throws -> BoundRRDexSave {
        try BoundRRDexSaveRefreshEvent.suppressWhileCapturing(gameID: gameID) {
            let wasRunning = core.state == .running
            if wasRunning, !owner.pauseEmulation() { throw BoundRRDexSave.ImportError.cannotPause }
            defer {
                if wasRunning, owner.emulatorCore === core, core.state == .paused,
                   (owner.game as? Game)?.identifier == gameID, owner.view.window != nil,
                   UIApplication.shared.applicationState == .active {
                    owner.resumeEmulation()
                }
            }
            guard core.state == .paused else { throw BoundRRDexSave.ImportError.cannotPause }
            if self.romMultiplayer.serverOnly {
                return try BoundRRDexSave.parse(BoundVBABattleBridge.captureServerBattery())
            }
            return try BoundRRDexCurrentSaveImport.capture { url in
                // Export the live battery buffer, including data restored from a save
                // state, instead of importing a potentially older file from disk.
                core.deltaCore.emulatorBridge.saveGameSave(to: url)
            }
        }
    }
    private func textEditing(_ editing: Bool) {
        guard isEditingText != editing else { return }
        // Only keyboard editing needs a larger, keyboard-safe panel. Reference
        // sheets and import alerts pause gameplay without changing its placement.
        isEditingText = editing
        owner?.view.setNeedsLayout()
    }
    private func notesEditing(_ editing: Bool, allowResume: Bool = true) {
        guard isEditingNotes != editing else { return }
        notesDismissalTask?.cancel()
        notesDismissalTask = nil
        isEditingNotes = editing; owner?.controllerView.cancelTouchInputs()
        owner?.controllerView.isUserInteractionEnabled = !editing
        owner?.view.setNeedsLayout()
        guard let owner, let core = owner.emulatorCore else { return }
        if editing {
            notesPaused = notesPaused || (core.state == .running && owner.gameViewControllerShouldPauseEmulation(owner))
            if notesPaused, core.state == .running { core.pause() }
        } else {
            guard allowResume else { notesPaused = false; return }
            scheduleNotesDismissalIfNeeded()
        }
    }
    private func scheduleNotesDismissalIfNeeded() {
        guard notesDismissalTask == nil, !isEditingNotes,
              notesPaused || pendingControllerReferenceAction != nil,
              let owner, let core = owner.emulatorCore else { return }
        let expectedGameID = gameID
        notesDismissalTask = Task { @MainActor [weak self, weak owner, weak core] in
            // SwiftUI alerts change their binding before UIKit dismisses.
            // Keep the pause ownership and queued action until UIKit finishes.
            while !Task.isCancelled {
                guard let self, let owner, let core else { return }
                guard owner.emulatorCore === core, self.gameID == expectedGameID,
                      core.state != .stopped else {
                    self.notesDismissalTask = nil
                    self.notesPaused = false
                    self.pendingControllerReferenceAction = nil
                    return
                }
                guard !self.isEditingNotes else { self.notesDismissalTask = nil; return }
                // Inactive or detached views are retried by foreground(), not polled.
                guard owner.view.window != nil,
                      UIApplication.shared.applicationState == .active else {
                    self.notesDismissalTask = nil
                    return
                }
                if owner.presentedViewController != nil {
                    do { try await Task.sleep(nanoseconds: 50_000_000) }
                    catch { return }
                    continue
                }
                let resume = self.notesPaused
                let action = self.pendingControllerReferenceAction
                self.notesPaused = false
                self.pendingControllerReferenceAction = nil
                self.notesDismissalTask = nil
                if resume, core.state == .paused,
                   owner.gameViewControllerShouldResumeEmulation(owner) { core.resume() }
                guard let action else { return }
                let isAvailable = action.isMultiviewTabAction
                    ? self.controllerMultiviewTabCyclingAvailable
                    : self.controllerNavigationAvailable
                guard isAvailable else { return }
                if action == .toggleBoundMultiview { self.toggleControllerPanel(action) }
                else { self.navigateControllerView(action) }
                return
            }
        }
    }
    private func editControls() {
        // Wired to the native skin placement editor below once its active traits are available.
        owner?.showBoundControlPlacement()
    }
}

struct BoundCompanionPanel: View {
    @ObservedObject var sharing: FriendSharingSession
    @ObservedObject var state: BoundCompanionState
    var gameID: String
    let editingChanged: (Bool) -> Void
    var textEditingChanged: (Bool) -> Void = { _ in }
    var currentSave: (String) throws -> BoundRRDexSave = { _ in throw BoundRRDexSave.ImportError.currentGameUnavailable }
    var contentOverride: BoundPiPContent? = nil
    var presentationEnabled = true
    var rendersFriend = true
    var inlineDexSearch = false
    private var displayedContent: BoundPiPContent { contentOverride ?? state.content }
    private func shows(_ content: BoundPiPContent) -> Bool {
        presentationEnabled && (contentOverride != nil || !state.availableContents.isEmpty) && displayedContent == content
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if shows(.friend) {
                    if rendersFriend {
                    ZStack {
                        Color.black
                        BoundRemoteCanvas(view: sharing.remoteView).opacity(sharing.remoteVisible || state.displaysFixtureVideo ? 1 : 0)
                        if !sharing.remoteVisible && !state.displaysFixtureVideo { Text(sharing.active ? "Waiting for friend" : sharing.connectionRequested ? "Retrying connection…" : "Connect a friend").foregroundStyle(.white).font(.callout) }
                    }.accessibilityIdentifier("bound.friend-screen")
                    }
                } else if shows(.notes) {
                    BoundNotesEditor(gameID: gameID, floating: state.landscape, editingChanged: { editing in
                        textEditingChanged(editing)
                        editingChanged(editing)
                    }).id(gameID)
                } else if shows(.connections) {
                    BoundConnectionsView(feed: sharing.connectionFeed, gameID: gameID)
                } else if shows(.types) {
                    if state.landscape {
                        Image("PokemonTypeChart").resizable().scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .accessibilityLabel("Pokémon type effectiveness chart")
                            .accessibilityIdentifier("bound.type-chart")
                    } else { BoundTypeChartView(topInset: state.chartTopInset, constrainsPan: BoundAppearancePreferences().effectiveScreenLayout == .bound) }
                }
            }
            BoundRetainedReferenceView(isActive: shows(.bosses), floating: state.landscape,
                                       portraitTopInset: state.referenceTopInset) { floating, topInset in
                BoundBossGuideView(gameID: gameID, floating: floating, portraitTopInset: topInset,
                                   isActive: shows(.bosses), presentationChanged: { active in
                    if shows(.bosses) { editingChanged(active) }
                })
            }
            .id("boss-" + gameID)
            BoundRetainedReferenceView(isActive: shows(.dex), floating: state.landscape,
                                       portraitTopInset: state.referenceTopInset) { floating, topInset in
                BoundRRDexView(gameID: gameID, floating: floating, inlineSearch: inlineDexSearch,
                               portraitTopInset: topInset,
                               isActive: shows(.dex), presentationChanged: { active in
                    if shows(.dex) { editingChanged(active) }
                }, textEditingChanged: { active in
                    if shows(.dex) { textEditingChanged(active) }
                }, currentSave: { try currentSave(gameID) })
            }
            .id("dex-" + gameID)
        }
        .background(displayedContent == .types ? Color.black : Color(uiColor: [.bosses, .dex].contains(displayedContent) ? .systemBackground : .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: state.landscape ? 8 : [.types, .bosses, .dex].contains(displayedContent) ? 0 : 4))
        .onChange(of: displayedContent) { _, _ in
            textEditingChanged(false)
            editingChanged(false)
        }
        .onChange(of: presentationEnabled) { _, enabled in
            if !enabled { textEditingChanged(false); editingChanged(false) }
        }
        .onChange(of: sharing.joined) { _, _ in state.refresh() }
    }
}

/// Keep a visited reference screen and its native scroll views alive. Hidden
/// screens retain their viewport too: the smaller Friend/Notes panel must not
/// switch their layout branches or clamp their saved scroll position.
struct BoundRetainedReferenceView<Content: View>: View {
    let isActive: Bool
    let floating: Bool
    let portraitTopInset: CGFloat
    @ViewBuilder let content: (Bool, CGFloat) -> Content
    @State private var retainedViewport: Viewport?

    private struct Viewport: Equatable {
        let size: CGSize
        let floating: Bool
        let topInset: CGFloat
    }

    var body: some View {
        GeometryReader { geometry in
            let current = Viewport(size: geometry.size, floating: floating, topInset: portraitTopInset)
            let viewport = isActive ? current : retainedViewport ?? current
            Group {
                if isActive || retainedViewport != nil {
                    content(viewport.floating, viewport.topInset)
                        .frame(width: viewport.size.width, height: viewport.size.height)
                }
            }
            .opacity(isActive ? 1 : 0)
            .onChange(of: isActive ? current : nil, initial: true) { _, activeViewport in
                if let activeViewport { retainedViewport = activeViewport }
            }
        }
        .allowsHitTesting(isActive)
        .accessibilityElement(children: isActive ? .contain : .ignore)
        .accessibilityHidden(!isActive)
    }
}

/// Settings shared by library and gameplay Controls, preserving their original storage.
struct BoundCompanionControlsSections: View {
    @ObservedObject var model: BoundCompanionSettingsModel
    var gameplay: BoundSettingsGameplayContext? = nil

    var body: some View {
        BoundGeneralSettingsSections()
        BoundAppearanceSettings(includeAbout: false)
        if !BoundFeatureVisibility.simplifiedSettings {
            Section("Picture in Picture") {
                ForEach([BoundPiPContent.friend, .notes], id: \.rawValue) { content in
                    VStack(alignment: .leading) {
                        Text("\(content.title) transparency: \(Int(model.preferences.transparency(for: content) * 100))%")
                        Slider(value: Binding(get: { model.preferences.transparency(for: content) }, set: {
                            model.preferences.setTransparency($0, for: content); model.refresh()
                        }), in: 0...1, step: 0.05)
                    }
                }
                if let show = gameplay?.showCompanion { Button("Show PiP", action: show) }
            }
        }
    }
}

struct BoundRemoteCanvas: UIViewRepresentable {
    let view: UIView
    var hidesAccessibilityChildren = false
    func makeUIView(context: Context) -> UIView { view }
    func updateUIView(_ uiView: UIView, context: Context) { uiView.accessibilityElementsHidden = hidesAccessibilityChildren }
}

struct BoundNotesEditor: View {
    let gameID: String
    let floating: Bool
    let editingChanged: (Bool) -> Void
    @State private var text = ""
    @State private var status = ""
    @State private var readable = false
    @State private var editing = false
    @FocusState private var classicEditing: Bool
    @AppStorage(BoundAppearancePreferences.screenLayoutKey) private var screenLayoutRaw = BoundAppearancePreferences.defaultScreenLayout.rawValue
    private let store = BoundNotesStore()
    private var usesBoundArrangement: Bool { BoundAppearancePreferences().effectiveScreenLayout == .bound }
    var body: some View {
        VStack(alignment: .leading) {
            if usesBoundArrangement {
                ZStack(alignment: .topLeading) {
                    BoundNotesTextView(text: $text, editing: Binding(get: { editing }, set: { editing = $0 }))
                        .disabled(!readable)
                        .allowsHitTesting(!floating || editing)
                    if readable && text.isEmpty && !editing {
                        Text("Tap to add notes")
                            .font(BoundNotesFont.swiftUIFont()).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 8)
                            .allowsHitTesting(false)
                            .accessibilityIdentifier("bound.notes-placeholder")
                    }
                }.accessibilityElement(children: .contain)
            } else {
                TextEditor(text: $text).focused($classicEditing).disabled(!readable)
                    .accessibilityIdentifier("bound.notes-editor")
                    .allowsHitTesting(!floating || editing)
            }
            if !status.isEmpty || editing {
                HStack {
                    if !status.isEmpty { Text(status).font(.caption) }
                    Spacer()
                    if editing { Button("Done") { editing = false; classicEditing = false }
                        .font(usesBoundArrangement ? BoundNotesFont.swiftUIFont(pointSize: 12, relativeTo: .callout) : .body)
                        .frame(minWidth: usesBoundArrangement ? 44 : nil, minHeight: usesBoundArrangement ? 44 : nil) }
                }
                .padding(usesBoundArrangement ? 8 : 0)
                .background(usesBoundArrangement ? Color.black : Color.clear)
                .foregroundStyle(usesBoundArrangement ? Color.white : Color.primary)
            }
        }
        .overlay {
            if floating && !editing && readable {
                Color.clear.contentShape(Rectangle())
                    .onTapGesture { editing = true; classicEditing = !usesBoundArrangement }
                    .accessibilityLabel("Edit notes")
                    .accessibilityIdentifier("bound.notes-preview")
            }
        }
        .onAppear {
            do { text = try store.read(game: gameID); readable = true }
            catch { status = "Could not read notes. Existing notes are kept." }
        }
        .onChange(of: text) { _, next in
            guard readable else { return }
            do { try store.write(next, game: gameID); status = "" }
            catch { status = "Could not save notes (16 KB limit)." }
        }
        .onChange(of: classicEditing) { _, next in if !usesBoundArrangement { editing = next } }
        .onChange(of: screenLayoutRaw) { _, _ in editing = false; classicEditing = false }
        .onChange(of: editing) { _, next in editingChanged(next) }
        .onDisappear { editingChanged(false) }
    }
}

/// Bound-only editor: explicit UIKit traits disable both correction and spelling underlines.
/// The native Delta arrangement continues to use its existing SwiftUI TextEditor.
struct BoundNotesTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var editing: Bool

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.font = BoundNotesFont.uiFont()
        view.adjustsFontForContentSizeCategory = true
        view.textColor = .label
        view.backgroundColor = .systemBackground
        view.autocorrectionType = .no
        view.spellCheckingType = .no
        view.accessibilityLabel = "Notes"
        view.accessibilityIdentifier = "bound.notes-editor"
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.parent = self
        view.isEditable = context.environment.isEnabled
        view.isSelectable = context.environment.isEnabled
        view.isUserInteractionEnabled = context.environment.isEnabled
        // Avoid disturbing the selection or marked text during ordinary typing.
        if view.text != text { view.text = text }
        if editing && !view.isFirstResponder {
            DispatchQueue.main.async { if self.editing { view.becomeFirstResponder() } }
        } else if !editing && view.isFirstResponder { view.resignFirstResponder() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: BoundNotesTextView
        init(_ parent: BoundNotesTextView) { self.parent = parent }
        func textViewDidBeginEditing(_ textView: UITextView) { if !parent.editing { parent.editing = true } }
        func textViewDidChange(_ textView: UITextView) { parent.text = textView.text }
        func textViewDidEndEditing(_ textView: UITextView) { if parent.editing { parent.editing = false } }
    }
}

struct BoundFriendsSheet: View {
    @ObservedObject var sharing: FriendSharingSession
    @ObservedObject var onboarding: FriendOnboarding
    @ObservedObject var account: BoundFriendAccount
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @AppStorage(BoundDeveloperFeatures.key) private var developerFeaturesEnabled = false
    var closed: () -> Void = {}

    init(sharing: FriendSharingSession, onboarding: FriendOnboarding, account: BoundFriendAccount,
         closed: @escaping () -> Void = {}) {
        self.sharing = sharing
        self.onboarding = onboarding
        self.account = account
        self.closed = closed
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if account.deletionPending {
                        Button("Retry account deletion", role: .destructive) {
                            Task { await account.resumeAccountDeletion(); onboarding.synchronizeAccount() }
                        }
                        .disabled(account.busy)
                        .accessibilityIdentifier("bound.account-delete-retry")
                    } else if account.session == nil {
                        BoundAccountSignInFields(account: account, email: $email, password: $password) { onboarding.synchronizeAccount() }
                    } else {
                        NavigationLink("Account and Security") {
                            BoundAccountSecurityView(account: account) { email = $0 }
                        }
                        .accessibilityIdentifier("bound.account-security")
                    }
                    if account.session == nil || account.status != "Signed in." {
                        Text(account.status).font(.caption)
                    }
                } header: {
                    if account.session != nil {
                        Text(onboarding.accountUsername.map { "Hello \($0)" } ?? "Hello")
                            .lineLimit(2).minimumScaleFactor(0.75)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("bound.friends-greeting")
                            .textCase(nil)
                    } else {
                        Text("Bound Account")
                    }
                }
                if account.session != nil {
                    BoundFriendsListSections(sharing: sharing, onboarding: onboarding, account: account)
                    if developerFeaturesEnabled {
                        BoundLivePresenceControls(session: sharing.livePresence)
                        BoundSoulControls(session: sharing.soulLink)
                        BoundRunTimelineControls(timeline: sharing.soulLink.probe.timeline)
                        BoundPartnerSpectatorControls(sharing: sharing)
                    }
                }
            }.navigationTitle("Friends")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(account.busy) } }
        }
        .onAppear { onboarding.open(sharing: sharing, existing: { account.session }) }
        .onReceive(NotificationCenter.default.publisher(for: BoundAccountProfile.didChangeNotification)) { _ in
            onboarding.refresh()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { onboarding.open(sharing: sharing, existing: { account.session }) }
            else { onboarding.close() }
        }
        .onDisappear { password = ""; onboarding.close(); closed() }
        .interactiveDismissDisabled(account.busy)
    }
}

enum BoundFriendRowConnection: Equatable {
    case inactive, connecting, connected

    @MainActor
    init(roomID: String, selectedRoomID: String?, sharing: FriendSharingSession) {
        guard selectedRoomID == roomID, sharing.configuredRoomID == roomID,
              sharing.connectionRequested else { self = .inactive; return }
        self = sharing.active && sharing.joined && !sharing.reconnecting && sharing.peerConnected
            ? .connected : .connecting
    }

    var title: String? {
        switch self {
        case .inactive: return nil
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        }
    }
    var symbol: String { self == .connected ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath" }
}

/// The Friends tile and Account settings use identical rows and actions.
struct BoundFriendsListSections: View {
    @ObservedObject var sharing: FriendSharingSession
    @ObservedObject var onboarding: FriendOnboarding
    @ObservedObject var account: BoundFriendAccount
    @State private var reportingRoom: FriendRoom?
    @State private var blockingRoom: FriendRoom?
    @State private var removingRoom: FriendRoom?

    var body: some View {
        Group {
            Section {
                if !onboarding.message.isEmpty {
                    Text(onboarding.message).font(.caption)
                }
                ForEach(onboarding.rooms) { room in
                    friendRow(room)
                }
                Button("Refresh") { onboarding.refresh() }.disabled(onboarding.busy)
                    .accessibilityIdentifier("bound.friends-refresh")
            } header: {
                HStack {
                    Text("Friends")
                        .accessibilityIdentifier("bound.friends-list-heading")
                    Spacer()
                    NavigationLink {
                        BoundAddFriendView(onboarding: onboarding, account: account)
                    } label: {
                        Label("Add", systemImage: "person.badge.plus")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1).minimumScaleFactor(0.8)
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .disabled(account.session == nil)
                    .accessibilityLabel("Add friend")
                    .accessibilityIdentifier("bound.add-friend-open")
                }
                .textCase(nil)
            }
            if !onboarding.blocks.isEmpty {
                Section("Blocked") {
                    ForEach(onboarding.blocks) { block in
                        HStack {
                            Text(block.displayName)
                            Spacer()
                            Button("Unblock") { onboarding.unblock(block) }.disabled(onboarding.busy)
                        }
                    }
                }
            }
        }
        .onChange(of: account.session?.owner) { _, _ in
            reportingRoom = nil
            blockingRoom = nil
            removingRoom = nil
        }
        .sheet(item: $reportingRoom) { room in BoundReportView(onboarding: onboarding, room: room) }
        .confirmationDialog("Remove this friend?", isPresented: Binding(get: { removingRoom != nil }, set: { if !$0 { removingRoom = nil } }), titleVisibility: .visible) {
            Button("Remove Friend", role: .destructive) {
                if let room = removingRoom { onboarding.remove(room) }
                removingRoom = nil
            }
            Button("Cancel", role: .cancel) { removingRoom = nil }
        } message: { Text("This ends your friendship and stops sharing. You can add each other again with a new invite.") }
        .confirmationDialog("Block this friend?", isPresented: Binding(get: { blockingRoom != nil }, set: { if !$0 { blockingRoom = nil } }), titleVisibility: .visible) {
            Button("Block", role: .destructive) { if let room = blockingRoom { onboarding.block(room) }; blockingRoom = nil }
            Button("Cancel", role: .cancel) { blockingRoom = nil }
        }
    }

    @ViewBuilder
    private func friendRow(_ room: FriendRoom) -> some View {
        let connection = BoundFriendRowConnection(roomID: room.roomID,
            selectedRoomID: onboarding.selected?.roomID, sharing: sharing)
        let connected = connection == .connected
        HStack(spacing: 10) {
            Button {
                onboarding.select(room, startSharing: true)
            } label: {
                HStack(spacing: 8) {
                    Text(room.displayName).fontWeight(connected ? .semibold : .regular)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 8)
                    if let title = connection.title {
                        Label(title, systemImage: connection.symbol)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(connected ? Color.accentColor : Color.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(onboarding.busy)
            .accessibilityHint("Starts sharing your game and sends this friend a notification")
            if connection != .inactive {
                Button("Stop") {
                    onboarding.disconnect()
                }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.borderless)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
                    .accessibilityIdentifier("bound.stop-sharing-selected")
            }
            Menu {
                Button("Remove Friend", systemImage: "person.badge.minus", role: .destructive) { removingRoom = room }
                Button("Report") { reportingRoom = room }
                Button("Block", role: .destructive) { blockingRoom = room }
            } label: { Image(systemName: "ellipsis.circle") }
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
                .accessibilityLabel("Actions for \(room.displayName)")
                .disabled(onboarding.busy)
        }
        .padding(.horizontal, 8)
        .frame(minHeight: 44)
        .background(connected ? Color.accentColor.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(connected ? Color.accentColor.opacity(0.5) : Color.clear, lineWidth: 1))
        .accessibilityIdentifier(connected ? "bound.friend-row-selected" : "bound.friend-row")
    }

}

/// Use the existing navigation stack so opening this form cannot dismiss its
/// Settings/Friends presenter or interrupt that presenter's account lifetime.
private struct BoundAddFriendView: View {
    @ObservedObject var onboarding: FriendOnboarding
    @ObservedObject var account: BoundFriendAccount
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var roomIDsBeforeAdding: Set<String>?

    var body: some View {
        Form {
            Section {
                TextField("Friend's username", text: $username)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit { addFriend() }
                    .accessibilityIdentifier("bound.add-friend-username")
            }
            if !onboarding.message.isEmpty { Text(onboarding.message).font(.caption) }
            Button("Add friend") { addFriend() }
                .disabled(account.session == nil || onboarding.busy || !validUsername)
                .accessibilityIdentifier("bound.add-friend")
        }
        .navigationTitle("Add a Friend")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
                    .accessibilityIdentifier("bound.add-friend-close")
            }
        }
        .onChange(of: account.session?.owner) { _, _ in dismiss() }
        .onChange(of: onboarding.rooms.map(\.roomID)) { _, ids in
            guard let roomIDsBeforeAdding else { return }
            if !Set(ids).subtracting(roomIDsBeforeAdding).isEmpty { dismiss() }
        }
    }

    private var validUsername: Bool {
        BoundSocialAPI.validUsername(username.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func addFriend() {
        guard account.session != nil, !onboarding.busy, validUsername else { return }
        roomIDsBeforeAdding = Set(onboarding.rooms.map(\.roomID))
        onboarding.add(username: username)
    }
}

private struct BoundReportView: View {
    @ObservedObject var onboarding: FriendOnboarding
    let room: FriendRoom
    @Environment(\.dismiss) private var dismiss
    @State private var reason = FriendReportReason.harassment
    var body: some View {
        NavigationStack {
            Form {
                Picker("Reason", selection: $reason) {
                    ForEach(FriendReportReason.allCases) { item in Text(item.title).tag(item) }
                }.pickerStyle(.inline)
                Button("Report") { onboarding.report(room, reason: reason); dismiss() }.disabled(onboarding.busy)
            }.navigationTitle("Report")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

/// Library settings and Friends share the same credentials form and account owner.
struct BoundAccountSignInFields: View {
    @ObservedObject var account: BoundFriendAccount
    @Binding var email: String
    @Binding var password: String
    var signedIn: () -> Void = {}

    var body: some View {
        Group {
            if account.pendingMFA {
                BoundAccountSecondFactorSignInView(account: account, signedIn: signedIn)
            } else {
                TextField("Email", text: $email)
                    .textContentType(.username).textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress).autocorrectionDisabled()
                    .accessibilityIdentifier("account.signin.email")
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .accessibilityIdentifier("account.signin.password")
                Button("Sign in") {
                    let entered = password; password = ""
                    Task { await account.signIn(email: email, password: entered); signedIn() }
                }
                .disabled(email.isEmpty || password.isEmpty)
                .accessibilityIdentifier("account.signin.submit")
                NavigationLink("Forgot password?") {
                    BoundForgotPasswordView(account: account, email: $email)
                }
                .accessibilityIdentifier("account.signin.forgot-password")
                NavigationLink("Create Account") {
                    BoundCreateAccountView(account: account, signInEmail: $email, signedIn: signedIn)
                }
                .accessibilityIdentifier("account.signin.create-account")
                if account.busy { ProgressView("Signing in…") }
            }
        }
        .disabled(account.busy || account.deletionPending)
    }
}

/// Show the current address alongside an explicit password-protected change action.
struct BoundAccountEmailText: View {
    @ObservedObject var account: BoundFriendAccount
    var changeEmail: () -> Void = {}
    var body: some View {
        if account.session != nil {
            Button(action: changeEmail) {
                HStack {
                    Text("Change email")
                    Spacer()
                    Text(account.emailAddress ?? "Email unavailable")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.trailing)
                }
            }
            .buttonStyle(.plain)
            .disabled(account.busy || account.securityBusy || account.changingEmail || account.deletionPending)
            .accessibilityLabel("Change email")
            .accessibilityValue(account.emailAddress ?? "Email unavailable")
            .accessibilityHint("Change your email using your current password")
            .accessibilityIdentifier("bound.account-email")
            .task(id: account.session?.owner) { await account.loadEmailAddress() }
        }
    }
}

struct BoundChangeEmailView: View {
    @ObservedObject var account: BoundFriendAccount
    var emailChanged: (String) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var newEmail = ""
    @State private var currentPassword = ""
    @State private var submission: Task<Void, Never>?
    @State private var changed = false
    var body: some View {
        NavigationStack {
            Form {
                if changed {
                    Section {
                        Text("Email updated. Sign in with your new email and current password.")
                            .accessibilityIdentifier("account.email-change.success")
                        Button("Sign in") { dismiss() }
                            .accessibilityIdentifier("account.email-change.return")
                    }
                } else if account.session == nil {
                    Section {
                        Text("Sign in before changing your email.")
                        Button("Sign in") { dismiss() }
                    }
                } else {
                    Section {
                        TextField("New email", text: $newEmail)
                            .textContentType(.emailAddress).keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("account.email-change.email")
                        SecureField("Current password", text: $currentPassword)
                            .textContentType(.password)
                            .submitLabel(.done).onSubmit { submit() }
                            .accessibilityIdentifier("account.email-change.password")
                        Button("Change email") { submit() }
                            .disabled(account.changingEmail || account.busy || currentPassword.isEmpty ||
                                      BoundFriendAccount.normalizedEmail(newEmail) == nil ||
                                      BoundFriendAccount.normalizedEmail(newEmail) == account.emailAddress)
                            .accessibilityIdentifier("account.email-change.submit")
                        if account.changingEmail { ProgressView("Changing email…") }
                    }
                }
                if !changed && !account.emailChangeStatus.isEmpty {
                    Section { Text(account.emailChangeStatus).accessibilityIdentifier("account.email-change.status") }
                }
            }
            .navigationTitle("Change Email")
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button(changed ? "Done" : "Cancel") { submission?.cancel(); currentPassword = ""; dismiss() }
                    .disabled(account.changingEmail)
            } }
        }
        .interactiveDismissDisabled(account.changingEmail)
        .onDisappear { submission?.cancel(); submission = nil; currentPassword = "" }
    }
    private func submit() {
        guard submission == nil, !account.changingEmail, !account.busy,
              !currentPassword.isEmpty, let normalized = BoundFriendAccount.normalizedEmail(newEmail),
              normalized != account.emailAddress else { return }
        let entered = currentPassword; currentPassword = ""
        submission = Task { @MainActor in
            let updated = await account.changeEmail(to: normalized, currentPassword: entered)
            if updated { emailChanged(normalized); changed = true }
            submission = nil
        }
    }
}

/// Keep password recovery visible even when a saved account is already signed in.
struct BoundAccountPasswordResetLink: View {
    @ObservedObject var account: BoundFriendAccount
    var body: some View {
        NavigationLink("Reset password") {
            BoundForgotPasswordView(account: account, email: .constant(""), forCurrentAccount: true)
        }
        .disabled(account.busy || account.securityBusy || account.changingEmail || account.deletionPending)
        .accessibilityIdentifier("bound.account-reset-password")
    }
}

struct BoundForgotPasswordView: View {
    @ObservedObject var account: BoundFriendAccount
    @Binding var email: String
    var forCurrentAccount = false
    @State private var submission: Task<Void, Never>?
    private var unavailable: Bool {
        submission != nil || account.busy || account.securityBusy || account.changingEmail ||
        account.sendingPasswordReset || account.deletionPending ||
        (forCurrentAccount ? account.session == nil : BoundFriendAccount.normalizedEmail(email) == nil)
    }
    var body: some View {
        Form {
            Section {
                if forCurrentAccount {
                    if account.session != nil {
                        LabeledContent("Email") {
                            Text(account.emailAddress ?? "Email unavailable")
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("account.recovery.account-email")
                        }
                    } else {
                        Text("Your account has signed out. Return to Sign in and choose Forgot password to request a reset link.")
                    }
                } else {
                    TextField("Email", text: $email)
                        .textContentType(.emailAddress).keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(.send).onSubmit { submit() }
                        .accessibilityIdentifier("account.recovery.email")
                }
                Button("Send reset link") { submit() }
                    .disabled(unavailable)
                    .accessibilityIdentifier("account.recovery.submit")
                if account.sendingPasswordReset { ProgressView("Sending reset link…") }
            }
            if !account.passwordResetStatus.isEmpty {
                Section {
                    Text(account.passwordResetStatus)
                        .accessibilityIdentifier("account.recovery.status")
                }
            }
        }
        .navigationTitle("Reset Password")
        .task(id: account.session?.owner) {
            if forCurrentAccount { await account.loadEmailAddress() }
        }
        .onDisappear { submission?.cancel(); submission = nil }
    }
    private func submit() {
        guard !unavailable else { return }
        submission = Task { @MainActor in
            if forCurrentAccount { _ = await account.requestPasswordResetForCurrentAccount() }
            else { _ = await account.requestPasswordReset(email: email) }
            submission = nil
        }
    }
}

struct BoundCreateAccountView: View {
    @ObservedObject var account: BoundFriendAccount
    @Binding var signInEmail: String
    var signedIn: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var username = ""
    @State private var email = ""
    @State private var password = ""
    @State private var checkEmail = false
    @State private var submission: Task<Void, Never>?
    var body: some View {
        Form {
            if checkEmail {
                Section {
                    Text(account.status).accessibilityIdentifier("account.signup.result")
                    Button("Back to Sign In") { dismiss() }
                }
            } else {
                Section {
                    TextField("Username", text: $username)
                        .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("account.signup.username")
                    TextField("Email", text: $email).textContentType(.username).keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("account.signup.email")
                    SecureField("Password", text: $password).textContentType(.newPassword)
                        .accessibilityIdentifier("account.signup.password")
                }.disabled(account.busy)
                Section {
                    Button("Create Account") {
                        let entered = password; password = ""
                        signInEmail = email
                        submission = Task { @MainActor in
                            let result = await account.createAccount(email: email, password: entered, username: username)
                            guard !Task.isCancelled else { return }
                            if result == .signedIn { signedIn(); dismiss() }
                            else if result == .checkEmail { checkEmail = true }
                            submission = nil
                        }
                    }.disabled(account.busy || BoundFriendAccount.normalizedEmail(email) == nil || password.isEmpty || !BoundSocialAPI.validUsername(username.trimmingCharacters(in: .whitespacesAndNewlines)))
                        .accessibilityIdentifier("account.signup.submit")
                    if account.busy { ProgressView("Creating account…") }
                    Text(account.status).font(.caption)
                }
            }
        }.navigationTitle("Create Account")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { submission?.cancel(); password = ""; dismiss() } } }
            .onAppear { email = signInEmail }
            .onDisappear { submission?.cancel(); submission = nil; password = "" }
    }
}

struct BoundDeleteAccountView: View {
    @ObservedObject var account: BoundFriendAccount
    var stopSharing: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var confirmationEmail = ""
    var body: some View {
        Form {
            Section {
                Text("Permanently deletes your Bound account, friends, and Bound cloud data. Local games and notes stay on this device.")
                if account.deletionPending {
                    Button("Retry account deletion", role: .destructive) { Task { await account.resumeAccountDeletion() } }
                        .disabled(account.busy)
                } else if account.session != nil {
                    if let email = account.deletionEmail {
                        Text("Type \(email) to confirm.").textSelection(.enabled)
                        TextField("Account email", text: $confirmationEmail).keyboardType(.emailAddress)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityIdentifier("account.deletion.email").disabled(account.busy)
                        Button("DELETE MY ACCOUNT", role: .destructive) {
                            stopSharing()
                            Task { await account.deleteAccount(confirmationEmail: confirmationEmail) }
                        }.disabled(account.busy || BoundFriendAccount.normalizedEmail(confirmationEmail) != email)
                            .accessibilityIdentifier("account.deletion.submit")
                    } else {
                        Button("Verify account email") { Task { await account.loadDeletionIdentity() } }.disabled(account.busy)
                    }
                }
                if account.busy { ProgressView("Please wait…") }
                Text(account.status).font(.caption).accessibilityIdentifier("account.deletion.result")
            }
        }.navigationTitle("Delete Account")
            .navigationBarBackButtonHidden(account.busy)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(account.session == nil ? "Done" : "Cancel") { dismiss() }.disabled(account.busy) } }
            .task { await account.loadDeletionIdentity() }
            .interactiveDismissDisabled(account.busy)
    }
}


/// A separate canvas preserves the companion screen when the watch sheet closes.
struct BoundPartnerSpectatorControls: View {
    @ObservedObject var sharing: FriendSharingSession
    @State private var showing = false
    var body: some View {
        Section("Partner Battle") {
            Button("Watch partner", systemImage: "play.rectangle") {
                sharing.watchPartner()
                showing = sharing.watchingPartner
            }
            .disabled(!sharing.active || !sharing.joined || sharing.reconnecting)
            .accessibilityIdentifier("bound.watch-partner")
        }
        .fullScreenCover(isPresented: $showing, onDismiss: { sharing.stopWatchingPartner() }) {
            BoundPartnerSpectatorView(sharing: sharing)
        }
    }
}

struct BoundPartnerSpectatorView: View {
    @ObservedObject var sharing: FriendSharingSession
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                BoundRemoteCanvas(view: sharing.spectatorView, hidesAccessibilityChildren: true)
                    .aspectRatio(1.5, contentMode: .fit)
                    .opacity(sharing.spectatorLive ? 1 : 0)
                if !sharing.spectatorLive {
                    Text(sharing.reconnecting ? "Reconnecting…" : "Waiting for live partner video…")
                        .foregroundStyle(.white)
                }
            }
            .navigationTitle(sharing.spectatorLive ? "Partner · Live" : "Partner")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Close") { dismiss() } }
            }
        }
        .onChange(of: sharing.watchingPartner) { _, watching in if !watching { dismiss() } }
        .onDisappear { sharing.stopWatchingPartner() }
    }
}
