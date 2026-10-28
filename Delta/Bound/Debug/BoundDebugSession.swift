import Foundation
import Combine
import Darwin

protocol BoundDebugIntentStorage: Sendable {
    func load(owner:UUID,room:UUID) async throws -> BoundDebugLocalState?
    func save(_ state:BoundDebugLocalState) async throws
    func savePayload(_ bytes:Data,owner:UUID,operation:UUID) async throws
    func payload(owner:UUID,operation:UUID) async throws -> Data?
}

/// This private app directory retains recovery evidence, never account tokens.
/// An immutable payload is separate from the small atomic switch-intent record.
actor BoundDebugDiskStore: BoundDebugIntentStorage {
    private let directory:URL
    init(directory:URL) { self.directory=directory }
    private func record(_ owner:UUID,_ room:UUID)->URL {
        directory.appendingPathComponent(owner.uuidString.lowercased()+"-"+room.uuidString.lowercased()+".json")
    }
    private func blob(_ owner:UUID,_ operation:UUID)->URL {
        directory.appendingPathComponent(owner.uuidString.lowercased()+"-"+operation.uuidString.lowercased()+".payload")
    }
    private func read(_ url:URL,maximum:Int) throws -> Data? {
        guard FileManager.default.fileExists(atPath:url.path) else { return nil }
        let properties=try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
        guard properties.isRegularFile==true,properties.isSymbolicLink != true,
              let bytes=properties.fileSize,bytes<=maximum else { throw BoundDebugFailure.storage }
        let data=try Data(contentsOf:url);guard data.count<=maximum else { throw BoundDebugFailure.storage };return data
    }
    private func write(_ data:Data,to url:URL) throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        try data.write(to:url,options:[.atomic,.completeFileProtectionUntilFirstUserAuthentication])
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path)
        let handle=try FileHandle(forWritingTo:url);defer { try? handle.close() };try handle.synchronize()
        let fd=Darwin.open(directory.path,O_RDONLY);guard fd>=0 else { throw BoundDebugFailure.storage }
        defer { Darwin.close(fd) };guard Darwin.fsync(fd)==0 else { throw BoundDebugFailure.storage }
    }
    func load(owner:UUID,room:UUID) throws -> BoundDebugLocalState? {
        guard let data=try read(record(owner,room),maximum:524_288) else { return nil }
        return try JSONDecoder().decode(BoundDebugLocalState.self,from:data)
    }
    func save(_ state:BoundDebugLocalState) throws {
        guard state.valid(owner:state.ownerID,room:state.roomID,device:state.deviceID) else { throw BoundDebugFailure.storage }
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let data=try encoder.encode(state);guard data.count<=524_288 else { throw BoundDebugFailure.storage }
        try write(data,to:record(state.ownerID,state.roomID))
    }
    func savePayload(_ bytes:Data,owner:UUID,operation:UUID) throws {
        guard !bytes.isEmpty,bytes.count<=16_777_216 else { throw BoundDebugFailure.storage }
        let destination=blob(owner,operation)
        if let existing=try read(destination,maximum:16_777_216) {
            guard existing==bytes else { throw BoundDebugFailure.storage };return
        }
        try write(bytes,to:destination)
    }
    func payload(owner:UUID,operation:UUID) throws -> Data? { try read(blob(owner,operation),maximum:16_777_216) }
}

@MainActor final class BoundDebugSession: ObservableObject {
    enum Status:String,Sendable { case preparing="Preparing",waiting="Waiting for Buddy",loading="Loading",ready="Ready",ended="Point Ended",failed="Failed" }
    @Published private(set) var status:Status = .waiting
    @Published private(set) var failure:BoundDebugFailure?
    @Published private(set) var serverSession:BoundDebugServerSession?
    @Published private(set) var operation:BoundDebugOperation?
    @Published private(set) var manifest:BoundDebugManifest?
    @Published private(set) var activeManifest:BoundDebugManifest?
    @Published private(set) var captures:[BoundDebugCapture]=[]
    @Published private(set) var invitations:[BoundDebugServerSession]=[]
    @Published private(set) var isBusy=false
    @Published private(set) var bookmark:BoundDebugBookmark?
    @Published private(set) var terminal:BoundDebugTerminalProof?
    private weak var host:(any BoundDebugHost)?
    private let service:any BoundDebugServing,storage:any BoundDebugIntentStorage
    private let enabled:()->Bool,clock:()->TimeInterval
    private let sleep:@Sendable (TimeInterval) async throws -> Void
    private var token=UUID(),context:BoundDebugHostContext?,local:BoundDebugLocalState?,capability:String?
    private var polling:Task<Void,Never>?,lastRenewed:TimeInterval=0,lastVerified:TimeInterval=0
    private var completedRestoreGeneration:Int?
    private struct CompletedReturn {
        let sessionID:UUID,bookmark:BoundDebugBookmark,context:BoundDebugHostContext
        var verification:BoundDebugReturnVerification
    }
    // This is an execution receipt, not durable authority. A new process must
    // recover the current ordinary head through the normal host restore path.
    private var completedReturn:CompletedReturn?
    private var own:BoundDebugOwnerView?,timings:[String:TimeInterval]=[:]
    var currentPointID:String? { manifest?.source.pointID ?? operation?.source.pointID }
    var isController:Bool { serverSession?.controllerID==context?.session.owner }
    var canReturn:Bool { bookmark != nil }

    init(host:any BoundDebugHost,storage:any BoundDebugIntentStorage,service:any BoundDebugServing=BoundDebugService(),
         enabled:@escaping ()->Bool={false},clock:@escaping ()->TimeInterval={Date().timeIntervalSince1970},
         sleep:@escaping @Sendable (TimeInterval) async throws -> Void={ try await Task.sleep(nanoseconds:UInt64(max(0,$0)*1_000_000_000)) }) {
        self.host=host;self.storage=storage;self.service=service;self.enabled=enabled;self.clock=clock;self.sleep=sleep
    }
    deinit { polling?.cancel() }

    private func begin() throws -> (BoundDebugHostContext,UUID) {
        guard enabled(),let host else { throw BoundDebugFailure.unavailable }
        let value=try host.debugContext();try value.session.credentials()
        guard value.compatibility.known else { throw BoundDebugFailure.incompatible }
        if let context,!context.sameAuthority(as:value) {
            // Keep the original intent's storage scope when its expected Return
            // installs another ordinary profile/room within this same authority.
            if allowsOrdinaryReturn(from:context,to:value) { return (context,token) }
            invalidateLocalAuthority()
        }
        context=value
        return (value,token)
    }
    private func check(_ expected:BoundDebugHostContext,_ run:UUID) throws {
        guard run==token,enabled(),let value=try host?.debugContext() else { throw BoundDebugFailure.stale }
        guard expected.sameAuthority(as:value) || allowsOrdinaryReturn(from:expected,to:value) else { throw BoundDebugFailure.stale }
        try expected.session.credentials()
    }
    private func allowsOrdinaryReturn(from expected:BoundDebugHostContext,to value:BoundDebugHostContext)->Bool {
        local?.phase == .returning && local?.bookmark.map { bookmark in
            expected.session.isSameSession(as:value.session) && expected.deviceID==value.deviceID && expected.authorityGeneration==value.authorityGeneration
            && (value.roomID==expected.roomID || value.roomID==UUID(uuidString:bookmark.identity.roomID))
            && value.compatibility.known && value.compatibility.romSHA256==bookmark.identity.romSHA256 && value.compatibility.gameID==bookmark.identity.gameID
        }==true
    }
    private func invalidateLocalAuthority() {
        token=UUID();capability=nil;lastRenewed=0;lastVerified=0;completedRestoreGeneration=nil;completedReturn=nil;host?.setDebugAdmission(nil);host?.setDebugContinuation(nil)
        polling?.cancel();polling=nil;isBusy=false
        context=nil;local=nil;bookmark=nil;serverSession=nil;operation=nil;manifest=nil;activeManifest=nil;own=nil;captures=[];terminal=nil
    }
    private func failed(_ error:Error) {
        if (error as? BoundDebugFailure) != .busy { host?.setDebugAdmission(nil);host?.setDebugContinuation(nil) }
        if error is CancellationError { return }
        failure=(error as? BoundDebugFailure) ?? .unavailable;status = .failed
    }
    private func persist(_ value:BoundDebugLocalState,context:BoundDebugHostContext,token:UUID) async throws {
        try await storage.save(value);try check(context,token);local=value;bookmark=value.bookmark
    }
    private func loadLocal(_ context:BoundDebugHostContext,_ run:UUID) async throws {
        if let local,local.ownerID==context.session.owner,local.roomID==context.roomID {
            guard local.valid(owner:context.session.owner,room:context.roomID,device:context.deviceID) else { throw BoundDebugFailure.stale };return
        }
        let value=try await storage.load(owner:context.session.owner,room:context.roomID);try check(context,run)
        guard value?.valid(owner:context.session.owner,room:context.roomID,device:context.deviceID) ?? true else { throw BoundDebugFailure.stale }
        local=value;bookmark=value?.bookmark
        activeManifest=value?.manifest ?? value?.previousManifest
    }
    private struct TerminalPreparation {
        let proof:BoundDebugTerminalProof,manifest:BoundDebugManifest,identity:BoundMultiplayerRunIdentity,bookmark:BoundDebugBookmark
    }
    private func terminalProof(for manifest:BoundDebugManifest,_ context:BoundDebugHostContext,_ run:UUID) async throws -> BoundDebugTerminalProof? {
        var body=try fields("terminal");body["generation"] = .number(Double(manifest.generation))
        // Do not replace a pending operation with the source operation envelope.
        let response=try await raw(body,context:context,token:run)
        try validateGameplayEnvelope(response,context:context,sessionID:manifest.sessionID,generation:manifest.generation)
        guard let value=response["terminal"] else { throw BoundDebugFailure.invalidResponse }
        if value == .null { return nil }
        let proof=try value.decode(BoundDebugTerminalProof.self)
        guard proof.valid(manifest:manifest,owner:context.session.owner,device:context.deviceID),
              proof.membershipEpoch==serverSession?.membershipEpoch else { throw BoundDebugFailure.invalidResponse }
        return proof
    }
    private func prepareTerminal(_ proof:BoundDebugTerminalProof,manifest:BoundDebugManifest,identity supplied:BoundMultiplayerRunIdentity?=nil,
                                 _ context:BoundDebugHostContext,_ run:UUID) async throws -> TerminalPreparation {
        guard let host,let identity=supplied ?? local?.installedIdentity,identity.valid,
              identity.run==manifest.runID,identity.owner==context.session.owner,identity.roomID.lowercased()==context.roomID.uuidString.lowercased(),
              identity.gameID==manifest.compatibility.gameID,identity.romSHA256==manifest.compatibility.romSHA256,identity.settings==manifest.settings,
              serverSession?.owners.contains(identity.partner)==true,
              manifest.owners[identity.owner.uuidString.lowercased()]?.trainer.id==identity.localSeed,
              manifest.owners[identity.partner.uuidString.lowercased()]?.trainer.id==identity.partnerSeed,
              proof.valid(manifest:manifest,owner:context.session.owner,device:context.deviceID) else { throw BoundDebugFailure.stale }
        terminal=proof;host.setDebugAdmission(nil);host.setDebugContinuation(nil)
        let bookmark=try await host.prepareDebugTerminalTransition(proof:proof,manifest:manifest,identity:identity);try check(context,run)
        guard bookmark==local?.bookmark,bookmark.valid(owner:context.session.owner) else { throw BoundDebugFailure.stale }
        return .init(proof:proof,manifest:manifest,identity:identity,bookmark:bookmark)
    }
    private func preflightSwitch(allowTerminal:Bool,_ context:BoundDebugHostContext,_ run:UUID) async throws -> TerminalPreparation? {
        if let active=activeManifest,let proof=try await terminalProof(for:active,context,run) {
            terminal=proof;host?.setDebugAdmission(nil);host?.setDebugContinuation(nil)
            guard allowTerminal else { throw BoundDebugFailure.busy }
            return try await prepareTerminal(proof,manifest:active,context,run)
        }
        try host?.preflightDebugSwitch();return nil
    }
    private func retainTerminal(_ proof:BoundDebugTerminalProof,manifest:BoundDebugManifest,operation:BoundDebugOperation,
                                state original:BoundDebugLocalState,_ context:BoundDebugHostContext,_ run:UUID) async throws {
        guard let admittedIdentity=operation.identities[context.session.owner.uuidString.lowercased()] else { throw BoundDebugFailure.stale }
        let identity:BoundMultiplayerRunIdentity
        if original.manifest?.digest==manifest.digest || original.previousManifest?.digest==manifest.digest {
            guard let retained=original.installedIdentity,retained==admittedIdentity else { throw BoundDebugFailure.stale }
            identity=retained
        } else { identity=admittedIdentity }
        let prepared=try await prepareTerminal(proof,manifest:manifest,identity:identity,context,run)
        var state=original
        state.operationID=operation.operationID;state.generation=operation.generation;state.membershipEpoch=operation.membershipEpoch
        state.request=nil;state.manifest=manifest;state.previousManifest=nil;state.descriptor=manifest.owners[context.session.owner.uuidString.lowercased()]
        state.bookmark=prepared.bookmark;state.installedIdentity=identity;state.verification=nil;state.boundaryPending=nil;state.phase = .committed
        try await persist(state,context:context,token:run)
        activeManifest=manifest;completedRestoreGeneration=nil;lastVerified=0;status = .ended
        host?.setDebugSwitchPending(false)
    }

    private func work(_ body:(BoundDebugHostContext,UUID) async throws -> Void) async {
        guard !isBusy else { return }
        do {
            let (context,run)=try begin();isBusy=true;failure=nil
            defer {
                if run==token {
                    isBusy=false
                    if shouldReconcileReturn { startPolling() }
                }
            }
            do { try await loadLocal(context,run);try await body(context,run) }
            catch { if run==token { failed(error) } }
        } catch { failed(error) }
    }
    private func ensure(_ expected:BoundDebugOperation) throws {
        guard operation?.operationID==expected.operationID,operation?.generation==expected.generation,
              serverSession?.membershipEpoch==expected.membershipEpoch,serverSession?.status == .active else { throw BoundDebugFailure.stale }
    }
    private func invoke(_ action:String,operation:BoundDebugOperation?=nil,extra:[String:BoundDebugJSON]=[:],
                        capabilityRequired:Bool=true,context:BoundDebugHostContext,run:UUID,timeout:TimeInterval=10) async throws -> BoundDebugJSON {
        var body=try fields(action,operation:operation,capabilityRequired:capabilityRequired)
        body.merge(extra) { _,new in new }
        // Ordinary play can publish another checkpoint after a lost Return
        // acknowledgement. Retrying that body would replay an obsolete proof;
        // reconciliation must ask the continuing host for a fresh one instead.
        return try accept(await raw(body,context:context,token:run,retry:timeout>=10 && action != "returnVerify",timeout:timeout),context:context,token:run)
    }

    func listInvitations() async {
        await work { context,run in
            let response=try await self.raw(["action":.string("list")],context:context,token:run)
            guard response["version"]?.integer==1,let rows=response["sessions"]?.array,rows.count<=100 else { throw BoundDebugFailure.invalidResponse }
            let values=try rows.map { try $0.decode(BoundDebugServerSession.self) }
            guard values.allSatisfy({ $0.valid(owner:context.session.owner,room:$0.roomID) }) else { throw BoundDebugFailure.invalidResponse }
            self.invitations=values.filter { $0.roomID==context.roomID }
        }
    }
    func createSession() async {
        await work { context,run in
            if self.local==nil || self.local?.phase == .returned {
                try await self.persist(.init(ownerID:context.session.owner,roomID:context.roomID,deviceID:context.deviceID,sessionID:UUID()),context:context,token:run)
            }
            guard let local=self.local,local.operationID==nil else { throw BoundDebugFailure.busy }
            let response=try await self.raw(["action":.string("create"),"sessionID":.string(local.sessionID.uuidString.lowercased()),
                "roomID":.string(context.roomID.uuidString.lowercased())],context:context,token:run)
            try self.accept(response,context:context,token:run);self.status = .waiting
            self.startPolling()
        }
    }
    func join(sessionID:UUID,membershipEpoch:Int) async {
        await work { context,run in
            guard membershipEpoch>0,self.local?.manifest==nil || self.local?.phase == .returned || self.local?.sessionID==sessionID else { throw BoundDebugFailure.busy }
            var state=BoundDebugLocalState(ownerID:context.session.owner,roomID:context.roomID,deviceID:context.deviceID,sessionID:sessionID)
            if self.local?.sessionID==sessionID { state=self.local! }
            state.membershipEpoch=membershipEpoch
            try await self.persist(state,context:context,token:run)
            let response=try await self.raw(["action":.string("join"),"sessionID":.string(sessionID.uuidString.lowercased()),
                "membershipEpoch":.number(Double(membershipEpoch))],context:context,token:run)
            try self.accept(response,context:context,token:run);try await self.drive(context,run);self.startPolling()
        }
    }
    func refresh() async { await refreshState() }
    func reconcile() async { await refreshState() }
    /// A completed foreground save invalidates native working authority even
    /// when this process retains its earlier installation receipt. Revalidate
    /// the latest scoped head through the same recovery path as a fresh process.
    func reconcileNativeInstallation() async {
        suspend();completedRestoreGeneration=nil
        let run=token
        await reconcile()
        if run==token,failure==nil,serverSession?.status == .active,local?.phase != .returned { startPolling() }
    }
    private func refreshState() async {
        await work { context,run in
            guard let state=self.local else { return }
            let action=self.capability==nil || self.clock()-self.lastRenewed>=30 ? "resume":"status"
            let body:[String:BoundDebugJSON] = ["action":.string(action),"sessionID":.string(state.sessionID.uuidString.lowercased())]
            try self.accept(await self.raw(body,context:context,token:run),context:context,token:run)
            if self.local?.phase == .returned { self.status = .waiting;return }
            if self.local?.phase == .returning { try await self.returnToOrdinary(context,run);return }
            if self.serverSession?.status == .revoked {
                if state.phase == .preparing,state.request?["kind"]?.string=="return",let id=state.operationID,
                   self.operation?.operationID != id {
                    let response=try await self.raw(["action":.string("status"),"sessionID":.string(state.sessionID.uuidString.lowercased()),
                        "operationID":.string(id.uuidString.lowercased())],context:context,token:run)
                    try self.accept(response,context:context,token:run)
                }
                if self.operation?.kind == .return,let operation=self.operation,[.committed,.ready].contains(operation.state) {
                    try await self.driveReturn(operation,context,run);return
                }
                // Revocation retains immutable recovery evidence and the
                // ordinary bookmark, but grants no scoped gameplay authority.
                // A committed Return intent above may reconcile; other callers
                // must explicitly choose the normally validated Return action.
                self.host?.setDebugAdmission(nil);self.host?.setDebugContinuation(nil)
                throw BoundDebugFailure.revoked
            }
            guard self.local?.membershipEnded != true else { throw BoundDebugFailure.revoked }
            if try await self.reconcilePersistedCustomOperation(context,run) { return }
            if state.phase == .preparing,let request=state.request,self.operation?.operationID != state.operationID {
                guard let capability=self.capability else { throw BoundDebugFailure.expired }
                var retry=request;retry["capability"] = .string(capability)
                try self.accept(await self.raw(retry,context:context,token:run),context:context,token:run)
            }
            try await self.drive(context,run)
        }
    }
    /// Archive-only commit clears the server's active operation while leaving
    /// its gameplay generation unchanged. Recover the saved operation before
    /// interpreting a default status response as that older active generation.
    private func reconcilePersistedCustomOperation(_ context:BoundDebugHostContext,_ run:UUID) async throws -> Bool {
        guard let state=local,[.preparing,.sealed].contains(state.phase),
              let id=state.operationID,let generation=state.generation,operation?.operationID != id,
              state.request?["kind"]?.string=="custom" || state.descriptor?.cutDigest != nil else { return false }
        guard let active=activeManifest,let session=serverSession,
              session.currentGeneration==active.generation,session.currentManifestDigest==active.digest,
              session.activeOperationID==nil || session.activeOperationID==id else { throw BoundDebugFailure.stale }
        let response=try await raw(["action":.string("status"),"sessionID":.string(state.sessionID.uuidString.lowercased()),
            "operationID":.string(id.uuidString.lowercased())],context:context,token:run)
        guard let recovered=try response["operation"]?.decode(BoundDebugOperation.self),
              recovered.operationID==id,recovered.generation==generation else { throw BoundDebugFailure.invalidResponse }
        // Reloading a custom capture also carries a cut digest, but it is an
        // activating operation and follows the ordinary committed restore path.
        guard recovered.kind == .custom else { return false }
        guard let current=try response["session"]?.decode(BoundDebugServerSession.self),
              current.status == .active,current.membershipEpoch==active.membershipEpoch,
              recovered.membershipEpoch==current.membershipEpoch,
              current.currentGeneration==active.generation,current.currentManifestDigest==active.digest,
              current.activeOperationID==nil || current.activeOperationID==id,
              recovered.source.sourceGeneration==active.generation else { throw BoundDebugFailure.stale }
        try accept(response,context:context,token:run)
        try await drive(context,run)
        return true
    }
    func load(source:BoundDebugSource,settings:Data,kind:BoundDebugOperation.Kind = .load) async {
        await work { context,run in
            guard context.compatibility.valid,source.valid,settings.count==32,[.load,.reload,.custom].contains(kind),let session=self.serverSession,
                  session.status == .active,session.controllerID==context.session.owner,Set(session.joined)==Set(session.owners),
                  let capability=self.capability else { throw BoundDebugFailure.rejected }
            let terminalSource=try await self.preflightSwitch(allowTerminal:kind != .custom,context,run)
            self.host?.setDebugSwitchPending(true)
            self.host?.setDebugAdmission(nil);self.status = .preparing
            var state=self.local ?? .init(ownerID:context.session.owner,roomID:context.roomID,deviceID:context.deviceID,sessionID:session.sessionID)
            if state.phase == .preparing,let request=state.request {
                var request=request;request["capability"] = .string(capability)
                try self.accept(await self.raw(request,context:context,token:run),context:context,token:run)
                try await self.drive(context,run);self.startPolling();return
            }
            guard self.operation==nil || [.ready,.aborted].contains(self.operation!.state)
                    || terminalSource != nil && self.operation?.state == .committed || state.phase == .returned else { throw BoundDebugFailure.busy }
            let operationID=UUID()
            let request:[String:BoundDebugJSON] = ["action":.string("prepare"),"sessionID":.string(session.sessionID.uuidString.lowercased()),
                "membershipEpoch":.number(Double(session.membershipEpoch)),"operationID":.string(operationID.uuidString.lowercased()),
                "expectedGeneration":.number(Double(session.currentGeneration)),"kind":.string(kind.rawValue),"source":try .wire(source),
                "compatibility":try .wire(context.compatibility),"settings":.string(settings.base64EncodedString())]
            state.operationID=operationID;state.generation=nil;state.membershipEpoch=session.membershipEpoch;state.request=request
            state.descriptor=nil;state.previousManifest=state.manifest ?? state.previousManifest;state.manifest=nil;state.verification=nil;state.phase = .preparing
            try await self.persist(state,context:context,token:run)
            var authenticated=request;authenticated["capability"] = .string(capability)
            try self.accept(await self.raw(authenticated,context:context,token:run),context:context,token:run)
            try await self.drive(context,run);self.startPolling()
        }
    }
    func reload() async {
        guard let manifest else { return }
        let source:BoundDebugSource
        if manifest.source.kind == .current {
            source = .init(kind:.custom,customID:manifest.operationID,sourceGeneration:manifest.generation)
        } else { source=manifest.source }
        await load(source:source,settings:manifest.settings,kind:.reload)
    }
    func saveCustom() async {
        guard let manifest else { return }
        await load(source:.init(kind:.current,sourceGeneration:manifest.generation),settings:manifest.settings,kind:.custom)
    }
    /// A durable pause intent precedes the native boundary. If its readiness
    /// outcome is unknown and no immutable candidate/acknowledgement exists,
    /// reconcile the server before any new-switch preflight can self-reject.
    private func reconcileUncertainBoundary(_ context:BoundDebugHostContext,_ run:UUID) async throws -> Bool {
        guard let state=local,let pending=state.boundaryPending else { return false }
        guard pending==state.operationID else { throw BoundDebugFailure.storage }
        if operation?.operationID != pending {
            let response=try await raw(["action":.string("status"),"sessionID":.string(state.sessionID.uuidString.lowercased()),
                "operationID":.string(pending.uuidString.lowercased())],context:context,token:run,retry:false,timeout:1)
            try accept(response,context:context,token:run)
        }
        guard let pendingOperation=operation,pendingOperation.operationID==pending else { throw BoundDebugFailure.stale }
        if [.aborted,.committed,.ready].contains(pendingOperation.state) { return false }
        if pendingOperation.kind == .custom,let descriptor=state.descriptor,
           let bytes=try await storage.payload(owner:context.session.owner,operation:pending) {
            try check(context,run)
            if BoundDebugPreparedPayload(bytes:bytes,descriptor:descriptor).valid(owner:context.session.owner,operation:pendingOperation) { return false }
        }
        if pendingOperation.kind == .return,pendingOperation.preparedOwners.contains(context.session.owner) { return false }
        guard [.custom,.return].contains(pendingOperation.kind) else { throw BoundDebugFailure.storage }
        do { _=try await invoke("abort",operation:pendingOperation,context:context,run:run,timeout:1) }
        catch {
            let response=try await raw(["action":.string("status"),"sessionID":.string(state.sessionID.uuidString.lowercased()),
                "operationID":.string(pending.uuidString.lowercased())],context:context,token:run,retry:false,timeout:1)
            try accept(response,context:context,token:run)
        }
        guard operation?.operationID==pending,let current=operation,[.aborted,.committed,.ready].contains(current.state) else { throw BoundDebugFailure.timedOut }
        try await drive(context,run)
        return true
    }

    private func drive(_ context:BoundDebugHostContext,_ run:UUID) async throws {
        if try await reconcileUncertainBoundary(context,run) { return }
        guard let operation,let session=serverSession else { status = .waiting;return }
        guard session.joined.contains(context.session.owner) else { status = .waiting;return }
        if operation.state == .aborted {
            try await host?.finishDebugCapture(operation:operation,captured:false);try check(context,run)
            if activeManifest?.generation==session.currentGeneration { try await restoreActiveBookkeeping(context,run) }
            else {
                guard session.currentGeneration==0,var state=local else { throw BoundDebugFailure.stale }
                state.operationID=nil;state.generation=nil;state.request=nil;state.descriptor=nil;state.manifest=nil
                state.previousManifest=nil;state.verification=nil;state.boundaryPending=nil;state.phase = .invited
                try await persist(state,context:context,token:run)
                host?.setDebugSwitchPending(false);status = .waiting
            }
            return
        }
        if operation.kind == .return { try await driveReturn(operation,context,run);return }
        if operation.state == .committed || operation.state == .ready {
            if operation.kind == .custom { try await finishCustomArchive(operation,context,run) }
            else { try await applyCommitted(context,run) }
            return
        }
        try ensure(operation)
        if operation.kind != .custom || Set(operation.capturedOwners ?? []) != Set(session.owners) {
            host?.setDebugSwitchPending(true);host?.setDebugAdmission(nil)
        }
        status = .preparing
        if operation.deadline<=clock() {
            _=try await invoke("abort",operation:operation,context:context,run:run)
            try await drive(context,run);return
        }
        if !operation.preparedOwners.contains(context.session.owner) {
            do { try await prepareOwn(operation,context,run) }
            catch BoundDebugFailure.busy { status = .waiting;return }
        }
        guard let current=self.operation else { throw BoundDebugFailure.stale }
        try ensure(current)
        if Set(current.preparedOwners)==Set(session.owners),session.controllerID==context.session.owner {
            _=try await invoke("commit",operation:current,context:context,run:run)
            if current.kind == .custom { try await finishCustomArchive(current,context,run) }
            else { try await applyCommitted(context,run) }
        } else { status = .waiting }
    }
    private func prepareOwn(_ initial:BoundDebugOperation,_ context:BoundDebugHostContext,_ run:UUID) async throws {
        guard let host else { throw BoundDebugFailure.unavailable }
        var state=local ?? .init(ownerID:context.session.owner,roomID:context.roomID,deviceID:context.deviceID,sessionID:initial.sessionID)
        if state.operationID != initial.operationID {
            guard (state.generation ?? 0)<initial.generation else { throw BoundDebugFailure.stale }
            state.operationID=initial.operationID;state.generation=initial.generation;state.membershipEpoch=initial.membershipEpoch
            state.request=nil;state.descriptor=nil;state.previousManifest=state.manifest ?? state.previousManifest;state.manifest=nil;state.verification=nil;state.phase = .preparing
        }
        if state.generation==nil { state.generation=initial.generation }
        try await persist(state,context:context,token:run)
        let payload:BoundDebugPreparedPayload
        if let descriptor=state.descriptor,let stored=try await storage.payload(owner:context.session.owner,operation:initial.operationID) {
            try check(context,run);payload = .init(bytes:stored,descriptor:descriptor)
            if initial.kind == .custom {
                try await completeCustomCapture(initial,payload,context,run)
                try await host.finishDebugCapture(operation:initial,captured:true);try check(context,run)
                state.boundaryPending=nil;try await persist(state,context:context,token:run)
            }
        } else {
            let terminalSource=try await preflightSwitch(allowTerminal:initial.kind != .custom,context,run)
            let settled:BoundDebugBookmark
            if let terminalSource { settled=terminalSource.bookmark }
            else { settled=try await host.settleForDebugSwitch() }
            try check(context,run);try ensure(initial)
            guard settled.valid(owner:context.session.owner) else { throw BoundDebugFailure.invalidResponse }
            state.bookmark=state.bookmark ?? settled
            try await persist(state,context:context,token:run)
            var capture=initial,holdingCut=false
            do {
                if initial.source.kind == .custom {
                    payload=try await immutableCustomSource(initial,context,run)
                } else {
                if initial.kind == .custom {
                    state.boundaryPending=initial.operationID;try await persist(state,context:context,token:run)
                    holdingCut=true
                    let readiness=try await host.rendezvousDebugCapture(operation:initial)
                    try check(context,run);try ensure(initial);guard readiness.valid else { throw BoundDebugFailure.invalidResponse }
                    let until=clock()+2
                    let extra=try BoundDebugJSON.wire(readiness).object!
                    _=try await invoke("captureReady",operation:initial,extra:extra,context:context,run:run,timeout:1)
                    while self.operation?.cut==nil,clock()<until {
                        try await sleep(0.2);try check(context,run)
                        _=try await invoke("status",extra:["operationID":.string(initial.operationID.uuidString.lowercased())],
                            capabilityRequired:false,context:context,run:run,timeout:max(0.05,min(0.5,until-clock())))
                        try ensure(initial)
                    }
                    guard clock()<=until,let current=self.operation,current.cut != nil else { throw BoundDebugFailure.timedOut };capture=current
                }
                payload=try await host.prepareDebugPayload(operation:capture,cut:capture.cut,bookmark:state.bookmark!)
                }
                try check(context,run);try ensure(initial)
                guard payload.valid(owner:context.session.owner,operation:capture),payload.descriptor.deviceID==context.deviceID,
                      payload.descriptor.bookmark==state.bookmark else { throw BoundDebugFailure.invalidResponse }
                try await storage.savePayload(payload.bytes,owner:context.session.owner,operation:initial.operationID);try check(context,run)
                state.descriptor=payload.descriptor;try await persist(state,context:context,token:run)
                if holdingCut {
                    try await completeCustomCapture(capture,payload,context,run)
                    try await host.finishDebugCapture(operation:capture,captured:true);try check(context,run);holdingCut=false
                    state.boundaryPending=nil;try await persist(state,context:context,token:run)
                }
            } catch {
                if holdingCut {
                    // Abort must be reconciled before the host decides whether
                    // its ordinary capture pause may be released.
                    _=try? await invoke("abort",operation:initial,context:context,run:run,timeout:1)
                    if token==run,self.operation?.operationID==initial.operationID,self.operation?.state == .aborted {
                        try? await host.finishDebugCapture(operation:initial,captured:false)
                    }
                }
                throw error
            }
        }
        guard let current=self.operation,payload.valid(owner:context.session.owner,operation:current) else { throw BoundDebugFailure.invalidResponse }
        _=try await invoke("ownerPrepare",operation:current,extra:["descriptor":try .wire(payload.descriptor)],context:context,run:run)
        let encoded=Data(payload.bytes.base64EncodedString().utf8)
        for index in 0..<payload.descriptor.count {
            try check(context,run);try ensure(current)
            let chunk=String(decoding:encoded[(index*12_000)..<min(encoded.count,(index+1)*12_000)],as:UTF8.self)
            _=try await invoke("chunk",operation:current,extra:["index":.number(Double(index)),"data":.string(chunk)],context:context,run:run)
        }
        _=try await invoke("seal",operation:current,context:context,run:run)
        guard self.operation?.preparedOwners.contains(context.session.owner)==true else { throw BoundDebugFailure.invalidResponse }
        state.phase = .sealed;state.generation=current.generation;try await persist(state,context:context,token:run)
    }

    private func completeCustomCapture(_ operation:BoundDebugOperation,_ payload:BoundDebugPreparedPayload,_ context:BoundDebugHostContext,_ run:UUID) async throws {
        _=try await invoke("ownerPrepare",operation:operation,extra:["descriptor":try .wire(payload.descriptor)],context:context,run:run,timeout:1)
        let until=clock()+2
        while true {
            try check(context,run);try ensure(operation)
            do {
                _=try await invoke("captureComplete",operation:operation,extra:["payloadSHA256":.string(payload.descriptor.receipt.payloadSHA256),
                    "cutDigest":.string(payload.descriptor.cutDigest ?? "")],context:context,run:run,timeout:max(0.05,min(0.5,until-clock())))
                guard self.operation?.capturedOwners?.contains(context.session.owner)==true else { throw BoundDebugFailure.invalidResponse }
                return
            } catch BoundDebugFailure.busy where clock()<until {
                try await sleep(0.1)
            }
            if clock()>=until { throw BoundDebugFailure.timedOut }
        }
    }
    private func finishCustomArchive(_ archived:BoundDebugOperation,_ context:BoundDebugHostContext,_ run:UUID) async throws {
        guard let custom=manifest,custom.operationID==archived.operationID,custom.generation==archived.generation,
              let active=activeManifest,serverSession?.currentGeneration==active.generation,
              serverSession?.currentManifestDigest==active.digest else { throw BoundDebugFailure.stale }
        if local?.boundaryPending==archived.operationID {
            guard self.operation?.capturedOwners?.contains(context.session.owner)==true,let host else { throw BoundDebugFailure.stale }
            try await host.finishDebugCapture(operation:archived,captured:true);try check(context,run)
        }
        let capture=BoundDebugCapture(operation:self.operation ?? archived,manifest:custom)
        captures.removeAll { $0.id==capture.id };captures.append(capture);captures.sort { $0.operation.generation>$1.operation.generation }
        try await restoreActiveBookkeeping(context,run)
    }
    private func restoreActiveBookkeeping(_ context:BoundDebugHostContext,_ run:UUID) async throws {
        guard let active=activeManifest,serverSession?.currentGeneration==active.generation,
              serverSession?.currentManifestDigest==active.digest,var state=local else { throw BoundDebugFailure.stale }
        // Restore only client bookkeeping to the still-running generation. A
        // fresh process recovers its latest authoritative head, never the cut.
        let response=try await raw(["action":.string("status"),"sessionID":.string(active.sessionID.uuidString.lowercased()),
            "operationID":.string(active.operationID.uuidString.lowercased())],context:context,token:run)
        try accept(response,context:context,token:run)
        guard manifest?.digest==active.digest,let installedOperation=operation,
              let descriptor=active.owners[context.session.owner.uuidString.lowercased()],let host else { throw BoundDebugFailure.stale }
        if let proof=try await terminalProof(for:active,context,run) {
            try await retainTerminal(proof,manifest:active,operation:installedOperation,state:state,context,run);return
        }
        let recoveredInstallation=completedRestoreGeneration==nil
        let proof:BoundDebugVerification
        if recoveredInstallation { proof=try await host.recoverDebugInstallation(manifest:active) }
        else { proof=try await host.verifyDebugRestore(manifest:active) }
        try check(context,run)
        guard proof.valid(descriptor:descriptor) else { throw BoundDebugFailure.nativeVerification }
        state.operationID=active.operationID;state.generation=active.generation;state.request=nil;state.manifest=active;state.previousManifest=nil
        state.descriptor=descriptor;state.verification=proof;state.boundaryPending=nil;state.phase = .verified
        state.installedIdentity=installedOperation.identities[context.session.owner.uuidString.lowercased()]
        try await persist(state,context:context,token:run)
        if recoveredInstallation {
            try await host.completeDebugRestore(manifest:active);try check(context,run)
            completedRestoreGeneration=active.generation
        }
        host.setDebugSwitchPending(false)
        try await applyCommitted(context,run)
    }
    func refreshCaptures() async {
        await work { context,run in
            guard let session=self.serverSession else { return }
            let response=try await self.raw(["action":.string("captures"),"sessionID":.string(session.sessionID.uuidString.lowercased())],context:context,token:run)
            guard let values=response["captures"]?.array,values.count<=100 else { throw BoundDebugFailure.invalidResponse }
            let captures=try values.map { value -> BoundDebugCapture in
                let capture=try value.decode(BoundDebugCapture.self)
                guard capture.operation.kind == .custom,capture.operation.valid(session:session),[.committed,.ready].contains(capture.operation.state),
                      capture.manifest.valid(operation:capture.operation,session:session),var raw=value["manifest"]?.object else { throw BoundDebugFailure.invalidResponse }
                raw.removeValue(forKey:"digest")
                guard try BoundDebugJSON.digest(BoundDebugJSON.object(raw).data())==capture.manifest.digest else { throw BoundDebugFailure.invalidResponse }
                return capture
            }
            guard Set(captures.map(\.id)).count==captures.count else { throw BoundDebugFailure.invalidResponse }
            self.captures=captures.sorted { $0.operation.generation>$1.operation.generation }
        }
    }
    func reloadCustom(_ capture:BoundDebugCapture) async {
        guard captures.contains(capture) else { failed(BoundDebugFailure.stale);return }
        await load(source:.init(kind:.custom,customID:capture.id,sourceGeneration:capture.operation.generation),settings:capture.manifest.settings,kind:.reload)
    }

    private func applyCommitted(_ context:BoundDebugHostContext,_ run:UUID) async throws {
        guard let operation,let manifest,let host,let session=serverSession,
              [.committed,.ready].contains(operation.state),manifest.generation==session.currentGeneration,
              manifest.digest==session.currentManifestDigest,
              let descriptor=manifest.owners[context.session.owner.uuidString.lowercased()],descriptor.deviceID==context.deviceID else {
            throw BoundDebugFailure.stale
        }
        try ensure(operation)
        var state=local ?? .init(ownerID:context.session.owner,roomID:context.roomID,deviceID:context.deviceID,sessionID:session.sessionID)
        guard (state.generation ?? 0)<=manifest.generation else { throw BoundDebugFailure.stale }
        if let proof=try await terminalProof(for:manifest,context,run) {
            try await retainTerminal(proof,manifest:manifest,operation:operation,state:state,context,run);return
        }
        terminal=nil
        let alreadyVerified=state.phase == .verified && state.manifest?.digest==manifest.digest && state.verification?.valid(descriptor:descriptor)==true
        if alreadyVerified,completedRestoreGeneration==nil {
            activeManifest=manifest;host.setDebugAdmission(nil);status = .loading
            // A durable receipt proves an earlier installation, not that a
            // fresh process has a core. Recover the latest authoritative head
            // in this generation; never silently rewind to its baseline.
            let proof=try await host.recoverDebugInstallation(manifest:manifest);try check(context,run)
            guard proof.valid(descriptor:descriptor) else { throw BoundDebugFailure.nativeVerification }
        }
        if !alreadyVerified {
            host.setDebugContinuation(nil)
            host.setDebugAdmission(nil);status = .loading
            state.operationID=operation.operationID;state.generation=operation.generation;state.membershipEpoch=operation.membershipEpoch
            state.manifest=manifest;state.installedIdentity=operation.identities[context.session.owner.uuidString.lowercased()];state.descriptor=descriptor;state.bookmark=descriptor.bookmark ?? state.bookmark;state.phase = .committed
            try await persist(state,context:context,token:run)
            let start=clock(),bytes=try await download(operation,descriptor,context,run)
            timings["downloadSeconds"]=clock()-start
            let payload=try JSONDecoder().decode(BoundMultiplayerSavePackage.Payload.self,from:bytes)
            guard payload.version==2,payload.manifest.identity==operation.identities[context.session.owner.uuidString.lowercased()],
                  payload.checkpoint==descriptor.receipt.checkpoint,payload.sharedEventDigest==descriptor.historyDigest else { throw BoundDebugFailure.invalidResponse }
            state.phase = .restoring;try await persist(state,context:context,token:run)
            activeManifest=manifest
            let restoreStart=clock();try await host.restoreDebugPayload(bytes,manifest:manifest);try check(context,run)
            timings["restoreSeconds"]=clock()-restoreStart
            let proof=try await host.verifyDebugRestore(manifest:manifest);try check(context,run)
            guard proof.valid(descriptor:descriptor) else { throw BoundDebugFailure.nativeVerification }
            state.verification=proof;state.phase = .verified;try await persist(state,context:context,token:run)
            lastVerified=0;completedRestoreGeneration=nil
        }
        if completedRestoreGeneration != manifest.generation {
            try await host.completeDebugRestore(manifest:manifest);try check(context,run)
            completedRestoreGeneration=manifest.generation
        }
        try ensure(operation)
        if clock()-lastVerified>=10 || own?.verifiedGeneration != operation.generation {
            let proof=try await host.verifyDebugRestore(manifest:manifest);try check(context,run);try ensure(operation)
            guard proof.valid(descriptor:descriptor) else { throw BoundDebugFailure.nativeVerification }
            var extra=try BoundDebugJSON.wire(proof).object!
            extra["manifestDigest"] = .string(manifest.digest)
            _=try await invoke("verify",operation:operation,extra:extra,context:context,run:run)
            guard own?.verifiedGeneration==operation.generation else { throw BoundDebugFailure.invalidResponse }
            lastVerified=clock()
        }
        let response=try await invoke("admission",extra:["generation":.number(Double(operation.generation))],context:context,run:run)
        guard let admission=response["admission"],let allowed=admission["allowed"]?.boolean,
              admission["generation"]?.integer==operation.generation,
              admission["manifestDigest"]?.string==manifest.digest else { throw BoundDebugFailure.invalidResponse }
        host.setDebugContinuation(realtimeScope(for:manifest))
        if allowed {
            guard let expiry=admission["expiresAt"]?.numberValue,expiry>clock(),expiry<=clock()+35,
                  self.operation?.state == .ready,Set(self.operation?.verifiedOwners ?? [])==Set(session.owners) else { throw BoundDebugFailure.invalidResponse }
            host.setDebugSwitchPending(false)
            host.setDebugAdmission(.init(sessionID:session.sessionID,membershipEpoch:session.membershipEpoch,
                generation:operation.generation,manifestDigest:manifest.digest,expiresAt:expiry));status = .ready
        } else { host.setDebugAdmission(nil);status = .waiting }
    }
    private func download(_ operation:BoundDebugOperation,_ descriptor:BoundDebugOwnerDescriptor,_ context:BoundDebugHostContext,_ run:UUID) async throws -> Data {
        var encoded=Data();encoded.reserveCapacity((descriptor.bytes+2)/3*4)
        for index in 0..<descriptor.count {
            let response=try await invoke("download",operation:operation,extra:["index":.number(Double(index))],capabilityRequired:false,context:context,run:run)
            guard let chunk=response["chunk"],chunk["index"]?.integer==index,chunk["count"]?.integer==descriptor.count,
                  chunk["bytes"]?.integer==descriptor.bytes,chunk["payloadSHA256"]?.string==descriptor.receipt.payloadSHA256,
                  let value=chunk["data"]?.string,value.utf8.count==(index==descriptor.count-1 ? ((descriptor.bytes+2)/3*4-index*12_000):12_000),
                  value.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [43,47,61].contains($0) }) else { throw BoundDebugFailure.invalidResponse }
            encoded.append(contentsOf:value.utf8)
        }
        guard let bytes=Data(base64Encoded:encoded),bytes.count==descriptor.bytes,
              BoundDebugJSON.digest(bytes)==descriptor.receipt.payloadSHA256 else { throw BoundDebugFailure.invalidResponse }
        return bytes
    }
    private func immutableCustomSource(_ pending:BoundDebugOperation,_ context:BoundDebugHostContext,_ run:UUID) async throws -> BoundDebugPreparedPayload {
        guard let id=pending.source.customID,let generation=pending.source.sourceGeneration else { throw BoundDebugFailure.invalidResponse }
        let body:[String:BoundDebugJSON] = ["action":.string("status"),"sessionID":.string(pending.sessionID.uuidString.lowercased()),
            "operationID":.string(id.uuidString.lowercased())]
        let response=try await raw(body,context:context,token:run)
        guard let session=serverSession else { throw BoundDebugFailure.stale }
        try validateGameplayEnvelope(response,context:context,sessionID:pending.sessionID,generation:session.currentGeneration)
        guard let sourceJSON=response["operation"],let manifestJSON=response["manifest"] else { throw BoundDebugFailure.invalidResponse }
        let source=try sourceJSON.decode(BoundDebugOperation.self)
        let manifest=try manifestJSON.decode(BoundDebugManifest.self)
        guard source.valid(session:session),source.operationID==id,source.generation==generation,source.kind == .custom,
              [.committed,.ready].contains(source.state),manifest.valid(operation:source,session:session),
              source.runID==pending.runID,source.identities==pending.identities,source.cut==pending.cut,
              var rawManifest=response["manifest"]?.object,
              let publicDescriptor=manifest.owners[context.session.owner.uuidString.lowercased()],
              let own=response["own"],own["ownerID"]?.string.flatMap(UUID.init(uuidString:))==context.session.owner,
              let descriptorJSON=own["descriptor"] else { throw BoundDebugFailure.invalidResponse }
        let descriptor=try descriptorJSON.decode(BoundDebugOwnerDescriptor.self)
        var stripped=descriptor;stripped.bookmark=publicDescriptor.bookmark
        guard stripped==publicDescriptor,descriptor.deviceID==context.deviceID,descriptor.bookmark==local?.bookmark,
              descriptor.valid(owner:context.session.owner,operation:source) else { throw BoundDebugFailure.invalidResponse }
        rawManifest.removeValue(forKey:"digest")
        guard try BoundDebugJSON.digest(BoundDebugJSON.object(rawManifest).data())==manifest.digest else { throw BoundDebugFailure.invalidResponse }
        var encoded=Data();encoded.reserveCapacity((descriptor.bytes+2)/3*4)
        for index in 0..<descriptor.count {
            try ensure(pending)
            let value=try await raw(["action":.string("download"),"sessionID":.string(pending.sessionID.uuidString.lowercased()),
                "operationID":.string(id.uuidString.lowercased()),"generation":.number(Double(generation)),"index":.number(Double(index))],context:context,token:run)
            try validateGameplayEnvelope(value,context:context,sessionID:pending.sessionID,generation:session.currentGeneration)
            guard let chunk=value["chunk"],chunk["index"]?.integer==index,chunk["count"]?.integer==descriptor.count,
                  chunk["bytes"]?.integer==descriptor.bytes,chunk["payloadSHA256"]?.string==descriptor.receipt.payloadSHA256,
                  let data=chunk["data"]?.string,data.utf8.count==(index==descriptor.count-1 ? ((descriptor.bytes+2)/3*4-index*12_000):12_000) else { throw BoundDebugFailure.invalidResponse }
            encoded.append(contentsOf:data.utf8)
        }
        guard let bytes=Data(base64Encoded:encoded),bytes.count==descriptor.bytes,
              BoundDebugJSON.digest(bytes)==descriptor.receipt.payloadSHA256 else { throw BoundDebugFailure.invalidResponse }
        return .init(bytes:bytes,descriptor:descriptor)
    }

    func returnToPreviousRun() async {
        await work { context,run in
            if self.local?.phase == .returned { return }
            guard self.host != nil,let session=self.serverSession,let saved=self.local?.bookmark else { throw BoundDebugFailure.unavailable }
            if session.status == .revoked || self.local?.membershipEnded == true {
                try await self.returnToOrdinary(context,run);return
            }
            if self.operation?.kind == .return,let operation=self.operation { try await self.driveReturn(operation,context,run);return }
            let terminalSource=try await self.preflightSwitch(allowTerminal:true,context,run)
            guard session.controllerID==context.session.owner,let manifest=self.activeManifest,saved.valid(owner:context.session.owner),
                  self.operation?.state == .ready || terminalSource != nil && self.operation?.state == .committed,
                  let capability=self.capability,var state=self.local else { throw BoundDebugFailure.busy }
            self.host?.setDebugSwitchPending(true);self.host?.setDebugAdmission(nil)
            let id=UUID()
            let request:[String:BoundDebugJSON] = ["action":.string("prepare"),"sessionID":.string(session.sessionID.uuidString.lowercased()),
                "membershipEpoch":.number(Double(session.membershipEpoch)),"operationID":.string(id.uuidString.lowercased()),
                "expectedGeneration":.number(Double(session.currentGeneration)),"kind":.string("return"),"source":try .wire(BoundDebugSource(kind:.previous)),
                "compatibility":try .wire(manifest.compatibility),"settings":.string(manifest.settings.base64EncodedString())]
            state.operationID=id;state.generation=nil;state.request=request;state.previousManifest=state.manifest ?? state.previousManifest
            state.phase = .preparing;try await self.persist(state,context:context,token:run)
            var body=request;body["capability"] = .string(capability)
            try self.accept(await self.raw(body,context:context,token:run),context:context,token:run)
            guard let operation=self.operation else { throw BoundDebugFailure.invalidResponse }
            try await self.driveReturn(operation,context,run);self.startPolling()
        }
    }
    private func driveReturn(_ operation:BoundDebugOperation,_ context:BoundDebugHostContext,_ run:UUID) async throws {
        if try await reconcileUncertainBoundary(context,run) { return }
        guard let host,let session=serverSession else { throw BoundDebugFailure.unavailable }
        guard let bookmark=local?.bookmark,operation.identities[context.session.owner.uuidString.lowercased()]==bookmark.identity else { throw BoundDebugFailure.invalidResponse }
        if [.committed,.ready].contains(operation.state) { try await returnToOrdinary(context,run);return }
        try ensure(operation);host.setDebugSwitchPending(true);host.setDebugAdmission(nil)
        if operation.deadline<=clock() {
            _=try await invoke("abort",operation:operation,context:context,run:run)
            try await drive(context,run);return
        }
        var boundaryHeld=operation.preparedOwners.contains(context.session.owner)
        do {
            if !boundaryHeld {
                let terminalSource:TerminalPreparation?
                do { terminalSource=try await preflightSwitch(allowTerminal:true,context,run) }
                catch BoundDebugFailure.busy { status = .waiting;return }
                guard var state=local else { throw BoundDebugFailure.storage }
                if state.operationID != operation.operationID {
                    guard (state.generation ?? 0)<operation.generation else { throw BoundDebugFailure.stale }
                    state.operationID=operation.operationID;state.request=nil;state.previousManifest=state.manifest ?? state.previousManifest
                }
                state.generation=operation.generation;state.membershipEpoch=operation.membershipEpoch;state.phase = .preparing
                state.boundaryPending=operation.operationID;try await persist(state,context:context,token:run)
                boundaryHeld=true
                let readiness:BoundDebugReturnReady
                if let terminalSource {
                    readiness=try await host.debugTerminalReturnReady(operation:operation,proof:terminalSource.proof,
                        manifest:terminalSource.manifest,identity:terminalSource.identity)
                } else { readiness=try await host.debugReturnReady(operation:operation) }
                try check(context,run);try ensure(operation)
                guard readiness.valid,readiness.deviceID==context.deviceID,readiness.terminalProof==terminalSource?.proof else { throw BoundDebugFailure.invalidResponse }
                var extra=try BoundDebugJSON.wire(readiness).object!
                if readiness.terminalProof != nil { extra["sourceCheckpoint"] = .null }
                _=try await invoke("returnReady",operation:operation,extra:extra,context:context,run:run,timeout:1)
            }
            let until=clock()+2
            while clock()<until {
                guard let current=self.operation else { throw BoundDebugFailure.stale }
                if [.committed,.ready].contains(current.state) { try await returnToOrdinary(context,run);return }
                if current.state == .aborted { try await drive(context,run);return }
                if Set(current.preparedOwners)==Set(session.owners),session.controllerID==context.session.owner {
                    _=try await invoke("commit",operation:current,context:context,run:run,timeout:max(0.05,min(1,until-clock())))
                } else {
                    try await sleep(0.1);try check(context,run)
                    _=try await invoke("status",operation:nil,extra:["operationID":.string(operation.operationID.uuidString.lowercased())],
                        capabilityRequired:false,context:context,run:run,timeout:max(0.05,min(0.5,until-clock())))
                }
            }
            throw BoundDebugFailure.timedOut
        } catch {
            guard boundaryHeld else { throw error }
            // Neither a missing buddy nor a lost reply may release a source
            // whose writes are fenced. Reconcile abort/commit before resuming.
            _=try? await invoke("abort",operation:operation,context:context,run:run,timeout:1)
            if token==run,self.operation?.operationID==operation.operationID,self.operation?.state == .aborted {
                try await drive(context,run);return
            }
            let response=try? await raw(["action":.string("status"),"sessionID":.string(operation.sessionID.uuidString.lowercased()),
                "operationID":.string(operation.operationID.uuidString.lowercased())],context:context,token:run,retry:false,timeout:1)
            if let response { try accept(response,context:context,token:run) }
            if self.operation?.operationID==operation.operationID,let current=self.operation {
                if current.state == .aborted { try await drive(context,run);return }
                if [.committed,.ready].contains(current.state) { try await returnToOrdinary(context,run);return }
            }
            throw error
        }
    }
    private func returnToOrdinary(_ context:BoundDebugHostContext,_ run:UUID) async throws {
        guard let host,var state=local else { throw BoundDebugFailure.unavailable }
        host.setDebugAdmission(nil);host.setDebugContinuation(nil);status = .preparing
        let response=try await invoke("return",capabilityRequired:false,context:context,run:run)
        guard let target=response["returnTarget"]?["bookmark"],let saved=state.bookmark else { throw BoundDebugFailure.invalidResponse }
        let bookmark=try target.decode(BoundDebugBookmark.self)
        guard bookmark==saved,bookmark.valid(owner:context.session.owner) else { throw BoundDebugFailure.invalidResponse }
        state.phase = .returning;try await persist(state,context:context,token:run)
        let verified:BoundDebugReturnVerification
        if let installed=completedReturn {
            guard installed.sessionID==state.sessionID,installed.bookmark==bookmark,
                  installed.context.sameAuthority(as:context) else { throw BoundDebugFailure.stale }
            // A lost acknowledgement must not rewind subsequent ordinary play.
            // The host also checks the retained core/run and current confirmed
            // receipt; context alone cannot distinguish another same-ROM run.
            verified=try await host.verifyDebugReturn(bookmark:bookmark,previous:installed.verification)
        } else {
            // A fresh execution recovers the normally validated current head;
            // a durable bookmark never authorizes restoring its historical head.
            verified=try await host.returnFromDebug(bookmark:bookmark)
        }
        try check(context,run)
        guard verified.nativeVerified,verified.deviceID==context.deviceID else { throw BoundDebugFailure.nativeVerification }
        completedReturn = .init(sessionID:state.sessionID,bookmark:bookmark,context:context,verification:verified)
        _=try await invoke("returnVerify",extra:try BoundDebugJSON.wire(verified).object!,capabilityRequired:false,context:context,run:run)
        guard own?.returnVerified==true else { throw BoundDebugFailure.invalidResponse }
        state.boundaryPending=nil;state.phase = .returned;try await persist(state,context:context,token:run)
        polling?.cancel();polling=nil;status = .waiting;completedRestoreGeneration=nil;completedReturn=nil;activeManifest=nil;terminal=nil;host.setDebugAdmission(nil);host.setDebugSwitchPending(false)
    }
    func leave() async { await endMembership(controller:false) }
    func revoke() async { await endMembership(controller:true) }
    private func endMembership(controller:Bool) async {
        host?.setDebugAdmission(nil);host?.setDebugContinuation(nil)
        do {
            let (context,_)=try begin()
            let request=try fields(controller ? "revoke":"leave")
            token=UUID();let run=token;polling?.cancel();polling=nil;isBusy=true
            defer { if token==run { isBusy=false } }
            if var state=local { state.membershipEnded=true;try await persist(state,context:context,token:run) }
            capability=nil;lastVerified=0
            try accept(await raw(request,context:context,token:run),context:context,token:run)
            status = .waiting
        } catch { failed(error) }
    }
    /// Called immediately on feature/account/game changes. The local gate closes
    /// synchronously; best-effort server revocation never grants new authority.
    func availabilityChanged() {
        let previous=context,session=serverSession,capability=self.capability,service=self.service
        invalidateLocalAuthority();status = .waiting
        guard let previous,let session,let capability,session.status != .revoked else { return }
        Task {
            let action=session.controllerID==previous.session.owner ? "revoke":"leave"
            _=try? await service.request(["action":.string(action),"sessionID":.string(session.sessionID.uuidString.lowercased()),
                "membershipEpoch":.number(Double(session.membershipEpoch)),"capability":.string(capability)],session:previous.session)
        }
    }
    func stop() { availabilityChanged() }
    func suspend() {
        token=UUID();polling?.cancel();polling=nil;isBusy=false;capability=nil;lastVerified=0
        host?.setDebugAdmission(nil);host?.setDebugContinuation(nil)
    }
    private var shouldReconcileReturn:Bool {
        local?.phase == .returning && (failure==nil || failure == .busy || failure == .timedOut || failure == .unavailable)
    }
    func startPolling() {
        guard polling==nil,enabled() else { return }
        let run=token
        polling=Task { [weak self] in
            guard let self else { return }
            var failures=0
            while !Task.isCancelled {
                do { try await self.sleep(self.status == .ready || self.status == .ended ? 10:min(10,Double(1 << min(failures,3))));try Task.checkCancellation() }
                catch { break }
                guard run==self.token,self.enabled() else { break }
                if self.local?.phase == .returning,!self.shouldReconcileReturn { break }
                await self.refresh()
                failures=self.failure==nil ? 0:min(failures+1,3)
                // A coordinated Return revokes DEBUG admission before ordinary
                // verification. Keep its bounded retry cadence until that
                // acknowledgement settles, but stop on hard authority failures.
                if self.local?.phase == .returned || self.local?.phase == .returning && !self.shouldReconcileReturn ||
                    self.serverSession?.status == .revoked && !self.shouldReconcileReturn { break }
            }
            if run==self.token { self.host?.setDebugAdmission(nil);self.host?.setDebugContinuation(nil);self.polling=nil }
        }
    }
    func exportReport() throws -> Data {
        // Intentionally built from a fixed allowlist; server errors, capability,
        // access tokens, account email and all native payloads are excluded.
        var report:[String:BoundDebugJSON] = ["version":.number(1),"status":.string(status.rawValue),
            "localValidationOnly":.bool(true),"timings":.object(timings.mapValues { .number($0) })]
        if let session=serverSession {
            report["sessionID"] = .string(session.sessionID.uuidString.lowercased());report["membershipEpoch"] = .number(Double(session.membershipEpoch))
        }
        if let operation {
            report["operationID"] = .string(operation.operationID.uuidString.lowercased());report["generation"] = .number(Double(operation.generation))
            report["operationState"] = .string(operation.state.rawValue);report["compatibility"] = try .wire(operation.compatibility)
            report["source"] = try .wire(operation.source);report["preparedOwners"] = try .wire(operation.preparedOwners)
            report["verifiedOwners"] = try .wire(operation.verifiedOwners)
        }
        if let manifest { report["manifestDigest"] = .string(manifest.digest) }
        if let phase=local?.phase { report["localPhase"] = .string(phase.rawValue) }
        if let failure { report["failureCode"] = .string(failure.rawValue) }
        return try BoundDebugJSON.object(report).data()
    }
    private func realtimeScope(for manifest:BoundDebugManifest) -> BoundDebugRealtimeScope {
        .init(sessionID:manifest.sessionID,membershipEpoch:serverSession?.membershipEpoch ?? manifest.membershipEpoch,
              generation:manifest.generation,manifestDigest:manifest.digest)
    }
    func makeRealtimeConfiguration(scope:BoundDebugRealtimeScope,room:String,session:AppCloudSession) async throws -> BoundNakamaConfiguration {
        let (context,run)=try gameplayScope(sessionID:scope.sessionID,generation:scope.generation,manifestDigest:scope.manifestDigest)
        guard context.session.isSameSession(as:session),UUID(uuidString:room)==context.roomID,
              scope.membershipEpoch==serverSession?.membershipEpoch,let manifest=activeManifest,let host,
              completedRestoreGeneration==scope.generation,let descriptor=manifest.owners[context.session.owner.uuidString.lowercased()] else { throw BoundDebugFailure.stale }
        if clock()-lastRenewed>=20 { try await revalidateGameplay(sessionID:scope.sessionID,generation:scope.generation,manifestDigest:scope.manifestDigest) }
        // Explicit historical verification renews the installed generation while
        // a buddy finishes an admitted activity in a pending next operation.
        if clock()-lastVerified>=10 {
            let proof=try await host.verifyDebugRestore(manifest:manifest);try check(context,run)
            guard proof.valid(descriptor:descriptor) else { throw BoundDebugFailure.nativeVerification }
            var body=try fields("verify");body.merge(try BoundDebugJSON.wire(proof).object!) { _,new in new }
            body["operationID"] = .string(manifest.operationID.uuidString.lowercased());body["generation"] = .number(Double(scope.generation))
            body["manifestDigest"] = .string(manifest.digest)
            let response=try await raw(body,context:context,token:run)
            try validateGameplayEnvelope(response,context:context,sessionID:scope.sessionID,generation:scope.generation)
            guard response["own"]?["verifiedGeneration"]?.integer==scope.generation else { throw BoundDebugFailure.invalidResponse }
            lastVerified=clock()
        }
        var body=try fields("realtime");body["generation"] = .number(Double(scope.generation))
        let value=try await raw(body,context:context,token:run)
        try validateGameplayEnvelope(value,context:context,sessionID:scope.sessionID,generation:scope.generation)
        _=try gameplayScope(sessionID:scope.sessionID,generation:scope.generation,manifestDigest:scope.manifestDigest)
        guard let realtime=value["realtime"] else { throw BoundDebugFailure.invalidResponse }
        let configuration=try BoundNakamaAuthorization.debugConfiguration(realtime,scope:scope,session:session,logicalRoom:context.roomID,now:clock())
        if realtime["activitiesAllowed"]?.boolean==true {
            host.setDebugSwitchPending(false)
            host.setDebugAdmission(.init(sessionID:scope.sessionID,membershipEpoch:scope.membershipEpoch,generation:scope.generation,
                manifestDigest:scope.manifestDigest,expiresAt:configuration.expiresAt))
        } else { host.setDebugAdmission(nil) }
        return configuration
    }
    func makeRunService(identity:BoundMultiplayerRunIdentity,requestTimeout:TimeInterval=10) throws -> BoundNakamaRunService {
        guard requestTimeout.isFinite,requestTimeout>0,requestTimeout<=10 else { throw BoundDebugFailure.invalidResponse }
        let (context,_)=try begin()
        guard let manifest=activeManifest,identity==local?.installedIdentity,identity.run==manifest.runID,identity.owner==context.session.owner,
              identity.romSHA256==manifest.compatibility.romSHA256,identity.gameID==manifest.compatibility.gameID,
              identity.settings==manifest.settings,manifest.owners[identity.owner.uuidString.lowercased()] != nil else { throw BoundDebugFailure.stale }
        let sessionID=manifest.sessionID,generation=manifest.generation,digest=manifest.digest
        return BoundNakamaRunService(debugIdentity:identity,sessionID:sessionID,generation:generation,
            performDebug:{ [weak self] request in
                guard let self else { throw BoundDebugFailure.stale }
                return try await self.gameplay(request:request,sessionID:sessionID,generation:generation,manifestDigest:digest,timeout:requestTimeout)
            },revalidateDebug:{ [weak self] in
                guard let self else { throw BoundDebugFailure.stale }
                try await self.revalidateGameplay(sessionID:sessionID,generation:generation,manifestDigest:digest,timeout:requestTimeout)
            })
    }
    private func gameplayScope(sessionID:UUID,generation:Int,manifestDigest:String) throws -> (BoundDebugHostContext,UUID) {
        let result=try begin()
        guard activeManifest?.sessionID==sessionID,activeManifest?.generation==generation,activeManifest?.digest==manifestDigest,
              serverSession?.sessionID==sessionID,serverSession?.currentGeneration==generation,serverSession?.status == .active,
              local?.phase != .returned,local?.phase != .returning,local?.membershipEnded != true,capability != nil else { throw BoundDebugFailure.stale }
        return result
    }
    private func validateGameplayEnvelope(_ value:BoundDebugJSON,context:BoundDebugHostContext,sessionID:UUID,generation:Int) throws {
        guard value["version"]?.integer==1,let raw=value["session"] else { throw BoundDebugFailure.invalidResponse }
        let session=try raw.decode(BoundDebugServerSession.self)
        guard session.valid(owner:context.session.owner,room:context.roomID),session.sessionID==sessionID,
              session.currentGeneration==generation,session.membershipEpoch==serverSession?.membershipEpoch,
              session.status == .active,session.joined.contains(context.session.owner) else {
            host?.setDebugAdmission(nil);throw BoundDebugFailure.stale
        }
    }
    private func revalidateGameplay(sessionID:UUID,generation:Int,manifestDigest:String,timeout:TimeInterval=10) async throws {
        let (context,run)=try gameplayScope(sessionID:sessionID,generation:generation,manifestDigest:manifestDigest)
        let value=try await raw(["action":.string("resume"),"sessionID":.string(sessionID.uuidString.lowercased())],context:context,token:run,retry:timeout>=10,timeout:timeout)
        try validateGameplayEnvelope(value,context:context,sessionID:sessionID,generation:generation)
        _=try gameplayScope(sessionID:sessionID,generation:generation,manifestDigest:manifestDigest)
        guard let next=value["capability"]?.string,!next.isEmpty,next.utf8.count<=8192 else { throw BoundDebugFailure.revoked }
        capability=next;lastRenewed=clock()
    }
    func gameplay(request:[String:BoundDebugJSON]) async throws -> Data {
        guard let manifest=activeManifest else { throw BoundDebugFailure.stale }
        return try await gameplay(request:request,sessionID:manifest.sessionID,generation:manifest.generation,manifestDigest:manifest.digest)
    }
    private func gameplay(request:[String:BoundDebugJSON],sessionID:UUID,generation:Int,manifestDigest:String,timeout:TimeInterval=10) async throws -> Data {
        let (context,run)=try gameplayScope(sessionID:sessionID,generation:generation,manifestDigest:manifestDigest)
        let allowed:Set<String>=["get","events","save","saveChunk","saveSeal","saveDownload","gameOver","gameOverReturn","gameOverMenu","gameOverStatus"]
        guard request["action"]?.string.map(allowed.contains)==true,
              Set(request.keys).isDisjoint(with:["owner","ownerID","runID","save_id","identity","namespace","collection","key","ticket","saveTicket","capability"]) else { throw BoundDebugFailure.rejected }
        var body=try fields("gameplay");body["generation"] = .number(Double(generation));body["request"] = .object(request)
        let response=try await raw(body,context:context,token:run,retry:timeout>=10,timeout:timeout)
        try validateGameplayEnvelope(response,context:context,sessionID:sessionID,generation:generation)
        _=try gameplayScope(sessionID:sessionID,generation:generation,manifestDigest:manifestDigest)
        guard let result=response["gameplay"],result.object != nil else { throw BoundDebugFailure.invalidResponse }
        return try result.data()
    }
    private func raw(_ fields:[String:BoundDebugJSON],context:BoundDebugHostContext,token:UUID,retry:Bool=true,timeout:TimeInterval=10) async throws -> BoundDebugJSON {
        var attempt=0
        while true {
            try check(context,token)
            do { let value=try await service.request(fields,session:context.session,timeout:timeout);try check(context,token);return value }
            catch BoundDebugFailure.timedOut where retry && attempt<2 {
                attempt+=1;try await sleep(0.25*Double(attempt));try check(context,token)
            }
        }
    }
    private func fields(_ action:String,operation:BoundDebugOperation?=nil,capabilityRequired:Bool=true) throws -> [String:BoundDebugJSON] {
        guard let session=serverSession ?? local.map({ state in
            BoundDebugServerSession(sessionID:state.sessionID,roomID:state.roomID,owners:[],controllerID:state.ownerID,
                membershipEpoch:state.membershipEpoch ?? 1,joined:[],status:.invited,currentGeneration:0)
        }) else { throw BoundDebugFailure.unavailable }
        var result:[String:BoundDebugJSON] = ["action":.string(action),"sessionID":.string(session.sessionID.uuidString.lowercased())]
        if capabilityRequired {
            guard session.status != .revoked,let capability,!capability.isEmpty else { throw BoundDebugFailure.revoked }
            result["membershipEpoch"] = .number(Double(session.membershipEpoch));result["capability"] = .string(capability)
        }
        if let operation {
            result["operationID"] = .string(operation.operationID.uuidString.lowercased());result["generation"] = .number(Double(operation.generation))
        }
        return result
    }
    @discardableResult private func accept(_ value:BoundDebugJSON,context:BoundDebugHostContext,token:UUID) throws -> BoundDebugJSON {
        try check(context,token)
        guard value["version"]?.integer==1,let sessionJSON=value["session"] else { throw BoundDebugFailure.invalidResponse }
        let session=try sessionJSON.decode(BoundDebugServerSession.self)
        guard session.valid(owner:context.session.owner,room:context.roomID),local?.sessionID==nil || local?.sessionID==session.sessionID else { throw BoundDebugFailure.invalidResponse }
        let decodedOperation:BoundDebugOperation? = value["operation"] == .null ? nil:try value["operation"]?.decode(BoundDebugOperation.self)
        if let decodedOperation, !decodedOperation.valid(session:session) { throw BoundDebugFailure.invalidResponse }
        let decodedManifest:BoundDebugManifest? = value["manifest"] == .null ? nil:try value["manifest"]?.decode(BoundDebugManifest.self)
        if let decodedManifest {
            guard let decodedOperation,decodedManifest.valid(operation:decodedOperation,session:session),
                  var rawManifest=value["manifest"]?.object else { throw BoundDebugFailure.invalidResponse }
            rawManifest.removeValue(forKey:"digest")
            guard try BoundDebugJSON.digest(BoundDebugJSON.object(rawManifest).data())==decodedManifest.digest else { throw BoundDebugFailure.invalidResponse }
        }
        let owner:BoundDebugOwnerView? = value["own"] == .null ? nil:try value["own"]?.decode(BoundDebugOwnerView.self)
        guard owner?.ownerID==context.session.owner || owner==nil else { throw BoundDebugFailure.invalidResponse }
        if let next=value["capability"]?.string {
            guard !next.isEmpty,next.utf8.count<=8192 else { throw BoundDebugFailure.invalidResponse }
            capability=next;lastRenewed=clock()
        }
        if serverSession?.membershipEpoch != session.membershipEpoch || session.status == .revoked { host?.setDebugAdmission(nil);lastVerified=0 }
        if session.status == .revoked { capability=nil }
        serverSession=session;operation=decodedOperation;manifest=decodedManifest;own=owner
        return value
    }
}
