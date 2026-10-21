import UIKit

/// Runtime routing for the iOS app on Apple silicon. iPhone and iPad keep their
/// existing interface; the Simulator override exists only in Debug builds.
enum BoundMacWorkspacePlatform {
    static var isEnabled: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--bound-ui-mac-workspace") { return true }
        #endif
        return ProcessInfo.processInfo.isiOSAppOnMac
    }
}

/// Shared rectangles keep the native game renderer aligned with the resizable sidebar.
struct BoundMacWorkspaceGeometry: Equatable {
    let bounds: CGRect
    let gameplay: CGRect
    let inspector: CGRect
    let resizeHandle: CGRect
    let controls: CGRect

    init(bounds: CGRect, sidebarVisible: Bool = true, preferredSidebarWidth: CGFloat = 420) {
        self.bounds = bounds
        let width = max(0, bounds.width), height = max(0, bounds.height)
        let maximum = min(720, width * 0.6, max(0, width - 240))
        let minimum = min(280, maximum)
        let preferred = preferredSidebarWidth.isFinite ? preferredSidebarWidth : 420
        let inspectorWidth = sidebarVisible ? min(maximum, max(minimum, preferred)) : 0
        gameplay = CGRect(x: bounds.minX, y: bounds.minY, width: width - inspectorWidth, height: height)
        inspector = sidebarVisible ? CGRect(x: gameplay.maxX, y: bounds.minY, width: inspectorWidth, height: height) : .zero
        resizeHandle = sidebarVisible ? CGRect(x: inspector.minX, y: bounds.minY, width: min(12, inspectorWidth), height: height) : .zero
        let controlWidth = min(76, width), controlHeight = min(36, height)
        controls = CGRect(x: max(bounds.minX, bounds.maxX - controlWidth - 8),
                          y: bounds.minY + min(8, max(0, height - controlHeight)),
                          width: controlWidth, height: controlHeight)
    }
}
