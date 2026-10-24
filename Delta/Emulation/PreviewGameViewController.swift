//
//  PreviewGameViewController.swift
//  Delta
//
//  Created by Riley Testut on 8/11/16.
//  Copyright © 2016 Riley Testut. All rights reserved.
//

import UIKit

import DeltaCore

private var kvoContext = 0

class PreviewGameViewController: DeltaCore.GameViewController
{
    // If non-nil, will override the default preview action items returned in previewActionItems()
    var overridePreviewActionItems: [UIPreviewActionItem]?
    
    // Save state to be loaded upon preview
    var previewSaveState: SaveStateProtocol? {
        didSet {
            // Resolve managed objects before entering the emulation queue. A
            // synchronous shutdown must never wait on the main Core Data context.
            self.previewStateSnapshot = nil
            if let saveState = self.previewSaveState as? SaveState {
                saveState.managedObjectContext?.performAndWait {
                    self.previewStateSnapshot = DeltaCore.SaveState(fileURL: saveState.fileURL, gameType: saveState.gameType)
                }
            } else {
                self.previewStateSnapshot = self.previewSaveState
            }
        }
    }
    private var previewStateSnapshot: SaveStateProtocol?
    
    // Initial image to be shown while loading
    var previewImage: UIImage? {
        didSet {
            self.updatePreviewImage()
        }
    }
    
    var isLivePreview: Bool = true
    var onPreviewStopped: (() -> Void)?
    
    private var emulatorCoreQueue = DispatchQueue(label: "com.rileytestut.Delta.PreviewGameViewController.emulatorCoreQueue", qos: .userInitiated)
    // Accessed only on emulatorCoreQueue.
    private var hasPreparedPreview = false
    private var hasRestoredSaveFiles = false
    private let lifecycleLock = NSLock()
    private var isStoppingPreview = false
    private var canRunPreview: Bool {
        self.lifecycleLock.lock()
        defer { self.lifecycleLock.unlock() }
        return !self.isStoppingPreview
    }
    private var copiedSaveFiles = [(originalURL: URL, copyURL: URL)]()
    
    private lazy var temporaryDirectoryURL: URL = {
        let directoryURL = FileManager.default.temporaryDirectory.appendingPathComponent("preview-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
        return directoryURL
    }()
    
    override var game: GameProtocol? {
        get { super.game }
        set {
            guard newValue == nil || !BoundROMUpdateManager.shared.isApplying else { return }
            if let game = newValue as? Game,
               BoundROMUpdateManager.shared.hasPendingSaveClear(for: game.identifier) { return }
            if let game = newValue as? Game,
               BoundServerBackupManager.hasPendingRestore(gameID: game.identifier) { return }
            self.emulatorCore?.removeObserver(self, forKeyPath: #keyPath(EmulatorCore.state), context: &kvoContext)
            super.game = newValue
            BoundROMUpdateActivity.bindingChanged(self)
            guard let emulatorCore = self.emulatorCore else {
                self.preferredContentSize = CGSize.zero
                return
            }
            
            emulatorCore.addObserver(self, forKeyPath: #keyPath(EmulatorCore.state), options: [.old], context: &kvoContext)
            
            let size = CGSize(width: emulatorCore.preferredRenderingSize.width * 2.0, height: emulatorCore.preferredRenderingSize.height * 2.0)
            self.preferredContentSize = size
        }
    }
    
    override var previewActionItems: [UIPreviewActionItem] {
        guard let previewActionItems = self.overridePreviewActionItems else { return [] }
        return previewActionItems
    }
    
    public required init()
    {
        super.init()
        
        self.delegate = self
    }
    
    public required init?(coder aDecoder: NSCoder)
    {
        super.init(coder: aDecoder)
        
        self.delegate = self
    }
    
    deinit
    {
        
    }
}

//MARK: - UIViewController -
/// UIViewController
extension PreviewGameViewController
{
    override func viewDidLoad()
    {
        super.viewDidLoad()
        
        self.controllerView.isHidden = true
        self.controllerView.controllerSkin = nil // Skip loading controller skin from disk, which may be slow.
        
        // Temporarily prevent emulatorCore from updating gameView to prevent flicker of black, or other visual glitches
        self.emulatorCore?.remove(self.gameView)
        
        self.emulatorCore?.audioManager.respectsSilentMode = Settings.respectSilentMode
        self.emulatorCore?.audioManager.mixesWithOtherAudio = Settings.mixWithOtherAudio
        self.emulatorCore?.audioManager.pausesOtherAudio = Settings.pauseOtherAudio
    }
    
    override func viewWillAppear(_ animated: Bool)
    {
        // The superclass queues startup, which may immediately write a save.
        if self.canRunPreview { self.copySaveFiles() }
        super.viewWillAppear(animated)
    }

    override func viewWillDisappear(_ animated: Bool)
    {
        super.viewWillDisappear(animated)
        
        // Pause in viewWillDisappear and not viewDidDisappear like DeltaCore.GameViewController so the audio cuts off earlier if being dismissed
        self.emulatorCoreQueue.sync { _ = self.pauseEmulation() }
    }
    
    override func viewDidDisappear(_ animated: Bool)
    {
        super.viewDidDisappear(animated)
        
        self.stopPreview {
            // Release renderers only after both emulation queues have drained.
            self.game = nil
        }
    }
    
    override func viewDidLayoutSubviews()
    {
        super.viewDidLayoutSubviews()
        
        // Need to update in viewDidLayoutSubviews() to ensure bounds of gameView are not CGRect.zero
        self.updatePreviewImage()
    }

    override func didReceiveMemoryWarning()
    {
        super.didReceiveMemoryWarning()
        // Dispose of any resources that can be recreated.
    }

    func stopPreview(completion: @escaping () -> Void)
    {
        self.stopPreview()
        completion()
    }

    @discardableResult
    func stopPreview(savingTo fileURL: URL? = nil) -> SaveStateProtocol?
    {
        precondition(Thread.isMainThread)
        self.lifecycleLock.lock()
        self.isStoppingPreview = true
        self.lifecycleLock.unlock()

        let core = self.emulatorCore
        let saveState: SaveStateProtocol? = self.emulatorCoreQueue.sync {
            // Drain superclass lifecycle work as well as preview preparation.
            // The terminal flag prevents later UIKit callbacks from restarting
            // this core after gameplay takes ownership of the shared bridge.
            self.pauseEmulation()
            var saveState: SaveStateProtocol?
            if let core, core.state != .stopped, let fileURL,
               self.hasPreparedPreview || self.previewStateSnapshot == nil {
                saveState = core.saveSaveState(to: fileURL)
            }
            core?.stop()
            self.restoreSaveFiles()
            return saveState
        }
        let onStopped = self.onPreviewStopped
        self.onPreviewStopped = nil
        onStopped?()
        return saveState
    }
    
    override func observeValue(forKeyPath keyPath: String?, of object: Any?, change: [NSKeyValueChangeKey : Any]?, context: UnsafeMutableRawPointer?)
    {
        guard context == &kvoContext else { return super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context) }
        
        guard
            let rawValue = change?[.oldKey] as? Int,
            let previousState = EmulatorCore.State(rawValue: rawValue),
            let state = self.emulatorCore?.state
        else { return }
        
        switch state
        {
        case .running where previousState == .stopped:
            self.emulatorCoreQueue.async {
                // Pause to prevent it from starting before visible (in case user peeked slowly)
                self.emulatorCore?.pause()
                self.preparePreview()
            }
            
        default: break
        }
    }
}

//MARK: - Private -
private extension PreviewGameViewController
{
    func updatePreviewImage()
    {        
        if let previewImage = self.previewImage
        {
            self.gameView?.inputImage = CIImage(image: previewImage)
        }
        else
        {
            self.gameView?.inputImage = nil
        }
    }
    
    func preparePreview()
    {
        // Startup's KVO callback can enqueue this work after a stop was requested.
        // A stopped preview must not load into the bridge now owned by gameplay.
        guard self.canRunPreview, let emulatorCore = self.emulatorCore, emulatorCore.state != .stopped else { return }
        
        if let saveState = self.previewStateSnapshot
        {
            do
            {
                try emulatorCore.load(saveState)
            }
            catch EmulatorCore.SaveStateError.doesNotExist
            {
                print("Save State does not exist.")
            }
            catch
            {
                print(error)
            }
        }
        
        emulatorCore.updateCheats()
        
        // Re-enable emulatorCore to update gameView again
        emulatorCore.add(self.gameView)
        self.hasPreparedPreview = true
        
        if self.canRunPreview { emulatorCore.resume() }
    }
    
    func copySaveFiles()
    {
        guard let game = self.game as? Game, let gameSave = game.gameSave else { return }
        
        self.copiedSaveFiles.removeAll()
        
        let fileURLs = gameSave.syncableFiles.lazy.map { $0.fileURL }
        for fileURL in fileURLs
        {
            do
            {
                let destinationURL = self.temporaryDirectoryURL.appendingPathComponent(fileURL.lastPathComponent)
                try FileManager.default.copyItem(at: fileURL, to: destinationURL, shouldReplace: true)
                
                self.copiedSaveFiles.append((fileURL, destinationURL))
                print("Copied save file:", fileURL.lastPathComponent)
            }
            catch
            {
                print("Failed to back up save file \(fileURL.lastPathComponent).", error)
            }
        }
    }
    
    func restoreSaveFiles()
    {
        // A screenshot-only preview may never start, so there need not be a
        // stopped-state KVO notification. Terminal shutdown owns cleanup once.
        guard !self.hasRestoredSaveFiles else { return }
        self.hasRestoredSaveFiles = true
        for (originalURL, copyURL) in self.copiedSaveFiles
        {
            do
            {
                try FileManager.default.copyItem(at: copyURL, to: originalURL, shouldReplace: true)
                print("Restored save file:", originalURL.lastPathComponent)
            }
            catch
            {
                print("Failed to restore copied save file \(copyURL.lastPathComponent).", error)
            }
        }
        
        self.copiedSaveFiles.removeAll()
        do
        {
            try FileManager.default.removeItem(at: self.temporaryDirectoryURL)
        }
        catch
        {
            print("Failed to remove preview temporary directory.", error)
        }
    }
}

extension PreviewGameViewController: GameViewControllerDelegate
{
    func gameViewControllerShouldResumeEmulation(_ gameViewController: DeltaCore.GameViewController) -> Bool
    {
        guard self.game != nil else { return false }
        if let game = self.game as? Game,
           BoundROMUpdateStorage.live.hasPendingSaveClear(gameID: game.identifier) { return false }
        return self.isLivePreview && self.canRunPreview
    }
    
    func gameViewController(_ gameViewController: DeltaCore.GameViewController, optionsFor game: GameProtocol) -> [EmulatorCore.Option: Any]
    {
        // Context-menu previews need gameplay's renderer, including the Metal
        // GBA path that avoids OpenGL crashes while attaching the preview view.
        GameViewController.emulatorCoreOptions(for: game)
    }
}
