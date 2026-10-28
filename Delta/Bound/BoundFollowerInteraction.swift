import Foundation
import SwiftUI

/// Ephemeral cosmetic intent. It cannot express an item, stat, friendship,
/// save, battle or trade mutation. The authenticated transport owns delivery.
struct BoundFollowerInteractionPacket: Equatable, Sendable {
    static let prefix=Data("BFC1".utf8)
    let sender: UUID
    let receiver: UUID
    let id: UUID
    let sequence: UInt64
    let followerID: UInt64
    let generation: UInt32
    let mapInstance: UInt64
    let origin: BoundFriendWorldPosition
    let target: BoundFriendWorldPosition
    private var valid: Bool {
        sender != receiver && sequence>0 && mapInstance>0 && origin.isFacing(target)
        && [origin.x,origin.y,target.x,target.y].allSatisfy { (-7...1030).contains($0) }
    }
    func encoded() -> Data? {
        guard valid else { return nil }
        var data=Data(repeating:0,count:100);data.replaceSubrange(0..<4,with:Self.prefix);data[4]=1
        func put(_ n:UInt64,_ at:Int,_ size:Int) { for i in 0..<size { data[at+i]=UInt8(truncatingIfNeeded:n>>(8*i)) } }
        for (at,uuid) in [(8,sender),(24,receiver),(40,id)] {
            var bytes=uuid.uuid;withUnsafeBytes(of:&bytes) { data.replaceSubrange(at..<at+16,with:$0) }
        }
        put(sequence,56,8);put(followerID,64,8);put(mapInstance,72,8);put(UInt64(generation),80,4)
        for (at,p) in [(84,origin),(92,target)] {
            data[at]=UInt8(p.mapGroup);data[at+1]=UInt8(p.mapNumber);data[at+2]=UInt8(p.elevation);data[at+3]=UInt8(p.facing)
            put(UInt64(UInt16(bitPattern:Int16(p.x))),at+4,2);put(UInt64(UInt16(bitPattern:Int16(p.y))),at+6,2)
        }
        return data
    }
    static func decode(_ input:Data) -> Self? {
        guard input.count==100,input.starts(with:prefix) else { return nil }
        let d=Data(input);guard d[4]==1,d[5]==0,d[6]==0,d[7]==0 else { return nil }
        func n(_ at:Int,_ size:Int)->UInt64 { (0..<size).reduce(0) { $0|UInt64(d[at+$1])<<(8*$1) } }
        func uuid(_ at:Int)->UUID { let b=Array(d[at..<at+16]);return UUID(uuid:(b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15])) }
        func position(_ at:Int)->BoundFriendWorldPosition {
            .init(mapGroup:Int(d[at]),mapNumber:Int(d[at+1]),elevation:Int(d[at+2]),
                x:Int(Int16(bitPattern:UInt16(n(at+4,2)))),y:Int(Int16(bitPattern:UInt16(n(at+6,2)))),facing:Int(d[at+3]))
        }
        let value=Self(sender:uuid(8),receiver:uuid(24),id:uuid(40),sequence:n(56,8),followerID:n(64,8),
            generation:UInt32(n(80,4)),mapInstance:n(72,8),origin:position(84),target:position(92))
        return value.valid ? value:nil
    }
}

/// Smooth presentation only. Actions still validate fresh movement context.
struct BoundLetPassVisibility {
    private(set) var visible = false
    private var lastNearby: TimeInterval = -.infinity
    mutating func update(enabled: Bool, distance: Int?, at now: TimeInterval) -> Bool {
        guard enabled, now.isFinite, now >= lastNearby else { reset(); return false }
        if let distance {
            // Enter at two tiles, leave beyond three; moving samples can
            // alternate between adjacent tiles without blinking the button.
            visible = distance <= (visible ? 3 : 2)
            if visible { lastNearby = now }
        } else if now - lastNearby > 0.5 {
            visible = false
        }
        return visible
    }
    mutating func reset() { visible = false; lastNearby = -.infinity }
}

@MainActor
final class BoundFollowerInteractionSession: ObservableObject {
    struct Context: Equatable {
        let localEpoch: UUID
        let peerEpoch: UUID
        let mapInstance: UInt64
        let actor: BoundFriendWorldPosition
        let target: BoundFriendWorldPosition
        let followerID: UInt64
        let generation: UInt32
        var valid: Bool { localEpoch != peerEpoch && mapInstance>0 && actor.isFacing(target) }
    }
    /// Outbound: actor is this trainer, target is the peer's current follower.
    /// Return nil unless both samples/epochs/map instance are freshly admitted.
    var context: (() -> Context?)?
    /// Inbound: actor is peer trainer, target is our current follower; epochs
    /// still describe this session's local and peer challenges respectively.
    var receiveContext: (() -> Context?)?
    var send: ((Data) -> Bool)?
    var changed: (() -> Void)?
    var onReaction: ((UInt64) -> Void)?
    var letPass: (() -> Void)?
    @Published var canLetPass=false
    private var letPassVisibility = BoundLetPassVisibility()
    func updateLetPass(available: Bool, distance: Int?, at now: TimeInterval) {
        let visible = letPassVisibility.update(enabled: available && BoundLetPassButton.isShown, distance: distance, at: now)
        if canLetPass != visible { canLetPass = visible }
    }
    @Published private(set) var isPresented=false
    @Published private(set) var reaction=""
    private var anchor: Context?
    private var localEpoch: UUID?,peerEpoch: UUID?
    private var sequence: UInt64=0,lastReceived: UInt64=0
    private var recent: [UUID]=[]
    private var reactionTask: Task<Void,Never>?
    var blocksGameplay: Bool { isPresented }
    var canInteract: Bool { BoundMultiplayerFeatures.isEnabled && context?()?.valid==true }
    @discardableResult func open() -> Bool {
        guard canInteract,let value=context?() else { return false }
        anchor=value;isPresented=true;changed?();return true
    }
    func dismiss() { anchor=nil;isPresented=false;changed?() }
    func offerBerry() {
        guard isPresented,let anchor,let now=context?(),now.valid,now==anchor else {
            dismiss();show("That Pokémon moved away.");return
        }
        if localEpoch != now.localEpoch { localEpoch=now.localEpoch;sequence=0 }
        guard sequence<UInt64.max else { dismiss();return };sequence+=1
        let packet=BoundFollowerInteractionPacket(sender:now.localEpoch,receiver:now.peerEpoch,id:UUID(),sequence:sequence,
            followerID:now.followerID,generation:now.generation,mapInstance:now.mapInstance,origin:now.actor,target:now.target)
        dismiss()
        guard let bytes=packet.encoded(),send?(bytes)==true else { show("Friend is unavailable.");return }
        show("♥ A berry for your friend's Pokémon!");onReaction?(now.followerID)
    }
    func receive(_ data:Data) {
        guard BoundMultiplayerFeatures.isEnabled,let packet=BoundFollowerInteractionPacket.decode(data),
              let value=receiveContext?(),value.valid,packet.sender==value.peerEpoch,packet.receiver==value.localEpoch,
              packet.mapInstance==value.mapInstance,packet.followerID==value.followerID,packet.generation==value.generation,
              packet.origin==value.actor,packet.target==value.target else { return }
        if peerEpoch != value.peerEpoch { peerEpoch=value.peerEpoch;lastReceived=0;recent=[] }
        guard packet.sequence>lastReceived else { return };lastReceived=packet.sequence
        guard !recent.contains(packet.id) else { return }
        recent.append(packet.id);if recent.count>64 { recent.removeFirst(recent.count-64) }
        show("♥ Your friend offered a berry!");onReaction?(value.followerID)
    }
    func requestLetPass() { guard canLetPass, BoundLetPassButton.isShown else { return };dismiss();letPass?();show("Letting your friend pass.") }
    func suspend() { dismiss();reactionTask?.cancel();reaction="";canLetPass=false;letPassVisibility.reset() }
    private func show(_ text:String) {
        reactionTask?.cancel();reaction=text;changed?()
        reactionTask=Task { [weak self] in
            try? await Task.sleep(for:.milliseconds(1800));guard !Task.isCancelled else { return }
            self?.reaction="";self?.changed?()
        }
    }
}

struct BoundFollowerInteractionView: View {
    @ObservedObject var session: BoundFollowerInteractionSession
    var body: some View {
        VStack(alignment:.leading,spacing:6) {
            if session.isPresented {
                Text("Your friend's Pokémon")
                Button("Offer berry") { session.offerBerry() }.accessibilityIdentifier("bound.follower-berry")
                Button("Back") { session.dismiss() }.accessibilityIdentifier("bound.follower-dismiss")
            } else if !session.reaction.isEmpty { Text(session.reaction).accessibilityIdentifier("bound.follower-reaction") }
            if session.canLetPass { Button("Let pass") { session.requestLetPass() }.accessibilityIdentifier("bound.friend-let-pass") }
        }
        .font(.system(size:13,weight:.semibold,design:.monospaced))
        .buttonStyle(.plain).foregroundStyle(.black)
        .padding(session.isPresented || !session.reaction.isEmpty || session.canLetPass ? 10:0)
        .background(.white).overlay(Rectangle().stroke(.black,lineWidth:session.isPresented || !session.reaction.isEmpty || session.canLetPass ? 2:0))
        .fixedSize(horizontal:false,vertical:true)
    }
}
