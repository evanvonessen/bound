//
//  SaveStatesViewController.swift
//  Delta
//
//  Created by Riley Testut on 1/23/16.
//  Copyright © 2016 Riley Testut. All rights reserved.
//

import UIKit
import CoreData
import UniformTypeIdentifiers

import DeltaCore
import MelonDSDeltaCore
import Roxas

protocol SaveStatesViewControllerDelegate: AnyObject
{
    func saveStatesViewController(_ saveStatesViewController: SaveStatesViewController, updateSaveState saveState: SaveState)
    func saveStatesViewController(_ saveStatesViewController: SaveStatesViewController, loadSaveState saveState: SaveStateProtocol)
}

/// Retain preview-commit files until the loading owner has consumed the state.
private final class TemporaryPreviewSaveState: SaveStateProtocol
{
    let fileURL: URL
    let gameType: GameType

    init(_ saveState: SaveStateProtocol)
    {
        self.fileURL = saveState.fileURL
        self.gameType = saveState.gameType
    }

    deinit
    {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

extension SaveStatesViewController
{
    enum Mode
    {
        case saving
        case loading
    }
    
    enum Section: Int
    {
        case info // No content, just a header
        case auto
        case quick
        case general
        case locked
        
        var localizedName: String {
            switch self
            {
            case .info: return NSLocalizedString("Info", comment: "")
            case .auto: return NSLocalizedString("Auto Save", comment: "")
            case .quick: return NSLocalizedString("Quick Save", comment: "")
            case .general: return NSLocalizedString("General", comment: "")
            case .locked: return NSLocalizedString("Locked", comment: "")
            }
        }
    }
    
    enum Sorting: String, CaseIterable
    {
        case name
        case date
        
        public var localizedName: String {
            switch self
            {
            case .name: return NSLocalizedString("Name", comment: "")
            case .date: return NSLocalizedString("Date", comment: "")
            }
        }
    }
    
    enum Filter: String, CaseIterable
    {
        case compatible
        case incompatible
        
        public var localizedName: String {
            switch self
            {
            case .compatible: return NSLocalizedString("Compatible", comment: "")
            case .incompatible: return NSLocalizedString("Incompatible", comment: "")
            }
        }
    }
}

class SaveStatesViewController: UICollectionViewController
{
    private struct SaveAccess {
        let gameID: String
        let revision: UUID?
        init?(gameID: String) {
            self.gameID = gameID
            guard !BoundROMUpdateStorage.live.hasPendingSaveClear(gameID: gameID) else { return nil }
            do { revision = try BoundROMUpdateStorage.live.saveClearRevision(gameID: gameID) }
            catch { return nil }
        }
        var isCurrent: Bool {
            let storage = BoundROMUpdateStorage.live
            guard !storage.hasPendingSaveClear(gameID: gameID) else { return false }
            do { return try storage.saveClearRevision(gameID: gameID) == revision }
            catch { return false }
        }
    }
    private var saveAccess: SaveAccess?
    private var emulatorSaveAccess: SaveAccess?
    private var saveClearInvalidated = false
    private var mayAccessSaves: Bool { game?.boundUsesServerMultiplayer != true && !saveClearInvalidated && saveAccess?.isCurrent == true }

    var game: Game! {
        didSet {
            self.saveAccess = game.flatMap { SaveAccess(gameID: $0.identifier) }
            self.saveClearInvalidated = false
            self.updateDataSource()
        }
    }
    
    // Reference to a current EmulatorCore. emulatorCore.game does _not_ have to match self.game
    var emulatorCore: EmulatorCore? {
        didSet { emulatorSaveAccess = (emulatorCore?.game as? Game).flatMap { SaveAccess(gameID: $0.identifier) } }
    }
    
    weak var delegate: SaveStatesViewControllerDelegate?
    
    var mode = Mode.loading
    
    var theme = Theme.translucent {
        didSet {
            if self.isViewLoaded
            {
                self.update()
            }
        }
    }
    
    private var preferredSorting: Sorting = UserDefaults.standard.preferredSaveStatesSorting {
        didSet {
            UserDefaults.standard.preferredSaveStatesSorting = self.preferredSorting
        }
    }
    
    private var prefersDescendingSorting: Bool = UserDefaults.standard.prefersDescendingSaveStatesSorting {
        didSet {
            UserDefaults.standard.prefersDescendingSaveStatesSorting = self.prefersDescendingSorting
        }
    }
    
    private var filter: Filter = .compatible
        
    private var vibrancyView: UIVisualEffectView!
    private var placeholderView: RSTPlaceholderView!
    
    private var prototypeCell = GridCollectionViewCell()
    private var prototypeHeader = SaveStatesCollectionHeaderView()
    private var prototypeCellWidthConstraint: NSLayoutConstraint!
    private var prototypeHeaderWidthConstraint: NSLayoutConstraint!
    
    private var incompatibleSaveStatesCount: Int = 0
    private var incompatibleLabel: UILabel!
    private var incompatibleButton: UIButton!
    
    private weak var _previewTransitionViewController: PreviewGameViewController?
    private var activePreviewViewController: PreviewGameViewController?
    private weak var _importingSaveState: SaveState?
    private var _exportedSaveStateURL: URL?
    
    private let dataSource: RSTCompositeCollectionViewPrefetchingDataSource<SaveState, UIImage>
    private let infoDataSource: RSTDynamicCollectionViewPrefetchingDataSource<SaveState, UIImage>
    private let fetchedDataSource: RSTFetchedResultsCollectionViewPrefetchingDataSource<SaveState, UIImage>
    
    private var emulatorCoreSaveState: SaveStateProtocol?
    
    @IBOutlet private var optionsButton: UIBarButtonItem!

    private var selectionCountItem: UIBarButtonItem?
    private var deleteSelectionItem: UIBarButtonItem?
    
    required init?(coder aDecoder: NSCoder)
    {
        let fetchedDataSource = RSTFetchedResultsCollectionViewPrefetchingDataSource<SaveState, UIImage>(fetchedResultsController: NSFetchedResultsController())
        let infoDataSource = RSTDynamicCollectionViewPrefetchingDataSource<SaveState, UIImage>()
        
        self.dataSource = RSTCompositeCollectionViewPrefetchingDataSource<SaveState, UIImage>(dataSources: [infoDataSource, fetchedDataSource])
        self.infoDataSource = infoDataSource
        self.fetchedDataSource = fetchedDataSource
        
        super.init(coder: aDecoder)
        
        self.prepareDataSource()
        NotificationCenter.default.addObserver(self, selector: #selector(saveClearBegan(_:)),
            name: BoundROMUpdateManager.saveClearBegan, object: nil)
    }

    @objc private func saveClearBegan(_ notification: Notification) {
        guard let gameID = notification.object as? String else { return }
        let selected = game?.identifier == gameID
        let retainedCore = (emulatorCore?.game as? Game)?.identifier == gameID
        guard selected || retainedCore else { return }
        if selected {
            saveClearInvalidated = true
            activePreviewViewController?.stopPreview()
            _previewTransitionViewController = nil
            activePreviewViewController = nil
            _importingSaveState = nil
            delegate = nil
        }
        if retainedCore { emulatorCore?.stop(); emulatorCore = nil }
        // Viewing another ROM's saves can temporarily retain an unrelated core.
        // Only the cleared ROM is discarded; restore an unrelated paused core.
        resetEmulatorCoreIfNeeded()
        if selected { emulatorCore = nil }
        guard selected, isViewLoaded else { return }
        view.isUserInteractionEnabled = false
        if let presenter = navigationController?.presentingViewController ?? presentingViewController {
            presenter.dismiss(animated: false)
        } else {
            navigationController?.popViewController(animated: false)
        }
    }
}

extension SaveStatesViewController: NSFetchedResultsControllerDelegate
{
    func controllerDidChangeContent(_ controller: NSFetchedResultsController<NSFetchRequestResult>)
    {
        // Roxas schedules a second batch after moved items finish animating. Renaming
        // or updating an autosave can leave that batch pending after this screen is
        // dismissed and its data source is gone. Refresh this list without batching.
        self.dataSource.prefetchItemCache.removeAllObjects()
        guard self.isViewLoaded else { return }
        self.collectionView?.reloadData()
        self.updateToolbarState()
    }
}

extension SaveStatesViewController
{
    override func viewDidLoad()
    {
        super.viewDidLoad()
        self.collectionView.accessibilityIdentifier = "bound.save-states"
        
        self.collectionView?.dataSource = self.dataSource
        self.collectionView?.prefetchDataSource = self.dataSource
        
        switch self.mode
        {
        case .saving:
            self.title = NSLocalizedString("Save State", comment: "")
            self.placeholderView.detailTextLabel.text = NSLocalizedString("Create a new save state by pressing the + button in the top right.", comment: "")
            
        case .loading:
            self.title = NSLocalizedString("Load State", comment: "")
            self.placeholderView.detailTextLabel.text = NSLocalizedString("Create a new save state by pressing the Save State option in the pause menu.", comment: "")
            self.navigationItem.rightBarButtonItems?.removeFirst()
        }
        
        if #available(iOS 26, *)
        {
            self.optionsButton.image = UIImage(systemName: "ellipsis")
        }

        self.collectionView.allowsMultipleSelectionDuringEditing = true

        var rightBarButtonItems = self.navigationItem.rightBarButtonItems ?? []
        rightBarButtonItems.insert(self.editButtonItem, at: 0)
        self.navigationItem.rightBarButtonItems = rightBarButtonItems

        self.prototypeCellWidthConstraint = self.prototypeCell.contentView.widthAnchor.constraint(equalToConstant: 0)
        self.prototypeCellWidthConstraint.isActive = true
        
        self.prototypeHeaderWidthConstraint = self.prototypeHeader.widthAnchor.constraint(equalToConstant: 0)
        self.prototypeHeaderWidthConstraint.isActive = true
        
        self.prepareEmulatorCoreSaveState()
    }
    
    override func viewWillAppear(_ animated: Bool) 
    {
        super.viewWillAppear(animated)
        
        let predicate = self.makePredicate(filter: .incompatible)
        let saveStates = SaveState.instancesWithPredicate(predicate, inManagedObjectContext: DatabaseManager.shared.viewContext, type: SaveState.self)
        self.incompatibleSaveStatesCount = saveStates.count
        
        self.prepareOptionsMenu()
    }
    
    override func viewIsAppearing(_ animated: Bool) 
    {
        super.viewIsAppearing(animated)
        
        self.update()
    }
    
    override func viewDidAppear(_ animated: Bool) 
    {
        super.viewDidAppear(animated)
        
        if let core = Delta.core(for: self.game.type), core == MelonDS.core, self.incompatibleSaveStatesCount > 0, !UserDefaults.standard.showedIncompatibleDSSaveStatesAlert
        {
            let alertController = UIAlertController(title: NSLocalizedString("Incompatible Save States", comment: ""),
                                                    message: NSLocalizedString("This version of Delta is not compatible with previous Nintendo DS save states.\n\nYou can find previous save states by pressing “View Incompatible Save States” in the options menu.", comment: ""),
                                                    preferredStyle: .alert)
            alertController.addAction(.ok)
            self.present(alertController, animated: true)
            
            UserDefaults.standard.showedIncompatibleDSSaveStatesAlert = true
        }
    }
    
    override func viewWillDisappear(_ animated: Bool)
    {
        super.viewWillDisappear(animated)
        
        if self.isEditing { self.setEditing(false, animated: false) }

        self.withStoppedPreview {
            self.resetEmulatorCoreIfNeeded()
        }
    }
    
    override func viewWillTransition(to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator) 
    {
        super.viewWillTransition(to: size, with: coordinator)
        
        coordinator.animate { context in
            UIView.performWithoutAnimation {
                self.update()
                self.collectionView.reloadData()
            }
        }
    }

    override func didReceiveMemoryWarning()
    {
        super.didReceiveMemoryWarning()
    }
}

private extension SaveStatesViewController
{
    func prepareDataSource()
    {
        self.dataSource.proxy = self
        
        self.vibrancyView = UIVisualEffectView(effect: nil)
        
        self.placeholderView = RSTPlaceholderView(frame: CGRect(x: 0, y: 0, width: self.vibrancyView.bounds.width, height: self.vibrancyView.bounds.height))
        self.placeholderView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.placeholderView.stackView.distribution = .fill
        self.placeholderView.textLabel.text = NSLocalizedString("No Save States", comment: "")
        self.placeholderView.textLabel.textColor = UIColor.white
        self.placeholderView.detailTextLabel.textColor = UIColor.white
        
        self.incompatibleLabel = UILabel()
        self.incompatibleLabel.isHidden = true
        self.incompatibleLabel.font = self.placeholderView.detailTextLabel.font
        self.incompatibleLabel.textColor = .white
        self.incompatibleLabel.numberOfLines = 0
        self.incompatibleLabel.text = NSLocalizedString("You have save states that are incompatible with this version of Delta.", comment: "")
        self.placeholderView.stackView.addArrangedSubview(self.incompatibleLabel)
        self.placeholderView.stackView.setCustomSpacing(30, after: self.placeholderView.detailTextLabel)
        self.vibrancyView.contentView.addSubview(self.placeholderView)
        
        self.incompatibleButton = UIButton(type: .system, primaryAction: UIAction(title: NSLocalizedString("View Incompatible Save States", comment: "")) { [weak self] _ in
            self?.showIncompatibleSaveStates()
        })
        self.incompatibleButton.isHidden = true
        self.incompatibleButton.translatesAutoresizingMaskIntoConstraints = false
        self.incompatibleButton.titleLabel?.font = UIFont.preferredFont(forTextStyle: .headline)
        self.incompatibleButton.tintColor = .deltaPurple
        
        // Add button outside vibrancy view to ensure it retains tint color.
        let placeholderView = UIView()
        placeholderView.addSubview(self.vibrancyView, pinningEdgesWith: .zero)
        placeholderView.addSubview(incompatibleButton)
        self.dataSource.placeholderView = placeholderView
        
        NSLayoutConstraint.activate([
            self.incompatibleButton.centerXAnchor.constraint(equalTo: placeholderView.centerXAnchor),
            self.incompatibleButton.topAnchor.constraint(equalTo: self.incompatibleLabel.bottomAnchor, constant: 15)
        ])
        
        self.infoDataSource.numberOfSectionsHandler = { [weak self] in
            // Info section is only visible when viewing incompatible save states.
            switch self?.filter
            {
            case .incompatible: return 1
            case .compatible, nil: return 0
            }
        }
        self.infoDataSource.numberOfItemsHandler = { _ in 0 }
        
        self.dataSource.cellConfigurationHandler = { [unowned self] (cell, item, indexPath) in
            self.configure(cell as! GridCollectionViewCell, for: indexPath)
        }
        
        self.dataSource.prefetchHandler = { [unowned self] (saveState, indexPath, completionHandler) in
            let imageOperation = LoadImageURLOperation(url: saveState.imageFileURL)
            imageOperation.resultHandler = { (image, error) in
                completionHandler(image, error)
            }
                        
            if self.isAppearing
            {
                imageOperation.start()
                imageOperation.waitUntilFinished()
                return nil
            }
            
            return imageOperation
        }
        
        self.dataSource.prefetchCompletionHandler = { (cell, image, indexPath, error) in
            guard let image = image, let cell = cell as? GridCollectionViewCell else { return }
            
            cell.imageView.backgroundColor = nil
            cell.imageView.image = image
            
            cell.isImageViewVibrancyEnabled = false
        }
    }
    
    func prepareOptionsMenu()
    {
        let sortActionsProvider: (([UIMenuElement]) -> Void) -> Void = { [weak self] completion in
            guard let self else { return completion([]) }
            
            let actions = Sorting.allCases.map { sorting in
                let state: UIMenuElement.State = (sorting == self.preferredSorting) ? .on : .off
                
                let icon: UIImage?
                if state == .on
                {
                    // Only show chevron for active sorting.
                    icon = self.prefersDescendingSorting ? UIImage(symbolNameIfAvailable: "chevron.down") : UIImage(symbolNameIfAvailable: "chevron.up")
                }
                else
                {
                    icon = nil
                }
                
                let action = UIAction(title: sorting.localizedName, image: icon, state: state) { action in
                    self.preferredSorting = sorting
                    
                    if state == .on
                    {
                        // Previously enabled, so toggle sorting direction.
                        self.prefersDescendingSorting.toggle()
                    }
                    else
                    {
                        // New, so reset sorting direction to ascending.
                        self.prefersDescendingSorting = false
                    }
                    
                    UIView.transition(with: self.collectionView, duration: 0.4, options: .transitionCrossDissolve, animations: {
                        self.updateDataSource()
                    }, completion: nil)
                }
                
                return action
            }
            
            completion(actions)
        }
        
        let filterActionsProvider: (([UIMenuElement]) -> Void) -> Void = { [weak self] completion in
            guard let self else { return completion([]) }
            
            let action: UIAction
            switch self.filter
            {
            case .compatible:
                action = UIAction(title: NSLocalizedString("View Incompatible Save States", comment: ""), image: UIImage(systemName: "x.circle")) { _ in
                    self.showIncompatibleSaveStates()
                }
                
            case .incompatible:
                action = UIAction(title: NSLocalizedString("View Compatible Save States", comment: ""), image: UIImage(systemName: "checkmark.circle")) { _ in
                    self.showCompatibleSaveStates()
                }
            }
            
            completion([action])
        }
        
        let sortActions: UIDeferredMenuElement
        let filterActions: UIDeferredMenuElement
        let menuOptions: UIMenu.Options
        
        if #available(iOS 15, *)
        {
            sortActions = UIDeferredMenuElement.uncached(sortActionsProvider)
            filterActions = UIDeferredMenuElement.uncached(filterActionsProvider)
            menuOptions = [.singleSelection, .displayInline]
        }
        else
        {
            sortActions = UIDeferredMenuElement(sortActionsProvider)
            filterActions = UIDeferredMenuElement(filterActionsProvider)
            menuOptions = [.displayInline]
        }
        
        let sortMenu = UIMenu(title: NSLocalizedString("Sort by…", comment: ""), options: menuOptions, children: [sortActions])
        var allMenus = [sortMenu]
        
        if self.incompatibleSaveStatesCount > 0
        {
            // There is at least one incompatible save state, so show the filter menu.
            let filterMenu = UIMenu(title: "", options: menuOptions, children: [filterActions])
            allMenus.append(filterMenu)
        }
        
        let optionsMenu = UIMenu(children: allMenus)
        self.optionsButton.menu = optionsMenu
    }
    
    @objc private func deleteSelectedSaveStates()
    {
        guard mayAccessSaves, let access = saveAccess else { return }
        let indexPaths = self.collectionView.indexPathsForSelectedItems ?? []
        guard !indexPaths.isEmpty else { return }

        let objectIDs = indexPaths.map { self.dataSource.item(at: $0).objectID }
        let count = objectIDs.count

        let title = count == 1
            ? NSLocalizedString("Delete Save State?", comment: "")
            : String(format: NSLocalizedString("Delete %d Save States?", comment: ""), count)
        let message = count == 1
            ? NSLocalizedString("Are you sure you want to delete this save state? This cannot be undone.", comment: "")
            : String(format: NSLocalizedString("Are you sure you want to delete %d save states? This cannot be undone.", comment: ""), count)

        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: NSLocalizedString("Delete", comment: ""), style: .destructive) { [weak self] _ in
            guard let self, self.mayAccessSaves else { return }

            DatabaseManager.shared.performBackgroundTask { context in
                guard access.isCurrent else { return }
                for objectID in objectIDs {
                    guard let object = try? context.existingObject(with: objectID) else { continue }
                    context.delete(object)
                }
                guard access.isCurrent else { context.rollback(); return }
                context.saveWithErrorLogging()
            }

            self.setEditing(false, animated: true)
        })
        alert.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel))

        self.present(alert, animated: true)
    }

    private func updateToolbarState()
    {
        let count = self.collectionView.indexPathsForSelectedItems?.count ?? 0
        self.selectionCountItem?.title = count == 1
            ? NSLocalizedString("1 Selected", comment: "")
            : String(format: NSLocalizedString("%d Selected", comment: ""), count)

        self.deleteSelectionItem?.isEnabled = count > 0
    }
}

private extension SaveStatesViewController
{
    //MARK: - Update -
    func updateDataSource()
    {
        let fetchRequest: NSFetchRequest<SaveState> = SaveState.fetchRequest()
        fetchRequest.returnsObjectsAsFaults = false
        
        var sortDescriptors = [NSSortDescriptor(key: #keyPath(SaveState.type), ascending: true)]
        switch self.preferredSorting
        {
        case .name:
            sortDescriptors += [NSSortDescriptor(key: #keyPath(SaveState.name), ascending: !self.prefersDescendingSorting),
                                NSSortDescriptor(key: #keyPath(SaveState.creationDate), ascending: true)]
        case .date:
            sortDescriptors += [NSSortDescriptor(key: #keyPath(SaveState.creationDate), ascending: !self.prefersDescendingSorting),
                                NSSortDescriptor(key: #keyPath(SaveState.name), ascending: true)]
        }
        fetchRequest.sortDescriptors = sortDescriptors
        
        let predicate = self.makePredicate(filter: self.filter)
        fetchRequest.predicate = predicate
        
        let controller = NSFetchedResultsController(fetchRequest: fetchRequest, managedObjectContext: DatabaseManager.shared.viewContext, sectionNameKeyPath: #keyPath(SaveState.type), cacheName: nil)
        controller.delegate = self
        self.fetchedDataSource.fetchedResultsController = controller
    }
    
    func makePredicate(filter: Filter) -> NSPredicate
    {
        if let system = System(gameType: self.game.type)
        {
            let predicate = NSPredicate(format: "%K == %@ AND %K == %@", #keyPath(SaveState.game), self.game, #keyPath(SaveState.coreIdentifier), system.deltaCore.identifier)
            
            if let version = system.deltaCore.version
            {
                let filterPredicate: NSPredicate
                switch filter
                {
                case .compatible: filterPredicate = NSPredicate(format: "%K == %@", #keyPath(SaveState.coreVersion), version)
                case .incompatible: filterPredicate = NSPredicate(format: "%K == nil OR %K != %@", #keyPath(SaveState.coreVersion), #keyPath(SaveState.coreVersion), version)
                }
                
                let compoundPredicate = NSCompoundPredicate(andPredicateWithSubpredicates: [predicate, filterPredicate])
                return compoundPredicate
            }
            else
            {
                switch filter
                {
                case .compatible:
                    // DeltaCore has no version, so fall back to showing all save states.
                    return predicate
                    
                case .incompatible:
                    // DeltaCore has no version, so there can't be any incompatible save states.
                    return NSPredicate(value: false)
                }
            }
        }
        else
        {
            switch filter
            {
            case .compatible:
                let predicate = NSPredicate(format: "%K == %@", #keyPath(SaveState.game), self.game)
                return predicate
                
            case .incompatible:
                // Don't show any incompatible save states for unrecognized systems.
                return NSPredicate(value: false)
            }
        }
    }
    
    func update()
    {
        switch self.theme
        {
        case .opaque:
            self.view.backgroundColor = UIColor.deltaDarkGray
            
            self.vibrancyView.effect = nil
            
            self.placeholderView.textLabel.textColor = UIColor.gray
            self.placeholderView.detailTextLabel.textColor = UIColor.gray
            self.incompatibleLabel.textColor = .gray
            
        case .translucent:
            self.view.backgroundColor = nil
            
            if #unavailable(iOS 26)
            {
                self.vibrancyView.effect = UIVibrancyEffect(blurEffect: UIBlurEffect(style: .dark))
            }
            
            self.placeholderView.textLabel.textColor = UIColor.white
            self.placeholderView.detailTextLabel.textColor = UIColor.white
            self.incompatibleLabel.textColor = .white
        }
        
        if self.incompatibleSaveStatesCount > 0 && self.filter == .compatible
        {
            if self.incompatibleSaveStatesCount == 1
            {
                self.incompatibleLabel.text = NSLocalizedString("You have 1 save state that is incompatible with this version of Delta.", comment: "")
            }
            else
            {
                self.incompatibleLabel.text = String(format: NSLocalizedString("You have %@ save states that are incompatible with this version of Delta.", comment: ""), NSNumber(value: self.incompatibleSaveStatesCount))
            }
            
            self.incompatibleLabel.isHidden = false
            self.incompatibleButton.isHidden = false
        }
        else
        {
            self.incompatibleLabel.isHidden = true
            self.incompatibleButton.isHidden = true
        }
                
        let collectionViewLayout = self.collectionViewLayout as! GridCollectionViewLayout
        
        if self.traitCollection.horizontalSizeClass == .regular
        {
            collectionViewLayout.itemWidth = 180
            collectionViewLayout.minimumInteritemSpacing = 30
        }
        else
        {
            //FIXME: Calculate actual values so resizing results in correct thumbnail size
            let averageHorizontalInset = 20.0
            
            var portraitWindowWidth = UIScreen.main.coordinateSpace.convert(UIScreen.main.bounds, to: UIScreen.main.fixedCoordinateSpace).width
            
            if let window = self.view.window
            {
                if window.bounds.height > window.bounds.width
                {
                    // Portrait window
                    portraitWindowWidth = window.bounds.width
                }
                else
                {
                    // Landscape window
                    portraitWindowWidth = window.bounds.height
                }
            }
            
            // Use dimensions that allow two cells to fill the screen horizontally with padding in portrait mode
            // We'll keep the same size for landscape orientation, which will allow more to fit
            let value = (portraitWindowWidth - (averageHorizontalInset * 3)) / 2
            collectionViewLayout.itemWidth = floor(value)
        }
        
        // Manually update prototype cell properties
        self.prototypeCellWidthConstraint.constant = collectionViewLayout.itemWidth
        self.prototypeHeaderWidthConstraint.constant = self.collectionView.bounds.width - (self.collectionView.contentInset.left + self.collectionView.contentInset.right)
    }
    
    //MARK: - Configure Views -
    
    func configure(_ cell: GridCollectionViewCell, for indexPath: IndexPath)
    {
        let saveState = self.dataSource.item(at: indexPath)
        cell.accessibilityIdentifier = "bound.save-state." + saveState.identifier
        
        cell.imageView.backgroundColor = UIColor.white
        cell.imageView.image = UIImage(named: "DeltaPlaceholder")
        
        switch self.theme
        {
        case .opaque:
            cell.textLabel.textColor = .gray
            
            if #available(iOS 26, *)
            {
                cell.isImageViewGlassEnabled = true
            }
            else
            {
                cell.isImageViewVibrancyEnabled = false
            }
            
            cell.isTextLabelVibrancyEnabled = false
            
        case .translucent:
            if #available(iOS 26, *)
            {
                cell.textLabel.textColor = .white
                
                cell.isImageViewGlassEnabled = true
                cell.isTextLabelVibrancyEnabled = false
            }
            else
            {
                cell.textLabel.textColor = .gray
                
                cell.isImageViewVibrancyEnabled = true
                cell.isTextLabelVibrancyEnabled = true
            }
        }
        
        let dimensions: CGSize
        if let deltaCore = Delta.core(for: self.game.type)
        {
            dimensions = deltaCore.videoFormat.dimensions
        }
        else
        {
            dimensions = CGSize(width: 1, height: 1)
        }
                
        cell.maximumImageSize = CGSize(width: self.prototypeCellWidthConstraint.constant, height: (self.prototypeCellWidthConstraint.constant / dimensions.width) * dimensions.height)
        
        let fontDescriptor = UIFontDescriptor.preferredFontDescriptor(withTextStyle: .subheadline).withSymbolicTraits(.traitBold)!
        cell.textLabel.font = UIFont(descriptor: fontDescriptor, size: 0.0)
        cell.textLabel.text = saveState.localizedName

        let section = self.correctedSectionForSectionIndex(indexPath.section)
        cell.isInSelectionMode = self.isEditing && section != .auto && section != .info && section != .locked
    }
    
    func configure(_ headerView: SaveStatesCollectionHeaderView, forSection section: Int)
    {
        let section = self.correctedSectionForSectionIndex(section)
        switch section
        {
        case .info:
            let attributedText = NSMutableAttributedString(string: NSLocalizedString("These save states are incompatible with this version of Delta. You can export them to continue playing in Delta Legacy.", comment: ""), attributes: [.font: UIFont.preferredFont(forTextStyle: .body), .foregroundColor: UIColor.lightGray])
            attributedText.mutableString.append("\n\n")
            
            let learnMoreLink = NSAttributedString(string: NSLocalizedString("Learn More…", comment: ""), attributes: [.link: URL(string: "https://deltaemulator.com/legacy")!,
                                                                                                                       .font: UIFont.preferredFont(forTextStyle: .body)])
            attributedText.append(learnMoreLink)
            
            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.lineBreakMode = .byWordWrapping
            paragraphStyle.alignment = .center
            attributedText.addAttribute(.paragraphStyle, value: paragraphStyle, range: NSMakeRange(0, attributedText.length))
            
            headerView.textView.attributedText = attributedText
            headerView.textView.tintColor = .deltaPurple
            headerView.isTextVibrancyEnabled = false
            
        case .auto, .quick, .general, .locked:
            headerView.textView.text = section.localizedName
            
            switch self.theme
            {
            case .opaque:
                headerView.textView.textColor = UIColor.lightGray
                headerView.isTextVibrancyEnabled = false
                
            case .translucent:
                headerView.textView.textColor = UIColor.white
                
                if #available(iOS 26, *)
                {
                    headerView.isTextVibrancyEnabled = false
                }
                else
                {
                    headerView.isTextVibrancyEnabled = true
                }
            }
        }
    }
    
    //MARK: - Save States -
    
    @IBAction func addSaveState()
    {
        guard mayAccessSaves else { return }
        var saveState: SaveState!
        
        let backgroundContext = DatabaseManager.shared.newBackgroundContext()
        backgroundContext.performAndWait {
            
            let game = backgroundContext.object(with: self.game.objectID) as! Game
            
            saveState = SaveState.insertIntoManagedObjectContext(backgroundContext)
            saveState.type = .general
            saveState.game = game
        }
        
        self.updateSaveState(saveState)
    }
    
    func updateSaveState(_ saveState: SaveState)
    {
        guard mayAccessSaves, let access = saveAccess else { return }
        let context = saveState.managedObjectContext
        self.withStoppedPreview {
            self.prepareEmulatorCore()
            context?.performAndWait {
                guard access.isCurrent, !saveState.isDeleted, saveState.game?.identifier == access.gameID else { return }
                self.delegate?.saveStatesViewController(self, updateSaveState: saveState)
                context?.saveWithErrorLogging()
            }
        }
    }
    
    func loadSaveState(_ saveState: SaveStateProtocol)
    {
        guard mayAccessSaves else { return }
        if let state = saveState as? SaveState, state.isDeleted || state.game?.identifier != game?.identifier { return }
        self.withStoppedPreview {
            self.prepareEmulatorCore()
            self.delegate?.saveStatesViewController(self, loadSaveState: saveState)
        }
        
        // Implicit assumption that loadSaveState will always result in SaveStatesViewController being dismissed
        // Mostly because the method used in updateSaveState(_:) to detect this doesn't work for peek/pop, and too lazy to care rn
    }
    
    func deleteSaveState(_ saveState: SaveState)
    {
        guard mayAccessSaves, let access = saveAccess, !saveState.isDeleted else { return }
        let objectID = saveState.objectID
        let confirmationAlertController = UIAlertController(title: NSLocalizedString("Delete Save State?", comment: ""), message: NSLocalizedString("Are you sure you want to delete this save state? This cannot be undone.", comment: ""), preferredStyle: .alert)
        confirmationAlertController.addAction(UIAlertAction(title: NSLocalizedString("Delete", comment: ""), style: .destructive, handler: { action in
            
            DatabaseManager.shared.performBackgroundTask { (context) in
                guard access.isCurrent, let temporarySaveState = try? context.existingObject(with: objectID) else { return }
                context.delete(temporarySaveState)
                guard access.isCurrent else { context.rollback(); return }
                context.saveWithErrorLogging()
            }
            
        }))
        confirmationAlertController.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel, handler: nil))
        
        self.present(confirmationAlertController, animated: true, completion: nil)
    }
    
    func renameSaveState(_ saveState: SaveState)
    {
        guard mayAccessSaves, !saveState.isDeleted else { return }
        self.withStoppedPreview {
            self.presentRenameSaveState(saveState)
        }
    }

    func presentRenameSaveState(_ saveState: SaveState)
    {
        guard mayAccessSaves, !saveState.isDeleted else { return }
        let alertController = UIAlertController(title: NSLocalizedString("Rename Save State", comment: ""), message: nil, preferredStyle: .alert)
        alertController.addTextField { (textField) in
            textField.text = saveState.name
            textField.placeholder = NSLocalizedString("Name", comment: "")
            textField.autocapitalizationType = .words
            textField.returnKeyType = .done
        }
        alertController.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel, handler: nil))
        alertController.addAction(UIAlertAction(title: NSLocalizedString("Rename", comment: ""), style: .default, handler: { [unowned alertController] (action) in
            self.rename(saveState, with: alertController.textFields?.first?.text)
        }))
        self.present(alertController, animated: true, completion: nil)
    }
    
    func rename(_ saveState: SaveState, with name: String?)
    {
        guard mayAccessSaves, let access = saveAccess, !saveState.isDeleted else { return }
        var name = name
        if (name ?? "").count == 0
        {
            // When text is nil, we know to show the timestamp instead
            name = nil
        }
        
        let objectID = saveState.objectID
        DatabaseManager.shared.performBackgroundTask { (context) in
            guard access.isCurrent, let saveState = try? context.existingObject(with: objectID) as? SaveState else { return }
            saveState.name = name
            guard access.isCurrent else { context.rollback(); return }
            context.saveWithErrorLogging()
        }
    }
    
    func updatePreviewSaveState(_ saveState: SaveState?)
    {
        guard mayAccessSaves, let access = saveAccess else { return }
        let message: String
        
        if #available(iOS 13, *)
        {
            message = NSLocalizedString("The Preview Save State is loaded whenever you long press this game from the Main Menu. Are you sure you want to change it?", comment: "")
        }
        else
        {
            message = NSLocalizedString("The Preview Save State is loaded whenever you 3D Touch this game from the Main Menu. Are you sure you want to change it?", comment: "")
        }
        
        let alertController = UIAlertController(title: NSLocalizedString("Change Preview Save State?", comment: ""), message: message, preferredStyle: .alert)
        alertController.addAction(UIAlertAction(title: NSLocalizedString("Cancel", comment: ""), style: .cancel, handler: nil))
        alertController.addAction(UIAlertAction(title: NSLocalizedString("Change", comment: ""), style: .default, handler: { (action) in
            
            DatabaseManager.shared.performBackgroundTask { (context) in
                guard access.isCurrent, let game = try? context.existingObject(with: self.game.objectID) as? Game else { return }
                
                if let saveState = saveState
                {
                    guard let previewSaveState = try? context.existingObject(with: saveState.objectID) as? SaveState else { return }
                    game.previewSaveState = previewSaveState
                }
                else
                {
                    game.previewSaveState = nil
                }
                
                guard access.isCurrent else { context.rollback(); return }
                context.saveWithErrorLogging()
            }
        }))
        
        self.present(alertController, animated: true, completion: nil)
    }
    
    func lockSaveState(_ saveState: SaveState)
    {
        self.setSaveState(saveState, locked: true)
    }
    
    func unlockSaveState(_ saveState: SaveState)
    {
        self.setSaveState(saveState, locked: false)
    }

    func setSaveState(_ saveState: SaveState, locked: Bool)
    {
        guard mayAccessSaves, let access = saveAccess, !saveState.isDeleted else { return }
        let objectID = saveState.objectID
        self.withStoppedPreview {
            let backgroundContext = DatabaseManager.shared.newBackgroundContext()
            backgroundContext.performAndWait {
                guard access.isCurrent, let temporarySaveState = try? backgroundContext.existingObject(with: objectID) as? SaveState else { return }
                temporarySaveState.type = locked ? .locked : .general
                backgroundContext.saveWithErrorLogging()
            }
        }
    }
    
    func importSaveState(_ saveState: SaveState)
    {
        guard mayAccessSaves, !saveState.isDeleted else { return }
        self._importingSaveState = saveState
        
        let importController = ImportController(documentTypes: [UTType.item.identifier])
        importController.delegate = self
        self.present(importController, animated: true, completion: nil)
    }
    
    func importSaveState(_ saveState: SaveState, from fileURL: URL, error: Error?)
    {
        guard mayAccessSaves, !saveState.isDeleted, saveState.game?.identifier == game?.identifier else { return }
        do
        {
            if let error = error
            {
                throw error
            }
            
            try FileManager.default.copyItem(at: fileURL, to: saveState.fileURL, shouldReplace: true)
            SyncManager.shared.recordController?.updateRecord(for: saveState)
        }
        catch
        {
            let alertController = UIAlertController(title: NSLocalizedString("Unable to Import Save State", comment: ""), error: error)
            self.present(alertController, animated: true, completion: nil)
        }
    }
    
    func exportSaveState(_ saveState: SaveState)
    {
        guard mayAccessSaves, !saveState.isDeleted, saveState.game?.identifier == game?.identifier else { return }
        do
        {
            let sanitizedFilename = saveState.localizedName.components(separatedBy: .urlFilenameAllowed.inverted).joined()
            
            let temporaryURL = FileManager.default.temporaryDirectory.appendingPathComponent(sanitizedFilename).appendingPathExtension("svs")
            try FileManager.default.copyItem(at: saveState.fileURL, to: temporaryURL, shouldReplace: true)
            
            self._exportedSaveStateURL = temporaryURL
            
            let documentPicker = UIDocumentPickerViewController(forExporting: [temporaryURL], asCopy: false)
            documentPicker.delegate = self
            self.present(documentPicker, animated: true, completion: nil)
        }
        catch
        {
            let alertController = UIAlertController(title: NSLocalizedString("Unable to Export Save State", comment: ""), error: error)
            self.present(alertController, animated: true, completion: nil)
        }
    }
    
    func markSaveStateAsCompatible(_ saveState: SaveState)
    {
        guard mayAccessSaves, !saveState.isDeleted else { return }
        // Can only mark save states as compatible if the DeltaCore has an explicit version.
        guard let deltaCore = Delta.core(for: self.game.type), let version = deltaCore.version else { return }
        
        let backgroundContext = DatabaseManager.shared.newBackgroundContext()
        backgroundContext.performAndWait() {
            let temporarySaveState = backgroundContext.object(with: saveState.objectID) as! SaveState
            temporarySaveState.coreVersion = version
            
            if temporarySaveState.type == .auto
            {
                // Move auto save states to "general" to avoid ending up with more than 2 auto save states.
                temporarySaveState.type = .general
            }
            
            backgroundContext.saveWithErrorLogging()
            
            DispatchQueue.main.async {
                self.update()
            }
        }
    }
    
    func markSaveStateAsIncompatible(_ saveState: SaveState)
    {
        guard mayAccessSaves, !saveState.isDeleted else { return }
        let backgroundContext = DatabaseManager.shared.newBackgroundContext()
        backgroundContext.performAndWait() {
            let temporarySaveState = backgroundContext.object(with: saveState.objectID) as! SaveState
            temporarySaveState.coreVersion = nil
            
            if temporarySaveState.type == .auto
            {
                // Move auto save states to "general" to avoid ending up with more than 2 auto save states.
                temporarySaveState.type = .general
            }
            
            backgroundContext.saveWithErrorLogging()
        }
    }
    
    func showCompatibleSaveStates()
    {
        UIView.transition(with: self.collectionView, duration: 0.4, options: .transitionCrossDissolve) {
            self.filter = .compatible
            self.updateDataSource()
        }
    }
    
    func showIncompatibleSaveStates()
    {
        UIView.transition(with: self.collectionView, duration: 0.4, options: .transitionCrossDissolve) {
            self.filter = .incompatible
            self.updateDataSource()
        }
    }
    
    //MARK: - Convenience Methods -
    
    func correctedSectionForSectionIndex(_ index: Int) -> Section
    {
        var index = index
        
        switch self.filter
        {
        case .compatible:
            // .info section is hidden, so no need to adjust index.
            break
            
        case .incompatible where index == 0:
            // Index 0 is always .info when viewing incompatible save states.
            return .info
            
        case .incompatible:
            // Account for extra empty .info section.
            index -= 1
        }

        let sectionInfo = self.fetchedDataSource.fetchedResultsController.sections![index]
        let sectionIndex = Int(sectionInfo.name)! + 1 // Add 1 to account for empty .info section
        
        let section = Section(rawValue: sectionIndex)!
        return section
    }
    
    func actionsForSaveState(_ saveState: SaveState) -> [UIMenuElement]?
    {
        guard mayAccessSaves, !saveState.isDeleted else { return nil }
        if self.filter != .incompatible
        {
            // Don't show actions for auto save states (unless they're incompatible).
            guard saveState.type != .auto else { return nil }
        }
        
        var actions = [UIMenuElement]()
        
        let previewAction: UIAction
        if saveState.game?.previewSaveState != saveState
        {
            previewAction = UIAction(title: NSLocalizedString("Set as Preview Save State", comment: ""), image: UIImage(symbolNameIfAvailable: "eye.fill")) { [unowned self] action in
                self.updatePreviewSaveState(saveState)
            }
        }
        else
        {
            previewAction = UIAction(title: NSLocalizedString("Remove as Preview Save State", comment: ""), image: UIImage(symbolNameIfAvailable: "eye.slash.fill")) { [unowned self] action in
                self.updatePreviewSaveState(nil)
            }
        }
        
        let previewMenu = UIMenu(options: .displayInline, children: [previewAction])
        
        let markCompatibleAction = UIAction(title: NSLocalizedString("Mark as Compatible", comment: ""), image: UIImage(symbolNameIfAvailable: "checkmark.circle")) { [unowned self] _ in
            self.markSaveStateAsCompatible(saveState)
        }
        
        let markIncompatibleAction = UIAction(title: NSLocalizedString("Mark as Incompatible", comment: ""), image: UIImage(symbolNameIfAvailable: "x.circle")) { [unowned self] _ in
            self.markSaveStateAsIncompatible(saveState)
        }
        
        let compatibilityMenu = UIMenu(options: .displayInline, children: [markCompatibleAction])
        let incompatibilityMenu = UIMenu(options: .displayInline, children: [markIncompatibleAction])
        
        switch self.filter
        {
        case .compatible: 
            actions.append(previewMenu)
            
            #if BETA
            actions.append(incompatibilityMenu)
            #endif
            
        case .incompatible: actions.append(compatibilityMenu)
        }
        
        let renameAction = UIAction(title: NSLocalizedString("Rename", comment: ""), image: UIImage(symbolNameIfAvailable: "pencil")) { [unowned self] action in
            self.renameSaveState(saveState)
        }
        actions.append(renameAction)
        
        switch saveState.type
        {
        case .auto: break
        case .quick: break
        case .general:
            let lockAction = UIAction(title: NSLocalizedString("Lock", comment: ""), image: UIImage(symbolNameIfAvailable: "lock.fill")) { [unowned self] action in
                self.lockSaveState(saveState)
            }
            actions.append(lockAction)
            
        case .locked:
            let unlockAction = UIAction(title: NSLocalizedString("Unlock", comment: ""), image: UIImage(symbolNameIfAvailable: "lock.open.fill")) { [unowned self] action in
                self.unlockSaveState(saveState)
            }
            actions.append(unlockAction)
        }
        
        let importAction = UIAction(title: NSLocalizedString("Import", comment: ""), image: UIImage(symbolNameIfAvailable: "square.and.arrow.down")) { [unowned self] action in
            self.importSaveState(saveState)
        }
        
        let exportAction = UIAction(title: NSLocalizedString("Export", comment: ""), image: UIImage(symbolNameIfAvailable: "square.and.arrow.up")) { [unowned self] action in
            self.exportSaveState(saveState)
        }
        
        let manageMenu = UIMenu(options: .displayInline, children: [importAction, exportAction])
        actions.append(manageMenu)
        
        let deleteAction = UIAction(title: NSLocalizedString("Delete", comment: ""), image: UIImage(symbolNameIfAvailable: "trash"), attributes: .destructive) { [unowned self] action in
            self.deleteSaveState(saveState)
        }
        
        let deleteMenu = UIMenu(options: .displayInline, children: [deleteAction])
        actions.append(deleteMenu)
        
        return actions
    }
    
    //MARK: - Emulator -
    
    func resetEmulatorCoreIfNeeded()
    {
        self.prepareEmulatorCore()
        
        if let saveState = self.emulatorCoreSaveState
        {
            self.emulatorCoreSaveState = nil
            // Remove temporary save state file
            do
            {
                try FileManager.default.removeItem(at: saveState.fileURL)
            }
            catch let error as NSError
            {
                print(error)
            }
        }
    }
    
    func prepareEmulatorCore()
    {
        // We stopped emulation for 3D Touch, so now we must resume emulation and load the save state we made to make it seem like it was never stopped
        // Additionally, if emulatorCore.state != .stopped, then we have already resumed emulation with correct save state, and don't need to do it again
        guard let emulatorCore = self.emulatorCore, emulatorCore.state == .stopped else { return }
        if emulatorCore.game is Game, emulatorSaveAccess?.isCurrent != true { return }
        
        // Temporarily disable video rendering to prevent flickers
        emulatorCore.videoManager.isEnabled = false
        
        // Load the save state we stored a reference to
        emulatorCore.start()
        emulatorCore.pause()
        
        if let saveState = self.emulatorCoreSaveState
        {
            do
            {
                try emulatorCore.load(saveState)
            }
            catch EmulatorCore.SaveStateError.doesNotExist
            {
                print("Save State does not exist.")
            }
            catch let error as NSError
            {
                print(error)
            }
        }
        
        // Re-enable video rendering
        emulatorCore.videoManager.isEnabled = true
    }
}

private extension SaveStatesViewController
{
    func withStoppedPreview(_ completion: @escaping () -> Void)
    {
        guard mayAccessSaves else { return }
        guard let preview = self.activePreviewViewController else {
            completion()
            return
        }
        preview.stopPreview {
            guard self.mayAccessSaves else { return }
            completion()
        }
    }

    @discardableResult private func prepareEmulatorCoreSaveState() -> Bool
    {
        guard mayAccessSaves else { return false }
        guard let emulatorCore = self.emulatorCore, emulatorCore.state != .stopped else { return true }
        if emulatorCore.game is Game, emulatorSaveAccess?.isCurrent != true { return false }
        
        // Store reference to current game state before we stop emulation so we can resume it if user decides to not load a save state
        
        let wasRunning = emulatorCore.state == .running
        if wasRunning { emulatorCore.pause() }
        let fileURL = FileManager.default.uniqueTemporaryURL()
        let saveState = emulatorCore.saveSaveState(to: fileURL)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? NSNumber, size.intValue > 0 else {
            if wasRunning { emulatorCore.resume() }
            return false
        }

        let previousSaveState = self.emulatorCoreSaveState
        self.emulatorCoreSaveState = saveState
        emulatorCore.stop()
        if let previousSaveState {
            try? FileManager.default.removeItem(at: previousSaveState.fileURL)
        }
        return true
    }
    
    func makePreviewGameViewController(for saveState: SaveState) -> PreviewGameViewController?
    {
        guard mayAccessSaves, !saveState.isDeleted, saveState.game?.identifier == game?.identifier else { return nil }
        guard self.activePreviewViewController == nil else { return nil }
        // Saving a state may have restarted the gameplay core since this screen
        // opened. Stop it before a preview takes over the shared emulator bridge.
        guard self.prepareEmulatorCoreSaveState() else { return nil }
        let previewImage = self.dataSource.prefetchItemCache.object(forKey: saveState) ?? UIImage(contentsOfFile: saveState.imageFileURL.path)
        
        let gameViewController = PreviewGameViewController()
        gameViewController.game = self.game
        gameViewController.previewSaveState = saveState
        gameViewController.previewImage = previewImage
        self.activePreviewViewController = gameViewController
        gameViewController.onPreviewStopped = { [weak self, weak gameViewController] in
            guard let self, self.activePreviewViewController === gameViewController else { return }
            self.activePreviewViewController = nil
        }
        return gameViewController
    }
    
    func commitPreviewTransition()
    {
        guard let gameViewController = self._previewTransitionViewController else { return }
        guard mayAccessSaves else {
            gameViewController.stopPreview()
            _previewTransitionViewController = nil
            return
        }
        let fileURL = FileManager.default.uniqueTemporaryURL()
        if let saveState = gameViewController.stopPreview(savingTo: fileURL)
        {
            self.loadSaveState(TemporaryPreviewSaveState(saveState))
        }
        else if let saveState = gameViewController.previewSaveState
        {
            self.loadSaveState(saveState)
        }
    }
}

//MARK: - <UICollectionViewDataSource> -
extension SaveStatesViewController
{
    override func collectionView(_ collectionView: UICollectionView, viewForSupplementaryElementOfKind kind: String, at indexPath: IndexPath) -> UICollectionReusableView
    {
        let headerView = collectionView.dequeueReusableSupplementaryView(ofKind: kind, withReuseIdentifier: "Header", for: indexPath) as! SaveStatesCollectionHeaderView
        self.configure(headerView, forSection: indexPath.section)
        return headerView
    }
}

//MARK: - <UICollectionViewDelegate> -
extension SaveStatesViewController
{
    override func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool
    {
        guard mayAccessSaves else { return false }
        guard self.isEditing else { return true }

        let section = self.correctedSectionForSectionIndex(indexPath.section)
        return section != .auto && section != .info && section != .locked
    }

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath)
    {
        guard mayAccessSaves else { return }
        if self.isEditing
        {
            self.updateToolbarState()
            return
        }

        let saveState = self.dataSource.item(at: indexPath)
        
        switch self.filter
        {
        case .incompatible:
            let alertController = UIAlertController(title: NSLocalizedString("Incompatible Save State", comment: ""), message: NSLocalizedString("This save state is incompatible with this version of Delta.", comment: ""), preferredStyle: .alert)
            alertController.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .cancel, handler: nil))
            self.present(alertController, animated: true, completion: nil)
            
        case .compatible:
            
            switch self.mode
            {
            case .saving:
                
                let section = self.correctedSectionForSectionIndex(indexPath.section)
                switch section
                {
                case .auto, .info: break
                case .quick, .general:
                    let backgroundContext = DatabaseManager.shared.newBackgroundContext()
                    let objectID = saveState.objectID
                    var temporarySaveState: SaveState?
                    backgroundContext.performAndWait() {
                        temporarySaveState = try? backgroundContext.existingObject(with: objectID) as? SaveState
                    }
                    if let temporarySaveState {
                        // Preview shutdown and delegate/UI work belong on main;
                        // updateSaveState enters the context only for the write.
                        self.updateSaveState(temporarySaveState)
                    }
                    
                case .locked:
                    let alertController = UIAlertController(title: NSLocalizedString("Cannot Modify Locked Save State", comment: ""), message: NSLocalizedString("This save state must first be unlocked before it can be modified.", comment: ""), preferredStyle: .alert)
                    alertController.addAction(UIAlertAction(title: NSLocalizedString("OK", comment: ""), style: .cancel, handler: nil))
                    self.present(alertController, animated: true, completion: nil)
                    
                }
                
            case .loading: self.loadSaveState(saveState)
            }
        }
    }

    override func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath)
    {
        guard self.isEditing else { return }
        self.updateToolbarState()
    }
}

//MARK: - <UICollectionViewDelegateFlowLayout> -
extension SaveStatesViewController: UICollectionViewDelegateFlowLayout
{
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, sizeForItemAt indexPath: IndexPath) -> CGSize
    {
        self.configure(self.prototypeCell, for: indexPath)
        
        let size = self.prototypeCell.contentView.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        return size
    }
    
    func collectionView(_ collectionView: UICollectionView, layout collectionViewLayout: UICollectionViewLayout, referenceSizeForHeaderInSection section: Int) -> CGSize
    {
        self.configure(self.prototypeHeader, forSection: section)
        
        let size = self.prototypeHeader.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        return size
    }
}

@available(iOS 13.0, *)
extension SaveStatesViewController
{
    override func collectionView(_ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration?
    {
        guard mayAccessSaves, !self.isEditing else { return nil }

        let saveState = self.dataSource.item(at: indexPath)
        guard let actions = self.actionsForSaveState(saveState) else { return nil }
        
        return UIContextMenuConfiguration(identifier: indexPath as NSIndexPath, previewProvider: { [weak self] in
            guard let self = self, Settings.isPreviewsEnabled, self.filter != .incompatible,
                  (!AchievementsManager.shared.isAuthenticated || !Settings.features.retroAchievements.isHardcoreModeEnabled) // Disable preview in hardcore mode so it can't be abused to load state
            else { return nil }
            
            let previewGameViewController = self.makePreviewGameViewController(for: saveState)
            self._previewTransitionViewController = previewGameViewController
            
            return previewGameViewController
        }) { suggestedActions in
            return UIMenu(title: saveState.localizedName, children: actions)
        }
    }
    
    override func collectionView(_ collectionView: UICollectionView, willPerformPreviewActionForMenuWith configuration: UIContextMenuConfiguration, animator: UIContextMenuInteractionCommitAnimating)
    {
        self.commitPreviewTransition()
    }
    
    override func collectionView(_ collectionView: UICollectionView, previewForHighlightingContextMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview?
    {
        guard let indexPath = configuration.identifier as? NSIndexPath else { return nil }
        guard let cell = collectionView.cellForItem(at: indexPath as IndexPath) as? GridCollectionViewCell else { return nil }
        
        let parameters = UIPreviewParameters()
        parameters.backgroundColor = .clear

        let preview = UITargetedPreview(view: cell.imageView, parameters: parameters)
        return preview
    }
    
    override func collectionView(_ collectionView: UICollectionView, previewForDismissingContextMenuWithConfiguration configuration: UIContextMenuConfiguration) -> UITargetedPreview?
    {
        self._previewTransitionViewController = nil
        return self.collectionView(collectionView, previewForHighlightingContextMenuWithConfiguration: configuration)
    }
}

//MARK: - <ImportControllerDelegate> -
extension SaveStatesViewController: ImportControllerDelegate
{
    func importController(_ importController: ImportController, didImportItemsAt urls: Set<URL>, errors: [Error])
    {
        if let saveState = self._importingSaveState, let fileURL = urls.first
        {
            self.importSaveState(saveState, from: fileURL, error: errors.first)
        }
        
        self._importingSaveState = nil
    }
    
    func importControllerDidCancel(_ importController: ImportController)
    {
        self.presentedViewController?.dismiss(animated: true, completion: nil)
    }
}

//MARK: - <UIDocumentPickerDelegate> -
extension SaveStatesViewController: UIDocumentPickerDelegate
{
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL])
    {
        if let saveStateURL = self._exportedSaveStateURL
        {
            try? FileManager.default.removeItem(at: saveStateURL)
        }
        
        self._exportedSaveStateURL = nil
    }
    
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController)
    {
        if let saveStateURL = self._exportedSaveStateURL
        {
            try? FileManager.default.removeItem(at: saveStateURL)
        }
        
        self._exportedSaveStateURL = nil
    }
}

private extension UserDefaults
{
    @NSManaged var showedIncompatibleDSSaveStatesAlert: Bool
    @NSManaged var prefersDescendingSaveStatesSorting: Bool
    
    @nonobjc var preferredSaveStatesSorting: SaveStatesViewController.Sorting {
        get {
            let sorting = _preferredSaveStatesSorting.flatMap { SaveStatesViewController.Sorting(rawValue: $0) } ?? .date
            return sorting
        }
        set {
            _preferredSaveStatesSorting = newValue.rawValue
        }
    }
    @NSManaged @objc(preferredSaveStatesSorting) private var _preferredSaveStatesSorting: String?
}

extension SaveStatesViewController
{
    override func setEditing(_ editing: Bool, animated: Bool)
    {
        super.setEditing(editing, animated: animated)

        if editing
        {
            // Use a title-based UIBarButtonItem so iOS 26's toolbar capsule sizes to fit the text.
            let countItem = UIBarButtonItem(title: NSLocalizedString("0 Selected", comment: ""), style: .plain, target: nil, action: nil)
            self.selectionCountItem = countItem

            let flexSpace = UIBarButtonItem(barButtonSystemItem: .flexibleSpace, target: nil, action: nil)

            let deleteButton = UIBarButtonItem(title: NSLocalizedString("Delete", comment: ""),
                                               style: .plain, target: self,
                                               action: #selector(deleteSelectedSaveStates))
            deleteButton.tintColor = UIColor.systemRed
            deleteButton.isEnabled = false
            self.deleteSelectionItem = deleteButton

            self.toolbarItems = [countItem, flexSpace, deleteButton]
            self.navigationController?.setToolbarHidden(false, animated: animated)
        }
        else
        {
            self.collectionView.indexPathsForSelectedItems?.forEach {
                self.collectionView.deselectItem(at: $0, animated: false)
            }

            self.navigationController?.setToolbarHidden(true, animated: animated)
            self.toolbarItems = nil
            self.selectionCountItem = nil
            self.deleteSelectionItem = nil
        }

        // Update selection appearance without discarding the current selection.
        for indexPath in self.collectionView.indexPathsForVisibleItems
        {
            guard let cell = self.collectionView.cellForItem(at: indexPath) as? GridCollectionViewCell else { continue }

            if editing
            {
                let section = self.correctedSectionForSectionIndex(indexPath.section)
                cell.isInSelectionMode = section != .auto && section != .info && section != .locked
            }
            else
            {
                cell.isInSelectionMode = false
            }
        }
    }
}
