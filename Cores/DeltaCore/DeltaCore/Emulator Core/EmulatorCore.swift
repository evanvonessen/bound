//
//  EmulatorCore.swift
//  DeltaCore
//
//  Created by Riley Testut on 3/11/15.
//  Copyright (c) 2015 Riley Testut. All rights reserved.
//

import AVFoundation

#if DEBUG
/// Opt-in, bounded frame tracing. Install only while the core is paused.
/// Numeric events stay in memory until QA exports them after playback stops.
public final class EmulatorFrameTrace: @unchecked Sendable {
    public struct Event: Codable, Sendable {
        public let frame: UInt64
        public let stage: String
        public let time: TimeInterval
        public let duration: TimeInterval
        public let value: Double
        public let detail: UInt64
    }
    private let lock = NSLock()
    private let capacity: Int
    private var frame: UInt64 = 0
    private var events: [Event] = []
    private var overflow = 0
    /// Set before resuming. Runs synchronously on the native video owner.
    public var observeVideo: ((UInt64) -> Void)?
    public init(capacity: Int = 200_000) {
        self.capacity = max(1, min(capacity, 2_000_000))
        events.reserveCapacity(self.capacity)
    }
    public var currentFrame: UInt64 { lock.lock(); defer { lock.unlock() }; return frame }
    public var droppedEvents: Int { lock.lock(); defer { lock.unlock() }; return overflow }
    public func snapshot() -> [Event] { lock.lock(); defer { lock.unlock() }; return events }
    @discardableResult public func beginFrame(renderGraphics: Bool) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        frame &+= 1
        append("frame.begin", frame: frame, time: ProcessInfo.processInfo.systemUptime,
               duration: 0, value: renderGraphics ? 1 : 0, detail: 0)
        return frame
    }
    public func record(_ stage: String, frame: UInt64? = nil, at time: TimeInterval? = nil,
                       duration: TimeInterval = 0, value: Double = 0, detail: UInt64 = 0) {
        let now = time ?? ProcessInfo.processInfo.systemUptime
        lock.lock(); defer { lock.unlock() }
        append(stage, frame: frame ?? self.frame, time: now, duration: duration, value: value, detail: detail)
    }
    private func append(_ stage: String, frame: UInt64, time: TimeInterval,
                        duration: TimeInterval, value: Double, detail: UInt64) {
        guard events.count < capacity else { overflow += 1; return }
        events.append(.init(frame: frame, stage: stage, time: time, duration: duration, value: value, detail: detail))
    }
    public func measure<T>(_ stage: String, frame: UInt64? = nil, _ work: () throws -> T) rethrows -> T {
        let start = ProcessInfo.processInfo.systemUptime
        defer { record(stage, frame: frame, at: start, duration: ProcessInfo.processInfo.systemUptime - start) }
        return try work()
    }
}
#endif

extension EmulatorCore
{
    @objc public static let emulationDidQuitNotification = Notification.Name("com.rileytestut.DeltaCore.emulationDidQuit")
    
    private static let didUpdateFrameNotification = Notification.Name("com.rileytestut.DeltaCore.didUpdateFrame")
}

public extension EmulatorCore
{
    typealias Option = __EmulatorCoreOption
    
    @objc enum State: Int
    {
        case stopped
        case running
        case paused
    }
    
    enum CheatError: Error
    {
        case invalid
    }
    
    enum SaveStateError: Error
    {
        case doesNotExist
    }
}

@objc(DLTAEmulatorCore)
public final class EmulatorCore: NSObject
{
    //MARK: - Properties -
    /** Properties **/
    public let game: GameProtocol
    public let options: [Option: Any]
    
    public var gameViews: Set<GameView> {
        return _gameViews.setRepresentation as! Set<GameView>
    }
    private let _gameViews: NSHashTable = NSHashTable<GameView>.weakObjects()
    
    public var updateHandler: ((EmulatorCore) -> Void)?
    public var saveHandler: ((EmulatorCore) -> Void)?
    #if DEBUG
    public var debugFrameTrace: EmulatorFrameTrace?
    #endif
    
    public let audioManager: AudioManager
    public let videoManager: VideoManager
    
    // KVO-Compliant
    @objc public private(set) dynamic var state = State.stopped
    @objc public dynamic var rate = 1.0 {
        didSet {
            self.audioManager.rate = self.rate
        }
    }
    
    public let deltaCore: DeltaCoreProtocol
    public var preferredRenderingSize: CGSize { return self.deltaCore.videoFormat.dimensions }
    
    //MARK: - Private Properties
    
    // We privately set this first to clean up before setting self.state, which notifies KVO observers
    private var _state = State.stopped
    
    private let gameType: GameType
    private let gameSaveURL: URL
    
    private var cheatCodes = [String: CheatType]()
    
    private var gameControllers = NSHashTable<AnyObject>.weakObjects()
    
    private var previousState = State.stopped
    private var previousFrameDuration: TimeInterval? = nil
    
    private var reactivateInputsDispatchGroup: DispatchGroup?
    private let reactivateInputsQueue = DispatchQueue(label: "com.rileytestut.DeltaCore.EmulatorCore.reactivateInputsQueue", attributes: [.concurrent])
    
    private let emulationLock = NSLock()
    
    //MARK: - Initializers -
    /** Initializers **/
    public required init?(game: GameProtocol, options: [Option: Any] = [:])
    {
        // These MUST be set in start(), because it's possible the same emulator core might be stopped, another one started, and then resumed back to this one
        // AKA, these need to always be set at start to ensure it points to the correct managers
        // self.configuration.bridge.audioRenderer = self.audioManager
        // self.configuration.bridge.videoRenderer = self.videoManager
        
        guard let deltaCore = Delta.core(for: game.type) else {
            print(game.type.rawValue + " is not a supported game type.")
            return nil
        }
        
        self.deltaCore = deltaCore
        
        self.game = game
        self.options = options
        
        // Store separately in case self.game is an NSManagedObject subclass, and we need to access .type or .gameSaveURL on a different thread than its NSManagedObjectContext
        self.gameType = self.game.type
        self.gameSaveURL = self.game.gameSaveURL
        
        var videoFormat = deltaCore.videoFormat
        if let prefersOpenGLES2 = self.options[.openGLES2] as? Bool, prefersOpenGLES2, videoFormat.format == .openGLES3
        {
            // Override core's video format to use OpenGL ES 2.0 instead.
            videoFormat.format = .openGLES2
        }
        
        // These were previously lazy variables, but turns out Swift lazy variables are not thread-safe.
        // Since they don't actually need to be lazy, we now explicitly initialize them in the initializer.
        self.audioManager = AudioManager(audioFormat: deltaCore.audioFormat)
        self.videoManager = VideoManager(videoFormat: videoFormat, options: options)
                
        super.init()
        
        NotificationCenter.default.addObserver(self, selector: #selector(EmulatorCore.emulationDidQuit), name: EmulatorCore.emulationDidQuitNotification, object: nil)
    }
}

//MARK: - Emulation -
/// Emulation
public extension EmulatorCore
{
    @discardableResult func start() -> Bool
    {
        self.emulationLock.lock()
        guard self._state == .stopped else { self.emulationLock.unlock(); return false }
        
        self._state = .running
        defer { self.state = self._state }
        
        self.deltaCore.emulatorBridge.audioRenderer = self.audioManager
        self.deltaCore.emulatorBridge.videoRenderer = self.videoManager
        self.deltaCore.emulatorBridge.saveUpdateHandler = { [unowned self] in
            self.save()
        }
        
        self.audioManager.start()
        self.deltaCore.emulatorBridge.start(withGameURL: self.game.fileURL)
        self.deltaCore.emulatorBridge.loadGameSave(from: self.gameSaveURL)
        
        self.waitForFrameUpdate { self.runGameLoop() }
        
        self.emulationLock.unlock()
        
        return true
    }
    
    @discardableResult func stop() -> Bool
    {
        self.emulationLock.lock()
        guard self._state != .stopped else { self.emulationLock.unlock(); return false }
        
        let isRunning = self._state == .running
        
        defer { self.state = self._state }

        if isRunning
        {
            self.waitForFrameUpdate { self._state = .stopped }
        }
        else
        {
            self._state = .stopped
        }
        
        self.save()
        
        self.audioManager.stop()
        self.deltaCore.emulatorBridge.stop()
        
        self.emulationLock.unlock()
        
        return true
    }
    
    @discardableResult func pause() -> Bool
    {
        self.emulationLock.lock()
        guard self._state == .running else { self.emulationLock.unlock(); return false }
        
        defer { self.state = self._state }

        self.waitForFrameUpdate { self._state = .paused }
        
        self.save()
        
        self.audioManager.isEnabled = false
        self.deltaCore.emulatorBridge.pause()
        
        self.emulationLock.unlock()
        
        return true
    }
    
    @discardableResult func resume() -> Bool
    {
        self.emulationLock.lock()
        guard self._state == .paused else { self.emulationLock.unlock(); return false }
        
        self._state = .running
        defer { self.state = self._state }
        
        self.audioManager.isEnabled = true
        self.deltaCore.emulatorBridge.resume()
        
        self.waitForFrameUpdate { self.runGameLoop() }
        
        self.emulationLock.unlock()
        
        return true
    }
    
    private func waitForFrameUpdate(updating: () -> Void)
    {
        let semaphore = DispatchSemaphore(value: 0)

        let token = NotificationCenter.default.addObserver(forName: EmulatorCore.didUpdateFrameNotification, object: self, queue: nil) { (notification) in
            semaphore.signal()
        }

        // Observe first: a fast frame can acknowledge the transition and exit
        // before a waiter registered after the state change sees the notification.
        updating()
        semaphore.wait()

        NotificationCenter.default.removeObserver(token, name: EmulatorCore.didUpdateFrameNotification, object: self)
    }
}

//MARK: - Game Views -
/// Game Views
public extension EmulatorCore
{
    func add(_ gameView: GameView)
    {
        guard !self.gameViews.contains(gameView) else { return }
        
        self._gameViews.add(gameView)
        self.videoManager.add(gameView)
    }
    
    func remove(_ gameView: GameView)
    {
        self._gameViews.remove(gameView)
        self.videoManager.remove(gameView)
    }
}

//MARK: - Game Saves -
/// Game Saves
public extension EmulatorCore
{
    func save()
    {
        self.deltaCore.emulatorBridge.saveGameSave(to: self.gameSaveURL)
        self.saveHandler?(self)
    }
}

//MARK: - Save States -
/// Save States
public extension EmulatorCore
{
    @discardableResult func saveSaveState(to url: URL) -> SaveStateProtocol
    {
        self.deltaCore.emulatorBridge.saveSaveState(to: url)
        
        let saveState = SaveState(fileURL: url, gameType: self.gameType)
        return saveState
    }
    
    func load(_ saveState: SaveStateProtocol) throws
    {
        guard FileManager.default.fileExists(atPath: saveState.fileURL.path) else { throw SaveStateError.doesNotExist }
        
        self.deltaCore.emulatorBridge.loadSaveState(from: saveState.fileURL)
        
        self.updateCheats()
        self.deltaCore.emulatorBridge.resetInputs()
        
        // Reactivate activated inputs.
        for gameController in self.gameControllers.allObjects as! [GameController]
        {
            for (input, value) in gameController.activatedInputs
            {
                gameController.activate(input, value: value)
            }
        }
    }
}

//MARK: - Cheats -
/// Cheats
public extension EmulatorCore
{
    func activate(_ cheat: CheatProtocol) throws
    {
        let success = self.deltaCore.emulatorBridge.addCheatCode(String(cheat.code), type: cheat.type.rawValue)
        if success
        {
            self.cheatCodes[cheat.code] = cheat.type
        }
        
        // Ensures correct state, especially if attempted cheat was invalid
        self.updateCheats()
        
        if !success
        {
            throw CheatError.invalid
        }
    }
    
    func deactivate(_ cheat: CheatProtocol)
    {
        guard self.cheatCodes[cheat.code] != nil else { return }
        
        self.cheatCodes[cheat.code] = nil
        
        self.updateCheats()
    }
    
    private func updateCheats()
    {
        self.deltaCore.emulatorBridge.resetCheats()
        
        for (cheatCode, type) in self.cheatCodes
        {
            self.deltaCore.emulatorBridge.addCheatCode(String(cheatCode), type: type.rawValue)
        }
        
        self.deltaCore.emulatorBridge.updateCheats()
    }
}

extension EmulatorCore: GameControllerReceiver
{
    public func gameController(_ gameController: GameController, didActivate controllerInput: Input, value: Double)
    {
        // Ignore controllers without assigned playerIndex.
        guard let playerIndex = gameController.playerIndex else { return }
        
        if !self.gameViews.isEmpty
        {
            // Ignore unless there is a game screen in the active scene.
            guard self.gameViews.contains(where: { $0.window?.windowScene?.hasKeyboardFocus == true }) else { return }
        }
        
        self.gameControllers.add(gameController)
        
        guard let input = self.mappedInput(for: controllerInput), input.type == .game(self.gameType) else { return }
        
        // If any of game controller's sustained inputs map to input, treat input as sustained.
        let sustainedControllerInput = gameController.sustainedInputs.first { (sustainedInput, value) in
            guard let mappedInput = gameController.mappedInput(for: sustainedInput, receiver: self) else { return false }
            return self.mappedInput(for: mappedInput) == input
        }
        
        let discreteThreshold = 0.33
        var adjustedValue: Double? = value
        
        if !input.isContinuous, controllerInput.isContinuous, value > (1.0 - discreteThreshold)
        {
            // input is discrete while controller input is continuous, so activate values greater than 0.66 for better responsiveness.
            // this helps when using analog sticks as button inputs (especially for controllers with poor analog stick calibration).
            adjustedValue = 1.0
        }
        
        if !input.isContinuous, value < discreteThreshold
        {
            // input is discrete, so ignore values less than 0.33 to avoid eagerly activating.
            // This significantly improves using analog sticks as dpad inputs.
            
            if let sustainedControllerInput, sustainedControllerInput.value >= discreteThreshold
            {
                // Set adjustedValue to sustained value to reset.
                adjustedValue = sustainedControllerInput.value
            }
            else
            {
                // input is not sustained, or sustained value is less than threshold,
                // so we'll deactivate the input instead.
                adjustedValue = nil
            }
        }
        
        if let adjustedValue
        {
            if let sustainedControllerInput, !sustainedControllerInput.key.isContinuous, !input.isContinuous
            {
                // input is sustained, but neither it nor the controller input are continuous.
                // This means we need to temporarily deactivate the input before activating it again.
                self.reactivateInputsQueue.async {
                    
                    self.deltaCore.emulatorBridge.deactivateInput(input.intValue!, playerIndex: playerIndex)
                    
                    self.reactivateInputsDispatchGroup = DispatchGroup()
                    
                    // To ensure the emulator core recognizes us activating an input that is currently active, we need to first deactivate it, wait at least two frames, then activate it again.
                    self.reactivateInputsDispatchGroup?.enter()
                    self.reactivateInputsDispatchGroup?.enter()
                    self.reactivateInputsDispatchGroup?.wait()

                    self.reactivateInputsDispatchGroup = nil
                    
                    if gameController.sustainedInputs.keys.contains(sustainedControllerInput.key)
                    {
                        // Make sure input is still sustained before reactivating it.
                        self.deltaCore.emulatorBridge.activateInput(input.intValue!, value: adjustedValue, playerIndex: playerIndex)
                    }
                }
            }
            else
            {
                // Because continuous sustainedControllerInput values are deactivated when below discreteThreshold,
                // we don't need to manually deactivate them first since that will implicitly happen during user gesture.
                self.deltaCore.emulatorBridge.activateInput(input.intValue!, value: adjustedValue, playerIndex: playerIndex)
            }
        }
        else
        {
            // Treat input as deactivated if adjustedValue is nil (a.k.a. below discreteThreshold).
            self.gameController(gameController, didDeactivate: controllerInput)
        }
    }
    
    public func gameController(_ gameController: GameController, didDeactivate input: Input)
    {
        // Ignore controllers without assigned playerIndex.
        guard let playerIndex = gameController.playerIndex else { return }
        
        if !self.gameViews.isEmpty
        {
            // Ignore unless there is a game screen in the active scene.
            guard self.gameViews.contains(where: { $0.window?.windowScene?.hasKeyboardFocus == true }) else { return }
        }
        
        guard let input = self.mappedInput(for: input), input.type == .game(self.gameType) else { return }
        
        self.deltaCore.emulatorBridge.deactivateInput(input.intValue!, playerIndex: playerIndex)
    }
    
    private func mappedInput(for input: Input) -> Input?
    {
        guard let standardInput = StandardGameControllerInput(input: input) else { return input }
        
        let mappedInput = standardInput.input(for: self.gameType)
        return mappedInput
    }
}

private extension EmulatorCore
{
    func runGameLoop()
    {
        let emulationQueue = DispatchQueue(label: "com.rileytestut.DeltaCore.emulationQueue", qos: .userInitiated)
        emulationQueue.async {
            
            let screenRefreshRate = 1.0 / 60.0
            
            var emulationTime = Thread.absoluteSystemTime
            var counter = 0.0
            
            while true
            {
                let frameDuration = self.deltaCore.emulatorBridge.frameDuration / self.rate
                if frameDuration != self.previousFrameDuration
                {
                    Thread.setRealTimePriority(withPeriod: frameDuration)
                    
                    self.previousFrameDuration = frameDuration
                    
                    // Reset counter
                    counter = 0
                }
                
                // Update audio configurations if necessary.
                
                let internalFrameDuration = self.deltaCore.emulatorBridge.frameDuration
                if internalFrameDuration != self.audioManager.frameDuration
                {
                    self.audioManager.frameDuration = internalFrameDuration
                }
                
                let audioFormat = self.deltaCore.audioFormat
                if audioFormat != self.audioManager.audioFormat
                {
                    self.audioManager.audioFormat = audioFormat
                }
                
                if counter >= screenRefreshRate
                {
                    self.runFrame(renderGraphics: true)
                    
                    // Reset counter
                    counter = 0
                }
                else
                {
                    // No need to render graphics more than once per screen refresh rate
                    self.runFrame(renderGraphics: false)
                }
                
                counter += frameDuration
                emulationTime += frameDuration
                
                let currentTime = Thread.absoluteSystemTime
                
                // The number of frames we need to skip to keep in sync
                var framesToSkip = Int((currentTime - emulationTime) / frameDuration)
                framesToSkip = min(framesToSkip, 5) // Prevent unbounding frame skipping resulting in frozen game.
                
                if framesToSkip > 0
                {
                    #if DEBUG
                    self.debugFrameTrace?.record("loop.catchup", value: Double(framesToSkip), detail: self.rate == 1 ? 1 : 0)
                    #endif
                    // Only actually skip frames if we're running at normal speed
                    if self.rate == 1.0
                    {
                        for _ in 0 ..< framesToSkip
                        {
                            // "Skip" frames by running them without rendering graphics
                            self.runFrame(renderGraphics: false)
                        }
                    }
                    
                    emulationTime = currentTime
                }
                
                // Prevent race conditions
                let state = self._state
                
                defer
                {                    
                    if self.previousState != state
                    {
                        self.previousState = state
                        NotificationCenter.default.post(name: EmulatorCore.didUpdateFrameNotification, object: self)
                    }
                }
                
                if state != .running
                {
                    break
                }
                
                Thread.realTimeWait(until: emulationTime)
            }
        }
    }
    
    func runFrame(renderGraphics: Bool)
    {
        #if DEBUG
        let trace = self.debugFrameTrace
        let tracedFrame = trace?.beginFrame(renderGraphics: renderGraphics) ?? 0
        self.videoManager.debugBeginFrame(trace: trace, frame: tracedFrame)
        let frameStarted = trace == nil ? 0 : ProcessInfo.processInfo.systemUptime
        #endif
        self.deltaCore.emulatorBridge.runFrame(processVideo: renderGraphics)
        #if DEBUG
        trace?.record("frame.emulate", frame: tracedFrame, at: frameStarted,
                      duration: ProcessInfo.processInfo.systemUptime - frameStarted)
        #endif
        
        if renderGraphics
        {
            self.videoManager.render()
        }
        
        if let dispatchGroup = self.reactivateInputsDispatchGroup
        {
            dispatchGroup.leave()
        }
        
        #if DEBUG
        if let trace { trace.measure("frame.updateHandler", frame: tracedFrame) { self.updateHandler?(self) } }
        else { self.updateHandler?(self) }
        trace?.record("frame.end", frame: tracedFrame, at: frameStarted,
                      duration: ProcessInfo.processInfo.systemUptime - frameStarted)
        #else
        self.updateHandler?(self)
        #endif
    }
}

private extension EmulatorCore
{
    @objc func emulationDidQuit(_ notification: Notification)
    {
        guard let bridge = notification.object as? EmulatorBridging, bridge.gameURL == self.game.fileURL else { return }
        
        // Re-post notification with `self` as object.
        NotificationCenter.default.post(name: EmulatorCore.emulationDidQuitNotification, object: self, userInfo: nil)
        
        DispatchQueue.global(qos: .userInitiated).async {
            // Dispatch onto global queue to prevent deadlock.
            self.stop()
        }
    }
}
