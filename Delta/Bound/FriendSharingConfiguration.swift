import Foundation
import CoreVideo

struct FriendSharingFailure: Equatable, Sendable {
    enum Kind: String, Sendable {
        case sdkError, connectionLost, connectionFailed, reconnectionTimeout, tokenRequired, tokenExpiring, joinRejected
        case inactive, engineUnavailable, pixelPoolMissing, pixelPoolThreshold
        case pixelAllocation, pixelLock, pixelBaseAddress, invalidFrame, pushRejected
    }
    let kind: Kind
    let code: Int?
    init(_ kind: Kind, code: Int? = nil) { self.kind = kind; self.code = code }
}

/// Server-authorized lobby membership. A new join gets a fresh session even if
/// its small Agora UID is reused, so queued messages cannot target a successor.
struct FriendSharingLobbyMember: Codable, Equatable, Sendable {
    let ownerID: UUID
    let uid: UInt
    let sessionID: UUID
}

struct FriendSharingLobbyRoute: Equatable, Sendable {
    let lobbyID: UUID
    let localUID: UInt
    let members: [FriendSharingLobbyMember]
    var local: FriendSharingLobbyMember? { members.first { $0.uid == localUID } }
    func member(_ uid: UInt) -> FriendSharingLobbyMember? { members.first { $0.uid == uid } }
    var isValid: Bool {
        (1...4).contains(members.count) && local != nil
        && members.allSatisfy { (1...4).contains($0.uid) }
        && Set(members.map(\.uid)).count == members.count
        && Set(members.map(\.ownerID)).count == members.count
        && Set(members.map(\.sessionID)).count == members.count
    }
}

/// RDT's data stream can combine or split writes. Every bounded envelope is
/// addressed to one membership incarnation; UID authentication comes from RTC.
struct FriendSharingLobbyEnvelope {
    static let prefix = Data("BGL1".utf8)
    static let headerSize = 54
    static let maximumBytes = headerSize + 1024
    let lobbyID: UUID
    let senderSession: UUID
    let receiverSession: UUID
    let payload: Data
    func encoded() -> Data? {
        guard !payload.isEmpty, payload.count <= 1024 else { return nil }
        let count = UInt16(Self.headerSize + payload.count)
        var data = Self.prefix + Data([UInt8(count & 255), UInt8(count >> 8)])
        for id in [lobbyID, senderSession, receiverSession] {
            var bytes = id.uuid
            withUnsafeBytes(of: &bytes) { data.append(contentsOf: $0) }
        }
        data.append(payload); return data
    }
    static func decode(_ data: Data, from uid: UInt, route: FriendSharingLobbyRoute) -> Data? {
        guard route.isValid, uid != route.localUID, let sender = route.member(uid), let receiver = route.local,
              data.count > headerSize, data.count <= maximumBytes, data.starts(with: prefix),
              (Int(data[4]) | (Int(data[5]) << 8)) == data.count else { return nil }
        let expected = Self(lobbyID: route.lobbyID, senderSession: sender.sessionID,
                            receiverSession: receiver.sessionID, payload: Data(data.dropFirst(headerSize)))
        guard expected.encoded() == data else { return nil }
        return expected.payload
    }
}

struct FriendSharingLobbyFramer {
    private var pending = Data()
    mutating func consume(_ data: Data) -> [Data]? {
        guard !data.isEmpty, data.count <= 65536, pending.count + data.count <= 66560 else { pending.removeAll(); return nil }
        pending.append(data)
        var messages: [Data] = []
        while pending.count >= 6 {
            guard pending.starts(with: FriendSharingLobbyEnvelope.prefix) else { pending.removeAll(); return nil }
            let size = Int(pending[4]) | Int(pending[5]) << 8
            guard size > FriendSharingLobbyEnvelope.headerSize, size <= FriendSharingLobbyEnvelope.maximumBytes else { pending.removeAll(); return nil }
            guard pending.count >= size else { break }
            messages.append(Data(pending.prefix(size)))
            pending = Data(pending.dropFirst(size))
        }
        return messages
    }
}

struct FriendSharingConfiguration: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable, Decodable {
    let appID: String
    let channel: String
    let uid: UInt
    let remoteUID: UInt
    let token: String
    let lobbyID: UUID?
    let members: [FriendSharingLobbyMember]?
    init(appID: String, channel: String, uid: UInt, remoteUID: UInt, token: String,
         lobbyID: UUID? = nil, members: [FriendSharingLobbyMember]? = nil) {
        self.appID = appID; self.channel = channel; self.uid = uid; self.remoteUID = remoteUID; self.token = token
        self.lobbyID = lobbyID; self.members = members
    }
    var lobbyRoute: FriendSharingLobbyRoute? {
        guard let lobbyID, let members else { return nil }
        return .init(lobbyID: lobbyID, localUID: uid, members: members)
    }

    var description: String { "FriendSharingConfiguration(redacted)" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["credential": "redacted"]) }

    var isValid: Bool {
        appID.count == 32 && appID.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
        && !channel.isEmpty && channel.utf8.count <= 64
        && !channel.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        && uid > 0 && uid <= UInt(UInt32.max) && remoteUID <= UInt(UInt32.max)
        && uid != remoteUID && !token.isEmpty && token.utf8.count <= 8192
        && (lobbyID == nil ? members == nil && remoteUID > 0 : lobbyRoute?.isValid == true
            && (remoteUID == 0 || lobbyRoute?.member(remoteUID) != nil))
    }

    static var authenticationRequested: Bool {
        #if DEBUG && targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains("--friend-sharing-auth")
        #else
        true
        #endif
    }
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FriendSharing", isDirectory: true)
    }

    static func load(arguments: [String] = ProcessInfo.processInfo.arguments,
                     directory: URL = Self.directory) -> Self? {
        #if DEBUG && targetEnvironment(simulator)
        guard arguments.contains("--friend-sharing-test"),
              let data = try? Data(contentsOf: directory.appendingPathComponent("config.json")),
              data.count <= 16384,
              let value = try? JSONDecoder().decode(Self.self, from: data), value.isValid else { return nil }
        return value
        #else
        return nil
        #endif
    }
}

enum FriendSharingPixels {
    // Unit-fixture generator only. Configured playback publishes actual detached
    // GameFrame pixels and never calls this synthetic calibration helper.
    static func rgba(sequence: UInt64, uid: UInt) -> Data {
        var bytes = [UInt8](repeating: 255, count: SharingFrame.byteCount)
        let left = Int(sequence % 208)
        let top = 40 + Int(uid % 3) * 32
        for y in 0..<160 {
            for x in 0..<240 {
                let i = (y * 240 + x) * 4
                let stripe = x / 80
                bytes[i] = stripe == 0 ? 220 : 24
                bytes[i + 1] = stripe == 1 ? 220 : 24
                bytes[i + 2] = stripe == 2 ? 220 : 24
                if y < 12 {
                    let bit = UInt(x * 32 / 240)
                    let shade: UInt8 = (uid >> bit) & 1 == 0 ? 48 : 240
                    bytes[i] = shade; bytes[i + 1] = shade; bytes[i + 2] = shade
                }
                if x >= left && x < left + 32 && y >= top && y < top + 24 {
                    bytes[i] = 255
                    bytes[i + 1] = uid % 2 == 0 ? 255 : 100
                    bytes[i + 2] = uid % 2 == 0 ? 255 : 0
                }
            }
        }
        return Data(bytes)
    }

    // Copies only the supported detached RTC I420 image while the SDK callback
    // owns its planes. BT.601 limited-range conversion; no borrowed pointer escapes.
    static func rgbaFromI420(width: Int, height: Int, yStride: Int, uStride: Int, vStride: Int,
                             y: UnsafePointer<UInt8>, u: UnsafePointer<UInt8>, v: UnsafePointer<UInt8>) -> Data? {
        guard width == 240, height == 160, yStride >= 240, uStride >= 120, vStride >= 120,
              yStride <= 4096, uStride <= 4096, vStride <= 4096 else { return nil }
        var rgba = Data(count: SharingFrame.byteCount)
        rgba.withUnsafeMutableBytes { raw in
            let output = raw.bindMemory(to: UInt8.self).baseAddress!
            // One chroma sample serves a 2x2 block. Keep the existing integer
            // BT.601 rounding exactly, without Array allocation or Data subscripts.
            for row in stride(from: 0, to: 160, by: 2) {
                let uRow = u + (row / 2) * uStride
                let vRow = v + (row / 2) * vStride
                for column in stride(from: 0, to: 240, by: 2) {
                    let blue = Int(uRow[column / 2]) - 128
                    let red = Int(vRow[column / 2]) - 128
                    let r = 409 * red + 128
                    let g = -100 * blue - 208 * red + 128
                    let b = 516 * blue + 128
                    for dy in 0..<2 {
                        let source = y + (row + dy) * yStride + column
                        let target = output + ((row + dy) * 240 + column) * 4
                        for dx in 0..<2 {
                            let luminance = 298 * max(0, Int(source[dx]) - 16)
                            target[dx * 4] = UInt8(clamping: (luminance + r) >> 8)
                            target[dx * 4 + 1] = UInt8(clamping: (luminance + g) >> 8)
                            target[dx * 4 + 2] = UInt8(clamping: (luminance + b) >> 8)
                            target[dx * 4 + 3] = 255
                        }
                    }
                }
            }
        }
        return rgba
    }

    static func bgraBuffer(_ frame: SharingFrame, pool: CVPixelBufferPool? = nil,
                           failure: ((FriendSharingFailure) -> Void)? = nil) -> CVPixelBuffer? {
        guard frame.rgba8.count == SharingFrame.byteCount else { failure?(.init(.invalidFrame)); return nil }
        var buffer: CVPixelBuffer?
        let result: CVReturn
        if let pool {
            result = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool,
                [kCVPixelBufferPoolAllocationThresholdKey: 3] as CFDictionary, &buffer)
        } else {
            result = CVPixelBufferCreate(kCFAllocatorDefault, 240, 160, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        }
        guard result == kCVReturnSuccess, let buffer else {
            failure?(.init(result == kCVReturnWouldExceedAllocationThreshold ? .pixelPoolThreshold : .pixelAllocation, code: Int(result)))
            return nil
        }
        guard CVPixelBufferGetWidth(buffer) == 240, CVPixelBufferGetHeight(buffer) == 160,
              CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetBytesPerRow(buffer) >= 240 * 4 else { failure?(.init(.invalidFrame)); return nil }
        let lockResult = CVPixelBufferLockBaseAddress(buffer, [])
        guard lockResult == kCVReturnSuccess else { failure?(.init(.pixelLock, code: Int(lockResult))); return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { failure?(.init(.pixelBaseAddress)); return nil }
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        frame.rgba8.withUnsafeBytes { raw in
            let pixels = raw.bindMemory(to: UInt8.self).baseAddress!
            for y in 0..<160 {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
                let source = pixels + y * 240 * 4
                for x in 0..<240 {
                    let offset = x * 4
                    row[offset] = source[offset + 2]
                    row[offset + 1] = source[offset + 1]
                    row[offset + 2] = source[offset]
                    row[offset + 3] = source[offset + 3]
                }
            }
        }
        return buffer
    }
}
