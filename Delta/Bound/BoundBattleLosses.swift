import Foundation
import SwiftUI
import UIKit

/// Presentation history only. The Soul Link ledger remains the authority for
/// ownership and permanent losses; this journal never creates a loss.
struct BoundBattleLossNotice: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let slots: [String]
    let completedAt: Date
    var announced = false
    var valid: Bool {
        !slots.isEmpty && slots.count <= 6 && slots.allSatisfy(BoundSoulLedger.validSlot)
        && Set(slots).count == slots.count && completedAt.timeIntervalSince1970.isFinite
    }
}

struct BoundBattleLossJournal: Codable, Equatable, Sendable {
    struct Battle: Codable, Equatable, Sendable {
        let id: UUID
        let baseline: Set<String>
        var slots: Set<String>
        var excluded: Bool
    }
    enum Error: Swift.Error { case corrupt }
    var battle: Battle?
    var notices: [BoundBattleLossNotice] = []
    var pending: BoundBattleLossNotice? { notices.first { !$0.announced } }
    private var recorded: Set<String> { Set(notices.flatMap(\.slots)) }
    var valid: Bool {
        guard notices.count <= 6400, notices.allSatisfy(\.valid), Set(notices.map(\.id)).count == notices.count,
              recorded.count == notices.reduce(0, { $0 + $1.slots.count }), recorded.count <= 6400 else { return false }
        guard let battle else { return true }
        return battle.baseline.count <= 6400 && battle.slots.count <= 6
            && battle.baseline.allSatisfy(BoundSoulLedger.validSlot) && battle.slots.allSatisfy(BoundSoulLedger.validSlot)
            && battle.baseline.isDisjoint(with: battle.slots)
    }
    /// Call from the durable observation worker with the loss set from before
    /// and after this observation. Eligibility must exclude friendly battles
    /// and borrowed parties for the entire battle, including its entry frame.
    mutating func observe(inBattle: Bool, eligible: Bool, previousDead: Set<String>, dead: Set<String>,
                          at date: Date = Date(), battleID: UUID? = nil) throws {
        guard valid, previousDead.isSubset(of: dead), dead.count <= 6400,
              dead.allSatisfy(BoundSoulLedger.validSlot), date.timeIntervalSince1970.isFinite else { throw Error.corrupt }
        // An observation queue may coalesce the old exit and next entry. The
        // producer's stable battle ID separates their groups without assigning
        // this new observation's losses to the already completed battle.
        if inBattle, let battleID, let finished = battle, finished.id != battleID {
            let slots = finished.slots.intersection(dead).subtracting(recorded)
            if !finished.excluded && !slots.isEmpty {
                notices.append(.init(id: finished.id, slots: ordered(slots), completedAt: date))
            }
            battle = nil
        }
        if inBattle {
            if battle == nil { battle = .init(id: battleID ?? UUID(), baseline: previousDead, slots: [], excluded: !eligible) }
            if var current = battle {
                current.excluded = current.excluded || !eligible
                current.slots.formUnion(dead.subtracting(previousDead))
                battle = current
            }
        } else if let finished = battle {
            battle = nil
            if !finished.excluded && eligible {
                let slots = finished.slots.union(dead.subtracting(previousDead)).intersection(dead).subtracting(recorded)
                if !slots.isEmpty {
                    notices.append(.init(id: finished.id, slots: ordered(slots), completedAt: date))
                }
            }
        }
        guard valid else { throw Error.corrupt }
    }
    /// Completed remote batches are cosmetic evidence. They are accepted only
    /// after the existing authenticated loss channel has made every slot dead.
    /// Peers retry an early batch; receipt cannot itself disable a Pokémon.
    @discardableResult mutating func admit(_ notice: BoundBattleLossNotice, dead: Set<String>) throws -> Bool {
        guard valid, notice.valid else { throw Error.corrupt }
        if notices.contains(where: { $0.id == notice.id }) { return false }
        guard Set(notice.slots).isSubset(of: dead) else { throw Error.corrupt }
        let remaining = Set(notice.slots).subtracting(recorded)
        guard !remaining.isEmpty else { return false }
        notices.append(.init(id: notice.id, slots: ordered(remaining), completedAt: notice.completedAt))
        guard valid else { throw Error.corrupt }
        return true
    }
    mutating func markAnnounced(_ id: UUID) {
        if let index = notices.firstIndex(where: { $0.id == id }) { notices[index].announced = true }
    }
    /// Retain acknowledged notices across an independent checkpoint rollback.
    /// Never resurrect an old in-flight battle from an earlier checkpoint.
    mutating func retain(_ older: Self) throws {
        guard valid, older.valid else { throw Error.corrupt }
        for notice in older.notices {
            if let index = notices.firstIndex(where: { $0.id == notice.id }) {
                let additional = Set(notice.slots).subtracting(recorded)
                notices[index] = .init(id: notice.id, slots: ordered(Set(notices[index].slots).union(additional)),
                                      completedAt: min(notices[index].completedAt, notice.completedAt),
                                      announced: notices[index].announced || notice.announced)
            } else {
                let slots = Set(notice.slots).subtracting(recorded)
                if !slots.isEmpty { notices.append(.init(id: notice.id, slots: ordered(slots), completedAt: notice.completedAt, announced: notice.announced)) }
            }
        }
        guard valid else { throw Error.corrupt }
    }
    private func ordered(_ slots: Set<String>) -> [String] {
        slots.sorted { (BoundSoulLedger.wireIndex($0) ?? Int.max) < (BoundSoulLedger.wireIndex($1) ?? Int.max) }
    }
}

/// BLB1 carries completed cosmetic batches. The session separately authenticates
/// the run, fresh challenge epochs and increasing sequence before admission.
struct BoundBattleLossPacket: Sendable {
    static let prefix = Data("BLB1".utf8)
    let run: UUID
    let sender: UUID
    let receiver: UUID
    let sequence: UInt64
    let notice: BoundBattleLossNotice
    static func recognizes(_ data: Data) -> Bool { data.starts(with: prefix) }
    func encoded() -> Data? {
        guard sequence > 0, notice.valid else { return nil }
        var data = Data(repeating: 0, count: 88)
        data.replaceSubrange(0..<4, with: Self.prefix); data[4] = 1; data[5] = UInt8(notice.slots.count)
        func put(_ value: UInt64, at offset: Int) {
            for n in 0..<8 { data[offset+n] = UInt8(truncatingIfNeeded: value >> (8*n)) }
        }
        put(sequence, at: 8)
        for (offset, value) in [(16, run), (32, sender), (48, receiver), (64, notice.id)] {
            var bytes = value.uuid
            withUnsafeBytes(of: &bytes) { data.replaceSubrange(offset..<offset+16, with: $0) }
        }
        put(notice.completedAt.timeIntervalSince1970.bitPattern, at: 80)
        for index in notice.slots.compactMap(BoundSoulLedger.wireIndex).sorted() {
            data.append(UInt8(truncatingIfNeeded: index)); data.append(UInt8(index >> 8))
        }
        return data
    }
    static func decode(_ input: Data) -> Self? {
        guard (90...100).contains(input.count), recognizes(input) else { return nil }
        let data = Data(input), count = Int(data[5])
        guard data[4] == 1, (1...6).contains(count), data.count == 88 + 2*count,
              data[6] == 0, data[7] == 0 else { return nil }
        func number(_ offset: Int) -> UInt64 {
            (0..<8).reduce(0) { $0 | UInt64(data[offset+$1]) << (8*$1) }
        }
        func uuid(_ offset: Int) -> UUID {
            let b = Array(data[offset..<offset+16])
            return UUID(uuid: (b[0],b[1],b[2],b[3],b[4],b[5],b[6],b[7],b[8],b[9],b[10],b[11],b[12],b[13],b[14],b[15]))
        }
        var slots: [String] = [], previous = -1
        for n in 0..<count {
            let index = Int(data[88+2*n]) | Int(data[89+2*n]) << 8
            guard index > previous, let slot = BoundSoulLedger.wireSlot(index) else { return nil }
            slots.append(slot); previous = index
        }
        let notice = BoundBattleLossNotice(id: uuid(64), slots: slots, completedAt: Date(timeIntervalSince1970: Double(bitPattern: number(80))))
        guard number(8) > 0, notice.valid else { return nil }
        return Self(run: uuid(16), sender: uuid(32), receiver: uuid(48), sequence: number(8), notice: notice)
    }
}

/// Each device always renders its own Pokémon on the left. Passing the local
/// ledger's rows also keeps missing partners visibly absent after reconnect.
struct BoundBattleLossGraphic: View {
    let notice: BoundBattleLossNotice
    let rows: [BoundSoulLinks.Row]
    var dismiss: () -> Void
    @State private var dex: BoundRRDexCatalog?
    private let ink = Color(red: 0.13, green: 0.16, blue: 0.22)
    private let paper = Color(red: 0.94, green: 0.95, blue: 0.87)
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("BATTLE LOSSES").tracking(2)
                Spacer()
                Button(action: dismiss) { Text("CLOSE").padding(8) }
                    .accessibilityLabel("Dismiss battle losses")
                    .accessibilityIdentifier("bound.soul-link.battle-loss-dismiss")
            }
            .font(.system(size: 13, weight: .bold, design: .monospaced)).padding(.horizontal, 12).padding(.vertical, 4)
            .foregroundStyle(paper).background(ink)
            HStack { Text("YOU"); Spacer(); Text("PARTNER") }
                .font(.system(size: 11, weight: .bold, design: .monospaced)).padding(.horizontal, 30).padding(.top, 10)
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(rows.filter { notice.slots.contains($0.slot) }, id: \.slot) { row in
                        VStack(spacing: 4) {
                            Text(row.label.uppercased()).font(.system(size: 10, weight: .bold, design: .monospaced)).lineLimit(2)
                            HStack(spacing: 4) {
                                mon(row.own, caught: row.ownCaught, fallback: "Your Pokémon")
                                brokenLink.frame(width: 34, height: 28).accessibilityHidden(true)
                                mon(row.partner, caught: row.partnerCaught, fallback: row.partnerNameFallback ?? "Partner’s Pokémon")
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(row.label + ". " + (row.own?.name ?? "Your Pokémon") + ", " + (row.partner?.name ?? row.partnerNameFallback ?? "Partner’s Pokémon") + ". Lost.")
                    }
                }.padding(12)
            }.frame(maxHeight: 280)
            Text("LINKED PAIRS LOST").font(.system(size: 10, weight: .bold, design: .monospaced))
                .padding(8).frame(maxWidth: .infinity).foregroundStyle(paper).background(ink)
        }
        .foregroundStyle(ink).background(paper)
        .overlay { Rectangle().strokeBorder(ink, lineWidth: 4) }
        .overlay { Rectangle().strokeBorder(paper, lineWidth: 1).padding(4).allowsHitTesting(false) }
        .accessibilityIdentifier("bound.soul-link.battle-losses")
        .task { dex = await Task.detached(priority: .utility) { BoundRRDexCatalog.bundled }.value }
    }
    private func mon(_ value: BoundSoulLinkPresentation?, caught: Bool, fallback: String) -> some View {
        VStack(spacing: 4) {
            if caught, let value, !value.isEgg, let sprite = dex?.pokemon(id: value.species)?.sprite,
               let bytes = Data(base64Encoded: sprite), let image = UIImage(data: bytes) {
                Image(uiImage: image).resizable().interpolation(.none).scaledToFit().frame(width: 64, height: 56).saturation(0)
            } else {
                Text(caught ? (value?.isEgg == true ? "EGG" : "?") : "--")
                    .font(.system(size: 24, weight: .black, design: .monospaced)).frame(width: 64, height: 56)
            }
            Text(caught ? value?.name ?? fallback : "NO CATCH")
                .font(.system(size: 11, weight: .bold, design: .monospaced)).lineLimit(2).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity)
    }
    private var brokenLink: some View {
        Canvas { context, size in
            let red = Color(red: 0.65, green: 0.12, blue: 0.12)
            let origin = CGPoint(x: floor((size.width-21)/2), y: floor((size.height-21)/2))
            for step in 0..<7 {
                for x in [step,6-step] {
                    context.fill(Path(CGRect(x:origin.x+CGFloat(x*3),y:origin.y+CGFloat(step*3),width:3,height:3)),with:.color(red))
                }
            }
        }
    }
}
