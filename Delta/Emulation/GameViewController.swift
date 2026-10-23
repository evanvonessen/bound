//
//  GameViewController.swift
//  Delta
//
//  Created by Riley Testut on 5/5/15.
//  Copyright © 2016 Riley Testut. All rights reserved.
//

import UIKit
import Photos
import AVFoundation

import DeltaCore
import GBADeltaCore
import N64DeltaCore
import MelonDSDeltaCore
import GPGXDeltaCore

import Roxas
import AltKit
import SwiftUI

private var kvoContext = 0

/// Bound keeps a virtual controller receiver alongside a wireless pad so its
/// touch controls remain available. Controller Mode only changes the skin's
/// landscape artwork; it never changes whether this receiver is shown.
struct BoundControllerViewAssignment {
    let isVisible: Bool
    let playerIndex: Int

    static func resolve(localPlayerIndex: Int?, externalPlayerIndex: Int?, menuOnly: Bool) -> Self {
        let playerIndex = (menuOnly ? externalPlayerIndex : nil) ?? localPlayerIndex ?? externalPlayerIndex ?? 0
        return Self(isVisible: true, playerIndex: playerIndex)
    }
}

private extension DeltaCore.ControllerSkin
{
    func hasTouchScreen(for traits: DeltaCore.ControllerSkin.Traits) -> Bool
    {
        let hasTouchScreen = self.items(for: traits)?.contains(where: { $0.kind == .touchScreen }) ?? false
        return hasTouchScreen
    }
}
/// Reuses the stock Menu hit frame while UIKit repeats layout for unchanged skin geometry.
struct BoundStockMenuDefaultFrameCache {
    struct Key: Equatable {
        let skinIdentity: ObjectIdentifier?
        let skinIdentifier: String
        let skinName: String
        let gameType: String
        let debugMode: Bool
        let traits: DeltaCore.ControllerSkin.Traits
        let sourceFrame: CGRect
        let contentInsets: UIEdgeInsets
        let gutter: CGRect?
        let controlLayout: BoundControlLayout
        let canvasSize: CGSize
    }

    private var cachedKey: Key?
    private var cachedFrame: CGRect?
    private var hasCachedValue = false

    mutating func frame(for key: Key, compute: () -> CGRect?) -> CGRect? {
        if hasCachedValue, cachedKey == key { return cachedFrame }
        let frame = compute()
        cachedKey = key
        cachedFrame = frame
        hasCachedValue = true
        return frame
    }
}

private extension GameViewController
{
    struct PausedSaveState: SaveStateProtocol
    {
        var fileURL: URL
        var gameType: GameType
        
        var isSaved = false
        
        init(fileURL: URL, gameType: GameType)
        {
            self.fileURL = fileURL
            self.gameType = gameType
        }
    }
    
    struct DefaultInputMapping: GameControllerInputMappingProtocol
    {
        let gameController: GameController
        let defaultMapping: GameControllerInputMappingProtocol?

        init(gameController: GameController, gameType: GameType) {
            self.gameController = gameController
            if gameController.inputType == .mfi, gameType == .gba {
                self.defaultMapping = BoundMultiviewDefaultMapping.mapping(for: gameController, gameType: gameType)
            } else {
                self.defaultMapping = gameController.defaultInputMapping
            }
        }
        
        var gameControllerInputType: GameControllerInputType {
            return self.gameController.inputType
        }
        
        func input(forControllerInput controllerInput: Input) -> Input?
        {
            if let mappedInput = self.defaultMapping?.input(forControllerInput: controllerInput)
            {
                return mappedInput
            }
            
            // Only intercept controller skin inputs.
            guard controllerInput.type == .controller(.controllerSkin) else { return nil }
            
            let actionInput = ActionInput(stringValue: controllerInput.stringValue)
            return actionInput
        }
    }
}

class GameViewController: DeltaCore.GameViewController
{
    private let boundCompanion = BoundCompanionCoordinator()
    private let boundWorldAPressed = NSHashTable<AnyObject>.weakObjects()
    var boundCompanionForTesting: BoundCompanionCoordinator { boundCompanion }
    func releaseBoundFriendGameplayInputs() {
        guard let core = emulatorCore else { return }
        var controllers: [GameController] = [controllerView]
        controllers.append(contentsOf: ExternalGameControllerManager.shared.connectedControllers)
        for controller in controllers {
            guard var mapping = controller.inputMapping(for: core) as? BoundControllerInputMapping else { continue }
            mapping.friendWorldGate = nil
            for (physical, _) in controller.activatedInputs {
                if let target = mapping.input(forControllerInput: physical),
                   ActionInput(input: target) == nil, StandardGameControllerInput(input: target) != .menu {
                    // Cancel sustained reactivation as well as the current press;
                    // otherwise Delta's delayed hold job can reassert a game input
                    // after the invitation starts blocking the normal mapping.
                    if controller.sustainedInputs[physical] != nil { controller.unsustain(physical) }
                    core.gameController(controller, didDeactivate: target)
                }
            }
        }
        controllerView.cancelTouchInputs()
    }
    func refreshBoundControllerPreferences() {
        updateControllers()
        refreshBoundMultiviewInputRouting()
    }
    private(set) var boundRRDexSaveCache = BoundRRDexSaveCache()
    func boundRRDexDidLoadSaveState(core: EmulatorCore) {
        guard core === emulatorCore, core.game.type == .gba else { return }
        boundCompanion.sharing.interactions.invalidate()
        boundCompanion.playerStateDisplay.didLoadSaveState()
        #if DEBUG && targetEnvironment(simulator)
        BoundFullAppGameplayQA.current?.didRestore()
        #endif
        boundRRDexSaveCache.invalidate(restoredState: true)
        guard let game = game as? Game else { return }
        // Save-state RAM can differ from the battery file. Read it while the
        // caller already has the core paused, so there is no second pause cycle.
        if core.state == .paused {
            _ = try? boundRRDexSaveCache.value(completedSave: {
                throw BoundRRDexSave.ImportError.currentGameUnavailable
            }, restoredSave: {
                try BoundRRDexCurrentSaveImport.capture { core.deltaCore.emulatorBridge.saveGameSave(to: $0) }
            })
        }
        BoundRRDexSaveRefreshEvent.post(gameID: game.identifier)
    }
    private var boundControllerModeActive = false
    private struct BoundControlConfiguration: Equatable {
        let skin: String
        let layout: BoundControlLayout
        let canvas: CGSize
        let source: CGRect
        let insets: UIEdgeInsets
        let gutter: CGRect?
        let minimal: Bool
        let controllerMode: Bool
        let controllerMenuFrame: CGRect?
        let style: UIUserInterfaceStyle
        let contrast: UIAccessibilityContrast
    }
    private var boundControlConfiguration: BoundControlConfiguration?
    private var boundStockMenuDefaultFrameCache = BoundStockMenuDefaultFrameCache()
    private var boundAppliedSkinIdentifier: String?
    private let boundPanelActions = BoundPanelActionRouter()
    private let boundMultiviewRepeater = BoundMultiviewInputRepeater()
    private var boundMultiviewCapturing = false
    private var updatingBoundMultiviewRouting = false
    var boundFastForwardPreferences = BoundFastForwardPreferences()
    /// Assumed to be Delta.Game instance
    override var game: GameProtocol? {
        get { super.game }
        set {
            guard newValue == nil || !BoundROMUpdateManager.shared.isApplying else { return }
            let oldValue = super.game
            self.emulatorCore?.removeObserver(self, forKeyPath: #keyPath(EmulatorCore.state), context: &kvoContext)
            
            let previousGame = self.game as? Game
            NotificationCenter.default.removeObserver(self, name: .NSManagedObjectContextDidSave, object: previousGame?.managedObjectContext)
            super.game = newValue
            BoundROMUpdateActivity.bindingChanged(self)
            self.emulatorCore?.addObserver(self, forKeyPath: #keyPath(EmulatorCore.state), options: [.old], context: &kvoContext)
            
            let game = self.game as? Game
            NotificationCenter.default.addObserver(self, selector: #selector(GameViewController.managedObjectContextDidChange(with:)), name: .NSManagedObjectContextObjectsDidChange, object: game?.managedObjectContext)
            
            let gameIdentifier = game?.identifier
            let gameSaveURL = game?.gameSaveURL
            let isGBA = game?.type == .gba
            let dexSaveCache = BoundRRDexSaveCache()
            self.boundRRDexSaveCache = dexSaveCache
            self.emulatorCore?.saveHandler = { [weak self, gameIdentifier, gameSaveURL, dexSaveCache] _ in
                self?.updateGameSave()
                guard isGBA, let gameIdentifier, let gameSaveURL,
                      !BoundRRDexSaveRefreshEvent.isSuppressed(gameID: gameIdentifier) else { return }
                if dexSaveCache.completedSave(read: { try BoundRRDexCurrentSaveImport.readCompletedSave(at: gameSaveURL) }) {
                    BoundRRDexSaveRefreshEvent.post(gameID: gameIdentifier)
                }
            }
            
            if oldValue?.fileURL != game?.fileURL
            {
                self.shouldResetSustainedInputs = true
            }
            
            self.updateControllers()
            self.updateAudio()
            
            self.presentedGyroAlert = false
            
            self.startTrackingAchievements()
            boundCompanion.bind(core: emulatorCore, gameID: game?.identifier ?? "")
            self.restoreBoundFastForward()
        }
    }
    
    private var isGameScene: Bool {
        let gameScene = self.view.window?.windowScene as? GameScene
        return gameScene != nil
    }
    
    //MARK: - Private Properties -
    private var pauseViewController: PauseViewController?
    private var pausingGameController: GameController?
    
    // Prevents the same save state from being saved multiple times
    private var pausedSaveState: PausedSaveState? {
        didSet
        {
            if let saveState = oldValue, self.pausedSaveState == nil
            {
                do
                {
                    try FileManager.default.removeItem(at: saveState.fileURL)
                }
                catch
                {
                    print(error)
                }
            }
        }
    }
    
    private var _deepLinkResumingSaveState: SaveStateProtocol? {
        didSet {
            guard let saveState = oldValue, _deepLinkResumingSaveState == nil else { return }
            
            do
            {
                try FileManager.default.removeItem(at: saveState.fileURL)
            }
            catch
            {
                print(error)
            }
        }
    }
    
    private var _isLoadingSaveState = false
    
    // Online Multiplayer
    private var onlineConnectionDate: Date?
    private var onlineBackgroundTaskID: UIBackgroundTaskIdentifier?
    
    // Handoff
    private var isContinuingHandoff = false
    private var handoffPlaceholderView: RSTPlaceholderView!
    
    // Gestures
    private var isMenuButtonHeldDown = false

    private lazy var gameScreenRepositionGestureRecognizer: UILongPressGestureRecognizer = {
        let gestureRecognizer = UILongPressGestureRecognizer(target: self, action: #selector(GameViewController.handleGameScreenRepositionGesture(_:)))
        gestureRecognizer.delegate = self
        return gestureRecognizer
    }()
    private var repositionAnchor: CGPoint? // Location where the current drag began.
    private lazy var repositionFeedbackGenerator: UIImpactFeedbackGenerator = {
        if #available(iOS 17.5, *)
        {
            return UIImpactFeedbackGenerator(style: .light, view: self.view)
        }
        else
        {
            return UIImpactFeedbackGenerator(style: .light)
        }
    }()
        
    private var repositionResetButton: UIButton!
    private var repositionResetButtonTimer: Timer?
    
    private var shouldResetSustainedInputs = false

    private var isGyroActive = false
    private var presentedGyroAlert = false
    
    private var presentedJITAlert = false
    
    private var achievementsTracker: AchievementsTracker?
    private var isPreparingAchievements = false
    
    override var shouldAutorotate: Bool {
        return !self.isGyroActive
    }
    
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        guard self.isGyroActive else { return super.supportedInterfaceOrientations }
        
        // Lock orientation to whatever current device orientation is.
        
        switch UIDevice.current.orientation
        {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
            
        // UIDevice.landscapeLeft == UIInterfaceOrientation.landscapeRight (and vice versa)
        case .landscapeLeft: return .landscapeRight
        case .landscapeRight: return .landscapeLeft
            
        default: return super.supportedInterfaceOrientations
        }
    }
    
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge {
        return .all
    }
    
    override var prefersStatusBarHidden: Bool {
        return !ExperimentalFeatures.shared.showStatusBar.isEnabled
    }
    
    override var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent
    }
    
    required init()
    {
        super.init()
        
        self.initialize()
    }
    
    required init?(coder aDecoder: NSCoder)
    {
        super.init(coder: aDecoder)
        
        self.initialize()
    }
    
    private func initialize()
    {
        self.delegate = self
        
        NotificationCenter.default.addObserver(self, selector: #selector(GameViewController.updateControllers), name: .externalGameControllerDidConnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(GameViewController.updateControllers), name: .externalGameControllerDidDisconnect, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(GameViewController.boundControllerDisconnected(with:)), name: .externalGameControllerDidDisconnect, object: nil)
        
        NotificationCenter.default.addObserver(self, selector: #selector(GameViewController.didEnterBackground(with:)), name: UIApplication.didEnterBackgroundNotification, object: UIApplication.shared)
        
        NotificationCenter.default.addObserver(self, selector: #selector(GameViewController.settingsDidChange(with:)), name: Settings.didChangeNotification, object: nil)
        
        NotificationCenter.default.addObserver(self, selector: #selector(GameViewController.deepLinkControllerWillLaunchGame(with:)), name: .deepLinkControllerWillLaunchGame, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(GameViewController.deepLinkControllerLaunchGame(with:)), name: .deepLinkControllerLaunchGame, object: nil)
        
        NotificationCenter.default.addObserver(self, selector: #selector(GameViewController.didActivateGyro(with:)), name: GBA.didActivateGyroNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(GameViewController.didDeactivateGyro(with:)), name: GBA.didDeactivateGyroNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(GameViewController.didConnectOnline(with:)), name: MelonDS.didConnectToWFCNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(GameViewController.didDisconnectFromOnline(with:)), name: MelonDS.didDisconnectFromWFCNotification, object: nil)
        
        NotificationCenter.default.addObserver(self, selector: #selector(GameViewController.emulationDidQuit(with:)), name: EmulatorCore.emulationDidQuitNotification, object: nil)
        
        NotificationCenter.default.addObserver(self, selector: #selector(GameViewController.didEnableJIT(with:)), name: ServerManager.didEnableJITNotification, object: nil)
        
        NotificationCenter.default.addObserver(self, selector: #selector(GameViewController.sceneWillConnect(with:)), name: UIScene.willConnectNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(GameViewController.sceneDidDisconnect(with:)), name: UIScene.didDisconnectNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(GameViewController.sceneSessionWillQuit(with:)), name: UISceneSession.willQuitNotification, object: nil)
        
        NotificationCenter.default.addObserver(self, selector: #selector(GameViewController.sceneKeyboardFocusDidChange(with:)), name: UIScene.keyboardFocusDidChangeNotification, object: nil)
        
        self.automaticallyPausesWhileInactive = Settings.pauseWhileInactive
    }
    
    deinit
    {
        self.emulatorCore?.removeObserver(self, forKeyPath: #keyPath(EmulatorCore.state), context: &kvoContext)
    }
    
    // MARK: - GameControllerReceiver -
    override func gameController(_ gameController: GameController, didActivate input: Input, value: Double)
    {
        if StandardGameControllerInput(input: input) == .menu, value >= 0.33 {
            boundCompanion.sharing.nativeBattle.cancel()
        }
        super.gameController(gameController, didActivate: input, value: value)
        let worldInput = BoundFriendWorldInput(input: input)
        if BoundFriendWorldInputGate.isA(input) || worldInput == .interact || worldInput == .blockedA {
            if value < 0.33 { boundWorldAPressed.remove(gameController) }
            else if !boundWorldAPressed.contains(gameController) {
                boundWorldAPressed.add(gameController)
                if worldInput == .interact, self.view.window?.windowScene?.hasKeyboardFocus == true {
                    boundCompanion.sharing.interactions.open()
                }
            }
        }
        if worldInput != nil { return }
        if let action = ActionInput(input: input), action.isBoundPanelAction {
            self.receiveBoundPanelAction(action, from: gameController, pressed: value >= 0.5)
            return
        }
        
        // Ignore unless we're the active scene.
        guard self.view.window?.windowScene?.hasKeyboardFocus == true else { return }
        
        if let standardInput = StandardGameControllerInput(input: input), standardInput == .menu, gameController.inputType == .controllerSkin
        {
            // Menu only opens the pause menu; other buttons keep their normal mapping.
            self.isMenuButtonHeldDown = true
        }
        else if let actionInput = ActionInput(input: input), let emulatorCore = self.emulatorCore, emulatorCore.state == .running
        {
            switch actionInput
            {
            case .none, .systemOverlay: break
            case .quickSave: self.performQuickSaveAction()
            case .quickLoad: self.performQuickLoadAction()
            case .fastForward: self.performFastForwardAction(activate: true, remember: false)
            case .reverseScreens: self.performReverseScreensAction()
            case .screenshot: self.performScreenshotAction()
            case .cycleBoundPanels, .toggleBoundFriend, .toggleBoundMultiview,
                 .boundScrollUp, .boundScrollDown, .boundScrollLeft, .boundScrollRight,
                 .boundFocusUp, .boundFocusDown, .boundFocusLeft, .boundFocusRight,
                 .boundPreviousItem, .boundNextItem, .boundSelect, .boundBack, .boundDetails,
                 .boundPreviousView, .boundNextView, .boundHideFriend, .boundHideMultiview,
                 .boundShowDex, .boundShowBosses, .boundShowTypes: break // Handled independently above; never emulated inputs.
            case .toggleFastForward:
                let isFastForwarding = (emulatorCore.rate != emulatorCore.deltaCore.supportedRates.lowerBound)
                self.performFastForwardAction(activate: !isFastForwarding)
            }
        }
    }
    
    override func gameController(_ gameController: GameController, didDeactivate input: Input)
    {
        super.gameController(gameController, didDeactivate: input)
        let worldInput = BoundFriendWorldInput(input: input)
        if BoundFriendWorldInputGate.isA(input) || worldInput == .interact || worldInput == .blockedA {
            boundWorldAPressed.remove(gameController)
        }
        if worldInput != nil { return }
        if let action = ActionInput(input: input), action.isBoundPanelAction {
            self.receiveBoundPanelAction(action, from: gameController, pressed: false)
            return
        }
        
        // Ignore unless we're the active scene.
        guard self.view.window?.windowScene?.hasKeyboardFocus == true else { return }
        
        if let standardInput = StandardGameControllerInput(input: input), standardInput == .menu, gameController.inputType == .controllerSkin
        {
            self.isMenuButtonHeldDown = false
        }
        else if let actionInput = ActionInput(input: input)
        {
            switch actionInput
            {
            case .none, .systemOverlay: break
            case .quickSave: break
            case .quickLoad: break
            case .fastForward: self.performFastForwardAction(activate: false, remember: false)
            case .toggleFastForward: break
            case .reverseScreens: break
            case .screenshot: break
            case .cycleBoundPanels, .toggleBoundFriend, .toggleBoundMultiview,
                 .boundScrollUp, .boundScrollDown, .boundScrollLeft, .boundScrollRight,
                 .boundFocusUp, .boundFocusDown, .boundFocusLeft, .boundFocusRight,
                 .boundPreviousItem, .boundNextItem, .boundSelect, .boundBack, .boundDetails,
                 .boundPreviousView, .boundNextView, .boundHideFriend, .boundHideMultiview,
                 .boundShowDex, .boundShowBosses, .boundShowTypes: break
            }
        }
    }
    private func receiveBoundPanelAction(_ action: ActionInput, from controller: GameController, pressed: Bool) {
        let expectedCore = emulatorCore
        let apply = { [weak self, weak controller] in
            guard let self, let controller else { return }
            if !pressed {
                self.boundPanelActions.release(controller: controller, action: action)
                self.boundMultiviewRepeater.end(controller: controller, action: action)
                return
            }
            let navigationIsAllowedWhilePaused = action.isMultiviewTabAction
                ? self.boundCompanion.allowsControllerTabCyclingWhilePaused
                : self.boundCompanion.allowsControllerNavigationWhilePaused
            let navigatingReference = (action.isViewNavigationAction || action.isMultiviewTabAction || action == .toggleBoundMultiview || action == .toggleBoundFriend)
                && navigationIsAllowedWhilePaused
            let eligible = self.emulatorCore === expectedCore
                && (expectedCore?.state == .running || (navigatingReference && expectedCore?.state == .paused))
                // Consume landscape companion bindings in portrait without
                // changing a panel or falling back to the button's game input.
                && (self.boundCompanion.isMacWorkspace || self.view.bounds.width > self.view.bounds.height)
                && controller.inputType != .controllerSkin && controller.playerIndex != nil
                && ExternalGameControllerManager.shared.connectedControllers.contains(where: { $0 === controller })
                && self.view.window?.windowScene?.hasKeyboardFocus == true
                && UIApplication.shared.applicationState == .active
                && (self.presentedViewController == nil || (navigatingReference && !(self.presentedViewController is PauseViewController)))
                && (!self.boundCompanion.isEditingNotes || navigatingReference)
                && !self.boundCompanion.state.showingFriends && !self.boundCompanion.state.showingSettings
                && self.boundCompanion.allowsControllerPanelAction(action, controllerType: controller.inputType)
            self.boundPanelActions.activate(controller: controller, action: action, eligible: eligible) {
                if action.isViewNavigationAction || action.isMultiviewTabAction { self.boundCompanion.navigateControllerView(action) }
                else if action == .cycleBoundPanels { self.boundCompanion.cyclePanels() }
                else { self.boundCompanion.toggleControllerPanel(action) }
                if self.boundMultiviewCapturing,
                   action.isAutomaticFocusAction || [.boundScrollUp, .boundScrollDown, .boundScrollLeft, .boundScrollRight].contains(action) {
                    self.boundMultiviewRepeater.begin(controller: controller, action: action) { [weak self, weak controller] in
                        guard let self, let controller, self.boundMultiviewCapturing,
                              self.boundCompanion.automaticControllerMultiviewAvailable,
                              self.emulatorCore === expectedCore,
                              expectedCore?.state == .running || (expectedCore?.state == .paused && self.boundCompanion.allowsControllerNavigationWhilePaused),
                              self.presentedViewController == nil || self.boundCompanion.allowsControllerNavigationWhilePaused,
                              controller.playerIndex != nil,
                              self.view.window?.windowScene?.hasKeyboardFocus == true,
                              UIApplication.shared.applicationState == .active else { return false }
                        self.boundCompanion.navigateControllerView(action)
                        return true
                    }
                }
            }
        }
        if Thread.isMainThread { apply() } else { DispatchQueue.main.async(execute: apply) }
    }
    @objc private func boundControllerDisconnected(with notification: Notification) {
        guard let controller = notification.object as? GameController else { return }
        let release = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.boundPanelActions.release(controller: controller)
            self.boundMultiviewRepeater.end(controller: controller)
            self.boundCompanion.resetMacControllerFocus()
        }
        if Thread.isMainThread { release() } else { DispatchQueue.main.async(execute: release) }
    }
}


//MARK: - UIViewController -
/// UIViewController
extension GameViewController
{
    override func viewDidLoad()
    {
        super.viewDidLoad()

        self.registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitAccessibilityContrast.self]) { (self: GameViewController, _) in
            self.view.setNeedsLayout()
        }
        boundCompanion.install(in: self)
        
        self.view.layoutIfNeeded()
        
        self.controllerView.translucentControllerSkinOpacity = Settings.translucentControllerSkinOpacity
        
        // Handoff
        self.handoffPlaceholderView = RSTPlaceholderView(frame: CGRect(x: 0, y: 0, width: self.view.bounds.width, height: self.view.bounds.height))
        self.handoffPlaceholderView.translatesAutoresizingMaskIntoConstraints = false
        self.handoffPlaceholderView.isHidden = true
        self.handoffPlaceholderView.textLabel.isHidden = true
        self.handoffPlaceholderView.detailTextLabel.font = UIFont.preferredFont(forTextStyle: .body)
        self.handoffPlaceholderView.detailTextLabel.text = NSLocalizedString("Resuming…", comment: "")
        self.handoffPlaceholderView.detailTextLabel.numberOfLines = 1
        self.handoffPlaceholderView.detailTextLabel.minimumScaleFactor = 0.5
        self.handoffPlaceholderView.detailTextLabel.adjustsFontSizeToFitWidth = true
        self.handoffPlaceholderView.activityIndicatorView.isHidden = false
        self.handoffPlaceholderView.activityIndicatorView.startAnimating()
        self.handoffPlaceholderView.activityIndicatorView.color = .white
        self.view.insertSubview(self.handoffPlaceholderView, aboveSubview: self.gameView)
        
        // Reset Game Screen Position Button
        var repositionResetButtonConfiguration: UIButton.Configuration
        if #available(iOS 26, *)
        {
            repositionResetButtonConfiguration = .clearGlass()
        }
        else
        {
            repositionResetButtonConfiguration = .plain()
            repositionResetButtonConfiguration.cornerStyle = .capsule
            repositionResetButtonConfiguration.background.visualEffect = UIBlurEffect(style: .systemUltraThinMaterial)
        }
        repositionResetButtonConfiguration.baseForegroundColor = .red
        repositionResetButtonConfiguration.title = NSLocalizedString("Reset", comment: "")
        repositionResetButtonConfiguration.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 18, bottom: 12, trailing: 18)

        self.repositionResetButton = UIButton(configuration: repositionResetButtonConfiguration, primaryAction: UIAction { [weak self] _ in
            self?.resetGameScreenPosition()
        })
        self.repositionResetButton.translatesAutoresizingMaskIntoConstraints = false
        self.repositionResetButton.alpha = 0.0
        self.repositionResetButton.isHidden = true
        self.view.addSubview(self.repositionResetButton)

        self.view.addGestureRecognizer(self.gameScreenRepositionGestureRecognizer)

        // Auto Layout
        NSLayoutConstraint.activate([
            self.repositionResetButton.topAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.topAnchor, constant: 8),
            self.repositionResetButton.trailingAnchor.constraint(equalTo: self.view.safeAreaLayoutGuide.trailingAnchor, constant: -16),

            self.handoffPlaceholderView.leadingAnchor.constraint(equalTo: self.gameView.leadingAnchor),
            self.handoffPlaceholderView.trailingAnchor.constraint(equalTo: self.gameView.trailingAnchor),
            self.handoffPlaceholderView.topAnchor.constraint(equalTo: self.gameView.topAnchor),
            self.handoffPlaceholderView.bottomAnchor.constraint(equalTo: self.gameView.bottomAnchor),
        ])
        
        self.updateControllers()
    }
    
    override func viewDidAppear(_ animated: Bool)
    {
        super.viewDidAppear(animated)
        boundCompanion.playerStateDisplay.bind(core: emulatorCore)
        
        if self.emulatorCore?.deltaCore == MelonDS.core, ProcessInfo.processInfo.isJITAvailable
        {
            self.showJITEnabledAlert()
        }
        
        self.startGameActivity()
        
        if let scene = UIApplication.shared.externalDisplayScene, Settings.supportsExternalDisplays
        {
            // We have priority, so replace whatever is currently on external display.
            self.connectExternalDisplay(for: scene)
        }
    }
    
    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator)
    {
        boundCompanion.cancelInteractions()
        if BoundControllerModePreferences().isEnabled && BoundAppearancePreferences().effectiveScreenLayout == .bound {
            cancelBoundTouchInputsPreservingExternalHolds()
        }
        super.viewWillTransition(to: size, with: coordinator)
        
        guard UIApplication.shared.applicationState != .background else { return }
                
        coordinator.animate(alongsideTransition: { (context) in
            self.updateControllerSkin()
        }, completion: nil)        
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || isMovingFromParent || navigationController?.isBeingDismissed == true {
            boundCompanion.stop()
        }
    }

    override func viewDidLayoutSubviews()
    {
        gameplayLayoutBounds = boundCompanion.layout(in: view.bounds, safeArea: view.safeAreaInsets, controllerSize: nativeBoundControllerSize())
        applyBoundControlPlacement()
        super.viewDidLayoutSubviews()
        if controllerLayoutBounds != nil { view.bringSubviewToFront(controllerView) }
        // Native layout can change the controller bounds after rotation or Reset.
        // Refresh companion/Menu geometry only after those real frames settle.
        boundCompanion.bringControlsToFront()
        pauseViewController?.showsArrangeViews = boundCompanion.canArrangeLandscapeViews
        gameView.accessibilityIdentifier = "bound.game-screen"
        gameView.isAccessibilityElement = true
        gameView.accessibilityLabel = "Your gameplay screen"
    }
    
    // MARK: - Segues
    /// KVO
    
    override func prepare(for segue: UIStoryboardSegue, sender: Any?)
    {
        guard let identifier = segue.identifier else { return }
        
        self.pauseGameActivity()
        
        switch identifier
        {
        case "showGamesViewController":
            boundCompanion.stop()
            let gamesViewController = (segue.destination as! UINavigationController).topViewController as! GamesViewController
            
            if let emulatorCore = self.emulatorCore
            {
                gamesViewController.theme = .translucent
                gamesViewController.activeEmulatorCore = emulatorCore
                
                self.updateAutoSaveState()
            }
            else
            {
                gamesViewController.theme = .opaque
            }
            
        case "pause":
            
            if let game = self.game
            {
                let fileURL = FileManager.default.uniqueTemporaryURL()
                self.pausedSaveState = PausedSaveState(fileURL: fileURL, gameType: game.type)
                
                self.emulatorCore?.saveSaveState(to: fileURL)
            }

            guard let gameController = sender as? GameController else {
                fatalError("sender for pauseSegue must be the game controller that pressed the Menu button")
            }
            
            self.pausingGameController = gameController
            
            let pauseViewController = segue.destination as! PauseViewController
            pauseViewController.pauseText = (self.game as? Game)?.name ?? NSLocalizedString("Delta", comment: "")
            pauseViewController.emulatorCore = self.emulatorCore
            pauseViewController.saveStatesViewControllerDelegate = self
            pauseViewController.cheatsViewControllerDelegate = self
            pauseViewController.closeButtonTitle = self.isGameScene ? NSLocalizedString("Close", comment: "") : NSLocalizedString("Main Menu", comment: "")
            
            if let traits = self.controllerView.controllerSkinTraits, let menuInsets = self.controllerView.controllerSkin?.menuInsets(for: traits)
            {
                pauseViewController.menuInsets = menuInsets
            }
                        
            pauseViewController.fastForwardItem?.isSelected = (self.emulatorCore?.rate != self.emulatorCore?.deltaCore.supportedRates.lowerBound)
            pauseViewController.fastForwardItem?.action = { [unowned self] item in
                self.performFastForwardAction(activate: item.isSelected)
            }
            pauseViewController.friendsItem = MenuItem(text: boundCompanion.account.session == nil ? "Connect" : "Friends", image: UIImage(systemName: "person.2.fill")) { [weak self, weak pauseViewController] item in
                item.isSelected = false
                guard let self, let presenter = pauseViewController else { return }
                self.boundCompanion.presentFriends(from: presenter)
            }
            pauseViewController.screenshotItem = MenuItem(text: "Settings", image: UIImage(systemName: "gearshape.fill")) { [weak self, weak pauseViewController] item in
                item.isSelected = false
                guard let self, let presenter = pauseViewController else { return }
                self.boundCompanion.presentSettings(from: presenter)
            }
            pauseViewController.arrangeViewsItem = MenuItem(text: "Arrange Views", image: UIImage(systemName: "arrow.up.and.down.and.arrow.left.and.right")?.withRenderingMode(.alwaysTemplate)) { [weak self, weak pauseViewController] item in
                item.isSelected = false
                guard let self else { return }
                guard self.view.bounds.width > self.view.bounds.height else {
                    let alert = UIAlertController(title: nil, message: "Rotate your phone", preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default))
                    pauseViewController?.present(alert, animated: true)
                    return
                }
                self.boundCompanion.beginLandscapeArrangementFromMenu()
            }
            pauseViewController.arrangeViewsItem?.accessibilityIdentifier = "bound.menu-arrange-views"
            pauseViewController.showsArrangeViews = boundCompanion.canArrangeLandscapeViews
            pauseViewController.controllerModeItem?.isSelected = BoundControllerModePreferences().isEnabled
            pauseViewController.controllerModeItem?.action = { [weak self] item in
                guard let self else { return }
                self.cancelBoundTouchInputsPreservingExternalHolds()
                let preferences = BoundControllerModePreferences()
                preferences.cycle()
                self.view.setNeedsLayout()
                self.view.layoutIfNeeded()
                item.text = preferences.displayName
                item.isSelected = preferences.isEnabled
            }
            if self.emulatorCore?.deltaCore.supportedRates.upperBound == 1
            {
                pauseViewController.fastForwardItem = nil
            }
            
            if let emulatorCore, emulatorCore.isWirelessMultiplayerActive
            {
                pauseViewController.saveStateItem = nil
                pauseViewController.loadStateItem = nil
                pauseViewController.cheatCodesItem = nil
                pauseViewController.fastForwardItem = nil
            }
            
            if let game = self.game as? Game, AchievementsManager.shared.isAuthenticated,
               game.settings[.retroAchievementsEnabled] as? Bool ?? true, Settings.features.retroAchievements.isHardcoreModeEnabled
            {
                // Saving save states is fine, just not loading them
                // pauseViewController.saveStateItem = nil
                
                pauseViewController.loadStateItem = nil
                pauseViewController.cheatCodesItem = nil
            }
            
            if !boundPermitsIndependentStateLoad { pauseViewController.loadStateItem = nil }
            self.pauseViewController = pauseViewController
            
        default: break
        }
    }
    
    @IBAction private func unwindFromPauseViewController(_ segue: UIStoryboardSegue)
    {
        self.pauseViewController = nil
        self.pausingGameController = nil
        
        guard let identifier = segue.identifier else { return }
        
        switch identifier
        {
        case "unwindFromPauseMenu":
            
            self.pausedSaveState = nil
            
            DispatchQueue.main.async {
                
                if self._isLoadingSaveState
                {
                    // If loading save state, resume emulation immediately (since the game view needs to be updated ASAP)
                    
                    if self.resumeEmulation()
                    {
                        // Temporarily disable audioManager to prevent delayed audio bug when using 3D Touch Peek & Pop
                        self.emulatorCore?.audioManager.isEnabled = false
                        
                        // Re-enable after delay
                        
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            self.emulatorCore?.audioManager.isEnabled = true
                        }
                    }
                }
                else
                {
                    // Otherwise, wait for the transition to complete before resuming emulation
                    self.transitionCoordinator?.animate(alongsideTransition: nil, completion: { (context) in
                        self.resumeEmulation()
                    })
                }
                
                self._isLoadingSaveState = false
                
                if self.emulatorCore?.deltaCore == MelonDS.core, ProcessInfo.processInfo.isJITAvailable
                {
                    self.transitionCoordinator?.animate(alongsideTransition: nil, completion: { (context) in
                        self.showJITEnabledAlert()
                    })
                }
            }
            
            self.startGameActivity()
            
        case "unwindToGames":
            if self.isGameScene
            {
                guard let session = self.view.window?.windowScene?.session else { return }
                UIApplication.shared.requestSceneSessionDestruction(session, options: nil) { error in
                    Logger.main.error("Failed to close game window. \(error.localizedDescription, privacy: .public)")
                }
                
                // Ensure emulation stops when explicitly quit.
                self.emulatorCore?.stop()
            }
            else
            {
                DispatchQueue.main.async {
                    self.transitionCoordinator?.animate(alongsideTransition: nil, completion: { (context) in
                        self.performSegue(withIdentifier: "showGamesViewController", sender: nil)
                    })
                }
            }
                        
        default: break
        }
    }
    
    @IBAction private func unwindFromGamesViewController(with segue: UIStoryboardSegue)
    {
        self.pausedSaveState = nil
        
        if let emulatorCore = self.emulatorCore, emulatorCore.state == .paused
        {
            emulatorCore.resume()
        }
    }
    
    // MARK: - KVO
    /// KVO
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?)
    {
        guard context == &kvoContext else { return super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context) }
        
        guard let rawValue = change?[.oldKey] as? Int, let previousState = EmulatorCore.State(rawValue: rawValue) else { return }
        
        if !boundPermitsIndependentStateLoad { _deepLinkResumingSaveState = nil }
        if let saveState = _deepLinkResumingSaveState, let emulatorCore = self.emulatorCore, emulatorCore.state == .running
        {
            emulatorCore.pause()
            
            do
            {
                try emulatorCore.load(saveState)
                self.boundRRDexDidLoadSaveState(core: emulatorCore)
            }
            catch
            {
                print(error)
            }
            
            _deepLinkResumingSaveState = nil
            emulatorCore.resume()
        }
        
        if previousState == .stopped
        {
            self.emulatorCore?.updateCheats()
        }
        
        if self.emulatorCore?.state == .running
        {
            DatabaseManager.shared.performBackgroundTask { (context) in
                guard let game = self.game as? Game else { return }
                
                let backgroundGame = context.object(with: game.objectID) as! Game
                backgroundGame.playedDate = Date()
                
                context.saveWithErrorLogging()
            }
        }
    }
}

//MARK: - Emulation -
private extension GameViewController
{
    func quitEmulation()
    {
        boundCompanion.sharing.nativeBattle.cancel(resume: false)
        if let presentedViewController = self.presentedViewController
        {
            presentedViewController.dismiss(animated: true) {
                self.quitEmulation()
            }
            
            return
        }
        
        self.updateAutoSaveState()
        
        self.emulatorCore?.stop()
        self.game = nil
        
        // Make sure split view controller doesn't accidentally re-appear.
        self.controllerView.resignFirstResponder()
        
        if self.isGameScene
        {
            guard let session = self.view.window?.windowScene?.session else { return }
            UIApplication.shared.requestSceneSessionDestruction(session, options: nil) { error in
                Logger.main.error("Failed to close game window. \(error.localizedDescription, privacy: .public)")
            }
        }
        else
        {
            self.performSegue(withIdentifier: "showGamesViewController", sender: nil)
        }
        
        self.stopGameActivity()
    }
}

//MARK: - Controllers -
private extension GameViewController
{
    private func installBoundInputMapping(_ mapping: BoundControllerInputMapping,
                                         controller: GameController, core: EmulatorCore) {
        let mapping = boundCompanion.isMacWorkspace ? BoundMacControllerActionRouting.inputMapping(mapping) : mapping
        let old = controller.inputMapping(for: self)
        let held = controller.activatedInputs
        // Release the OLD mapped game input before swapping. Otherwise holding
        // a direction while opening Multiview can leave the emulator latched.
        for (physical, _) in held {
            guard let previous = old?.input(forControllerInput: physical),
                  AnyInput(previous) != mapping.input(forControllerInput: physical).map(AnyInput.init) else { continue }
            self.gameController(controller, didDeactivate: previous)
            core.gameController(controller, didDeactivate: previous)
        }
        controller.addReceiver(self, inputMapping: mapping)
        controller.addReceiver(core, inputMapping: mapping)
        for (physical, value) in held {
            guard let target = mapping.input(forControllerInput: physical),
                  ActionInput(input: target) == nil,
                  StandardGameControllerInput(input: target) != .menu,
                  old?.input(forControllerInput: physical).map(AnyInput.init) != AnyInput(target) else { continue }
            // Resume a held gameplay direction when control returns from Multiview.
            self.gameController(controller, didActivate: target, value: value)
            core.gameController(controller, didActivate: target, value: value)
        }
    }

    @objc func updateControllers()
    {
        let firstActiveController = ExternalGameControllerManager.shared.connectedControllers.first(where: { $0.playerIndex != nil })
        if firstActiveController == nil && Settings.localControllerPlayerIndex == nil
        {
            Settings.localControllerPlayerIndex = 0
        }
        else if let index = Settings.localControllerPlayerIndex, ExternalGameControllerManager.shared.connectedControllers.contains(where: { $0.playerIndex == index })
        {
            // There is an active controller with same player index as local controller, so disable local controller.
            Settings.localControllerPlayerIndex = nil
        }
        
        // Controller Mode retains a real on-screen Menu even when upstream
        // normally hides the virtual controller for an assigned external pad.
        let menuOnly = BoundControllerModePreferences.hidesTouchControls(enabled: BoundControllerModePreferences().isEnabled,
            layout: BoundAppearancePreferences().effectiveScreenLayout, landscape: view.bounds.width > view.bounds.height)
        let usesBoundController = !BoundMacWorkspacePlatform.isEnabled &&
            BoundAppearancePreferences().effectiveScreenLayout == .bound
        if menuOnly, let firstActiveController {
            let assignment = BoundControllerViewAssignment.resolve(
                localPlayerIndex: Settings.localControllerPlayerIndex,
                externalPlayerIndex: firstActiveController.playerIndex,
                menuOnly: true)
            self.controllerView.playerIndex = assignment.playerIndex
            self.controllerView.isHidden = false
        }
        else if usesBoundController {
            // Bound always keeps its touch controller available. The mode skin
            // filters it to Menu only in enabled landscape mode.
            let assignment = BoundControllerViewAssignment.resolve(
                localPlayerIndex: Settings.localControllerPlayerIndex,
                externalPlayerIndex: firstActiveController?.playerIndex,
                menuOnly: false)
            self.controllerView.playerIndex = assignment.playerIndex
            self.controllerView.isHidden = !assignment.isVisible
        }
        else if let index = Settings.localControllerPlayerIndex
        {
            self.controllerView.playerIndex = index
            self.controllerView.isHidden = false
        }
        else
        {
            if let game = self.game as? Game,
               let traits = self.controllerView.controllerSkinTraits,
               let firstActiveController,
               let _ = Settings.preferredControllerSkin(for: game, traits: traits, forExternalController: true)
            {
                self.controllerView.isHidden = false
                self.controllerView.playerIndex = firstActiveController.playerIndex // Give Controller View same playerIndex as first active connected controller if using external controller skin
            }
            else if let game = self.game,
                    let traits = self.controllerView.controllerSkinTraits,
                    let controllerSkin = DeltaCore.ControllerSkin.standardControllerSkin(for: game.type),
                    controllerSkin.hasTouchScreen(for: traits)
            {
                self.controllerView.isHidden = false
                self.controllerView.playerIndex = 0
            }
            else
            {
                self.controllerView.isHidden = true
                self.controllerView.playerIndex = nil
            }
        }
        
        self.view.setNeedsLayout()
        self.view.layoutIfNeeded()
        
        if BoundMacWorkspacePlatform.isEnabled {
            // Keep Delta's keyboard receiver and DS touchscreen available.
            self.controllerView.isHidden = false
            self.controllerView.playerIndex = Settings.localControllerPlayerIndex ?? firstActiveController?.playerIndex ?? 0
        }

        // Roundabout way of combining arrays to prevent rare runtime crash in + operator :(
        var controllers = [GameController]()
        controllers.append(self.controllerView)
        controllers.append(contentsOf: ExternalGameControllerManager.shared.connectedControllers)
        
        if let emulatorCore = self.emulatorCore, let game = self.game
        {
            for gameController in controllers
            {
                if gameController.playerIndex != nil
                {
                    let inputMapping: GameControllerInputMappingProtocol
                    let multiviewDefaults: DeltaCore.GameControllerInputMapping?
                    
                    if let mapping = GameControllerInputMapping.inputMapping(forPlayer: gameController.playerIndex, gameType: game.type, controllerType: gameController.inputType, in: DatabaseManager.shared.viewContext)
                    {
                        inputMapping = mapping
                        multiviewDefaults = nil
                    }
                    else
                    {
                        inputMapping = DefaultInputMapping(gameController: gameController, gameType: game.type)
                        multiviewDefaults = BoundControllerMultiviewPreferences().isEnabled
                            ? BoundMultiviewDefaultMapping.mapping(for: gameController, gameType: game.type) : nil
                    }
                    
                    if let controller = gameController as? MFiGameController {
                        BoundControllerSystemGestures.apply(to: controller, mapping: inputMapping)
                    }
                    let gameplayMapping = BoundControllerInputMapping(base: inputMapping,
                        multiviewActive: gameController.inputType != .controllerSkin && boundMultiviewCapturing,
                        multiviewDefaults: multiviewDefaults,
                        friendWorldGate: game.type == .gba ? boundCompanion.sharing.interactions.inputGate : nil)
                    installBoundInputMapping(gameplayMapping, controller: gameController, core: emulatorCore)
                }
                else
                {
                    gameController.removeReceiver(self)
                    gameController.removeReceiver(emulatorCore)
                }
            }
        }
        
        if self.shouldResetSustainedInputs
        {
            for controller in controllers
            {
                for input in controller.sustainedInputs.keys
                {
                    controller.unsustain(input)
                }
            }
            
            self.shouldResetSustainedInputs = false
        }
        
        self.controllerView.isButtonHapticFeedbackEnabled = Settings.isButtonHapticFeedbackEnabled
        self.controllerView.isThumbstickHapticFeedbackEnabled = Settings.isThumbstickHapticFeedbackEnabled
        
        self.updateControllerSkin()
    }
    
    func updateControllerSkin()
    {
        guard let game = self.game as? Game, let window = self.view.window else { return }

        if BoundMacWorkspacePlatform.isEnabled,
           let base = DeltaCore.ControllerSkin.standardControllerSkin(for: game.type) {
            if !(controllerView.controllerSkin is TouchControllerSkin) || controllerView.controllerSkin?.gameType != game.type {
                controllerView.cancelTouchInputs()
                controllerView.controllerSkin = TouchControllerSkin(controllerSkin: base)
            }
            controllerView.usesControlOnlyHitTesting = true
            gameScreenOffset = .zero
            updateExternalDisplay()
            view.setNeedsLayout()
            return
        }
        
        let traits = DeltaCore.ControllerSkin.Traits.defaults(for: window)
        let isExternalControllerConnected = ExternalGameControllerManager.shared.connectedControllers.contains(where: { $0.playerIndex != nil })

        if BoundAppearancePreferences().effectiveScreenLayout == .bound
        {
            // A wireless pad's optional external skin may have no on-screen
            // controls. Bound uses the regular touch skin in every mode and
            // lets BoundControllerModeSkin hide gameplay buttons only when
            // Controller Mode is enabled in landscape.
            if let controllerSkin = Settings.preferredControllerSkin(for: game, traits: traits, forExternalController: false) {
                self.controllerView.controllerSkin = controllerSkin
            } else {
                self.controllerView.controllerSkin = DeltaCore.ControllerSkin.standardControllerSkin(for: game.type)
            }
        }
        else if Settings.localControllerPlayerIndex != nil
        {
            // If there is both a local player and a connected controller with a controller skin, we prioritize local player's skin.
            // Even if the skin doesn't exist, we'll fall back to standard skin for local player.
            let controllerSkin = Settings.preferredControllerSkin(for: game, traits: traits, forExternalController: false) // Explicitly load non-external controller skin.
            self.controllerView.controllerSkin = controllerSkin
        }
        else if isExternalControllerConnected, let externalControllerSkin = Settings.preferredControllerSkin(for: game, traits: traits, forExternalController: true)
        {
            // No local player, but user has selected an external controller skin, so show that instead.
            self.controllerView.controllerSkin = externalControllerSkin
        }
        else if let controllerSkin = DeltaCore.ControllerSkin.standardControllerSkin(for: game.type), controllerSkin.hasTouchScreen(for: traits)
        {
            var touchControllerSkin = TouchControllerSkin(controllerSkin: controllerSkin)
            
            if UIApplication.shared.isExternalDisplayConnected
            {
                // Only show touch screen if external display is connected.
                touchControllerSkin.screenPredicate = { $0.isTouchScreen }
            }
            
            if self.view.bounds.width > self.view.bounds.height
            {
                touchControllerSkin.screenLayoutAxis = .horizontal
            }
            else
            {
                touchControllerSkin.screenLayoutAxis = .vertical
            }
            
            self.controllerView.controllerSkin = touchControllerSkin
        }
        else
        {
            // TODO: Add this back once we've adopted modern keyboard input handling.
            // Until then, setting controllerSkin to nil breaks our legacy keyboard handling.
            // self.controllerView.controllerSkin = nil
        }
        
        self.applyBoundControlPlacement()
        self.updateExternalDisplay()
        
        if let pauseViewController
        {
            if let traits = self.controllerView.controllerSkinTraits, let menuInsets = self.controllerView.controllerSkin?.menuInsets(for: traits)
            {
                pauseViewController.menuInsets = menuInsets
            }
            else
            {
                pauseViewController.menuInsets = .zero
            }
        }
        
        // Reapply the saved offset for the current orientation, or reset it when controls are present.
        if self.repositionAnchor == nil
        {
            let distance = self.canRepositionGameScreen ? UserDefaults.standard.gameScreenOffset(for: traits) : 0
            
            switch traits.orientation
            {
            case .portrait: self.gameScreenOffset = CGPoint(x: 0, y: distance)
            case .landscape: self.gameScreenOffset = CGPoint(x: distance, y: 0)
            }
        }

        self.view.setNeedsLayout()
    }
    
    func updateGameViews()
    {
        if self.isContinuingHandoff
        {
            // Continuing from Handoff which may take a while, so hide all views.
            for gameView in self.gameViews
            {
                gameView.isEnabled = false
                gameView.isHidden = true
            }
        }
        else if UIApplication.shared.isExternalDisplayConnected
        {
            // AirPlaying, hide all (non-touch) screens.
            
            if let traits = self.controllerView.controllerSkinTraits,
               let supportedTraits = self.controllerView.controllerSkin?.supportedTraits(for: traits),
               let screens = self.controllerView.controllerSkin?.screens(for: supportedTraits)
            {
                for (screen, gameView) in zip(screens, self.gameViews)
                {
                    gameView.isEnabled = screen.isTouchScreen
                    
                    if gameView == self.gameView && !(screen.isTouchScreen && Settings.features.dsAirPlay.topScreenOnly)
                    {
                        // Always show AirPlay indicator on self.gameView, unless it is a touch screen AND we're only AirPlaying top screen.
                        gameView.isAirPlaying = true
                        gameView.isHidden = false
                    }
                    else
                    {
                        gameView.isAirPlaying = false
                        gameView.isHidden = !screen.isTouchScreen
                    }
                }
            }
            else
            {
                // Either self.controllerView.controllerSkin is `nil`, or it doesn't support these traits.
                // Most likely this system only has 1 screen, so just hide self.gameView.
                
                self.gameView.isEnabled = false
                self.gameView.isHidden = false
                self.gameView.isAirPlaying = true
            }
        }
        else
        {
            // Not AirPlaying, show all screens.
            
            if let traits = self.controllerView.controllerSkinTraits,
               let supportedTraits = self.controllerView.controllerSkin?.supportedTraits(for: traits),
               let screens = self.controllerView.controllerSkin?.screens(for: supportedTraits),
               ExperimentalFeatures.shared.reverseScreens.isEnabled
            {
                for (screen, gameView) in zip(screens, self.gameViews)
                {
                    gameView.isAirPlaying = false
                    
                    if let outputFrame = screen.outputFrame, outputFrame.isEmpty
                    {
                        // Frame is empty, so always disable it,
                        gameView.isEnabled = false
                        gameView.isHidden = true
                    }
                    else
                    {
                        gameView.isEnabled = true
                        gameView.isHidden = false
                    }
                }
            }
            else
            {
                for gameView in self.gameViews
                {
                    gameView.isEnabled = true
                    gameView.isHidden = false
                    gameView.isAirPlaying = false
                }
            }
        }
    }
}

extension GameViewController {
    /// Package metadata can change after the cartridge battery was already
    /// uploaded. A completed paired checkpoint is independently sync-worthy.
    func boundDidCompleteMultiplayerCheckpoint() {
        guard let game = game as? Game else { return }
        let id = game.objectID
        DatabaseManager.shared.performBackgroundTask { context in
            guard let game = try? context.existingObject(with: id) as? Game,
                  let save = game.gameSave else { return }
            save.modifiedDate = Date()
            try? context.save()
        }
    }
}

//MARK: - Game Saves -
/// Game Saves
private extension GameViewController
{
    func updateGameSave()
    {
        guard let game = self.game as? Game else { return }
        
        DatabaseManager.shared.performBackgroundTask { (context) in
            do
            {
                let game = context.object(with: game.objectID) as! Game
                
                let hash = try RSTHasher.sha1HashOfFile(at: game.gameSaveURL)
                let previousHash = game.gameSave?.sha1
                
                guard hash != previousHash else { return }
                
                if let gameSave = game.gameSave
                {
                    gameSave.modifiedDate = Date()
                    gameSave.sha1 = hash
                }
                else
                {
                    let gameSave = GameSave(context: context)
                    gameSave.identifier = game.identifier
                    gameSave.sha1 = hash
                    
                    game.gameSave = gameSave
                }
                
                try context.save()
                
                if ExperimentalFeatures.shared.toastNotifications.gameSaveEnabled
                {
                    self.presentExperimentalToastView(NSLocalizedString("Game Data Saved", comment: ""))
                }
            }
            catch CocoaError.fileNoSuchFile
            {
                // Ignore
            }
            catch
            {
                print("Error updating game save.", error)
            }
        }
    }
}

//MARK: - Save States -
/// Save States
extension GameViewController: SaveStatesViewControllerDelegate
{
    private func updateAutoSaveState()
    {
        guard !boundCompanion.sharing.nativeBattle.blocksAutoSave else { return }
        // Ensures game is non-nil and also a Game subclass
        guard let game = self.game as? Game else { return }
        
        guard let emulatorCore = self.emulatorCore, emulatorCore.state != .stopped, !emulatorCore.isWirelessMultiplayerActive else { return }
        
        // If pausedSaveState exists and has already been saved, don't update auto save state
        // This prevents us from filling our auto save state slots with the same save state
        let savedPausedSaveState = self.pausedSaveState?.isSaved ?? false
        guard !savedPausedSaveState else { return }
        
        self.pausedSaveState?.isSaved = true
        
        // Must be done synchronously
        let backgroundContext = DatabaseManager.shared.newBackgroundContext()
        backgroundContext.performAndWait {
            
            let game = backgroundContext.object(with: game.objectID) as! Game
            
            let fetchRequest = SaveState.fetchRequest(for: game, type: .auto)
            fetchRequest.sortDescriptors = [NSSortDescriptor(key: #keyPath(SaveState.creationDate), ascending: true)]
            
            do
            {
                let saveStates = try fetchRequest.execute()
                
                if let saveState = saveStates.first, saveStates.count >= 2
                {
                    // If there are two or more auto save states, update the oldest one
                    self.update(saveState, with: self.pausedSaveState)
                    
                    // Tiny hack: SaveStatesViewController sorts save states by creation date, so we update the creation date too
                    // Simpler than deleting old save states ¯\_(ツ)_/¯
                    saveState.creationDate = saveState.modifiedDate
                }
                else
                {
                    // Otherwise, create a new one
                    let saveState = SaveState.insertIntoManagedObjectContext(backgroundContext)
                    saveState.type = .auto
                    saveState.game = game
                    
                    self.update(saveState, with: self.pausedSaveState)
                }
            }
            catch
            {
                print(error)
            }

            backgroundContext.saveWithErrorLogging()
        }
    }
    
    private func update(_ saveState: SaveState, with replacementSaveState: SaveStateProtocol? = nil)
    {
        let isRunning = (self.emulatorCore?.state == .running)
        
        if isRunning
        {
            self.pauseEmulation()
        }
        
        if let replacementSaveState = replacementSaveState
        {
            do
            {
                if FileManager.default.fileExists(atPath: saveState.fileURL.path)
                {
                    // Don't use replaceItem(), since that removes the original file as well
                    try FileManager.default.removeItem(at: saveState.fileURL)
                }
                
                try FileManager.default.copyItem(at: replacementSaveState.fileURL, to: saveState.fileURL)
            }
            catch
            {
                print(error)
            }
        }
        else
        {
            self.emulatorCore?.saveSaveState(to: saveState.fileURL)
        }
        
        if let snapshot = self.emulatorCore?.videoManager.snapshot(), let data = snapshot.pngData()
        {
            do
            {
                try data.write(to: saveState.imageFileURL, options: [.atomicWrite])
            }
            catch
            {
                print(error)
            }
        }
        
        saveState.modifiedDate = Date()
        saveState.coreIdentifier = self.emulatorCore?.deltaCore.identifier
        saveState.coreVersion = self.emulatorCore?.deltaCore.version
        
        if ExperimentalFeatures.shared.toastNotifications.stateSaveEnabled,
           saveState.type != .auto
        {
            self.presentExperimentalToastView(NSLocalizedString("Saved Save State", comment: ""))
        }
        
        if isRunning
        {
            self.resumeEmulation()
        }
    }
    
    private var boundPermitsIndependentStateLoad: Bool {
        guard boundCompanion.sharing.soulLink.permitsIndependentStateLoading else { return false }
        guard let id = (game as? Game)?.identifier else { return true }
        return !BoundSoulSession.hasProtectedRun(gameID: id) && !BoundMultiplayerSaveStore.shared.hasRun(gameID: id)
    }

    @discardableResult private func load(_ saveState: SaveStateProtocol) -> Bool
    {
        guard boundPermitsIndependentStateLoad else { return false }
        boundCompanion.sharing.nativeBattle.cancel()
        guard !boundCompanion.sharing.nativeBattle.blocksAutoSave else { return false }
        let isRunning = (self.emulatorCore?.state == .running)
        
        if isRunning
        {
            self.pauseEmulation()
        }
        
        // If we're loading the auto save state, we need to create a temporary copy of saveState.
        // Then, we update the auto save state, but load our copy so everything works out.
        var temporarySaveState: SaveStateProtocol? = nil
        
        if let autoSaveState = saveState as? SaveState, autoSaveState.type == .auto
        {
            let temporaryURL = FileManager.default.uniqueTemporaryURL()
            
            do
            {
                try FileManager.default.moveItem(at: saveState.fileURL, to: temporaryURL)
                temporarySaveState = DeltaCore.SaveState(fileURL: temporaryURL, gameType: saveState.gameType)
            }
            catch
            {
                print(error)
            }
        }
        
        self.updateAutoSaveState()
        
        var didLoad = false
        do
        {
            if let temporarySaveState = temporarySaveState
            {
                if let core = self.emulatorCore {
                    try core.load(temporarySaveState)
                    self.boundRRDexDidLoadSaveState(core: core)
                }
                try FileManager.default.removeItem(at: temporarySaveState.fileURL)
            }
            else
            {
                if let core = self.emulatorCore {
                    try core.load(saveState)
                    self.boundRRDexDidLoadSaveState(core: core)
                }
            }

            didLoad = true
            
            if ExperimentalFeatures.shared.toastNotifications.stateLoadEnabled
            {
                self.presentExperimentalToastView(NSLocalizedString("Loaded Save State", comment: ""))
            }
        }
        catch EmulatorCore.SaveStateError.doesNotExist
        {
            print("Save State does not exist.")
        }
        catch let error as NSError
        {
            print(error)
        }
        
        self.achievementsTracker?.reset()
        
        if isRunning
        {
            self.resumeEmulation()
        }

        return didLoad
    }
    
    //MARK: - SaveStatesViewControllerDelegate
    
    func saveStatesViewController(_ saveStatesViewController: SaveStatesViewController, updateSaveState saveState: SaveState)
    {
        let updatingExistingSaveState = FileManager.default.fileExists(atPath: saveState.fileURL.path)
        
        self.update(saveState)
        
        // Dismiss if updating an existing save state.
        // If creating a new one, don't dismiss.
        if updatingExistingSaveState
        {
            self.pauseViewController?.dismiss()
        }
    }
    
    func saveStatesViewController(_ saveStatesViewController: SaveStatesViewController, loadSaveState saveState: SaveStateProtocol)
    {
        self._isLoadingSaveState = true
        
        self.load(saveState)
        
        self.pauseViewController?.dismiss()
    }
}

//MARK: - Cheats -
/// Cheats
extension GameViewController: CheatsViewControllerDelegate
{
    func cheatsViewController(_ cheatsViewController: CheatsViewController, activateCheat cheat: Cheat)
    {
        self.emulatorCore?.activateCheatWithErrorLogging(cheat)
    }
    
    func cheatsViewController(_ cheatsViewController: CheatsViewController, deactivateCheat cheat: Cheat)
    {
        self.emulatorCore?.deactivate(cheat)
    }
}

//MARK: - Audio -
/// Audio
private extension GameViewController
{
    func updateAudio()
    {
        self.emulatorCore?.audioManager.respectsSilentMode = Settings.respectSilentMode
        self.emulatorCore?.audioManager.mixesWithOtherAudio = Settings.mixWithOtherAudio
        self.emulatorCore?.audioManager.pausesOtherAudio = Settings.pauseOtherAudio
    }
}

//MARK: - Action Inputs -
/// Action Inputs
extension GameViewController
{
    @objc func performQuickSaveAction()
    {
        guard !boundCompanion.sharing.nativeBattle.blocksAutoSave else { return }
        guard let game = self.game as? Game, let emulatorCore, !emulatorCore.isWirelessMultiplayerActive else { return }
        
        let backgroundContext = DatabaseManager.shared.newBackgroundContext()
        backgroundContext.performAndWait {
            
            let game = backgroundContext.object(with: game.objectID) as! Game
            let fetchRequest = SaveState.fetchRequest(for: game, type: .quick)
            
            do
            {
                if let quickSaveState = try fetchRequest.execute().first
                {
                    self.update(quickSaveState)
                }
                else
                {
                    let saveState = SaveState(context: backgroundContext)
                    saveState.type = .quick
                    saveState.game = game
                    
                    self.update(saveState)
                }
            }
            catch
            {
                print(error)
            }
            
            backgroundContext.saveWithErrorLogging()
        }
    }
    
    @objc func performQuickLoadAction()
    {
        guard !AchievementsManager.shared.isAuthenticated || !Settings.features.retroAchievements.isHardcoreModeEnabled else {
            // Disable loading save states when using RetroAchievements and Hardcore Mode
            return
        }
        
        guard let game = self.game as? Game, let emulatorCore, !emulatorCore.isWirelessMultiplayerActive else { return }
        
        let fetchRequest = SaveState.fetchRequest(for: game, type: .quick)
        
        do
        {
            if let quickSaveState = try DatabaseManager.shared.viewContext.fetch(fetchRequest).first
            {
                self.load(quickSaveState)
            }
        }
        catch
        {
            print(error)
        }
    }
    
    private var boundFastForwardGameID: String? {
        guard let game = self.game else { return nil }
        // Library ROM filenames and identifiers are stable across sandbox moves.
        return (game as? Game)?.identifier ?? game.fileURL.lastPathComponent
    }

    private func restoreBoundFastForward() {
        guard let gameID = boundFastForwardGameID else { return }
        performFastForwardAction(activate: boundFastForwardPreferences.isEnabled(for: gameID), remember: false, showToast: false)
    }

    func performFastForwardAction(activate: Bool, remember: Bool = true, showToast: Bool = true)
    {
        guard !boundCompanion.sharing.nativeBattle.isActive else { return }
        guard let emulatorCore = self.emulatorCore, !emulatorCore.isWirelessMultiplayerActive else { return }

        if remember {
            if let gameID = boundFastForwardGameID {
                boundFastForwardPreferences.setEnabled(activate, for: gameID)
            }
        }
        
        if activate
        {
            // Use Delta's default for this core (3x for GBA), regardless of
            // legacy per-game, per-system, or unrestricted-speed preferences.
            emulatorCore.rate = emulatorCore.deltaCore.supportedRates.upperBound

            if showToast && ExperimentalFeatures.shared.toastNotifications.fastForwardEnabled
            {
                self.presentExperimentalToastView(NSLocalizedString("Fast Forward Enabled", comment: ""))
            }
        }
        else
        {
            emulatorCore.rate = emulatorCore.deltaCore.supportedRates.lowerBound

            if showToast && ExperimentalFeatures.shared.toastNotifications.fastForwardEnabled
            {
                self.presentExperimentalToastView(NSLocalizedString("Fast Forward Disabled", comment: ""))
            }
        }
    }
    
    func performScreenshotAction()
    {
        guard let emulatorCore, let snapshot = emulatorCore.videoManager.snapshot() else { return }
        
        let minEdge = min(emulatorCore.videoManager.videoFormat.dimensions.width, emulatorCore.videoManager.videoFormat.dimensions.height)
        
        let imageScale: Double
        if minEdge >= 1080
        {
            // Screenshot is already at or above 1080p, so no need to scale it.
            imageScale = 1
        }
        else
        {
            // Determine integer scaling to ensure we reach 1080p.
            imageScale = (1080.0 / minEdge).rounded(.up)
        }
        
        let imageSize = CGSize(width: snapshot.size.width * imageScale, height: snapshot.size.height * imageScale)
        
        let screenshotData: Data
        if imageScale == 1, let data = snapshot.pngData()
        {
            // No need to redraw image because it's already the correct size.
            screenshotData = data
        }
        else
        {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            
            let renderer = UIGraphicsImageRenderer(size: imageSize, format: format)
            screenshotData = renderer.pngData { (context) in
                context.cgContext.interpolationQuality = .none
                snapshot.draw(in: CGRect(origin: .zero, size: imageSize))
            }
        }
        
        Task<Void, Never>(priority: .userInitiated) {
            do
            {
                try await PHPhotoLibrary.requestAuthorizationIfNeeded()
                try await PHPhotoLibrary.shared().saveScreenshotData(screenshotData)
                
                let toastView = RSTToastView(text: NSLocalizedString("Saved screenshot to Photos", comment: ""), detailText: nil)
                self.show(toastView)
            }
            catch
            {
                let toastView = RSTToastView(text: NSLocalizedString("Unable to Save Screenshot", comment: ""), detailText: error.localizedDescription)
                self.show(toastView)
            }
            
            self.pauseViewController?.screenshotItem?.isSelected = false
        }
    }
    
    func performReverseScreensAction()
    {
        guard let controllerSkin = self.controllerView.controllerSkin as? ControllerSkin else { return }
        controllerSkin.isReversingScreens.toggle()
        
        self.updateControllerSkin()
    }
}

private extension GameViewController
{
    func connectExternalDisplay(for scene: ExternalDisplayScene)
    {
        // hasKeyboardFocus is false when enabling AirPlay via Control Center, so can't rely on that.
        // guard let windowScene = self.view.window?.windowScene, windowScene.hasKeyboardFocus else { return }
        
        // We need to receive gameViewController(_:didUpdateGameViews:) callback.
        scene.gameViewController.delegate = self
                
        self.updateControllerSkin()
        
        // Implicitly called from updateControllerSkin()
        // self.updateExternalDisplay()
        
        self.updateGameViews()
    }
    
    func updateExternalDisplay()
    {
        guard let scene = UIApplication.shared.externalDisplayScene, scene.gameViewController.delegate === self else { return }
        
        if scene.game?.fileURL != self.game?.fileURL
        {
            scene.game = self.game
        }
        
        var controllerSkin: ControllerSkinProtocol?
        
        if let game = self.game, let system = System(gameType: game.type), let traits = scene.gameViewController.controllerView.controllerSkinTraits
        {
            //TODO: Support per-game AirPlay skins
            if let preferredControllerSkin = Settings.preferredControllerSkin(for: system, traits: traits, forExternalController: false), preferredControllerSkin.supports(traits)
            {
                // Use preferredControllerSkin directly.
                controllerSkin = preferredControllerSkin
            }
            else if let standardSkin = DeltaCore.ControllerSkin.standardControllerSkin(for: game.type), standardSkin.supports(traits)
            {
                if standardSkin.hasTouchScreen(for: traits)
                {
                    // Only use TouchControllerSkin for standard controller skins with touch screens.
                    
                    var touchControllerSkin = DeltaCore.TouchControllerSkin(controllerSkin: standardSkin)
                    touchControllerSkin.screenLayoutAxis = Settings.features.dsAirPlay.layoutAxis

                    if Settings.features.dsAirPlay.topScreenOnly
                    {
                        touchControllerSkin.screenPredicate = { !$0.isTouchScreen }
                    }

                    controllerSkin = touchControllerSkin
                }
                else
                {
                    controllerSkin = standardSkin
                }
            }
        }
        
        scene.gameViewController.controllerView.controllerSkin = controllerSkin
        
        // Implicitly called when assigning controllerSkin.
        // self.updateExternalDisplayGameViews()
    }
    
    func updateExternalDisplayGameViews()
    {
        guard let scene = UIApplication.shared.externalDisplayScene, let emulatorCore = self.emulatorCore, scene.gameViewController.delegate === self else { return }
        
        for gameView in scene.gameViewController.gameViews
        {
            emulatorCore.add(gameView)
            gameView.exclusiveVideoManager = emulatorCore.videoManager
            
            // GameView must layout subviews after resetting EAGLContext before it can render frames.
            // Fixes external display screen sometimes not updating when switching back to paused game.
            gameView.setNeedsLayout()
            gameView.layoutIfNeeded()
        }
    }
    
    func disconnectExternalDisplay(for scene: ExternalDisplayScene)
    {
        if scene.gameViewController.delegate === self
        {
            scene.gameViewController.delegate = nil
        }
        
        for gameView in scene.gameViewController.gameViews
        {
            self.emulatorCore?.remove(gameView)
        }
        
        self.updateControllerSkin() // Reset TouchControllerSkin + GameViews
        self.updateGameViews() // Ensure we re-enable GameView and hide AirPlay message.
    }
}

//MARK: - GameViewControllerDelegate -
/// GameViewControllerDelegate
extension GameViewController: GameViewControllerDelegate
{
    func gameViewController(_ gameViewController: DeltaCore.GameViewController, handleMenuInputFrom gameController: GameController)
    {
        guard gameViewController == self else { return }
        if self.boundCompanion.finishLandscapeArrangementIfNeeded() { return }
        
        if let pausingGameController = self.pausingGameController
        {
            guard pausingGameController == gameController else { return }
        }
        
        if let pauseViewController = self.pauseViewController
        {
            pauseViewController.dismiss()
        }
        else if self.presentedViewController == nil
        {
            self.pauseEmulation()
            self.controllerView.resignFirstResponder()
            
            self.performSegue(withIdentifier: "pause", sender: gameController)
        }
    }
    
    func gameViewControllerShouldPauseEmulation(_ gameViewController: DeltaCore.GameViewController) -> Bool
    {
        guard gameViewController == self else { return true }
        
        if let emulatorCore, emulatorCore.isWirelessMultiplayerActive
        {
            // Disable pausing game when wireless multiplayer is active.
            return false
        }
        
        return true
    }
    
    func gameViewControllerShouldResumeEmulation(_ gameViewController: DeltaCore.GameViewController) -> Bool
    {
        guard gameViewController == self else { return false }
        guard !self.isContinuingHandoff else { return false }
        guard !self.isPreparingAchievements else { return false }
        
        var result = false
        
        rst_dispatch_sync_on_main_thread {
            let macSheet = BoundMacWorkspacePlatform.isEnabled && (self.boundCompanion.state.showingFriends || self.boundCompanion.state.showingSettings)
            result = !self.boundCompanion.isEditingNotes && !macSheet && (self.presentedViewController == nil || self.presentedViewController?.isDisappearing == true) && self.view.window != nil
        }
        
        return result
    }
    
    func gameViewController(_ gameViewController: DeltaCore.GameViewController, didUpdateGameViews gameViews: [GameView])
    {
        // gameViewController could be `self` or ExternalDisplayScene.gameViewController.
        
        if gameViewController == self
        {
            self.updateGameViews()
        }
        else
        {
            self.updateExternalDisplayGameViews()
        }
    }
    
    func gameViewController(_ gameViewController: DeltaCore.GameViewController, optionsFor game: GameProtocol) -> [EmulatorCore.Option: Any]
    {
        Self.emulatorCoreOptions(for: game)
    }

    static func emulatorCoreOptions(for game: GameProtocol) -> [EmulatorCore.Option: Any]
    {
        if let game = game as? Game, game.type == .n64
        {
            if let useOpenGLES2 = game.settings[.openGLES2] as? Bool, useOpenGLES2
            {
                return [.openGLES2: true]
            }
            else
            {
                return [:]
            }
        }
        else
        {
            var options: [EmulatorCore.Option: Any] = [.metal: ExperimentalFeatures.shared.metal.isEnabled]
            // The Simulator GL driver crashes when keyboard/layout resize races a resumed draw.
            // Physical devices keep Delta's existing Metal preference for GBA.
            #if targetEnvironment(simulator)
            if game.type == .gba { options[.metal] = true }
            #endif
            
            if #available(iOS 18, macOS 15, *), ProcessInfo.processInfo.isiOSAppOnMac
            {
                // macOS 15 Sequoia no longer supports rendering bitmap CIImages with OpenGL ES,
                // so always render with Metal.
                options[.metal] = true
            }
            
            return options
        }
    }
}

//MARK: - Gestures -
/// Gestures
extension GameViewController
{
    override func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool
    {
        guard super.gestureRecognizer(gestureRecognizer, shouldReceive: touch) else { return false }
        
        if gestureRecognizer == self.gameScreenRepositionGestureRecognizer
        {
            guard self.canRepositionGameScreen, !self.isMenuButtonHeldDown else { return false }

            let location = touch.location(in: self.view)

            // Begin only when touching a game screen (but not the DS touch screen).
            let isTouchingGameScreen: Bool
            if let traits = self.controllerView.controllerSkinTraits,
               let screens = self.controllerView.controllerSkin?.screens(for: traits)
            {
                isTouchingGameScreen = zip(screens, self.gameViews).contains { screen, gameView in
                    !screen.isTouchScreen && gameView.frame.contains(location)
                }
            }
            else
            {
                isTouchingGameScreen = self.gameViews.contains { $0.frame.contains(location) }
            }
            
            guard isTouchingGameScreen else { return false }

            self.repositionFeedbackGenerator.prepare()

            return true
        }

        // Default to true, as if this method wasn't overridden.
        return true
    }
    
    @objc private func handleGameScreenRepositionGesture(_ gestureRecognizer: UILongPressGestureRecognizer)
    {
        guard let traits = self.controllerView.controllerSkinTraits else { return }
        let location = gestureRecognizer.location(in: self.view)

        switch gestureRecognizer.state
        {
        case .began:
            self.repositionAnchor = location
            self.showRepositionResetButton()
            
            if #available(iOS 17.5, *)
            {
                self.repositionFeedbackGenerator.impactOccurred(at: location)
            }
            else
            {
                self.repositionFeedbackGenerator.impactOccurred()
            }

        case .changed:
            // Reposition screen through the offset (rather than moving the game view, which the layout would overwrite).
            let distance = self.gameScreenDistance(to: location, for: traits)
            
            switch traits.orientation
            {
            case .portrait: self.gameScreenOffset = CGPoint(x: 0, y: distance)
            case .landscape: self.gameScreenOffset = CGPoint(x: distance, y: 0)
            }
            
            self.view.setNeedsLayout()

        case .ended:
            let distance = self.gameScreenDistance(to: location, for: traits)
            UserDefaults.standard.setGameScreenOffset(distance, for: traits)
            self.repositionAnchor = nil
            self.hideRepositionResetButton(afterDelay: 3.0) // Match the toast auto-dismiss duration.

        case .cancelled, .failed:
            self.repositionAnchor = nil
            self.hideRepositionResetButton(afterDelay: 3.0)

        default: break
        }
    }
}

private extension GameViewController
{
    // True when on-screen controls are hidden (for DS, via TouchControllerSkin).
    var canRepositionGameScreen: Bool
    {
        if BoundMacWorkspacePlatform.isEnabled { return false }
        return self.controllerView.isHidden || self.controllerView.controllerSkin is TouchControllerSkin
    }

    // Distance the game view has been dragged along its movable axis, clamped within the screen bounds.
    func gameScreenDistance(to location: CGPoint, for traits: DeltaCore.ControllerSkin.Traits) -> CGFloat
    {
        guard let anchor = self.repositionAnchor else { return 0 }

        // Union of all game views (so the clamp accounts for both screens on DS).
        let gameSize = self.gameViews.reduce(CGRect.null) { $0.union($1.frame) }.size
        let screenSize = self.view.bounds.size

        let distance: CGFloat
        let maxDistance: CGFloat
        switch traits.orientation
        {
        case .portrait:
            distance = UserDefaults.standard.gameScreenOffset(for: traits) + (location.y - anchor.y)
            maxDistance = (screenSize.height - gameSize.height) / 2
        case .landscape:
            distance = UserDefaults.standard.gameScreenOffset(for: traits) + (location.x - anchor.x)
            maxDistance = (screenSize.width - gameSize.width) / 2
        }

        return min(max(distance, -maxDistance), maxDistance)
    }

    func resetGameScreenPosition()
    {
        self.hideRepositionResetButton()

        guard let traits = self.controllerView.controllerSkinTraits else { return }

        UserDefaults.standard.setGameScreenOffset(0, for: traits)
        self.repositionAnchor = nil

        self.gameScreenOffset = .zero
        self.view.setNeedsLayout()

        UIView.animate(withDuration: 0.3) {
            self.view.layoutIfNeeded()
        }
    }

    func showRepositionResetButton()
    {
        self.repositionResetButtonTimer?.invalidate()

        self.repositionResetButton.isHidden = false
        UIView.animate(withDuration: 0.2) {
            self.repositionResetButton.alpha = 1.0
        }
    }

    func hideRepositionResetButton(afterDelay delay: TimeInterval = 0)
    {
        self.repositionResetButtonTimer?.invalidate()
        
        self.repositionResetButtonTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            
            UIView.animate(withDuration: 0.2) {
                self.repositionResetButton.alpha = 0.0
            } completion: { finished in
                if finished
                {
                    self.repositionResetButton.isHidden = true
                }
            }
        }
    }

    func show(_ toastView: RSTToastView, in superview: UIView? = nil, duration: TimeInterval = 3.0)
    {
        let superview = superview ?? self.view!
        
        toastView.textLabel.textAlignment = .center
        toastView.presentationEdge = .top
        toastView.show(in: superview, duration: duration)
    }
    
    func showJITEnabledAlert()
    {
        guard !self.presentedJITAlert, self.presentedViewController == nil, self.game != nil else { return }
        self.presentedJITAlert = true
        
        func presentToastView()
        {
            let detailText: String?
            let duration: TimeInterval
            
            if UserDefaults.standard.jitEnabledAlertCount < 3
            {
                detailText = NSLocalizedString("You can now Fast Forward DS games up to 3x speed.", comment: "")
                duration = 5.0
            }
            else
            {
                detailText = nil
                duration = 2.0
            }
            
            let toastView = RSTToastView(text: NSLocalizedString("JIT Compilation Enabled", comment: ""), detailText: detailText)
            toastView.edgeOffset.vertical = 8
            self.show(toastView, duration: duration)
            
            UserDefaults.standard.jitEnabledAlertCount += 1
        }
        
        DispatchQueue.main.async {
            if let transitionCoordinator = self.transitionCoordinator
            {
                transitionCoordinator.animate(alongsideTransition: nil) { (context) in
                    presentToastView()
                }
            }
            else
            {
                presentToastView()
            }
        }
    }
    
    @available(iOS 15, *)
    func chooseWFCServer()
    {
        let viewController = WFCServersView.makeViewController()
        
        let navigationController = UINavigationController(rootViewController: viewController)
        navigationController.isModalInPresentation = true
        
        func finish()
        {
            if let preferredWFCServer = Settings.preferredWFCServer
            {
                var message = NSLocalizedString("Please restart this game to apply your changes.", comment: "")
                
                if FileManager.default.fileExists(atPath: MelonDSEmulatorBridge.shared.firmwareURL.path)
                {
                    message += "\n\n"
                    message += NSLocalizedString("You may need to also “Erase Nintendo WFC Configuration” in-game.", comment: "")
                }
                
                let alertController = UIAlertController(title: NSLocalizedString("Restart Required", comment: ""), message: message, preferredStyle: .alert)
                alertController.addAction(UIAlertAction(title: NSLocalizedString("Restart", comment: ""), style: .destructive) { _ in
                    if let emulatorBridge = self.emulatorCore?.deltaCore.emulatorBridge as? MelonDSEmulatorBridge
                    {
                        emulatorBridge.wfcDNS = preferredWFCServer
                    }
                    
                    self.emulatorCore?.stop()
                    self.emulatorCore?.start()
                    
                    navigationController.dismiss(animated: true)
                })
                alertController.addAction(UIAlertAction(title: NSLocalizedString("Later", comment: ""), style: .cancel) { _ in
                    self.emulatorCore?.resume()
                    navigationController.dismiss(animated: true)
                })
                
                viewController.present(alertController, animated: true)
            }
            else
            {
                // No changes, so just resume + dismiss navigationController.
                self.emulatorCore?.resume()
                navigationController.dismiss(animated: true)
            }
        }
        
        let doneButton = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { _ in
            finish()
        })
        viewController.navigationItem.rightBarButtonItem = doneButton
        
        self.present(navigationController, animated: true)
    }
}

//MARK: - Handoff -
extension GameViewController: NSUserActivityDelegate
{
    func prepareForHandoff()
    {
        guard !self.isContinuingHandoff else { return }
        self.isContinuingHandoff = true
        
        self.updateGameViews()
        
        self.handoffPlaceholderView.alpha = 1.0
        self.handoffPlaceholderView.isHidden = false
    }
    
    func finishHandoff()
    {
        guard self.isContinuingHandoff else { return }
        self.isContinuingHandoff = false
        
        self.updateGameViews()
        
        UIView.animate(withDuration: 0.4) {
            self.handoffPlaceholderView.alpha = 0.0
        } completion: { _ in
            self.handoffPlaceholderView.isHidden = true
        }
    }
    
    func startGameActivity()
    {
        if let userActivity = self.view.window?.windowScene?.userActivity, userActivity.activityType == NSUserActivity.playGameActivityType,
           let gameID = userActivity.userInfo?[NSUserActivity.gameIDKey] as? String, let game = self.game as? Game, game.identifier == gameID
        {
            // There is an existing activity for this game, so make it the current activity.
            userActivity.becomeCurrent()
        }
        else if let game = self.game as? Game
        {
            // No existing activity, or activity is different type, so create new activity.
            
            let userActivity = NSUserActivity(game: game)
            userActivity.delegate = self
            userActivity.isEligibleForHandoff = true
            userActivity.supportsContinuationStreams = true
            userActivity.userInfo?[NSUserActivity.isSaveStateAvailable] = true // Allow transferring save states via Handoff
            userActivity.requiredUserInfoKeys?.insert(NSUserActivity.isSaveStateAvailable)
            userActivity.becomeCurrent()
            self.view.window?.windowScene?.userActivity = userActivity
        }
        else
        {
            // No game, so stop current activity instead.
            self.stopGameActivity()
        }
    }
    
    func pauseGameActivity()
    {
        guard let userActivity = self.view.window?.windowScene?.userActivity, userActivity.activityType == NSUserActivity.playGameActivityType else { return }
        userActivity.resignCurrent()
    }
    
    func stopGameActivity()
    {
        self.pauseGameActivity()
        self.view.window?.windowScene?.userActivity = nil
    }
    
    func userActivity(_ userActivity: NSUserActivity, didReceive inputStream: InputStream, outputStream: OutputStream)
    {
        inputStream.open()
        outputStream.open()
        
        let isRunning = (self.emulatorCore?.state == .running)
        if isRunning
        {
            self.pauseEmulation()
        }
        
        let temporaryURL = FileManager.default.uniqueTemporaryURL()
        self.emulatorCore?.saveSaveState(to: temporaryURL)
        
        Task<Void, Never> {
            do
            {
                if #available(iOS 16, *)
                {
                    // Wait for save state to flush to disk (necessary for N64).
                    try await Task.sleep(for: .seconds(0.5))
                }

                defer {
                    try? FileManager.default.removeItem(at: temporaryURL)
                }
                
                let data = try Data(contentsOf: temporaryURL)
                try await outputStream.send(data)
                
                self.quitEmulation()
            }
            catch
            {
                Logger.main.error("Failed to send save state for Handoff. \(error.localizedDescription, privacy: .public)")
                
                if isRunning
                {
                    self.resumeEmulation()
                }
            }
            
            inputStream.close()
            outputStream.close()
        }
    }
}

//MARK: - RetroAchievements
private extension GameViewController
{
    func startTrackingAchievements()
    {
        NotificationCenter.default.removeObserver(self, name: AchievementsTracker.didUnlockAchievementNotification, object: self.achievementsTracker)
        
        guard let emulatorCore, let game = self.game as? Game, AchievementsManager.shared.isAuthenticated, game.settings[.retroAchievementsEnabled] as? Bool ?? true
        else { return }
        
        self.isPreparingAchievements = true
        
        Task<Void, Never> {
            do
            {
                let tracker = try AchievementsManager.shared.makeTracker(for: emulatorCore)
                let gameInfo = try await tracker.start()
                
                NotificationCenter.default.addObserver(self, selector: #selector(GameViewController.didUnlockAchievement(with:)), name: AchievementsTracker.didUnlockAchievementNotification, object: tracker)
                
                self.achievementsTracker = tracker
                
                if #available (iOS 26.0, *)
                {
                    let toastView = AchievementToastView {
                        AchievementGameBanner(game: gameInfo)
                    }
                    toastView.show(in: self.view, duration: 4.0)
                }
            }
            catch
            {
                Logger.main.error("Failed to start tracking achievements for game \(game.name). \(error.localizedDescription, privacy: .public)")
                
                let toastView = RSTToastView(text: NSLocalizedString("Unable to Track Achievements", comment: ""), detailText: error.localizedDescription)
                self.show(toastView)
            }
            
            self.isPreparingAchievements = false
            
            DispatchQueue.global(qos: .userInitiated).async {
                // Call from non-main thread to avoid potential deadlock.
                self.resumeEmulation()
            }
        }
    }
}

//MARK: - Notifications -
private extension GameViewController
{
    @objc func didEnterBackground(with notification: Notification)
    {
        self.updateAutoSaveState()
        
        if let emulatorCore, emulatorCore.isWirelessMultiplayerActive
        {
            self.onlineBackgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "Online Background Connection") { [weak self] in
                guard let self, let taskID = self.onlineBackgroundTaskID else { return }
                UIApplication.shared.endBackgroundTask(taskID)
                self.onlineBackgroundTaskID = nil
            }
        }
    }
    
    @objc func managedObjectContextDidChange(with notification: Notification)
    {
        guard let deletedObjects = notification.userInfo?[NSDeletedObjectsKey] as? Set<NSManagedObject> else { return }
        guard let game = self.game as? Game else { return }
        
        if deletedObjects.contains(game)
        {
            self.emulatorCore?.gameViews.forEach { $0.inputImage = nil }
            self.game = nil
        }
    }
    
    @objc func settingsDidChange(with notification: Notification)
    {
        guard let settingsName = notification.userInfo?[Settings.NotificationUserInfoKey.name] as? Settings.Name else { return }
        
        switch settingsName
        {
        case .resetToDefaults:
            self.restoreBoundFastForward()
            self.updateControllers()
            self.controllerView.translucentControllerSkinOpacity = Settings.translucentControllerSkinOpacity
            self.view.setNeedsLayout()

        case .localControllerPlayerIndex, .isButtonHapticFeedbackEnabled, .isThumbstickHapticFeedbackEnabled:
            self.updateControllers()

        case .preferredControllerSkin:
            guard
                let system = notification.userInfo?[Settings.NotificationUserInfoKey.system] as? System,
                let traits = notification.userInfo?[Settings.NotificationUserInfoKey.traits] as? DeltaCore.ControllerSkin.Traits
            else { return }
                        
            if system.gameType == self.game?.type && traits.orientation == self.controllerView.controllerSkinTraits?.orientation
            {
                self.updateControllerSkin()
            }
            
        case .translucentControllerSkinOpacity:
            self.controllerView.translucentControllerSkinOpacity = Settings.translucentControllerSkinOpacity
            
        case .respectSilentMode, .mixWithOtherAudio, .pauseOtherAudio:
            self.updateAudio()
                
        case .syncingService, .isAltJITEnabled: break
            
        case Settings.features.dsAirPlay.$topScreenOnly.settingsKey: fallthrough
        case Settings.features.dsAirPlay.$layoutAxis.settingsKey:
            self.updateExternalDisplay()
        
        case ExperimentalFeatures.shared.airPlaySkins.settingsKey: fallthrough
        case _ where settingsName.rawValue.hasPrefix(ExperimentalFeatures.shared.airPlaySkins.settingsKey.rawValue):
            // Update whenever any of the AirPlay skins have changed.
            self.updateExternalDisplay()
            
        case .pauseWhileInactive: self.automaticallyPausesWhileInactive = Settings.pauseWhileInactive
        case .supportsExternalDisplays:
            // May return nil if Settings.supportsExternalDisplays is false
            // guard let externalDisplayScene = UIApplication.shared.externalDisplayScene else { break }
            
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? ExternalDisplayScene }).first(where: { $0.session.role == .windowExternalDisplayNonInteractive }) else { break }
            
            if Settings.supportsExternalDisplays /*, scene.hasKeyboardFocus */ // Connect all scenes, not just one with keyboard focus.
            {
                self.connectExternalDisplay(for: scene)
            }
            else
            {
                self.disconnectExternalDisplay(for: scene)
            }
            
            
        default: break
        }
    }
    
    @objc func deepLinkControllerWillLaunchGame(with notification: Notification)
    {
        guard let game = notification.userInfo?[DeepLink.Key.game] as? Game, let scene = notification.userInfo?[DeepLink.Key.scene] as? UIScene, scene == self.view.window?.windowScene else { return }
        
        // Game won't start until we call finishHandoff()
        self.game = game
        self.prepareForHandoff()
        
        self.returnToGameViewController()
    }
    
    @objc func deepLinkControllerLaunchGame(with notification: Notification)
    {
        guard let game = notification.userInfo?[DeepLink.Key.game] as? Game, let scene = notification.userInfo?[DeepLink.Key.scene] as? UIScene, scene == self.view.window?.windowScene else { return }
        
        let previousGame = self.game
        self.game = game
        
        if self.isContinuingHandoff
        {
            let error = notification.userInfo?[DeepLink.Key.error] as? Error
            self.finishHandoff()
            
            if let saveState = notification.userInfo?[DeepLink.Key.saveState] as? SaveStateProtocol
            {
                // Included save state with deep link, so load it when emulator core is started.
                // Note: Will be automatically deleted when loaded, so make a copy if it's important.
                _deepLinkResumingSaveState = saveState
            }
            
            if let error
            {
                let toastView = RSTToastView(text: NSLocalizedString("Handoff Failed", comment: ""), detailText: error.localizedDescription)
                self.show(toastView)
            }
        }
        else if let pausedSaveState = self.pausedSaveState, game == (previousGame as? Game)
        {
            // Launching current game via deep link, so we store a copy of the paused save state to resume when emulator core is started.
            
            do
            {
                let temporaryURL = FileManager.default.uniqueTemporaryURL()
                try FileManager.default.copyItem(at: pausedSaveState.fileURL, to: temporaryURL)
                
                _deepLinkResumingSaveState = DeltaCore.SaveState(fileURL: temporaryURL, gameType: game.type)
            }
            catch
            {
                Logger.main.error("Failed to resume save state after deep link. \(error.localizedDescription, privacy: .public)")
            }
        }
                
        self.returnToGameViewController() {
            self.resumeEmulation()
        }
    }
    
    
    @objc func didActivateGyro(with notification: Notification)
    {
        self.isGyroActive = true
        
        if #available(iOS 16, *)
        {
            DispatchQueue.main.async {
                self.setNeedsUpdateOfSupportedInterfaceOrientations()
                self.parent?.setNeedsUpdateOfSupportedInterfaceOrientations() // LaunchViewController
            }
        }
        
        guard !self.presentedGyroAlert else { return }
        
        self.presentedGyroAlert = true
        
        func presentToastView()
        {
            let toastView = RSTToastView(text: NSLocalizedString("Autorotation Disabled", comment: ""), detailText: NSLocalizedString("Pause game to change orientation.", comment: ""))
            self.show(toastView)
        }
        
        DispatchQueue.main.async {
            if let transitionCoordinator = self.transitionCoordinator
            {
                transitionCoordinator.animate(alongsideTransition: nil) { (context) in
                    presentToastView()
                }
            }
            else
            {
                presentToastView()
            }
        }
    }
    
    @objc func didDeactivateGyro(with notification: Notification)
    {
        self.isGyroActive = false
        
        if #available(iOS 16, *)
        {
            DispatchQueue.main.async {
                self.setNeedsUpdateOfSupportedInterfaceOrientations()
                self.parent?.setNeedsUpdateOfSupportedInterfaceOrientations() // LaunchViewController
            }
        }
    }
    
    @objc func didConnectOnline(with notification: Notification)
    {
        guard let bridge = notification.object as? EmulatorBridging, bridge.gameURL == self.game?.fileURL else { return }
        
        guard let emulatorCore, !emulatorCore.isWirelessMultiplayerActive else { return }
        
        if Settings.preferredWFCServer == nil && !UserDefaults.standard.didShowChooseWFCServerAlert, #available(iOS 15, *)
        {
            // Ask user to choose preferred WFC server before connecting online.
            
            DispatchQueue.main.async {
                emulatorCore.pause()
                
                let alertController = UIAlertController(title: NSLocalizedString("Choose WFC Server", comment: ""), message: NSLocalizedString("You must choose a 3rd-party WFC server to use Nintendo DS online features.", comment: ""), preferredStyle: .alert)
                alertController.addAction(UIAlertAction(title: NSLocalizedString("Later", comment: ""), style: .cancel) { _ in
                    emulatorCore.resume()
                })
                alertController.addAction(UIAlertAction(title: NSLocalizedString("Choose Server", comment: ""), style: .default) { _ in
                    self.chooseWFCServer()
                })
                
                self.present(alertController, animated: true)
                UserDefaults.standard.didShowChooseWFCServerAlert = true
            }
            
            return
        }
        
        emulatorCore.isWirelessMultiplayerActive = true
        emulatorCore.rate = 1.0 // Disable FF in case it is currently enabled.
        
        DispatchQueue.main.async {
            let toastView = RSTToastView(text: NSLocalizedString("Connecting to Nintendo WFC…", comment: ""), detailText: NSLocalizedString("Some features will be disabled while playing online.", comment: ""))
            self.show(toastView, in: self.view.window, duration: 5.0) // Show in window to fix not receiving touches 🤷‍♂️
            self.onlineConnectionDate = Date()
        }
    }
    
    @objc func didDisconnectFromOnline(with notification: Notification)
    {
        guard let bridge = notification.object as? EmulatorBridging, bridge.gameURL == self.game?.fileURL else { return }
        
        guard let emulatorCore, emulatorCore.isWirelessMultiplayerActive else { return }
        emulatorCore.isWirelessMultiplayerActive = false
        
        DispatchQueue.main.async {
            let toastView = RSTToastView(text: NSLocalizedString("Disconnected from Nintendo WFC", comment: ""), detailText: nil)
            var duration = 3.0
            
            if let onlineConnectionDate = self.onlineConnectionDate, Date().timeIntervalSince(onlineConnectionDate) < 30
            {
                // If we're disconnecting within 30 seconds of connecting, show troubleshooting message.
                toastView.detailTextLabel.text = NSLocalizedString("⚠️ Tap to view our Troubleshooting Guide.", comment: "")
                
                let action = UIAction { _ in
                    let troubleshootingGuideURL = URL(string: "https://faq.deltaemulator.com/using-delta/online-multiplayer")!
                    UIApplication.shared.open(troubleshootingGuideURL, options: [:])
                }
                toastView.addAction(action, for: .touchUpInside)
                
                duration = 5.0
            }
            
            self.show(toastView, in: self.view.window, duration: duration) // Show in window to fix not receiving touches 🤷‍♂️
            self.onlineConnectionDate = nil
        }
    }
    
    @objc func didUnlockAchievement(with notification: Notification)
    {
        guard let achievement = notification.userInfo?[AchievementsTracker.achievementUserInfoKey] as? Achievement else { return }
        
        DispatchQueue.main.async {
            if #available (iOS 26.0, *) {
                let toastView = AchievementToastView {
                    AchievementNotification(achievement: achievement)
                }
                toastView.show(in: self.view, duration: 4.0)
            } else {
                let title = String(format: NSLocalizedString("✅ Achievement Unlocked", comment: ""))
                let message = String(AttributedString(localized: "\(achievement.title) (^[\(achievement.points) \("point")](inflect: true))").characters)
                
                let toastView = RSTToastView(text: title, detailText: message)
                toastView.detailTextLabel.textAlignment = .center
                self.show(toastView)
            }
        }
    }
    
    @objc func didEnableJIT(with notification: Notification)
    {
        DispatchQueue.main.async {
            self.showJITEnabledAlert()
        }
        
        DispatchQueue.global(qos: .utility).async {
            guard let emulatorCore = self.emulatorCore, let emulatorBridge = emulatorCore.deltaCore.emulatorBridge as? MelonDSEmulatorBridge, !emulatorBridge.isJITEnabled
            else { return }
            
            guard emulatorCore.state != .stopped else {
                // Emulator core is not running, which means we can set
                // isJITEnabled to true without resetting the core.
                emulatorBridge.isJITEnabled = true
                return
            }
            
            let isVideoEnabled = emulatorCore.videoManager.isEnabled
            emulatorCore.videoManager.isEnabled = false
            
            let isRunning = (emulatorCore.state == .running)
            if isRunning
            {
                self.pauseEmulation()
            }
            
            let temporaryFileURL = FileManager.default.uniqueTemporaryURL()
            
            let saveState = emulatorCore.saveSaveState(to: temporaryFileURL)
            emulatorCore.stop()
            
            emulatorBridge.isJITEnabled = true
            
            emulatorCore.start()
            emulatorCore.pause()
            
            do
            {
                try emulatorCore.load(saveState)
            }
            catch
            {
                print("Failed to load save state after enabling JIT.", error)
            }
            
            if isRunning
            {
                self.resumeEmulation()
            }
            
            emulatorCore.videoManager.isEnabled = isVideoEnabled
        }
    }
    
    @objc func emulationDidQuit(with notification: Notification)
    {
        guard let emulatorCore = notification.object as? EmulatorCore, emulatorCore == self.emulatorCore else { return }
        
        DispatchQueue.main.async {
            guard self.presentedViewController == nil else { return }
            
            // Wait for emulation to stop completely before performing segue.
            var token: NSKeyValueObservation?
            token = self.emulatorCore?.observe(\.state, options: [.initial]) { (emulatorCore, change) in
                guard emulatorCore.state == .stopped else { return }
                
                DispatchQueue.main.async {
                    self.quitEmulation()
                }
                
                token?.invalidate()
            }
        }
    }
    
    @objc func sceneWillConnect(with notification: Notification)
    {
        guard let scene = notification.object as? ExternalDisplayScene, Settings.supportsExternalDisplays else { return }
        self.connectExternalDisplay(for: scene)
    }
    
    @objc func sceneDidDisconnect(with notification: Notification)
    {
        // Always allow disconnecting external displays.
        // guard Settings.supportsExternalDisplays else { return }
        
        guard let scene = notification.object as? ExternalDisplayScene else { return }
        self.disconnectExternalDisplay(for: scene)
    }
    
    @objc func sceneSessionWillQuit(with notification: Notification)
    {
        guard let session = notification.object as? UISceneSession, let windowScene = self.view.window?.windowScene, session.scene == windowScene else { return }
        Logger.main.info("Discarding current scene session, quitting emulation for game \((self.game as? Game)?.identifier ?? "nil", privacy: .public)")
        
        self.updateAutoSaveState()
        self.emulatorCore?.stop() // Required to ensure data isn't corrupted due to starting new game before previous EmulatorBridge state is reset.
    }
    
    @objc func sceneKeyboardFocusDidChange(with notification: Notification)
    {
        guard let scene = notification.object as? UIWindowScene, scene == self.view.window?.windowScene else { return }
        if !scene.hasKeyboardFocus { boundCompanion.resetMacControllerFocus() }
        guard let externalDisplayScene = UIApplication.shared.externalDisplayScene else { return }
        
        if scene.hasKeyboardFocus
        {
            self.connectExternalDisplay(for: externalDisplayScene)
            
            if self.presentedViewController == nil
            {
                self.startGameActivity()
            }
        }
        else
        {
            // DON'T disconnect, only connect when active (so it stays connected to last active scene)
        }
    }
}

private extension UserDefaults
{
    @NSManaged var desmumeDeprecatedAlertCount: Int
    
    @NSManaged var jitEnabledAlertCount: Int

    // Offset of the game screen (from center) along its movable axis when a controller is connected.
    @NSManaged var gameScreenOffsetPortrait: CGFloat
    @NSManaged var gameScreenOffsetLandscape: CGFloat

    func gameScreenOffset(for traits: DeltaCore.ControllerSkin.Traits) -> CGFloat
    {
        switch traits.orientation
        {
        case .portrait: return self.gameScreenOffsetPortrait
        case .landscape: return self.gameScreenOffsetLandscape
        }
    }

    func setGameScreenOffset(_ offset: CGFloat, for traits: DeltaCore.ControllerSkin.Traits)
    {
        switch traits.orientation
        {
        case .portrait: self.gameScreenOffsetPortrait = offset
        case .landscape: self.gameScreenOffsetLandscape = offset
        }
    }
}


// Bound's editing operates on native Delta artwork and item hit frames together.
extension GameViewController {
    func showBoundMacLibrary() {
        guard BoundMacWorkspacePlatform.isEnabled, presentedViewController == nil else { return }
        view.endEditing(true)
        pauseEmulation()
        controllerView.resignFirstResponder()
        performSegue(withIdentifier: "showGamesViewController", sender: nil)
    }

    func applyBoundControlPlacement() {
        guard !BoundMacWorkspacePlatform.isEnabled else { return }
        guard let current = controllerView.controllerSkin else { return }
        let base = unwrappedBoundControllerSkin(current)
        let layout = BoundControlPlacementStore.shared.read(skin: base.identifier, landscape: view.bounds.width > view.bounds.height)
        let mode = BoundControllerModePreferences.hidesTouchControls(enabled: BoundControllerModePreferences().isEnabled,
            layout: BoundAppearancePreferences().effectiveScreenLayout, landscape: view.bounds.width > view.bounds.height)
        if boundControllerModeActive != mode {
            cancelBoundTouchInputsPreservingExternalHolds()
            boundControllerModeActive = mode
            // Reapply upstream assignment/visibility on OFF/portrait, or add
            // the Menu-only virtual receiver on ON. The state is updated first
            // so a nested layout pass cannot repeat this transition.
            updateControllers()
        }
        let minimal = BoundAppearancePreferences().effectiveTheme == .minimal
        let source = nativeBoundControllerFrame(base: base)
        let insets = nativeBoundControllerInsets(base: base)
        let gutter = nativeBoundLandscapeControlGutter(base: base)
        let defaultMenu = boundControllerModeButtonDefaults()?[.menu]
            ?? cachedBoundTouchMenuFrame(base: base, layout: layout, source: source, insets: insets, gutter: gutter)
        let movableMenu = defaultMenu.flatMap {
            boundCompanion.controllerMenuFrame(defaultFrame: $0, canvas: view.bounds.inset(by: view.safeAreaInsets))
        }
        let controllerMenuFrame = movableMenu ?? boundControllerModeThreeGeometry()?.menu
        let configuration = BoundControlConfiguration(skin: base.identifier, layout: layout, canvas: view.bounds.size,
            source: source, insets: insets, gutter: gutter, minimal: minimal, controllerMode: mode, controllerMenuFrame: controllerMenuFrame,
            style: traitCollection.userInterfaceStyle, contrast: traitCollection.accessibilityContrast)
        // A settled layout must not recreate wrappers or serialize placements.
        // Also verify the applied identity, because upstream may replace the skin.
        if configuration == boundControlConfiguration,
           controllerView.controllerSkin?.identifier == boundAppliedSkinIdentifier { return }
        controllerView.usesControlOnlyHitTesting = mode || controllerMenuFrame != nil || !layout.positions.isEmpty
        controllerLayoutBounds = controllerMenuFrame != nil || !layout.positions.isEmpty ? view.bounds : nil
        controllerLayoutSize = controllerMenuFrame != nil ? view.bounds.size : layout.positions.isEmpty && !minimal ? nil : nativeBoundControllerSize()
        let placesTouchControls = !layout.positions.isEmpty || (!mode && controllerMenuFrame != nil)
        let stock = BoundStockControllerSkin(base: base, canvasSize: source.size, contentInsets: insets, boundLandscapeGutter: gutter)
        var proposed: ControllerSkinProtocol = placesTouchControls
            ? BoundPlacedControllerSkin(base: stock, layout: layout, canvasSize: view.bounds.size, sourceFrame: source,
                                        menuFrame: mode ? nil : controllerMenuFrame)
            : stock
        if minimal { proposed = BoundMinimalControllerSkin(base: proposed, canvasSize: placesTouchControls ? view.bounds.size : source.size, traits: traitCollection) }
        if mode {
            let menuFrame = controllerMenuFrame?.offsetBy(dx: -view.bounds.minX, dy: -view.bounds.minY)
                .applying(.init(scaleX: 1 / view.bounds.width, y: 1 / view.bounds.height))
            proposed = BoundControllerModeSkin(base: proposed, menuFrame: menuFrame)
        }
        let identifier = proposed.identifier
        if controllerView.controllerSkin?.identifier != identifier { controllerView.cancelTouchInputs(); controllerView.controllerSkin = proposed }
        boundControlConfiguration = configuration
        boundAppliedSkinIdentifier = identifier
    }
    private func cancelBoundTouchInputsPreservingExternalHolds() {
        BoundControllerModeSkin.cancelTouchInputs(in: controllerView,
            preservingExternalInputsFrom: ExternalGameControllerManager.shared.connectedControllers,
            emulatorCore: emulatorCore)
    }
    func setBoundControllerModeEnabled(_ enabled: Bool) {
        cancelBoundTouchInputsPreservingExternalHolds()
        BoundControllerModePreferences().isEnabled = enabled
        view.setNeedsLayout()
        view.layoutIfNeeded()
    }
    private func unwrappedBoundControllerSkin(_ skin: ControllerSkinProtocol) -> ControllerSkinProtocol {
        if let mode = skin as? BoundControllerModeSkin { return unwrappedBoundControllerSkin(mode.base) }
        if let placed = skin as? BoundPlacedControllerSkin { return unwrappedBoundControllerSkin(placed.base) }
        if let minimal = skin as? BoundMinimalControllerSkin { return unwrappedBoundControllerSkin(minimal.base) }
        if let stock = skin as? BoundStockControllerSkin { return unwrappedBoundControllerSkin(stock.base) }
        return skin
    }
    private func nativeBoundControllerSize() -> CGSize {
        guard let current = controllerView.controllerSkin, let traits = controllerView.controllerSkinTraits else { return controllerView.intrinsicContentSize }
        let base = unwrappedBoundControllerSkin(current)
        return base.aspectRatio(for: traits) ?? controllerView.intrinsicContentSize
    }
    private func nativeBoundControllerFrame(base: ControllerSkinProtocol) -> CGRect {
        let bounds = gameplayLayoutBounds ?? view.bounds
        guard let traits = controllerView.controllerSkinTraits, let aspect = base.aspectRatio(for: traits), aspect.width > 0, aspect.height > 0 else { return controllerView.frame }
        if traits.orientation == .portrait {
            let height = bounds.width * aspect.height / aspect.width
            return CGRect(x: bounds.minX, y: bounds.maxY - height, width: bounds.width, height: height)
        }
        return AVMakeRect(aspectRatio: aspect, insideRect: bounds)
    }
    /// App-only chrome reservation. Matches Bound's existing aspect-fit game math;
    /// it neither changes rendering bounds nor uses a stale pre-rotation game frame.
    func boundLandscapeControlGutter() -> CGRect? {
        let bounds = view.bounds
        guard BoundAppearancePreferences().effectiveScreenLayout == .bound, bounds.width > bounds.height else { return nil }
        let insets = view.safeAreaInsets
        let horizontal = CGRect(x: bounds.minX+insets.left, y: bounds.minY,
            width: max(1, bounds.width-insets.left-insets.right), height: bounds.height)
        let aspect = emulatorCore?.preferredRenderingSize ?? CGSize(width: 3, height: 2)
        guard aspect.width > 0, aspect.height > 0, aspect.width.isFinite, aspect.height.isFinite else { return nil }
        let game = AVMakeRect(aspectRatio: aspect, insideRect: horizontal)
        let safe = bounds.inset(by: insets)
        let gutter = CGRect(x: game.maxX, y: safe.minY, width: max(0, safe.maxX-game.maxX), height: safe.height)
        return gutter.width >= 44 && gutter.height >= 44 ? gutter : nil
    }
    // Legacy accessors remain for source compatibility; Mode 2 no longer affects layout.
    func boundControllerModeTwoGeometry() -> BoundControllerModeTwoGeometry? { nil }
    func boundControllerModeThreeGeometry() -> BoundControllerModeThreeGeometry? {
        guard BoundControllerModePreferences().isEnabled,
              BoundAppearancePreferences().effectiveScreenLayout == .bound else { return nil }
        return BoundControllerModeThreeGeometry(bounds: view.bounds, safeArea: view.safeAreaInsets)
    }
    func boundControllerModeButtonDefaults() -> [BoundControllerButton: CGRect]? {
        guard let geometry = boundControllerModeThreeGeometry() else { return nil }
        let canvas = view.bounds.inset(by: view.safeAreaInsets)
        return [
            .menu: geometry.menu,
            .friend: CGRect(x: canvas.maxX - 44, y: canvas.maxY - 44, width: 44, height: 44),
            .multiview: CGRect(x: canvas.maxX - 44, y: canvas.minY, width: 44, height: 44)
        ]
    }
    /// Use the unmodified touch-menu slot as the arrangement fallback. Reading
    /// the already moved skin would also shift the mirrored Friend default.
    func boundLandscapeTouchMenuDefaultFrame() -> CGRect? {
        guard !BoundControllerModePreferences().isEnabled,
              BoundAppearancePreferences().effectiveScreenLayout == .bound,
              view.bounds.width > view.bounds.height,
              let current = controllerView.controllerSkin else { return nil }
        let base = unwrappedBoundControllerSkin(current)
        let source = nativeBoundControllerFrame(base: base)
        let insets = nativeBoundControllerInsets(base: base)
        let gutter = nativeBoundLandscapeControlGutter(base: base)
        let layout = BoundControlPlacementStore.shared.read(skin: base.identifier, landscape: true)
        return cachedBoundTouchMenuFrame(base: base, layout: layout, source: source, insets: insets, gutter: gutter)
    }
    private func cachedBoundTouchMenuFrame(base: ControllerSkinProtocol, layout: BoundControlLayout,
                                           source: CGRect, insets: UIEdgeInsets, gutter: CGRect?) -> CGRect? {
        guard let traits = controllerView.controllerSkinTraits else { return nil }
        let isKnownValueSkin = base is DeltaCore.ControllerSkin || base is DeltaCore.TouchControllerSkin
        let identity: ObjectIdentifier? = isKnownValueSkin ? nil : ObjectIdentifier(base as AnyObject)
        let key = BoundStockMenuDefaultFrameCache.Key(skinIdentity: identity, skinIdentifier: base.identifier,
            skinName: base.name, gameType: String(describing: base.gameType), debugMode: base.isDebugModeEnabled,
            traits: traits, sourceFrame: source, contentInsets: insets, gutter: gutter,
            controlLayout: layout, canvasSize: view.bounds.size)
        return boundStockMenuDefaultFrameCache.frame(for: key) {
            let stock = BoundStockControllerSkin(base: base, canvasSize: source.size,
                contentInsets: insets, boundLandscapeGutter: gutter)
            return boundTouchMenuFrame(stock: stock, layout: layout, source: source)
        }
    }
    private func boundTouchMenuFrame(stock: ControllerSkinProtocol, layout: BoundControlLayout, source: CGRect) -> CGRect? {
        guard let traits = controllerView.controllerSkinTraits,
              let menu = stock.items(for: traits)?.first(where: { $0.inputs.allInputs.contains { $0.stringValue == "menu" } }) else { return nil }
        let frame = menu.frame.applying(.init(scaleX: source.width, y: source.height))
            .offsetBy(dx: source.minX, dy: source.minY)
        return layout.frame(id: menu.id, base: frame, canvas: view.bounds.size, directional: false)
    }
    private func nativeBoundLandscapeControlGutter(base: ControllerSkinProtocol) -> CGRect? {
        guard let gutter = boundLandscapeControlGutter() else { return nil }
        let source = nativeBoundControllerFrame(base: base)
        return gutter.offsetBy(dx: -source.minX, dy: -source.minY).intersection(CGRect(origin: .zero, size: source.size))
    }
    private func nativeBoundControllerInsets(base: ControllerSkinProtocol) -> UIEdgeInsets {
        let source = nativeBoundControllerFrame(base: base)
        let visible = view.bounds.inset(by: view.safeAreaInsets).intersection(source)
        guard !visible.isNull else { return .zero }
        return UIEdgeInsets(top: max(0, visible.minY-source.minY), left: max(0, visible.minX-source.minX), bottom: max(0, source.maxY-visible.maxY), right: max(0, source.maxX-visible.maxX))
    }
    func showBoundControlPlacement(from presenter: UIViewController? = nil) {
        let presenting = presenter ?? self
        guard presenting.presentedViewController == nil, let current = controllerView.controllerSkin,
              let traits = controllerView.controllerSkinTraits else { return }
        let base = unwrappedBoundControllerSkin(current)
        boundCompanion.cancelInteractions()
        let editor = BoundControlPlacementEditor(skin: BoundStockControllerSkin(base: base, canvasSize: nativeBoundControllerFrame(base: base).size, contentInsets: nativeBoundControllerInsets(base: base), boundLandscapeGutter: nativeBoundLandscapeControlGutter(base: base)), traits: traits, canvasSize: view.bounds.size, landscape: view.bounds.width > view.bounds.height, sourceFrame: nativeBoundControllerFrame(base: base), storageIdentifier: base.identifier, saved: { [weak self] in self?.applyBoundControlPlacement(); self?.view.setNeedsLayout() })
        let navigation = UINavigationController(rootViewController: editor)
        navigation.modalPresentationStyle = .fullScreen
        presenting.present(navigation, animated: true)
    }
}

extension GameViewController
{
    /// Change only receiver mappings when a panel opens/closes. No controller
    /// reconnect, database fetch, or next-frame delay is needed for this handoff.
    internal func refreshBoundMultiviewInputRouting()
    {
        guard !updatingBoundMultiviewRouting, let core = emulatorCore else { return }
        let capture = boundCompanion.automaticControllerMultiviewAvailable
            && (boundCompanion.isMacWorkspace || view.bounds.width > view.bounds.height)
        guard capture != boundMultiviewCapturing else { return }
        updatingBoundMultiviewRouting = true
        boundMultiviewCapturing = capture
        boundMultiviewRepeater.endAll()
        for controller in ExternalGameControllerManager.shared.connectedControllers {
            guard controller.playerIndex != nil,
                  let old = controller.inputMapping(for: self) as? BoundControllerInputMapping else { continue }
            let mapping = BoundControllerInputMapping(base: old.base, multiviewActive: capture,
                                                       multiviewDefaults: old.multiviewDefaults,
                                                       friendWorldGate: old.friendWorldGate)
            installBoundInputMapping(mapping, controller: controller, core: core)
        }
        updatingBoundMultiviewRouting = false
    }

    internal func returnToGameViewController(completion: (() -> Void)? = nil)
    {
        if let pauseViewController = self.pauseViewController
        {
            let segue = UIStoryboardSegue(identifier: "unwindFromPauseMenu", source: pauseViewController, destination: self)
            self.unwindFromPauseViewController(segue)
        }
        else if
            let navigationController = self.presentedViewController as? UINavigationController,
            let pageViewController = navigationController.topViewController?.children.first as? UIPageViewController,
            let gameCollectionViewController = pageViewController.viewControllers?.first as? GameCollectionViewController
        {
            let segue = UIStoryboardSegue(identifier: "unwindFromGames", source: gameCollectionViewController, destination: self)
            self.unwindFromGamesViewController(with: segue)
        }

        if let presentedViewController = self.presentedViewController
        {
            presentedViewController.dismiss(animated: true, completion: completion)
        }
        else
        {
            completion?()
        }
    }
}
