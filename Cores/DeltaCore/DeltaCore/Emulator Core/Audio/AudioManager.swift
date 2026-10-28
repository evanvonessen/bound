//
//  AudioManager.swift
//  DeltaCore
//
//  Created by Riley Testut on 1/12/16.
//  Copyright © 2016 Riley Testut. All rights reserved.
//

import AVFoundation

internal extension AVAudioFormat
{
    var frameSize: Int {
        return Int(self.streamDescription.pointee.mBytesPerFrame)
    }
}

private extension AVAudioSession
{
    func setDeltaCategory(mixWithOthers: Bool = true) throws
    {
        var options: AVAudioSession.CategoryOptions = [.allowBluetoothA2DP, .allowAirPlay]

        if mixWithOthers
        {
            options.insert(.mixWithOthers)
        }

        try self.setCategory(.playAndRecord, options: options)
    }
}

private extension AVAudioSessionRouteDescription
{
    var isHeadsetPluggedIn: Bool
    {
        let isHeadsetPluggedIn = self.outputs.contains { $0.portType == .headphones || $0.portType == .bluetoothA2DP }
        return isHeadsetPluggedIn
    }
    
    var isOutputtingToReceiver: Bool
    {
        let isOutputtingToReceiver = self.outputs.contains { $0.portType == .builtInReceiver }
        return isOutputtingToReceiver
    }
    
    var isOutputtingToExternalDevice: Bool
    {
        let isOutputtingToExternalDevice = self.outputs.contains { $0.portType != .builtInSpeaker && $0.portType != .builtInReceiver }
        return isOutputtingToExternalDevice
    }
}

/// Callback-owned state. Starvation is a valid silent render, never a failed
/// AudioUnit render that strands an otherwise running emulator producer.
struct BufferedAudioSource {
    let buffer: RingBuffer
    let frameSize: Int
    let primingMultiplier: Int
    private var isPrimed = false

    init(buffer: RingBuffer, frameSize: Int, primingMultiplier: Int) {
        self.buffer = buffer; self.frameSize = frameSize; self.primingMultiplier = primingMultiplier
    }

    mutating func render(frameCount: AVAudioFrameCount, buffers: UnsafeMutableAudioBufferListPointer,
                         isSilence: UnsafeMutablePointer<ObjCBool>) -> OSStatus {
        guard !buffers.isEmpty, let output = buffers[0].mData else { return kAudioFileStreamError_UnspecifiedError }
        let requested = Int(frameCount) * frameSize
        func silence() -> OSStatus {
            for item in buffers { if let data = item.mData { memset(data, 0, Int(item.mDataByteSize)) } }
            isSilence.pointee = true
            return noErr
        }
        guard requested <= Int(buffers[0].mDataByteSize) else { isPrimed = false; return silence() }
        let threshold = requested * (isPrimed ? 1 : primingMultiplier)
        guard buffer.availableBytesForReading >= threshold else { isPrimed = false; return silence() }
        let count = buffer.read(into: output, preferredSize: requested)
        guard count > 0 else { isPrimed = false; return silence() }
        if count < requested { memset(output.advanced(by: count), 0, requested - count) }
        buffers[0].mDataByteSize = UInt32(requested)
        isSilence.pointee = false; isPrimed = true
        return noErr
    }
}

public class AudioManager: NSObject, AudioRendering
{
    /// Currently only supports 16-bit interleaved Linear PCM.
    private struct PlaybackState {
        var started = false
        var enabled = true
        var playbackMuted = false
        var respectsSilentMode = true
        var mixesWithOtherAudio = false
        var pausesOtherAudio = false
        var systemMuted = false
        var rate = 1.0
        var frameDuration = 1.0 / 60.0
    }
    private let stateLock = NSLock()
    private var playback = PlaybackState()
    private var storedFormat: AVAudioFormat
    private var storedBuffer: RingBuffer
    private var configurationGeneration: UInt64 = 0 // stateLock

    public internal(set) var audioFormat: AVAudioFormat {
        get { stateLock.lock(); defer { stateLock.unlock() }; return storedFormat }
        set {
            stateLock.lock()
            guard storedFormat != newValue else { stateLock.unlock(); return }
            storedFormat = newValue; configurationGeneration &+= 1
            storedBuffer.isEnabled = false; stateLock.unlock()
            resetAudioEngine()
        }
    }
    public var audioBuffer: RingBuffer {
        stateLock.lock(); defer { stateLock.unlock() }; return storedBuffer
    }
    public var isEnabled: Bool {
        get { stateSnapshot.enabled }
        set {
            stateLock.lock()
            guard playback.enabled != newValue else { stateLock.unlock(); return }
            playback.enabled = newValue
            // Stop producer writes immediately. Resume only after the queued
            // engine/session transition has finished.
            storedBuffer.isEnabled = false; stateLock.unlock()
            renderingQueue.async { self.applyPlaybackState() }
        }
    }
    /// User mute survives core pause/resume and audio route changes.
    public var isPlaybackMuted: Bool {
        get { stateSnapshot.playbackMuted }
        set { changeState { $0.playbackMuted = newValue }; scheduleSettingsUpdate() }
    }
    public var respectsSilentMode: Bool {
        get { stateSnapshot.respectsSilentMode }
        set { changeState { $0.respectsSilentMode = newValue }; scheduleSettingsUpdate() }
    }
    public var mixesWithOtherAudio: Bool {
        get { stateSnapshot.mixesWithOtherAudio }
        set { changeState { $0.mixesWithOtherAudio = newValue }; scheduleSettingsUpdate() }
    }
    public var pausesOtherAudio: Bool {
        get { stateSnapshot.pausesOtherAudio }
        set { changeState { $0.pausesOtherAudio = newValue }; scheduleSettingsUpdate() }
    }
    public internal(set) var rate: Double {
        get { stateSnapshot.rate }
        set {
            changeState { $0.rate = newValue }
            renderingQueue.async { if self.enginePrepared { self.timePitchEffect.rate = Float(self.rate) } }
        }
    }
    var frameDuration: Double {
        get { stateSnapshot.frameDuration }
        set {
            stateLock.lock()
            guard playback.frameDuration != newValue else { stateLock.unlock(); return }
            playback.frameDuration = newValue; configurationGeneration &+= 1
            storedBuffer.isEnabled = false; stateLock.unlock()
            resetAudioEngine()
        }
    }

    // Created and used exclusively on renderingQueue, after setting a mixing
    // category. Constructing a core never configures the Mac audio device on UI.
    private lazy var audioEngine = AVAudioEngine()
    private lazy var audioPlayerNode = AVAudioPlayerNode()
    private lazy var timePitchEffect = AVAudioUnitTimePitch()
    private var enginePrepared = false
    private var configuredSampleRate: Double = 0
    private var engineStartFailed = false
    private var engineGeneration: UInt64?
    private var sessionConfigured = false // audioQueue only
    
    @available(iOS 13.0, *)
    private var sourceNode: AVAudioSourceNode {
        get {
            return _sourceNode as! AVAudioSourceNode
        }
        set {
            _sourceNode = newValue
        }
    }
    private var _sourceNode: Any! = nil
    
    private var audioConverter: AVAudioConverter?
    private var audioConverterRequiredFrameCount: AVAudioFrameCount?
    
    private let audioBufferCount = 3
    
    // AVAudioSession belongs to the process. Ordering all managers on the same
    // queue prevents an old core's queued stop from overtaking its replacement.
    private static let audioQueue = DispatchQueue(label: "com.rileytestut.Delta.AudioManager.renderingQueue", qos: .userInitiated)
    private static var sessionOwners = Set<ObjectIdentifier>() // audioQueue only
    private let renderingQueue = AudioManager.audioQueue
    
    private var isMuted: Bool {
        get { stateSnapshot.systemMuted }
        set { changeState { $0.systemMuted = newValue }; scheduleSettingsUpdate() }
    }
    
    private let muteSwitchMonitor = DLTAMuteSwitchMonitor()
        
    public init(audioFormat: AVAudioFormat)
    {
        self.storedFormat = audioFormat
        
        // Temporary. Will be replaced with more accurate RingBuffer in resetAudioEngine().
        self.storedBuffer = RingBuffer(preferredBufferSize: 4096)!
        self.storedBuffer.isEnabled = false
        super.init()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        let owner = ObjectIdentifier(self)
        let engine = enginePrepared ? audioEngine : nil
        let node = enginePrepared ? audioPlayerNode : nil
        AudioManager.audioQueue.async {
            node?.stop(); engine?.stop()
            if AudioManager.sessionOwners.remove(owner) != nil, AudioManager.sessionOwners.isEmpty {
                try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }
}

public extension AudioManager
{
    func start()
    {
        guard !stateSnapshot.started else { return }
        changeState { $0.started = true }
        self.muteSwitchMonitor.startMonitoring { [weak self] (isMuted) in
            self?.isMuted = isMuted
        }
        renderingQueue.async {
          guard self.stateSnapshot.started else { return }
          AudioManager.sessionOwners.insert(ObjectIdentifier(self))
          do {
            // Interrupt other audio by activating a non-mixing session.
            if self.shouldInterruptOtherAudio
            {
                // Explicitly say 'don't mix with others' to pause anything else that's playing
                // Then change the category below to allow other audio to be resumed if mixing is on
                try AVAudioSession.sharedInstance().setDeltaCategory(mixWithOthers: false)
                try AVAudioSession.sharedInstance().setActive(true)
            }

            // Allow other audio if mixing is on, OR we're not interrupting other audio anyways.
            try AVAudioSession.sharedInstance().setDeltaCategory(mixWithOthers: self.mixesWithOtherAudio || !self.shouldInterruptOtherAudio)
            try AVAudioSession.sharedInstance().setPreferredIOBufferDuration(0.005)
            
            if #available(iOS 13.0, *)
            {
               try AVAudioSession.sharedInstance().setAllowHapticsAndSystemSoundsDuringRecording(true)
            }
            
            try AVAudioSession.sharedInstance().setActive(true)
          } catch {
            print(error)
          }
          self.sessionConfigured = true
          self.resetAudioEngineOnQueue()
          guard self.stateSnapshot.started else { return }
          NotificationCenter.default.removeObserver(self, name: .AVAudioEngineConfigurationChange, object: nil)
          NotificationCenter.default.removeObserver(self, name: AVAudioSession.routeChangeNotification, object: nil)
          NotificationCenter.default.addObserver(self, selector: #selector(AudioManager.audioConfigurationChanged(_:)), name: .AVAudioEngineConfigurationChange, object: self.audioEngine)
          NotificationCenter.default.addObserver(self, selector: #selector(AudioManager.audioConfigurationChanged(_:)), name: AVAudioSession.routeChangeNotification, object: nil)
        }
    }
    
    func stop()
    {
        changeState { $0.started = false }
        self.audioBuffer.isEnabled = false
        self.muteSwitchMonitor.stopMonitoring()
        
        // Remove observers before deactivating — otherwise deactivation could trigger a reset, which would undo setActive(false) below.
        NotificationCenter.default.removeObserver(self, name: .AVAudioEngineConfigurationChange, object: nil)
        NotificationCenter.default.removeObserver(self, name: AVAudioSession.routeChangeNotification, object: nil)

        self.renderingQueue.async {
          self.sessionConfigured = false
          NotificationCenter.default.removeObserver(self, name: .AVAudioEngineConfigurationChange, object: nil)
          NotificationCenter.default.removeObserver(self, name: AVAudioSession.routeChangeNotification, object: nil)
          if self.enginePrepared {
            self.audioPlayerNode.stop(); self.audioEngine.stop()
          }
          self.audioBuffer.reset()
          AudioManager.sessionOwners.remove(ObjectIdentifier(self))
          guard AudioManager.sessionOwners.isEmpty else { return }
          do {
            // Relinquish audio session so other apps can resume playback.
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
          } catch {
            print(error)
          }
        }
    }
}

private extension AudioManager
{
    private var stateSnapshot: PlaybackState {
        stateLock.lock(); defer { stateLock.unlock() }; return playback
    }
    private func changeState(_ change: (inout PlaybackState) -> Void) {
        stateLock.lock(); defer { stateLock.unlock() }; change(&playback)
    }
    func enableCurrentBuffer(generation: UInt64) {
        stateLock.lock(); defer { stateLock.unlock() }
        storedBuffer.isEnabled = playback.started && playback.enabled && configurationGeneration == generation
    }
    func scheduleSettingsUpdate() {
        renderingQueue.async {
            guard self.enginePrepared, self.sessionConfigured else { return }
            self.updateAudioSessionCategory(); self.updateOutputVolume()
        }
    }
    func applyPlaybackState() {
        guard enginePrepared, sessionConfigured else { return }
        audioEngine.pause()
        audioBuffer.isEnabled = false
        // The producer is gated and the callback has stopped. Only now can
        // lifecycle code clear the consumer-owned tail safely.
        audioBuffer.reset()
        guard stateSnapshot.started, isEnabled else { updateOutputVolume(); return }
        stateLock.lock(); let generation = configurationGeneration; stateLock.unlock()
        guard engineGeneration == generation else { resetAudioEngineOnQueue(); return }
        do {
            try audioEngine.start()
            engineStartFailed = false
            if #available(iOS 13.0, *) {} else { audioPlayerNode.play() }
            updateAudioSessionCategory(); updateOutputVolume()
            enableCurrentBuffer(generation: generation)
        } catch { engineStartFailed = true; print(error) }
    }
    func render(_ inputBuffer: AVAudioPCMBuffer, into outputBuffer: AVAudioPCMBuffer)
    {
        guard let buffer = inputBuffer.int16ChannelData, let audioConverter = self.audioConverter else { return }
        let format = inputBuffer.format
        
        // Ensure any buffers from previous audio route configurations are no longer processed.
        guard inputBuffer.format == audioConverter.inputFormat && outputBuffer.format == audioConverter.outputFormat else { return }
        
        if self.audioConverterRequiredFrameCount == nil
        {
            // Determine the minimum number of input frames needed to perform a conversion.
            audioConverter.convert(to: outputBuffer, error: nil) { (requiredPacketCount, outStatus) -> AVAudioBuffer? in
                // In Linear PCM, one packet = one frame.
                self.audioConverterRequiredFrameCount = requiredPacketCount
                
                // Setting to ".noDataNow" sometimes results in crash, so we set to ".endOfStream" and reset audioConverter afterwards.
                outStatus.pointee = .endOfStream
                return nil
            }
            
            audioConverter.reset()
        }
        
        guard let audioConverterRequiredFrameCount = self.audioConverterRequiredFrameCount else { return }
        
        let availableFrameCount = AVAudioFrameCount(self.audioBuffer.availableBytesForReading / format.frameSize)
        if self.audioEngine.isRunning && availableFrameCount >= audioConverterRequiredFrameCount
        {            
            var conversionError: NSError?
            let status = audioConverter.convert(to: outputBuffer, error: &conversionError) { (requiredPacketCount, outStatus) -> AVAudioBuffer? in
                
                // Copy requiredPacketCount frames into inputBuffer's first channel (since audio is interleaved, no need to modify other channels).
                let preferredSize = min(Int(requiredPacketCount) * format.frameSize, Int(inputBuffer.frameCapacity) * format.frameSize)
                buffer[0].withMemoryRebound(to: UInt8.self, capacity: preferredSize) { (uint8Buffer) in
                    let readBytes = self.audioBuffer.read(into: uint8Buffer, preferredSize: preferredSize)
                    
                    let frameLength = AVAudioFrameCount(readBytes / format.frameSize)
                    inputBuffer.frameLength = frameLength
                }
                
                if inputBuffer.frameLength == 0
                {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                else
                {
                    outStatus.pointee = .haveData
                    return inputBuffer
                }
            }
            
            if status == .error
            {
                if let error = conversionError
                {
                    print(error, error.userInfo)
                }
            }
        }
        else
        {
            // If not running or not enough input frames, set frameLength to 0 to minimize time until we check again.
            inputBuffer.frameLength = 0
        }
        
        self.audioPlayerNode.scheduleBuffer(outputBuffer) { [weak self, weak node = audioPlayerNode] in
            guard let self = self else { return }
            
            self.renderingQueue.async {
                if node?.isPlaying == true
                {
                    self.render(inputBuffer, into: outputBuffer)
                }
            }
        }
    }
    
    @objc func resetAudioEngine()
    {
        self.renderingQueue.async { self.resetAudioEngineOnQueue() }
    }

    @objc func audioConfigurationChanged(_ notification: Notification)
    {
        let isRouteChange = notification.name == AVAudioSession.routeChangeNotification
        let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        self.renderingQueue.async {
            guard self.stateSnapshot.started, self.enginePrepared, self.sessionConfigured else { return }
            let sampleRate = AVAudioSession.sharedInstance().sampleRate
            guard sampleRate.isFinite, sampleRate > 0 else { return }
            if self.engineStartFailed && sampleRate == self.configuredSampleRate {
                // A failed start must not retry on its own graph/category
                // notifications. A real device change or explicit resume may retry.
                let reason = rawReason.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
                guard isRouteChange,
                      reason == .newDeviceAvailable || reason == .oldDeviceUnavailable || reason == .wakeFromSleep || reason == .routeConfigurationChange else { return }
            }
            // Session/category and our own graph changes can notify us again.
            // A working graph (or intentionally paused one) needs no rebuild.
            if sampleRate == self.configuredSampleRate && (self.audioEngine.isRunning || !self.isEnabled) { return }
            self.resetAudioEngineOnQueue()
        }
    }

    func resetAudioEngineOnQueue()
    {
            stateLock.lock()
            let format = storedFormat, settings = playback, generation = configurationGeneration
            stateLock.unlock()
            guard settings.started, sessionConfigured else { return }
            if !enginePrepared {
                self.audioEngine.attach(self.audioPlayerNode)
                self.audioEngine.attach(self.timePitchEffect)
                enginePrepared = true
            }
            self.audioBuffer.isEnabled = false
            self.audioEngine.stop()
            self.audioPlayerNode.reset()
            
            let sampleRate = AVAudioSession.sharedInstance().sampleRate
            guard sampleRate.isFinite, sampleRate > 0,
                  format.sampleRate.isFinite, format.sampleRate > 0,
                  settings.frameDuration.isFinite, settings.frameDuration > 0,
                  let outputAudioFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: format.channelCount) else { self.engineStartFailed = true; return }
            self.configuredSampleRate = outputAudioFormat.sampleRate
            self.engineGeneration = generation
            
            let inputAudioBufferFrameCount = Int(format.sampleRate * settings.frameDuration)
            let outputAudioBufferFrameCount = Int(outputAudioFormat.sampleRate * settings.frameDuration)
            
            // Allocate enough space to prevent us from overwriting data before we've used it.
            let ringBufferAudioBufferCount = Int((format.sampleRate / outputAudioFormat.sampleRate).rounded(.up) + 10.0)
            
            let preferredBufferSize = inputAudioBufferFrameCount * format.frameSize * ringBufferAudioBufferCount
            guard let ringBuffer = RingBuffer(preferredBufferSize: preferredBufferSize) else {
                fatalError("Cannot initialize RingBuffer with preferredBufferSize of \(preferredBufferSize)")
            }
            ringBuffer.isEnabled = false
            self.stateLock.lock(); self.storedBuffer = ringBuffer; self.stateLock.unlock()
            
            let audioConverter = AVAudioConverter(from: format, to: outputAudioFormat)
            self.audioConverter = audioConverter
            
            self.audioConverterRequiredFrameCount = nil
            
            self.audioEngine.disconnectNodeOutput(self.timePitchEffect)
            self.audioEngine.connect(self.timePitchEffect, to: self.audioEngine.mainMixerNode, format: outputAudioFormat)

            if #available(iOS 13.0, *)
            {
                if let existing = self._sourceNode as? AVAudioSourceNode { self.audioEngine.detach(existing) }
                
                self.sourceNode = self.makeSourceNode(format: format, buffer: ringBuffer, outputSampleRate: outputAudioFormat.sampleRate)
                self.audioEngine.attach(self.sourceNode)
                
                self.audioEngine.connect(self.sourceNode, to: self.timePitchEffect, format: outputAudioFormat)
            }
            else
            {
                self.audioEngine.disconnectNodeOutput(self.audioPlayerNode)
                self.audioEngine.connect(self.audioPlayerNode, to: self.timePitchEffect, format: outputAudioFormat)
                
                for _ in 0 ..< self.audioBufferCount
                {
                    let inputAudioBufferFrameCapacity = max(inputAudioBufferFrameCount, outputAudioBufferFrameCount)
                    
                    if let inputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(inputAudioBufferFrameCapacity)),
                        let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputAudioFormat, frameCapacity: AVAudioFrameCount(outputAudioBufferFrameCount))
                    {
                        self.render(inputBuffer, into: outputBuffer)
                    }
                }
            }
            
            do
            {
                // Explicitly set output port since .defaultToSpeaker option pauses external audio.
                if AVAudioSession.sharedInstance().currentRoute.isOutputtingToReceiver
                {
                    try AVAudioSession.sharedInstance().overrideOutputAudioPort(.speaker)
                }
                
                self.updateOutputVolume()
                self.timePitchEffect.rate = Float(self.rate)
                if self.isEnabled && self.stateSnapshot.started {
                    try self.audioEngine.start()
                    self.engineStartFailed = false
                    self.updateAudioSessionCategory(); self.updateOutputVolume()
                    self.enableCurrentBuffer(generation: generation)
                }
                else { self.audioEngine.pause() }

                if #available(iOS 13.0, *) {}
                else
                {
                    if self.isEnabled { self.audioPlayerNode.play() }
                }
            }
            catch
            {
                self.engineStartFailed = true; print(error)
            }
        self.updateAudioSessionCategory()
    }
    
    // Interrupt other audio if the user wants to pause it AND we won't be silent.
    private var shouldInterruptOtherAudio: Bool
    {
        return self.pausesOtherAudio && !self.isPlaybackMuted && !(self.respectsSilentMode && self.isMuted)
    }
    
    private func updateAudioSessionCategory()
    {
        guard self.audioEngine.isRunning else { return }

        // Allow other audio if mixing is on, OR we're not interrupting other audio anyways.
        let allowMixing = self.mixesWithOtherAudio || !self.shouldInterruptOtherAudio

        let currentlyMixing = AVAudioSession.sharedInstance().categoryOptions.contains(.mixWithOthers)
        guard allowMixing != currentlyMixing else { return }

        do
        {
            try AVAudioSession.sharedInstance().setDeltaCategory(mixWithOthers: allowMixing)
        }
        catch
        {
            print(error)
        }
    }

    @objc func updateOutputVolume()
    {
        if !self.isEnabled || self.isPlaybackMuted
        {
            self.audioEngine.mainMixerNode.outputVolume = 0.0
        }
        else
        {
            let route = AVAudioSession.sharedInstance().currentRoute
            
            if AVAudioSession.sharedInstance().isOtherAudioPlaying && !self.mixesWithOtherAudio
            {
                // Mute if another app is playing audio and we're not mixing with it.
                self.audioEngine.mainMixerNode.outputVolume = 0.0
            }
            else if self.respectsSilentMode
            {
                if self.isMuted && (route.isHeadsetPluggedIn || !route.isOutputtingToExternalDevice)
                {
                    // Respect mute switch IFF playing through speaker or headphones.
                    self.audioEngine.mainMixerNode.outputVolume = 0.0
                }
                else
                {
                    // Ignore mute switch for other audio routes (e.g. AirPlay).
                    self.audioEngine.mainMixerNode.outputVolume = 1.0
                }
            }
            else
            {
                // Ignore silent mode and always play game audio (unless another app is playing audio).
                self.audioEngine.mainMixerNode.outputVolume = 1.0
            }
        }
    }
    
    @available(iOS 13.0, *)
    func makeSourceNode(format: AVAudioFormat, buffer: RingBuffer, outputSampleRate: Double) -> AVAudioSourceNode
    {
        let sampleRateRatio = max(1, (format.sampleRate / outputSampleRate).rounded(.up))
        var reader = BufferedAudioSource(buffer: buffer, frameSize: format.frameSize,
                                         primingMultiplier: Int(sampleRateRatio))
        let sourceNode = AVAudioSourceNode(format: format) { (isSilence, _, frameCount, audioBufferList) -> OSStatus in
            reader.render(frameCount: frameCount, buffers: UnsafeMutableAudioBufferListPointer(audioBufferList), isSilence: isSilence)
        }

        return sourceNode
    }
}
