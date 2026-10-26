import XCTest
import UIKit
@testable import Delta

private actor DebugHTTPFixture {
    var requests:[URLRequest]=[]
    let status:Int,data:Data,redirect:Bool
    init(status:Int=200,data:Data=Data("{\"version\":1}".utf8),redirect:Bool=false) {
        self.status=status;self.data=data;self.redirect=redirect
    }
    func call(_ request:URLRequest)->BoundDebugService.Response {
        requests.append(request)
        return .init(data:data,status:status,url:redirect ? URL(string:"https://unrelated.example/"):request.url)
    }
    func captured()->[URLRequest] { requests }
}

private actor DebugMemoryIntentStore:BoundDebugIntentStorage {
    var state:BoundDebugLocalState?,blobs:[UUID:Data]=[:]
    var returnedExpectation:XCTestExpectation?
    func load(owner:UUID,room:UUID)->BoundDebugLocalState? { state?.ownerID==owner && state?.roomID==room ? state:nil }
    func save(_ state:BoundDebugLocalState) {
        self.state=state
        if state.phase == .returned { returnedExpectation?.fulfill();returnedExpectation=nil }
    }
    func observeReturn(_ expectation:XCTestExpectation) {
        if state?.phase == .returned { expectation.fulfill() } else { returnedExpectation=expectation }
    }
    func savePayload(_ bytes:Data,owner:UUID,operation:UUID) throws {
        if let existing=blobs[operation],existing != bytes { throw BoundDebugFailure.storage };blobs[operation]=bytes
    }
    func payload(owner:UUID,operation:UUID)->Data? { blobs[operation] }
}

private actor DebugProtocolFixture:BoundDebugServing {
    var session:BoundDebugServerSession,operation:BoundDebugOperation?,manifest:BoundDebugManifest?,descriptor:BoundDebugOwnerDescriptor?
    var requestTimeouts:[TimeInterval]=[]
    var chunks:[Int:String]=[:],requests:[[String:BoundDebugJSON]]=[],prepared:[UUID:BoundDebugJSON]=[:]
    var history:[UUID:(BoundDebugOperation,BoundDebugManifest,BoundDebugOwnerDescriptor,[Int:String])]=[:]
    var timeoutPrepare=true,peerVerified=false,tamperDownload=false,returned=false,nextGeneration=0,peerPrepared=true,loseReturnCommits=0,loseReturnStatuses=0
    var lostBoundaryAction:String?,boundaryOffline=false,dropBoundaryBeforeApply=false
    var requiredReturnCheckpoint:UUID?
    var delayCaptureCut=false,delayedCut:BoundDebugHistoryCut?
    var terminalProofValue:BoundDebugTerminalProof?
    let owner:UUID,peer:UUID,settings=Data(repeating:0,count:32)
    init(owner:UUID,peer:UUID,room:UUID,joined:Bool=true) {
        self.owner=owner;self.peer=peer
        session = .init(sessionID:UUID(),roomID:room,owners:[owner,peer],controllerID:owner,membershipEpoch:1,
            joined:joined ? [owner,peer]:[owner],status:joined ? .active:.invited,currentGeneration:0)
    }
    func setPeerVerified(_ value:Bool) { peerVerified=value }
    func setPeerPrepared(_ value:Bool) { peerPrepared=value }
    func expirePendingOperation() { operation?.deadline=Date().timeIntervalSince1970-1 }
    func loseReturnCommitResponses() { loseReturnCommits=3;loseReturnStatuses=1 }
    func loseBoundaryReply(_ action:String,beforeApply:Bool=false) { lostBoundaryAction=action;dropBoundaryBeforeApply=beforeApply }
    func restoreBoundaryNetwork() { boundaryOffline=false;lostBoundaryAction=nil }
    func requireReturnCheckpoint(_ value:UUID) { requiredReturnCheckpoint=value }
    func delayNextCaptureCut() { delayCaptureCut=true }
    func activateNewerGeneration() throws -> Int {
        let active=try XCTUnwrap(history.values.first { $0.0.generation==session.currentGeneration })
        nextGeneration+=1
        var next=active.0;next.operationID=UUID();next.generation=nextGeneration;next.kind = .reload;next.state = .ready
        var nextManifest=active.1;nextManifest.operationID=next.operationID;nextManifest.generation=next.generation
        var canonical=try BoundDebugJSON.wire(nextManifest).object!;canonical.removeValue(forKey:"digest")
        nextManifest.digest=BoundDebugJSON.digest(try BoundDebugJSON.object(canonical).data())
        history[next.operationID]=(next,nextManifest,active.2,active.3)
        operation=next;manifest=nextManifest;descriptor=active.2
        session.currentGeneration=next.generation;session.currentManifestDigest=nextManifest.digest;session.activeOperationID=nil
        return next.generation
    }
    func makeBuddyInvitation() { session.controllerID=peer;session.joined=[peer];session.status = .invited }
    func currentSession()->BoundDebugServerSession { session }
    func corruptDownload() { tamperDownload=true }
    func captured()->[[String:BoundDebugJSON]] { requests }
    func capturedTimeouts()->[TimeInterval] { requestTimeouts }
    func markCurrentGenerationTerminal() throws -> BoundDebugTerminalProof {
        let record=try XCTUnwrap(history.values.first { $0.0.generation==session.currentGeneration }),d=record.2
        let proof=BoundDebugTerminalProof(sessionID:session.sessionID,membershipEpoch:session.membershipEpoch,generation:session.currentGeneration,
            manifestDigest:record.1.digest,runID:record.1.runID,eventID:UUID(),ownerID:owner,deviceID:d.deviceID,ownershipEpoch:d.ownershipEpoch)
        terminalProofValue=proof;return proof
    }
    func replaceTerminalProof(_ proof:BoundDebugTerminalProof) { terminalProofValue=proof }
    /// A server-admitted generation retained across an app/profile upgrade.
    /// This bypasses only the fixture's new-prepare path, never client validation.
    func seedCommitted(_ value:BoundDebugOperation,payload:BoundDebugPreparedPayload,auth:AppCloudSession) throws -> BoundDebugManifest {
        operation=value;nextGeneration=value.generation;descriptor=payload.descriptor;peerVerified=true;timeoutPrepare=false
        let encoded=Array(payload.bytes.base64EncodedString().utf8)
        chunks=Dictionary(uniqueKeysWithValues:(0..<payload.descriptor.count).map { index in
            (index,String(decoding:encoded[(index*12_000)..<min(encoded.count,(index+1)*12_000)],as:UTF8.self))
        })
        _=try request(["action":.string("commit")],session:auth)
        _=try request(["action":.string("verify"),"operationID":.string(value.operationID.uuidString.lowercased())],session:auth)
        return try XCTUnwrap(manifest)
    }
    func request(_ body:[String:BoundDebugJSON],session:AppCloudSession,timeout:TimeInterval) throws -> BoundDebugJSON {
        requestTimeouts.append(timeout);return try request(body,session:session)
    }
    func request(_ body:[String:BoundDebugJSON],session auth:AppCloudSession) throws -> BoundDebugJSON {
        requests.append(body)
        guard auth.owner==owner,let action=body["action"]?.string else { throw BoundDebugFailure.rejected }
        if boundaryOffline { throw BoundDebugFailure.timedOut }
        if lostBoundaryAction==action,dropBoundaryBeforeApply { boundaryOffline=true;throw BoundDebugFailure.timedOut }
        var extra:[String:BoundDebugJSON]=[:]
        switch action {
        case "create":session.sessionID=try XCTUnwrap(body["sessionID"]?.string.flatMap(UUID.init(uuidString:)))
        case "join":session.joined=[owner,peer];session.status = .active
        case "resume","status":
            let permitted:Set<String>=action=="status" ? ["action","sessionID","operationID"]:["action","sessionID"]
            guard Set(body.keys).isSubset(of:permitted) else { throw BoundDebugFailure.invalidResponse }
            if operation?.kind == .return,operation?.state == .committed,loseReturnStatuses>0 { loseReturnStatuses-=1;throw BoundDebugFailure.timedOut }
            if let delayedCut,action=="status",body["operationID"]?.string==operation?.operationID.uuidString.lowercased() {
                operation?.cut=delayedCut;operation?.state = .preparing;self.delayedCut=nil
            }
        case "list":return .object(["version":.number(1),"sessions":.array([try .wire(session)])])
        case "prepare":
            guard session.status == .active else { throw BoundDebugFailure.rejected }
            let id=try XCTUnwrap(body["operationID"]?.string.flatMap(UUID.init(uuidString:)))
            var stable=body;stable.removeValue(forKey:"capability")
            if let previous=prepared[id] { guard previous == .object(stable) else { throw BoundDebugFailure.busy };break }
            let source=try XCTUnwrap(body["source"]).decode(BoundDebugSource.self)
            let kind=try XCTUnwrap(body["kind"]?.string.flatMap(BoundDebugOperation.Kind.init(rawValue:)))
            let run:UUID
            if kind == .custom { run=try XCTUnwrap(manifest?.runID) }
            else if source.kind == .custom,let id=source.customID { run=try XCTUnwrap(history[id]?.0.runID) }
            else { run=UUID() }
            var identities:[String:BoundMultiplayerRunIdentity]=[:]
            for value in [owner,peer] {
                identities[value.uuidString.lowercased()] = .init(run:run,gameID:BoundGameProfiles.current.gameID,owner:value,
                    partner:value==owner ? peer:owner,roomID:session.roomID.uuidString.lowercased(),settingsOwner:owner,settings:settings,
                    localSeed:value==owner ? 1:2,partnerSeed:value==owner ? 2:1,romSHA256:BoundGameProfiles.current.romSHA256)
            }
            if kind == .return {
                let prior=try XCTUnwrap(history.values.first { $0.0.generation==session.currentGeneration }?.2.bookmark?.identity)
                identities[owner.uuidString.lowercased()]=prior
                var buddy=prior;buddy.owner=peer;buddy.partner=owner;buddy.run=UUID()
                identities[peer.uuidString.lowercased()]=buddy
            }
            nextGeneration+=1
            operation = .init(operationID:id,sessionID:session.sessionID,membershipEpoch:session.membershipEpoch,
                requestDigest:BoundDebugJSON.digest(try BoundDebugJSON.object(stable).data()),generation:nextGeneration,
                kind:kind,source:source,state:kind == .custom ? .waiting_cut:.preparing,runID:kind == .return ? manifest!.runID:run,identities:identities,
                compatibility:kind == .return ? manifest!.compatibility:.init(profile:BoundGameProfiles.current),settings:settings,preparedOwners:[],verifiedOwners:[],deadline:Date().timeIntervalSince1970+300)
            if let id=source.customID { operation?.cut=history[id]?.0.cut }
            prepared[id] = .object(stable);session.activeOperationID=id;chunks=[:];descriptor=nil
            if timeoutPrepare { timeoutPrepare=false;throw BoundDebugFailure.timedOut }
        case "captureReady":
            let previous=try XCTUnwrap(history.values.first { $0.0.generation==session.currentGeneration }?.1),heads=Dictionary(uniqueKeysWithValues:previous.owners.map { ($0.key,Optional($0.value.receipt.checkpoint)) })
            operation?.cut = .init(sourceGeneration:previous.generation,sourceRunID:previous.runID,cursor:.init(),digest:String(repeating:"c",count:64),heads:heads)
            operation?.state = .preparing
            if delayCaptureCut { delayCaptureCut=false;delayedCut=operation?.cut;operation?.cut=nil;operation?.state = .waiting_cut }
        case "captureComplete":operation?.capturedOwners=[owner,peer]
        case "terminal":extra["terminal"] = try terminalProofValue.map(BoundDebugJSON.wire) ?? .null
        case "returnReady":
            if let terminalProofValue {
                guard body["sourceCheckpoint"] == .null,try body["terminalProof"]?.decode(BoundDebugTerminalProof.self)==terminalProofValue else { throw BoundDebugFailure.rejected }
            } else if body["terminalProof"] != nil { throw BoundDebugFailure.rejected }
            operation?.preparedOwners=peerPrepared ? [owner,peer]:[owner];operation?.state = peerPrepared ? .prepared:.preparing
        case "ownerPrepare":descriptor=try XCTUnwrap(body["descriptor"]).decode(BoundDebugOwnerDescriptor.self)
        case "chunk":
            let index=try XCTUnwrap(body["index"]?.integer),value=try XCTUnwrap(body["data"]?.string)
            if let prior=chunks[index],prior != value { throw BoundDebugFailure.busy };chunks[index]=value
        case "seal":operation?.preparedOwners=peerPrepared ? [owner,peer]:[owner];operation?.state = peerPrepared ? .prepared:.preparing
        case "commit":
            if operation?.kind == .return {
                if operation?.state != .committed { operation?.state = .committed;session.status = .revoked;session.membershipEpoch+=1 }
                if loseReturnCommits>0 { loseReturnCommits-=1;throw BoundDebugFailure.timedOut }
                break
            }
            let operation=try XCTUnwrap(operation),own=try XCTUnwrap(descriptor)
            var other=own;other.receipt.owner=peer;other.deviceID=UUID();other.trainer.id=2;other.bookmark=nil
            var publicOwn=own;publicOwn.bookmark=nil
            var value=BoundDebugManifest(sessionID:session.sessionID,membershipEpoch:session.membershipEpoch,operationID:operation.operationID,
                generation:operation.generation,runID:operation.runID,source:operation.source,compatibility:operation.compatibility,
                settings:settings,owners:[owner.uuidString.lowercased():publicOwn,peer.uuidString.lowercased():other],cut:operation.cut,
                digest:String(repeating:"0",count:64),committedAt:Date().timeIntervalSince1970)
            var raw=try BoundDebugJSON.wire(value).object!;raw.removeValue(forKey:"digest")
            value.digest=BoundDebugJSON.digest(try BoundDebugJSON.object(raw).data());manifest=value
            if operation.kind != .custom { session.currentGeneration=operation.generation;session.currentManifestDigest=value.digest;terminalProofValue=nil }
            self.operation?.state = .committed;session.activeOperationID=nil
            history[operation.operationID]=(self.operation!,value,own,chunks)
        case "download":
            let previous=body["operationID"]?.string.flatMap(UUID.init(uuidString:)).flatMap { history[$0] }
            let index=try XCTUnwrap(body["index"]?.integer),descriptor=try XCTUnwrap(previous?.2 ?? descriptor),sourceChunks=previous?.3 ?? chunks
            extra["chunk"] = .object(["index":.number(Double(index)),"data":.string(tamperDownload ? "bad":sourceChunks[index] ?? ""),
                "count":.number(Double(descriptor.count)),"bytes":.number(Double(descriptor.bytes)),"payloadSHA256":.string(descriptor.receipt.payloadSHA256)])
        case "verify":
            let id=try XCTUnwrap(body["operationID"]?.string.flatMap(UUID.init(uuidString:)))
            if var record=history[id] {
                record.0.verifiedOwners=peerVerified ? [owner,peer]:[owner];record.0.state=peerVerified ? .ready:.committed;history[id]=record
                if operation?.operationID==id { operation=record.0 }
            }
        case "captures":extra["captures"] = .array(try history.values.filter { $0.0.kind == .custom }.map { try .wire(BoundDebugCapture(operation:$0.0,manifest:$0.1)) })
        case "admission":extra["admission"] = .object(["allowed":.bool(peerVerified),"generation":.number(Double(session.currentGeneration)),
            "manifestDigest":.string(session.currentManifestDigest!),"expiresAt":.number(Date().timeIntervalSince1970+30)])
        case "revoke","leave":session.status = .revoked;session.membershipEpoch+=1
        case "abort":guard session.status == .active,operation?.state != .committed,operation?.state != .ready else { throw BoundDebugFailure.revoked };operation?.state = .aborted;session.activeOperationID=nil
        case "return":extra["returnTarget"] = .object(["bookmark":try .wire(XCTUnwrap(history.values.first { $0.0.generation==session.currentGeneration }?.2.bookmark))])
        case "returnVerify":
            if let requiredReturnCheckpoint,body["checkpoint"]?.string != requiredReturnCheckpoint.uuidString.lowercased() { throw BoundDebugFailure.busy }
            returned=true
        case "realtime":
            guard peerVerified,session.status == .active,body["generation"]?.integer==session.currentGeneration else { throw BoundDebugFailure.stale }
            extra["realtime"] = .object(["protocol":.string("bound-debug-room-v1"),"sessionID":.string(session.sessionID.uuidString.lowercased()),
                "membershipEpoch":.number(Double(session.membershipEpoch)),"generation":.number(Double(session.currentGeneration)),"activitiesAllowed":.bool(session.activeOperationID==nil || operation?.kind == .custom && operation?.capturedOwners?.count==2),
                "endpoint":.string("wss://bound.example/ws?format=json"),"httpEndpoint":.string("https://bound.example"),"accessToken":.string("synthetic-nakama"),
                "expiresAt":.number(Date().timeIntervalSince1970+30),"matchID":.string("debug-match"),"roomID":.string(UUID().uuidString.lowercased()),
                "ownerID":.string(owner.uuidString.lowercased()),"nakamaUserID":.string(UUID().uuidString.lowercased()),"members":try .wire([owner,peer]),
                "peerOwnerID":.string(peer.uuidString.lowercased()),"joinTicket":.string("synthetic-debug-ticket")])
        case "gameplay":extra["gameplay"] = .object(["fixture":.bool(true)])
        default:throw BoundDebugFailure.rejected
        }
        if lostBoundaryAction==action { boundaryOffline=true;throw BoundDebugFailure.timedOut }
        let historical=body["operationID"]?.string.flatMap(UUID.init(uuidString:)).flatMap { $0 != operation?.operationID ? history[$0]:nil }
        let currentRecord=history.values.first { $0.0.generation==session.currentGeneration }
        let committedReturn=operation?.kind == .return && (operation?.state == .committed || operation?.state == .ready)
        let defaultCurrent=body["operationID"]==nil && session.activeOperationID==nil && !committedReturn
        let responseOperation=historical?.0 ?? (defaultCurrent ? currentRecord?.0:operation),responseDescriptor=historical?.2 ?? (defaultCurrent ? currentRecord?.2:descriptor)
        let activeManifest=historical?.1 ?? (defaultCurrent ? currentRecord?.1:(manifest?.operationID==operation?.operationID ? manifest:nil))
        let own=BoundDebugOwnerView(ownerID:owner,descriptor:responseDescriptor,bookmark:responseDescriptor?.bookmark,
            verifiedGeneration:responseOperation?.verifiedOwners.contains(owner)==true ? responseOperation?.generation:nil,
            liveUntil:Date().timeIntervalSince1970+30,returnVerified:returned)
        var response:[String:BoundDebugJSON] = ["version":.number(1),"session":try .wire(session),
            "capability":session.status == .revoked ? .null:.string("synthetic-capability-must-not-export"),
            "operation":try responseOperation.map(BoundDebugJSON.wire) ?? .null,"manifest":try activeManifest.map(BoundDebugJSON.wire) ?? .null,"own":try .wire(own)]
        response.merge(extra) { _,new in new };return .object(response)
    }
}

/// Drop one accepted verification reply while ordinary gameplay advances. The
/// backend then requires its new head, so resending the old body cannot pass.
private actor DebugLostReturnReply:BoundDebugServing {
    let backend:DebugProtocolFixture,advance:@Sendable () async -> Void
    var lost=false
    init(backend:DebugProtocolFixture,advance:@escaping @Sendable () async -> Void) { self.backend=backend;self.advance=advance }
    func request(_ body:[String:BoundDebugJSON],session:AppCloudSession) async throws -> BoundDebugJSON {
        try await request(body,session:session,timeout:10)
    }
    func request(_ body:[String:BoundDebugJSON],session:AppCloudSession,timeout:TimeInterval) async throws -> BoundDebugJSON {
        let response=try await backend.request(body,session:session,timeout:timeout)
        if body["action"]?.string=="returnVerify",!lost { lost=true;await advance();throw BoundDebugFailure.timedOut }
        return response
    }
}

/// Only polling intervals are gated; short request retry delays remain bounded
/// and immediate. Tests release each poll explicitly instead of racing timers.
private actor DebugPollGate {
    private var intervals:[TimeInterval]=[],order:[UUID]=[],waiters:[UUID:CheckedContinuation<Void,Error>]=[:]
    private var permits=0
    private var observers:[(Int,XCTestExpectation)]=[]
    func sleep(_ interval:TimeInterval) async throws {
        try Task.checkCancellation()
        guard interval>=1 else { return }
        intervals.append(interval)
        let ready=observers.filter { intervals.count >= $0.0 };observers.removeAll { intervals.count >= $0.0 }
        for (_,expectation) in ready { expectation.fulfill() }
        let id=UUID()
        try await withTaskCancellationHandler(operation:{
            try Task.checkCancellation()
            if permits>0 { permits-=1;return }
            try await withCheckedThrowingContinuation { continuation in order.append(id);waiters[id]=continuation }
        },onCancel:{ Task { await self.cancel(id) } })
    }
    private func cancel(_ id:UUID) { order.removeAll { $0==id };waiters.removeValue(forKey:id)?.resume(throwing:CancellationError()) }
    func advance() { guard let id=order.first else { permits+=1;return };order.removeFirst();waiters.removeValue(forKey:id)?.resume() }
    func recorded()->[TimeInterval] { intervals }
    func observe(count:Int,expectation:XCTestExpectation) {
        if intervals.count>=count { expectation.fulfill() } else { observers.append((count,expectation)) }
    }
}

@MainActor private final class DebugHostFixture:BoundDebugHost {
    var context:BoundDebugHostContext,previous:BoundDebugBookmark
    var restored=false,changeScopeOnRestore=false,restoreCount=0,recoverCount=0,completeCount=0,cutCount=0,cutReleased=0,prepareCount=0,returnCount=0,verifyReturnCount=0
    var ordinaryProgress=0,ordinaryCheckpoint=UUID(),ordinaryRun:UUID?
    var returnVerification:BoundDebugReturnVerification?
    var observedReturnReceipt:BoundMultiplayerCheckpointReceipt?
    var busy=false,switchPending=false
    var terminalTransitionAllowed=true,terminalReturnCount=0,settleCount=0
    var terminalIdentities:[BoundMultiplayerRunIdentity]=[]
    var heldBoundary:UUID?
    var boundaryObserved:((UUID) async -> Void)?
    var continuation:BoundDebugRealtimeScope?
    var admission:BoundDebugAdmission?
    init(context:BoundDebugHostContext,peer:UUID) {
        self.context=context
        previous = .init(identity:.init(run:UUID(),gameID:context.compatibility.gameID,owner:context.session.owner,partner:peer,
            roomID:context.roomID.uuidString.lowercased(),settingsOwner:context.session.owner,settings:Data(repeating:0,count:32),
            localSeed:1,partnerSeed:2,romSHA256:context.compatibility.romSHA256),deviceID:context.deviceID,ownershipEpoch:1,settled:true)
    }
    func debugContext()->BoundDebugHostContext { context }
    func preflightDebugSwitch() throws { if busy || heldBoundary != nil { throw BoundDebugFailure.busy } }
    func setDebugContinuation(_ scope:BoundDebugRealtimeScope?) { continuation=scope }
    func setDebugSwitchPending(_ pending:Bool) { switchPending=pending }
    func debugReturnReady(operation:BoundDebugOperation) async throws -> BoundDebugReturnReady {
        try preflightDebugSwitch();await boundaryObserved?(operation.operationID);heldBoundary=operation.operationID
        return .init(deviceID:context.deviceID,ownershipEpoch:1,sourceCheckpoint:UUID(),safe:true)
    }
    func settleForDebugSwitch() async throws -> BoundDebugBookmark { settleCount+=1;return previous }
    func prepareDebugTerminalTransition(proof:BoundDebugTerminalProof,manifest:BoundDebugManifest,identity:BoundMultiplayerRunIdentity) async throws -> BoundDebugBookmark {
        guard terminalTransitionAllowed,proof.valid(manifest:manifest,owner:context.session.owner,device:context.deviceID),
              identity.owner==context.session.owner,identity.run==manifest.runID else { throw BoundDebugFailure.busy }
        terminalIdentities.append(identity);return previous
    }
    func debugTerminalReturnReady(operation:BoundDebugOperation,proof:BoundDebugTerminalProof,manifest:BoundDebugManifest,identity:BoundMultiplayerRunIdentity) async throws -> BoundDebugReturnReady {
        _=try await prepareDebugTerminalTransition(proof:proof,manifest:manifest,identity:identity)
        await boundaryObserved?(operation.operationID);heldBoundary=operation.operationID;terminalReturnCount+=1
        return .init(deviceID:context.deviceID,ownershipEpoch:proof.ownershipEpoch,sourceCheckpoint:nil,safe:true,terminalProof:proof)
    }
    func rendezvousDebugCapture(operation:BoundDebugOperation) async throws -> BoundDebugCaptureReady {
        await boundaryObserved?(operation.operationID);heldBoundary=operation.operationID
        cutCount+=1;return .init(received:.init(),applied:.init(),durable:.init())
    }
    func prepareDebugPayload(operation:BoundDebugOperation,cut:BoundDebugHistoryCut?,bookmark:BoundDebugBookmark) async throws -> BoundDebugPreparedPayload {
        prepareCount+=1
        let identity=try XCTUnwrap(operation.identities[context.session.owner.uuidString.lowercased()])
        if operation.kind == .custom { XCTAssertNotNil(cut) }
        let journal=BoundSDKEventJournal(run:identity.run,owner:identity.owner,partner:identity.partner)
        let files:[String:BoundMultiplayerSavePackage.Blob] = ["game.sav":.init(Data([1,2,3])),"checkpoint.state":.init(Data([4,5,6])),
            "memory-files.json":.init(Data("{}".utf8)),"shared-events.json":.init(try JSONEncoder().encode(journal))]
        let payload=BoundMultiplayerSavePackage.Payload(version:2,manifest:.init(identity:identity,deviceOwner:context.deviceID),
            checkpoint:UUID(),predecessor:nil,sharedEventDigest:String(repeating:"d",count:64),files:files)
        let bytes=try BoundMultiplayerSaveStore.encode(payload)
        let receipt=BoundMultiplayerCheckpointReceipt(run:identity.run,checkpoint:payload.checkpoint,owner:identity.owner,
            payloadSHA256:BoundDebugJSON.digest(bytes),sharedEventDigest:payload.sharedEventDigest)
        let descriptor=BoundDebugOwnerDescriptor(deviceID:context.deviceID,ownershipEpoch:1,compatibility:context.compatibility,
            trainer:.init(id:1,name:"PLAYER",gender:0),receipt:receipt,bytes:bytes.count,count:((bytes.count+2)/3*4+11_999)/12_000,
            files:files.mapValues { .init(sha256:$0.sha256,bytes:$0.data.count) },historyDigest:payload.sharedEventDigest,
            soulDigest:BoundDebugJSON.digest(Data()),received:.init(),applied:.init(),durable:.init(),cutDigest:cut?.digest,bookmark:bookmark,safe:true)
        return .init(bytes:bytes,descriptor:descriptor)
    }
    func restoreDebugPayload(_ payload:Data,manifest:BoundDebugManifest) async throws {
        restored=true;restoreCount+=1
        if changeScopeOnRestore { context.authorityGeneration=UUID() }
    }
    func verifyDebugRestore(manifest:BoundDebugManifest) async throws -> BoundDebugVerification {
        guard restored else { throw BoundDebugFailure.nativeVerification }
        let descriptor=try XCTUnwrap(manifest.owners[context.session.owner.uuidString.lowercased()])
        return .init(deviceID:descriptor.deviceID,ownershipEpoch:descriptor.ownershipEpoch,payloadSHA256:descriptor.receipt.payloadSHA256,
            checkpoint:descriptor.receipt.checkpoint,trainerID:descriptor.trainer.id,soulDigest:descriptor.soulDigest,applied:descriptor.applied,nativeVerified:true)
    }
    func recoverDebugInstallation(manifest:BoundDebugManifest) async throws -> BoundDebugVerification {
        recoverCount+=1;restored=true;return try await verifyDebugRestore(manifest:manifest)
    }
    func completeDebugRestore(manifest:BoundDebugManifest) async throws { guard restored else { throw BoundDebugFailure.nativeVerification };completeCount+=1 }
    func finishDebugCapture(operation:BoundDebugOperation,captured:Bool) async throws { if heldBoundary==operation.operationID { heldBoundary=nil;cutReleased+=1 } }
    func returnFromDebug(bookmark:BoundDebugBookmark) async throws -> BoundDebugReturnVerification {
        returnCount+=1;heldBoundary=nil;XCTAssertEqual(bookmark,previous)
        ordinaryProgress=0;ordinaryRun=bookmark.identity.run
        let value=BoundDebugReturnVerification(checkpoint:ordinaryCheckpoint,deviceID:context.deviceID,nativeVerified:true)
        returnVerification=value;return value
    }
    func verifyDebugReturn(bookmark:BoundDebugBookmark,previous:BoundDebugReturnVerification) async throws -> BoundDebugReturnVerification {
        verifyReturnCount+=1
        guard bookmark==self.previous,ordinaryRun==bookmark.identity.run,previous==returnVerification else { throw BoundDebugFailure.stale }
        if let observedReturnReceipt {
            let known=BoundMultiplayerCheckpointReceipt(run:bookmark.identity.run,checkpoint:ordinaryCheckpoint,owner:context.session.owner,
                payloadSHA256:String(repeating:"a",count:64),sharedEventDigest:String(repeating:"b",count:64))
            try BoundROMMultiplayerCoordinator.validateDebugReturnReceipt(observedReturnReceipt,installed:known,
                requestedHead:known,currentHead:known,requestedConfirmed:ordinaryCheckpoint,currentConfirmed:ordinaryCheckpoint,uploadInFlight:false)
        }
        let value=BoundDebugReturnVerification(checkpoint:ordinaryCheckpoint,deviceID:context.deviceID,nativeVerified:true)
        returnVerification=value;return value
    }
    func setDebugAdmission(_ admission:BoundDebugAdmission?) { self.admission=admission }
}

private final class DebugRoomFixture: BoundSDKRoomTransport, @unchecked Sendable {
    typealias Configuration=BoundNakamaConfiguration
    private let lock=NSLock()
    private var callbacks:[@Sendable (BoundSDKRoomEvent)->Void]=[]
    func start(configuration:Configuration,event:@escaping @Sendable (BoundSDKRoomEvent)->Void) throws {
        lock.lock();callbacks.append(event);lock.unlock();event(.joined)
    }
    func stop() {}
    func emit(_ value:BoundSDKRoomEvent,index:Int) { lock.lock();let callback=callbacks[index];lock.unlock();callback(value) }
    func sendPresence(_ data:Data,targetOwnerID:UUID?)->Bool { true }
    func sendInteraction(_ data:Data,targetOwnerID:UUID?)->Bool { true }
    func sendBattle(_ data:Data,targetOwnerID:UUID)->Bool { true }
    func renewTicket(_ ticket:String,expiresAt:TimeInterval)->Bool { true }
}
@MainActor private final class DebugMediaFixture: FriendSharingTransport {
    var starts=0,stops=0,publishedFrames=0,receivedFrames=0
    func start(configuration:FriendSharingConfiguration,remoteView:UIView,event:@escaping @MainActor (FriendSharingEvent)->Void) { starts+=1;event(.joined) }
    func stop() { stops+=1 }
    func send(_ frame:SharingFrame,completion:@escaping @MainActor (Result<Void,SharingFailure>)->Void)->any SharingCancellation { completion(.success(()));return DebugFrameCancellation() }
}
@MainActor private final class DebugFrameCancellation:SharingCancellation { func cancel() {} }

final class DebugSessionTests:XCTestCase {
    private func identity(owner:UUID=UUID())->AppCloudSession {
        let value:[String:Any] = ["uid":owner.uuidString.lowercased(),"exp":Date().timeIntervalSince1970+3600]
        let payload=try! JSONSerialization.data(withJSONObject:value).base64EncodedString()
            .replacingOccurrences(of:"+",with:"-").replacingOccurrences(of:"/",with:"_").replacingOccurrences(of:"=",with:"")
        return try! AppCloudSession(owner:owner,key:"must-not-be-sent",token:"fixture."+payload+".signature",
            backend:.init(kind:.selfhost,origin:"https://bound.example"))
    }
    @MainActor private func fixture(joined:Bool=true)->(BoundDebugSession,DebugHostFixture,DebugProtocolFixture,DebugMemoryIntentStore) {
        let owner=UUID(),peer=UUID(),room=UUID(),account=identity(owner:owner)
        let host=DebugHostFixture(context:.init(session:account,roomID:room,deviceID:UUID(),authorityGeneration:UUID(),
            compatibility:.init(profile:BoundGameProfiles.current)),peer:peer)
        let backend=DebugProtocolFixture(owner:owner,peer:peer,room:room,joined:joined),store=DebugMemoryIntentStore()
        return (BoundDebugSession(host:host,storage:store,service:backend,enabled:{true}),host,backend,store)
    }
    @MainActor private func historicalFixture() async throws -> (BoundDebugSession,DebugHostFixture,DebugProtocolFixture,DebugMemoryIntentStore,BoundDebugOperation,BoundDebugManifest) {
        let owner=UUID(),peer=UUID(),room=UUID(),account=identity(owner:owner)
        let compatibility=BoundDebugCompatibility(profile:BoundGameProfiles.original)
        let host=DebugHostFixture(context:.init(session:account,roomID:room,deviceID:UUID(),authorityGeneration:UUID(),compatibility:compatibility),peer:peer)
        let priorCheckpoint=UUID()
        host.previous.checkpoint=priorCheckpoint
        host.previous.receipt = .init(run:host.previous.identity.run,checkpoint:priorCheckpoint,owner:owner,
            payloadSHA256:String(repeating:"a",count:64),sharedEventDigest:String(repeating:"b",count:64))
        let backend=DebugProtocolFixture(owner:owner,peer:peer,room:room),store=DebugMemoryIntentStore()
        let session=await backend.currentSession(),run=UUID(),settings=Data(repeating:0,count:32)
        var identities:[String:BoundMultiplayerRunIdentity]=[:]
        for value in [owner,peer] {
            identities[value.uuidString.lowercased()] = .init(run:run,gameID:compatibility.gameID,owner:value,
                partner:value==owner ? peer:owner,roomID:room.uuidString.lowercased(),settingsOwner:owner,settings:settings,
                localSeed:value==owner ? 1:2,partnerSeed:value==owner ? 2:1,romSHA256:compatibility.romSHA256)
        }
        let operation=BoundDebugOperation(operationID:UUID(),sessionID:session.sessionID,membershipEpoch:session.membershipEpoch,
            requestDigest:String(repeating:"c",count:64),generation:1,kind:.load,source:.init(kind:.builtin,pointID:"01",fixtureVersion:"v1"),
            state:.ready,runID:run,identities:identities,compatibility:compatibility,settings:settings,
            preparedOwners:[owner,peer],verifiedOwners:[owner,peer],deadline:Date().timeIntervalSince1970+300)
        let payload=try await host.prepareDebugPayload(operation:operation,cut:nil,bookmark:host.previous)
        let manifest=try await backend.seedCommitted(operation,payload:payload,auth:account),descriptor=payload.descriptor
        var state=BoundDebugLocalState(ownerID:owner,roomID:room,deviceID:host.context.deviceID,sessionID:session.sessionID)
        state.operationID=operation.operationID;state.generation=operation.generation;state.membershipEpoch=operation.membershipEpoch
        state.bookmark=host.previous;state.descriptor=descriptor;state.manifest=manifest;state.phase = .verified
        state.installedIdentity=identities[owner.uuidString.lowercased()]
        state.verification = .init(deviceID:descriptor.deviceID,ownershipEpoch:descriptor.ownershipEpoch,payloadSHA256:descriptor.receipt.payloadSHA256,
            checkpoint:descriptor.receipt.checkpoint,trainerID:descriptor.trainer.id,soulDigest:descriptor.soulDigest,applied:descriptor.applied,nativeVerified:true)
        await store.save(state)
        return (BoundDebugSession(host:host,storage:store,service:backend,enabled:{true}),host,backend,store,operation,manifest)
    }
    @MainActor func testSupportedHistoricalProfileResumesAndReturnsLatestOrdinaryHead() async throws {
        let (client,host,backend,store,operation,manifest)=try await historicalFixture();defer { client.suspend() }
        let session=await backend.currentSession()
        XCTAssertTrue(operation.compatibility.known);XCTAssertFalse(operation.compatibility.valid)
        XCTAssertTrue(operation.valid(session:session))
        XCTAssertTrue(manifest.valid(operation:operation,session:session))
        await client.reconcile()
        XCTAssertNil(client.failure);XCTAssertEqual(client.status,.ready);XCTAssertEqual(host.recoverCount,1)
        XCTAssertEqual(host.restoreCount,0);XCTAssertEqual(client.activeManifest,manifest)
        let latest=UUID();host.ordinaryCheckpoint=latest
        XCTAssertNotEqual(latest,host.previous.checkpoint)
        await client.returnToPreviousRun()
        XCTAssertNil(client.failure);XCTAssertEqual(host.returnCount,1);XCTAssertNil(client.activeManifest)
        let calls=await backend.captured(),prepared=try XCTUnwrap(calls.last { $0["action"]?.string=="prepare" })
        XCTAssertEqual(prepared["kind"]?.string,"return")
        XCTAssertEqual(try prepared["compatibility"]?.decode(BoundDebugCompatibility.self),operation.compatibility)
        let verified=try XCTUnwrap(calls.last { $0["action"]?.string=="returnVerify" })
        XCTAssertEqual(verified["checkpoint"]?.string,latest.uuidString.lowercased())
        let saved=await store.load(owner:host.context.session.owner,room:host.context.roomID)
        XCTAssertEqual(saved?.phase,.returned);XCTAssertEqual(saved?.bookmark,host.previous)
        XCTAssertEqual(saved?.manifest,manifest) // Recovery evidence is never converted to the current profile.
    }
    @MainActor func testSupportedHistoricalProfileCannotPrepareNewLoadReloadOrCustom() async throws {
        let (client,host,backend,_,_,_)=try await historicalFixture();defer { client.suspend() }
        await client.reconcile();XCTAssertNil(client.failure)
        let count=await backend.captured().count
        await client.load(source:.init(kind:.builtin,pointID:"02",fixtureVersion:"v1"),settings:Data(repeating:0,count:32))
        XCTAssertEqual(client.failure,.rejected)
        await client.reload();XCTAssertEqual(client.failure,.rejected)
        await client.saveCustom();XCTAssertEqual(client.failure,.rejected)
        let calls=await backend.captured();XCTAssertEqual(calls.count,count);XCTAssertEqual(host.cutCount,0)
    }
    @MainActor func testHistoricalProfileValidationRejectsUnknownROMCoreAndLayout() async throws {
        let (client,host,backend,_,original,manifest)=try await historicalFixture();defer { client.suspend() }
        let session=await backend.currentSession()
        var wrongROM=original.compatibility;wrongROM.romSHA256=String(repeating:"d",count:64)
        var wrongCore=original.compatibility;wrongCore.coreStateVersion+=1
        var wrongLayout=original.compatibility;wrongLayout.saveStateLayout+=1
        for incompatible in [wrongROM,wrongCore,wrongLayout] {
            XCTAssertFalse(incompatible.known)
            var operation=original;operation.compatibility=incompatible
            operation.identities=operation.identities.mapValues { value in var next=value;next.romSHA256=incompatible.romSHA256;return next }
            var invalid=manifest;invalid.compatibility=incompatible
            invalid.owners=invalid.owners.mapValues { value in var next=value;next.compatibility=incompatible;return next }
            XCTAssertFalse(operation.valid(session:session))
            XCTAssertFalse(invalid.valid(operation:operation,session:session))
            XCTAssertFalse(try XCTUnwrap(invalid.owners[host.context.session.owner.uuidString.lowercased()]).valid(owner:host.context.session.owner,operation:operation))
        }
    }
    @MainActor func testTerminalReloadUsesFreshGenerationWithoutSavingOrVerifyingTheEndedExecution() async throws {
        let (client,host,backend,store)=fixture();defer { client.suspend() };await backend.setPeerVerified(true)
        await client.createSession();await client.load(source:.init(kind:.builtin,pointID:"01",fixtureVersion:"v1"),settings:Data(repeating:0,count:32))
        let original=try XCTUnwrap(client.activeManifest),settlements=host.settleCount,completions=host.completeCount
        let terminal=try await backend.markCurrentGenerationTerminal();host.busy=true
        await client.reconcile()
        XCTAssertNil(client.failure);XCTAssertEqual(client.status,.ended);XCTAssertEqual(client.terminal,terminal)
        XCTAssertNil(host.admission);XCTAssertNil(host.continuation);XCTAssertEqual(host.completeCount,completions)
        let ended=await store.load(owner:host.context.session.owner,room:host.context.roomID)
        XCTAssertNil(ended?.verification);XCTAssertEqual(ended?.manifest,original)
        let beforeCustom=await backend.captured().filter { $0["action"]?.string=="prepare" }.count
        await client.saveCustom();XCTAssertEqual(client.failure,.busy)
        let afterCustom=await backend.captured().filter { $0["action"]?.string=="prepare" }.count
        XCTAssertEqual(beforeCustom,afterCustom);XCTAssertEqual(host.cutCount,0)
        await client.reload()
        XCTAssertNil(client.failure);XCTAssertEqual(client.status,.ready);XCTAssertNil(client.terminal)
        XCTAssertEqual(client.activeManifest?.generation,original.generation+1);XCTAssertNotEqual(client.activeManifest?.runID,original.runID)
        XCTAssertEqual(host.settleCount,settlements);XCTAssertEqual(host.restoreCount,2)
    }
    @MainActor func testColdTerminalRecoveryUsesDurableIdentityWithoutDeadStateRestoreAndReturnsLatestOrdinaryHead() async throws {
        let (first,host,backend,store)=fixture();await backend.setPeerVerified(true)
        await first.createSession();await first.load(source:.init(kind:.builtin,pointID:"01",fixtureVersion:"v1"),settings:Data(repeating:0,count:32))
        let loaded=await store.load(owner:host.context.session.owner,room:host.context.roomID)
        let saved=try XCTUnwrap(loaded),identity=try XCTUnwrap(saved.installedIdentity)
        _=try await backend.markCurrentGenerationTerminal();first.suspend()
        let cold=DebugHostFixture(context:host.context,peer:host.previous.identity.partner);cold.previous=host.previous;cold.busy=true
        cold.ordinaryCheckpoint=UUID()
        let client=BoundDebugSession(host:cold,storage:store,service:backend,enabled:{true});defer { client.suspend() }
        await client.reconcile()
        XCTAssertNil(client.failure);XCTAssertEqual(client.status,.ended);XCTAssertEqual(cold.terminalIdentities,[identity])
        XCTAssertFalse(cold.restored);XCTAssertEqual(cold.restoreCount,0);XCTAssertEqual(cold.recoverCount,0);XCTAssertEqual(cold.completeCount,0)
        await client.returnToPreviousRun()
        XCTAssertNil(client.failure);XCTAssertEqual(cold.terminalReturnCount,1);XCTAssertEqual(cold.returnCount,1);XCTAssertEqual(cold.settleCount,0)
        let calls=await backend.captured(),ready=try XCTUnwrap(calls.last { $0["action"]?.string=="returnReady" })
        XCTAssertEqual(ready["sourceCheckpoint"],.null);XCTAssertNotNil(ready["terminalProof"])
        XCTAssertEqual(calls.last?["checkpoint"]?.string,cold.ordinaryCheckpoint.uuidString.lowercased())
        let returned=await store.load(owner:cold.context.session.owner,room:cold.context.roomID);XCTAssertEqual(returned?.phase,.returned)
    }
    @MainActor func testTerminalProofCannotBypassForeignScopeOrUnresolvedHostRecovery() async throws {
        for invalid in ["owner","generation","epoch","device","hostRecovery"] {
            let (client,host,backend,_)=fixture();defer { client.suspend() };await backend.setPeerVerified(true)
            await client.createSession();await client.load(source:.init(kind:.builtin,pointID:"01",fixtureVersion:"v1"),settings:Data(repeating:0,count:32))
            var proof=try await backend.markCurrentGenerationTerminal();host.busy=true
            switch invalid {
            case "owner":proof.ownerID=host.previous.identity.partner
            case "generation":proof.generation+=1
            case "epoch":proof.ownershipEpoch+=1
            case "device":proof.deviceID=UUID()
            default:host.terminalTransitionAllowed=false
            }
            await backend.replaceTerminalProof(proof)
            let count=await backend.captured().filter { $0["action"]?.string=="prepare" }.count
            await client.reload()
            XCTAssertNotNil(client.failure);XCTAssertEqual(host.restoreCount,1);XCTAssertEqual(host.terminalReturnCount,0)
            let after=await backend.captured().filter { $0["action"]?.string=="prepare" }.count;XCTAssertEqual(after,count)
        }
    }
    @MainActor func testLocalBusyWithoutAuthenticatedTerminalCannotBypassOrdinaryPreflight() async throws {
        let (client,host,backend,_)=fixture();defer { client.suspend() };await backend.setPeerVerified(true)
        await client.createSession();await client.load(source:.init(kind:.builtin,pointID:"01",fixtureVersion:"v1"),settings:Data(repeating:0,count:32))
        host.busy=true
        let before=await backend.captured().filter { $0["action"]?.string=="prepare" }.count
        await client.reload();XCTAssertEqual(client.failure,.busy)
        await client.returnToPreviousRun();XCTAssertEqual(client.failure,.busy)
        XCTAssertTrue(host.terminalIdentities.isEmpty);XCTAssertEqual(host.restoreCount,1)
        let after=await backend.captured().filter { $0["action"]?.string=="prepare" }.count;XCTAssertEqual(before,after)
    }
    @MainActor func testColdTerminalRecoveryRejectsMissingOrReplacedDurableInstalledIdentity() async throws {
        for missing in [true,false] {
            let (first,host,backend,store)=fixture();await backend.setPeerVerified(true)
            await first.createSession();await first.load(source:.init(kind:.builtin,pointID:"01",fixtureVersion:"v1"),settings:Data(repeating:0,count:32))
            _=try await backend.markCurrentGenerationTerminal();first.suspend()
            let loaded=await store.load(owner:host.context.session.owner,room:host.context.roomID)
            var state=try XCTUnwrap(loaded)
            if missing { state.installedIdentity=nil } else { state.installedIdentity?.run=UUID() }
            await store.save(state)
            let cold=DebugHostFixture(context:host.context,peer:host.previous.identity.partner);cold.previous=host.previous;cold.busy=true
            let client=BoundDebugSession(host:cold,storage:store,service:backend,enabled:{true});defer { client.suspend() }
            await client.reconcile()
            XCTAssertEqual(client.failure,.stale);XCTAssertTrue(cold.terminalIdentities.isEmpty)
            XCTAssertEqual(cold.restoreCount,0);XCTAssertEqual(cold.recoverCount,0);XCTAssertEqual(cold.completeCount,0)
        }
    }
    @MainActor func testTerminalReturnLostReadinessReconcilesWithoutClaimingLiveNativeVerification() async throws {
        for beforeApply in [true,false] {
            let (first,host,backend,store)=fixture();await backend.setPeerVerified(true)
            await first.createSession();await first.load(source:.init(kind:.builtin,pointID:"01",fixtureVersion:"v1"),settings:Data(repeating:0,count:32))
            _=try await backend.markCurrentGenerationTerminal();host.busy=true;await first.reconcile()
            await backend.loseBoundaryReply("returnReady",beforeApply:beforeApply);await first.returnToPreviousRun()
            XCTAssertEqual(first.failure,.timedOut);XCTAssertNotNil(host.heldBoundary);first.suspend()
            let retained=await store.load(owner:host.context.session.owner,room:host.context.roomID);XCTAssertNotNil(retained?.boundaryPending)
            await backend.restoreBoundaryNetwork()
            let client=BoundDebugSession(host:host,storage:store,service:backend,enabled:{true});defer { client.suspend() }
            await client.reconcile()
            XCTAssertNil(client.failure);XCTAssertNil(host.heldBoundary);XCTAssertEqual(host.restoreCount,1);XCTAssertEqual(host.recoverCount,0)
            XCTAssertEqual(host.completeCount,1)
            if beforeApply { XCTAssertEqual(client.status,.ended);XCTAssertEqual(host.returnCount,0) }
            else { XCTAssertNil(client.activeManifest);XCTAssertEqual(host.returnCount,1) }
        }
    }
    @MainActor func testPreparedTimeoutReusesOperationAndOneVerificationNeverMeansReady() async throws {
        let (client,host,backend,store)=fixture();defer { client.suspend() }
        await client.createSession()
        await client.load(source:.init(kind:.builtin,pointID:"01",fixtureVersion:"fixture-v1"),settings:Data(repeating:0,count:32))
        XCTAssertNil(client.failure);XCTAssertEqual(client.status,.waiting);XCTAssertNil(host.admission)
        XCTAssertEqual(host.restoreCount,1);XCTAssertEqual(host.completeCount,1);XCTAssertEqual(client.manifest?.generation,1)
        let calls=await backend.captured(),prepares=calls.filter { $0["action"]?.string=="prepare" }
        XCTAssertEqual(prepares.count,2);XCTAssertEqual(Set(prepares.compactMap { $0["operationID"]?.string }).count,1)
        let savedValue=await store.load(owner:host.context.session.owner,room:host.context.roomID),saved=try XCTUnwrap(savedValue)
        XCTAssertEqual(saved.phase,.verified);XCTAssertNotNil(saved.bookmark)
        let record=String(decoding:try JSONEncoder().encode(saved),as:UTF8.self),report=String(decoding:try client.exportReport(),as:UTF8.self)
        for text in [record,report] { XCTAssertFalse(text.contains("synthetic-capability"));XCTAssertFalse(text.contains("fixture.")) }
        XCTAssertFalse(report.contains("checkpoint.state"));XCTAssertFalse(report.contains("game.sav"))
    }
    @MainActor func testRestartRecoversLatestInstallationBeforeCompletingAndReverifiesBothOwners() async throws {
        let (first,host,backend,store)=fixture()
        await first.createSession();await first.load(source:.init(kind:.builtin,pointID:"01",fixtureVersion:"v1"),settings:Data(repeating:0,count:32))
        first.suspend();await backend.setPeerVerified(true)
        let replacement=DebugHostFixture(context:host.context,peer:host.previous.identity.partner);replacement.busy=true
        let resumed=BoundDebugSession(host:replacement,storage:store,service:backend,enabled:{true});defer { resumed.suspend() }
        await resumed.refresh()
        XCTAssertNil(resumed.failure);XCTAssertEqual(resumed.status,.ready)
        XCTAssertEqual(replacement.recoverCount,1);XCTAssertEqual(replacement.restoreCount,0);XCTAssertEqual(replacement.completeCount,1)
        XCTAssertEqual(replacement.admission?.generation,1)
        let calls=await backend.captured();XCTAssertEqual(calls.filter { $0["action"]?.string=="prepare" }.count,2)
    }
    @MainActor func testForegroundFinalSaveRecoversRetainedInstallationWithoutReloadingBaselineOrLeaving() async throws {
        let (client,host,backend,store)=fixture();defer { client.suspend() }
        await backend.setPeerVerified(true);await client.createSession()
        await client.load(source:.init(kind:.builtin,pointID:"01",fixtureVersion:"v1"),settings:Data(repeating:0,count:32))
        XCTAssertEqual(client.status,.ready);XCTAssertEqual(host.restoreCount,1);XCTAssertEqual(host.recoverCount,0)
        let owner=host.context.session.owner,room=host.context.roomID
        let before=await store.load(owner:owner,room:room),manifest=client.activeManifest
        let callsBefore=await backend.captured()
        // The final save's foreground path has withdrawn native working
        // authority, while the client still has its in-process receipt cache.
        host.restored=false
        await client.reconcileNativeInstallation()
        XCTAssertNil(client.failure);XCTAssertEqual(client.status,.ready)
        XCTAssertEqual(host.recoverCount,1);XCTAssertEqual(host.restoreCount,1);XCTAssertEqual(host.completeCount,2)
        XCTAssertEqual(client.activeManifest,manifest);XCTAssertEqual(host.admission?.generation,manifest?.generation)
        let after=await store.load(owner:owner,room:room)
        XCTAssertEqual(after?.sessionID,before?.sessionID);XCTAssertEqual(after?.bookmark,before?.bookmark)
        XCTAssertEqual(after?.installedIdentity,before?.installedIdentity);XCTAssertEqual(after?.phase,.verified)
        let calls=Array((await backend.captured()).dropFirst(callsBefore.count))
        XCTAssertEqual(calls.first?["action"]?.string,"resume")
        XCTAssertFalse(calls.contains { ["prepare","download","revoke","leave"].contains($0["action"]?.string ?? "") })
        await client.reconcile();XCTAssertEqual(host.recoverCount,1,"The renewed installation proof is cached only after successful recovery")
    }
    @MainActor func testLateNativeRestoreAfterAuthorityChangeCannotVerifyOrResume() async throws {
        let (client,host,backend,store)=fixture();defer { client.suspend() };host.changeScopeOnRestore=true
        await backend.setPeerVerified(true);await client.createSession()
        await client.load(source:.init(kind:.builtin,pointID:"01",fixtureVersion:"v1"),settings:Data(repeating:0,count:32))
        XCTAssertEqual(client.failure,.stale);XCTAssertEqual(host.restoreCount,1);XCTAssertEqual(host.completeCount,0);XCTAssertNil(host.admission)
        let calls=await backend.captured();XCTAssertFalse(calls.contains { $0["action"]?.string=="verify" })
        let state=await store.load(owner:host.context.session.owner,room:host.context.roomID);XCTAssertEqual(state?.phase,.restoring)
    }
    @MainActor func testBuddyExplicitJoinIsRequiredAndResumeDoesNotRepeatConsent() async throws {
        let (client,host,backend,_)=fixture(joined:false);defer { client.suspend() }
        await backend.makeBuddyInvitation();let invite=await backend.currentSession()
        await client.join(sessionID:invite.sessionID,membershipEpoch:invite.membershipEpoch)
        XCTAssertNil(client.failure);XCTAssertFalse(client.isController)
        await client.load(source:.init(kind:.builtin,pointID:"01",fixtureVersion:"v1"),settings:Data(repeating:0,count:32))
        XCTAssertEqual(client.failure,.rejected)
        client.suspend();await client.refresh()
        let calls=await backend.captured();XCTAssertEqual(calls.filter { $0["action"]?.string=="join" }.count,1)
        XCTAssertFalse(calls.contains { $0["action"]?.string=="prepare" });XCTAssertEqual(host.restoreCount,0)
    }
    @MainActor func testCustomCaptureUsesServerCutAndNewDomainWithoutChangingSerializedRun() async throws {
        let (client,host,backend,_)=fixture();defer { client.suspend() };await backend.setPeerVerified(true)
        await client.createSession();await client.load(source:.init(kind:.builtin,pointID:"01",fixtureVersion:"v1"),settings:Data(repeating:0,count:32))
        let run=try XCTUnwrap(client.manifest?.runID)
        await client.saveCustom()
        XCTAssertNil(client.failure);XCTAssertEqual(client.manifest?.generation,1);XCTAssertEqual(client.manifest?.runID,run)
        XCTAssertEqual(host.restoreCount,1,"Save Custom never rewinds live native progress")
        let custom=try XCTUnwrap(client.captures.first)
        XCTAssertNotNil(custom.manifest.cut);XCTAssertEqual(host.cutCount,1);XCTAssertEqual(host.cutReleased,1)
        let calls=await backend.captured(),capture=try XCTUnwrap(calls.firstIndex { $0["action"]?.string=="captureReady" })
        let laterPrepare=try XCTUnwrap(calls[capture...].firstIndex { $0["action"]?.string=="ownerPrepare" })
        XCTAssertGreaterThan(laterPrepare,capture)
        let capturedID=custom.id,capturedReceipt=custom.manifest.owners[host.context.session.owner.uuidString.lowercased()]?.receipt
        await client.reloadCustom(custom)
        XCTAssertNil(client.failure);XCTAssertEqual(client.manifest?.generation,3);XCTAssertEqual(client.manifest?.runID,run)
        XCTAssertEqual(client.manifest?.source.customID,capturedID);XCTAssertEqual(host.prepareCount,2,"Reload must reuse immutable custom bytes")
        XCTAssertEqual(client.manifest?.owners[host.context.session.owner.uuidString.lowercased()]?.receipt,capturedReceipt)
    }
    @MainActor func testLostCustomCommitRecoversArchiveAndLatestActiveInstallationAfterRestart() async throws {
        let (client,host,backend,store)=fixture();await backend.setPeerVerified(true)
        await client.createSession();await client.load(source:.init(kind:.builtin,pointID:"01",fixtureVersion:"v1"),settings:Data(repeating:0,count:32))
        let active=try XCTUnwrap(client.activeManifest)
        await backend.loseBoundaryReply("commit");await client.saveCustom()
        XCTAssertEqual(client.failure,.timedOut);client.suspend()
        let pendingValue=await store.load(owner:host.context.session.owner,room:host.context.roomID)
        let pending=try XCTUnwrap(pendingValue)
        XCTAssertEqual(pending.phase,.sealed);XCTAssertEqual(pending.generation,2);XCTAssertNil(pending.boundaryPending)
        let source=(await backend.captured()).count
        let replacement=DebugHostFixture(context:host.context,peer:host.previous.identity.partner);replacement.previous=host.previous
        let resumed=BoundDebugSession(host:replacement,storage:store,service:backend,enabled:{true});defer { resumed.suspend() }
        await backend.restoreBoundaryNetwork();await resumed.reconcile()
        XCTAssertNil(resumed.failure);XCTAssertEqual(resumed.status,.ready);XCTAssertEqual(resumed.activeManifest,active)
        XCTAssertEqual(resumed.captures.first?.id,pending.operationID);XCTAssertEqual(resumed.captures.first?.operation.generation,2)
        XCTAssertEqual(replacement.recoverCount,1);XCTAssertEqual(replacement.restoreCount,0);XCTAssertEqual(replacement.prepareCount,0)
        XCTAssertEqual(replacement.cutCount,0);XCTAssertEqual(replacement.completeCount,1)
        let calls=Array((await backend.captured()).dropFirst(source))
        XCTAssertTrue(calls.contains { $0["action"]?.string=="status" && $0["operationID"]?.string==pending.operationID?.uuidString.lowercased() })
        XCTAssertFalse(calls.contains { ["prepare","ownerPrepare","captureReady","captureComplete","chunk","seal","commit","download"].contains($0["action"]?.string ?? "") })
        let recovered=await store.load(owner:host.context.session.owner,room:host.context.roomID)
        XCTAssertEqual(recovered?.phase,.verified);XCTAssertEqual(recovered?.generation,active.generation)
        XCTAssertEqual(recovered?.manifest,active);XCTAssertEqual(recovered?.bookmark,pending.bookmark)
    }
    @MainActor func testCustomCapturePollsMissingCutUsingOnlyStatusContractFields() async throws {
        let (client,host,backend,_)=fixture();defer { client.suspend() };await backend.setPeerVerified(true)
        await client.createSession();await client.load(source:.init(kind:.builtin,pointID:"01",fixtureVersion:"v1"),settings:Data(repeating:0,count:32))
        await backend.delayNextCaptureCut();await client.saveCustom()
        XCTAssertNil(client.failure);XCTAssertEqual(client.captures.count,1);XCTAssertEqual(host.cutCount,1)
        XCTAssertEqual(host.cutReleased,1);XCTAssertEqual(host.restoreCount,1)
        let calls=await backend.captured(),ready=try XCTUnwrap(calls.lastIndex { $0["action"]?.string=="captureReady" })
        let poll=try XCTUnwrap(calls.dropFirst(ready+1).first { $0["action"]?.string=="status" })
        XCTAssertEqual(Set(poll.keys),Set(["action","sessionID","operationID"]))
        XCTAssertEqual(poll["operationID"],calls[ready]["operationID"])
        XCTAssertFalse(calls.dropFirst(ready+1).contains { $0["action"]?.string=="abort" })
    }
    @MainActor func testPersistedCustomCommitCannotOverrideNewerActiveGeneration() async throws {
        let (client,host,backend,store)=fixture();await backend.setPeerVerified(true)
        await client.createSession();await client.load(source:.init(kind:.builtin,pointID:"01",fixtureVersion:"v1"),settings:Data(repeating:0,count:32))
        await backend.loseBoundaryReply("commit");await client.saveCustom();client.suspend()
        let pending=await store.load(owner:host.context.session.owner,room:host.context.roomID)
        await backend.restoreBoundaryNetwork();let newer=try await backend.activateNewerGeneration()
        let replacement=DebugHostFixture(context:host.context,peer:host.previous.identity.partner)
        let resumed=BoundDebugSession(host:replacement,storage:store,service:backend,enabled:{true});defer { resumed.suspend() }
        await resumed.reconcile()
        XCTAssertEqual(resumed.failure,.stale);XCTAssertEqual(resumed.serverSession?.currentGeneration,newer)
        XCTAssertEqual(resumed.operation?.generation,newer);XCTAssertEqual(resumed.manifest?.generation,newer)
        XCTAssertEqual(replacement.recoverCount,0);XCTAssertEqual(replacement.restoreCount,0);XCTAssertEqual(replacement.completeCount,0)
        let retained=await store.load(owner:host.context.session.owner,room:host.context.roomID)
        XCTAssertEqual(retained,pending);XCTAssertNil(replacement.admission);XCTAssertTrue(resumed.captures.isEmpty)
    }
    @MainActor func testMalformedOwnDownloadNeverCallsNativeRestore() async throws {
        let (client,host,backend,store)=fixture();defer { client.suspend() };await backend.corruptDownload()
        await client.createSession();await client.load(source:.init(kind:.builtin,pointID:"01",fixtureVersion:"v1"),settings:Data(repeating:0,count:32))
        XCTAssertEqual(client.failure,.invalidResponse);XCTAssertEqual(host.restoreCount,0);XCTAssertEqual(host.completeCount,0)
        let state=await store.load(owner:host.context.session.owner,room:host.context.roomID)
        XCTAssertEqual(state?.phase,.committed);XCTAssertNotNil(state?.bookmark)
    }
    @MainActor func testDebugRunServiceRejectsOrdinaryActionsWrongRunAndRevokedScope() async throws {
        let (client,host,backend,_)=fixture();defer { client.suspend() }
        await client.createSession();await client.load(source:.init(kind:.builtin,pointID:"01",fixtureVersion:"v1"),settings:Data(repeating:0,count:32))
        let identity=try XCTUnwrap(client.operation?.identities[host.context.session.owner.uuidString.lowercased()])
        let service=try client.makeRunService(identity:identity),isDebug=await service.isDebug;XCTAssertTrue(isDebug)
        let bounded=try client.makeRunService(identity:identity,requestTimeout:1)
        try await bounded.revalidateDebugScope()
        _=try? await bounded.sharedEvents(identity:identity,events:[],cursor:.init())
        let timeouts=await backend.capturedTimeouts();XCTAssertEqual(Array(timeouts.suffix(2)),[1,1])
        let initial=(await backend.captured()).count
        do { _=try await service.getSave(UUID());XCTFail("Wrong run") } catch { }
        do { _=try await service.listSaves(gameID:identity.gameID);XCTFail("Ordinary listing") } catch { }
        do { _=try await service.configureSaves(session:host.context.session);XCTFail("Ordinary authorization") } catch { }
        let later=await backend.captured();XCTAssertEqual(later.count,initial)
        await client.leave();XCTAssertNil(host.admission)
        do { try await service.revalidateDebugScope();XCTFail("Revoked scope") } catch { }
    }
    @MainActor func testBusyPreflightCannotPrepareOrTearDownCurrentAdmission() async throws {
        let (client,host,backend,store)=fixture();defer { client.suspend() };await backend.setPeerVerified(true)
        await client.createSession();await client.load(source:.init(kind:.builtin,pointID:"01",fixtureVersion:"v1"),settings:Data(repeating:0,count:32))
        let admission=host.admission,continuation=host.continuation,callsBefore=await backend.captured()
        let sessionBefore=await backend.currentSession(),operationBefore=client.operation,manifestBefore=client.activeManifest
        let intentBefore=await store.load(owner:host.context.session.owner,room:host.context.roomID)
        let hostEffectsBefore=[host.settleCount,host.prepareCount,host.restoreCount,host.recoverCount,host.completeCount,
            host.cutCount,host.cutReleased,host.returnCount,host.terminalReturnCount,host.terminalIdentities.count]
        host.busy=true
        await client.load(source:.init(kind:.builtin,pointID:"02",fixtureVersion:"v1"),settings:Data(repeating:0,count:32))
        XCTAssertEqual(client.failure,.busy);XCTAssertEqual(host.admission,admission);XCTAssertEqual(host.continuation,continuation)
        let callsAfter=await backend.captured(),added=Array(callsAfter.dropFirst(callsBefore.count))
        // A terminal proof is read before ordinary preflight so a genuine ended
        // generation can recover. A live busy source may only make that lookup.
        XCTAssertEqual(Array(callsAfter.prefix(callsBefore.count)),callsBefore)
        XCTAssertEqual(added.map { $0["action"]?.string },["terminal"])
        let lookup=try XCTUnwrap(added.first)
        XCTAssertEqual(Set(lookup.keys),Set(["action","sessionID","membershipEpoch","capability","generation"]))
        XCTAssertEqual(lookup["sessionID"]?.string,sessionBefore.sessionID.uuidString.lowercased())
        XCTAssertEqual(lookup["membershipEpoch"]?.integer,sessionBefore.membershipEpoch)
        XCTAssertEqual(lookup["generation"]?.integer,manifestBefore?.generation)
        XCTAssertFalse(lookup["capability"]?.string?.isEmpty ?? true)
        let sessionAfter=await backend.currentSession(),intentAfter=await store.load(owner:host.context.session.owner,room:host.context.roomID)
        XCTAssertEqual(sessionAfter,sessionBefore);XCTAssertEqual(intentAfter,intentBefore)
        XCTAssertEqual(client.operation,operationBefore);XCTAssertEqual(client.activeManifest,manifestBefore)
        XCTAssertEqual([host.settleCount,host.prepareCount,host.restoreCount,host.recoverCount,host.completeCount,
            host.cutCount,host.cutReleased,host.returnCount,host.terminalReturnCount,host.terminalIdentities.count],hostEffectsBefore)
        XCTAssertNil(host.heldBoundary);XCTAssertNil(client.terminal);XCTAssertFalse(host.switchPending)
    }
    @MainActor func testRealtimeUsesFixedCommittedScopeAndRejectsStaleGeneration() async throws {
        let (client,host,backend,_)=fixture();defer { client.suspend() };await backend.setPeerVerified(true)
        await client.createSession();await client.load(source:.init(kind:.builtin,pointID:"01",fixtureVersion:"v1"),settings:Data(repeating:0,count:32))
        let scope=try XCTUnwrap(host.continuation)
        let value=try await client.makeRealtimeConfiguration(scope:scope,room:host.context.roomID.uuidString,session:host.context.session)
        XCTAssertEqual(value.matchID,"debug-match");XCTAssertNotEqual(value.roomID,host.context.roomID)
        var stale=scope;stale.generation+=1
        do { _=try await client.makeRealtimeConfiguration(scope:stale,room:host.context.roomID.uuidString,session:host.context.session);XCTFail("stale scope") } catch {}
        await client.leave()
        do { _=try await client.makeRealtimeConfiguration(scope:scope,room:host.context.roomID.uuidString,session:host.context.session);XCTFail("revoked scope") } catch {}
    }
    @MainActor func testCoordinatedReturnSettlesBothBeforeCommitAndReopensOrdinaryBookmark() async throws {
        let (client,host,backend,store)=fixture();defer { client.suspend() };await backend.setPeerVerified(true)
        await client.createSession();await client.load(source:.init(kind:.builtin,pointID:"01",fixtureVersion:"v1"),settings:Data(repeating:0,count:32))
        let ordinary=host.previous.identity.run;XCTAssertNotEqual(ordinary,client.manifest?.runID)
        await client.returnToPreviousRun()
        XCTAssertNil(client.failure);XCTAssertNil(client.activeManifest);XCTAssertFalse(host.switchPending)
        let calls=await backend.captured(),ready=try XCTUnwrap(calls.lastIndex { $0["action"]?.string=="returnReady" }),commit=try XCTUnwrap(calls.lastIndex { $0["action"]?.string=="commit" })
        XCTAssertLessThan(ready,commit);XCTAssertEqual(calls.last?["action"]?.string,"returnVerify")
        let record=await store.load(owner:host.context.session.owner,room:host.context.roomID);XCTAssertEqual(record?.phase,.returned)
    }
    @MainActor func testExpiredPreparationAbortsAndReleasesFirstSwitchWithoutDiscardingBookmark() async throws {
        let (client,host,backend,store)=fixture();defer { client.suspend() };await backend.setPeerPrepared(false)
        await client.createSession();await client.load(source:.init(kind:.builtin,pointID:"01",fixtureVersion:"v1"),settings:Data(repeating:0,count:32))
        XCTAssertTrue(host.switchPending);XCTAssertEqual(host.restoreCount,0)
        await backend.expirePendingOperation();await client.refresh()
        XCTAssertNil(client.failure);XCTAssertFalse(host.switchPending);XCTAssertEqual(client.operation?.state,.aborted)
        let record=await store.load(owner:host.context.session.owner,room:host.context.roomID)
        XCTAssertNil(record?.request);XCTAssertNil(record?.operationID);XCTAssertNotNil(record?.bookmark)
        await backend.setPeerPrepared(true)
        await client.load(source:.init(kind:.builtin,pointID:"02",fixtureVersion:"v1"),settings:Data(repeating:0,count:32))
        XCTAssertNil(client.failure);XCTAssertEqual(host.restoreCount,1)
    }
    @MainActor func testReturnBuddyWaitAbortsBeforeReleasingSourceBoundary() async throws {
        let (client,host,backend,_)=fixture();defer { client.suspend() };await backend.setPeerVerified(true)
        await client.createSession();await client.load(source:.init(kind:.builtin,pointID:"01",fixtureVersion:"v1"),settings:Data(repeating:0,count:32))
        let active=client.activeManifest?.digest;await backend.setPeerPrepared(false)
        let start=Date();await client.returnToPreviousRun()
        XCTAssertLessThan(Date().timeIntervalSince(start),4)
        XCTAssertNil(client.failure);XCTAssertEqual(host.returnCount,0);XCTAssertEqual(host.cutReleased,1)
        XCTAssertEqual(client.activeManifest?.digest,active);XCTAssertFalse(host.switchPending)
        let calls=await backend.captured();XCTAssertTrue(calls.contains { $0["action"]?.string=="abort" })
    }
    @MainActor func testLostReturnCommitReconcilesDurableIntentAfterRestart() async throws {
        let (client,host,backend,store)=fixture();await backend.setPeerVerified(true)
        await client.createSession();await client.load(source:.init(kind:.builtin,pointID:"01",fixtureVersion:"v1"),settings:Data(repeating:0,count:32))
        await backend.loseReturnCommitResponses();await client.returnToPreviousRun()
        XCTAssertEqual(client.failure,.timedOut);client.suspend()
        let resumed=BoundDebugSession(host:host,storage:store,service:backend,enabled:{true});defer { resumed.suspend() }
        await resumed.reconcile()
        XCTAssertNil(resumed.failure);XCTAssertNil(resumed.activeManifest)
        let record=await store.load(owner:host.context.session.owner,room:host.context.roomID);XCTAssertEqual(record?.phase,.returned)
    }
    @MainActor func testLostReturnVerificationPreservesLiveProgressAndRevalidatesAdvancedHead() async throws {
        for beforeApply in [true,false] {
            let (client,host,backend,store)=fixture();defer { client.suspend() };await backend.setPeerVerified(true)
            await client.createSession();await client.load(source:.init(kind:.builtin,pointID:"01",fixtureVersion:"v1"),settings:Data(repeating:0,count:32))
            await backend.loseBoundaryReply("returnVerify",beforeApply:beforeApply);await client.returnToPreviousRun()
            XCTAssertEqual(client.failure,.timedOut);XCTAssertEqual(host.returnCount,1)
            let pending=await store.load(owner:host.context.session.owner,room:host.context.roomID);XCTAssertEqual(pending?.phase,.returning)
            host.ordinaryProgress=20;host.ordinaryCheckpoint=UUID()
            client.suspend();await backend.restoreBoundaryNetwork();await client.reconcile()
            XCTAssertNil(client.failure);XCTAssertEqual(host.returnCount,1);XCTAssertEqual(host.verifyReturnCount,1)
            XCTAssertEqual(host.ordinaryProgress,20)
            let calls=await backend.captured(),verified=try XCTUnwrap(calls.last { $0["action"]?.string=="returnVerify" })
            XCTAssertEqual(verified["checkpoint"]?.string,host.ordinaryCheckpoint.uuidString.lowercased())
            let complete=await store.load(owner:host.context.session.owner,room:host.context.roomID);XCTAssertEqual(complete?.phase,.returned)
            await client.reconcile();await client.returnToPreviousRun()
            XCTAssertNil(client.failure);XCTAssertEqual(host.returnCount,1);XCTAssertEqual(host.ordinaryProgress,20)
        }
    }
    @MainActor func testLostReturnVerificationFreshClientRecoversCurrentOrdinaryHead() async throws {
        let (client,host,backend,store)=fixture();await backend.setPeerVerified(true)
        await client.createSession();await client.load(source:.init(kind:.builtin,pointID:"01",fixtureVersion:"v1"),settings:Data(repeating:0,count:32))
        await backend.loseBoundaryReply("returnVerify");await client.returnToPreviousRun()
        XCTAssertEqual(client.failure,.timedOut);client.suspend()
        let replacement=DebugHostFixture(context:host.context,peer:host.previous.identity.partner);replacement.previous=host.previous
        replacement.ordinaryCheckpoint=UUID()
        let resumed=BoundDebugSession(host:replacement,storage:store,service:backend,enabled:{true});defer { resumed.suspend() }
        await backend.restoreBoundaryNetwork();await resumed.reconcile()
        XCTAssertNil(resumed.failure);XCTAssertEqual(replacement.returnCount,1);XCTAssertEqual(replacement.verifyReturnCount,0)
        let calls=await backend.captured(),verified=try XCTUnwrap(calls.last { $0["action"]?.string=="returnVerify" })
        XCTAssertEqual(verified["checkpoint"]?.string,replacement.ordinaryCheckpoint.uuidString.lowercased())
    }
    @MainActor func testLostReturnVerificationRejectsUnrelatedSameProfileRunWithoutRestoreFallback() async throws {
        let (client,host,backend,store)=fixture();defer { client.suspend() };await backend.setPeerVerified(true)
        await client.createSession();await client.load(source:.init(kind:.builtin,pointID:"01",fixtureVersion:"v1"),settings:Data(repeating:0,count:32))
        await backend.loseBoundaryReply("returnVerify");await client.returnToPreviousRun()
        XCTAssertEqual(client.failure,.timedOut)
        host.ordinaryRun=UUID();host.ordinaryProgress=42
        await backend.restoreBoundaryNetwork();await client.reconcile()
        XCTAssertEqual(client.failure,.stale);XCTAssertEqual(host.verifyReturnCount,1)
        XCTAssertEqual(host.returnCount,1);XCTAssertEqual(host.ordinaryProgress,42)
        let state=await store.load(owner:host.context.session.owner,room:host.context.roomID);XCTAssertEqual(state?.phase,.returning)
    }
    @MainActor func testReturnVerificationRequestsFreshProofAfterLostReplyAndAdvancedHead() async throws {
        let (_,host,backend,store)=fixture(),first=host.ordinaryCheckpoint,next=UUID()
        let service=DebugLostReturnReply(backend:backend) {
            await MainActor.run { host.ordinaryProgress=31;host.ordinaryCheckpoint=next }
            await backend.requireReturnCheckpoint(next)
        }
        let client=BoundDebugSession(host:host,storage:store,service:service,enabled:{true});defer { client.suspend() }
        await backend.setPeerVerified(true);await backend.requireReturnCheckpoint(first)
        await client.createSession();await client.load(source:.init(kind:.builtin,pointID:"01",fixtureVersion:"v1"),settings:Data(repeating:0,count:32))
        await client.returnToPreviousRun()
        XCTAssertNil(client.failure);XCTAssertEqual(host.returnCount,1);XCTAssertEqual(host.verifyReturnCount,1)
        XCTAssertEqual(host.ordinaryProgress,31)
        let requests=await backend.captured(),proofs=requests.filter { $0["action"]?.string=="returnVerify" }
        XCTAssertEqual(proofs.map { $0["checkpoint"]?.string },[first.uuidString.lowercased(),next.uuidString.lowercased()],
            "No raw retry may resend the old native proof after ordinary progress advances.")
        let state=await store.load(owner:host.context.session.owner,room:host.context.roomID);XCTAssertEqual(state?.phase,.returned)
    }
    @MainActor func testReturningAutomaticallyReconcilesRevokedSessionWithBoundedBackoff() async throws {
        let (_,host,backend,store)=fixture(),gate=DebugPollGate()
        let client=BoundDebugSession(host:host,storage:store,service:backend,enabled:{true},sleep:{ try await gate.sleep($0) })
        defer { client.suspend() }
        await backend.setPeerVerified(true);await client.createSession()
        await client.load(source:.init(kind:.builtin,pointID:"01",fixtureVersion:"v1"),settings:Data(repeating:0,count:32))
        let initialWait=expectation(description:"first bounded poll waits")
        await gate.observe(count:1,expectation:initialWait);await fulfillment(of:[initialWait],timeout:2)
        await backend.loseBoundaryReply("returnVerify");await client.returnToPreviousRun()
        XCTAssertEqual(client.failure,.timedOut);XCTAssertEqual(client.serverSession?.status,.revoked)
        let pending=await store.load(owner:host.context.session.owner,room:host.context.roomID);XCTAssertEqual(pending?.phase,.returning)
        let retryWait=expectation(description:"revoked Return retains next bounded poll")
        await gate.observe(count:2,expectation:retryWait);await gate.advance()
        await fulfillment(of:[retryWait],timeout:2)
        let intervals=await gate.recorded();XCTAssertEqual(intervals,[1,2])
        // No manual refresh/reconcile follows. Ordinary play and its confirmed
        // checkpoint advance before the next automatically scheduled proof.
        host.ordinaryProgress=47;host.ordinaryCheckpoint=UUID()
        await backend.requireReturnCheckpoint(host.ordinaryCheckpoint);await backend.restoreBoundaryNetwork()
        let returned=expectation(description:"automatic Return is durably acknowledged")
        await store.observeReturn(returned);await gate.advance();await fulfillment(of:[returned],timeout:2)
        XCTAssertNil(client.failure);XCTAssertEqual(host.returnCount,1);XCTAssertEqual(host.verifyReturnCount,1)
        XCTAssertEqual(host.ordinaryProgress,47)
        let complete=await store.load(owner:host.context.session.owner,room:host.context.roomID);XCTAssertEqual(complete?.phase,.returned)
        let requests=await backend.captured(),proofs=requests.filter { $0["action"]?.string=="returnVerify" }
        XCTAssertEqual(proofs.count,2);XCTAssertEqual(proofs.last?["checkpoint"]?.string,host.ordinaryCheckpoint.uuidString.lowercased())
    }
    @MainActor func testReturnReceiptValidationDistinguishesOwnedUploadRacesFromForeignHead() throws {
        let known=BoundMultiplayerCheckpointReceipt(run:UUID(),checkpoint:UUID(),owner:UUID(),
            payloadSHA256:String(repeating:"a",count:64),sharedEventDigest:String(repeating:"b",count:64))
        var pending=known;pending.checkpoint=UUID();pending.payloadSHA256=String(repeating:"c",count:64)
        func check(_ observed:BoundMultiplayerCheckpointReceipt,confirmed:UUID,pending head:BoundMultiplayerCheckpointReceipt?,
                   requested:UUID?=nil,uploading:Bool=false) throws {
            try BoundROMMultiplayerCoordinator.validateDebugReturnReceipt(observed,installed:known,
                requestedHead:known,currentHead:head,requestedConfirmed:requested ?? confirmed,
                currentConfirmed:confirmed,uploadInFlight:uploading)
        }
        XCTAssertNoThrow(try check(known,confirmed:known.checkpoint,pending:pending))
        XCTAssertThrowsError(try check(pending,confirmed:known.checkpoint,pending:pending,uploading:true)) { XCTAssertEqual($0 as? BoundDebugFailure,.busy) }
        XCTAssertThrowsError(try check(known,confirmed:known.checkpoint,pending:pending,uploading:true)) { XCTAssertEqual($0 as? BoundDebugFailure,.busy) }
        XCTAssertNoThrow(try check(pending,confirmed:pending.checkpoint,pending:pending,requested:known.checkpoint))
        XCTAssertThrowsError(try check(known,confirmed:pending.checkpoint,pending:pending,requested:known.checkpoint)) { XCTAssertEqual($0 as? BoundDebugFailure,.busy) }
        var foreign=known;foreign.checkpoint=UUID()
        XCTAssertThrowsError(try check(foreign,confirmed:pending.checkpoint,pending:pending,requested:known.checkpoint)) { XCTAssertEqual($0 as? BoundDebugFailure,.busy) }
        XCTAssertThrowsError(try check(foreign,confirmed:pending.checkpoint,pending:pending)) { XCTAssertEqual($0 as? BoundDebugFailure,.stale) }
        for field in ["payload","history","owner","run"] {
            var tampered=known
            switch field {
            case "payload":tampered.payloadSHA256=String(repeating:"f",count:64)
            case "history":tampered.sharedEventDigest=String(repeating:"f",count:64)
            case "owner":tampered.owner=UUID()
            default:tampered.run=UUID()
            }
            XCTAssertThrowsError(try check(tampered,confirmed:pending.checkpoint,pending:pending,requested:known.checkpoint,uploading:true)) {
                XCTAssertEqual($0 as? BoundDebugFailure,.stale,"An owned upload cannot authorize altered \(field) metadata.")
            }
        }
    }
    @MainActor func testForeignReturnHeadRejectsWithoutRestoringOrRewindingOrdinaryProgress() async throws {
        let (client,host,backend,store)=fixture();defer { client.suspend() };await backend.setPeerVerified(true)
        await client.createSession();await client.load(source:.init(kind:.builtin,pointID:"01",fixtureVersion:"v1"),settings:Data(repeating:0,count:32))
        await backend.loseBoundaryReply("returnVerify");await client.returnToPreviousRun()
        host.ordinaryProgress=61
        host.observedReturnReceipt = .init(run:host.previous.identity.run,checkpoint:UUID(),owner:host.context.session.owner,
            payloadSHA256:String(repeating:"a",count:64),sharedEventDigest:String(repeating:"b",count:64))
        await backend.restoreBoundaryNetwork();await client.reconcile()
        XCTAssertEqual(client.failure,.stale);XCTAssertEqual(host.verifyReturnCount,1)
        XCTAssertEqual(host.returnCount,1);XCTAssertEqual(host.ordinaryProgress,61)
        let state=await store.load(owner:host.context.session.owner,room:host.context.roomID);XCTAssertEqual(state?.phase,.returning)
        let requests=await backend.captured();XCTAssertEqual(requests.filter { $0["action"]?.string=="returnVerify" }.count,1)
    }
    @MainActor func testScopedGameplayFenceRetainsMediaAndRejectsOldSocketCallbacks() async throws {
        let room=DebugRoomFixture(),media=DebugMediaFixture(),owner=UUID(),peer=UUID()
        let transport=BoundNakamaSharingTransport(media:media,client:room)
        let config=BoundNakamaConfiguration(endpoint:URL(string:"wss://bound.example/ws?format=json")!,accessToken:"fixture",
            expiresAt:Date().timeIntervalSince1970+30,matchID:"debug",roomID:UUID(),ownerID:owner,nakamaUserID:UUID(),joinTicket:"ticket",members:[owner,peer],peerOwnerID:peer)
        let display=FriendSharingConfiguration(appID:String(repeating:"0",count:32),channel:"logical",uid:1,remoteUID:2,token:"fixture")
        defer { transport.stop() }
        let joined=expectation(description:"first room"),rejoined=expectation(description:"replacement room")
        var failures=0,values:[Data]=[]
        transport.configureGameplay(config,debug:true);transport.setVideoRequired(true)
        transport.start(configuration:display,remoteView:UIView()) { event in
            if event == .joined { joined.fulfill() };if event == .rejoined { rejoined.fulfill() }
            if case .failed=event { failures+=1 }
        }
        await fulfillment(of:[joined],timeout:2)
        let starts=media.starts,stops=media.stops
        transport.suspendGameplay();XCTAssertFalse(transport.sendPresence(Data([1])))
        XCTAssertEqual(media.starts,starts);XCTAssertEqual(media.stops,stops)
        transport.configureGameplay(config,debug:true);XCTAssertTrue(transport.startConfiguredGameplay(rejoining:true))
        await fulfillment(of:[rejoined],timeout:2)
        transport.setPresenceReceiver { values.append($0) }
        room.emit(.failed(.connectionLost),index:0)
        room.emit(.message(opcode:1,data:Data([1]),senderOwnerID:peer),index:0)
        room.emit(.message(opcode:1,data:Data([2]),senderOwnerID:peer),index:1)
        let drained=expectation(description:"queued events");DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of:[drained],timeout:2);transport.pollPresence()
        XCTAssertEqual(failures,0);XCTAssertEqual(values,[Data([2])]);XCTAssertEqual(media.starts,starts);XCTAssertEqual(media.stops,stops)
        XCTAssertTrue(transport.renewGameplay(config,debug:true));XCTAssertFalse(transport.renewGameplay(config))
    }
    @MainActor func testWithheldDebugProviderNeverFetchesOrdinaryRoomAndPendingGatesFirstSwitch() async throws {
        let previous=UserDefaults.standard.object(forKey:BoundMultiplayerFeatures.key);BoundMultiplayerFeatures.setEnabled(true)
        defer { UserDefaults.standard.set(previous,forKey:BoundMultiplayerFeatures.key) }
        let owner=UUID(),room=UUID(),account=identity(owner:owner),wire=DebugRoomFixture()
        let transport=BoundNakamaSharingTransport(media:DebugMediaFixture(),client:wire)
        var ordinaryRequests=0,debugRequests=0
        let sharing=FriendSharingSession(configuration:nil,transport:transport,authenticatedMode:true,roomProvider:{room.uuidString},
            nakamaFetcher:{ _,_ in ordinaryRequests+=1;throw BoundDebugFailure.rejected })
        sharing.authenticatedSession={account};defer { sharing.stop() }
        sharing.setDebugSwitchPending(true)
        XCTAssertNil(sharing.interactions.admissionIdentity?(),"First ordinary switch blocks new activities before a debug room exists")
        let scope=BoundDebugRealtimeScope(sessionID:UUID(),membershipEpoch:1,generation:1,manifestDigest:String(repeating:"a",count:64))
        sharing.setDebugRealtimeProvider(scope:scope,provider:nil);sharing.start()
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(ordinaryRequests,0)
        sharing.setDebugRealtimeProvider(scope:scope,provider:{ _,_ in debugRequests+=1;throw BoundDebugFailure.expired })
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(debugRequests,1);XCTAssertEqual(ordinaryRequests,0)
        sharing.setDebugRealtimeProvider(scope:scope,provider:nil)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(ordinaryRequests,0)
    }
    @MainActor func testLostCaptureReadinessReconcilesDurableBoundaryBeforePreflightAfterRestart() async throws {
        let (client,host,backend,store)=fixture();await backend.setPeerVerified(true)
        await client.createSession();await client.load(source:.init(kind:.builtin,pointID:"01",fixtureVersion:"v1"),settings:Data(repeating:0,count:32))
        let active=client.activeManifest?.digest,owner=host.context.session.owner,room=host.context.roomID
        host.boundaryObserved={ id in
            let saved=await store.load(owner:owner,room:room)
            XCTAssertEqual(saved?.boundaryPending,id,"Pause intent must be durable before native boundary entry")
        }
        await backend.loseBoundaryReply("captureReady");await client.saveCustom()
        XCTAssertEqual(client.failure,.timedOut);XCTAssertNotNil(host.heldBoundary);XCTAssertEqual(host.cutReleased,0)
        let uncertain=await store.load(owner:owner,room:room)
        XCTAssertNotNil(uncertain?.boundaryPending);XCTAssertNil(uncertain?.descriptor);XCTAssertNotNil(uncertain?.bookmark)
        client.suspend();await backend.restoreBoundaryNetwork()
        let resumed=BoundDebugSession(host:host,storage:store,service:backend,enabled:{true});defer { resumed.suspend() }
        let start=Date();await resumed.reconcile()
        XCTAssertLessThan(Date().timeIntervalSince(start),3);XCTAssertNil(resumed.failure)
        XCTAssertNil(host.heldBoundary);XCTAssertEqual(host.cutReleased,1);XCTAssertEqual(host.cutCount,1)
        XCTAssertEqual(resumed.activeManifest?.digest,active);XCTAssertFalse(host.switchPending)
        let saved=await store.load(owner:owner,room:room);XCTAssertNil(saved?.boundaryPending);XCTAssertEqual(saved?.phase,.verified)
        let calls=await backend.captured();XCTAssertEqual(calls.filter { $0["action"]?.string=="captureReady" }.count,1)
        XCTAssertTrue(calls.contains { $0["action"]?.string=="abort" })
    }
    @MainActor func testLostReturnReadinessReconcilesBothUnacknowledgedAndAcceptedBoundaries() async throws {
        for beforeApply in [true,false] {
            let (client,host,backend,store)=fixture();defer { client.suspend() };await backend.setPeerVerified(true)
            await client.createSession();await client.load(source:.init(kind:.builtin,pointID:"01",fixtureVersion:"v1"),settings:Data(repeating:0,count:32))
            let active=client.activeManifest?.digest,owner=host.context.session.owner,room=host.context.roomID
            host.boundaryObserved={ id in
                let saved=await store.load(owner:owner,room:room);XCTAssertEqual(saved?.boundaryPending,id)
            }
            await backend.loseBoundaryReply("returnReady",beforeApply:beforeApply);await client.returnToPreviousRun()
            XCTAssertEqual(client.failure,.timedOut);XCTAssertNotNil(host.heldBoundary);XCTAssertEqual(host.cutReleased,0)
            let uncertain=await store.load(owner:owner,room:room);XCTAssertNotNil(uncertain?.boundaryPending)
            await backend.restoreBoundaryNetwork();let start=Date();await client.reconcile()
            XCTAssertLessThan(Date().timeIntervalSince(start),3);XCTAssertNil(client.failure);XCTAssertNil(host.heldBoundary)
            let saved=await store.load(owner:owner,room:room);XCTAssertNil(saved?.boundaryPending)
            if beforeApply {
                XCTAssertEqual(host.cutReleased,1);XCTAssertEqual(host.returnCount,0);XCTAssertEqual(client.activeManifest?.digest,active)
            } else { XCTAssertEqual(host.returnCount,1);XCTAssertEqual(saved?.phase,.returned) }
            let calls=await backend.captured();XCTAssertEqual(calls.filter { $0["action"]?.string=="returnReady" }.count,1)
        }
    }
    @MainActor func testRevokedReconcileRetainsRecoveryAndBookmarkWithoutRestoringDebugGameplay() async throws {
        let (client,host,backend,store)=fixture();defer { client.suspend() };await backend.setPeerVerified(true)
        await client.createSession();await client.load(source:.init(kind:.builtin,pointID:"01",fixtureVersion:"v1"),settings:Data(repeating:0,count:32))
        let restores=host.restoreCount,completions=host.completeCount,manifest=client.activeManifest
        await client.revoke();await client.reconcile()
        XCTAssertEqual(client.failure,.revoked);XCTAssertEqual(host.restoreCount,restores);XCTAssertEqual(host.completeCount,completions)
        XCTAssertNil(host.admission);XCTAssertNil(host.continuation);XCTAssertEqual(client.activeManifest,manifest);XCTAssertTrue(client.canReturn)
        let record=await store.load(owner:host.context.session.owner,room:host.context.roomID)
        XCTAssertEqual(record?.phase,.verified);XCTAssertNotNil(record?.bookmark);XCTAssertTrue(record?.membershipEnded==true)
        host.busy=true // Only the host's validated return path decides its boundary.
        await client.returnToPreviousRun()
        XCTAssertNil(client.failure);XCTAssertEqual(host.returnCount,1)
    }
    @MainActor func testDefaultDisabledClientNeverRequestsServerAuthority() async throws {
        let (_,host,backend,store)=fixture()
        let client=BoundDebugSession(host:host,storage:store,service:backend)
        await client.createSession();XCTAssertEqual(client.failure,.unavailable)
        let calls=await backend.captured();XCTAssertTrue(calls.isEmpty)
    }
    func testPrivateIntentStoragePreservesImmutablePayloadAndRejectsCapabilities() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        let storage=BoundDebugDiskStore(directory:directory),owner=UUID(),room=UUID(),operation=UUID()
        var state=BoundDebugLocalState(ownerID:owner,roomID:room,deviceID:UUID(),sessionID:UUID())
        try await storage.save(state);let loaded=try await storage.load(owner:owner,room:room);XCTAssertEqual(loaded,state)
        try await storage.savePayload(Data([1,2,3]),owner:owner,operation:operation)
        do { try await storage.savePayload(Data([4]),owner:owner,operation:operation);XCTFail("Immutable payload") } catch { }
        let payload=try await storage.payload(owner:owner,operation:operation);XCTAssertEqual(payload,Data([1,2,3]))
        state.request=["capability":.string("never persist")]
        do { try await storage.save(state);XCTFail("Credential in intent") } catch { }
        let preserved=try await storage.load(owner:owner,room:room);XCTAssertNil(preserved?.request)
    }
    func testDebugHTTPUsesCurrentAuthenticatedFixedOriginAndNoAPIKey() async throws {
        let fixture=DebugHTTPFixture(),session=identity(),service=BoundDebugService(transport:{ await fixture.call($0) })
        let result=try await service.request(["action":.string("status")],session:session)
        XCTAssertEqual(result["version"]?.integer,1)
        let requests=await fixture.captured(),request=try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.absoluteString,"https://bound.example/functions/v1/bound-debug")
        XCTAssertEqual(request.httpMethod,"POST");XCTAssertNil(request.value(forHTTPHeaderField:"apikey"))
        XCTAssertTrue(request.value(forHTTPHeaderField:"Authorization")?.hasPrefix("Bearer fixture.")==true)
        XCTAssertEqual(try BoundDebugJSON(data:XCTUnwrap(request.httpBody))["action"]?.string,"status")
    }
    func testDebugHTTPRejectsRedirectOversizeAndMalformedBodiesWithoutLeakingResponse() async throws {
        let fixtures=[DebugHTTPFixture(redirect:true),DebugHTTPFixture(data:Data(repeating:65,count:524_289)),
                      DebugHTTPFixture(data:Data("[1,2,3]".utf8)),DebugHTTPFixture(status:403,data:Data("secret-bearer".utf8))]
        for fixture in fixtures {
            do { _=try await BoundDebugService(transport:{ await fixture.call($0) }).request(["action":.string("status")],session:identity());XCTFail("Must reject") }
            catch { XCTAssertFalse(error.localizedDescription.contains("secret-bearer")) }
        }
        let fixture=DebugHTTPFixture()
        do {
            _=try await BoundDebugService(transport:{ await fixture.call($0) }).request(["action":.string("status"),"extra":.string(String(repeating:"x",count:65_536))],session:identity())
            XCTFail("Oversized request must fail before transport")
        } catch { }
        let captured=await fixture.captured();XCTAssertTrue(captured.isEmpty)
    }
    func testDebugJSONCanonicalObjectOrderBoundsAndNumberTypes() throws {
        let first=try BoundDebugJSON(data:Data("{\"z\":true,\"a\":1,\"path\":\"x/y\"}".utf8))
        let second=try BoundDebugJSON(data:Data("{\"path\":\"x/y\",\"a\":1,\"z\":true}".utf8))
        XCTAssertEqual(try first.data(),try second.data())
        XCTAssertEqual(first["a"]?.integer,1);XCTAssertNil(first["z"]?.integer);XCTAssertEqual(first["z"]?.boolean,true)
        XCTAssertThrowsError(try BoundDebugJSON(data:Data((String(repeating:"[",count:26)+"0"+String(repeating:"]",count:26)).utf8)))
        XCTAssertNil(BoundDebugJSON.number(9_007_199_254_740_992).integer)
        XCTAssertFalse(BoundDebugJSON.validDigest(String(repeating:"A",count:64)))
    }
}
