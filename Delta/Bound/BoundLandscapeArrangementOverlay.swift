import SwiftUI
import UIKit

struct BoundLandscapeArrangementOverlay: View {
    @ObservedObject var model: BoundLandscapeArrangementModel
    var showsEditor = true
    var showsButtons = true
    private var multiview: Bool { model.multiview }
    private func title(for content: BoundPiPContent) -> String {
        multiview && content != .friend ? "Multiview" : content.title
    }
    var body: some View {
        ZStack(alignment: .topLeading) {
            if showsEditor && model.editing {
                moveTarget(.friend, frame: model.layout.friend).zIndex(model.selected == .friend ? 1 : 0)
                if !model.contents.isEmpty { moveTarget(model.referenceContent, frame: model.layout.reference).zIndex(model.selected == .friend ? 0 : 1) }
                if !multiview {
                    Group {
                        if model.placementShortcuts { placementEditor }
                        else if model.refined { refinedEditor }
                        else { editor }
                    }
                    .placed(arrangementEditorFrame(for: model)).zIndex(2)
                }
                if model.movableControllerButtons {
                    buttonAlignmentGuides.allowsHitTesting(false).zIndex(2)
                    buttonMoveTarget(.friend).zIndex(4)
                    buttonMoveTarget(.multiview).zIndex(4)
                }
                Button { model.finish(save: true) } label: {
                    Text("DONE").font(.system(size: 11, weight: .heavy))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .foregroundStyle(.white)
                        .background(Color(uiColor: .deltaPurple), in: Circle())
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Done arranging views")
                .accessibilityIdentifier(model.accessibilityPrefix + "-done")
                .placed(model.layout.doneButton).zIndex(3)
                if model.movableControllerButtons { buttonMoveTarget(.menu).zIndex(4) }
            }
            if showsButtons && !model.menuOnlyControllerMode {
              Button(action: model.toggleFriend) { Image(systemName: "person.2.fill") }
                .buttonStyle(ArrangementButtonStyle(selected: model.friendVisible))
                .accessibilityLabel("Friend")
                .accessibilityValue(model.friendVisible ? "Visible" : "Hidden")
                .accessibilityHint("Shows or hides only the friend screen.")
                .accessibilityIdentifier(model.accessibilityPrefix + "-friend-button")
                .disabled(model.editing)
                .placed(model.layout.friendButton).zIndex(3)
            Button(action: model.toggleReference) {
                if multiview {
                    Image(systemName: model.referenceVisible ? "xmark" : "book")
                } else if model.placementShortcuts {
                    Text("VIEWS").font(.system(size: 10, weight: .heavy))
                } else {
                    Image(systemName: model.refined ? (model.referenceVisible ? "eye" : "eye.slash") : "xmark")
                }
            }
                .buttonStyle(ArrangementButtonStyle(selected: model.referenceVisible))
                .accessibilityLabel(multiview ? (model.referenceVisible ? "Hide multiview" : "Show multiview") : model.focusedHandles ? (model.referenceVisible ? "Hide views" : "Show views") : "Toggle views")
                .accessibilityValue(model.referenceVisible ? "Visible" : "Hidden")
                .accessibilityHint(model.option == .option7 ? "Shows or hides Multiview. Use the DEX, DOCS, and TYPES tabs to switch views." : multiview ? "Shows or hides Multiview. Swipe left or right inside it to switch views." : "Shows or hides the selected reference view. Bound changes the selection.")
                .accessibilityIdentifier(model.accessibilityPrefix + "-views-button")
                .disabled(model.editing || model.contents.isEmpty)
                .placed(model.layout.viewsButton).zIndex(3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var buttonAlignmentGuides: some View {
        Path { path in
            if let x = model.buttonAlignmentX {
                path.move(to: CGPoint(x: x, y: model.layout.canvas.minY))
                path.addLine(to: CGPoint(x: x, y: model.layout.canvas.maxY))
            }
            if let y = model.buttonAlignmentY {
                path.move(to: CGPoint(x: model.layout.canvas.minX, y: y))
                path.addLine(to: CGPoint(x: model.layout.canvas.maxX, y: y))
            }
        }.stroke(Color.cyan, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
    }

    private func buttonMoveTarget(_ button: BoundControllerButton) -> some View {
        ZStack {
            if button != .menu {
                Circle().fill(Color(uiColor: .deltaPurple))
                Image(systemName: button == .friend ? "person.2.fill" : (model.referenceVisible ? "xmark" : "book"))
                    .font(.system(size: 18, weight: .bold)).foregroundStyle(.white)
            }
            Circle().stroke(.white, lineWidth: 2)
            ArrangementDragTarget(identifier: "bound.controller-button-move." + button.rawValue,
                label: "Move " + (button == .friend ? "Friend" : button == .multiview ? "Multiview" : "Menu"),
                select: { if button == .menu { model.finish(save: true) } },
                cancelled: model.cancelControllerButtonMove) {
                    model.moveControllerButton(button, translation: $0, ended: $1)
                }
        }.placed(model.buttonFrame(button))
    }

    private func moveTarget(_ content: BoundPiPContent, frame: CGRect) -> some View {
        let selected = model.selected == content
        return ZStack {
            RoundedRectangle(cornerRadius: 8)
                .stroke(selected ? Color.purple : Color.white.opacity(model.focusedHandles ? 0.5 : 1), lineWidth: selected ? 3 : 1.5)
                .allowsHitTesting(false)
            ArrangementDragTarget(identifier: model.accessibilityPrefix + "-move.\(content.rawValue)", label: "Move \(title(for: content))",
                                  value: "Opacity \(Int((model.opacity(for: content) * 100).rounded()))%", selected: selected,
                                  select: { model.select(content) }, cancelled: model.cancelManipulation) {
                model.move(content: content, translation: $0, ended: $1)
            }
        }
            .overlay(alignment: .topLeading) {
                Text(title(for: content)).font(.caption.weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule()).padding(5).allowsHitTesting(false)
            }
            .overlay(alignment: .topTrailing) {
                if multiview && selected {
                    HStack(spacing: 4) {
                        layerButton(content, above: true)
                        layerButton(content, above: false)
                    }
                    .padding(5)
                }
            }
            .overlay(alignment: .trailing) {
                if (!model.focusedHandles || selected) && (content == .bosses || content == .dex || (multiview && content != .friend)) {
                    resizeHandle(content, axis: .width, symbol: "arrow.left.and.right", name: "width")
                }
            }
            .overlay(alignment: .bottom) {
                if (!model.focusedHandles || selected) && (content == .bosses || content == .dex || (multiview && content != .friend)) {
                    resizeHandle(content, axis: .height, symbol: "arrow.up.and.down", name: "height")
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !model.focusedHandles || selected {
                    resizeHandle(content, axis: .scale, symbol: "arrow.up.left.and.arrow.down.right", name: "scale")
                }
            }
            .placed(frame)
    }
    private func layerButton(_ content: BoundPiPContent, above: Bool) -> some View {
        let active = model.aboveButtons(for: content) == above
        return Button { model.setAboveButtons(above, for: content) } label: {
            Image(systemName: above ? "arrow.up" : "arrow.down")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(active ? Color(uiColor: .deltaPurple) : Color.black.opacity(0.65),
                            in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(.white.opacity(active ? 1 : 0.4)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(above ? "Bring \(title(for: content)) in front of buttons" : "Put \(title(for: content)) behind buttons")
        .accessibilityAddTraits(active ? .isSelected : [])
        .accessibilityIdentifier(model.accessibilityPrefix + (above ? "-layer-front." : "-layer-back.") + content.rawValue)
    }
    private func resizeHandle(_ content: BoundPiPContent, axis: BoundLandscapeArrangementModel.ResizeAxis,
                              symbol: String, name: String) -> some View {
        Image(systemName: symbol).font(.system(size: 14, weight: .bold))
            .foregroundStyle(.white).frame(width: model.focusedHandles ? 44 : 36, height: model.focusedHandles ? 44 : 36)
            .background(model.focusedHandles ? Color(uiColor: .deltaPurple).opacity(0.9) : Color.purple, in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                ArrangementDragTarget(identifier: model.accessibilityPrefix + "-resize-\(name).\(content.rawValue)",
                                      label: "Resize \(title(for: content)) \(name)", select: { model.select(content) },
                                      cancelled: model.cancelManipulation) {
                    model.resize(content: content, translation: $0, axis: axis, ended: $1)
                }
            }
    }
    private var editor: some View {
        VStack(spacing: 5) {
            HStack(spacing: 8) {
                selection(.friend)
                if !model.contents.isEmpty { selection(model.referenceContent) }
                Spacer(minLength: 0)
                Button("Cancel") { model.finish(save: false) }
                    .accessibilityIdentifier(model.accessibilityPrefix + "-cancel")
            }
            HStack(spacing: 8) {
                Text("Opacity").font(.caption)
                Slider(value: Binding(get: { model.opacity(for: model.selected) },
                                      set: { model.setOpacity($0, for: model.selected) }), in: 0...1)
                    .accessibilityLabel("\(title(for: model.selected)) opacity")
                    .accessibilityIdentifier(model.accessibilityPrefix + "-opacity")
                Text("\(Int((model.opacity(for: model.selected) * 100).rounded()))%")
                    .font(.caption.monospacedDigit()).frame(width: 35, alignment: .trailing)
            }
            Text("Drag views or handles. Swipe 3 fingers up/down in the middle for opacity.")
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
        }
        .font(.caption).padding(.horizontal, 12).padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(model.accessibilityPrefix + "-arrangement")
    }

    private var refinedEditor: some View {
        VStack(spacing: 3) {
            HStack(spacing: 8) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach([BoundPiPContent.friend] + model.contents, id: \.rawValue) { content in
                            selection(content)
                        }
                    }
                }
                Button("Cancel") { model.finish(save: false) }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier(model.accessibilityPrefix + "-cancel")
            }
            HStack(spacing: 8) {
                Text("Opacity").foregroundStyle(.secondary)
                Slider(value: Binding(get: { model.opacity(for: model.selected) },
                                      set: { model.setOpacity($0, for: model.selected) }), in: 0...1)
                    .accessibilityLabel("\(model.selected.title) opacity")
                    .accessibilityIdentifier(model.accessibilityPrefix + "-opacity")
                Text("\(Int((model.opacity(for: model.selected) * 100).rounded()))%")
                    .monospacedDigit().frame(width: 35, alignment: .trailing)
                Button(action: model.resetSelectedView) {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
                .frame(minHeight: 44)
                .accessibilityLabel("Reset \(model.selected.title)")
                .accessibilityHint("Restores this view’s position, size and opacity. Cancel undoes the reset.")
                .accessibilityIdentifier(model.accessibilityPrefix + "-reset")
            }
            Text("Drag to move · Handles resize · 3-finger swipe adjusts opacity · DONE saves")
                .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
        }
        .font(.caption).tint(Color(uiColor: .deltaPurple))
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.2), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(model.accessibilityPrefix + "-arrangement")
    }
    private var placementEditor: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Menu {
                    ForEach([BoundPiPContent.friend] + model.contents, id: \.rawValue) { content in
                        Button { model.select(content) } label: {
                            if model.selected == content { Label(content.title, systemImage: "checkmark") }
                            else { Text(content.title) }
                        }
                        .accessibilityIdentifier(model.accessibilityPrefix + "-select.\(content.rawValue)")
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(model.selected.title).fontWeight(.semibold)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold))
                    }
                    .frame(width: 98, height: 40)
                    .background(Color.purple.opacity(0.12), in: Capsule())
                    .frame(height: 44)
                }
                .accessibilityLabel("Choose view")
                .accessibilityValue(model.selected.title)
                .accessibilityIdentifier(model.accessibilityPrefix + "-choose-view")
                Text("Opacity").foregroundStyle(.secondary)
                Slider(value: Binding(get: { model.opacity(for: model.selected) },
                                      set: { model.setOpacity($0, for: model.selected) }), in: 0...1)
                    .accessibilityLabel("\(model.selected.title) opacity")
                    .accessibilityIdentifier(model.accessibilityPrefix + "-opacity")
                Text("\(Int((model.opacity(for: model.selected) * 100).rounded()))%")
                    .monospacedDigit().lineLimit(1).frame(width: 40, alignment: .trailing)
                Button("Cancel") { model.finish(save: false) }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier(model.accessibilityPrefix + "-cancel")
            }
            HStack(spacing: 6) {
                Text("Place").foregroundStyle(.secondary)
                ForEach(BoundLandscapeArrangementModel.Corner.allCases, id: \.rawValue) { corner in
                    Button { model.placeSelectedView(at: corner) } label: {
                        Image(systemName: corner.symbol).font(.system(size: 14, weight: .semibold))
                            .frame(width: 44, height: 36)
                            .background(Color.purple.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                            .frame(height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Place \(model.selected.title) \(corner.title.lowercased())")
                    .accessibilityHint("Moves this view to the corner. Drag it to fine-tune the position.")
                    .accessibilityIdentifier(model.accessibilityPrefix + "-place.\(corner.rawValue)")
                }
                Spacer(minLength: 0)
                Button("Reset", action: model.resetSelectedView)
                    .frame(minWidth: 44, minHeight: 44)
                    .accessibilityLabel("Reset \(model.selected.title)")
                    .accessibilityIdentifier(model.accessibilityPrefix + "-reset")
            }
        }
        .font(.caption).tint(Color(uiColor: .deltaPurple))
        .padding(.horizontal, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(.white.opacity(0.2), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(model.accessibilityPrefix + "-arrangement")
    }

    private func selection(_ content: BoundPiPContent) -> some View {
        Button { model.select(content) } label: {
            Text(title(for: content)).fontWeight(model.selected == content ? .bold : .regular)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .frame(minHeight: model.refined ? 36 : nil)
                .background(model.selected == content ? Color.purple.opacity(0.22) : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(model.selected == content ? .isSelected : [])
        .accessibilityIdentifier(model.accessibilityPrefix + "-select.\(content.rawValue)")
    }
}

@MainActor
private func arrangementEditorFrame(for model: BoundLandscapeArrangementModel) -> CGRect {
    let canvas = model.layout.canvas
    let width = model.placementShortcuts ? min(520, canvas.width * 0.70) : min(model.refined ? 560 : 490, canvas.width * (model.refined ? 0.74 : 0.66))
    let height: CGFloat = model.placementShortcuts ? 88 : model.refined ? 122 : 90
    let y = model.placementShortcuts && model.editorAtTop ? canvas.minY + 4 : canvas.maxY - height - 4
    return CGRect(x: canvas.midX - width / 2, y: y, width: width, height: height)
}

private struct ArrangementButtonStyle: ButtonStyle {
    var selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 20, weight: .semibold))
            .frame(width: 44, height: 44).foregroundStyle(.white)
            .background(Color(uiColor: .deltaPurple).opacity(selected ? 0.85 : 0.55), in: Circle())
            .overlay(Circle().stroke(.white.opacity(0.85), lineWidth: 1.5))
            .contentShape(Circle()).opacity(configuration.isPressed ? 0.65 : 1)
    }
}
private extension View {
    func placed(_ frame: CGRect) -> some View {
        self.frame(width: max(0, frame.width), height: max(0, frame.height))
            .offset(x: frame.minX, y: frame.minY)
    }
}

/// A separate, exact-three-finger recognizer leaves the old gestures untouched.
@MainActor
final class BoundLandscapeOpacityGesture: NSObject, UIGestureRecognizerDelegate {
    private enum SwipeDirection { case pending, vertical, rejected }
    private weak var view: UIView?
    private let model: BoundLandscapeArrangementModel
    private var gate = BoundPiPTouchCountGate()
    private var translation: CGFloat = 0
    private var direction = SwipeDirection.pending
    private var pan: ArrangementReleasePan!
    init(view: UIView, model: BoundLandscapeArrangementModel) {
        self.view = view; self.model = model
        super.init()
        pan = ArrangementReleasePan(target: self, action: #selector(fade(_:)))
        pan.minimumNumberOfTouches = 3; pan.maximumNumberOfTouches = 3
        pan.cancelsTouchesInView = true
        pan.delegate = self
        view.addGestureRecognizer(pan)
    }
    func detach() { if let pan { view?.removeGestureRecognizer(pan) }; view = nil }
    @objc private func fade(_ gesture: ArrangementReleasePan) {
        switch gate.update(phase: gesture.state, touches: gesture.numberOfTouches, required: 3, releasing: gesture.isReleasing) {
        case .ignore: break
        case .cancel: model.fade(phase: .cancelled, dy: 0)
        case .deliver:
            if gesture.state == .began { direction = .pending }
            if gesture.state == .began || (gesture.state == .changed && !gesture.isReleasing) {
                let delta = gesture.translation(in: view)
                if model.multiview {
                    // UIKit can begin a three-finger pan with zero translation.
                    // Wait for movement before locking the swipe to its axis.
                    if direction == .pending, max(abs(delta.x), abs(delta.y)) >= 4 {
                        direction = abs(delta.y) > abs(delta.x) ? .vertical : .rejected
                    }
                    if direction == .rejected {
                        model.fade(phase: .cancelled, dy: 0)
                        return
                    }
                    if direction == .pending && gesture.state == .changed { return }
                }
                translation = delta.y
            }
            model.fade(phase: gesture.state, dy: translation)
        }
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        let point = touch.location(in: view)
        guard model.active && model.editing else { return false }
        // Multiview has no toolbar: a selected panel can be faded anywhere in
        // the arrangement canvas, including where the old opacity box sat.
        if model.multiview { return model.layout.canvas.contains(point) }
        return model.layout.opacityZone.contains(point) && !arrangementEditorFrame(for: model).contains(point)
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        otherGestureRecognizer is ArrangementReleasePan
    }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        let delta = pan.translation(in: view)
        return model.active && model.editing && pan.numberOfTouches == 3
            && (model.multiview || abs(delta.y) > abs(delta.x))
    }
}
private final class ArrangementReleasePan: UIPanGestureRecognizer {
    private(set) var isReleasing = false
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if isReleasing && (state == .began || state == .changed) { state = .cancelled; return }
        super.touchesBegan(touches, with: event)
        if maximumNumberOfTouches == 1, numberOfTouches > 1, state == .began || state == .changed { state = .cancelled }
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        isReleasing = true
        super.touchesEnded(touches, with: event)
    }
    override func reset() { super.reset(); isReleasing = false }
}

/// UIKit enforces one-finger manipulation before SwiftUI can claim a three-finger swipe.
private struct ArrangementDragTarget: UIViewRepresentable {
    var identifier: String
    var label: String
    var value: String? = nil
    var selected = false
    var select: () -> Void
    var cancelled: () -> Void
    var moved: (CGSize, Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = true
        view.isAccessibilityElement = true
        let pan = ArrangementReleasePan(target: context.coordinator, action: #selector(Coordinator.drag(_:)))
        pan.minimumNumberOfTouches = 1; pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap))
        tap.require(toFail: pan)
        view.addGestureRecognizer(tap)
        updateUIView(view, context: context)
        return view
    }
    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.target = self
        view.accessibilityIdentifier = identifier
        view.accessibilityLabel = label
        view.accessibilityValue = value
        view.accessibilityTraits = selected ? .selected : []
    }
    final class Coordinator: NSObject {
        var target: ArrangementDragTarget
        var gate = BoundPiPTouchCountGate()
        var translation = CGSize.zero
        init(_ target: ArrangementDragTarget) { self.target = target }
        @objc func tap() { target.select() }
        @objc func drag(_ pan: ArrangementReleasePan) {
            if pan.state == .cancelled || pan.state == .failed { target.cancelled(); return }
            switch gate.update(phase: pan.state, touches: pan.numberOfTouches, required: 1, releasing: pan.isReleasing) {
            case .ignore: break
            case .cancel: target.cancelled()
            case .deliver:
                if pan.state == .began || (pan.state == .changed && !pan.isReleasing) {
                    let delta = pan.translation(in: pan.view?.window)
                    translation = CGSize(width: delta.x, height: delta.y)
                }
                target.moved(translation, pan.state == .ended)
            }
        }
    }
}
