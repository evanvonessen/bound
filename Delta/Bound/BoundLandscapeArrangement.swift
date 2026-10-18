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
        init(_ placement: BoundLandscapeViewPlacement) {
            center = placement.center; widthFraction = placement.widthFraction
            heightFraction = placement.heightFraction; opacity = placement.opacity
        }
        var placement: BoundLandscapeViewPlacement {
            BoundLandscapeViewPlacement(center: center, widthFraction: widthFraction,
                                        heightFraction: heightFraction, opacity: opacity)
        }
    }

    @Published private(set) var active = false
    @Published private(set) var option: BoundLandscapeOption = .option3
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
    private var persistedContents = Set<BoundPiPContent>()
    private var initializedDefaults = Set<BoundPiPContent>()
    private var defaultPlacements: [BoundPiPContent: State] = [:]
    private var draft: [BoundPiPContent: State]?
    private var gestureStart: (BoundPiPContent, State)?
    private var fadeStartOpacity: Double?
    private var boundButtonFrame: CGRect = .zero
    private var selectionBeforeArrangement: BoundPiPContent?
    private var layoutInput: (canvas: CGRect, occupied: [CGRect], menu: CGRect, bound: CGRect, defaults: [BoundPiPContent: CGRect], keyboard: CGFloat)?

    private func refreshLayout(avoidFriend: Bool = false) {
        if let input = layoutInput {
            updateLayout(canvas: input.canvas, occupied: input.occupied, menuFrame: input.menu,
                         boundFrame: input.bound, defaults: input.defaults, keyboardHeight: input.keyboard,
                         avoidFriend: avoidFriend)
        }
        needsLayout?()
    }

    var refined: Bool { option == .option4 }
    var placementShortcuts: Bool { option == .option5 }
    var focusedHandles: Bool { refined || placementShortcuts }
    var accessibilityPrefix: String { "bound.landscape\(option.rawValue)" }

    init(defaults: UserDefaults? = nil, namespace: String = "bound.landscape") {
        self.defaults = defaults ?? .standard
        self.namespace = namespace
        let contents = Self.nonFriend(BoundPiPContent.cycleOrder)
        self.contents = contents
        self.selected = contents.first ?? .notes
        self.referenceContent = contents.first ?? .notes
        self.friendVisible = self.defaults.object(forKey: namespace + ".option3.friend-visible") as? Bool ?? true
        self.referenceVisible = self.defaults.object(forKey: namespace + ".option3.reference-visible") as? Bool ?? true
        self.referenceContent = Self.readContent(self.defaults, key: namespace + ".option3.reference-content", allowed: contents) ?? contents.first ?? .notes
        self.selected = self.referenceContent
        readPlacements()
    }

    /// New variants start as an Option 3 snapshot, then save independently. Keeping
    /// one observable session also keeps the live video canvas and gestures mounted.
    func useOption(_ value: BoundLandscapeOption) {
        guard value.supportsArrangement, option != value else { return }
        finish(save: false, resume: false)
        if active { beforeSwitch?() }
        let destination = namespace + ".option\(value.rawValue)"
        if value != .option3, !defaults.bool(forKey: destination + ".initialized") {
            let suffixes = ["friend-visible", "reference-visible", "reference-content"]
                + BoundPiPContent.allCases.map { "placement." + $0.rawValue }
            for suffix in suffixes {
                if let saved = defaults.object(forKey: namespace + ".option3." + suffix) {
                    defaults.set(saved, forKey: destination + "." + suffix)
                }
            }
            defaults.set(true, forKey: destination + ".initialized")
        }
        option = value
        editorAtTop = false
        friendVisible = defaults.object(forKey: key("friend-visible")) as? Bool ?? true
        referenceVisible = defaults.object(forKey: key("reference-visible")) as? Bool ?? true
        referenceContent = Self.readContent(defaults, key: key("reference-content"), allowed: contents) ?? contents.first ?? .notes
        selected = referenceContent
        readPlacements()
        layoutInput = nil
        needsLayout?()
    }

    private func readPlacements() {
        saved.removeAll()
        persistedContents.removeAll()
        initializedDefaults.removeAll()
        defaultPlacements.removeAll()
        for content in BoundPiPContent.allCases {
            let placementKey = key("placement." + content.rawValue)
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
        let normalized = Self.nonFriend(values)
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
                      avoidFriend: Bool = false) {
        layoutInput = (canvas, occupied, menuFrame, boundFrame, defaultFrames, keyboardHeight)
        let insetCanvas = canvas.insetBy(dx: 4, dy: 4)
        for content in BoundPiPContent.allCases {
            if var frame = defaultFrames[content], insetCanvas.width > 0, insetCanvas.height > 0 {
                if content == .friend, let reference = defaultFrames[referenceContent] {
                    // Start on the opposite side so the reference cannot hide Friend.
                    let x = insetCanvas.minX + insetCanvas.maxX - reference.midX
                    frame.origin.x = x - frame.width / 2
                }
                let initial = State(BoundLandscapeViewPlacement(
                    center: BoundLandscapeGeometry.normalizedCenter(frame: frame, canvas: insetCanvas),
                    widthFraction: frame.width / insetCanvas.width,
                    heightFraction: frame.height / insetCanvas.height,
                    opacity: 1))
                defaultPlacements[content] = initial
                if !persistedContents.contains(content) && !initializedDefaults.contains(content) {
                    initializedDefaults.insert(content)
                    saved[content] = initial
                }
            }
        }
        var next = Layout()
        next.canvas = insetCanvas
        next.doneButton = menuFrame
        boundButtonFrame = boundFrame
        let buttonSize: CGFloat = 44
        let friendCenter = CGPoint(x: insetCanvas.minX + insetCanvas.maxX - menuFrame.midX,
                                   y: menuFrame.midY)
        let viewsCenter = CGPoint(x: insetCanvas.minX + insetCanvas.maxX - boundFrame.midX,
                                  y: boundFrame.midY)
        next.friendButton = CGRect(x: friendCenter.x - buttonSize / 2, y: friendCenter.y - buttonSize / 2,
                                   width: buttonSize, height: buttonSize).intersection(insetCanvas)
        next.viewsButton = CGRect(x: viewsCenter.x - buttonSize / 2, y: viewsCenter.y - buttonSize / 2,
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
                            canvas: insetCanvas, base: defaultFrames[.friend])

        let availableHeight = max(100, insetCanvas.height - max(0, keyboardHeight))
        let referenceCanvas = CGRect(x: insetCanvas.minX, y: insetCanvas.minY,
                                     width: insetCanvas.width, height: min(insetCanvas.height, availableHeight))
        let state = current[referenceContent] ?? State(Self.defaultState(for: referenceContent))
        let base = defaultFrames[referenceContent] ?? CGRect(origin: .zero, size: defaultSize(for: referenceContent, canvas: referenceCanvas))
        let desired = CGSize(width: max(160, referenceCanvas.width * state.widthFraction),
                             height: max(110, referenceCanvas.height * state.heightFraction))
        let initialSeparation = (!persistedContents.contains(referenceContent) && !editing) || avoidFriend
        let obstacles = occupied + (initialSeparation ? [next.friend.insetBy(dx: -4, dy: -4)] : []) + [next.friendButton.insetBy(dx: -4, dy: -4),
                                    next.viewsButton.insetBy(dx: -4, dy: -4),
                                    menuFrame.insetBy(dx: -2, dy: -2), boundFrame.insetBy(dx: -2, dy: -2)]
        next.reference = BoundLandscapeGeometry.referenceFrame(canvas: referenceCanvas,
                        preferredCenter: state.center, preferredSize: desired,
                        occupied: obstacles, minimumSize: CGSize(width: 160, height: 110)) ??
                        fallbackReference(base: base, canvas: referenceCanvas, occupied: obstacles)
        if initialSeparation, !editing, !next.reference.isEmpty {
            var resolved = state
            resolved.center = BoundLandscapeGeometry.normalizedCenter(frame: next.reference, canvas: insetCanvas)
            resolved.widthFraction = next.reference.width / insetCanvas.width
            resolved.heightFraction = next.reference.height / insetCanvas.height
            saved[referenceContent] = resolved
        }
        if layout != next { layout = next }
    }

    func toggleFriend() { friendVisible.toggle(); defaults.set(friendVisible, forKey: key("friend-visible")); needsLayout?() }
    func toggleReference() { referenceVisible.toggle(); defaults.set(referenceVisible, forKey: key("reference-visible")); needsLayout?() }

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
        let canvas = layout.canvas
        guard canvas.width > 0, canvas.height > 0 else { return }
        value.center = CGPoint(x: clamp(start.center.x + translation.width / canvas.width),
                               y: clamp(start.center.y + translation.height / canvas.height))
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
        let dx = translation.width / max(1, layout.canvas.width)
        let dy = translation.height / max(1, layout.canvas.height)
        switch axis {
        case .width:
            if content == .friend {
                setFriendWidth(clamp(start.widthFraction + dx), on: &value)
            } else {
                value.widthFraction = clamp(start.widthFraction + dx)
            }
        case .height:
            if content == .friend {
                let requestedWidth = (start.heightFraction + dy) * layout.canvas.height / max(1, layout.canvas.width) * 1.5
                setFriendWidth(requestedWidth, on: &value)
            } else {
                value.heightFraction = clamp(start.heightFraction + dy)
            }
        case .scale:
            let pixelWidth = max(1, layout.canvas.width * start.widthFraction)
            let pixelHeight = max(1, layout.canvas.height * start.heightFraction)
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
        guard !frame.isEmpty, layout.canvas.width > 0, layout.canvas.height > 0 else { return value }
        value.center = BoundLandscapeGeometry.normalizedCenter(frame: frame, canvas: layout.canvas)
        value.widthFraction = frame.width / layout.canvas.width
        value.heightFraction = frame.height / layout.canvas.height
        return value
    }
    private func state(for content: BoundPiPContent) -> State {
        draft?[content] ?? saved[content] ?? State(Self.defaultState(for: content))
    }
    private func setDraft(_ state: State, for content: BoundPiPContent) {
        if draft == nil { draft = saved }
        objectWillChange.send()
        draft?[content] = state
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
        let canvasAspect = layout.canvas.width / max(1, layout.canvas.height)
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
    private func fallbackReference(base: CGRect, canvas: CGRect, occupied: [CGRect]) -> CGRect {
        let size = CGSize(width: min(base.width, canvas.width), height: min(base.height, canvas.height))
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
        defaults.set(data, forKey: key("placement." + content.rawValue))
    }
    private func key(_ suffix: String) -> String { namespace + ".option\(option.rawValue)." + suffix }
    private static func readState(_ defaults: UserDefaults, key: String) -> State? {
        guard let data = defaults.data(forKey: key), let state = try? JSONDecoder().decode(State.self, from: data) else { return nil }
        return State(state.placement)
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
    private func unit(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 1 }
}

private extension CGRect {
    func intersection(in rect: CGRect) -> CGRect {
        let result = intersection(rect)
        return result.isNull ? .zero : result
    }
}
