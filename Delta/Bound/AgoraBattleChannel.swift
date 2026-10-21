import Foundation
import AgoraRtcKit

/// Reliable native link commands run on the completed-frame worker.
/// Close fences sends before the owning transport destroys RTC.
final class AgoraBattleChannel:BoundBattleChannel,@unchecked Sendable {
    private let lock=NSRecursiveLock()
    private let sendLock=NSLock()
    private var lastSend:TimeInterval=0
    private var engine:AgoraRtcEngineKit?
    private let uid:Int
    private var framer=BoundBattleRDTFramer()
    private var sends=0,receives=0,frames=0,largestCallback=0
    private var receiver:(@Sendable (Data)->Void)?
    private var failure:(@Sendable ()->Void)?
    init(engine:AgoraRtcEngineKit,uid:UInt,receiver:@escaping @Sendable (Data)->Void,failure:@escaping @Sendable ()->Void) {
        self.engine=engine; self.uid=Int(uid); self.receiver=receiver; self.failure=failure
    }
    func send(_ data:Data)->Bool {
        guard data.count>30,data.count<=256,data.starts(with:BoundBattleWire.prefix) else { return false }
        // The command stream is low latency and permits 100 packets/sec. Pace
        // at 80 on the frame worker, keeping main and receive callbacks free.
        sendLock.lock(); defer { sendLock.unlock() }
        let remaining=lastSend+1.0/80-ProcessInfo.processInfo.systemUptime
        if remaining>0 { Thread.sleep(forTimeInterval:remaining) }
        lock.lock(); defer { lock.unlock() }
        guard let engine else { return false }
        sends+=1; lastSend=ProcessInfo.processInfo.systemUptime
        let result=engine.sendRdtMessage(uid,type:.cmd,data:data)
        if result != 0 { NSLog("Bound battle RDT send failed: %d",result) }
        return result==0
    }
    func receive(_ data:Data) {
        lock.lock(); defer { lock.unlock() }
        guard let receiver else { return }
        receives+=1; largestCallback=max(largestCallback,data.count)
        guard let messages=framer.consume(data) else { failure?(); return }
        frames+=messages.count
        for message in messages { receiver(message) }
    }
    func failed() {
        lock.lock(); let failure=failure; lock.unlock(); failure?()
    }
    func close() {
        lock.lock(); defer { lock.unlock() }
        if engine != nil { NSLog("Bound battle RDT counts: sends=%d callbacks=%d frames=%d maxBytes=%d",sends,receives,frames,largestCallback) }
        engine=nil; receiver=nil; failure=nil
    }
}
