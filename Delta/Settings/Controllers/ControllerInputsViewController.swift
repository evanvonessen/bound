//
//  ControllerInputsViewController.swift
//  Delta
//
//  Created by Riley Testut on 7/1/17.
//  Copyright © 2017 Riley Testut. All rights reserved.
//

import UIKit
import Roxas

import DeltaCore

import SMCalloutView

class ControllerInputsViewController: UIViewController
{
    var gameController: GameController! {
        didSet {
            self.gameController.addReceiver(self, inputMapping: nil)
        }
    }
    
    var system: System = .gba {
        didSet {
            guard self.system != oldValue else { return }
            self.updateSystem()
        }
    }
    
    private lazy var managedObjectContext: NSManagedObjectContext = DatabaseManager.shared.newBackgroundContext()
    private var inputMappings = [System: GameControllerInputMapping]()
    
    private var supportedActionInputs: [ActionInput] {
        var actions = ActionInput.configurableActions
        if let controller = self.gameController as? MFiGameController, controller.physicalHomeInput != nil
        {
            actions.append(.systemOverlay)
        }
        return actions
    }
    
    private var gameViewController: DeltaCore.GameViewController!
    private var actionsMenuViewController: GridMenuViewController!
    
    private var calloutViews = [AnyInput: InputCalloutView]()
    
    private var activeCalloutView: InputCalloutView?

    private var savedCurrentMapping = false
    
    private var _didLayoutSubviews = false
    
    @IBOutlet private var actionsMenuViewControllerHeightConstraint: NSLayoutConstraint!
    @IBOutlet private var cancelTapGestureRecognizer: UITapGestureRecognizer!
    
    public override var next: UIResponder? {
        return KeyboardResponder(nextResponder: super.next)
    }
    
    override var shouldAutorotate: Bool {
        return false
    }
    
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return .portrait
    }
    
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        return .portrait
    }
        
    override func viewDidLoad()
    {
        super.viewDidLoad()
        
        self.gameViewController.controllerView.addReceiver(self)
        
        if let navigationController = self.navigationController, #available(iOS 13, *)
        {
            navigationController.overrideUserInterfaceStyle = .dark
            navigationController.navigationBar.scrollEdgeAppearance = navigationController.navigationBar.standardAppearance // Fixes invisible navigation bar on iPad.
        }
        else
        {
            self.navigationController?.navigationBar.barStyle = .black
        }
        
        NSLayoutConstraint.activate([self.gameViewController.gameView.centerYAnchor.constraint(equalTo: self.actionsMenuViewController.view.centerYAnchor)])
        
        self.preparePopoverMenuController()
        self.updateSystem()

        if #available(iOS 27, *),
           let controller = self.gameController as? MFiGameController,
           controller.physicalHomeInput != nil
        {
            var rightItems = self.navigationItem.rightBarButtonItems ?? []
            rightItems.append(UIBarButtonItem(title: NSLocalizedString("Home Button Settings", comment: ""), style: .plain, target: self, action: #selector(self.openHomeButtonSettings)))
            self.navigationItem.rightBarButtonItems = rightItems
        }
    }
    
    override func viewDidLayoutSubviews()
    {
        super.viewDidLayoutSubviews()
        
        if self.actionsMenuViewController.preferredContentSize.height > 0
        {
            self.actionsMenuViewControllerHeightConstraint.constant = self.actionsMenuViewController.preferredContentSize.height
        }
        
        if let window = self.view.window, !_didLayoutSubviews
        {
            var traits = DeltaCore.ControllerSkin.Traits.defaults(for: window)
            traits.orientation = .portrait
            
            if traits.device == .ipad
            {
                // Use standard iPhone skins instead of iPad skins.
                traits.device = .iphone
                traits.displayType = .standard
            }
            
            self.gameViewController.controllerView.overrideControllerSkinTraits = traits
            
            _didLayoutSubviews = true
        }
    }
    
    override func viewDidAppear(_ animated: Bool)
    {
        super.viewDidAppear(animated)
        
        if self.calloutViews.isEmpty
        {
            self.prepareCallouts()
        }
        
        // controllerView must be first responder to receive keyboard presses.
        self.gameViewController.controllerView.becomeFirstResponder()

        if let controller = self.gameController as? MFiGameController,
           let mapping = self.inputMappings[self.system]
        {
            BoundControllerSystemGestures.apply(to: controller, mapping: mapping, capturing: true)
        }
    }

    override func viewDidDisappear(_ animated: Bool)
    {
        super.viewDidDisappear(animated)

        guard let controller = self.gameController as? MFiGameController else { return }

        let mapping: GameControllerInputMappingProtocol
        if savedCurrentMapping, let currentMapping = self.inputMappings[self.system]
        {
            mapping = currentMapping
        }
        else if let storedMapping = GameControllerInputMapping.inputMapping(forPlayer: controller.playerIndex,
                                                                             gameType: self.system.gameType,
                                                                             controllerType: controller.inputType,
                                                                             in: DatabaseManager.shared.viewContext)
        {
            mapping = storedMapping
        }
        else if let defaultMapping = controller.defaultInputMapping as? DeltaCore.GameControllerInputMapping
        {
            mapping = defaultMapping
        }
        else
        {
            mapping = DeltaCore.GameControllerInputMapping(gameControllerInputType: controller.inputType)
        }

        BoundControllerSystemGestures.apply(to: controller, mapping: mapping, capturing: false)
    }
}

extension ControllerInputsViewController
{
    override func prepare(for segue: UIStoryboardSegue, sender: Any?)
    {
        guard let identifier = segue.identifier else { return }
        
        switch identifier
        {
        case "embedGameViewController": self.gameViewController = segue.destination as? DeltaCore.GameViewController
        case "embedActionsMenuViewController":
            self.actionsMenuViewController = segue.destination as? GridMenuViewController
            self.prepareActionsMenuViewController()
            
        case "cancelControllerInputs": break
        case "saveControllerInputs":
            self.managedObjectContext.performAndWait {
                self.managedObjectContext.saveWithErrorLogging()
            }
            self.savedCurrentMapping = true
            
        default: break
        }
    }

    @objc private func openHomeButtonSettings()
    {
        guard #available(iOS 27, *) else { return }

        ControllerHomeButtonSettings.open { [weak self] error in
            let alert = UIAlertController(title: NSLocalizedString("Unable to Open Home Button Settings", comment: ""),
                                          message: error.localizedDescription,
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .default))
            self?.present(alert, animated: true)
        }
    }
}

private extension ControllerInputsViewController
{
    func makeDefaultInputMapping() -> GameControllerInputMapping
    {
        let deltaCoreInputMapping = BoundMultiviewDefaultMapping.mapping(for: self.gameController)
        
        let inputMapping = GameControllerInputMapping(inputMapping: deltaCoreInputMapping, context: self.managedObjectContext)
        inputMapping.gameControllerInputType = gameController.inputType
        inputMapping.gameType = self.system.gameType
        
        if let controller = self.gameController, let playerIndex = controller.playerIndex
        {
            inputMapping.playerIndex = Int16(playerIndex)
        }
        
        return inputMapping
    }
    
    func updateSystem()
    {
        guard self.isViewLoaded else { return }
        
        // Update popoverMenuButton to display correctly on iOS 10.
        if let popoverMenuButton = self.navigationItem.popoverMenuController?.popoverMenuButton
        {
            popoverMenuButton.title = self.system.localizedShortName
            popoverMenuButton.bounds.size = popoverMenuButton.intrinsicContentSize
            
            self.navigationController?.navigationBar.layoutIfNeeded()
        }
        
        // Update controller view's controller skin.
        self.gameViewController.controllerView.controllerSkin = DeltaCore.ControllerSkin.standardControllerSkin(for: self.system.gameType)
        self.gameViewController.view.setNeedsUpdateConstraints()
        
        // Fetch input mapping if it hasn't already been fetched.
        if let gameController = self.gameController, self.inputMappings[self.system] == nil
        {
            self.managedObjectContext.performAndWait {
                let inputMapping = GameControllerInputMapping.inputMapping(forPlayer: gameController.playerIndex, gameType: self.system.gameType, controllerType: gameController.inputType, in: self.managedObjectContext) ?? self.makeDefaultInputMapping()
                
                inputMapping.name = String.localizedStringWithFormat("Custom %@", gameController.name)
                
                self.inputMappings[self.system] = inputMapping
            }
        }
        
        // Update callouts, if view is already on screen.
        if self.view.window != nil
        {
            self.calloutViews.forEach { $1.dismissCallout(animated: true) }
            
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.calloutViews = [:]
                self.prepareCallouts()
            }
        }
    }
    
    func preparePopoverMenuController()
    {
        let listMenuViewController = ListMenuViewController()
        listMenuViewController.title = NSLocalizedString("Game System", comment: "")
        
        let navigationController = UINavigationController(rootViewController: listMenuViewController)
        if #available(iOS 13, *)
        {
            navigationController.navigationBar.scrollEdgeAppearance = navigationController.navigationBar.standardAppearance
        }
        
        let popoverMenuController = PopoverMenuController(popoverViewController: navigationController)
        self.navigationItem.popoverMenuController = popoverMenuController
        
        let items = [System.gba].filter { Delta.core(for: $0.gameType) != nil }.map { [unowned self, weak popoverMenuController, weak listMenuViewController] system -> MenuItem in
            let item = MenuItem(text: system.localizedShortName, image: #imageLiteral(resourceName: "CheatCodes")) { [weak popoverMenuController, weak listMenuViewController] item in
                listMenuViewController?.items.forEach { $0.isSelected = ($0 == item) }
                popoverMenuController?.isActive = false
                
                self.system = system
            }
            item.isSelected = (system == self.system)
            
            return item
        }
        listMenuViewController.items = items
    }
    
    func prepareActionsMenuViewController()
    {
        var items = [MenuItem]()
        
        for input in self.supportedActionInputs
        {
            let image: UIImage
            let text: String
            
            switch input {
            case .quickSave: image = #imageLiteral(resourceName: "SaveSaveState")
            case .quickLoad: image = #imageLiteral(resourceName: "LoadSaveState")
            case .fastForward: image = #imageLiteral(resourceName: "FastForward")
            case .screenshot: image = #imageLiteral(resourceName: "Screenshot")
            default: image = UIImage(systemName: input.sfSymbolName) ?? #imageLiteral(resourceName: "Screenshot")
            }
            text = input.localizedDisplayName
            
            let item = MenuItem(text: text, image: image) { [unowned self] (item) in
                guard let calloutView = self.calloutViews[AnyInput(input)] else { return }
                self.toggle(calloutView)
            }
            
            items.append(item)
        }
        
        self.actionsMenuViewController.loadViewIfNeeded()
        
        let collectionViewLayout = self.actionsMenuViewController.collectionViewLayout as! GridCollectionViewLayout
        collectionViewLayout.minimumLineSpacing = 10
        collectionViewLayout.sectionInset.left += 10
        collectionViewLayout.sectionInset.right += 10
        collectionViewLayout.usesEqualHorizontalSpacingDistributionForSingleRow = true
        
        // Assign actionsMenuViewController's itemWidth so it can adjust layout correctly.
        self.actionsMenuViewController.itemWidth = 70 // BARELY fits 4 icons inside DS skin.
        
        self.actionsMenuViewController.items = items
        self.actionsMenuViewController.isVibrancyEnabled = false
        
        self.actionsMenuViewController.collectionView.backgroundColor = nil
    }
    
    func prepareCallouts()
    {
        guard
            let controllerView = self.gameViewController.controllerView,
            let traits = controllerView.controllerSkinTraits,
            let items = controllerView.controllerSkin?.items(for: traits),
            let controllerViewInputMapping = controllerView.defaultInputMapping,
            let inputMapping = self.inputMappings[self.system]
        else { return }
        
        // Implicit assumption that all skins used for controller input mapping don't have multiple items with same input.
        let mappedInputs = items.flatMap { $0.inputs.allInputs.compactMap(controllerViewInputMapping.input(forControllerInput:)) } + (self.supportedActionInputs as [Input])
        
        // Create callout view for each on-screen input.
        for input in mappedInputs
        {
            let calloutView = InputCalloutView()
            calloutView.delegate = self
            calloutView.permittedArrowDirection = .any
            calloutView.constrainedInsets = self.view.safeAreaInsets
            self.calloutViews[AnyInput(input)] = calloutView
        }
        
        self.managedObjectContext.performAndWait {
            // Update callout views with controller inputs that map to callout views' associated controller skin inputs.
            for input in inputMapping.supportedControllerInputs
            {
                let mappedInput = self.mappedInput(for: input)
                
                if let calloutView = self.calloutViews[mappedInput]
                {
                    if let previousInput = calloutView.input
                    {
                        // Ensure the input we display has a higher priority.
                        calloutView.input = (input.displayPriority > previousInput.displayPriority) ? input : previousInput
                    }
                    else
                    {
                        calloutView.input = input
                    }
                }
            }
        }
        
        // Present only callout views that are associated with a controller input.
        for calloutView in self.calloutViews.values
        {
            if let presentationRect = self.presentationRect(for: calloutView), calloutView.input != nil
            {
                calloutView.presentCallout(from: presentationRect, in: self.view, constrainedTo: self.view, animated: true)
            }
        }
    }
}

private extension ControllerInputsViewController
{
    func updateActiveCalloutView(with controllerInput: Input?)
    {
        guard let inputMapping = self.inputMappings[self.system] else { return }
        
        guard let activeCalloutView = self.activeCalloutView else { return }
        
        guard let input = self.calloutViews.first(where: { $0.value == activeCalloutView })?.key else { return }

        if let controllerInput,
           let action = ActionInput(input: input)
        {
            if BoundControllerInputMapping.isLeftStickDirection(controllerInput), action.isBoundPanelAction
            {
                self.showMappingFeedback(NSLocalizedString("Use the right thumbstick for view controls.", comment: ""))
                return
            }

            if action == .systemOverlay
            {
                guard let controller = self.gameController as? MFiGameController,
                      controller.physicalHomeInput?.stringValue == controllerInput.stringValue
                else
                {
                    self.showMappingFeedback(NSLocalizedString("Overlay can only be assigned to the Home button.", comment: ""))
                    return
                }
            }
        }
        
        if let controllerInput = controllerInput
        {
            for (_, calloutView) in self.calloutViews
            {
                guard let calloutInput = calloutView.input else { continue }
                
                if calloutInput == controllerInput
                {
                    // Hide callout views that previously displayed the controller input.
                    calloutView.input = nil
                    calloutView.dismissCallout(animated: true)
                }
            }
        }
        
        self.managedObjectContext.performAndWait {
            let isNoneAction = ActionInput(input: input) == Optional(ActionInput.none)

            if !isNoneAction
            {
                for supportedInput in inputMapping.supportedControllerInputs
                {
                    let mappedInput = self.mappedInput(for: supportedInput)

                    if mappedInput == input
                    {
                        // Keep ordinary actions one-to-one. None may be assigned to several physical buttons.
                        inputMapping.set(nil, forControllerInput: supportedInput)
                    }
                }
            }
            
            if let controllerInput = controllerInput
            {
                inputMapping.set(input, forControllerInput: controllerInput)
            }
        }

        if let controller = self.gameController as? MFiGameController
        {
            BoundControllerSystemGestures.apply(to: controller, mapping: inputMapping, capturing: true)
        }
        
        activeCalloutView.input = controllerInput
        
        self.toggle(activeCalloutView)
    }

    func showMappingFeedback(_ message: String)
    {
        let toast = RSTToastView(text: message, detailText: nil)
        toast.show(in: self.navigationController?.view ?? self.view, duration: 2.5)
    }
    
    func toggle(_ calloutView: InputCalloutView)
    {
        if let activeCalloutView = self.activeCalloutView, activeCalloutView != calloutView
        {
            self.toggle(activeCalloutView)
        }
        
        let menuItem: MenuItem?
        
        if let input = self.calloutViews.first(where: { $0.value == calloutView })?.key, let index = self.supportedActionInputs.firstIndex(where: { $0 == input })
        {
            menuItem = self.actionsMenuViewController.items[index]
        }
        else
        {
            menuItem = nil
        }
        
        switch calloutView.state
        {
        case .normal:
            calloutView.state = .listening
            menuItem?.isSelected = true
            self.activeCalloutView = calloutView
            
        case .listening:
            calloutView.state = .normal
            menuItem?.isSelected = false
            self.activeCalloutView = nil
        }
        
        calloutView.dismissCallout(animated: true)
        
        if let presentationRect = self.presentationRect(for: calloutView)
        {
            if calloutView.state == .listening || calloutView.input != nil
            {
                calloutView.presentCallout(from: presentationRect, in: self.view, constrainedTo: self.view, animated: true)
            }
        }
    }
    
    @IBAction func resetInputMapping(_ sender: UIBarButtonItem)
    {
        func reset()
        {
            self.managedObjectContext.perform {
                guard let inputMapping = self.inputMappings[self.system] else { return }
                
                self.managedObjectContext.delete(inputMapping)
                self.inputMappings[self.system] = nil
                
                DispatchQueue.main.async {
                    self.updateSystem()
                }
            }
        }
        
        let alertController = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        alertController.popoverPresentationController?.barButtonItem = sender
        alertController.addAction(.cancel)
        alertController.addAction(UIAlertAction(title: NSLocalizedString("Reset Controls to Defaults", comment: ""), style: .destructive, handler: { (action) in
            reset()
        }))
        self.present(alertController, animated: true, completion: nil)
    }
}

extension ControllerInputsViewController: UIGestureRecognizerDelegate
{
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool
    {
        return self.activeCalloutView != nil
    }
    
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool
    {
        // Necessary to prevent other gestures (e.g. GameViewController's resumeEmulationIfNeeded() tap gesture) from cancelling tap.
        return true
    }
    
    @IBAction private func handleTapGesture(_ tapGestureRecognizer: UITapGestureRecognizer)
    {
        self.updateActiveCalloutView(with: nil)
    }
}

private extension ControllerInputsViewController
{
    func mappedInput(for input: Input) -> AnyInput
    {
        guard let inputMapping = self.inputMappings[self.system] else {
            fatalError("Input mapping for current system does not exist.")
        }
        
        guard let mappedInput = inputMapping.input(forControllerInput: input) else {
            fatalError("Mapped input for provided input does not exist.")
        }
        
        if let standardInput = StandardGameControllerInput(input: mappedInput)
        {
            if let gameInput = standardInput.input(for: self.system.gameType)
            {
                return AnyInput(gameInput)
            }
        }
        
        return AnyInput(mappedInput)
    }
    
    func presentationRect(for calloutView: InputCalloutView) -> CGRect?
    {
        guard let input = self.calloutViews.first(where: { $0.value == calloutView })?.key else { return nil }
        
        guard
            let controllerView = self.gameViewController.controllerView,
            let traits = controllerView.controllerSkinTraits,
            let items = controllerView.controllerSkin?.items(for: traits)
        else { return nil }
        
        if let item = items.first(where: { $0.inputs.allInputs.contains(where: { $0.stringValue == input.stringValue })})
        {
            // Input is a controller skin input.
            
            let itemFrame: CGRect?
            
            switch item.inputs
            {
            case .standard: itemFrame = item.frame
            case .touch: itemFrame = item.frame
            case let .directional(up, down, left, right):
                let frame = (item.kind == .thumbstick) ? item.extendedFrame : item.frame
                
                switch input.stringValue
                {
                case up.stringValue:
                    itemFrame = CGRect(x: frame.minX + frame.width / 3,
                                       y: frame.minY,
                                       width: frame.width / 3,
                                       height: frame.height / 3)
                case down.stringValue:
                    itemFrame = CGRect(x: frame.minX + frame.width / 3,
                                       y: frame.minY + (frame.height / 3) * 2,
                                       width: frame.width / 3,
                                       height: frame.height / 3)
                    
                case left.stringValue:
                    itemFrame = CGRect(x: frame.minX,
                                       y: frame.minY + (frame.height / 3),
                                       width: frame.width / 3,
                                       height: frame.height / 3)
                    
                case right.stringValue:
                    itemFrame = CGRect(x: frame.minX + (frame.width / 3) * 2,
                                       y: frame.minY + (frame.height / 3),
                                       width: frame.width / 3,
                                       height: frame.height / 3)
                    
                default: itemFrame = nil
                }
            }
            
            if let itemFrame = itemFrame
            {
                var presentationFrame = itemFrame.applying(CGAffineTransform(scaleX: controllerView.bounds.width, y: controllerView.bounds.height))
                presentationFrame = self.view.convert(presentationFrame, from: controllerView)
                
                return presentationFrame
            }
        }
        else if let index = self.supportedActionInputs.firstIndex(where: { $0 == input })
        {
            // Input is an ActionInput.
            
            let indexPath = IndexPath(item: index, section: 0)
            
            if let attributes = self.actionsMenuViewController.collectionViewLayout.layoutAttributesForItem(at: indexPath)
            {
                let presentationFrame = self.view.convert(attributes.frame, from: self.actionsMenuViewController.view)
                return presentationFrame
            }
        }
        else
        {
            // Input is not an on-screen input.
        }
        
        return nil
    }
}

extension ControllerInputsViewController: GameControllerReceiver
{
    func gameController(_ gameController: GameController, didActivate controllerInput: DeltaCore.Input, value: Double)
    {
        guard self.isViewLoaded, value > 0.9 else { return }
        
        switch gameController
        {
        case self.gameViewController.controllerView:
            if let calloutView = self.calloutViews[AnyInput(controllerInput)]
            {
                if controllerInput.isContinuous
                {
                    // Make sure we only toggle calloutView once in a single gesture.
                    guard calloutView.state == .normal else { break }
                }
                
                self.toggle(calloutView)
            }
            
        case self.gameController: self.updateActiveCalloutView(with: controllerInput)
            
        default: break
        }
    }
    
    func gameController(_ gameController: GameController, didDeactivate input: DeltaCore.Input)
    {
    }
}

extension ControllerInputsViewController: SMCalloutViewDelegate
{
    func calloutViewClicked(_ calloutView: SMCalloutView)
    {
        guard let calloutView = calloutView as? InputCalloutView else { return }

        self.toggle(calloutView)
    }
}

extension ControllerInputsViewController: UIAdaptivePresentationControllerDelegate
{
    func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle
    {
        switch (traitCollection.horizontalSizeClass, traitCollection.verticalSizeClass)
        {
        case (.regular, .regular): return .formSheet // Regular width and height, so display as form sheet
        default: return .fullScreen // Compact width and/or height, so display full screen
        }
    }
}
