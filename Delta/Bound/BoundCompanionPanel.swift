import SwiftUI
import UIKit
import AVFoundation
import Combine
import DeltaCore

@MainActor
final class BoundCompanionState: ObservableObject {
    @Published var selected = 0
    @Published var landscape = false
    @Published var chartTopInset: CGFloat = 0
    @Published var hidden = false
    @Published var showingFriends = false
    @Published var showingSettings = false
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
    init(preferences: BoundPiPPreferences? = nil) { self.preferences = preferences ?? BoundPiPPreferences() }
    var changed: (() -> Void)?
    var pendingControlEditor = false
    var editControls: (() -> Void)?
    var sharingChanged: ((Bool) -> Void)?
    var selectionChanged: (() -> Void)?
    var content: BoundPiPContent { selected == 1 ? .notes : selected == 2 ? .types : .friend }
    func refresh() { revision += 1; changed?() }
}

/// The overlay yields native button touches even if a moved PiP crosses a button.
private final class BoundOverlayView: UIView {
    var yieldsTouch: ((CGPoint) -> Bool)?
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if yieldsTouch?(point) == true { return nil }
        return super.hitTest(point, with: event)
    }
}

@MainActor
final class BoundCompanionCoordinator {
    let sharing: FriendSharingSession
    #if DEBUG && targetEnvironment(simulator)
    private let usesLocalPairedFixture: Bool
    #endif
    let onboarding = FriendOnboarding()
    let account = BoundFriendAccount.shared
    let state: BoundCompanionState
    init(state: BoundCompanionState? = nil) {
        self.state = state ?? BoundCompanionState()
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
    private var host: UIHostingController<BoundCompanionPanel>?
    private var controls: BoundCompanionCycleButton?
    private var subscriptions = Set<AnyCancellable>()
    private var nativeMenuAccessibility: BoundNativeMenuAccessibilityElement?
    private weak var settingsPresenter: UIViewController?
    private var overlay: BoundOverlayView?
    private weak var owner: GameViewController?
    private weak var boundCore: EmulatorCore?
    private var gameID = ""
    private var notesPaused = false
    private(set) var isEditingNotes = false
    private var keyboardHeight: CGFloat = 0
    private var observers: [NSObjectProtocol] = []
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
    func install(in owner: GameViewController) {
        guard host == nil else { return }
        self.owner = owner
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--bound-ui-reset-layout") {
            UserDefaults.standard.removeObject(forKey: BoundControllerModePreferences.key)
            for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("bound.delta.pip.v1.") || key.hasPrefix("bound.controls.v1.") { UserDefaults.standard.removeObject(forKey: key) }
        }
        #endif
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--bound-ui-screen-layout-bound") { BoundAppearancePreferences().screenLayout = .bound }
        if ProcessInfo.processInfo.arguments.contains("--bound-ui-reset-screen-layout") { UserDefaults.standard.removeObject(forKey: BoundAppearancePreferences.screenLayoutKey) }
        #endif
        state.changed = { [weak owner] in owner?.view.setNeedsLayout() }
        state.editControls = { [weak self] in self?.editControls() }
        state.selectionChanged = { [weak self] in self?.cancelInteractions() }
        state.sharingChanged = { [weak self] in self?.tap.setEnabled($0) }
        observers.append(NotificationCenter.default.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] notification in
            guard let self, let owner = self.owner, let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let local = owner.view.convert(frame, from: nil)
            self.keyboardHeight = owner.presentedViewController == nil ? max(0, owner.view.bounds.maxY - local.minY) : 0
            owner.view.setNeedsLayout()
        })
        observers.append(NotificationCenter.default.addObserver(forName: BoundAppearancePreferences.didChangeNotification, object: nil, queue: .main) { [weak self, weak owner] _ in self?.cancelInteractions(); owner?.view.setNeedsLayout() })
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in self?.background() })
        // Restore foreground eligibility without automatically restarting authenticated sharing.
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in self?.foreground() })
        let panel = BoundCompanionPanel(sharing: sharing, state: state, gameID: (owner.game as? Game)?.identifier ?? "", editingChanged: { [weak self] in self?.notesEditing($0) })
        let host = UIHostingController(rootView: panel)
        // The coordinator already positions the overlay inside the game viewport.
        // A second inherited home-indicator inset would shrink the visible video
        // and shift the bottom-corner content above its actual PiP frame.
        host.safeAreaRegions = []
        host.view.backgroundColor = .clear
        let overlay = BoundOverlayView()
        overlay.accessibilityIdentifier = "bound.companion-container"
        overlay.yieldsTouch = { [weak self, weak overlay] point in
            guard let self, let owner = self.owner, let overlay, !self.isEditingNotes else { return false }
            let local = owner.controllerView.convert(point, from: overlay)
            return owner.controllerView.controlHitFrames.contains { $0.contains(local) }
        }
        owner.addChild(host); owner.view.addSubview(overlay); overlay.addSubview(host.view); host.didMove(toParent: owner)
        self.overlay = overlay; self.host = host
        let controls = BoundCompanionCycleButton()
        controls.cycle = { [weak self] in
            self?.cyclePanels()
        }
        owner.view.addSubview(controls); self.controls = controls
        sharing.$joined.combineLatest(sharing.$active).sink { [weak self] joined, active in
            self?.tap.setEnabled(joined && active)
        }.store(in: &subscriptions)
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
    func bind(core: EmulatorCore?, gameID: String) {
        guard boundCore !== core || self.gameID != gameID else { return }
        cancelInteractions(); tap.setEnabled(false); sharing.stop(); notesPaused = false; isEditingNotes = false; owner?.controllerView.isUserInteractionEnabled = true; self.gameID = gameID
        host?.rootView.gameID = gameID
        guard let core else { boundCore = nil; state.emulationDetails = nil; return }
        state.emulationDetails = BoundEmulationDetails(packageName: core.deltaCore.name, packageIdentifier: core.deltaCore.identifier, packageVersion: core.deltaCore.version)
        boundCore = core
        let previous = core.updateHandler, tap = self.tap
        core.updateHandler = { [weak tap] core in previous?(core); tap?.receive(core) }
        #if DEBUG && targetEnvironment(simulator)
        if usesLocalPairedFixture { sharing.start() }
        #endif
    }
    func layout(in bounds: CGRect, safeArea: UIEdgeInsets, controllerSize: CGSize) -> CGRect? {
        guard let owner else { return nil }
        let screenLayout = BoundAppearancePreferences().effectiveScreenLayout
        if previousScreenLayout != screenLayout { previousScreenLayout = screenLayout; cancelInteractions() }
        let landscape = bounds.width > bounds.height
        if state.landscape != landscape { state.landscape = landscape; cancelInteractions() }
        if screenLayout == .delta {
            owner.gameScreenLayoutBounds = nil
            return nil // Native Delta must lay out first; companion positioning follows it.
        }
        let horizontal = CGRect(x: safeArea.left, y: 0, width: max(1, bounds.width - safeArea.left - safeArea.right), height: bounds.height)
        if landscape {
            // The native game and controls must finish layout before placing PiP.
            owner.gameScreenLayoutBounds = horizontal
            return bounds
        }
        let geometry = BoundPortraitScreenGeometry(bounds: bounds, safeTop: safeArea.top,
            controllerSize: controllerSize, gameAspect: owner.emulatorCore?.preferredRenderingSize ?? CGSize(width: 3, height: 2))
        overlay?.frame = geometry.friend
        if state.content != .friend { overlay?.frame = CGRect(x: bounds.minX, y: geometry.friend.minY, width: bounds.width, height: geometry.friend.height) }
        if state.content == .types {
            overlay?.frame = BoundTypeChartGeometry.portraitViewport(bounds: bounds, gameFrame: geometry.game)
            if state.chartTopInset != safeArea.top { state.chartTopInset = safeArea.top }
        }
        if isEditingNotes {
            overlay?.frame.size.height = max(geometry.friend.height, min(220, bounds.height - keyboardHeight - geometry.friend.minY - 8))
        }
        overlay?.isHidden = false; overlay?.alpha = 1
        host?.view.frame = overlay?.bounds ?? .zero
        owner.gameScreenLayoutBounds = geometry.game
        owner.view.bringSubviewToFront(overlay!); layoutCycleButton(bounds: bounds, safeArea: safeArea)
        return nil // Native Delta's full-viewport controller layout remains untouched.
    }
    func bringControlsToFront() {
        guard let owner else { return }
        layoutCycleButton(bounds: owner.view.bounds, safeArea: owner.view.safeAreaInsets)
        if state.landscape || BoundAppearancePreferences().effectiveScreenLayout == .delta {
            layoutFloatingPanel()
        }
        sharing.setRemotePresentationEnabled(state.content == .friend && overlay?.isHidden == false)
        if let controls { owner.view.bringSubviewToFront(controls) }
    }
    /// One final placement, using the settled native viewport and actual hit regions.
    private func layoutFloatingPanel() {
        guard let owner, let overlay, let controls else { return }
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
            baseSize: companionBaseSize(width: viewport.width * 0.36),
            scale: CGFloat(state.preferences.scale(for: state.content)) * pinchScale, occupied: occupied)
        geometry = layout
        let corner = state.preferences.corner(for: state.content)
        // Follow the finger continuously; collision-free corner placement happens
        // on release. The overlay always yields touches to native controls.
        let center = translation == .zero ? layout.center(corner) : layout.dragCenter(from: corner, translation: translation)
        var panel = CGRect(x: center.x - layout.size.width / 2, y: center.y - layout.size.height / 2,
                           width: layout.size.width, height: layout.size.height)
        if isEditingNotes {
            let available = owner.view.bounds.inset(by: owner.view.safeAreaInsets)
            let top = available.minY + (state.landscape ? 4 : 48)
            panel = CGRect(x: available.midX - min(400, available.width) / 2, y: top,
                           width: min(400, available.width),
                           height: max(100, min(230, owner.view.bounds.height - keyboardHeight - top - 8)))
        }
        overlay.frame = panel
        host?.view.frame = overlay.bounds
        overlay.isHidden = state.hidden || layout.size.width == 0 || layout.size.height == 0
        overlay.alpha = isEditingNotes ? 1 : liveOpacity ?? state.preferences.opacity(for: state.content)
        owner.view.bringSubviewToFront(overlay)
    }
    private func layoutCycleButton(bounds: CGRect, safeArea: UIEdgeInsets) {
        guard let owner, let controls, let skin = owner.controllerView.controllerSkin,
              let traits = owner.controllerView.controllerSkinTraits,
              let menu = skin.items(for: traits)?.first(where: { $0.inputs.allInputs.contains(where: { $0.stringValue == "menu" }) }) else { controls?.isHidden = true; return }
        let local = menu.frame.applying(.init(scaleX: owner.controllerView.bounds.width, y: owner.controllerView.bounds.height))
        let frame = owner.controllerView.convert(local, to: owner.view)
        let menuAccessibility = nativeMenuAccessibility ?? BoundNativeMenuAccessibilityElement(accessibilityContainer: owner.controllerView)
        menuAccessibility.accessibilityIdentifier = "bound.native-menu"
        menuAccessibility.accessibilityLabel = "Menu"
        menuAccessibility.accessibilityTraits = .button
        menuAccessibility.accessibilityFrameInContainerSpace = local
        menuAccessibility.activate = { [weak owner] in
            guard let owner else { return false }
            owner.controllerView.cancelTouchInputs()
            owner.gameViewController(owner, handleMenuInputFrom: owner.controllerView)
            return true
        }
        var accessibleControls: [UIAccessibilityElement] = [menuAccessibility]
        for input in ["l", "r"] {
            guard let item = skin.items(for: traits)?.first(where: { $0.inputs.allInputs.contains(where: { $0.stringValue == input }) }) else { continue }
            let element = UIAccessibilityElement(accessibilityContainer: owner.controllerView)
            element.accessibilityIdentifier = "bound.native-" + input
            element.accessibilityLabel = input.uppercased() + " shoulder control"
            element.accessibilityFrameInContainerSpace = item.frame.applying(.init(scaleX: owner.controllerView.bounds.width, y: owner.controllerView.bounds.height))
            accessibleControls.append(element)
        }
        owner.controllerView.accessibilityElements = accessibleControls
        nativeMenuAccessibility = menuAccessibility
        let controller = owner.controllerView.convert(owner.controllerView.bounds, to: owner.view)
        let occupied = owner.controllerView.controlHitFrames.map { owner.controllerView.convert($0, to: owner.view) }
        controls.isHidden = false
        let right = skin.items(for: traits)?.first(where: { $0.inputs.allInputs.contains(where: { $0.stringValue == "r" }) })
        let rightFrame = right.map { owner.controllerView.convert($0.extendedFrame.applying(.init(scaleX: owner.controllerView.bounds.width, y: owner.controllerView.bounds.height)), to: owner.view) }
        let menuHitSize = menu.extendedFrame.applying(.init(scaleX: owner.controllerView.bounds.width, y: owner.controllerView.bounds.height)).size
        let boundPortrait = !state.landscape && BoundAppearancePreferences().effectiveScreenLayout == .bound
        let select = skin.items(for: traits)?.first { $0.inputs.allInputs.contains { $0.stringValue == "select" } }
        let selectArtwork = boundPortrait && BoundAppearancePreferences().effectiveTheme != .minimal
            ? select.flatMap { skin.image(for: $0, traits: traits, preferredSize: .large)?.0 } : nil
        controls.configure(menuFrame: frame, controllerFrame: controller, landscape: state.landscape,
            minimal: BoundAppearancePreferences().effectiveTheme == .minimal, content: state.content,
            canvas: bounds.inset(by: safeArea), occupied: occupied, rightShoulderFrame: rightFrame, menuHitSize: menuHitSize, boundPortrait: boundPortrait, selectArtwork: selectArtwork,
            rightControlGutter: owner.boundLandscapeControlGutter(),
            menuHitFrame: owner.controllerView.convert(menu.extendedFrame.applying(.init(scaleX: owner.controllerView.bounds.width, y: owner.controllerView.bounds.height)), to: owner.view))
        controls.accessibilityHint = state.hidden ? "Restores the hidden panel" : "Cycles Friend, Notes, and Types"
        owner.view.bringSubviewToFront(controls)
    }
    func presentFriends(from presenter: UIViewController) {
        cancelInteractions(); state.showingFriends = true
        let host = UIHostingController(rootView: BoundFriendsSheet(sharing: sharing, onboarding: onboarding, account: account, closed: { [weak self] in self?.state.showingFriends = false }))
        presenter.present(host, animated: true)
    }
    func presentSettings(from presenter: UIViewController) {
        cancelInteractions(); state.showingSettings = true; settingsPresenter = presenter
        let host = UIHostingController(rootView: BoundPiPSettings(state: state, closed: { [weak self] in
            guard let self else { return }; self.state.showingSettings = false
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
        }))
        presenter.present(host, animated: true)
    }
    func cancelInteractions() {
        gestures?.cancel(); translation = .zero; pinchScale = 1; liveOpacity = nil
        fadingContent = nil; resizingContent = nil
        owner?.controllerView.cancelTouchInputs()
    }
    func cyclePanels() {
        owner?.view.endEditing(true)
        cancelInteractions()
        if !state.hidden { state.selected = (state.selected + 1) % 3 }
        state.hidden = false; state.refresh()
    }
    var allowsOpacityGesture: Bool { state.landscape && state.content != .types && !isEditingNotes }
    private func companionBaseSize(width: CGFloat) -> CGSize {
        let image = state.landscape && state.content == .types ? UIImage(named: "PokemonTypeChart")?.size : nil
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
        guard (state.landscape || (BoundAppearancePreferences().effectiveScreenLayout == .delta && state.content != .types)), !isEditingNotes, !state.showingFriends, !state.showingSettings,
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
        sharing.foreground()
        #if DEBUG && targetEnvironment(simulator)
        if usesLocalPairedFixture { sharing.start() }
        #endif
    }
    func background() { cancelInteractions(); tap.setEnabled(false); sharing.background(); onboarding.close() }
    func stop() {
        cancelInteractions(); tap.setEnabled(false); sharing.stop(); onboarding.close()
        notesPaused = false; isEditingNotes = false; owner?.controllerView.isUserInteractionEnabled = true; host?.view.endEditing(true)
    }
    private func notesEditing(_ editing: Bool) {
        isEditingNotes = editing; owner?.controllerView.cancelTouchInputs()
        owner?.controllerView.isUserInteractionEnabled = !editing
        owner?.view.setNeedsLayout()
        guard let core = owner?.emulatorCore else { return }
        if editing {
            notesPaused = core.state == .running
            if notesPaused { core.pause() }
        } else {
            let resume = notesPaused; notesPaused = false
            if resume, core.state == .paused, owner?.view.window != nil,
               UIApplication.shared.applicationState == .active, let owner,
               owner.gameViewControllerShouldResumeEmulation(owner) { core.resume() }
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
    var body: some View {
        Group {
            if state.selected == 0 {
                ZStack {
                    Color.black
                    BoundRemoteCanvas(view: sharing.remoteView).opacity(sharing.remoteVisible || state.displaysFixtureVideo ? 1 : 0)
                    if !sharing.remoteVisible && !state.displaysFixtureVideo { Text(sharing.active ? "Waiting for friend" : "Connect a friend").foregroundStyle(.white).font(.callout) }
                }.accessibilityIdentifier("bound.friend-screen")
            } else if state.selected == 1 {
                BoundNotesEditor(gameID: gameID, floating: state.landscape, editingChanged: editingChanged).id(gameID)
            } else {
                if state.landscape {
                    Image("PokemonTypeChart").resizable().scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel("Pokémon type effectiveness chart")
                        .accessibilityIdentifier("bound.type-chart")
                } else { BoundTypeChartView(topInset: state.chartTopInset, constrainsPan: BoundAppearancePreferences().effectiveScreenLayout == .bound) }
            }
        }.background(state.content == .types ? Color.black : Color(uiColor: .secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: state.landscape ? 8 : state.content == .types ? 0 : 4))
        .onChange(of: sharing.joined) { _ in state.refresh() }
    }
}

private struct BoundPiPSettings: View {
    @ObservedObject var state: BoundCompanionState
    var closed: () -> Void = {}
    @Environment(\.dismiss) var dismiss
    var body: some View {
        NavigationStack {
            Form {
                BoundAppearanceSettings(emulationDetails: state.emulationDetails)
                if !BoundFeatureVisibility.simplifiedSettings {
                Section("Picture in picture") {
                    Text("In landscape, drag a panel with one finger to move it, or pinch on it with two fingers to resize. Slide two fingers vertically in the center of the game to change Friend or Notes opacity. Types stays opaque. Swipe a panel to an edge to hide; tap the companion button to restore it. Portrait Types zooms and pans its chart content.")
                    ForEach([BoundPiPContent.friend, .notes], id: \.rawValue) { content in
                        VStack(alignment: .leading) {
                            Text("\(content.rawValue.capitalized) transparency: \(Int(state.preferences.transparency(for: content) * 100))%")
                            Slider(value: Binding(get: { state.preferences.transparency(for: content) }, set: { state.preferences.setTransparency($0, for: content); state.refresh() }), in: 0...1, step: 0.05).accessibilityIdentifier("bound.\(content.rawValue)-transparency")
                        }
                    }
                    Button("Show PiP") { state.hidden = false; state.refresh() }
                }
                Section("Controls") {
                    Text("Classic placement is the default. Customize positions separately for portrait and landscape, or reset to defaults.")
                }
                }
            }.navigationTitle("Bound Settings").toolbar {
                if !BoundFeatureVisibility.simplifiedSettings { ToolbarItem(placement: .navigationBarLeading) { Button("Buttons") { state.pendingControlEditor = true; dismiss() }.accessibilityLabel("Button placement").accessibilityIdentifier("bound.button-placement") } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }.onDisappear(perform: closed)
    }
}

private struct BoundRemoteCanvas: UIViewRepresentable {
    let view: UIView
    func makeUIView(context: Context) -> UIView { view }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

private struct BoundNotesEditor: View {
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
        .onChange(of: text) { next in
            guard readable else { return }
            do { try store.write(next, game: gameID); status = "" }
            catch { status = "Could not save notes (16 KB limit)." }
        }
        .onChange(of: classicEditing) { if !usesBoundArrangement { editing = $0 } }
        .onChange(of: screenLayoutRaw) { _ in editing = false; classicEditing = false }
        .onChange(of: editing) { editingChanged($0) }
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

private struct BoundFriendsSheet: View {
    @ObservedObject var sharing: FriendSharingSession
    @ObservedObject var onboarding: FriendOnboarding
    @ObservedObject var account: BoundFriendAccount
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var name = ""
    @State private var invite = ""
    @State private var reportingRoom: FriendRoom?
    @State private var blockingRoom: FriendRoom?
    var closed: () -> Void = {}
    var body: some View {
        NavigationStack {
            Form {
                Section("Bound account") {
                    if account.deletionPending {
                        Button("Retry account deletion", role: .destructive) {
                            Task { await account.resumeAccountDeletion(); onboarding.synchronizeAccount() }
                        }.disabled(account.busy)
                    } else if account.session == nil {
                        TextField("Email", text: $email).textContentType(.username).textInputAutocapitalization(.never).keyboardType(.emailAddress).autocorrectionDisabled()
                        SecureField("Password", text: $password).textContentType(.password)
                        Button("Sign in") {
                            let entered = password; password = ""
                            Task { await account.signIn(email: email, password: entered); onboarding.synchronizeAccount() }
                        }.disabled(account.busy || email.isEmpty || password.isEmpty)
                        NavigationLink("Create Account") {
                            BoundCreateAccountView(account: account, signInEmail: $email) { onboarding.synchronizeAccount() }
                        }.disabled(account.busy)
                    } else {
                        Button("Sign out") { sharing.stop(); onboarding.signOut(); account.signOut() }.disabled(account.busy)
                    }
                    Text(account.status).font(.caption)
                }
                if account.session != nil {
                    Section("Friends") {
                        Text(onboarding.message).font(.caption)
                        ForEach(onboarding.rooms) { room in
                            HStack {
                                Button(room.displayName) { onboarding.select(room) }
                                Spacer()
                                Menu {
                                    Button("Report") { reportingRoom = room }
                                    Button("Block", role: .destructive) { blockingRoom = room }
                                } label: { Image(systemName: "ellipsis.circle") }
                                    .accessibilityLabel("Actions for \(room.displayName)")
                            }.disabled(onboarding.busy)
                        }
                        Button("Refresh") { onboarding.refresh() }.disabled(onboarding.busy)
                        if onboarding.selected != nil {
                            Button(sharing.active ? "Stop sharing" : "Start sharing") {
                                if sharing.active { sharing.stop() } else { sharing.start() }
                            }
                        }
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
                    Section("Add a friend") {
                        TextField("Your display name", text: $name)
                        Button("Create invite") { onboarding.create(name: name) }.disabled(onboarding.busy || name.isEmpty)
                        if let code = onboarding.inviteCode {
                            Text(code).textSelection(.enabled)
                        }
                        TextField("Friend's invite code", text: $invite).textInputAutocapitalization(.characters).autocorrectionDisabled()
                        Button("Accept invite") { onboarding.accept(code: invite, name: name); invite = "" }
                            .disabled(onboarding.busy || invite.count != 16 || name.isEmpty)
                    }
                    Section {
                        NavigationLink {
                            BoundDeleteAccountView(account: account) { sharing.stop(); onboarding.signOut() }
                        } label: {
                            Text("DELETE MY ACCOUNT").foregroundStyle(.red)
                        }.disabled(account.busy)
                    }
                }
                Section {
                    Link("Rules & contact", destination: URL(string: "https://evanvonessen.github.io/bound/moderation.html")!).font(.caption)
                }
            }.navigationTitle("Friends")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(account.busy) } }
        }
        .onAppear { onboarding.open(sharing: sharing, existing: { account.session }) }
        .onChange(of: scenePhase) { phase in
            if phase == .active { onboarding.open(sharing: sharing, existing: { account.session }) }
            else { onboarding.close() }
        }
        .onDisappear { password = ""; onboarding.close(); closed() }
        .interactiveDismissDisabled(account.busy)
        .sheet(item: $reportingRoom) { room in BoundReportView(onboarding: onboarding, room: room) }
        .confirmationDialog("Block this friend?", isPresented: Binding(get: { blockingRoom != nil }, set: { if !$0 { blockingRoom = nil } }), titleVisibility: .visible) {
            Button("Block", role: .destructive) { if let room = blockingRoom { onboarding.block(room) }; blockingRoom = nil }
            Button("Cancel", role: .cancel) { blockingRoom = nil }
        }
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
                Link("Rules & contact", destination: URL(string: "https://evanvonessen.github.io/bound/moderation.html")!).font(.caption)
            }.navigationTitle("Report")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }
}

struct BoundCreateAccountView: View {
    @ObservedObject var account: BoundFriendAccount
    @Binding var signInEmail: String
    var signedIn: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
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
                            let result = await account.createAccount(email: email, password: entered)
                            guard !Task.isCancelled else { return }
                            if result == .signedIn { signedIn(); dismiss() }
                            else if result == .checkEmail { checkEmail = true }
                            submission = nil
                        }
                    }.disabled(account.busy || BoundFriendAccount.normalizedEmail(email) == nil || password.isEmpty)
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
