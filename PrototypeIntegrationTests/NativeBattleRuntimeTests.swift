import XCTest
import UIKit
import CryptoKit
import DeltaCore
import Network
@testable import Delta

private struct NativeBattleGame:GameProtocol {
    let fileURL:URL
    let gameSaveURL:URL
    var type:GameType { .gba }
}
private final class NativeBattleDriver:@unchecked Sendable {
    private let lock=NSLock()
    private let reader=BoundVBAPlayerStateProbe()
    private var frame=0,battleFrame:Int?,lastMask=0
    private var playing=false,moves=false,didBoot=false,didDamage=false
    private var initialHP:[Int]?
    let booted=XCTestExpectation(description:"Native overworld")
    let entered=XCTestExpectation(description:"Native battle")
    let damage=XCTestExpectation(description:"Native battle damage")
    init(core:EmulatorCore,profile:BoundPlayerROMProfile) {
        reader.configure(coreID:ObjectIdentifier(core),profile:profile,active:true,status:.waiting,detail:"Native battle cold boot")
    }
    func play(moves:Bool) { lock.lock(); playing=true; self.moves=moves; lock.unlock() }
    var damaged:Bool { lock.lock(); defer { lock.unlock() }; return didDamage }
    func receive(_ core:EmulatorCore) {
        frame+=1
        lock.lock(); let playing=playing,moves=moves; lock.unlock()
        if !playing {
            let value=reader.receive(core)
            if value?.status == .live,!didBoot { didBoot=true; booted.fulfill() }
            apply(didBoot ? 0:(1300..<1302).contains(frame) ? 8:(1600..<1602).contains(frame)||(2200..<2202).contains(frame) ? 1:0,core:core)
            return
        }
        let battle=BoundVBABattleBridge.isInBattle()
        if battle,battleFrame==nil { battleFrame=frame; entered.fulfill() }
        let hp=BoundVBABattleBridge.playerHP().map { $0.intValue }
        if battle,hp.first ?? 0>0,initialHP==nil { initialHP=hp }
        if battle,let initialHP,hp != initialHP {
            lock.lock(); let first = !didDamage; didDamage=true; lock.unlock()
            if first { damage.fulfill() }
        }
        if battle,moves,let battleFrame,frame-battleFrame>120 { apply((frame-battleFrame)%12<2 ? 1:0,core:core) }
        else { apply(0,core:core) }
    }
    private func apply(_ mask:Int,core:EmulatorCore) {
        for bit in [1,8] where mask&bit != lastMask&bit {
            if mask&bit != 0 { core.deltaCore.emulatorBridge.activateInput(bit,value:1,playerIndex:0) }
            else { core.deltaCore.emulatorBridge.deactivateInput(bit,playerIndex:0) }
        }
        lastMask=mask
    }
}

@MainActor
final class NativeBattleRuntimeTests:XCTestCase {
    private var previousExperimentalFeature: Any?
    override func setUp() {
        super.setUp()
        previousExperimentalFeature = UserDefaults.standard.object(forKey: BoundMultiplayerFeatures.key)
        BoundMultiplayerFeatures.setEnabled(true)
    }
    override func tearDown() {
        UserDefaults.standard.set(previousExperimentalFeature, forKey: BoundMultiplayerFeatures.key)
        NotificationCenter.default.post(name: BoundMultiplayerFeatures.didChange, object: nil)
        super.tearDown()
    }

    func testActualNativeLinkBattle() async throws { try await runNativeBattle(entryOnly:false) }
    func testNativeSessionForwardedEntry() async throws { try await runNativeBattle(entryOnly:true) }
    private func runNativeBattle(entryOnly:Bool) async throws {
        continueAfterFailure=false
        let env=ProcessInfo.processInfo.environment
        guard let peer=env["BOUND_NATIVE_BATTLE_PEER"],["A","B"].contains(peer),
              let raw=env["BOUND_NATIVE_BATTLE_PORT"],let port=Int(raw),(1024...65535).contains(port),
              let relayPort=env["BOUND_NATIVE_BATTLE_RELAY_PORT"].flatMap(UInt16.init),
              let uuid=env["BOUND_NATIVE_BATTLE_RELAY_ID"].flatMap(UUID.init(uuidString:)) else {
            throw XCTSkip("Requires the explicit two-owned-simulator native command coordinator with --relay")
        }
        let root=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("FullAppGameplayQA")
        let romURL=root.appendingPathComponent("RadicalRed.gba"),seed=root.appendingPathComponent("seed.sav")
        let rom=try Data(contentsOf:romURL),profile=try BoundPlayerROMProfile(rom:rom),seedBytes=try Data(contentsOf:seed)
        let output=root.appendingPathComponent("native-battle-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
        let battery=output.appendingPathComponent("work.sav"); try seedBytes.write(to:battery)
        let core=try XCTUnwrap(EmulatorCore(game:NativeBattleGame(fileURL:romURL,gameSaveURL:battery),options:[.metal:true]))
        let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous=scene.windows.first { $0.isKeyWindow },window=UIWindow(windowScene:scene),owner=UIViewController(),gameView=GameView()
        window.rootViewController=owner; window.makeKeyAndVisible()
        gameView.frame=CGRect(x:0,y:150,width:window.bounds.width,height:window.bounds.width*2/3)
        owner.view.addSubview(gameView); core.add(gameView)
        let driver=NativeBattleDriver(core:core,profile:profile)
        let native=BoundNativeBattleSession(),interactions=BoundFriendInteractionSession(),probe=native.probe
        core.updateHandler={ core in driver.receive(core); probe.receive(core) }
        var channel:NativeBattleRelayChannel?
        defer {
            native.cancel(resume:false); channel?.close(); native.makeChannel=nil; native.sendControl=nil
            _=core.pause(); BoundVBABattleBridge.close(); _=core.stop()
            window.isHidden=true; previous?.makeKeyAndVisible()
        }
        core.rate=8; XCTAssertTrue(core.start())
        await fulfillment(of:[driver.booted],timeout:90)
        _=core.pause(); core.rate=1
        XCTAssertTrue(BoundVBABattleBridge.verifyBattleReady())
        let before=output.appendingPathComponent("before.state"); core.saveSaveState(to:before)
        native.bind(core:core,gameID:output.lastPathComponent,interactions:interactions)
        native.canResume={ true }
        native.makeChannel={ receiver,failed in
            let value=NativeBattleRelayChannel(port:relayPort,peer:peer,receive:{ data in
                if data.starts(with:BoundBattleControlPacket.prefix) { Task { @MainActor in native.receive(data) } }
                else { receiver(data) }
            },failed:failed)
            channel=value; return value
        }
        native.sendControl={ data in channel?.send(data)==true }
        driver.play(moves:!entryOnly); _=core.resume()
        native.begin(activity:.battle,id:uuid,initiator:peer=="A")
        var entered=false
        for tick in 0..<1200 {
            if tick%100==0 { NSLog("Native entry %@: frame=%llu callback=%08x result=%d %@",peer,native.observation?.frame ?? 0,native.observation?.callback ?? 0,native.observation?.scriptResult ?? -1,native.probe.diagnostics) }
            if native.observation?.battle==true { entered=true; break }
            if !native.isActive { break }
            try await Task.sleep(for:.milliseconds(50))
        }
        XCTAssertTrue(entered,"Native entry failed: \(native.lastFailure), \(native.lastCableDiagnostic), result \(native.observation?.scriptResult ?? -1)")
        _=try await request(port:port,peer:peer,body:["stage":"entered"])
        for _ in 0..<200 {
            let status=try await request(port:port)
            if let peers=status["peers"] as? [String:[String:Any]],peers.count==2,peers.values.allSatisfy({ ["entered","done"].contains($0["stage"] as? String ?? "") }) { break }
            try await Task.sleep(for:.milliseconds(50))
        }
        if entryOnly { native.cancel() }
        else {
            var done=false
            for tick in 0..<8000 {
                if tick%200==0 { NSLog("Native battle %@: frame=%llu callback=%08x HP=%@ %@",peer,native.observation?.frame ?? 0,native.observation?.callback ?? 0,String(describing:native.observation?.playerHP),native.probe.diagnostics) }
                if native.completedBattles==1 { done=true; break }
                if !native.isActive { break }
                try await Task.sleep(for:.milliseconds(50))
            }
            XCTAssertTrue(done,"Native battle failed: \(native.lastFailure), \(native.lastCableDiagnostic)")
            XCTAssertTrue(driver.damaged,"A native move must change party HP")
        }
        _=core.pause()
        XCTAssertEqual(native.restoredBattles,1)
        XCTAssertTrue(BoundVBABattleBridge.verifyBattleReady())
        XCTAssertEqual(try Data(contentsOf:romURL),rom)
        XCTAssertEqual(try Data(contentsOf:seed),seedBytes)
        let report:[String:Any]=["stage":"done","entryOnly":entryOnly,"battle":entered,
            "damaged":driver.damaged,"restored":native.restoredBattles==1,"cable":native.lastCableDiagnostic,
            "outcome":native.observation?.outcome ?? 0]
        try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("report.json"))
        _=try await request(port:port,peer:peer,body:report)
    }
    private func request(port:Int,peer:String?=nil,body:[String:Any]?=nil) async throws->[String:Any] {
        var request=URLRequest(url:URL(string:"http://127.0.0.1:\(port)/"+(peer ?? "status"))!)
        request.timeoutInterval=5
        if let body { request.httpMethod="POST"; request.httpBody=try JSONSerialization.data(withJSONObject:body) }
        let (data,_)=try await URLSession.shared.data(for:request)
        return try JSONSerialization.jsonObject(with:data) as? [String:Any] ?? [:]
    }
}

/// Test-only reliable message channel. The host relay sees cable frames only;
/// wire framing, command admission and native queues use production code.
private final class NativeBattleRelayChannel:BoundBattleChannel,@unchecked Sendable {
    private let queue=DispatchQueue(label:"Native battle test messages")
    private let connection:NWConnection
    private var buffered=Data()
    private var active=true
    private var ready=false
    private var waiting:[Data]=[]
    private let receive:@Sendable (Data)->Void
    private let failed:@Sendable ()->Void
    init(port:UInt16,peer:String,receive:@escaping @Sendable (Data)->Void,failed:@escaping @Sendable ()->Void) {
        self.receive=receive; self.failed=failed
        let tcp=NWProtocolTCP.Options(); tcp.noDelay=true
        connection=NWConnection(host:"127.0.0.1",port:NWEndpoint.Port(rawValue:port)!,using:NWParameters(tls:nil,tcp:tcp))
        connection.stateUpdateHandler={ [weak self] state in
            guard let self,self.active else { return }
            if case .ready=state {
                self.connection.send(content:Data(peer.utf8),completion:.contentProcessed { _ in })
                self.ready=true
                let waiting=self.waiting; self.waiting.removeAll()
                for data in waiting { self.write(data) }
                self.read()
            }
            if case .failed=state { self.failed() }
        }
        connection.start(queue:queue)
    }
    func send(_ data:Data)->Bool {
        guard data.count<=4126 else { return false }
        queue.async { [self] in
            guard active else { return }
            if ready { write(data) }
            else if waiting.count<64 { waiting.append(data) }
            else { failed() }
        }
        return true
    }
    private func write(_ data:Data) {
        let count=data.count
        let header=Data([UInt8(count>>24),UInt8(truncatingIfNeeded:count>>16),UInt8(truncatingIfNeeded:count>>8),UInt8(truncatingIfNeeded:count)])
        connection.send(content:header+data,completion:.contentProcessed { [weak self] error in
            if error != nil,self?.active==true { self?.failed() }
        })
    }
    private func read() {
        connection.receive(minimumIncompleteLength:1,maximumLength:16384) { [weak self] data,_,ended,error in
            guard let self,self.active else { return }
            if let data { self.buffered.append(data) }
            guard self.buffered.count<=131072 else { self.failed(); return }
            while self.buffered.count>=4 {
                let count=self.buffered.prefix(4).reduce(0) { ($0<<8)|Int($1) }
                guard count>30,count<=4126 else { self.failed(); return }
                guard self.buffered.count>=count+4 else { break }
                self.receive(Data(self.buffered.dropFirst(4).prefix(count)))
                self.buffered.removeFirst(count+4)
            }
            if ended || error != nil { self.failed(); return }
            self.read()
        }
    }
    func close() { queue.async { [self] in active=false; connection.cancel() } }
}
