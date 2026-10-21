import SwiftUI
import UIKit
import DeltaCore
import GameController

enum BoundMultiviewTabCycling {
    static func index(current: Int, direction: Int, count: Int) -> Int? {
        guard count > 0, direction != 0 else { return nil }
        let step = direction > 0 ? 1 : -1
        return (current + step + count) % count
    }
}

/// Filters app-only choices before they reach either gameplay input receiver.
struct BoundControllerInputMapping: GameControllerInputMappingProtocol {
    let base: GameControllerInputMappingProtocol
    var multiviewActive = false
    var multiviewDefaults: DeltaCore.GameControllerInputMapping? = nil
    var friendWorldGate: BoundFriendWorldInputGate? = nil
    var gameControllerInputType: GameControllerInputType { base.gameControllerInputType }

    static func isLeftStickDirection(_ input: Input) -> Bool {
        if let input = MFiGameController.Input(input: input) {
            return [.leftThumbstickUp, .leftThumbstickDown, .leftThumbstickLeft, .leftThumbstickRight].contains(input)
        }
        if let input = StandardGameControllerInput(input: input) {
            return [.leftThumbstickUp, .leftThumbstickDown, .leftThumbstickLeft, .leftThumbstickRight].contains(input)
        }
        return false
    }

    func input(forControllerInput controllerInput: Input) -> Input? {
        let target = (multiviewActive ? multiviewDefaults : nil)?.input(forControllerInput: controllerInput)
            ?? base.input(forControllerInput: controllerInput)
        if let target, let action = ActionInput(input: target) {
            if action == .none || action == .systemOverlay { return nil }
            if Self.isLeftStickDirection(controllerInput), action.isBoundPanelAction { return nil }
            // Keep the user's panel and menu shortcuts available during capture.
            if action.isBoundPanelAction { return target }
        }
        if multiviewActive {
            if let target, StandardGameControllerInput(input: target) == .menu { return target }
            return Self.multiviewAction(for: controllerInput)
        }
        return target.map { friendWorldGate?.filter($0) ?? $0 }
    }

    static func multiviewAction(for input: Input) -> ActionInput? {
        let name: String
        if let input = MFiGameController.Input(input: input) { name = input.rawValue }
        else if let input = StandardGameControllerInput(input: input) { name = input.rawValue }
        else { return nil }
        switch name {
        case "up": return .boundFocusUp
        case "down": return .boundFocusDown
        case "left": return .boundFocusLeft
        case "right": return .boundFocusRight
        case "a": return .boundSelect
        case "b": return .boundBack
        case "rightThumbstickUp": return .boundScrollUp
        case "rightThumbstickDown": return .boundScrollDown
        case "rightThumbstickLeft": return .boundScrollLeft
        case "rightThumbstickRight": return .boundScrollRight
        default: return nil
        }
    }

}

enum BoundControllerSystemGestures {
    static func preferredState(for target: Input?, capturing: Bool = false) -> GCControllerElement.SystemGestureState {
        if capturing { return .disabled }
        guard let target else { return .enabled }
        return ActionInput(input: target) == .systemOverlay ? .enabled : .disabled
    }

    /// Request app control only for assigned buttons. iOS retains final control
    /// over reserved Home gestures; Overlay intentionally leaves them enabled.
    static func apply(to controller: MFiGameController, mapping: GameControllerInputMappingProtocol, capturing: Bool = false) {
        let inputs: [MFiGameController.Input] = [.menu, .start, .select, .share,
            .a, .b, .x, .y, .up, .down, .left, .right,
            .leftShoulder, .rightShoulder, .leftTrigger, .rightTrigger,
            .leftThumbstickButton, .rightThumbstickButton]
        for input in inputs {
            controller.physicalButton(for: input)?.preferredSystemGestureState = preferredState(
                for: mapping.input(forControllerInput: input), capturing: capturing)
        }
    }
}

enum BoundControllerNavigationCommand: String, CaseIterable, Sendable {
    case scrollUp
    case scrollDown
    case scrollLeft
    case scrollRight
    case focusUp, focusDown, focusLeft, focusRight, clearFocus
    case previousItem
    case nextItem
    case select
    case back
    case details
}

struct BoundControllerNavigationEvent {
    static let notificationName = Notification.Name("BoundControllerNavigationCommand")
    static let hideMultiviewNotificationName = Notification.Name("BoundControllerNavigationHideMultiview")
    static let gameIDKey = "gameID"
    static let contentKey = "content"
    static let commandKey = "command"

    static func command(from notification: Notification, gameID: String,
                        content: BoundPiPContent) -> BoundControllerNavigationCommand? {
        guard let info = notification.userInfo,
              info[gameIDKey] as? String == gameID,
              info[contentKey] as? String == content.rawValue,
              let rawValue = info[commandKey] as? String else { return nil }
        return BoundControllerNavigationCommand(rawValue: rawValue)
    }

    static func post(command: BoundControllerNavigationCommand, gameID: String,
                     content: BoundPiPContent) {
        let userInfo: [AnyHashable: Any] = [
            gameIDKey: gameID,
            contentKey: content.rawValue,
            commandKey: command.rawValue
        ]
        if Thread.isMainThread {
            NotificationCenter.default.post(name: notificationName, object: nil, userInfo: userInfo)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: notificationName, object: nil, userInfo: userInfo)
            }
        }
    }

    static func postHideMultiview(gameID: String, content: BoundPiPContent) {
        NotificationCenter.default.post(name: hideMultiviewNotificationName, object: nil,
                                        userInfo: [gameIDKey: gameID, contentKey: content.rawValue])
    }

    static func hideMultiviewRequestMatches(_ notification: Notification, gameID: String,
                                            content: BoundPiPContent, available: Bool) -> Bool {
        guard available, let info = notification.userInfo else { return false }
        return info[gameIDKey] as? String == gameID
            && info[contentKey] as? String == content.rawValue
    }
}

extension View {
    /// Routes scoped navigation events to the active content's visible scroll view.
    func boundControllerScroll(gameID: String, content: BoundPiPContent,
                               active: Bool = true) -> some View {
        background {
            BoundControllerNavigationScrollHost(gameID: gameID, content: content, active: active)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}

private struct BoundControllerNavigationScrollHost: UIViewRepresentable {
    let gameID: String
    let content: BoundPiPContent
    let active: Bool

    func makeCoordinator() -> BoundControllerNavigationScrollCoordinator {
        BoundControllerNavigationScrollCoordinator()
    }

    func makeUIView(context: Context) -> BoundControllerNavigationMarkerView {
        let view = BoundControllerNavigationMarkerView(frame: .zero)
        context.coordinator.attach(to: view, gameID: gameID, content: content, active: active)
        return view
    }

    func updateUIView(_ uiView: BoundControllerNavigationMarkerView, context: Context) {
        context.coordinator.attach(to: uiView, gameID: gameID, content: content, active: active)
    }

    static func dismantleUIView(_ uiView: BoundControllerNavigationMarkerView,
                                coordinator: BoundControllerNavigationScrollCoordinator) {
        coordinator.detach()
    }
}

final class BoundControllerNavigationMarkerView: UIView {
    fileprivate var gameID = ""
    fileprivate var content: BoundPiPContent = .dex
    fileprivate var active = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        accessibilityElementsHidden = true
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
final class BoundControllerNavigationScrollCoordinator {
    private weak var marker: BoundControllerNavigationMarkerView?
    private var observer: NSObjectProtocol?

    func attach(to marker: BoundControllerNavigationMarkerView, gameID: String,
                content: BoundPiPContent, active: Bool) {
        self.marker = marker
        marker.gameID = gameID
        marker.content = content
        marker.active = active
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: BoundControllerNavigationEvent.notificationName, object: nil, queue: .main
        ) { [weak self] notification in
            Task { @MainActor in self?.receive(notification) }
        }
    }

    func detach() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        marker = nil
    }

    func receive(_ notification: Notification) {
        guard let marker, marker.active, marker.window != nil,
              !marker.isHidden, marker.alpha > 0.01,
              let command = BoundControllerNavigationEvent.command(
                from: notification, gameID: marker.gameID, content: marker.content
              ),
              let scrollView = Self.resolveScrollView(for: marker, command: command) else { return }
        _ = BoundControllerNavigationScrollTarget.scroll(command, in: scrollView, active: true)
    }

    static func resolveScrollView(for marker: UIView,
                                  command: BoundControllerNavigationCommand) -> UIScrollView? {
        guard let window = marker.window else { return nil }
        let horizontal: Bool
        switch command {
        case .scrollLeft, .scrollRight: horizontal = true
        case .scrollUp, .scrollDown: horizontal = false
        default: return nil
        }

        let markerViewport = marker.convert(marker.bounds, to: window)
        var ancestor = marker.superview
        while let view = ancestor {
            if view is UIWindow { break }
            var localCandidates: [UIScrollView] = []
            if let scrollView = view as? UIScrollView { localCandidates.append(scrollView) }
            localCandidates.append(contentsOf: descendantScrollViews(of: view))
            let eligible = localCandidates.filter { scrollView in
                guard isVisible(scrollView), canScroll(scrollView, horizontally: horizontal),
                      scrollView.bounds.width > 0, scrollView.bounds.height > 0 else { return false }
                return scrollView.convert(scrollView.bounds, to: window).intersection(markerViewport).isNull == false &&
                    scrollView.convert(scrollView.bounds, to: window).intersection(markerViewport).isEmpty == false
            }
            if !eligible.isEmpty {
                // Resolve inside the closest ancestor scope with a viewport
                // intersecting this marker. Never keep walking into UIWindow,
                // where another visible game/reference scroller could win.
                return eligible.min {
                    let first = $0.convert($0.bounds, to: window).intersection(markerViewport)
                    let second = $1.convert($1.bounds, to: window).intersection(markerViewport)
                    if first.width * first.height != second.width * second.height {
                        return first.width * first.height > second.width * second.height
                    }
                    return ($0.bounds.width * $0.bounds.height) < ($1.bounds.width * $1.bounds.height)
                }
            }
            ancestor = view.superview
        }
        return nil
    }

    private static func descendantScrollViews(of root: UIView) -> [UIScrollView] {
        var result: [UIScrollView] = []
        var stack = Array(root.subviews.reversed())
        while let view = stack.popLast() {
            if let scrollView = view as? UIScrollView { result.append(scrollView) }
            stack.append(contentsOf: view.subviews.reversed())
        }
        return result
    }

    private static func isVisible(_ view: UIView) -> Bool {
        guard view.window != nil, !view.isHidden, view.alpha > 0.01 else { return false }
        var ancestor = view.superview
        while let current = ancestor {
            if current.isHidden || current.alpha <= 0.01 { return false }
            ancestor = current.superview
        }
        return true
    }

    private static func canScroll(_ view: UIScrollView, horizontally: Bool) -> Bool {
        guard view.isScrollEnabled else { return false }
        if horizontally {
            return view.alwaysBounceHorizontal ||
                view.contentSize.width + view.adjustedContentInset.left + view.adjustedContentInset.right > view.bounds.width + 0.5
        }
        return view.alwaysBounceVertical ||
            view.contentSize.height + view.adjustedContentInset.top + view.adjustedContentInset.bottom > view.bounds.height + 0.5
    }
}

@MainActor
enum BoundControllerNavigationScrollTarget {
    @discardableResult
    static func scroll(_ command: BoundControllerNavigationCommand, in scrollView: UIScrollView,
                       active: Bool, animated: Bool = true) -> Bool {
        guard active, scrollView.isScrollEnabled, !scrollView.isHidden,
              scrollView.alpha > 0.01, scrollView.window != nil else { return false }
        let inset = scrollView.adjustedContentInset
        let stepX = scrollView.bounds.width * 0.65
        let stepY = scrollView.bounds.height * 0.65
        var offset = scrollView.contentOffset
        switch command {
        case .scrollUp:
            offset.y -= stepY
        case .scrollDown:
            offset.y += stepY
        case .scrollLeft:
            offset.x -= stepX
        case .scrollRight:
            offset.x += stepX
        default:
            return false
        }
        let minimumX = -inset.left
        let maximumX = max(minimumX, scrollView.contentSize.width - scrollView.bounds.width + inset.right)
        let minimumY = -inset.top
        let maximumY = max(minimumY, scrollView.contentSize.height - scrollView.bounds.height + inset.bottom)
        offset.x = min(maximumX, max(minimumX, offset.x))
        offset.y = min(maximumY, max(minimumY, offset.y))
        guard offset != scrollView.contentOffset else { return false }
        scrollView.setContentOffset(offset, animated: animated)
        return true
    }
}

/// Default trigger shortcuts are supplied only for an uncustomized mapping.
/// Saved maps remain authoritative, including explicit None assignments.
enum BoundMultiviewDefaultMapping {
    static func mapping(for controller: GameController, enabled: Bool = BoundControllerMultiviewPreferences().isEnabled) -> DeltaCore.GameControllerInputMapping {
        var mapping = controller.defaultInputMapping as? DeltaCore.GameControllerInputMapping
            ?? DeltaCore.GameControllerInputMapping(gameControllerInputType: controller.inputType)
        guard enabled, controller.inputType == .mfi else { return mapping }
        mapping.set(ActionInput.boundPreviousView, forControllerInput: MFiGameController.Input.leftTrigger)
        mapping.set(ActionInput.boundNextView, forControllerInput: MFiGameController.Input.rightTrigger)
        return mapping
    }
}

@MainActor
final class BoundMultiviewInputRepeater {
    private struct Hold: Hashable {
        let controller: ObjectIdentifier
        let action: ActionInput
    }
    private var timers: [Hold: Timer] = [:]
    func begin(controller: GameController, action: ActionInput, perform: @escaping () -> Bool) {
        let key = Hold(controller: ObjectIdentifier(controller), action: action)
        guard timers[key] == nil else { return }
        // This timer is installed on RunLoop.main below, so its callback is synchronous
        // main-actor work and can safely keep the repeat handoff immediate.
        let timer = Timer(timeInterval: 0.18, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard perform() else {
                    timer.invalidate()
                    self?.timers[key] = nil
                    return
                }
            }
        }
        timer.fireDate = Date(timeIntervalSinceNow: 0.35)
        timers[key] = timer
        RunLoop.main.add(timer, forMode: .common)
    }
    func end(controller: GameController, action: ActionInput? = nil) {
        for key in Array(timers.keys) where key.controller == ObjectIdentifier(controller) && (action == nil || key.action == action) {
            timers.removeValue(forKey: key)?.invalidate()
        }
    }
    func endAll() {
        timers.values.forEach { $0.invalidate() }
        timers.removeAll()
    }
    deinit { timers.values.forEach { $0.invalidate() } }
}
