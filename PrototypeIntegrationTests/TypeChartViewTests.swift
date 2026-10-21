import XCTest
import UIKit
@testable import Delta

@MainActor final class TypeChartViewTests: XCTestCase {
    func testExpandedViewportInitiallyClearsIslandAndShowsChartBottom() throws {
        let scroll = BoundPortraitChartScrollView(frame: CGRect(x: 0, y: 0, width: 402, height: 240))
        scroll.topInset = 62
        XCTAssertFalse(scroll.constrainsPan, "Classic retains its existing scroll behavior")
        XCTAssertTrue(scroll.bounces)
        scroll.layoutIfNeeded()
        let image = try XCTUnwrap(scroll.subviews.compactMap { $0 as? UIImageView }.first)
        XCTAssertEqual(scroll.bounds.height, 240)
        XCTAssertEqual(image.frame.height, 178, accuracy: 0.1)
        let visibleFrame = image.frame.offsetBy(dx: -scroll.contentOffset.x, dy: -scroll.contentOffset.y)
        XCTAssertEqual(visibleFrame.minY, 62, accuracy: 0.1)
        XCTAssertEqual(visibleFrame.maxY, 240, accuracy: 0.1)
        XCTAssertEqual(scroll.backgroundColor, .black)
        XCTAssertTrue(scroll.bouncesZoom)
        let source = try XCTUnwrap(image.image)
        XCTAssertEqual(scroll.minimumZoomScale, min(402 / source.size.width, 178 / source.size.height), accuracy: 0.0001)
        scroll.setZoomScale(scroll.minimumZoomScale, animated: false)
        XCTAssertLessThanOrEqual(image.frame.width, scroll.bounds.width + 0.1)
        XCTAssertLessThanOrEqual(image.frame.height, 178.1)
        scroll.setZoomScale(178 / source.size.height, animated: false)
        let initial = scroll.zoomScale
        scroll.setZoomScale(initial * 2, animated: false)
        scroll.setContentOffset(CGPoint(x: 0, y: 0), animated: false)
        XCTAssertGreaterThan(image.frame.height, scroll.bounds.height)
        XCTAssertEqual(image.frame.minY-scroll.contentOffset.y, 0, accuracy: 0.1)
    }
    func testPortraitInitialHeightFitZoomPanAndViewportReset() throws {
        let scroll = BoundPortraitChartScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 240))
        scroll.layoutIfNeeded()
        let image = try XCTUnwrap(scroll.subviews.compactMap { $0 as? UIImageView }.first)
        let asset = try XCTUnwrap(image.image)
        let initial = scroll.zoomScale
        XCTAssertEqual(image.frame.height, scroll.bounds.height, accuracy: 0.1)
        XCTAssertEqual(image.frame.width / image.frame.height, asset.size.width / asset.size.height, accuracy: 0.001)
        XCTAssertEqual(scroll.accessibilityIdentifier, "bound.type-chart")
        XCTAssertTrue(scroll.accessibilityValue?.contains("viewportHeight=240.00") == true)
        scroll.setZoomScale(initial * 2, animated: false)
        scroll.layoutIfNeeded()
        XCTAssertEqual(scroll.zoomScale, initial * 2, accuracy: 0.0001)
        XCTAssertEqual(image.frame.height, 480, accuracy: 0.1)
        scroll.setContentOffset(CGPoint(x: 20, y: 50), animated: false)
        XCTAssertTrue(scroll.accessibilityValue?.contains("imageY=-50.00") == true)
        // Orientation/layout changes reset content instead of carrying stale offsets.
        scroll.frame = CGRect(x: 0, y: 0, width: 320, height: 180)
        scroll.setNeedsLayout(); scroll.layoutIfNeeded()
        XCTAssertEqual(image.frame.height, 180, accuracy: 0.1)
        XCTAssertEqual(scroll.zoomScale, 180 / asset.size.height, accuracy: 0.0001)
        XCTAssertEqual(scroll.contentOffset.y, 0, accuracy: 0.1)
        let reopened = BoundPortraitChartScrollView(frame: scroll.frame)
        reopened.layoutIfNeeded()
        XCTAssertEqual(reopened.zoomScale, scroll.zoomScale, accuracy: 0.0001)
        XCTAssertEqual(reopened.contentOffset, scroll.contentOffset)
    }
    func testBoundMinimumFitHasFixedBottomAlignmentAndNoPanOverscroll() throws {
        let scroll = BoundPortraitChartScrollView(frame: CGRect(x: 0, y: 0, width: 220, height: 390))
        scroll.topInset = 62
        scroll.constrainsPan = true
        scroll.layoutIfNeeded()
        let image = try XCTUnwrap(scroll.subviews.compactMap { $0 as? UIImageView }.first)
        XCTAssertFalse(scroll.bounces)
        XCTAssertTrue(scroll.bouncesZoom, "Pan bounds must retain UIKit's independent elastic pinch")
        scroll.setZoomScale(scroll.minimumZoomScale, animated: false)
        let fixed = scroll.contentOffset
        XCTAssertEqual(image.frame.height, 220, accuracy: 0.1)
        XCTAssertEqual(image.frame.maxY - fixed.y, scroll.bounds.height, accuracy: 0.1)
        for attempt in [CGPoint(x: -1000, y: -1000), CGPoint(x: 1000, y: 1000)] {
            scroll.setContentOffset(attempt, animated: false)
            XCTAssertEqual(scroll.contentOffset.x, fixed.x, accuracy: 0.1)
            XCTAssertEqual(scroll.contentOffset.y, fixed.y, accuracy: 0.1)
        }
        scroll.frame = CGRect(x: 0, y: 0, width: 320, height: 180)
        scroll.setNeedsLayout(); scroll.layoutIfNeeded()
        XCTAssertEqual(image.frame.maxY - scroll.contentOffset.y, 180, accuracy: 0.1)
        let rotatedOffset = scroll.contentOffset
        scroll.setContentOffset(CGPoint(x: 1000, y: -1000), animated: false)
        XCTAssertEqual(scroll.contentOffset, rotatedOffset)
    }

    func testBoundZoomedPanClampsEachOverflowingAxisWithoutBlankEdges() throws {
        let scroll = BoundPortraitChartScrollView(frame: CGRect(x: 0, y: 0, width: 220, height: 390))
        scroll.constrainsPan = true
        scroll.layoutIfNeeded()
        // A width-only overflow must not enable vertical movement.
        scroll.setZoomScale(scroll.minimumZoomScale * 1.3, animated: false)
        let fixedY = -(scroll.bounds.height - scroll.contentSize.height)
        XCTAssertGreaterThan(scroll.contentSize.width, scroll.bounds.width)
        XCTAssertLessThan(scroll.contentSize.height, scroll.bounds.height)
        scroll.setContentOffset(CGPoint(x: 1000, y: 1000), animated: false)
        XCTAssertEqual(scroll.contentOffset.x, scroll.contentSize.width - scroll.bounds.width, accuracy: 0.1)
        XCTAssertEqual(scroll.contentOffset.y, fixedY, accuracy: 0.1)
        scroll.setZoomScale(scroll.minimumZoomScale * 3, animated: false)
        let maximum = CGPoint(x: scroll.contentSize.width - scroll.bounds.width,
                              y: scroll.contentSize.height - scroll.bounds.height)
        XCTAssertGreaterThan(maximum.x, 0)
        XCTAssertGreaterThan(maximum.y, 0)
        scroll.setContentOffset(CGPoint(x: -1000, y: -1000), animated: false)
        XCTAssertEqual(scroll.contentOffset, .zero)
        scroll.setContentOffset(CGPoint(x: 1000, y: 1000), animated: false)
        XCTAssertEqual(scroll.contentOffset.x, maximum.x, accuracy: 0.1)
        XCTAssertEqual(scroll.contentOffset.y, maximum.y, accuracy: 0.1)
        let interior = CGPoint(x: maximum.x / 2, y: maximum.y / 2)
        scroll.setContentOffset(interior, animated: false)
        XCTAssertEqual(scroll.contentOffset, interior)
        scroll.setZoomScale(scroll.minimumZoomScale, animated: false)
        XCTAssertEqual(scroll.contentOffset.y, -(scroll.bounds.height - scroll.contentSize.height), accuracy: 0.1)
    }

    func testMacChartInitiallyFitsAndCentersAcrossSidebarResizes() throws {
        let scroll = BoundPortraitChartScrollView(frame: CGRect(x: 0, y: 0, width: 220, height: 390))
        scroll.constrainsPan = true
        scroll.fitsViewport = true
        scroll.layoutIfNeeded()
        let image = try XCTUnwrap(scroll.subviews.compactMap { $0 as? UIImageView }.first)
        let source = try XCTUnwrap(image.image)
        for viewport in [CGSize(width: 220, height: 390), CGSize(width: 360, height: 180)] {
            scroll.frame = CGRect(origin: .zero, size: viewport)
            scroll.setNeedsLayout()
            scroll.layoutIfNeeded()
            let visible = image.frame.offsetBy(dx: -scroll.contentOffset.x, dy: -scroll.contentOffset.y)
            XCTAssertEqual(scroll.zoomScale, min(viewport.width / source.size.width, viewport.height / source.size.height), accuracy: 0.0001)
            XCTAssertLessThanOrEqual(visible.width, viewport.width + 0.1)
            XCTAssertLessThanOrEqual(visible.height, viewport.height + 0.1)
            XCTAssertEqual(visible.midX, viewport.width / 2, accuracy: 0.1)
            XCTAssertEqual(visible.midY, viewport.height / 2, accuracy: 0.1)
            let centeredOffset = scroll.contentOffset
            scroll.setContentOffset(CGPoint(x: 1000, y: -1000), animated: false)
            XCTAssertEqual(scroll.contentOffset.x, centeredOffset.x, accuracy: 0.1)
            XCTAssertEqual(scroll.contentOffset.y, centeredOffset.y, accuracy: 0.1)
        }
    }

    func testMacChartPreservesMagnificationAndFocusWhenSidebarResizes() throws {
        let scroll = BoundPortraitChartScrollView(frame: CGRect(x: 0, y: 0, width: 220, height: 390))
        scroll.constrainsPan = true
        scroll.fitsViewport = true
        scroll.layoutIfNeeded()
        let image = try XCTUnwrap(scroll.subviews.compactMap { $0 as? UIImageView }.first)
        scroll.setZoomScale(scroll.minimumZoomScale * 3, animated: false)
        scroll.setContentOffset(CGPoint(x: 110, y: 135), animated: false)
        let focus = CGPoint(x: (scroll.contentOffset.x + scroll.bounds.width / 2) / image.frame.width,
                            y: (scroll.contentOffset.y + scroll.bounds.height / 2) / image.frame.height)
        scroll.frame = CGRect(x: 0, y: 0, width: 320, height: 280)
        scroll.setNeedsLayout()
        scroll.layoutIfNeeded()
        XCTAssertEqual(scroll.zoomScale / scroll.minimumZoomScale, 3, accuracy: 0.0001)
        XCTAssertEqual((scroll.contentOffset.x + scroll.bounds.width / 2) / image.frame.width, focus.x, accuracy: 0.001)
        XCTAssertEqual((scroll.contentOffset.y + scroll.bounds.height / 2) / image.frame.height, focus.y, accuracy: 0.001)
    }

}
