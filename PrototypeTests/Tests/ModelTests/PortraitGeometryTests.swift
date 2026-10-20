import XCTest
import Foundation
@testable import Models
final class PortraitGeometryTests: XCTestCase {
    func testFullWidthGameAndStockControlsAcrossPhoneSizes() {
        for (width, height, inset) in [(320.0,568.0,20.0), (375,667,20), (390,844,47), (430,932,59)] {
            let bounds = CGRect(x: 0, y: 0, width: width, height: height)
            let result = BoundPortraitScreenGeometry(bounds: bounds, safeTop: inset, controllerSize: CGSize(width: 320, height: 274), gameAspect: CGSize(width: 3, height: 2))
            XCTAssertEqual(result.game.width, width)
            XCTAssertEqual(result.game.width / result.game.height, 1.5, accuracy: 0.001)
            XCTAssertEqual(result.controller.height, width * 274 / 320, accuracy: 0.001)
            XCTAssertEqual(result.controller.maxY, height)
            XCTAssertEqual(result.game.maxY, result.controller.minY, accuracy: 0.001)
            XCTAssertGreaterThan(result.friend.height, 0)
            XCTAssertEqual(result.friend.width / result.friend.height, 1.5, accuracy: 0.001)
            XCTAssertGreaterThanOrEqual(result.friend.minY, inset)
            XCTAssertLessThanOrEqual(result.friend.maxY + 8, result.game.minY + 0.001)
        }
    }
}
