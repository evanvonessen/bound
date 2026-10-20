import XCTest
import UIKit
import CoreText
import DeltaCore
import ZIPFoundation
@testable import Delta

@MainActor final class AppearanceIntegrationTests: XCTestCase {
    func testIPadAndLandscapeBrandingPreservesNativeControlPixelsAndGeometry() throws {
        for system in [System.gba, .gbc, .snes, .nes, .n64, .genesis, .ds] {
            // Genesis is bundled but not registered by the Release app. Inspect
            // its shipped artwork without enabling a core or changing settings.
            let file = try XCTUnwrap(system.deltaCore.resourceBundle.url(forResource: "Standard", withExtension: "deltaskin"))
            let native = try XCTUnwrap(DeltaCore.ControllerSkin(fileURL: file))
            var cases = [DeltaCore.ControllerSkin.Traits]()
            for display in [DeltaCore.ControllerSkin.DisplayType.standard, .splitView] {
                for orientation in [DeltaCore.ControllerSkin.Orientation.portrait, .landscape] {
                    cases.append(.init(device: .ipad, displayType: display, orientation: orientation))
                }
            }
            if system == .gbc || system == .ds {
                for display in [DeltaCore.ControllerSkin.DisplayType.standard, .edgeToEdge] {
                    cases.append(.init(device: .iphone, displayType: display, orientation: .landscape))
                }
            }
            for traits in cases {
                let aspect = try XCTUnwrap(native.aspectRatio(for: traits))
                let size = CGSize(width: 768, height: 768 * aspect.height / aspect.width)
                let skin = BoundStockControllerSkin(base: native, canvasSize: size)
                let original = try XCTUnwrap(native.items(for: traits))
                let revised = try XCTUnwrap(skin.items(for: traits))
                if native.isTranslucent(for: traits) != true {
                    XCTAssertEqual(revised.map(\.frame), original.map(\.frame), "Opaque casings keep every native control, including Menu")
                    XCTAssertEqual(revised.map(\.extendedFrame), original.map(\.extendedFrame))
                }
                let gameplay = original.filter { !$0.inputs.allInputs.contains { $0.stringValue == "menu" } }
                for control in gameplay {
                    let actual = try XCTUnwrap(revised.first { $0.id == control.id })
                    XCTAssertEqual(actual.frame, control.frame)
                    XCTAssertEqual(actual.extendedFrame, control.extendedFrame)
                    XCTAssertEqual(actual.inputs.allInputs.map(\.stringValue), control.inputs.allInputs.map(\.stringValue))
                }
                XCTAssertEqual(skin.screens(for: traits)?.map(\.outputFrame), native.screens(for: traits)?.map(\.outputFrame))
                let format = UIGraphicsImageRendererFormat(); format.scale = 1
                func render(_ image: UIImage) -> UIImage {
                    UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
                }
                func pixels(_ image: UIImage) throws -> [UInt8] {
                    let cg = try XCTUnwrap(image.cgImage)
                    var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
                    try bytes.withUnsafeMutableBytes { buffer in
                        let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: cg.width, height: cg.height,
                            bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
                    }
                    return bytes
                }
                for pressed in [false, true] {
                    let source = pressed ? native.pressedImage(for: traits, preferredSize: .small) : native.image(for: traits, preferredSize: .small)
                    guard let source else { continue }
                    let result = try XCTUnwrap(pressed ? skin.pressedImage(for: traits, preferredSize: .small) : skin.image(for: traits, preferredSize: .small))
                    // Use the same UIKit compositing scale on both sides so the
                    // comparison measures artwork, not PDF/raster resampling.
                    let baseline = UIGraphicsImageRenderer(size: source.size).image { _ in source.draw(at: .zero) }
                    let before = try pixels(render(baseline)), afterImage = render(result), after = try pixels(afterImage)
                    let patches = skin.supplementalBrandingPatches(size: size, traits: traits)
                    for patch in patches {
                        XCTAssertTrue(CGRect(origin: .zero, size: size).contains(patch.frame))
                        XCTAssertTrue(CGRect(origin: .zero, size: size).contains(patch.sample))
                        // DS Split View has a virtual touch-screen input spanning
                        // the lower half; it has no printed control artwork.
                        for control in gameplay where control.kind != .touchScreen {
                            XCTAssertFalse(patch.frame.intersects(control.frame.applying(.init(scaleX: size.width, y: size.height))),
                                           "Branding must not paint over a native control: \(system) \(traits) \(control.inputs.allInputs)")
                        }
                    }
                    var excluded = patches.map { $0.frame.insetBy(dx: -2, dy: -2) }
                    // Menu relocation predates this repair and is verified separately.
                    for item in original + revised where item.inputs.allInputs.contains(where: { $0.stringValue == "menu" }) {
                        excluded.append(item.frame.applying(.init(scaleX: size.width, y: size.height)).insetBy(dx: -5, dy: -5))
                    }
                    var changedInk = 0, changedElsewhere = 0
                    for y in 0..<Int(size.height) {
                        for x in 0..<Int(size.width) {
                            let offset = (y * Int(size.width) + x) * 4
                            guard (0..<4).contains(where: { abs(Int(before[offset+$0])-Int(after[offset+$0])) > 8 }) else { continue }
                            let point = CGPoint(x: x, y: y)
                            if patches.contains(where: { $0.frame.contains(point) }) { changedInk += 1 }
                            else if !excluded.contains(where: { $0.contains(point) }) { changedElsewhere += 1 }
                        }
                    }
                    XCTAssertEqual(changedElsewhere, 0, "Only branding and the existing Menu relocation may change: \(system) \(traits)")
                    if !patches.isEmpty { XCTAssertGreaterThan(changedInk, 20) }
                    if !pressed {
                        let attachment = XCTAttachment(image: afterImage)
                        attachment.name = "Bound-branding-\(system)-\(traits.device)-\(traits.displayType)-\(traits.orientation)"
                        attachment.lifetime = .keepAlways; add(attachment)
                    }
                }
            }
        }
    }
    func testPortraitWordmarkPreservesRenderedStockShouldersAndCasingStrip() throws {
        let native = try XCTUnwrap(DeltaCore.ControllerSkin.standardControllerSkin(for: System.gba.gameType))
        for (width, display) in [(375.0, DeltaCore.ControllerSkin.DisplayType.standard), (430.0, .edgeToEdge)] {
            let traits = DeltaCore.ControllerSkin.Traits(device: .iphone, displayType: display, orientation: .portrait)
            let aspect = try XCTUnwrap(native.aspectRatio(for: traits))
            let size = CGSize(width: width, height: width * aspect.height / aspect.width)
            let stock = BoundStockControllerSkin(base: native, canvasSize: size)
            let original = try XCTUnwrap(native.items(for: traits))
            let revised = try XCTUnwrap(stock.items(for: traits))
            XCTAssertEqual(revised.map(\.frame), original.map(\.frame))
            XCTAssertEqual(revised.map(\.extendedFrame), original.map(\.extendedFrame))
            XCTAssertEqual(stock.aspectRatio(for: traits), aspect)
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            func render(_ skin: ControllerSkinProtocol) -> UIImage {
                let view = ControllerView(frame: CGRect(origin: .zero, size: size))
                view.overrideControllerSkinTraits = traits
                view.controllerSkin = skin
                view.layoutIfNeeded()
                return UIGraphicsImageRenderer(size: size, format: format).image { context in
                    UIColor.black.setFill(); context.fill(CGRect(origin: .zero, size: size))
                    view.layer.render(in: context.cgContext)
                }
            }
            let before = render(native), after = render(stock)
            func pixels(_ image: UIImage) throws -> [UInt8] {
                let cg = try XCTUnwrap(image.cgImage)
                var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
                try bytes.withUnsafeMutableBytes { buffer in
                    let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: cg.width, height: cg.height,
                        bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                    // A CGImage-to-bitmap copy already preserves image row order.
                    // Flipping here would compare the bottom branding as the top strip.
                    context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
                }
                return bytes
            }
            let oldPixels = try pixels(before), newPixels = try pixels(after)
            let wordmark = try XCTUnwrap(stock.portraitWordmarkFrame(size: size, traits: traits)).insetBy(dx: -1, dy: -1)
            let stripHeight = Int(34 * width / 320)
            var changedOutsideInk = 0, shoulderInk = 0, changedWordmark = 0
            for y in 0..<stripHeight {
                for x in 0..<Int(width) {
                    let offset = (y * Int(width) + x) * 4
                    let changed = (0..<4).contains { abs(Int(oldPixels[offset+$0])-Int(newPixels[offset+$0])) > 2 }
                    if wordmark.contains(CGPoint(x: x, y: y)) {
                        if changed { changedWordmark += 1 }
                    } else if changed { changedOutsideInk += 1 }
                    if x < Int(width / 4), oldPixels[offset] > 100 { shoulderInk += 1 }
                }
            }
            XCTAssertEqual(changedOutsideInk, 0, "Shoulder artwork and original casing edge must be pixel-identical")
            XCTAssertGreaterThan(changedWordmark, 20, "Render the replacement wordmark")
            XCTAssertGreaterThan(shoulderInk, 100, "Compare real rendered L/R assets, not empty views")
            for (name, image) in [("Stock-Delta-portrait-\(Int(width))", before), ("Bound-portrait-wordmark-\(Int(width))", after)] {
                let attachment = XCTAttachment(image: image); attachment.name = name
                attachment.lifetime = .keepAlways; add(attachment)
            }
        }
    }

    func testMinimalDrawingPreservesNativeAndCustomizedGeometryAndInput() throws {
        let native = try XCTUnwrap(DeltaCore.ControllerSkin.standardControllerSkin(for: System.gba.gameType))
        for orientation in [DeltaCore.ControllerSkin.Orientation.portrait, .landscape] {
            let traits = DeltaCore.ControllerSkin.Traits(device: .iphone, displayType: .standard, orientation: orientation)
            let canvas = orientation == .portrait ? CGSize(width: 390, height: 280) : CGSize(width: 844, height: 390)
            let items = try XCTUnwrap(native.items(for: traits))
            let first = try XCTUnwrap(items.first(where: { $0.kind == .button }))
            let placed = BoundPlacedControllerSkin(base: native, layout: .init(positions: [first.id: .init(x: 0.7, y: 0.65, scale: 1.1)]), canvasSize: canvas)
            for base in [native as ControllerSkinProtocol, placed as ControllerSkinProtocol] {
                let light = BoundMinimalControllerSkin(base: base, canvasSize: canvas, traits: UITraitCollection(userInterfaceStyle: .light))
                let dark = BoundMinimalControllerSkin(base: base, canvasSize: canvas, traits: UITraitCollection(userInterfaceStyle: .dark))
                let original = try XCTUnwrap(base.items(for: traits)), themed = try XCTUnwrap(light.items(for: traits))
                XCTAssertEqual(themed.map(\.id), original.map(\.id))
                XCTAssertEqual(themed.map(\.frame), original.map(\.frame))
                for (actual, expected) in zip(themed, original) {
                    XCTAssertTrue(actual.extendedFrame.contains(expected.extendedFrame))
                    if actual.kind == .button {
                        XCTAssertGreaterThanOrEqual(actual.extendedFrame.width * canvas.width, 44 - 0.001)
                        XCTAssertGreaterThanOrEqual(actual.extendedFrame.height * canvas.height, 44 - 0.001)
                    } else { XCTAssertEqual(actual.extendedFrame, expected.extendedFrame) }
                }
                XCTAssertEqual(themed.map { $0.inputs.allInputs.map(\.stringValue) }, original.map { $0.inputs.allInputs.map(\.stringValue) })
                XCTAssertEqual(light.gameScreenFrame(for: traits), base.gameScreenFrame(for: traits))
                XCTAssertEqual(light.aspectRatio(for: traits), base.aspectRatio(for: traits))
                XCTAssertNotEqual(light.identifier, dark.identifier)
                let normal = try XCTUnwrap(light.image(for: traits, preferredSize: .small))
                XCTAssertEqual(normal.size, canvas)
                XCTAssertNotEqual(normal.pngData(), dark.image(for: traits, preferredSize: .small)?.pngData())
                XCTAssertNotEqual(normal.pngData(), light.pressedImage(for: traits, preferredSize: .small)?.pngData())
            }
        }
    }
    func testBundledNotesPixelFontScalesAndRetainsUnicodeTextAndFallback() throws {
        let filenames = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "UIAppFonts") as? [String])
        XCTAssertTrue(filenames.contains("Early GameBoy.ttf"))
        XCTAssertNotNil(Bundle.main.url(forResource: "Early GameBoy", withExtension: "ttf"))
        XCTAssertNotNil(UIFont(name: BoundNotesFont.postScriptName, size: 16))
        let normal = BoundNotesFont.uiFont(compatibleWith: UITraitCollection(preferredContentSizeCategory: .large))
        let enlarged = BoundNotesFont.uiFont(compatibleWith: UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge))
        XCTAssertEqual(normal.fontName, BoundNotesFont.postScriptName)
        XCTAssertGreaterThan(enlarged.pointSize, normal.pointSize)
        let text = "Notes café 漢字 🧑🏽‍💻"
        let view = UITextView()
        view.font = normal
        view.text = text
        XCTAssertEqual(view.text, text)
        let base = CTFontCreateWithName(normal.fontName as CFString, normal.pointSize, nil)
        let fallback = CTFontCreateForString(base, "漢" as CFString, CFRange(location: 0, length: 1))
        XCTAssertNotEqual(CTFontCopyPostScriptName(fallback) as String, BoundNotesFont.postScriptName)
        let emojiFallback = CTFontCreateForString(base, "😀" as CFString, CFRange(location: 0, length: 2))
        XCTAssertNotEqual(CTFontCopyPostScriptName(emojiFallback) as String, BoundNotesFont.postScriptName)
        var character: UniChar = 0x6F22
        var glyph: CGGlyph = 0
        XCTAssertTrue(CTFontGetGlyphsForCharacters(fallback, &character, &glyph, 1))
        XCTAssertNotEqual(glyph, 0)
    }
    func testFreshNativeFeedbackDefaultsPreserveExplicitDisabledChoicesAcrossReopening() throws {
        let defaults = UserDefaults.standard
        let domain = try XCTUnwrap(Bundle.main.bundleIdentifier)
        let keys = [Settings.Name.isButtonHapticFeedbackEnabled.rawValue,
                    Settings.Name.isThumbstickHapticFeedbackEnabled.rawValue,
                    BoundAppearancePreferences.screenLayoutKey]
        let original = defaults.persistentDomain(forName: domain) ?? [:]
        defer {
            for key in keys {
                if let value = original[key] { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        // The hosted app registers the real native defaults during startup. Removing
        // only persisted choices exposes that registration without rerunning startup
        // (which also changes unrelated experimental/core preferences).
        for key in keys.prefix(2) { defaults.removeObject(forKey: key) }
        XCTAssertTrue(Settings.isButtonHapticFeedbackEnabled)
        XCTAssertTrue(Settings.isThumbstickHapticFeedbackEnabled)
        for key in keys.prefix(2) { XCTAssertNil(defaults.persistentDomain(forName: domain)?[key]) }
        Settings.isButtonHapticFeedbackEnabled = false
        Settings.isThumbstickHapticFeedbackEnabled = false
        let reopened = UserDefaults()
        for key in keys.prefix(2) { XCTAssertFalse(reopened.bool(forKey: key)) }
        let preferences = BoundAppearancePreferences()
        preferences.resetScreenLayout()
        XCTAssertFalse(Settings.isButtonHapticFeedbackEnabled)
        XCTAssertFalse(Settings.isThumbstickHapticFeedbackEnabled)
    }
    func testFeedbackUsesExistingDeltaSettingsAndNotifications() {
        let buttons = Settings.isButtonHapticFeedbackEnabled, sticks = Settings.isThumbstickHapticFeedbackEnabled
        defer { Settings.isButtonHapticFeedbackEnabled = buttons; Settings.isThumbstickHapticFeedbackEnabled = sticks }
        let expectation = expectation(forNotification: Settings.didChangeNotification, object: nil) { note in
            (note.userInfo?[Settings.NotificationUserInfoKey.name] as? Settings.Name) == .isButtonHapticFeedbackEnabled
        }
        Settings.isButtonHapticFeedbackEnabled = false
        Settings.isThumbstickHapticFeedbackEnabled = false
        XCTAssertFalse(Settings.isButtonHapticFeedbackEnabled)
        XCTAssertFalse(Settings.isThumbstickHapticFeedbackEnabled)
        Settings.isButtonHapticFeedbackEnabled = true
        Settings.isThumbstickHapticFeedbackEnabled = true
        XCTAssertTrue(Settings.isButtonHapticFeedbackEnabled)
        XCTAssertTrue(Settings.isThumbstickHapticFeedbackEnabled)
        wait(for: [expectation], timeout: 1)
    }
}

extension AppearanceIntegrationTests {
    func testBackendDetailsComeFromSelectedGBAIntegration() throws {
        let core = try XCTUnwrap(DeltaCore.Delta.core(for: System.gba.gameType))
        let details = BoundEmulationDetails(packageName: core.name, packageIdentifier: core.identifier, packageVersion: core.version)
        XCTAssertEqual(details.packageName, "GBADeltaCore")
        XCTAssertEqual(details.packageIdentifier, "com.rileytestut.GBADeltaCore")
        XCTAssertNil(core.version, "Pinned wrapper exposes no release version; source revision must be used")
        XCTAssertEqual(details.packageBuild, "Pinned source 869c34aeca9d")
        XCTAssertEqual(details.engineName, "VBA-M")
        XCTAssertEqual(details.engineRevision, "453fa0decf179360926fb417725a794aa496d6e3")
    }
}

@MainActor final class GameImportPolicyTests: XCTestCase {
    func testSupportedExtensionsAndUnsupportedDataAreValidatedAfterPicker() async throws {
        XCTAssertEqual(GameType(fileExtension: "gba"), System.gba.gameType)
        XCTAssertEqual(GameType(fileExtension: "GBA"), System.gba.gameType)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = try Set(["txt", "pdf", "sav"].map { ext -> URL in
            let url = directory.appendingPathComponent("Unsupported.\(ext)")
            try Data("Original unsupported test data".utf8).write(to: url)
            return url
        })
        let result = await withCheckedContinuation { continuation in
            DatabaseManager.shared.importGames(at: urls) { games, errors in
                continuation.resume(returning: (games, errors))
            }
        }
        XCTAssertTrue(result.0.isEmpty)
        XCTAssertEqual(result.1.count, urls.count)
    }
}

@MainActor final class ArchiveSecurityTests: XCTestCase {
    private func makeArchive(at url: URL, entries: [(String, ZIPFoundation.Entry.EntryType, Data)]) throws {
        let archive = try ZIPFoundation.Archive(url: url, accessMode: .create)
        for (path, type, data) in entries {
            try archive.addEntry(with: path, type: type, uncompressedSize: Int64(data.count)) { position, size in
                data.subdata(in: Int(position)..<min(Int(position) + size, data.count))
            }
        }
    }

    func testTraversalAndEscapingSymlinksCannotWriteOutsideDestination() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let sentinel = outside.appendingPathComponent("sentinel.gba")
        let original = Data("Original sentinel".utf8)
        try original.write(to: sentinel)
        let cases: [[(String, ZIPFoundation.Entry.EntryType, Data)]] = [
            [("../outside/sentinel.gba", .file, Data("bad".utf8))],
            [("/../outside/sentinel.gba", .file, Data("bad".utf8))],
            [("escape", .symlink, Data("../outside".utf8)), ("escape/sentinel.gba", .file, Data("bad".utf8))],
            [("escape", .symlink, Data(outside.path.utf8)), ("escape/sentinel.gba", .file, Data("bad".utf8))]
        ]
        for (index, entries) in cases.enumerated() {
            let zip = base.appendingPathComponent("attack-\(index).zip")
            let destination = base.appendingPathComponent("destination-\(index)", isDirectory: true)
            try makeArchive(at: zip, entries: entries)
            XCTAssertThrowsError(try FileManager.default.unzipItem(at: zip, to: destination))
            XCTAssertEqual(try Data(contentsOf: sentinel), original)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), ["sentinel.gba"])
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("escape").path))
        }
        let normal = base.appendingPathComponent("normal.zip")
        try makeArchive(at: normal, entries: [("folder/game.gba", .file, original)])
        let destination = base.appendingPathComponent("normal", isDirectory: true)
        try FileManager.default.unzipItem(at: normal, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("folder/game.gba")), original)
    }

    func testROMImportRejectsSymlinkAndTraversalButImportsNormalGBAAndZIP() async throws {
        // Hosted tests can begin before the asynchronous launch condition finishes.
        // Import needs the actual persistent store, not test-order timing.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DatabaseManager.shared.start { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let sentinel = base.appendingPathComponent("sentinel.gba")
        let original = Data("Untouched sentinel".utf8); try original.write(to: sentinel)
        let attack = base.appendingPathComponent("attack.zip")
        try makeArchive(at: attack, entries: [
            ("malicious.gba", .symlink, Data(sentinel.path.utf8)),
            ("../sentinel.gba", .file, Data("bad".utf8)),
            ("/../sentinel.gba", .file, Data("bad".utf8))
        ])
        let rejected = await withCheckedContinuation { continuation in
            DatabaseManager.shared.importGames(at: [attack]) { continuation.resume(returning: ($0, $1)) }
        }
        XCTAssertTrue(rejected.0.isEmpty); XCTAssertFalse(rejected.1.isEmpty)
        XCTAssertEqual(try Data(contentsOf: sentinel), original)
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "BoundDiagnostic", withExtension: "gba"))
        for zipped in [false, true] {
            let bytes = try Data(contentsOf: fixture) + Data(UUID().uuidString.utf8)
            let source = base.appendingPathComponent(zipped ? "normal.zip" : "normal.gba")
            if zipped { try makeArchive(at: source, entries: [("normal.gba", .file, bytes)]) }
            else { try bytes.write(to: source) }
            let imported = await withCheckedContinuation { continuation in
                DatabaseManager.shared.importGames(at: [source]) { continuation.resume(returning: ($0, $1)) }
            }
            XCTAssertTrue(imported.1.isEmpty); XCTAssertEqual(imported.0.count, 1)
            let game = try XCTUnwrap(imported.0.first)
            XCTAssertEqual(try Data(contentsOf: game.fileURL), bytes)
            DatabaseManager.shared.viewContext.delete(game)
            try DatabaseManager.shared.viewContext.save()
        }
    }
}
