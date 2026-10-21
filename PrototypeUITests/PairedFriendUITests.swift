import XCTest
import ObjectiveC

/// The local relay supplies only two dedicated Simulator peers; no friend/account is contacted.
final class PairedFriendUITests: XCTestCase {
    func testNativeFramesAcrossLocalPeer() throws {
        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        guard let peer = environment["BOUND_PAIR_PEER"], ["A", "B"].contains(peer),
              let portText = environment["BOUND_PAIR_PORT"], let port = Int(portText), (1024...65535).contains(port) else {
            throw XCTSkip("Run with PrototypeTools/paired_simulators.py and two isolated Simulators")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--bound-ui-paired-transport", "--bound-ui-no-animations", "--bound-ui-screen-layout-bound", "--bound-ui-reset-layout"]
        app.launchEnvironment = ["BOUND_PAIR_PEER": peer, "BOUND_PAIR_PORT": portText]
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        app.launch()
        let close = app.buttons["Close"]
        if close.waitForExistence(timeout: 2) { close.tap() }
        let cell = app.collectionViews.cells.firstMatch
        XCTAssertTrue(cell.waitForExistence(timeout: 30))
        cell.tap()
        let cycle = app.buttons["bound.panel-cycle"]
        XCTAssertTrue(cycle.waitForExistence(timeout: 20))
        for _ in 0..<3 {
            if cycle.value as? String == "Friend" { break }
            cycle.tap()
        }
        XCTAssertEqual(cycle.value as? String, "Friend")
        var lastStage = ""
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline {
            let status = try request(port: port, path: "/control/status")
            let stage = status["stage"] as? String ?? "waiting"
            if stage != lastStage {
                if stage == "done" { return }
                if stage == "background" {
                    XCUIDevice.shared.press(.home)
                    RunLoop.current.run(until: Date().addingTimeInterval(1))
                    app.activate()
                }
                if ["portrait", "landscape", "recovered"].contains(stage) {
                    XCUIDevice.shared.orientation = stage == "landscape" ? .landscapeLeft : .portrait
                    let friend = app.descendants(matching: .any).matching(identifier: "bound.friend-screen").firstMatch
                    let game = app.descendants(matching: .any).matching(identifier: "bound.game-screen").firstMatch
                    XCTAssertTrue(friend.waitForExistence(timeout: 15))
                    XCTAssertTrue(game.exists)
                    let shown = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                        !app.staticTexts["Connect a friend"].exists && friend.frame.width > 40 && friend.frame.height > 30
                    }, object: nil)
                    XCTAssertEqual(XCTWaiter.wait(for: [shown], timeout: 20), .completed)
                    XCTAssertEqual(friend.frame.width / friend.frame.height, 1.5, accuracy: 0.02)
                    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                    attachment.name = "Paired-\(peer)-\(stage)"
                    attachment.lifetime = .keepAlways
                    add(attachment)
                }
                _ = try request(port: port, path: "/report-ui/" + peer, body: ["peer": peer, "stage": stage])
                lastStage = stage
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTFail("Local paired relay did not finish within 240 seconds")
        #else
        throw XCTSkip("Local paired transport is excluded from Release")
        #endif
    }

    #if DEBUG
    private func request(port: Int, path: String, body: [String: String]? = nil) throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)" + path)!)
        request.timeoutInterval = 3
        if let body {
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let finished = expectation(description: "Local paired relay")
        final class ResultBox: @unchecked Sendable {
            private let lock = NSLock()
            private var stored: Result<Data, Error>?
            func set(_ value: Result<Data, Error>) { lock.lock(); stored = value; lock.unlock() }
            func get() -> Result<Data, Error>? { lock.lock(); defer { lock.unlock() }; return stored }
        }
        let result = ResultBox()
        URLSession.shared.dataTask(with: request) { data, _, error in
            if let error { result.set(.failure(error)) } else { result.set(.success(data ?? Data())) }
            finished.fulfill()
        }.resume()
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 5), .completed)
        guard let data = try result.get()?.get() else { throw NSError(domain: "BoundPairQA", code: 1) }
        if data.isEmpty { return [:] } // Relay acknowledgements intentionally return HTTP 204.
        return (try JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
    #endif
}

/// Real app, native touch input, native Save/Load State screens and real Agora.
/// The loopback service coordinates stages and reads private QA observations;
/// it has no pose, video, ROM, RAM-write or emulator-command endpoints.
final class FullAppGameplayUITests: XCTestCase {
    private var app = XCUIApplication()
    private var port = 0
    private var peer = ""
    private var savedCell = ""
    private var savedTile: [Int] = []
    private var quiescence: [(Method, IMP)] = []

    override func tearDownWithError() throws {
        for (method, implementation) in quiescence { method_setImplementation(method, implementation) }
        XCUIDevice.shared.orientation = .portrait
    }

    func testFullAppLiveGameplay() throws {
        try connectFriend()
        try press(peer == "A" ? "left" : "right", duration: 0.28)
        try report("ready")
        try runConnectedGameplay()
    }

    /// Short regression for the new NPC-style entry and real reliable Agora
    /// invitations. This intentionally makes no battle/trade completion claim.
    func testFriendWorldInvitations() throws {
        try connectFriend()
        try walkTo(x: peer == "A" ? 6 : 7, y: 8)
        if peer == "A" { try face("North", input: "up", x: 6, y: 8) }
        try report("positioned")
        var completed = Set<String>()
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            let stage = try request("/status")["stage"] as? String ?? "waiting"
            if stage == "done" { return }
            if stage == "failed" { XCTFail("Invitation coordinator failed"); return }
            if !completed.contains(stage) {
                switch stage {
                case "facing-away":
                    if peer == "A" {
                        XCTAssertEqual(try snapshot()["interactionCanStart"] as? Bool, false)
                        try press("a", duration: 0.08)
                        XCTAssertFalse(element("bound.friend-interaction.battle").exists)
                        try face("East", input: "right", x: 6, y: 8)
                    }
                case "open-interaction":
                    if peer == "A" {
                        try waitFor { $0["interactionCanStart"] as? Bool == true }
                        try press("a", duration: 0.08)
                        XCTAssertTrue(app.buttons["bound.friend-interaction.battle"].waitForExistence(timeout: 8))
                        let image = XCTAttachment(screenshot:XCUIScreen.main.screenshot())
                        image.name = "Walk-up-A-interaction"; image.lifetime = .keepAlways; add(image)
                    }
                case "battle-invite":
                    if peer == "A" { app.buttons["bound.friend-interaction.battle"].tap() }
                    try waitFor { $0["interactionPhase"] as? String == (self.peer == "A" ? "outgoing" : "incoming") }
                case "battle-accept":
                    if peer == "B" { app.buttons["bound.friend-interaction.decline"].tap() }
                    try waitFor { $0["interactionPhase"] as? String == (self.peer == "A" ? "ended":"idle") }
                case "close-battle":
                    if peer == "A" { app.buttons["bound.friend-interaction.close"].tap() }
                    try waitFor { $0["interactionPhase"] as? String == "idle" }
                case "trade-invite":
                    if peer == "A" {
                        try waitFor { $0["interactionCanStart"] as? Bool == true }
                        try press("a", duration: 0.08)
                        XCTAssertTrue(app.buttons["bound.friend-interaction.trade"].waitForExistence(timeout: 8))
                        app.buttons["bound.friend-interaction.trade"].tap()
                    }
                    try waitFor { $0["interactionPhase"] as? String == (self.peer == "A" ? "outgoing" : "incoming") }
                case "trade-decline":
                    if peer == "B" { app.buttons["bound.friend-interaction.decline"].tap() }
                    try waitFor { $0["interactionPhase"] as? String == (self.peer == "A" ? "ended" : "idle") }
                    if peer == "A" { app.buttons["bound.friend-interaction.close"].tap() }
                default: pause(0.2); continue
                }
                try report(stage); completed.insert(stage)
            }
            pause(0.2)
        }
        XCTFail("World invitation regression did not finish")
    }

    func testActualFriendBattle() throws {
        try connectFriend()
        try walkTo(x:peer == "A" ? 6:7,y:8)
        if peer == "A" { try face("East",input:"right",x:6,y:8) }
        try report("positioned")
        var completed=Set<String>()
        let deadline=Date().addingTimeInterval(850)
        while Date()<deadline {
            let stage=try request("/status")["stage"] as? String ?? "waiting"
            if stage == "done" { return }
            if stage == "failed" { XCTFail("Battle coordinator failed"); return }
            if !completed.contains(stage) {
                switch stage {
                case "battle-invite":
                    if peer == "A" {
                        try waitFor { $0["interactionCanStart"] as? Bool == true }
                        try press("a",duration:0.08)
                        XCTAssertTrue(app.buttons["bound.friend-interaction.battle"].waitForExistence(timeout:8))
                        app.buttons["bound.friend-interaction.battle"].tap()
                    }
                    try waitFor { $0["interactionPhase"] as? String == (self.peer == "A" ? "outgoing":"incoming") }
                case "battle-accept":
                    if peer == "B" { app.buttons["bound.friend-interaction.accept"].tap() }
                    try waitFor(timeout:150) { $0["nativeBattle"] as? Bool == true && $0["interactionPhase"] as? String == "playing" }
                    let image=XCTAttachment(screenshot:XCUIScreen.main.screenshot())
                    image.name="Actual-friend-battle-"+peer; image.lifetime = .keepAlways; add(image)
                case "battle-play":
                    let end=Date().addingTimeInterval(600)
                    var damaged=false,reportedDamage=false
                    let initial=try snapshot()["battlePlayerHP"] as? [Int] ?? []
                    while Date()<end {
                        let value=try snapshot()
                        XCTAssertEqual(value["battleFailure"] as? String,"")
                        if value["nativeBattle"] as? Bool == true,let hp=value["battlePlayerHP"] as? [Int],hp != initial { damaged=true }
                        if value["interactionPhase"] as? String == "ended" {
                            XCTAssertTrue(damaged,"A real native move must change party HP")
                            XCTAssertEqual(value["battlesCompleted"] as? Int,1)
                            XCTAssertEqual(value["battlesRestored"] as? Int,1)
                            XCTAssertTrue([1,2,3].contains(value["battleOutcome"] as? Int ?? 0))
                            break
                        }
                        if damaged && !reportedDamage { try report("battle-damage"); reportedDamage=true }
                        try press("a",duration:0.12); pause(0.12)
                    }
                    XCTAssertEqual(try snapshot()["battlesCompleted"] as? Int,1)
                    app.buttons["bound.friend-interaction.close"].tap()
                    try waitFor { $0["reader"] as? String == "live" && $0["tile"] as? [Int] == [self.peer == "A" ? 6:7,8] }
                default: pause(0.2); continue
                }
                try report(stage); completed.insert(stage)
            }
            pause(0.2)
        }
        XCTFail("Actual friend battle did not finish")
    }

    func testActualFriendTrade() throws {
        try connectFriend()
        try waitFor { $0["tradeFixtureReady"] as? Bool == true }
        try walkTo(x:peer == "A" ? 6:7,y:8)
        if peer == "A" { try face("East",input:"right",x:6,y:8) }
        try report("positioned")
        let mode=ProcessInfo.processInfo.environment["BOUND_GAMEPLAY_TRADE"] ?? "complete"
        var completed=Set<String>()
        let deadline=Date().addingTimeInterval(600)
        while Date()<deadline {
            let stage=try request("/status")["stage"] as? String ?? "waiting"
            if stage == "done" { return }
            if stage == "failed" { XCTFail("Trade coordinator failed"); return }
            if !completed.contains(stage) {
                switch stage {
                case "trade-invite":
                    if peer == "A" {
                        try waitFor { $0["interactionCanStart"] as? Bool == true }
                        try press("a",duration:0.08)
                        XCTAssertTrue(app.buttons["bound.friend-interaction.trade"].waitForExistence(timeout:8))
                        try tapScreenPoint(in:app.buttons["bound.friend-interaction.trade"])
                    }
                    try waitFor { $0["interactionPhase"] as? String == (self.peer == "A" ? "outgoing":"incoming") }
                case "trade-accept":
                    if peer == "B" { try tapScreenPoint(in:app.buttons["bound.friend-interaction.accept"]) }
                    let end=Date().addingTimeInterval(100)
                    while Date()<end {
                        let value=try snapshot()
                        XCTAssertEqual(value["battleFailure"] as? String,"")
                        if value["tradeOpened"] as? Bool == true { break }
                        try press("a",duration:0.08); pause(0.3)
                    }
                    XCTAssertEqual(try snapshot()["tradeOpened"] as? Bool,true)
                case "trade-exchange":
                    let end=Date().addingTimeInterval(180)
                    var selectedTrade=false
                    while Date()<end {
                        let value=try snapshot()
                        XCTAssertEqual(value["battleFailure"] as? String,"")
                        XCTAssertEqual(value["interactionPhase"] as? String,"playing","Unexpected cancellation: \(value["battleCancellation"] ?? "")")
                        if mode == "exchange-disconnect", value["battleCallback"] as? Int == 0x08053D85 { break }
                        if (value["tradeCount"] as? Int ?? 0)>0 { break }
                        if value["tradeMenuID"] as? Int == 1, !selectedTrade {
                            try press("down",duration:0.08); selectedTrade=true
                        } else {
                            if value["tradeMenuID"] as? Int != 1 { selectedTrade=false }
                            try press("a",duration:0.08)
                        }
                        pause(0.3)
                    }
                    let value=try snapshot()
                    if mode == "exchange-disconnect" {
                        XCTAssertEqual(value["tradeCount"] as? Int,0,"Interrupt before native exchange/save completion")
                    } else {
                    XCTAssertEqual(value["tradeCount"] as? Int,1)
                    XCTAssertEqual(value["tradeMarker"] as? Int,peer == "A" ? 0xBC:0xBB)
                    XCTAssertEqual(value["tradeOT"] as? Int,peer == "A" ? 0xBC:0xBB)
                    XCTAssertEqual(value["tradeUnofferedUnchanged"] as? Bool,true)
                    }
                case "trade-exit":
                    let end=Date().addingTimeInterval(50)
                    while Date()<end {
                        let value=try snapshot()
                        if value["interactionPhase"] as? String == "ended" { break }
                        if value["tradeMenuID"] as? Int == 0, value["tradeCursor"] as? Int != 12 {
                            try press("up",duration:0.08)
                        } else { try press("a",duration:0.08) }
                        pause(0.3)
                    }
                    try waitFor { $0["tradesCompleted"] as? Int == 1 && $0["tradeRecoveryBlocked"] as? Bool == false }
                    try tapScreenPoint(in:app.buttons["bound.friend-interaction.close"])
                    try waitFor { $0["reader"] as? String == "live" }
                case "trade-disconnect":
                    if peer == "A" { XCUIDevice.shared.press(.home); pause(4); app.activate(); pause(1); resume() }
                    try waitFor(timeout:35) { $0["tradeRecoveryBlocked"] as? Bool == false && $0["tradeOpened"] as? Bool == true }
                    if app.buttons["bound.friend-interaction.close"].exists { try tapScreenPoint(in:app.buttons["bound.friend-interaction.close"]) }
                    try waitFor { $0["interactionPhase"] as? String == "idle" }
                    // Interrupted trade boots the actual cartridge save. Continue
                    // through its native title/menu, using only controller touches.
                    let end=Date().addingTimeInterval(55)
                    while Date()<end {
                        let value=try snapshot()
                        if value["reader"] as? String == "live" { break }
                        try press("start",duration:0.08); try press("a",duration:0.08); pause(0.3)
                    }
                    try waitFor { $0["reader"] as? String == "live" }
                case "trade-verify":
                    let value=try snapshot(),exchanged=mode != "menu-disconnect"
                    if mode == "exchange-disconnect" {
                        XCTAssertTrue([0xBB,0xBC].contains(value["tradeMarker"] as? Int ?? 0))
                    } else {
                    XCTAssertEqual(value["tradeMarker"] as? Int,exchanged ? (peer == "A" ? 0xBC:0xBB):(peer == "A" ? 0xBB:0xBC))
                    }
                    XCTAssertEqual(value["tradeOT"] as? Int,value["tradeMarker"] as? Int)
                    XCTAssertEqual(value["tradeUnofferedUnchanged"] as? Bool,true)
                    XCTAssertEqual(value["tradeRecoveryBlocked"] as? Bool,false)
                    let image=XCTAttachment(screenshot:XCUIScreen.main.screenshot())
                    image.name="Actual-friend-trade-"+mode+"-"+peer; image.lifetime = .keepAlways; add(image)
                default: pause(0.2); continue
                }
                try report(stage); completed.insert(stage)
            }
            pause(0.2)
        }
        XCTFail("Actual friend trade did not finish")
    }

    private func walkTo(x: Int, y: Int) throws {
        for _ in 0..<20 {
            let tile = try XCTUnwrap(snapshot()["tile"] as? [Int])
            if tile == [x,y] { return }
            let input = tile[1] < y ? "down" : tile[1] > y ? "up" : tile[0] < x ? "right" : "left"
            try press(input,duration:0.12); pause(0.25)
        }
        XCTFail("Native walking did not reach the interaction tile")
    }
    private func face(_ direction: String, input: String, x: Int, y: Int) throws {
        for _ in 0..<8 {
            try walkTo(x:x,y:y)
            if try snapshot()["facing"] as? String == direction { pause(0.3); return }
            try press(input,duration:0.025); pause(0.25)
        }
        XCTFail("Native controller did not face the friend")
    }

    private func connectFriend() throws {
        try launchGame()
        try openFriends()
        let live = app.switches["bound.live-presence-enabled"]
        try reveal(live)
        if live.value as? String != "1" {
            live.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
        XCTAssertEqual(live.value as? String, "1")
        let check = app.buttons["Connection check"]
        try reveal(check); check.tap()
        let record = app.buttons["bound.presence-check-start"]
        try reveal(record); record.tap()
        try waitFor(timeout: 25) { $0["qaFriendListed"] as? Bool == true && $0["friendsBusy"] as? Bool == false }
        let label = try XCTUnwrap(snapshot()["qaFriendLabel"] as? String)
        let friend = app.buttons[label].firstMatch
        try reveal(friend)
        XCTAssertTrue(friend.isEnabled)
        // The row also contains a trailing actions menu. Touch the friend's
        // label area, then verify that the normal selection actually started.
        try tapScreenPoint(in: friend, horizontal: 0.15)
        try waitFor { $0["qaFriendSelected"] as? Bool == true && $0["active"] as? Bool == true }
        app.buttons["Done"].tap(); resume()
        try waitFor { $0["reader"] as? String == "live" && $0["running"] as? Bool == true && ($0["tile"] as? [Int])?.count == 2 }
    }

    /// Resolve native routing independently of RTC/friend-pairing setup.
    func testNativeMapAndSaveRestore() throws {
        try launchGame()
        try press(peer == "A" ? "left" : "right", duration: 0.28)
        try saveState(); savedTile = try snapshot()["tile"] as? [Int] ?? []
        XCTAssertEqual(savedTile.count, 2)
        try exitLab()
        let outside = try snapshot()
        XCTAssertEqual(outside["reader"] as? String, "live")
        XCTAssertNotEqual(outside["map"] as? [Int], [4, 3])
        try loadState()
        try waitFor { $0["map"] as? [Int] == [4, 3] && $0["tile"] as? [Int] == self.savedTile && ($0["restores"] as? Int ?? 0) > 0 }
        try report("native-done")
        let capture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        capture.name = "Native-map-and-restore-" + peer; capture.lifetime = .keepAlways; add(capture)
    }

    private func launchGame() throws {
        let env = ProcessInfo.processInfo.environment
        guard let id = env["BOUND_GAMEPLAY_PEER"], ["A", "B"].contains(id),
              let value = env["BOUND_GAMEPLAY_PORT"].flatMap(Int.init) else {
            throw XCTSkip("Requires the full-app gameplay coordinator and two disposable simulators")
        }
        peer = id; port = value; continueAfterFailure = false
        // The emulator continuously animates. Assert actual UI transitions instead
        // of waiting for Xcode 27's animation-idle notification before every touch.
        if let process = NSClassFromString("XCUIApplicationProcess") {
            for name in ["shouldSkipPreEventQuiescence", "shouldSkipPostEventQuiescence"] {
                if let method = class_getInstanceMethod(process, NSSelectorFromString(name)) {
                    let block: @convention(block) (AnyObject) -> Bool = { _ in true }
                    quiescence.append((method, method_setImplementation(method, imp_implementationWithBlock(block))))
                }
            }
        }
        app.launchArguments = ["--bound-ui-gameplay-qa", "--bound-ui-no-animations", "--bound-ui-screen-layout-bound"]
        if ProcessInfo.processInfo.environment["BOUND_GAMEPLAY_TRADE"] != nil { app.launchArguments.append("--bound-ui-trade-qa") }
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        if app.buttons["Close"].waitForExistence(timeout: 3) { app.buttons["Close"].tap() }
        let settings = app.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 30)); settings.tap()
        let experimental = app.switches["bound.settings-experimental-features"]
        XCTAssertTrue(experimental.waitForExistence(timeout: 10))
        if experimental.value as? String != "1" {
            experimental.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        }
        XCTAssertEqual(experimental.value as? String, "1")
        app.buttons["bound.settings-close"].tap()
        let game = app.collectionViews.cells.firstMatch
        XCTAssertTrue(game.waitForExistence(timeout: 60)); game.tap()
        XCTAssertTrue(element("bound.qa-input-start").waitForExistence(timeout: 30))
        let bootDeadline = Date().addingTimeInterval(100)
        while Date() < bootDeadline {
            if try snapshot()["reader"] as? String == "live" { break }
            try press("start", duration: 0.1); try press("a", duration: 0.1)
            pause(1)
        }
        XCTAssertEqual(try snapshot()["reader"] as? String, "live")
        XCTAssertEqual(try snapshot()["core"] as? String, "com.rileytestut.GBADeltaCore")
        let recovered=app.buttons["bound.friend-interaction.close"]
        if recovered.exists { recovered.tap() }
    }

    private func runConnectedGameplay() throws {
        var completed = Set<String>(), walk = 0
        let deadline = Date().addingTimeInterval(1500)
        while Date() < deadline {
            let control = try request("/status")
            let stage = control["stage"] as? String ?? "waiting"
            if stage == "done" { return }
            if stage == "failed" { XCTFail("Coordinator rejected gameplay evidence"); return }
            if !completed.contains(stage) {
                switch stage {
                case "save-lab":
                    try saveState(); savedTile = try snapshot()["tile"] as? [Int] ?? []
                    XCTAssertEqual(savedTile.count, 2)
                case "exit-a" where peer == "A", "exit-b" where peer == "B":
                    try exitLab()
                case "outside":
                    try press(peer == "A" ? "left" : "right", duration: 0.22)
                case "restore-a" where peer == "A", "restore-b" where peer == "B":
                    try loadState()
                    try waitFor { value in value["map"] as? [Int] == [4, 3] && value["tile"] as? [Int] == self.savedTile }
                case "background-a" where peer == "A":
                    try report("background-start")
                    XCUIDevice.shared.press(.home); pause(4); app.activate(); resume()
                case "stop":
                    try openFriends()
                    let disclosure = app.buttons["Connection check"]
                    try reveal(disclosure); disclosure.tap()
                    let stopCheck = app.buttons["bound.presence-check-stop"]
                    if stopCheck.exists { try reveal(stopCheck); stopCheck.tap() }
                    // SwiftUI materializes this row only after scrolling. Keep
                    // both normal UI labels in the query while revealing it.
                    let stop = app.buttons.matching(NSPredicate(format: "label == %@ OR label == %@", "Stop", "Stop sharing")).firstMatch
                    try waitFor { $0["friendsBusy"] as? Bool == false }
                    try reveal(stop); try tapScreenPoint(in: stop)
                    try waitFor { $0["active"] as? Bool == false && $0["joined"] as? Bool == false }
                    app.buttons["Done"].tap(); resume()
                default: break
                }
                if ["save-lab", "exit-a", "exit-b", "outside", "restore-a", "restore-b", "background-a", "stop"].contains(stage) {
                    try report(stage); completed.insert(stage)
                    let capture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                    capture.name = "Full-app-\(peer)-\(stage)"; capture.lifetime = .keepAlways; add(capture)
                }
            }
            if ["lab-visible", "reunited", "soak"].contains(stage) {
                let state = try snapshot()
                if state["reader"] as? String == "live", state["map"] as? [Int] == [4, 3] {
                    let tile = state["tile"] as? [Int] ?? [6, 8]
                    let direction = tile[0] <= 5 ? "right" : tile[0] >= 8 ? "left" : ["up", "right", "down", "left"][walk % 4]
                    if tile[1] <= 7 { try press("down", duration: 0.13) }
                    else if tile[1] >= 9 { try press("up", duration: 0.13) }
                    else { try press(direction, duration: 0.13) }
                    walk += 1
                }
            }
            pause(0.3)
        }
        XCTFail("Full-app gameplay exceeded its deadline")
    }

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any).matching(identifier: id).firstMatch }
    private func pause(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
    private func press(_ input: String, duration: Double) throws {
        // Controller AX elements are rebuilt during layout. Freeze the native
        // screen rectangle before event synthesis instead of resolving a stale
        // element's hit point halfway through a touch.
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            for target in app.buttons.matching(identifier: "bound.qa-input-" + input).allElementsBoundByIndex {
                let frame = target.frame
                if !frame.isEmpty && frame.midX.isFinite && frame.midY.isFinite {
                    app.coordinate(withNormalizedOffset: .zero)
                        .withOffset(CGVector(dx: frame.midX, dy: frame.midY)).press(forDuration: duration)
                    return
                }
            }
            pause(0.25)
        }
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "Unavailable-native-" + input; hierarchy.lifetime = .keepAlways; add(hierarchy)
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = "Unavailable-native-" + input; image.lifetime = .keepAlways; add(image)
        XCTFail("Native controller geometry was unavailable")
    }
    private func tapScreenPoint(in target: XCUIElement, horizontal: CGFloat = 0.5) throws {
        // SwiftUI applies the row identifier to its sibling buttons too. Freeze
        // the chosen label's frame before synthesis can resolve that shared ID.
        let deadline=Date().addingTimeInterval(10)
        var previous=CGRect.null,stableSince=Date()
        while Date()<deadline {
            let frame=target.frame
            if frame != previous { previous=frame; stableSince=Date() }
            if target.isEnabled, !frame.isEmpty, frame.midX.isFinite, frame.midY.isFinite,
               app.frame.contains(CGPoint(x:frame.midX,y:frame.midY)),
               Date().timeIntervalSince(stableSince)>=0.5 {
                app.coordinate(withNormalizedOffset:.zero)
                    .withOffset(CGVector(dx:frame.minX+frame.width*horizontal,dy:frame.midY)).tap()
                return
            }
            pause(0.2)
        }
        XCTFail("Normal control geometry did not settle")
    }
    private func snapshot() throws -> [String: Any] {
        let value = element("bound.gameplay-qa-status")
        if value.exists, let text = value.value as? String, let data = text.data(using: .utf8),
           let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return result }
        let status = try request("/status")
        return (status["peers"] as? [String: [String: Any]])?[peer] ?? [:]
    }
    private func waitFor(timeout: Double = 20, _ predicate: ([String: Any]) -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline { if predicate(try snapshot()) { return }; pause(0.25) }
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "Unreached-gameplay-checkpoint"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = "Unreached-gameplay-checkpoint"; image.lifetime = .keepAlways; add(image)
        let observed = XCTAttachment(string: String(describing: try snapshot()))
        observed.name = "Unreached-gameplay-observation"; observed.lifetime = .keepAlways; add(observed)
        XCTFail("Native gameplay state did not reach the expected checkpoint")
    }
    private func menu() {
        if !app.buttons["Settings"].exists { element("bound.native-menu").tap() }
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 8))
    }
    private func resume() { if app.buttons["Resume"].exists { app.buttons["Resume"].tap() } }
    private func openFriends() throws {
        menu()
        let button = app.buttons["Friends"].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5)); button.tap()
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 8))
    }
    private func reveal(_ target: XCUIElement) throws {
        for _ in 0..<12 {
            if target.exists && target.isHittable { return }
            app.swipeUp()
        }
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        image.name = "Missing-normal-control"; image.lifetime = .keepAlways; add(image)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "Normal-app-hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        XCTFail("Required normal app control was unavailable")
    }
    private func saveState() throws {
        menu(); app.buttons["Save State"].tap()
        let collection = app.collectionViews["bound.save-states"]
        XCTAssertTrue(collection.waitForExistence(timeout: 8))
        let before = Set(collection.cells.allElementsBoundByIndex.map(\.identifier))
        app.navigationBars.buttons["Add"].tap()
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let cell = collection.cells.allElementsBoundByIndex.first(where: { $0.identifier.hasPrefix("bound.save-state.") && !before.contains($0.identifier) }) {
                savedCell = cell.identifier; cell.tap(); resume()
                try waitFor { $0["reader"] as? String == "live" && $0["running"] as? Bool == true }
                return
            }
            pause(0.25)
        }
        XCTFail("Actual VBA-M save-state file was not created")
    }
    private func loadState() throws {
        XCTAssertFalse(savedCell.isEmpty)
        menu(); app.buttons["Load State"].tap()
        let cell = app.collectionViews["bound.save-states"].cells[savedCell]
        XCTAssertTrue(cell.waitForExistence(timeout: 8)); cell.tap(); resume()
    }
    private func exitLab() throws {
        for _ in 0..<15 {
            let state = try snapshot()
            if state["map"] as? [Int] != [4, 3] && state["reader"] as? String == "live" { return }
            let tile = state["tile"] as? [Int] ?? [6, 8]
            if tile[0] < 6 { try press("right", duration: 0.12) }
            else if tile[0] > 6 { try press("left", duration: 0.12) }
            else { try press("down", duration: 0.45) }
            pause(0.2)
        }
        XCTFail("The normal controller route did not exit the lab")
    }
    private func report(_ stage: String) throws {
        var body = try snapshot(); body["stage"] = stage
        if !savedCell.isEmpty {
            body["saveState"] = String(savedCell.dropFirst("bound.save-state.".count))
            body["savedTile"] = savedTile
        }
        _ = try request("/ui/" + peer, body: body)
    }
    private func request(_ path: String, body: [String: Any]? = nil) throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)" + path)!)
        request.timeoutInterval = 3
        if let body { request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let done = expectation(description: "QA stage coordination")
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var result: (Data?, Error?) = (nil, nil)
            func set(_ data: Data?, _ error: Error?) { lock.lock(); defer { lock.unlock() }; result = (data, error) }
            func get() -> (Data?, Error?) { lock.lock(); defer { lock.unlock() }; return result }
        }
        let box = Box()
        URLSession.shared.dataTask(with: request) { data, _, error in box.set(data, error); done.fulfill() }.resume()
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 5), .completed)
        let (bytes, error) = box.get()
        if let error { throw error }
        return try JSONSerialization.jsonObject(with: bytes ?? Data("{}".utf8)) as? [String: Any] ?? [:]
    }
}
