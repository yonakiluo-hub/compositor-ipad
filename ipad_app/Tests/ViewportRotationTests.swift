import XCTest
import CoreGraphics
@testable import CompositorKit

final class ViewportRotationTests: XCTestCase {
    private let document = CGSize(width: 1200, height: 700)

    private func viewport() -> CanvasViewport {
        var viewport = CanvasViewport()
        viewport.resize(to: CGSize(width: 900, height: 600), backingScale: 2, documentSize: document)
        return viewport
    }
    private func assertPoint(_ actual: CGPoint, _ expected: CGPoint,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.x, expected.x, accuracy: 0.000001, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: 0.000001, file: file, line: line)
    }

    func testQuarterTurnIsClockwiseAroundDocumentCenterAndSwapsBounds() {
        var viewport = viewport()
        viewport.setZoom(1, anchoredAt: viewport.center, documentSize: document)
        viewport.setRotation(.pi / 2, anchoredAt: viewport.center, documentSize: document)
        assertPoint(viewport.viewPoint(from: .zero, documentSize: document), CGPoint(x: 625, y: 0))
        assertPoint(viewport.viewPoint(from: CGPoint(x: 1200, y: 0), documentSize: document), CGPoint(x: 625, y: 600))
        assertPoint(viewport.viewPoint(from: CGPoint(x: 0, y: 700), documentSize: document), CGPoint(x: 275, y: 0))
        let bounds = viewport.documentRect(document)
        XCTAssertEqual(bounds.minX, 275, accuracy: 0.000001)
        XCTAssertEqual(bounds.minY, 0, accuracy: 0.000001)
        XCTAssertEqual(bounds.width, 350, accuracy: 0.000001)
        XCTAssertEqual(bounds.height, 600, accuracy: 0.000001)
    }

    func testNonSquareCoordinateRoundTripsUseSameDrawingTransformAtAnyAngle() {
        let points = [CGPoint.zero, CGPoint(x: 1200, y: 0), CGPoint(x: 1200, y: 700),
                      CGPoint(x: 0, y: 700), CGPoint(x: 137.25, y: 451.75), CGPoint(x: -100, y: 900)]
        for angle: CGFloat in [0, .pi / 2, .pi, -.pi / 2, 0.37, -1.8] {
            var viewport = viewport()
            viewport.setZoom(2.4, anchoredAt: CGPoint(x: 225, y: 175), documentSize: document)
            viewport.setRotation(angle, anchoredAt: CGPoint(x: 127, y: 441), documentSize: document)
            viewport.translate(by: CGSize(width: 53, height: -21))
            let drawingTransform = viewport.documentToViewTransform(documentSize: document)
            for point in points {
                let displayed = viewport.viewPoint(from: point, documentSize: document)
                assertPoint(displayed, point.applying(drawingTransform))
                assertPoint(viewport.documentPoint(from: displayed, documentSize: document), point)
                assertPoint(displayed.applying(drawingTransform.inverted()), point)
            }
        }
    }

    func testRotationAndZoomKeepOffCenterGestureAnchorFixed() {
        var viewport = viewport()
        viewport.translate(by: CGSize(width: 30, height: -50))
        let anchor = CGPoint(x: 137, y: 443)
        let pixel = viewport.documentPoint(from: anchor, documentSize: document)
        for (rotation, zoom): (CGFloat, CGFloat) in [(0.73, 3.5), (-1.25, 0.37), (.pi / 2, 8)] {
            viewport.setRotation(rotation, anchoredAt: anchor, documentSize: document)
            assertPoint(viewport.viewPoint(from: pixel, documentSize: document), anchor)
            viewport.setZoom(zoom, anchoredAt: anchor, documentSize: document)
            assertPoint(viewport.viewPoint(from: pixel, documentSize: document), anchor)
        }
        XCTAssertFalse(viewport.followsFit)
    }

    func testTranslateRemainsInViewPointsAfterRotation() {
        var viewport = viewport()
        viewport.setRotation(0.81, anchoredAt: viewport.center, documentSize: document)
        let pixel = CGPoint(x: 250, y: 410)
        let before = viewport.viewPoint(from: pixel, documentSize: document)
        viewport.translate(by: CGSize(width: 26, height: -19))
        assertPoint(viewport.viewPoint(from: pixel, documentSize: document), CGPoint(x: before.x + 26, y: before.y - 19))
    }

    func testResizePreservesCenterPixelAndRotationAcrossBackingScales() {
        var viewport = viewport()
        viewport.setRotation(0.63, anchoredAt: CGPoint(x: 180, y: 310), documentSize: document)
        viewport.setZoom(3, anchoredAt: CGPoint(x: 230, y: 170), documentSize: document)
        viewport.translate(by: CGSize(width: -37, height: 51))
        let centerPixel = viewport.documentPoint(from: viewport.center, documentSize: document)
        let oldPan = viewport.pan
        viewport.resize(to: CGSize(width: 1100, height: 800), backingScale: 3, documentSize: document)
        assertPoint(viewport.documentPoint(from: viewport.center, documentSize: document), centerPixel)
        XCTAssertEqual(viewport.rotation, 0.63, accuracy: 0.000001)
        XCTAssertEqual(viewport.zoom, 3)
        XCTAssertEqual(viewport.pan.width, oldPan.width * 2 / 3, accuracy: 0.000001)
        XCTAssertEqual(viewport.pan.height, oldPan.height * 2 / 3, accuracy: 0.000001)
    }

    func testFitPreservesAngleFitsRotatedBoundsAndFollowsResize() {
        var viewport = viewport()
        viewport.setRotation(.pi / 4, anchoredAt: CGPoint(x: 190, y: 450), documentSize: document)
        viewport.fit(documentSize: document)
        XCTAssertTrue(viewport.followsFit)
        XCTAssertEqual(viewport.rotation, .pi / 4)
        XCTAssertEqual(viewport.pan, .zero)
        var bounds = viewport.documentRect(document)
        XCTAssertLessThanOrEqual(bounds.width, 900 - 96 + 0.000001)
        XCTAssertEqual(bounds.height, 600 - 96, accuracy: 0.000001)
        assertPoint(CGPoint(x: bounds.midX, y: bounds.midY), viewport.center)
        viewport.resize(to: CGSize(width: 600, height: 1000), backingScale: 3, documentSize: document)
        bounds = viewport.documentRect(document)
        XCTAssertEqual(viewport.rotation, .pi / 4)
        XCTAssertEqual(bounds.width, 600 - 96, accuracy: 0.000001)
        XCTAssertLessThanOrEqual(bounds.height, 1000 - 96 + 0.000001)
        assertPoint(CGPoint(x: bounds.midX, y: bounds.midY), viewport.center)
    }

    func testResetRotationPreservesAnchorThenFitRecentersUpright() {
        var viewport = viewport()
        let anchor = CGPoint(x: 125, y: 450)
        viewport.setRotation(-0.9, anchoredAt: anchor, documentSize: document)
        let pixel = viewport.documentPoint(from: anchor, documentSize: document)
        viewport.resetRotation(anchoredAt: anchor, documentSize: document)
        XCTAssertEqual(viewport.rotation, 0)
        assertPoint(viewport.viewPoint(from: pixel, documentSize: document), anchor)
        viewport.setRotation(0.3, anchoredAt: anchor, documentSize: document)
        let centerPixel = viewport.documentPoint(from: viewport.center, documentSize: document)
        viewport.resetRotation(documentSize: document)
        assertPoint(viewport.documentPoint(from: viewport.center, documentSize: document), centerPixel)
        viewport.fit(documentSize: document)
        XCTAssertEqual(viewport.rotation, 0)
        XCTAssertEqual(viewport.pan, .zero)
        assertPoint(viewport.viewPoint(from: CGPoint(x: 600, y: 350), documentSize: document), viewport.center)
    }

    func testAngleNormalizationAndZoomClampingStillPreserveAnchor() {
        var viewport = viewport()
        let anchor = CGPoint(x: 211, y: 137)
        let pixel = viewport.documentPoint(from: anchor, documentSize: document)
        viewport.setRotation(8 * .pi + 0.25, anchoredAt: anchor, documentSize: document)
        XCTAssertEqual(viewport.rotation, 0.25, accuracy: 0.000001)
        assertPoint(viewport.viewPoint(from: pixel, documentSize: document), anchor)
        viewport.setZoom(1000, anchoredAt: anchor, documentSize: document)
        XCTAssertEqual(viewport.zoom, CanvasViewport.zoomRange.upperBound)
        assertPoint(viewport.viewPoint(from: pixel, documentSize: document), anchor)
        viewport.setZoom(-10, anchoredAt: anchor, documentSize: document)
        XCTAssertEqual(viewport.zoom, CanvasViewport.zoomRange.lowerBound)
        assertPoint(viewport.viewPoint(from: pixel, documentSize: document), anchor)
    }

    func testInvalidGestureAndLayoutValuesDoNotPoisonViewport() {
        var viewport = viewport()
        viewport.setRotation(0.4, anchoredAt: viewport.center, documentSize: document)
        let unchanged = viewport
        for value in [CGFloat.nan, .infinity, -.infinity] {
            viewport.setRotation(value, anchoredAt: viewport.center, documentSize: document)
            viewport.setZoom(value, anchoredAt: viewport.center, documentSize: document)
            viewport.translate(by: CGSize(width: value, height: 0))
            viewport.resize(to: CGSize(width: value, height: 600), backingScale: 2, documentSize: document)
            viewport.resize(to: CGSize(width: 900, height: 600), backingScale: value, documentSize: document)
            viewport.setRotation(1, anchoredAt: CGPoint(x: value, y: 0), documentSize: document)
            viewport.setZoom(3, anchoredAt: CGPoint(x: 0, y: value), documentSize: document)
            XCTAssertEqual(viewport, unchanged)
        }
        for badSize in [CGSize.zero, CGSize(width: -1, height: 700), CGSize(width: 1200, height: CGFloat.infinity)] {
            viewport.fit(documentSize: badSize)
            viewport.setRotation(1, anchoredAt: viewport.center, documentSize: badSize)
            viewport.setZoom(3, anchoredAt: viewport.center, documentSize: badSize)
            viewport.resize(to: CGSize(width: 1200, height: 900), backingScale: 2, documentSize: badSize)
            XCTAssertEqual(viewport, unchanged)
        }
        viewport.resize(to: CGSize(width: -1, height: 600), backingScale: 2, documentSize: document)
        viewport.resize(to: CGSize(width: 900, height: 600), backingScale: 0, documentSize: document)
        viewport.resize(to: CGSize(width: 900, height: 600), backingScale: .greatestFiniteMagnitude, documentSize: document)
        XCTAssertEqual(viewport, unchanged)
    }
}
