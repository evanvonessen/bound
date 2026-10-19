import Foundation
import CoreGraphics
import Combine
import UIKit

/// Persisted, normalized geometry and opacity for one landscape companion view.
struct BoundLandscapeViewPlacement: Codable, Equatable, Sendable {
    var center: CGPoint
    var widthFraction: CGFloat
    var heightFraction: CGFloat
    var opacity: Double

    init(center: CGPoint = CGPoint(x: 0.5, y: 0.35), widthFraction: CGFloat = 0.34,
         heightFraction: CGFloat = 0.55, opacity: Double = 1) {
        self.center = CGPoint(x: Self.unit(center.x, fallback: 0.5), y: Self.unit(center.y, fallback: 0.35))
        self.widthFraction = Self.unit(widthFraction, fallback: 0.34)
        self.heightFraction = Self.unit(heightFraction, fallback: 0.55)
        self.opacity = Self.unit(opacity, fallback: 1)
    }

    private static func unit(_ value: CGFloat, fallback: CGFloat) -> CGFloat {
        value.isFinite ? min(1, max(0, value)) : fallback
    }
    private static func unit(_ value: Double, fallback: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : fallback
    }
}

@MainActor
final class BoundLandscapeArrangementModel: ObservableObject {
    enum ResizeAxis { case width, height, scale }
    enum Corner: String, CaseIterable {
        case topLeft, topRight, bottomLeft, bottomRight
        var center: CGPoint {
            CGPoint(x: self == .topLeft || self == .bottomLeft ? 0 : 1,
                    y: self == .topLeft || self == .topRight ? 0 : 1)
        }
        var title: String {
            switch self {
            case .topLeft: "Top left"
            case .topRight: "Top right"
            case .bottomLeft: "Bottom left"
            case .bottomRight: "Bottom right"
            }
        }
        var symbol: String {
            switch self {
            case .topLeft: "arrow.up.left"
            case .topRight: "arrow.up.right"
            case .bottomLeft: "arrow.down.left"
            case .bottomRight: "arrow.down.right"
            }
        }
    }

    struct Layout: Equatable {
        var canvas: CGRect = .zero
        var friendCanvas: CGRect = .zero
        var friend: CGRect = .zero
        var reference: CGRect = .zero
        var friendButton: CGRect = .zero
        var viewsButton: CGRect = .zero
        var doneButton: CGRect = .zero
        var opacityZone: CGRect = .zero
    }

    private struct State: Codable, Equatable {
        var center: CGPoint
        var widthFraction: CGFloat
        var heightFraction: CGFloat
        var opacity: Double
        var aboveButtons: Bool
        var allowsButtonOverlap: Bool
        var friendUsesScreenCanvas: Bool
        var controllerModeTwoDefaultFriend: Bool
        init(_ placement: BoundLandscapeViewPlacement) {
            center = placement.center; widthFraction = placement.widthFraction
            heightFraction = placement.heightFraction; opacity = placement.opacity
            aboveButtons = true
            allowsButtonOverlap = false
            friendUsesScreenCanvas = false
            controllerModeTwoDefaultFriend = false
        }
        var placement: BoundLandscapeViewPlacement {
            BoundLandscapeViewPlacement(center: center, widthFraction: widthFraction,
                                        heightFraction: heightFraction, opacity: opacity)
        }
        private enum CodingKeys: String, CodingKey {
            case center, widthFraction, heightFraction, opacity, aboveButtons, allowsButtonOverlap,
                 friendUsesScreenCanvas, controllerModeTwoDefaultFriend
        }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            center = try container.decode(CGPoint.self, forKey: .center)
            widthFraction = try container.decode(CGFloat.self, forKey: .widthFraction)
            heightFraction = try container.decode(CGFloat.self, forKey: .heightFraction)
            opacity = try container.decode(Double.self, forKey: .opacity)
            aboveButtons = try container.decodeIfPresent(Bool.self, forKey: .aboveButtons) ?? true
            allowsButtonOverlap = try container.decodeIfPresent(Bool.self, forKey: .allowsButtonOverlap) ?? false
            friendUsesScreenCanvas = try container.decodeIfPresent(Bool.self, forKey: .friendUsesScreenCanvas) ?? false
            controllerModeTwoDefaultFriend = try container.decodeIfPresent(Bool.self, forKey: .controllerModeTwoDefaultFriend) ?? false
        }
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(center, forKey: .center)
            try container.encode(widthFraction, forKey: .widthFraction)
            try container.encode(heightFraction, forKey: .heightFraction)
            try container.encode(opacity, forKey: .opacity)
            try container.encode(aboveButtons, forKey: .aboveButtons)
            try container.encode(allowsButtonOverlap, forKey: .allowsButtonOverlap)
            try container.encode(friendUsesScreenCanvas, forKey: .friendUsesScreenCanvas)
            try container.encode(controllerModeTwoDefaultFriend, forKey: .controllerModeTwoDefaultFriend)
        }
    }

    @Published private(set) var active = false
    @Published private(set) var option: BoundLandscapeOption = .option3
    @Published private(set) var controllerModeEnabled = false
    @Published private(set) var controllerModeLayout: BoundControllerModeLayout = .mode1
    @Published private(set) var editing = false
    @Published private(set) var editorAtTop = false
    @Published private(set) var friendVisible: Bool
    @Published private(set) var referenceVisible: Bool
    @Published private(set) var referenceContent: BoundPiPContent
    @Published private(set) var contents: [BoundPiPContent]
    @Published private(set) var selected: BoundPiPContent
    @Published private(set) var layout = Layout()

    var needsLayout: (() -> Void)?
    var beforeSwitch: (() -> Void)?
    var beginArrangement: (() -> Bool)?
    var endArrangement: ((Bool) -> Void)?

    private let defaults: UserDefaults
    private let namespace: String
    private var saved: [BoundPiPContent: State] = [:]
    private var configuredContents: [BoundPiPContent] = []
    private var persistedContents = Set<BoundPiPContent>()
    private var initializedDefaults = Set<BoundPiPContent>()
    private var defaultPlacements: [BoundPiPContent: State] = [:]
    private var draft: [BoundPiPContent: State]?
    private var gestureStart: (BoundPiPContent, State)?
    private var fadeStartOpacity: Double?
    private var boundButtonFrame: CGRect = .zero
    private var selectionBeforeArrangement: BoundPiPContent?
    private var layoutInput: (canvas: CGRect, occupied: [CGRect], menu: CGRect, bound: CGRect, defaults: [BoundPiPContent: CGRect], keyboard: CGFloat, screenBounds: CGRect?, friendButton: CGRect?, viewsButton: CGRect?)?

    private func refreshLayout(avoidFriend: Bool = false) {
        if let input = layoutInput {
            updateLayout(canvas: input.canvas, occupied: input.occupied, menuFrame: input.menu,
                         boundFrame: input.bound, defaults: input.defaults, keyboardHeight: input.keyboard,
                         screenBounds: input.screenBounds,
                         friendButtonFrame: input.friendButton, viewsButtonFrame: input.viewsButton,
                         avoidFriend: avoidFriend)
        }
        needsLayout?()
    }

    var refined: Bool { option == .option4 }
    var placementShortcuts: Bool { option == .option5 }
    var focusedHandles: Bool { refined || placementShortcuts }
    var multiview: Bool { option == .option6 || option == .option7 }
    var tabbedMultiview: Bool { option == .option7 }
    var accessibilityPrefix: String { "bound.landscape\(option.rawValue)" }

    private static let multiviewContents: [BoundPiPContent] = [.dex, .bosses, .types]

    init(defaults: UserDefaults? = nil, namespace: String = "bound.landscape") {
        self.defaults = defaults ?? .standard
        self.namespace = namespace
        let contents = Self.nonFriend(BoundPiPContent.cycleOrder)
        self.configuredContents = contents
        self.contents = contents
        self.selected = contents.first ?? .notes
        self.referenceContent = contents.first ?? .notes
        self.friendVisible = self.defaults.object(forKey: namespace + ".option3.friend-visible") as? Bool ?? true
        self.referenceVisible = self.defaults.object(forKey: namespace + ".option3.reference-visible") as? Bool ?? true
        self.referenceContent = Self.readContent(self.defaults, key: namespace + ".option3.reference-content", allowed: contents) ?? contents.first ?? .notes
        self.selected = self.referenceContent
        migrateControllerModeArrangements()
        readPlacements()
    }

    /// New variants start as an Option 3 snapshot, then save independently. Keeping
    /// one observable session also keeps the live video canvas and gestures mounted.
    func useOption(_ value: BoundLandscapeOption, controllerModeEnabled: Bool = false,
                   controllerModeLayout: BoundControllerModeLayout = .mode1) {
        let effectiveControllerLayout = controllerModeEnabled ? controllerModeLayout : .mode1
        guard value.supportsArrangement,
              option != value || self.controllerModeEnabled != controllerModeEnabled
                || self.controllerModeLayout != effectiveControllerLayout else { return }
        finish(save: false, resume: false)
        if active { beforeSwitch?() }
        if self.controllerModeEnabled != controllerModeEnabled {
            self.controllerModeEnabled = controllerModeEnabled
            // Snapshot fallbacks must come from the destination mode, never the
            // previous mode's in-memory placement or unsaved geometry.
            readPlacements()
        }
        if self.controllerModeLayout != effectiveControllerLayout {
            self.controllerModeLayout = effectiveControllerLayout
            readPlacements()
        }
        let destination = arrangementNamespace + ".option\(value.rawValue)"
        if value != .option3, !defaults.bool(forKey: destination + ".initialized") {
            if value == .option6 {
                initializeMultiviewSnapshot(destination: destination)
            } else if value == .option7 {
                initializeTabbedSnapshot(destination: destination)
            } else {
                let suffixes = ["friend-visible", "reference-visible", "reference-content"]
                    + BoundPiPContent.allCases.map { "placement." + $0.rawValue }
                for suffix in suffixes {
                    if let saved = defaults.object(forKey: arrangementNamespace + ".option3." + suffix) {
                        defaults.set(saved, forKey: destination + "." + suffix)
                    }
                }
                defaults.set(true, forKey: destination + ".initialized")
            }
        }
        option = value
        contents = value == .option6 || value == .option7 ? Self.multiviewContents : configuredContents
        editorAtTop = false
        friendVisible = defaults.object(forKey: key("friend-visible")) as? Bool ?? true
        referenceVisible = defaults.object(forKey: key("reference-visible")) as? Bool ?? true
        referenceContent = Self.readContent(defaults, key: key("reference-content"), allowed: contents) ?? contents.first ?? .notes
        selected = referenceContent
        readPlacements()
        layoutInput = nil
        needsLayout?()
    }

    private func initializeMultiviewSnapshot(destination: String) {
        let option3 = arrangementNamespace + ".option3."
        let modeTwoNeedsGeometryDefault = controllerModeEnabled && controllerModeLayout == .mode2
        for suffix in ["friend-visible", "reference-visible", "placement.friend"] {
            if let value = defaults.object(forKey: option3 + suffix) {
                defaults.set(value, forKey: destination + "." + suffix)
            }
        }

        let allReferences = Self.nonFriend(BoundPiPContent.cycleOrder)
        let sourceContent = Self.readContent(defaults, key: option3 + "reference-content", allowed: allReferences)
            ?? Self.multiviewContents[0]
        let initialPage = Self.multiviewContents.contains(sourceContent) ? sourceContent : Self.multiviewContents[0]
        defaults.set(initialPage.rawValue, forKey: destination + ".reference-content")
        defaults.set(sourceContent.rawValue, forKey: destination + ".reference-layout-content")

        let savedReferenceState = Self.readState(defaults, key: option3 + "placement." + sourceContent.rawValue)
            ?? (option == .option3 && (!modeTwoNeedsGeometryDefault || persistedContents.contains(sourceContent)) ? saved[sourceContent] : nil)
        if let stateToCopy = savedReferenceState ?? (modeTwoNeedsGeometryDefault ? nil : State(Self.defaultState(for: sourceContent))),
           let data = try? JSONEncoder().encode(stateToCopy) {
            defaults.set(data, forKey: destination + ".placement.reference")
        }
        defaults.set(true, forKey: destination + ".initialized")
    }

    private func initializeTabbedSnapshot(destination: String) {
        let option6 = arrangementNamespace + ".option6."
        let option3 = arrangementNamespace + ".option3."
        let modeTwoNeedsGeometryDefault = controllerModeEnabled && controllerModeLayout == .mode2
        let allowed = Self.nonFriend(BoundPiPContent.cycleOrder)
        let option6Initialized = defaults.bool(forKey: option6 + "initialized")

        let sourceContent: BoundPiPContent
        let initialPage: BoundPiPContent
        let sharedState: State
        let hasSavedReferenceState: Bool
        if option6Initialized {
            sourceContent = Self.readContent(defaults, key: option6 + "reference-layout-content", allowed: allowed)
                ?? Self.readContent(defaults, key: option6 + "reference-content", allowed: Self.multiviewContents)
                ?? Self.multiviewContents[0]
            initialPage = Self.readContent(defaults, key: option6 + "reference-content", allowed: Self.multiviewContents)
                ?? Self.multiviewContents[0]
            let stored = (option == .option6 && (!modeTwoNeedsGeometryDefault || persistedContents.contains(.dex)) ? saved[.dex] : nil)
                ?? Self.readState(defaults, key: option6 + "placement.reference")
                ?? Self.readState(defaults, key: option3 + "placement." + sourceContent.rawValue)
            hasSavedReferenceState = stored != nil
            sharedState = stored ?? State(Self.defaultState(for: sourceContent))
        } else {
            sourceContent = Self.readContent(defaults, key: option3 + "reference-content", allowed: allowed)
                ?? Self.multiviewContents[0]
            initialPage = Self.multiviewContents.contains(sourceContent) ? sourceContent : Self.multiviewContents[0]
            let stored = Self.readState(defaults, key: option3 + "placement." + sourceContent.rawValue)
                ?? (option == .option3 && (!modeTwoNeedsGeometryDefault || persistedContents.contains(sourceContent)) ? saved[sourceContent] : nil)
            hasSavedReferenceState = stored != nil
            sharedState = stored ?? State(Self.defaultState(for: sourceContent))
        }

        for suffix in ["friend-visible", "reference-visible"] {
            let sourceKey = (option6Initialized ? option6 : option3) + suffix
            defaults.set(defaults.object(forKey: sourceKey) as? Bool ?? true,
                         forKey: destination + "." + suffix)
        }
        let friendSourceKey = (option6Initialized ? option6 : option3) + "placement.friend"
        let friendState = Self.readState(defaults, key: friendSourceKey)
            ?? (option == (option6Initialized ? .option6 : .option3) ? saved[.friend] : nil)
        if let friendState, let data = try? JSONEncoder().encode(friendState) {
            defaults.set(data, forKey: destination + ".placement.friend")
        }

        defaults.set(initialPage.rawValue, forKey: destination + ".reference-content")
        defaults.set(sourceContent.rawValue, forKey: destination + ".reference-layout-content")
        if (hasSavedReferenceState || !modeTwoNeedsGeometryDefault),
           let data = try? JSONEncoder().encode(sharedState) {
            defaults.set(data, forKey: destination + ".placement.reference")
        }
        defaults.set(true, forKey: destination + ".initialized")
    }

    private func readPlacements() {
        saved.removeAll()
        persistedContents.removeAll()
        initializedDefaults.removeAll()
        defaultPlacements.removeAll()
        for content in BoundPiPContent.allCases {
            let placementKey = multiview && Self.multiviewContents.contains(content)
                ? key("placement.reference") : key("placement." + content.rawValue)
            if let state = Self.readState(self.defaults, key: placementKey) {
                saved[content] = state
                persistedContents.insert(content)
            } else {
                saved[content] = State(Self.defaultState(for: content))
            }
        }
    }

    func setActive(_ value: Bool) {
        guard active != value else { return }
        if !value { finish(save: false, resume: false) }
        active = value
        needsLayout?()
    }

    func setContents(_ values: [BoundPiPContent]) {
        configuredContents = Self.nonFriend(values)
        let normalized = multiview ? Self.multiviewContents : configuredContents
        guard contents != normalized else { return }
        let referenceWasRemoved = !normalized.contains(referenceContent)
        if referenceWasRemoved && active { beforeSwitch?() }
        contents = normalized
        if !normalized.contains(selected) { selected = normalized.first ?? .notes }
        if !normalized.contains(referenceContent) { referenceContent = normalized.first ?? .notes }
        defaults.set(referenceContent.rawValue, forKey: key("reference-content"))
        needsLayout?()
    }

    func updateLayout(canvas: CGRect, occupied: [CGRect], menuFrame: CGRect, boundFrame: CGRect,
                      defaults defaultFrames: [BoundPiPContent: CGRect], keyboardHeight: CGFloat,
                      screenBounds: CGRect? = nil,
                      friendButtonFrame: CGRect? = nil, viewsButtonFrame: CGRect? = nil,
                      avoidFriend: Bool = false) {
        layoutInput = (canvas, occupied, menuFrame, boundFrame, defaultFrames, keyboardHeight,
                       screenBounds, friendButtonFrame, viewsButtonFrame)
        let insetCanvas = canvas.insetBy(dx: 4, dy: 4)
        let friendScreen = screenBounds.flatMap { $0.width > 0 && $0.height > 0 ? $0 : nil } ?? canvas
        let friendCanvas = multiview ? friendScreen : insetCanvas

        if multiview, insetCanvas.width > 0, insetCanvas.height > 0,
           friendCanvas.width > 0, friendCanvas.height > 0 {
            if persistedContents.contains(.friend), var state = saved[.friend], !state.friendUsesScreenCanvas {
                let oldFrame = frame(for: .friend, state: state, canvas: insetCanvas, base: defaultFrames[.friend])
                if !oldFrame.isEmpty {
                    state.center = BoundLandscapeGeometry.normalizedCenter(frame: oldFrame, canvas: friendCanvas)
                    state.widthFraction = oldFrame.width / friendCanvas.width
                    state.heightFraction = oldFrame.height / friendCanvas.height
                    state.friendUsesScreenCanvas = true
                    saved[.friend] = state
                    write(state, for: .friend)
                }
            }
        }
        for content in BoundPiPContent.allCases {
            let placementCanvas = content == .friend ? friendCanvas : insetCanvas
            if var frame = defaultFrames[content], placementCanvas.width > 0, placementCanvas.height > 0 {
                if content == .friend, !(controllerModeEnabled && controllerModeLayout == .mode2),
                   let reference = defaultFrames[referenceContent] {
                    // Start on the opposite side so the reference cannot hide Friend.
                    let x = placementCanvas.minX + placementCanvas.maxX - reference.midX
                    frame.origin.x = x - frame.width / 2
                }
                var initial = State(BoundLandscapeViewPlacement(
                    center: BoundLandscapeGeometry.normalizedCenter(frame: frame, canvas: placementCanvas),
                    widthFraction: frame.width / placementCanvas.width,
                    heightFraction: frame.height / placementCanvas.height,
                    opacity: 1))
                if content == .friend && multiview {
                    initial.friendUsesScreenCanvas = true
                    if controllerModeEnabled && controllerModeLayout == .mode2 {
                        initial.controllerModeTwoDefaultFriend = true
                    }
                }
                defaultPlacements[content] = initial
                if !persistedContents.contains(content) && !initializedDefaults.contains(content) {
                    initializedDefaults.insert(content)
                    saved[content] = initial
                }
            }
        }
        if controllerModeEnabled, controllerModeLayout == .mode2,
           let frame = defaultFrames[.friend], friendCanvas.width > 0, friendCanvas.height > 0 {
            var state = (draft ?? saved)[.friend] ?? State(Self.defaultState(for: .friend))
            if state.controllerModeTwoDefaultFriend {
                state.center = BoundLandscapeGeometry.normalizedCenter(frame: frame, canvas: friendCanvas)
                state.widthFraction = frame.width / friendCanvas.width
                state.heightFraction = frame.height / friendCanvas.height
                state.friendUsesScreenCanvas = true
                if draft != nil { draft?[.friend] = state } else { saved[.friend] = state }
            }
        }
        var next = Layout()
        next.canvas = insetCanvas
        next.friendCanvas = friendCanvas
        next.doneButton = menuFrame
        boundButtonFrame = boundFrame
        let buttonSize: CGFloat = 44
        let friendCenter = CGPoint(x: insetCanvas.minX + insetCanvas.maxX - menuFrame.midX,
                                   y: menuFrame.midY)
        let viewsCenter = CGPoint(x: multiview ? boundFrame.midX : insetCanvas.minX + insetCanvas.maxX - boundFrame.midX,
                                  y: boundFrame.midY)
        next.friendButton = friendButtonFrame ?? CGRect(x: friendCenter.x - buttonSize / 2, y: friendCenter.y - buttonSize / 2,
                                   width: buttonSize, height: buttonSize).intersection(insetCanvas)
        next.viewsButton = viewsButtonFrame ?? CGRect(x: viewsCenter.x - buttonSize / 2, y: viewsCenter.y - buttonSize / 2,
                                  width: buttonSize, height: buttonSize).intersection(insetCanvas)
        // The controls mirror MENU and BOUND across the screen center. If a device
        // reports unusual hit rectangles, keep the pair in-canvas and distinct.
        if next.friendButton.isEmpty || next.friendButton.intersects(next.viewsButton) {
            next.friendButton = CGRect(x: insetCanvas.minX + 8, y: insetCanvas.midY - 50, width: buttonSize, height: buttonSize)
            next.viewsButton = CGRect(x: insetCanvas.minX + 8, y: insetCanvas.midY + 6, width: buttonSize, height: buttonSize)
        }

        let opacityWidth = insetCanvas.width * 0.60
        let opacityHeight = insetCanvas.height * 0.65
        next.opacityZone = CGRect(x: insetCanvas.midX - opacityWidth / 2,
                                  y: insetCanvas.midY - opacityHeight / 2,
                                  width: opacityWidth, height: opacityHeight)

        let current = draft ?? saved
        next.friend = frame(for: .friend, state: current[.friend] ?? State(Self.defaultState(for: .friend)),
                            canvas: friendCanvas, base: defaultFrames[.friend])

        let availableHeight = max(100, insetCanvas.height - max(0, keyboardHeight))
        let referenceCanvas = CGRect(x: insetCanvas.minX, y: insetCanvas.minY,
                                     width: insetCanvas.width, height: min(insetCanvas.height, availableHeight))
        let geometryContent = multiview
            ? Self.readContent(defaults, key: key("reference-layout-content"), allowed: Self.nonFriend(BoundPiPContent.cycleOrder)) ?? Self.multiviewContents[0]
            : referenceContent
        let stateContent = multiview ? Self.multiviewContents[0] : geometryContent
        let state = current[stateContent] ?? current[referenceContent] ?? State(Self.defaultState(for: geometryContent))
        let base = defaultFrames[geometryContent] ?? CGRect(origin: .zero, size: defaultSize(for: geometryContent, canvas: referenceCanvas))
        let minimumReferenceHeight: CGFloat = tabbedMultiview
            ? min(154, max(110, referenceCanvas.height)) : 110
        let desired = CGSize(width: max(160, referenceCanvas.width * state.widthFraction),
                             height: max(minimumReferenceHeight, referenceCanvas.height * state.heightFraction))
        let initialSeparation = (!persistedContents.contains(referenceContent) && !editing) || avoidFriend
        let obstacles = occupied + (initialSeparation ? [next.friend.insetBy(dx: -4, dy: -4)] : []) + [next.friendButton.insetBy(dx: -4, dy: -4),
                                    next.viewsButton.insetBy(dx: -4, dy: -4),
                                    menuFrame.insetBy(dx: -2, dy: -2), boundFrame.insetBy(dx: -2, dy: -2)]
        let referenceObstacles = multiview && state.allowsButtonOverlap ? [] : obstacles
        next.reference = BoundLandscapeGeometry.referenceFrame(canvas: referenceCanvas,
                        preferredCenter: state.center, preferredSize: desired,
                        occupied: referenceObstacles, minimumSize: CGSize(width: 160, height: minimumReferenceHeight)) ??
                        fallbackReference(base: base, canvas: referenceCanvas, occupied: referenceObstacles,
                                         minimumHeight: tabbedMultiview ? minimumReferenceHeight : nil)
        if initialSeparation, !editing, !next.reference.isEmpty {
            var resolved = state
            resolved.center = BoundLandscapeGeometry.normalizedCenter(frame: next.reference, canvas: insetCanvas)
            resolved.widthFraction = next.reference.width / insetCanvas.width
            resolved.heightFraction = next.reference.height / insetCanvas.height
            if multiview {
                for content in Self.multiviewContents { saved[content] = resolved }
            } else {
                saved[referenceContent] = resolved
            }
        }
        if layout != next { layout = next }
    }

    func toggleFriend() { friendVisible.toggle(); defaults.set(friendVisible, forKey: key("friend-visible")); needsLayout?() }
    func toggleReference() { referenceVisible.toggle(); defaults.set(referenceVisible, forKey: key("reference-visible")); needsLayout?() }
    func toggleControllerFriend() {
        guard active, controllerModeEnabled, !editing else { return }
        toggleFriend()
    }
    func toggleControllerMultiview() {
        guard active, controllerModeEnabled, multiview, !editing, !contents.isEmpty else { return }
        toggleReference()
    }

    func aboveButtons(for content: BoundPiPContent) -> Bool { state(for: content).aboveButtons }

    /// Layer selection is available only while arranging Options 6 and 7.
    /// Choosing either layer also allows the shared reference panel to overlap
    /// native and companion controls instead of being moved away by the solver.
    func setAboveButtons(_ above: Bool, for content: BoundPiPContent) {
        guard editing, multiview else { return }
        var value = displayedState(for: content)
        value.aboveButtons = above
        value.allowsButtonOverlap = true
        setDraft(value, for: content)
        refreshLayout()
    }

    func cycleReference() {
        guard !contents.isEmpty else { return }
        let index = contents.firstIndex(of: referenceContent) ?? -1
        select(contents[(index + 1) % contents.count])
    }

    func arrange() {
        guard active, !editing, beginArrangement?() ?? true else { return }
        beforeSwitch?()
        selectionBeforeArrangement = referenceContent
        selected = contents.isEmpty ? .friend : referenceContent
        draft = saved
        editing = true
        updateEditorAnchor()
        needsLayout?()
    }

    func finish(save: Bool, resume: Bool = true) {
        guard editing else { return }
        if save, let draft {
            saved = draft
            for (content, state) in saved { write(state, for: content); persistedContents.insert(content) }
            if contents.contains(selected) { referenceContent = selected }
            defaults.set(referenceContent.rawValue, forKey: key("reference-content"))
        } else if let selectionBeforeArrangement {
            selected = selectionBeforeArrangement
            referenceContent = selectionBeforeArrangement
        }
        draft = nil
        selectionBeforeArrangement = nil
        editing = false
        gestureStart = nil
        fadeStartOpacity = nil
        endArrangement?(resume)
        needsLayout?()
    }

    func select(_ content: BoundPiPContent) {
        if content == .friend {
            guard editing, selected != .friend else { return }
            selected = .friend
            gestureStart = nil
            refreshLayout()
            updateEditorAnchor()
            return
        }
        guard contents.contains(content), referenceContent != content || selected != content else { return }
        let changesReference = referenceContent != content
        if changesReference { beforeSwitch?() }
        selected = content
        referenceContent = content
        if !editing { defaults.set(content.rawValue, forKey: key("reference-content")) }
        refreshLayout()
        updateEditorAnchor()
    }

    func move(content: BoundPiPContent, translation: CGSize, ended: Bool) {
        guard editing else { return }
        selectForEditing(content)
        var value = state(for: content)
        if gestureStart?.0 != content { gestureStart = (content, displayedState(for: content)) }
        let start = gestureStart?.1 ?? value
        let canvas = placementCanvas(for: content)
        guard canvas.width > 0, canvas.height > 0 else { return }
        if content == .friend && (translation.width != 0 || translation.height != 0) {
            value.controllerModeTwoDefaultFriend = false
        }
        let centerClamp: (CGFloat) -> CGFloat = content == .friend && multiview ? normalizedClamp : clamp
        value.center = CGPoint(x: centerClamp(start.center.x + translation.width / canvas.width),
                               y: centerClamp(start.center.y + translation.height / canvas.height))
        setDraft(value, for: content)
        refreshLayout()
        if ended {
            gestureStart = nil
            if content != .friend { persistResolvedReferencePosition(content) }
            updateEditorAnchor()
        }
    }

    func resize(content: BoundPiPContent, translation: CGSize, axis: ResizeAxis, ended: Bool) {
        guard editing else { return }
        selectForEditing(content)
        var value = state(for: content)
        if gestureStart?.0 != content { gestureStart = (content, displayedState(for: content)) }
        let start = gestureStart?.1 ?? value
        let canvas = placementCanvas(for: content)
        guard canvas.width > 0, canvas.height > 0 else { return }
        if content == .friend && (translation.width != 0 || translation.height != 0) {
            value.controllerModeTwoDefaultFriend = false
        }
        let dx = translation.width / max(1, canvas.width)
        let dy = translation.height / max(1, canvas.height)
        switch axis {
        case .width:
            if content == .friend {
                setFriendWidth(clamp(start.widthFraction + dx), on: &value)
            } else {
                value.widthFraction = clamp(start.widthFraction + dx)
            }
        case .height:
            if content == .friend {
                let requestedWidth = (start.heightFraction + dy) * canvas.height / max(1, canvas.width) * 1.5
                setFriendWidth(requestedWidth, on: &value)
            } else {
                value.heightFraction = clamp(start.heightFraction + dy)
            }
        case .scale:
            let pixelWidth = max(1, canvas.width * start.widthFraction)
            let pixelHeight = max(1, canvas.height * start.heightFraction)
            let minScale = max(0.08 / start.widthFraction, 0.08 / start.heightFraction)
            let maxScale = min(1 / start.widthFraction, 1 / start.heightFraction)
            let scale = min(maxScale, max(minScale, 1 + (translation.width + translation.height) / (pixelWidth + pixelHeight)))
            value.widthFraction = clamp(start.widthFraction * scale)
            value.heightFraction = clamp(start.heightFraction * scale)
        }
        setDraft(value, for: content)
        refreshLayout()
        if ended {
            gestureStart = nil
            if content != .friend { persistResolvedReferencePosition(content) }
            updateEditorAnchor()
        }
    }

    func cancelManipulation() { gestureStart = nil; updateEditorAnchor() }

    /// The same placement solver keeps interactive references clear of controls.
    /// Friend can occupy those corners because its locked surface passes touches through.
    func placeSelectedView(at corner: Corner) {
        guard placementShortcuts, editing else { return }
        gestureStart = nil
        fadeStartOpacity = nil
        var value = state(for: selected)
        value.center = corner.center
        setDraft(value, for: selected)
        refreshLayout()
        setDraft(displayedState(for: selected), for: selected)
        updateEditorAnchor()
    }

    private func updateEditorAnchor() {
        guard placementShortcuts, editing else { return }
        let frame = selected == .friend ? layout.friend : layout.reference
        // Move the toolbar only after selection or a completed manipulation,
        // so it never jumps between edges while a finger is dragging a view.
        let atTop = frame.midY > layout.canvas.midY
        if editorAtTop != atTop { editorAtTop = atTop }
    }

    func setOpacity(_ value: Double, for content: BoundPiPContent) {
        guard editing else { return }
        var state = state(for: content)
        state.opacity = unit(value)
        setDraft(state, for: content)
    }

    /// Reset is part of the arrangement draft, so Cancel restores the saved view.
    func resetSelectedView() {
        guard focusedHandles, editing else { return }
        gestureStart = nil
        fadeStartOpacity = nil
        setDraft(defaultPlacements[selected] ?? State(Self.defaultState(for: selected)), for: selected)
        refreshLayout(avoidFriend: selected != .friend)
        if selected != .friend { persistResolvedReferencePosition(selected) }
        updateEditorAnchor()
    }

    func fade(phase: UIGestureRecognizer.State, dy: CGFloat) {
        guard editing, layout.opacityZone.contains(CGPoint(x: layout.opacityZone.midX, y: layout.opacityZone.midY)) else { return }
        switch phase {
        case .began:
            gestureStart = nil
            fadeStartOpacity = state(for: selected).opacity
        case .changed:
            let start = fadeStartOpacity ?? opacity(for: selected)
            // Three-finger vertical drag is attached by the view layer. A 240pt
            // swipe traverses the full 0...1 opacity range.
            setOpacity(start - Double(dy / 240), for: selected)
        case .ended, .cancelled, .failed:
            fadeStartOpacity = nil
        default: break
        }
    }

    func opacity(for content: BoundPiPContent) -> Double { state(for: content).opacity }

    func receivesTouch(at point: CGPoint) -> Bool {
        guard active else { return false }
        if editing { return layout.doneButton.contains(point) || !boundButtonFrame.contains(point) }
        if layout.friendButton.contains(point) || layout.viewsButton.contains(point) { return true }
        guard !contents.isEmpty else { return false }
        return referenceVisible && !layout.reference.isEmpty && layout.reference.contains(point)
    }

    func placement(for content: BoundPiPContent) -> BoundLandscapeViewPlacement {
        (draft?[content] ?? saved[content] ?? State(Self.defaultState(for: content))).placement
    }

    private func displayedState(for content: BoundPiPContent) -> State {
        var value = state(for: content)
        let frame = content == .friend ? layout.friend : layout.reference
        let canvas = placementCanvas(for: content)
        guard !frame.isEmpty, canvas.width > 0, canvas.height > 0 else { return value }
        value.center = BoundLandscapeGeometry.normalizedCenter(frame: frame, canvas: canvas)
        value.widthFraction = frame.width / canvas.width
        value.heightFraction = frame.height / canvas.height
        return value
    }
    private func placementCanvas(for content: BoundPiPContent) -> CGRect {
        content == .friend && layout.friendCanvas.width > 0 ? layout.friendCanvas : layout.canvas
    }
    private func state(for content: BoundPiPContent) -> State {
        draft?[content] ?? saved[content] ?? State(Self.defaultState(for: content))
    }
    private func setDraft(_ state: State, for content: BoundPiPContent) {
        if draft == nil { draft = saved }
        objectWillChange.send()
        if multiview && content != .friend {
            for page in Self.multiviewContents { draft?[page] = state }
        } else {
            draft?[content] = state
        }
    }
    private func selectForEditing(_ content: BoundPiPContent) {
        guard selected != content else { return }
        if content == .friend {
            select(.friend)
        } else {
            select(content)
        }
    }
    private func setFriendWidth(_ requested: CGFloat, on state: inout State) {
        let canvas = layout.friendCanvas.width > 0 ? layout.friendCanvas : layout.canvas
        let canvasAspect = canvas.width / max(1, canvas.height)
        let minimum = max(0.08, 0.08 * 1.5 / canvasAspect)
        let maximum = min(1, 1.5 / canvasAspect)
        let width = min(maximum, max(minimum, requested))
        state.widthFraction = width
        state.heightFraction = width * canvasAspect / 1.5
    }
    private func frame(for content: BoundPiPContent, state: State, canvas: CGRect, base: CGRect?) -> CGRect {
        let size = base?.size ?? defaultSize(for: content, canvas: canvas)
        let width = min(canvas.width, max(content == .friend ? 120 : 160, canvas.width * state.widthFraction))
        let height = min(canvas.height, max(content == .friend ? 80 : 110, canvas.height * state.heightFraction))
        let aspect = content == .friend ? 1.5 : max(0.5, size.width / max(1, size.height))
        let fittedWidth = min(width, height * aspect)
        let fittedHeight = content == .friend ? fittedWidth / aspect : min(height, fittedWidth / aspect)
        let center = CGPoint(x: canvas.minX + state.center.x * canvas.width,
                             y: canvas.minY + state.center.y * canvas.height)
        return CGRect(x: min(max(center.x - fittedWidth / 2, canvas.minX), canvas.maxX - fittedWidth),
                      y: min(max(center.y - fittedHeight / 2, canvas.minY), canvas.maxY - fittedHeight),
                      width: fittedWidth, height: fittedHeight)
    }
    private func fallbackReference(base: CGRect, canvas: CGRect, occupied: [CGRect],
                                   minimumHeight: CGFloat? = nil) -> CGRect {
        let size = CGSize(width: min(canvas.width, minimumHeight == nil ? base.width : max(160, base.width)),
                          height: min(canvas.height, minimumHeight.map { max($0, base.height) } ?? base.height))
        let candidates = [CGPoint(x: canvas.midX, y: canvas.midY), CGPoint(x: canvas.minX + size.width/2, y: canvas.midY), CGPoint(x: canvas.maxX - size.width/2, y: canvas.midY)]
        for center in candidates {
            let rect = CGRect(x: center.x-size.width/2, y: center.y-size.height/2, width:size.width,height:size.height)
            if !occupied.contains(where: { $0.intersects(rect) }) { return rect }
        }
        return .zero
    }
    private func persistResolvedReferencePosition(_ content: BoundPiPContent) {
        guard content == referenceContent, !layout.reference.isEmpty else { return }
        var state = state(for: content)
        state.center = BoundLandscapeGeometry.normalizedCenter(frame: layout.reference, canvas: layout.canvas)
        state.widthFraction = layout.reference.width / max(1, layout.canvas.width)
        state.heightFraction = layout.reference.height / max(1, layout.canvas.height)
        setDraft(state, for: content)
    }
    private func write(_ state: State, for content: BoundPiPContent) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        let suffix = multiview && Self.multiviewContents.contains(content)
            ? "placement.reference" : "placement." + content.rawValue
        defaults.set(data, forKey: key(suffix))
    }
    private var arrangementNamespace: String {
        guard controllerModeEnabled else { return namespace }
        return controllerModeLayout == .mode2 ? namespace + ".controller-mode2" : namespace + ".controller-mode"
    }

    /// Keep the existing keys for Controller Mode off. On upgrade, preserve all
    /// saved variants in Controller Mode on too, then let the two sets diverge.
    private func migrateControllerModeArrangements() {
        let destination = namespace + ".controller-mode"
        guard !defaults.bool(forKey: destination + ".initialized") else { return }
        let savedValues = defaults.dictionaryRepresentation()
        for option in BoundLandscapeOption.allCases where option.supportsArrangement {
            let sourcePrefix = namespace + ".option\(option.rawValue)."
            for (key, value) in savedValues where key.hasPrefix(sourcePrefix) {
                let suffix = key.dropFirst(namespace.count)
                let destinationKey = destination + suffix
                if defaults.object(forKey: destinationKey) == nil {
                    defaults.set(value, forKey: destinationKey)
                }
            }
        }
        defaults.set(true, forKey: destination + ".initialized")
    }

    private func key(_ suffix: String) -> String { arrangementNamespace + ".option\(option.rawValue)." + suffix }
    private static func readState(_ defaults: UserDefaults, key: String) -> State? {
        guard let data = defaults.data(forKey: key), let state = try? JSONDecoder().decode(State.self, from: data) else { return nil }
        var normalized = state
        let placement = state.placement
        normalized.center = placement.center
        normalized.widthFraction = placement.widthFraction
        normalized.heightFraction = placement.heightFraction
        normalized.opacity = placement.opacity
        return normalized
    }
    private static func readContent(_ defaults: UserDefaults, key: String, allowed: [BoundPiPContent]) -> BoundPiPContent? {
        guard let raw = defaults.string(forKey: key), let content = BoundPiPContent(rawValue: raw),
              content != .friend, allowed.contains(content) else { return nil }
        return content
    }
    private static func nonFriend(_ values: [BoundPiPContent]) -> [BoundPiPContent] {
        var seen = Set<BoundPiPContent>()
        return values.filter { $0 != .friend && seen.insert($0).inserted }
    }
    private static func defaultState(for content: BoundPiPContent) -> BoundLandscapeViewPlacement {
        switch content {
        case .friend: BoundLandscapeViewPlacement(center: CGPoint(x: 0.75, y: 0.3), widthFraction: 0.28, heightFraction: 0.187, opacity: 1)
        case .dex: BoundLandscapeViewPlacement(center: CGPoint(x: 0.5, y: 0.34), widthFraction: 0.36, heightFraction: 0.72)
        case .bosses: BoundLandscapeViewPlacement(center: CGPoint(x: 0.5, y: 0.34), widthFraction: 0.36, heightFraction: 0.68)
        case .notes, .types: BoundLandscapeViewPlacement(center: CGPoint(x: 0.5, y: 0.34), widthFraction: 0.36, heightFraction: 0.65)
        }
    }
    private func defaultSize(for content: BoundPiPContent, canvas: CGRect) -> CGSize {
        let ratio: CGFloat = content == .bosses ? 260.0 / 360.0 : content == .dex ? 300.0 / 360.0 : 0.9
        let width = min(canvas.width * 0.42, canvas.height * ratio)
        return CGSize(width: width, height: width / ratio)
    }
    private func clamp(_ value: CGFloat) -> CGFloat { value.isFinite ? min(1, max(0.08, value)) : 0.5 }
    private func normalizedClamp(_ value: CGFloat) -> CGFloat { value.isFinite ? min(1, max(0, value)) : 0.5 }
    private func unit(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 1 }
}

private extension CGRect {
    func intersection(in rect: CGRect) -> CGRect {
        let result = intersection(rect)
        return result.isNull ? .zero : result
    }
}
