import SwiftUI
import UIKit
import Combine

@MainActor
final class BoundLandscapeMultiviewSwipeGesture: NSObject, UIGestureRecognizerDelegate {
    private weak var view: UIView?
    private weak var model: BoundLandscapeArrangementModel?
    private lazy var recognizer: UIPanGestureRecognizer = {
        let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        recognizer.delegate = self
        recognizer.minimumNumberOfTouches = 1
        recognizer.maximumNumberOfTouches = 1
        return recognizer
    }()

    init(view: UIView, model: BoundLandscapeArrangementModel) {
        self.view = view
        self.model = model
        super.init()
        view.addGestureRecognizer(recognizer)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard let view, let model, model.active, model.option == .option6,
              model.referenceVisible, !model.editing,
              model.layout.reference.contains(touch.location(in: view)) else { return false }

        var ancestor = touch.view
        while let candidate = ancestor, candidate !== view {
            if let scrollView = candidate as? UIScrollView, scrollView.isScrollEnabled,
               scrollView.alwaysBounceHorizontal ||
                scrollView.contentSize.width + scrollView.adjustedContentInset.left + scrollView.adjustedContentInset.right > scrollView.bounds.width + 0.5 {
                return false
            }
            ancestor = candidate.superview
        }
        return true
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer, let view else { return false }
        let velocity = pan.velocity(in: view)
        return abs(velocity.x) > 20 && abs(velocity.x) > abs(velocity.y) * 1.5
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let scrollView = otherGestureRecognizer.view as? UIScrollView,
              otherGestureRecognizer === scrollView.panGestureRecognizer,
              scrollView.isScrollEnabled else { return false }
        let verticallyScrollable = scrollView.alwaysBounceVertical ||
            scrollView.contentSize.height + scrollView.adjustedContentInset.top + scrollView.adjustedContentInset.bottom > scrollView.bounds.height + 0.5
        let horizontallyScrollable = scrollView.alwaysBounceHorizontal ||
            scrollView.contentSize.width + scrollView.adjustedContentInset.left + scrollView.adjustedContentInset.right > scrollView.bounds.width + 0.5
        return verticallyScrollable && !horizontallyScrollable
    }

    @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
        guard recognizer.state == .ended, let view, let model,
              model.active, model.option == .option6, model.referenceVisible, !model.editing else { return }
        let translation = recognizer.translation(in: view)
        guard abs(translation.x) > 40, abs(translation.x) > abs(translation.y) * 1.5,
              let index = model.contents.firstIndex(of: model.referenceContent) else { return }
        let destination = index + (translation.x < 0 ? 1 : -1)
        guard model.contents.indices.contains(destination) else { return }
        model.select(model.contents[destination])
    }
}

/// Option 2 owns its presentation state; the original panel selection, gestures,
/// and placement preferences remain available unchanged when returning to Option 1.
@MainActor
final class BoundLandscapeCompanionModel: ObservableObject {
    struct Layout: Equatable {
        var canvas = CGRect.zero
        var friend = CGRect.zero
        var reference = CGRect.zero
        var friendButton = CGRect.zero
        var viewsButton = CGRect.zero
        var editor = CGRect.zero
    }
    let preferences: BoundLandscapePreferences
    @Published private(set) var active = false
    @Published private(set) var editing = false
    @Published private(set) var layout = Layout()
    @Published private(set) var draft: BoundLandscapeFriendPlacement
    @Published private(set) var friendVisible: Bool
    @Published private(set) var referenceVisible: Bool
    @Published private(set) var referenceContent: BoundPiPContent
    @Published private(set) var referenceContents: [BoundPiPContent]
    var needsLayout: (() -> Void)?
    var beforeSwitch: (() -> Void)?
    var beginArrangement: (() -> Bool)?
    var endArrangement: ((_ resume: Bool) -> Void)?
    private var observation: AnyCancellable?
    private var friendDragStart: CGRect?
    private var referenceDragStart: CGRect?
    private var liveReferenceCenter: CGPoint?
    private var layoutInput: (canvas: CGRect, occupied: [CGRect], shoulder: CGRect?, keyboard: CGFloat)?

    private func refreshLayout() {
        if let input = layoutInput {
            updateLayout(canvas: input.canvas, occupied: input.occupied, leftShoulder: input.shoulder, keyboardHeight: input.keyboard)
        }
        needsLayout?()
    }

    init(preferences: BoundLandscapePreferences? = nil) {
        let preferences = preferences ?? BoundLandscapePreferences()
        self.preferences = preferences
        draft = preferences.friendPlacement
        friendVisible = preferences.friendVisible
        referenceVisible = preferences.referenceVisible
        referenceContent = preferences.referenceContent
        referenceContents = preferences.referenceContents
        observation = NotificationCenter.default.publisher(for: BoundLandscapePreferences.didChangeNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.reload() }
    }
    func reload() {
        if !editing { draft = preferences.friendPlacement; friendVisible = preferences.friendVisible }
        referenceVisible = preferences.referenceVisible
        referenceContent = preferences.referenceContent
        referenceContents = preferences.referenceContents
        refreshLayout()
    }
    func setActive(_ value: Bool) {
        guard active != value else { return }
        if !value { finishArrangement(save: false) }
        active = value
        friendDragStart = nil; referenceDragStart = nil; liveReferenceCenter = nil
        reload()
    }
    func updateLayout(canvas: CGRect, occupied: [CGRect], leftShoulder: CGRect?, keyboardHeight: CGFloat) {
        layoutInput = (canvas, occupied, leftShoulder, keyboardHeight)
        guard active, canvas.width > 0, canvas.height > 0 else { return }
        var next = Layout()
        next.canvas = canvas.insetBy(dx: 4, dy: 4)
        let obstacles = occupied.filter { !$0.isEmpty && !$0.isNull }.map { $0.insetBy(dx: -3, dy: -3) }
        let preferred = CGPoint(x: leftShoulder?.midX ?? canvas.minX + 26,
                                y: (leftShoulder?.maxY ?? canvas.minY + 44) + 10 + 48)
        let normalized = CGPoint(x: (preferred.x - canvas.minX) / canvas.width,
                                 y: (preferred.y - canvas.minY) / canvas.height)
        if let pair = BoundLandscapeGeometry.referenceFrame(canvas: next.canvas, preferredCenter: normalized,
                preferredSize: CGSize(width: 44, height: 96), occupied: obstacles,
                minimumSize: CGSize(width: 44, height: 96)) {
            next.friendButton = CGRect(origin: pair.origin, size: CGSize(width: 44, height: 44))
            next.viewsButton = next.friendButton.offsetBy(dx: 0, dy: 52)
        } else {
            next.friendButton = BoundLandscapeGeometry.referenceFrame(canvas: next.canvas, preferredCenter: normalized,
                preferredSize: CGSize(width: 44, height: 44), occupied: obstacles,
                minimumSize: CGSize(width: 44, height: 44)) ?? .zero
            next.viewsButton = BoundLandscapeGeometry.referenceFrame(canvas: next.canvas,
                preferredCenter: CGPoint(x: normalized.x, y: normalized.y + 0.15), preferredSize: CGSize(width: 44, height: 44),
                occupied: obstacles + [next.friendButton.insetBy(dx: -4, dy: -4)],
                minimumSize: CGSize(width: 44, height: 44)) ?? .zero
        }
        next.friend = BoundLandscapeGeometry.friendFrame(canvas: next.canvas, placement: draft)
        var referenceCanvas = next.canvas
        if keyboardHeight > 0 {
            referenceCanvas.size.height = max(0, min(referenceCanvas.height, canvas.maxY - keyboardHeight - referenceCanvas.minY - 4))
        }
        let width = min(360, max(260, canvas.width * 0.44)) * preferences.referenceScale
        let height: CGFloat = referenceContent == .types ? width : referenceContent == .dex ? width * 0.83 + 32 : width * 0.72 + 32
        let requested = CGSize(width: width, height: keyboardHeight > 0 ? min(height, referenceCanvas.height) : height)
        next.reference = BoundLandscapeGeometry.referenceFrame(canvas: referenceCanvas,
            preferredCenter: liveReferenceCenter ?? preferences.referenceCenter, preferredSize: requested,
            occupied: obstacles + [next.friendButton.insetBy(dx: -4, dy: -4), next.viewsButton.insetBy(dx: -4, dy: -4)],
            minimumSize: CGSize(width: 220, height: keyboardHeight > 0 ? 76 : 150)) ?? .zero
        let editorSize = CGSize(width: min(420, canvas.width - 16), height: min(160, canvas.height - 16))
        next.editor = CGRect(x: canvas.midX - editorSize.width / 2, y: canvas.maxY - editorSize.height - 8,
                             width: editorSize.width, height: editorSize.height)
        if layout != next { layout = next }
    }
    /// The enclosing UIKit overlay must also yield: disabling only SwiftUI's
    /// gesture does not make an otherwise full-screen hosting view touch-through.
    func receivesTouch(at point: CGPoint) -> Bool {
        guard active else { return false }
        if editing { return true } // Gameplay is paused until Save or Cancel.
        if layout.friendButton.contains(point) || layout.viewsButton.contains(point) { return true }
        return referenceVisible && !referenceContents.isEmpty && layout.reference.contains(point)
    }
    func toggleFriend() {
        guard !editing else { return }
        beforeSwitch?()
        preferences.friendVisible.toggle(); reload()
    }
    func cycleViews() {
        guard !editing else { return }
        beforeSwitch?()
        guard !referenceContents.isEmpty else {
            UIAccessibility.post(notification: .announcement, argument: "Choose landscape views in Interface & Companion settings.")
            return
        }
        if referenceVisible {
            let next = ((referenceContents.firstIndex(of: referenceContent) ?? 0) + 1) % referenceContents.count
            preferences.referenceContent = referenceContents[next]
        }
        preferences.referenceVisible = true; reload()
        if layout.reference.isEmpty {
            UIAccessibility.post(notification: .announcement, argument: "There is no clear space for a reference view. Move game controls in Settings.")
        }
    }
    func selectReference(_ content: BoundPiPContent) {
        guard !editing, referenceContents.contains(content) else { return }
        beforeSwitch?(); preferences.referenceContent = content; preferences.referenceVisible = true; reload()
    }
    func hideReference() {
        guard !editing else { return }
        beforeSwitch?(); preferences.referenceVisible = false; reload()
    }
    func arrangeFriend() {
        guard active, !editing, beginArrangement?() != false else { return }
        draft = preferences.friendPlacement; friendVisible = true; editing = true
        friendDragStart = nil; refreshLayout()
    }
    func finishArrangement(save: Bool, resume: Bool = true) {
        guard editing else { return }
        if save {
            draft.center = BoundLandscapeGeometry.normalizedCenter(frame: layout.friend, canvas: layout.canvas)
            preferences.friendPlacement = draft
            preferences.friendVisible = true
        }
        editing = false; friendDragStart = nil
        reload(); endArrangement?(resume)
        if save { UIAccessibility.post(notification: .announcement, argument: "Friend screen locked. Game controls work through it.") }
    }
    func moveFriend(_ translation: CGSize, ended: Bool) {
        guard editing, layout.canvas.width > 0, layout.canvas.height > 0 else { return }
        if friendDragStart == nil { friendDragStart = layout.friend }
        if let start = friendDragStart {
            draft.center = BoundLandscapeGeometry.normalizedCenter(frame: start.offsetBy(dx: translation.width, dy: translation.height), canvas: layout.canvas)
        }
        if ended { friendDragStart = nil }
        refreshLayout()
    }
    func nudgeFriend(dx: CGFloat, dy: CGFloat) {
        guard editing else { return }
        draft.center = BoundLandscapeGeometry.normalizedCenter(frame: layout.friend.offsetBy(dx: dx, dy: dy), canvas: layout.canvas)
        refreshLayout()
    }
    func setSize(_ value: Double) { draft.widthFraction = CGFloat(value); refreshLayout() }
    func setOpacity(_ value: Double) { draft.opacity = CGFloat(value); refreshLayout() }
    func moveReference(_ translation: CGSize, ended: Bool) {
        guard !editing, !layout.reference.isEmpty else { return }
        if referenceDragStart == nil { referenceDragStart = layout.reference }
        if let start = referenceDragStart {
            liveReferenceCenter = BoundLandscapeGeometry.normalizedCenter(frame: start.offsetBy(dx: translation.width, dy: translation.height), canvas: layout.canvas)
        }
        refreshLayout()
        if ended {
            preferences.referenceCenter = BoundLandscapeGeometry.normalizedCenter(frame: layout.reference, canvas: layout.canvas)
            referenceDragStart = nil; liveReferenceCenter = nil; refreshLayout()
        }
    }
}

/// A single permanent remote canvas avoids reparenting the live video between
/// separate hosting controllers on rotation or while changing landscape options.
struct BoundCompanionPresentation: View {
    @ObservedObject var sharing: FriendSharingSession
    @ObservedObject var state: BoundCompanionState
    @ObservedObject var landscape: BoundLandscapeCompanionModel
    @ObservedObject var arrangement: BoundLandscapeArrangementModel
    var gameID: String
    let editingChanged: (Bool) -> Void
    var textEditingChanged: (Bool) -> Void = { _ in }
    var currentSave: (String) throws -> BoundRRDexSave

    private var legacyFriend: Bool { !state.availableContents.isEmpty && state.content == .friend }
    private var showsFriend: Bool {
        arrangement.active ? (arrangement.friendVisible || arrangement.editing) : landscape.active ? landscape.friendVisible : legacyFriend
    }
    private var showsArrangementReference: Bool {
        (arrangement.referenceVisible || arrangement.editing) && !arrangement.contents.isEmpty && !arrangement.layout.reference.isEmpty
    }
    private var showsReference: Bool {
        landscape.referenceVisible && !landscape.referenceContents.isEmpty && !landscape.layout.reference.isEmpty
    }
    private var usesMultiviewTabs: Bool { arrangement.active && arrangement.option == .option7 }
    var body: some View {
        GeometryReader { geometry in
            let legacyFrame = CGRect(origin: .zero, size: geometry.size)
            let friendFrame = arrangement.active ? arrangement.layout.friend : landscape.active ? landscape.layout.friend : legacyFrame
            let reference = arrangement.active ? arrangement.layout.reference : landscape.active ? landscape.layout.reference : legacyFrame
            let headerHeight: CGFloat = usesMultiviewTabs ? 44 : landscape.active ? 32 : 0
            ZStack(alignment: .topLeading) {
                friendVideo
                    .frame(width: max(0, friendFrame.width), height: max(0, friendFrame.height))
                    .clipShape(RoundedRectangle(cornerRadius: state.landscape ? 8 : 4))
                    .opacity(showsFriend ? (arrangement.active ? arrangement.opacity(for: .friend) : landscape.active ? Double(landscape.draft.opacity) : 1) : 0)
                    .allowsHitTesting(!arrangement.active && !landscape.active && showsFriend)
                    .accessibilityHidden(true)
                    .offset(x: friendFrame.minX, y: friendFrame.minY)

                // Keep the live UIKit canvas mounted, but add its semantic
                // element only while visible. UIKit video descendants otherwise
                // remain discoverable beneath SwiftUI's opacity/hidden modifiers.
                if showsFriend {
                    Color.clear
                        .frame(width: friendFrame.width, height: friendFrame.height)
                        .accessibilityElement()
                        .accessibilityIdentifier(arrangement.active ? arrangement.accessibilityPrefix + "-friend" : landscape.active ? "bound.landscape-friend" : "bound.friend-screen")
                        .accessibilityLabel("Friend screen")
                        .accessibilityValue(arrangement.active ? (arrangement.editing ? "Arranging" : "Locked, touches pass through") : landscape.active ? (landscape.editing ? "Moving" : "Locked, touches pass through") : "")
                        .allowsHitTesting(false)
                        .offset(x: friendFrame.minX, y: friendFrame.minY)
                }

                // One retained content owner, with the tab bar outside its scroll views.
                // Composite the bar and background together so saved opacity applies once.
                VStack(spacing: 0) {
                    if usesMultiviewTabs {
                        Group {
                            if showsArrangementReference && !arrangement.editing {
                                multiviewTabs
                            } else {
                                Color.clear.accessibilityHidden(true)
                            }
                        }
                        .frame(height: headerHeight)
                    }
                    BoundCompanionPanel(sharing: sharing, state: state, gameID: gameID,
                        editingChanged: editingChanged, textEditingChanged: textEditingChanged, currentSave: currentSave,
                        contentOverride: arrangement.active ? arrangement.referenceContent : landscape.active ? landscape.referenceContent : nil,
                        presentationEnabled: arrangement.active ? showsArrangementReference : !landscape.active || showsReference,
                        rendersFriend: false, inlineDexSearch: arrangement.active && arrangement.multiview)
                        .frame(width: max(0, reference.width), height: max(0, reference.height - headerHeight))
                        .allowsHitTesting(arrangement.active ? showsArrangementReference && !arrangement.editing : landscape.active ? showsReference && !landscape.editing : !legacyFriend)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier(arrangement.active ? (showsArrangementReference && !arrangement.editing ? arrangement.accessibilityPrefix + "-reference-content" : "") : landscape.active ? "bound.landscape-reference-content" : "bound.companion-content")
                        .accessibilityValue(arrangement.active && arrangement.multiview ? arrangement.referenceContent.title : "")
                        .accessibilityHidden(arrangement.active ? !showsArrangementReference || arrangement.editing : landscape.active ? !showsReference || landscape.editing : legacyFriend)
                }
                .frame(width: max(0, reference.width), height: max(0, reference.height - (landscape.active ? headerHeight : 0)))
                .background {
                    if usesMultiviewTabs {
                        RoundedRectangle(cornerRadius: 8).fill(Color(uiColor: .systemBackground))
                    }
                }
                .compositingGroup()
                .opacity(arrangement.active ? (showsArrangementReference ? arrangement.opacity(for: arrangement.referenceContent) : 0) : landscape.active ? (showsReference ? (landscape.editing ? 0.35 : 1) : 0) : (legacyFriend ? 0 : 1))
                .offset(x: reference.minX, y: reference.minY + (landscape.active ? headerHeight : 0))

                if arrangement.active { BoundLandscapeArrangementOverlay(model: arrangement) }
                if landscape.active {
                    if showsReference { referenceHeader.frame(width: reference.width, height: headerHeight).offset(x: reference.minX, y: reference.minY) }
                    if landscape.editing {
                        RoundedRectangle(cornerRadius: 8).stroke(Color.purple, lineWidth: 3)
                            .background(Color.clear.contentShape(Rectangle()))
                            .overlay(alignment: .topLeading) { Text("Drag to move").font(.caption).padding(6).background(.ultraThinMaterial, in: Capsule()).padding(6).allowsHitTesting(false) }
                            .frame(width: friendFrame.width, height: friendFrame.height)
                            .contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 0).onChanged { landscape.moveFriend($0.translation, ended: false) }
                                .onEnded { landscape.moveFriend($0.translation, ended: true) })
                            .accessibilityLabel("Move friend screen")
                            .accessibilityIdentifier("bound.landscape-friend-move")
                            .offset(x: friendFrame.minX, y: friendFrame.minY)
                    }
                    if !landscape.layout.friendButton.isEmpty { friendButton.positioned(in: landscape.layout.friendButton) }
                    if !landscape.layout.viewsButton.isEmpty { viewsButton.positioned(in: landscape.layout.viewsButton) }
                    if landscape.editing { editor.positioned(in: landscape.layout.editor) }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
    }
    private var multiviewTabs: some View {
        HStack(spacing: 0) {
            multiviewTab("DEX", content: .dex)
            multiviewTab("DOCS", content: .bosses)
            multiviewTab("TYPES", content: .types)
        }
        .background(Color(uiColor: .systemBackground))
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8))
        .overlay(alignment: .bottom) { Divider().allowsHitTesting(false) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bound.landscape7-tabs")
    }
    private func multiviewTab(_ title: String, content: BoundPiPContent) -> some View {
        let selected = arrangement.referenceContent == content
        return Button { arrangement.select(content) } label: {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.9)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(selected ? Color(uiColor: .deltaPurple) : .secondary)
                .background(selected ? Color(uiColor: .deltaPurple).opacity(0.12) : .clear)
                .overlay(alignment: .bottom) {
                    if selected { Color(uiColor: .deltaPurple).frame(height: 3) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(content == .bosses ? "Shows Boss View" : "Shows \(content.title)")
        .accessibilityIdentifier("bound.landscape7-tab-" + content.rawValue)
    }
    private var friendVideo: some View {
        ZStack {
            Color.black
            BoundRemoteCanvas(view: sharing.remoteView, hidesAccessibilityChildren: true).opacity(sharing.remoteVisible || state.displaysFixtureVideo ? 1 : 0)
            if !sharing.remoteVisible && !state.displaysFixtureVideo {
                Text(sharing.active ? "Waiting for friend" : "Connect a friend").foregroundStyle(.white).font(.callout)
            }
        }
    }
    private var friendButton: some View {
        Button(action: landscape.toggleFriend) {
            Image(systemName: "person.2.fill")
                .overlay(alignment: .bottomTrailing) {
                    if landscape.friendVisible && !landscape.editing {
                        Image(systemName: "lock.fill").font(.system(size: 9, weight: .semibold))
                            .padding(3).background(Color(uiColor: .deltaPurple), in: Circle()).offset(x: 8, y: 8)
                    }
                }
        }
        .landscapeButtonStyle(selected: landscape.friendVisible)
        .accessibilityLabel("Friend")
        .accessibilityValue(landscape.friendVisible ? "Visible, locked" : "Hidden")
        .accessibilityHint("Shows or hides Friend. Hold to arrange the screen.")
        .accessibilityIdentifier("bound.landscape-friend-button")
        .accessibilityAction(named: "Arrange friend screen", landscape.arrangeFriend)
        .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in landscape.arrangeFriend() })
        .disabled(landscape.editing)
    }
    private var viewsButton: some View {
        Button(action: landscape.cycleViews) { Image(systemName: "rectangle.on.rectangle") }
            .landscapeButtonStyle(selected: showsReference)
            .accessibilityLabel("Views")
            .accessibilityValue(showsReference ? landscape.referenceContent.title : "Hidden")
            .accessibilityHint("Cycles selected reference views.")
            .accessibilityIdentifier("bound.landscape-views-button")
            .disabled(landscape.editing)
    }
    private var referenceHeader: some View {
        HStack(spacing: 8) {
            Label(landscape.referenceContent.title, systemImage: "line.3.horizontal")
                .font(.caption.weight(.medium))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .gesture(DragGesture().onChanged { landscape.moveReference($0.translation, ended: false) }
                    .onEnded { landscape.moveReference($0.translation, ended: true) })
                .accessibilityLabel("Move \(landscape.referenceContent.title) view")
                .accessibilityIdentifier("bound.landscape-reference-handle")
            Button(action: landscape.hideReference) { Image(systemName: "xmark").font(.caption.weight(.semibold)).frame(width: 32, height: 32) }
                .buttonStyle(.plain).accessibilityLabel("Hide reference view")
        }
        .padding(.leading, 10)
        .background(Color(uiColor: .secondarySystemBackground))
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8))
        .opacity(landscape.editing ? 0.35 : 1)
        .allowsHitTesting(!landscape.editing)
        .accessibilityHidden(landscape.editing)
    }
    private var editor: some View {
        VStack(spacing: 8) {
            HStack { Text("Arrange friend screen").font(.headline); Spacer(); Text("Paused").font(.caption).foregroundStyle(.secondary) }
            HStack {
                Text("Size").font(.caption)
                Slider(value: Binding(get: { Double(landscape.draft.widthFraction) }, set: landscape.setSize), in: 0.15...0.6)
                    .accessibilityLabel("Friend size").accessibilityIdentifier("bound.landscape-friend-size")
                Text("Opacity").font(.caption)
                Slider(value: Binding(get: { Double(landscape.draft.opacity) }, set: landscape.setOpacity), in: 0.35...1)
                    .accessibilityLabel("Friend opacity")
            }
            HStack(spacing: 4) {
                nudge("arrow.left", label: "Move left", dx: -1, dy: 0)
                nudge("arrow.up", label: "Move up", dx: 0, dy: -1)
                nudge("arrow.down", label: "Move down", dx: 0, dy: 1)
                nudge("arrow.right", label: "Move right", dx: 1, dy: 0)
                Spacer(minLength: 2)
                Button("Cancel") { landscape.finishArrangement(save: false) }.accessibilityIdentifier("bound.landscape-cancel")
                Button("Save & Lock") { landscape.finishArrangement(save: true) }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("bound.landscape-save-lock")
            }.font(.subheadline)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bound.landscape-arrangement")
    }
    private func nudge(_ symbol: String, label: String, dx: CGFloat, dy: CGFloat) -> some View {
        Button { landscape.nudgeFriend(dx: dx, dy: dy) } label: { Image(systemName: symbol).frame(width: 32, height: 44) }
            .buttonStyle(.borderless).accessibilityLabel(label)
    }
}

private extension View {
    func positioned(in frame: CGRect) -> some View {
        self.frame(width: max(0, frame.width), height: max(0, frame.height)).offset(x: frame.minX, y: frame.minY)
    }
    func landscapeButtonStyle(selected: Bool) -> some View {
        self.buttonStyle(BoundLandscapeButtonStyle(selected: selected))
    }
}

private struct BoundLandscapeButtonStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 21, weight: .semibold))
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .foregroundStyle(.white)
            .background(Color(uiColor: .deltaPurple).opacity(selected ? 0.85 : 0.55), in: Circle())
            .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: 1.5))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct BoundLandscapeOptionsSettings: View {
    @State private var option = BoundLandscapePreferences().option
    @State private var contents = BoundLandscapePreferences().referenceContents
    @State private var scale = BoundLandscapePreferences().referenceScale
    private let preferences = BoundLandscapePreferences()
    var body: some View {
        Section {
            Picker("Landscape Options", selection: Binding(get: { option }, set: {
                option = $0; preferences.option = $0
            })) {
                ForEach(BoundLandscapeOption.allCases, id: \.rawValue) { Text($0.title).tag($0) }
            }
            .accessibilityIdentifier("bound.landscape-options")
        } header: { Text("Landscape Options") } footer: {
            Text((option == .option1 ? "The existing landscape controls and companion panel. Portrait stays unchanged."
                 : option == .option7 ? "Use the fixed DEX, DOCS, and TYPES tabs at the top of Multiview. DOCS opens Boss View. The book button under Menu opens Multiview; X hides it. Friend stays separate. Starts with a copy of Option 6 and saves separately. Portrait stays unchanged."
                 : option == .option6 ? "Swipe left or right in Multiview to switch between RR Dex, Bosses, and Types. The book button under Menu opens it; X hides it. Friend stays separate. Starts with a copy of Option 3 and saves separately. Portrait stays unchanged."
                 : option == .option5 ? "Open Menu and tap Arrange Views to quickly place a view in a corner, then drag to fine-tune. A compact toolbar stays opposite the selected view. VIEWS shows or hides references; Bound cycles them. Starts with a copy of Option 3 and saves separately. Portrait stays unchanged."
                 : option == .option4 ? "Open Menu and tap Arrange Views for direct view selection, larger handles for the selected view, and Reset. The eye button shows or hides references. Starts with a copy of Option 3, then saves its own layout. Portrait stays unchanged."
                 : option == .option3 ? "Friend and the selected reference appear independently. Friend toggles video, X toggles references, and Bound cycles the views selected in Companion settings. In landscape, open Menu and tap Arrange Views to move, resize, or change each view’s opacity. Done locks the layout; references stay interactive."
                 : "Separate Friend and Views buttons. Hold Friend to position, resize, and lock it. Locked friend video lets touches reach the controls underneath. Portrait stays unchanged.")
                 + (option.supportsArrangement ? " Arrangements save separately for Controller Mode on and off." : ""))
        }
        if option == .option2 {
            Section {
                ForEach(BoundPiPContent.cycleOrder.filter { $0 != .friend }, id: \.rawValue) { content in
                    Toggle(content.title, isOn: Binding(get: { contents.contains(content) }, set: { enabled in
                        contents.removeAll { $0 == content }
                        if enabled { contents.append(content) }
                        preferences.referenceContents = contents
                    })).accessibilityIdentifier("bound.landscape-enabled.\(content.rawValue)")
                }
                Slider(value: Binding(get: { scale }, set: { scale = $0; preferences.referenceScale = $0 }), in: 0.8...1.3, step: 0.05) {
                    Text("Reference size")
                }.accessibilityIdentifier("bound.landscape-reference-size")
                Text("Reference size: \(Int(scale * 100))% \u{00b7} fitted to clear space").font(.footnote).foregroundStyle(.secondary)
            } header: { Text("Landscape Views") } footer: {
                Text("Views cycles through these selections, separately from Friend. Reference views remain interactive and avoid game controls. These choices apply only to landscape Option 2.")
            }
        }
    }
}
