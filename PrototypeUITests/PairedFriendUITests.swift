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
        try waitFor(timeout: 25) { $0["qaFriendListed"] as? Bool == true }
        let label = try XCTUnwrap(snapshot()["qaFriendLabel"] as? String)
        let friend = app.buttons[label].firstMatch
        try reveal(friend); friend.tap()
        app.buttons["Done"].tap(); resume()
        try press(peer == "A" ? "left" : "right", duration: 0.28)
        try report("ready")
        try runConnectedGameplay()
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
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        if app.buttons["Close"].waitForExistence(timeout: 3) { app.buttons["Close"].tap() }
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
                    let stop = app.buttons["Stop"].firstMatch
                    if stop.exists { try reveal(stop); stop.tap() }
                    else { try reveal(app.buttons["Stop sharing"]); app.buttons["Stop sharing"].tap() }
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
