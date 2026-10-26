import Foundation
import CoreFoundation
import CryptoKit

enum BoundDebugFailure: String, Error, Codable, Sendable, LocalizedError {
    case unavailable, signedOut, rejected, invalidResponse, incompatible, busy, stale, revoked, expired, timedOut, storage, nativeVerification
    var errorDescription: String? {
        switch self {
        case .signedOut: return "Sign in again."
        case .incompatible: return "Use the original game and core version."
        case .busy: return "Finish the current activity first."
        case .revoked: return "This DEBUG session ended."
        case .expired: return "Reconnect to this DEBUG session."
        case .stale: return "The session changed. Refresh its status."
        case .timedOut: return "Waiting for the server. Retry to reconcile."
        case .storage: return "Recovery could not be saved. Keep this game open."
        case .nativeVerification: return "The restored state could not be verified."
        default: return "DEBUG is unavailable. Try again."
        }
    }
}

/// Wire JSON is bounded before decoding model values. It is never logged or
/// used as an authority; capabilities and native account sessions stay in memory.
enum BoundDebugJSON: Equatable, Sendable {
    case object([String: Self]), array([Self]), string(String), number(Double), bool(Bool), null

    subscript(_ key: String) -> Self? { if case .object(let value)=self { return value[key] }; return nil }
    var object: [String: Self]? { if case .object(let value)=self { return value };return nil }
    var array: [Self]? { if case .array(let value)=self { return value };return nil }
    var string: String? { if case .string(let value)=self { return value };return nil }
    var integer: Int? {
        guard case .number(let value)=self,value.isFinite,value.rounded()==value,abs(value)<=9_007_199_254_740_991 else { return nil }
        return Int(exactly:value)
    }
    var boolean: Bool? { if case .bool(let value)=self { return value };return nil }
    var numberValue: Double? { if case .number(let value)=self,value.isFinite { return value };return nil }

    init(data: Data, limit: Int = 524_288) throws {
        guard !data.isEmpty,data.count<=limit else { throw BoundDebugFailure.invalidResponse }
        let raw=try JSONSerialization.jsonObject(with:data,options:[.fragmentsAllowed])
        self=try Self.parse(raw,depth:0)
    }
    private static func parse(_ raw: Any, depth: Int) throws -> Self {
        guard depth<=24 else { throw BoundDebugFailure.invalidResponse }
        if raw is NSNull { return .null }
        if let value=raw as? String { return .string(value) }
        if let value=raw as? NSNumber {
            if CFGetTypeID(value)==CFBooleanGetTypeID() { return .bool(value.boolValue) }
            guard value.doubleValue.isFinite else { throw BoundDebugFailure.invalidResponse }
            return .number(value.doubleValue)
        }
        if let value=raw as? [Any] {
            guard value.count<=100_000 else { throw BoundDebugFailure.invalidResponse }
            return .array(try value.map { try parse($0,depth:depth+1) })
        }
        if let value=raw as? [String: Any] {
            guard value.count<=4096,value.keys.allSatisfy({ $0.utf8.count<=256 }) else { throw BoundDebugFailure.invalidResponse }
            return .object(try value.mapValues { try parse($0,depth:depth+1) })
        }
        throw BoundDebugFailure.invalidResponse
    }
    private var foundation: Any {
        switch self {
        case .null:return NSNull()
        case .string(let value):return value
        case .number(let value):return value
        case .bool(let value):return value
        case .array(let value):return value.map(\.foundation)
        case .object(let value):return value.mapValues(\.foundation)
        }
    }
    func data(limit: Int = 524_288) throws -> Data {
        let result=try JSONSerialization.data(withJSONObject:foundation,options:[.sortedKeys,.withoutEscapingSlashes,.fragmentsAllowed])
        guard result.count<=limit else { throw BoundDebugFailure.invalidResponse };return result
    }
    static func encode<T: Encodable>(_ value: T) throws -> Self { try .init(data:JSONEncoder().encode(value)) }
    func decode<T: Decodable>(_ type: T.Type) throws -> T { try JSONDecoder().decode(type,from:data()) }
    static func digest(_ value: Data) -> String { SHA256.hash(data:value).map { String(format:"%02x",$0) }.joined() }
    static func validDigest(_ value: String) -> Bool {
        value.utf8.count==64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

extension BoundDebugJSON: Codable {
    init(from decoder: Decoder) throws {
        let value=try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let result=try? value.decode(Bool.self) { self = .bool(result) }
        else if let result=try? value.decode(String.self) { self = .string(result) }
        else if let result=try? value.decode(Double.self),result.isFinite { self = .number(result) }
        else if let result=try? value.decode([String: Self].self) { self = .object(result) }
        else { self = .array(try value.decode([Self].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var value=encoder.singleValueContainer()
        switch self {
        case .null:try value.encodeNil()
        case .string(let result):try value.encode(result)
        case .number(let result):try value.encode(result)
        case .bool(let result):try value.encode(result)
        case .array(let result):try value.encode(result)
        case .object(let result):try value.encode(result)
        }
    }
}

struct BoundDebugCompatibility: Codable, Equatable, Sendable {
    var romSHA256:String,gameID:String,coreIdentifier:String
    var coreStateVersion:UInt32,saveStateLayout:UInt32
    var ruleset:String
    var protocolVersion=1,saveVersion=1
    init(profile:BoundGameProfile) {
        romSHA256=profile.romSHA256;gameID=profile.gameID;coreIdentifier=profile.coreIdentifier
        coreStateVersion=profile.coreStateVersion;saveStateLayout=profile.saveStateLayout
        ruleset=profile.ruleset.map { String(format:"%02x",$0) }.joined()
    }
    var valid:Bool { self == Self(profile:BoundGameProfiles.current) }
    var known:Bool { BoundGameProfiles.all.contains { self == Self(profile:$0) } }
}

struct BoundDebugCursor: Codable, Equatable, Sendable {
    var origins:[String:BoundSDKEventCursor.Position]=[:]
    init(_ value:BoundSDKEventCursor = .init()) {
        for (key,position) in value.origins { origins[key.lowercased()]=position }
    }
    var sdk:BoundSDKEventCursor { .init(origins:Dictionary(uniqueKeysWithValues:origins.map { (UUID(uuidString:$0.key)?.uuidString ?? $0.key,$0.value) })) }
    var valid:Bool { origins.count<=2 && origins.allSatisfy { UUID(uuidString:$0.key) != nil && $0.key==$0.key.lowercased() && $0.value.valid } }
    func covers(_ value:Self)->Bool { sdk.covers(value.sdk) }
}

struct BoundDebugSource: Codable, Equatable, Sendable {
    enum Kind:String,Codable,Sendable { case builtin,custom,current,previous }
    var kind:Kind
    var pointID:String?=nil,fixtureVersion:String?=nil
    var customID:UUID?=nil,sourceGeneration:Int?=nil
    var valid:Bool {
        switch kind {
        case .builtin:return pointID.flatMap(Int.init).map { (1...15).contains($0) && pointID==String(format:"%02d",$0) }==true
            && fixtureVersion.map { !$0.isEmpty && $0.utf8.count<=128 && $0.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,46,95].contains($0) } }==true && customID==nil && sourceGeneration==nil
        case .custom:return customID != nil && (sourceGeneration ?? 0)>0 && pointID==nil && fixtureVersion==nil
        case .current:return (sourceGeneration ?? 0)>0 && pointID==nil && fixtureVersion==nil && customID==nil
        case .previous:return pointID==nil && fixtureVersion==nil && customID==nil && sourceGeneration==nil
        }
    }
}

struct BoundDebugBookmark: Codable, Equatable, Sendable {
    var identity:BoundMultiplayerRunIdentity
    var checkpoint:UUID?=nil,receipt:BoundMultiplayerCheckpointReceipt?=nil
    var deviceID:UUID,ownershipEpoch:Int,settled:Bool
    func valid(owner:UUID)->Bool {
        identity.valid && identity.owner==owner && ownershipEpoch>0 && settled
        && (checkpoint==nil)==(receipt==nil)
        && (receipt.map { $0.owner==owner && $0.run==identity.run && $0.checkpoint==checkpoint
            && BoundDebugJSON.validDigest($0.payloadSHA256) && BoundDebugJSON.validDigest($0.sharedEventDigest) } ?? true)
    }
}

struct BoundDebugHistoryCut: Codable, Equatable, Sendable {
    var sourceGeneration:Int,sourceRunID:UUID,cursor:BoundDebugCursor,digest:String
    var heads:[String:UUID?]
    var valid:Bool { sourceGeneration>0 && cursor.valid && BoundDebugJSON.validDigest(digest)
        && heads.count==2 && heads.keys.allSatisfy { UUID(uuidString:$0) != nil && $0==$0.lowercased() } }
}

struct BoundDebugOwnerDescriptor: Codable, Equatable, Sendable {
    struct Trainer:Codable,Equatable,Sendable {
        var id:UInt32,name:String,gender:Int
        var valid:Bool { id>0 && (0...1).contains(gender) && (1...7).contains(name.utf8.count)
            && name.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) } }
    }
    struct File:Codable,Equatable,Sendable { var sha256:String,bytes:Int }
    var deviceID:UUID,ownershipEpoch:Int,compatibility:BoundDebugCompatibility,trainer:Trainer
    var receipt:BoundMultiplayerCheckpointReceipt,bytes:Int,count:Int,files:[String:File]
    var historyDigest:String,soulDigest:String,received:BoundDebugCursor,applied:BoundDebugCursor,durable:BoundDebugCursor
    var cutDigest:String?,bookmark:BoundDebugBookmark?,safe:Bool
    func valid(owner:UUID,operation:BoundDebugOperation)->Bool {
        let needed:Set<String>=["game.sav","checkpoint.state","memory-files.json","shared-events.json"]
        // Immutable descriptors retain the exact supported profile admitted
        // with their operation, including recovery after a profile upgrade.
        guard ownershipEpoch>0,compatibility.known,compatibility==operation.compatibility,trainer.valid,
              receipt.owner==owner,receipt.run==operation.runID,BoundDebugJSON.validDigest(receipt.payloadSHA256),
              historyDigest==receipt.sharedEventDigest,BoundDebugJSON.validDigest(historyDigest),BoundDebugJSON.validDigest(soulDigest),
              (1...16_777_216).contains(bytes),count==((bytes+2)/3*4+11_999)/12_000,
              needed.isSubset(of:Set(files.keys)),files.count<=32,
              files.allSatisfy({ key,file in !key.isEmpty && key.utf8.count<=128 && !key.contains("/") && !key.contains("\\")
                  && key != "." && key != ".." && BoundDebugJSON.validDigest(file.sha256) && (0...16_777_216).contains(file.bytes) }),
              received.valid,applied.valid,durable.valid,received.covers(applied),durable.covers(applied),safe,
              bookmark.map({ $0.valid(owner:owner) }) ?? true else { return false }
        if let cut=operation.cut { return cut.valid && cutDigest==cut.digest && applied==cut.cursor && durable.covers(cut.cursor) }
        return cutDigest==nil
    }
}

struct BoundDebugServerSession: Codable, Equatable, Sendable, Identifiable {
    enum Status:String,Codable,Sendable { case invited,active,revoked }
    var sessionID:UUID,roomID:UUID,owners:[UUID],controllerID:UUID,membershipEpoch:Int,joined:[UUID],status:Status
    var currentGeneration:Int
    var activeOperationID:UUID?=nil,currentManifestDigest:String?=nil
    var id:UUID { sessionID }
    func valid(owner:UUID,room:UUID)->Bool {
        roomID==room && owners.count==2 && Set(owners).count==2 && owners.contains(owner) && owners.contains(controllerID)
        && Set(joined).count==joined.count && Set(joined).isSubset(of:Set(owners)) && joined.contains(controllerID)
        && membershipEpoch>0 && currentGeneration>=0 && currentGeneration<=9_007_199_254_740_991
        && (currentManifestDigest.map(BoundDebugJSON.validDigest) ?? true)
    }
}

struct BoundDebugOperation: Codable, Equatable, Sendable {
    enum Kind:String,Codable,Sendable { case load,reload,custom,`return` }
    enum State:String,Codable,Sendable { case preparing,waiting_cut,prepared,committed,ready,aborted }
    var operationID:UUID,sessionID:UUID,membershipEpoch:Int,requestDigest:String,generation:Int,kind:Kind,source:BoundDebugSource,state:State
    var runID:UUID,identities:[String:BoundMultiplayerRunIdentity],compatibility:BoundDebugCompatibility,settings:Data
    var cut:BoundDebugHistoryCut?=nil
    var preparedOwners:[UUID],verifiedOwners:[UUID],deadline:TimeInterval
    var failure:String?=nil
    var capturedOwners:[UUID]?=nil
    private var sourceMatchesKind:Bool {
        switch kind {
        case .load:return source.kind == .builtin
        case .reload:return source.kind == .builtin || source.kind == .custom
        case .custom:return source.kind == .current
        case .return:return source.kind == .previous
        }
    }
    func valid(session:BoundDebugServerSession)->Bool {
        // Authenticated existing operations may use an older supported profile.
        // BoundDebugSession.load still restricts every new preparation to current.
        sourceMatchesKind && sessionID==session.sessionID && membershipEpoch>0 && membershipEpoch<=session.membershipEpoch && generation>0
        && generation<=9_007_199_254_740_991 && BoundDebugJSON.validDigest(requestDigest) && source.valid && compatibility.known && settings.count==32
        && identities.count==2 && Set(identities.keys)==Set(session.owners.map { $0.uuidString.lowercased() })
        && identities.allSatisfy { key,value in value.valid && value.owner.uuidString.lowercased()==key
            && (kind == .return ? source.kind == .previous
                : value.run==runID && value.roomID.lowercased()==session.roomID.uuidString.lowercased()
                  && value.settings==settings && value.romSHA256==compatibility.romSHA256
                  && value.gameID==compatibility.gameID && session.owners.contains(value.partner)) }
        && Set(preparedOwners).isSubset(of:Set(session.owners)) && Set(verifiedOwners).isSubset(of:Set(session.owners))
        && Set(preparedOwners).count==preparedOwners.count && Set(verifiedOwners).count==verifiedOwners.count
        && (capturedOwners.map { Set($0).count==$0.count && Set($0).isSubset(of:Set(session.owners)) } ?? true)
        && deadline.isFinite && deadline>0 && (cut?.valid ?? true) && (failure?.utf8.count ?? 0)<=256
    }
}

struct BoundDebugManifest: Codable, Equatable, Sendable {
    var sessionID:UUID,membershipEpoch:Int,operationID:UUID,generation:Int,runID:UUID,source:BoundDebugSource
    var compatibility:BoundDebugCompatibility,settings:Data,owners:[String:BoundDebugOwnerDescriptor],cut:BoundDebugHistoryCut?,digest:String,committedAt:TimeInterval
    func valid(operation:BoundDebugOperation,session:BoundDebugServerSession)->Bool {
        sessionID==operation.sessionID && operationID==operation.operationID && generation==operation.generation && runID==operation.runID
        && membershipEpoch==operation.membershipEpoch && source==operation.source && compatibility==operation.compatibility
        && settings==operation.settings && cut==operation.cut && BoundDebugJSON.validDigest(digest) && committedAt.isFinite && committedAt>0
        && Set(owners.keys)==Set(session.owners.map { $0.uuidString.lowercased() })
        && owners.allSatisfy { key,value in UUID(uuidString:key).map { value.valid(owner:$0,operation:operation) }==true }
        && Set(owners.values.map { $0.trainer.id }).count==2
    }
}

struct BoundDebugCapture: Codable, Equatable, Sendable, Identifiable {
    var operation:BoundDebugOperation,manifest:BoundDebugManifest
    var id:UUID { operation.operationID }
}

struct BoundDebugOwnerView: Codable, Equatable, Sendable {
    var ownerID:UUID,descriptor:BoundDebugOwnerDescriptor?,bookmark:BoundDebugBookmark?,verifiedGeneration:Int?,liveUntil:TimeInterval,returnVerified:Bool
}

struct BoundDebugPreparedPayload: Sendable {
    var bytes:Data,descriptor:BoundDebugOwnerDescriptor
    func valid(owner:UUID,operation:BoundDebugOperation)->Bool {
        bytes.count==descriptor.bytes && BoundDebugJSON.digest(bytes)==descriptor.receipt.payloadSHA256 && descriptor.valid(owner:owner,operation:operation)
    }
}
struct BoundDebugVerification: Codable, Equatable, Sendable {
    var deviceID:UUID,ownershipEpoch:Int,payloadSHA256:String,checkpoint:UUID,trainerID:UInt32,soulDigest:String,applied:BoundDebugCursor,nativeVerified:Bool
    func valid(descriptor:BoundDebugOwnerDescriptor)->Bool {
        deviceID==descriptor.deviceID && ownershipEpoch==descriptor.ownershipEpoch && payloadSHA256==descriptor.receipt.payloadSHA256
        && checkpoint==descriptor.receipt.checkpoint && trainerID==descriptor.trainer.id && soulDigest==descriptor.soulDigest
        && applied==descriptor.applied && nativeVerified
    }
}
struct BoundDebugCaptureReady: Codable, Equatable, Sendable {
    var sourceCheckpoint:UUID?=nil
    var received:BoundDebugCursor,applied:BoundDebugCursor,durable:BoundDebugCursor
    var valid:Bool { received.valid && applied.valid && durable.valid && received.covers(applied) && durable.covers(applied) }
}
struct BoundDebugReturnReady: Codable, Equatable, Sendable {
    var deviceID:UUID,ownershipEpoch:Int,sourceCheckpoint:UUID?,safe:Bool
    var terminalProof:BoundDebugTerminalProof?=nil
    var valid:Bool { ownershipEpoch>0 && safe && (terminalProof.map {
        sourceCheckpoint==nil && $0.deviceID==deviceID && $0.ownershipEpoch==ownershipEpoch
    } ?? (sourceCheckpoint != nil)) }
}
/// Authenticated metadata for an absorbing loss in one exact DEBUG generation.
/// It grants no native verification, save authority, or permission to resume.
struct BoundDebugTerminalProof: Codable, Equatable, Sendable {
    var sessionID:UUID,membershipEpoch:Int,generation:Int,manifestDigest:String,runID:UUID,eventID:UUID
    var ownerID:UUID,deviceID:UUID,ownershipEpoch:Int
    func valid(manifest:BoundDebugManifest,owner:UUID,device:UUID)->Bool {
        sessionID==manifest.sessionID && membershipEpoch==manifest.membershipEpoch && generation==manifest.generation
        && manifestDigest==manifest.digest && runID==manifest.runID && ownerID==owner && deviceID==device
        && ownershipEpoch>0 && manifest.owners[owner.uuidString.lowercased()]?.deviceID==device
        && manifest.owners[owner.uuidString.lowercased()]?.ownershipEpoch==ownershipEpoch
    }
}
struct BoundDebugReturnVerification: Codable, Equatable, Sendable { var checkpoint:UUID,deviceID:UUID,nativeVerified:Bool }
struct BoundDebugAdmission: Equatable, Sendable {
    var sessionID:UUID,membershipEpoch:Int,generation:Int,manifestDigest:String,expiresAt:TimeInterval
}

struct BoundDebugHostContext: Sendable {
    var session:AppCloudSession,roomID:UUID,deviceID:UUID,authorityGeneration:UUID,compatibility:BoundDebugCompatibility
    func sameAuthority(as other:Self)->Bool {
        session.isSameSession(as:other.session) && roomID==other.roomID && deviceID==other.deviceID
        && authorityGeneration==other.authorityGeneration && compatibility==other.compatibility
    }
}

@MainActor protocol BoundDebugHost: AnyObject {
    func debugContext() throws -> BoundDebugHostContext
    func preflightDebugSwitch() throws
    func debugReturnReady(operation:BoundDebugOperation) async throws -> BoundDebugReturnReady
    func prepareDebugTerminalTransition(proof:BoundDebugTerminalProof,manifest:BoundDebugManifest,identity:BoundMultiplayerRunIdentity) async throws -> BoundDebugBookmark
    func debugTerminalReturnReady(operation:BoundDebugOperation,proof:BoundDebugTerminalProof,manifest:BoundDebugManifest,identity:BoundMultiplayerRunIdentity) async throws -> BoundDebugReturnReady
    func setDebugContinuation(_ scope:BoundDebugRealtimeScope?)
    func setDebugSwitchPending(_ pending:Bool)
    func settleForDebugSwitch() async throws -> BoundDebugBookmark
    func rendezvousDebugCapture(operation:BoundDebugOperation) async throws -> BoundDebugCaptureReady
    func prepareDebugPayload(operation:BoundDebugOperation,cut:BoundDebugHistoryCut?,bookmark:BoundDebugBookmark) async throws -> BoundDebugPreparedPayload
    func restoreDebugPayload(_ payload:Data,manifest:BoundDebugManifest) async throws
    func verifyDebugRestore(manifest:BoundDebugManifest) async throws -> BoundDebugVerification
    func recoverDebugInstallation(manifest:BoundDebugManifest) async throws -> BoundDebugVerification
    func completeDebugRestore(manifest:BoundDebugManifest) async throws
    func finishDebugCapture(operation:BoundDebugOperation,captured:Bool) async throws
    func returnFromDebug(bookmark:BoundDebugBookmark) async throws -> BoundDebugReturnVerification
    /// Validate the retained ordinary installation and its latest confirmed head
    /// without restoring, capturing, pausing or resuming live native execution.
    func verifyDebugReturn(bookmark:BoundDebugBookmark,previous:BoundDebugReturnVerification) async throws -> BoundDebugReturnVerification
    func setDebugAdmission(_ admission:BoundDebugAdmission?)
}

struct BoundDebugLocalState: Codable, Equatable, Sendable {
    enum Phase:String,Codable,Sendable { case invited,preparing,sealed,committed,restoring,verified,returning,returned }
    var version=1
    var ownerID:UUID,roomID:UUID,deviceID:UUID,sessionID:UUID
    var operationID:UUID?=nil,generation:Int?=nil,membershipEpoch:Int?=nil
    var request:[String:BoundDebugJSON]?=nil,bookmark:BoundDebugBookmark?=nil,descriptor:BoundDebugOwnerDescriptor?=nil
    var manifest:BoundDebugManifest?=nil,previousManifest:BoundDebugManifest?=nil,verification:BoundDebugVerification?=nil
    var phase:Phase = .invited
    var boundaryPending:UUID?=nil
    var installedIdentity:BoundMultiplayerRunIdentity?=nil
    var membershipEnded=false
    func valid(owner:UUID,room:UUID,device:UUID)->Bool {
        version==1 && ownerID==owner && roomID==room && deviceID==device && (generation.map { $0>0 } ?? true)
        && (boundaryPending==nil || boundaryPending==operationID)
        && (membershipEpoch.map { $0>0 } ?? true) && (bookmark.map { $0.valid(owner:owner) } ?? true)
        && (request.map { Set($0.keys).isSubset(of:["action","sessionID","membershipEpoch","operationID","expectedGeneration","kind","source","compatibility","settings"]) } ?? true)
    }
}

extension BoundDebugJSON {
    /// Metadata UUID spelling is normalized for this wire contract only. The
    /// encoded native payload is opaque and is never rewritten by the client.
    static func wire<T:Encodable>(_ value:T) throws -> Self { try encode(value).wireUUIDs() }
    private func wireUUIDs() throws -> Self {
        switch self {
        case .string(let value):return .string(UUID(uuidString:value)?.uuidString.lowercased() ?? value)
        case .object(let values):
            var result:[String:Self]=[:]
            for (key,value) in values {
                let normalized=UUID(uuidString:key)?.uuidString.lowercased() ?? key
                guard result[normalized]==nil else { throw BoundDebugFailure.invalidResponse }
                if key=="sparse",let array=value.array,array.allSatisfy({ $0.integer != nil }) {
                    result[normalized] = .array(array.sorted { $0.integer! < $1.integer! })
                } else { result[normalized]=try value.wireUUIDs() }
            }
            return .object(result)
        case .array(let values):return .array(try values.map { try $0.wireUUIDs() })
        default:return self
        }
    }
}
