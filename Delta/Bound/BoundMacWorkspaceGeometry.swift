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

/// The game renderer and SwiftUI chrome use the same rectangles, so resizing
/// cannot place reference controls over gameplay or its touchscreen input.
struct BoundMacWorkspaceGeometry: Equatable {
    let sidebar: CGRect
    let toolbar: CGRect
    let gameplay: CGRect
    let footer: CGRect
    let inspector: CGRect

    init(bounds: CGRect) {
        let width = max(0, bounds.width), height = max(0, bounds.height)
        let sidebarWidth: CGFloat = width >= 1080 ? 176 : width >= 840 ? 64 : 0
        let inspectorWidth = min(420, max(350, width * 0.34), width * 0.48)
        let centerWidth = max(0, width - sidebarWidth - inspectorWidth)
        let toolbarHeight = min(56, height * 0.15)
        let footerHeight = min(36, height * 0.1)
        let gutter = min(16, centerWidth * 0.04, height * 0.02)
        sidebar = CGRect(x: bounds.minX, y: bounds.minY, width: sidebarWidth, height: height)
        toolbar = CGRect(x: sidebar.maxX, y: bounds.minY, width: centerWidth, height: toolbarHeight)
        footer = CGRect(x: sidebar.maxX, y: bounds.maxY - footerHeight, width: centerWidth, height: footerHeight)
        gameplay = CGRect(x: sidebar.maxX + gutter, y: toolbar.maxY + gutter,
                          width: max(0, centerWidth - 2 * gutter),
                          height: max(0, height - toolbarHeight - footerHeight - 2 * gutter))
        inspector = CGRect(x: bounds.maxX - inspectorWidth, y: bounds.minY, width: inspectorWidth, height: height)
    }
}
