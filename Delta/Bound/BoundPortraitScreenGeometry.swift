import Foundation
import CoreGraphics

/// Two aspect-correct screens above the untouched stock Delta controller rectangle.
struct BoundPortraitScreenGeometry {
    let controller: CGRect
    let game: CGRect
    let friend: CGRect
    init(bounds: CGRect, safeTop: CGFloat, controllerSize: CGSize, gameAspect: CGSize) {
        let controllerHeight = controllerSize.width > 0 ? bounds.width * controllerSize.height / controllerSize.width : 0
        controller = CGRect(x: bounds.minX, y: bounds.maxY - controllerHeight, width: bounds.width, height: controllerHeight)
        let aspect = gameAspect.width > 0 && gameAspect.height > 0 ? gameAspect : CGSize(width: 3, height: 2)
        let mainHeight = bounds.width * aspect.height / aspect.width
        game = CGRect(x: bounds.minX, y: controller.minY - mainHeight, width: bounds.width, height: mainHeight)
        let top = bounds.minY + safeTop
        let height = max(0, min(mainHeight, game.minY - top - 8))
        friend = CGRect(x: bounds.midX - height * aspect.width / aspect.height / 2, y: top,
                        width: height * aspect.width / aspect.height, height: height)
    }
}
