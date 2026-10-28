import Foundation
import XCTest
@testable import Delta

final class SoulLinksTests: XCTestCase {
    private func ledger() -> BoundSoulLedger { .init(run: UUID(), binding: String(repeating: "a", count: 64)) }
    private func add(_ slot: String, to ledger: inout BoundSoulLedger, id: UInt32, name: String = "Sparky", species: Int = 25, egg: Bool = false) {
        var record = BoundSoulRecord(identity: .init(personality: id, trainer: 42), slot: slot, name: name, eligible: true, pendingHatch: egg)
        record.species = species; record.area = 100
        ledger.records.append(record)
    }
    private func presentation(_ ordinal: Int, name: String = "Buddy", species: Int = 4, egg: Bool = false) -> BoundSoulLinkPresentation {
        .init(species: species, personality: UInt32(ordinal), name: name, area: 101, ordinal: ordinal, isEgg: egg)
    }
    private func packet(_ rows: [BoundSoulLinksPacket.Row], total: Int? = nil, offset: Int = 0, sequence: UInt64 = 1) -> BoundSoulLinksPacket {
        .init(run: UUID(), sender: UUID(), receiver: UUID(), sequence: sequence, offset: offset, total: total ?? rows.count, rows: rows)
    }
    private func word(_ data: Data, _ offset: Int, size: Int = 4) -> UInt32 {
        (0..<size).reduce(0) { $0 | UInt32(data[offset+$1]) << (8*$1) }
    }
    func testLocalCaptureOrderKeepsRouteTwoBeforeRouteOneAndAllCategoriesSeparate() throws {
        var value = ledger()
        let slots = ["area:102", "area:101", "egg:1", "gift:1", "static:1", "area:0"]
        for (index, slot) in slots.enumerated() { add(slot, to: &value, id: UInt32(index+1), egg: slot == "egg:1") }
        value.partnerAcquisitions = ["area:103", "area:104"]
        value.partnerLinks = ["area:104": presentation(2), "area:103": presentation(1)]
        let rows = try XCTUnwrap(BoundSoulLinks.orderedRows(ledger: value, areaNames: [102:"Route 2",101:"Route 1",100:"Pewter City"]))
        XCTAssertEqual(rows.map(\.slot), slots + ["area:103", "area:104"])
        XCTAssertEqual(Array(rows.prefix(2)).map(\.label), ["Route 2", "Route 1"])
        XCTAssertEqual(BoundSoulLinks.localPresentations(ledger: value).map { $0.presentation.ordinal }, [1,2,3,4,5,6])
        XCTAssertEqual(rows[2].label, "Egg 1 - Pewter City"); XCTAssertEqual(rows[3].label, "Gift 1 - Pewter City"); XCTAssertEqual(rows[4].label, "Static 1 - Pewter City")
        XCTAssertEqual(rows[5].label, "Celadon City - Prize")
    }
    func testMetadataNeverAcquiresOrKillsAndAbsentPartnersStayMissing() throws {
        var value = ledger(); add("area:102", to: &value, id: 1)
        value.partnerLinks = ["gift:1": presentation(1)]
        XCTAssertNil(BoundSoulLinks.orderedRows(ledger:value,areaNames:[:]),"Metadata for an unacquired slot is rejected")
        value.partnerLinks = nil
        let rows = try XCTUnwrap(BoundSoulLinks.orderedRows(ledger: value, areaNames: [:]))
        XCTAssertEqual(rows.map(\.slot), ["area:102"])
        XCTAssertTrue(rows[0].ownCaught); XCTAssertFalse(rows[0].partnerCaught); XCTAssertFalse(rows[0].dead)
        let data = try XCTUnwrap(BoundSoulLinks.page(ledger: value, areaNames: [:], offset: 0, sequence: 2, connected: false))
        XCTAssertEqual(word(data,34,size:2),4)
        XCTAssertEqual(word(data,62,size:2),0, "Unknown partner has no invented icon")
        XCTAssertTrue(value.dead.isEmpty)
        let empty = try XCTUnwrap(BoundSoulLinks.page(ledger: nil, areaNames: [:], offset: 99, sequence: 2, connected: false))
        XCTAssertEqual(empty.count,1024); XCTAssertEqual(word(empty,12),0); XCTAssertEqual(word(empty,20),0); XCTAssertEqual(word(empty,16),99)
    }
    func testNativePageUsesExactFlagsNamesSpeciesAndStablePersonalities() throws {
        var value = ledger(); add("egg:1", to: &value, id: 0x12345678, name: "Egg", species: 25, egg: true)
        value.dead = ["egg:1"]; value.partnerAcquisitions = ["egg:1"]
        value.partnerLinks = ["egg:1": presentation(1,name:"Peer Egg",species:0,egg:true)]
        let data = try XCTUnwrap(BoundSoulLinks.page(ledger: value, areaNames: [:], offset: 0, sequence: 4, connected: true))
        XCTAssertEqual(word(data,0),0x314E4C42); XCTAssertEqual(word(data,4,size:2),1); XCTAssertEqual(word(data,6,size:2),0)
        XCTAssertEqual(word(data,8),4); XCTAssertEqual(word(data,12),1); XCTAssertEqual(word(data,20),1); XCTAssertEqual(word(data,24),1)
        XCTAssertEqual(word(data,32,size:2),256); XCTAssertEqual(word(data,34,size:2),1|8|16)
        XCTAssertEqual(word(data,60,size:2),0,"Unhatched species remains hidden behind the egg icon")
        XCTAssertEqual(word(data,64),0x12345678); XCTAssertEqual(word(data,68),1)
        XCTAssertEqual(data.subdata(in:72..<83),BoundSoulLinks.nativeText("Egg",size:11))
        XCTAssertEqual(data.subdata(in:83..<94),BoundSoulLinks.nativeText("Peer Egg",size:11))
        XCTAssertTrue(data[96...].allSatisfy { $0 == 0 },"Unused rows and reserved tail stay zero")
    }
    func testPaginationEchoesStaleOffsetsAndKeepsAcquisitionsAfterReleaseOrRollback() throws {
        var value = ledger()
        for (i, slot) in ["area:102","gift:1","static:1"].enumerated() { add(slot,to:&value,id:UInt32(i+1)) }
        let before = value.records.map(\.slot)
        try value.observe([],registering:true,fainted:[])
        XCTAssertEqual(value.records.map(\.slot),before)
        let page = try XCTUnwrap(BoundSoulLinks.page(ledger:value,areaNames:[:],offset:100,sequence:6,connected:false))
        XCTAssertEqual(word(page,12),3); XCTAssertEqual(word(page,16),100); XCTAssertEqual(word(page,20),0)
        let finalPage = try XCTUnwrap(BoundSoulLinks.page(ledger:value,areaNames:[:],offset:2,sequence:8,connected:false))
        XCTAssertEqual(word(finalPage,32,size:2),4352)
        XCTAssertNil(BoundSoulLinks.page(ledger:value,areaNames:[:],offset:-1,sequence:6,connected:false))
        XCTAssertNil(BoundSoulLinks.page(ledger:value,areaNames:[:],offset:0,sequence:0,connected:false))
        XCTAssertNil(BoundSoulLinks.page(ledger:value,areaNames:[:],offset:0,sequence:3,connected:false))
    }
    func testCosmeticChunksRoundTripWorstCaseNamesAndBoundedOffsets() throws {
        let rows = (1...8).map { BoundSoulLinksPacket.Row(slot:"gift:\($0)",presentation:presentation($0,name:String(repeating:"🐉",count:20))) }
        let value = packet(rows,total:16,offset:8,sequence:UInt64.max)
        let data = try XCTUnwrap(value.encoded()); XCTAssertEqual(data.count,848); XCTAssertLessThanOrEqual(data.count,1024)
        let decoded = try XCTUnwrap(BoundSoulLinksPacket.decode(data))
        XCTAssertEqual(decoded.run,value.run); XCTAssertEqual(decoded.sender,value.sender); XCTAssertEqual(decoded.receiver,value.receiver)
        XCTAssertEqual(decoded.sequence,UInt64.max); XCTAssertEqual(decoded.total,16); XCTAssertEqual(decoded.offset,8); XCTAssertEqual(decoded.rows,rows)
        XCTAssertEqual(BoundSoulLinksPacket.decode(try XCTUnwrap(packet([],total:0).encoded()))?.rows.count,0)
    }
    func testInvalidChunkCannotBecomePresentationEvidence() throws {
        let row = BoundSoulLinksPacket.Row(slot:"gift:1",presentation:presentation(1,name:"A"))
        XCTAssertNil(packet([row,row]).encoded())
        XCTAssertNil(packet([row],total:2049).encoded()); XCTAssertNil(packet([row],total:1,offset:1).encoded())
        XCTAssertNil(packet([row],sequence:0).encoded()); XCTAssertNil(packet([],total:1).encoded())
        XCTAssertNil(packet([.init(slot:"gift:0",presentation:presentation(1))]).encoded())
        XCTAssertNil(packet([.init(slot:"area:001",presentation:presentation(1))]).encoded())
        XCTAssertNil(packet([.init(slot:"gift:1",presentation:presentation(0))]).encoded())
        XCTAssertNil(packet([.init(slot:"gift:1",presentation:presentation(1,species:4096))]).encoded())
        XCTAssertNil(packet([.init(slot:"gift:1",presentation:presentation(1,name:String(repeating:"A",count:21)))]).encoded())
        let bytes = try XCTUnwrap(packet([row]).encoded())
        for length in 0..<bytes.count { XCTAssertNil(BoundSoulLinksPacket.decode(bytes.prefix(length))) }
        var bad = bytes; bad.append(0); XCTAssertNil(BoundSoulLinksPacket.decode(bad))
        bad = bytes; bad[4]=3; XCTAssertNil(BoundSoulLinksPacket.decode(bad))
        bad = bytes; bad[10]=1; XCTAssertNil(BoundSoulLinksPacket.decode(bad))
        bad = bytes; bad[68]=1; XCTAssertNil(BoundSoulLinksPacket.decode(bad))
        bad = bytes; bad[79]=4; XCTAssertNil(BoundSoulLinksPacket.decode(bad))
        bad = bytes; bad[85]=255; XCTAssertNil(BoundSoulLinksPacket.decode(bad))
        bad = bytes; bad[72]=0; bad[73]=25; XCTAssertNil(BoundSoulLinksPacket.decode(bad),"Wire index6400 is outside all categories")
    }
    func testUnionLimitIs4096AndUnknownHistoricalOrderDoesNotInventMetadata() throws {
        var value = ledger()
        for n in 1...2048 { add("gift:\(n)",to:&value,id:UInt32(n)) }
        value.partnerAcquisitions=Set((1...2048).map { "static:\($0)" })
        XCTAssertEqual(BoundSoulLinks.orderedRows(ledger:value,areaNames:[:])?.count,4096)
        value.partnerAcquisitions?.insert("area:100")
        XCTAssertNil(BoundSoulLinks.orderedRows(ledger:value,areaNames:[:]))
        var replay = ledger(); replay.consumedSlots=["gift:1"]
        let row = try XCTUnwrap(BoundSoulLinks.orderedRows(ledger:replay,areaNames:[:])?.first)
        XCTAssertTrue(row.ownCaught); XCTAssertNil(row.own)
    }
    func testNativeTextIsTerminatedBoundedAndHandlesAccentsWithoutControlInjection() {
        XCTAssertEqual(BoundSoulLinks.nativeText("Éon♀",size:6),Data([0x06,0xE3,0xE2,0xB6,255,255]))
        XCTAssertEqual(BoundSoulLinks.decodeNativeText(Data([0x06,0xE3,0xE2,0xB6,255])),"Éon♀")
        let text=BoundSoulLinks.nativeText("AAAAAAAAAAAA",size:11)
        XCTAssertEqual(text.count,11); XCTAssertEqual(text.last,255)
        XCTAssertEqual(BoundSoulLinks.nativeText("\u{0}😀",size:4),Data([0xAC,0xAC,255,255]))
        XCTAssertTrue(BoundSoulLinks.nativeText("X",size:0).isEmpty)
    }
    func testDeathOnlyFactAppearsBeforeCheckpointDependentCatchWithoutInventedMetadata() throws {
        var value=ledger();value.dead=["gift:1"]
        let rows=try XCTUnwrap(BoundSoulLinks.orderedRows(ledger:value,areaNames:[:]))
        XCTAssertEqual(rows.count,1);XCTAssertEqual(rows[0].slot,"gift:1");XCTAssertTrue(rows[0].dead)
        XCTAssertFalse(rows[0].ownCaught);XCTAssertFalse(rows[0].partnerCaught)
        XCTAssertNil(rows[0].own);XCTAssertNil(rows[0].partner)
        let page=try XCTUnwrap(BoundSoulLinks.encodePage(rows:rows,offset:0,sequence:2,connected:true))
        XCTAssertEqual(word(page,34,size:2),1|2|4)
        XCTAssertEqual(word(page,60,size:2),0);XCTAssertEqual(word(page,62,size:2),0)
        XCTAssertEqual(page.subdata(in:72..<83),BoundSoulLinks.nativeText("--",size:11))
        value.partnerAcquisitions=["gift:1"]
        value.partnerLinks=["gift:1":presentation(1,name:"Recovered")]
        let recovered=try XCTUnwrap(BoundSoulLinks.orderedRows(ledger:value,areaNames:[101:"Route 1"])?.first)
        XCTAssertTrue(recovered.dead);XCTAssertTrue(recovered.partnerCaught)
        XCTAssertEqual(recovered.label,"Gift 1 - Route 1");XCTAssertEqual(recovered.partner?.name,"Recovered")
        var full=ledger()
        for n in 1...2048 { add("gift:\(n)",to:&full,id:UInt32(n)) }
        full.partnerAcquisitions=Set((1...2048).map { "static:\($0)" })
        full.dead=["area:100"]
        XCTAssertNil(BoundSoulLinks.orderedRows(ledger:full,areaNames:[:]),"Death-only rows count toward the native4096-row bound")
    }

    func testFullTrainerIdentityAndLegacyMetadataRemainSeparate() throws {
        var info=presentation(1);info.trainerID=0xDEADBEEF
        let row=BoundSoulLinksPacket.Row(slot:"area:100",presentation:info)
        let current=try XCTUnwrap(packet([row]).encoded())
        XCTAssertEqual(BoundSoulLinksPacket.decode(current)?.rows.first?.presentation.trainerID,0xDEADBEEF)
        let legacy=try XCTUnwrap(packet([row]).encoded(legacy:true))
        XCTAssertTrue(legacy.starts(with:Data("BLP1".utf8)))
        XCTAssertNil(BoundSoulLinksPacket.decode(legacy)?.rows.first?.presentation.trainerID)
        XCTAssertEqual(BoundSoulLinksPacket.decode(legacy)?.rows.first?.presentation.personality,info.personality)
    }
    func testHatchedPresentationUsesCurrentIdentityWithoutForgettingOriginal() throws {
        var value=ledger();add("egg:1",to:&value,id:1,egg:true)
        let hatched=BoundSoulMon(identity:.init(personality:1,trainer:99),species:7,name:"Bubbles",area:101,eggOrigin:true,isEgg:false,hp:40)
        try value.observe([hatched],registering:false,fainted:[])
        let shown=try XCTUnwrap(BoundSoulLinks.localPresentations(ledger:value).first)
        XCTAssertEqual(shown.presentation.trainerID,99)
        XCTAssertTrue(value.records[0].identities.contains(.init(personality:1,trainer:42)))
        XCTAssertTrue(value.records[0].identities.contains(hatched.identity))
        value.dead=["egg:1"]
        XCTAssertEqual(value.eliminated.count,2);XCTAssertEqual(value.eliminationBits[0],3)
    }

}
