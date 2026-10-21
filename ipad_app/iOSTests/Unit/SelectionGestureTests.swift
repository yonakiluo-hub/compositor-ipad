import XCTest
import UIKit
@testable import CompositorPad

final class SelectionGestureTests: XCTestCase {
    private func draft(_ kind: SelectionGestureDraft.Kind, start: CGPoint = CGPoint(x: 10, y: 10),
                       documentID: UUID = UUID(), mode: SelectionCombineMode = .replace, feather: Double = 0) -> SelectionGestureDraft {
        .init(kind: kind, at: start, documentID: documentID, revision: 7, mode: mode, feather: feather)
    }

    func testFreehandFinishesOnReleaseWithFrozenOptionsAndQuarterPixelSampling() throws {
        var outline = draft(.freehand, mode: .subtract, feather: 8)
        outline.move(to: CGPoint(x: 10.1, y: 10.1))
        XCTAssertEqual(outline.points.count, 1)
        outline.move(to: CGPoint(x: 50, y: 10))
        outline.move(to: CGPoint(x: 50, y: 40))
        let shape = try XCTUnwrap(outline.end(at: CGPoint(x: 10, y: 40), closingDistance: 12))
        guard case .polygon(let points) = shape else { return XCTFail("Freehand must produce a polygon") }
        XCTAssertEqual(points, [CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 10), CGPoint(x: 50, y: 40), CGPoint(x: 10, y: 40)])
        XCTAssertEqual(outline.mode, .subtract)
        XCTAssertEqual(outline.feather, 8)
        let mask = try SelectionMask.rasterize(shape, width: 64, height: 48)
        let samples = try XCTUnwrap(mask.dataProvider?.data) as Data
        XCTAssertEqual(samples[20 * mask.bytesPerRow + 20], 255, "Rasterization must close the release edge")
        XCTAssertEqual(samples[20 * mask.bytesPerRow + 5], 0)
    }

    func testPolygonOnlyCommitsVerticesOnTouchUpAndClosesNearFirstVertex() throws {
        var outline = draft(.polygonal)
        outline.move(to: CGPoint(x: 40, y: 10))
        XCTAssertTrue(outline.points.isEmpty)
        outline.cancelPointer()
        XCTAssertTrue(outline.points.isEmpty, "Cancelled first touch must not leave an accidental vertex")
        XCTAssertNil(outline.end(at: CGPoint(x: 10, y: 10), closingDistance: 2))
        outline.move(to: CGPoint(x: 40, y: 10))
        outline.cancelPointer()
        XCTAssertEqual(outline.points, [CGPoint(x: 10, y: 10)], "Pan/pinch must preserve only previously committed vertices")
        XCTAssertNil(outline.end(at: CGPoint(x: 40, y: 10), closingDistance: 2))
        XCTAssertNil(outline.end(at: CGPoint(x: 40, y: 40), closingDistance: 2))
        let shape = try XCTUnwrap(outline.end(at: CGPoint(x: 11, y: 10), closingDistance: 2))
        guard case .polygon(let points) = shape else { return XCTFail("Polygon tool returned another shape") }
        XCTAssertEqual(points.count, 3, "Closing tap must not add a redundant near-first vertex")
        XCTAssertEqual(points.first, CGPoint(x: 10, y: 10))
    }

    func testPolygonCloseToleranceUsesScreenPointsAfterZoomAndPan() throws {
        let size = CGSize(width: 1200, height: 900)
        for zoom in [CGFloat(0.5), 2, 8] {
            var viewport = CanvasViewport()
            viewport.resize(to: CGSize(width: 1024, height: 768), backingScale: 2, documentSize: size)
            viewport.setZoom(zoom, anchoredAt: CGPoint(x: 300, y: 250), documentSize: size)
            viewport.translate(by: CGSize(width: 53, height: -27))
            let first = CGPoint(x: 200, y: 180)
            var outline = draft(.polygonal, start: first)
            for point in [first, CGPoint(x: 400, y: 180), CGPoint(x: 400, y: 350)] {
                let viewPoint = viewport.viewPoint(from: point, documentSize: size)
                let recovered = viewport.documentPoint(from: viewPoint, documentSize: size)
                _ = outline.end(at: recovered, closingDistance: 12 / viewport.pointsPerPixel)
            }
            let startOnScreen = viewport.viewPoint(from: first, documentSize: size)
            let closeOnScreen = CGPoint(x: startOnScreen.x + 10, y: startOnScreen.y)
            let shape = try XCTUnwrap(outline.end(at: viewport.documentPoint(from: closeOnScreen, documentSize: size),
                                                 closingDistance: 12 / viewport.pointsPerPixel))
            guard case .polygon(let points) = shape else { return XCTFail("Expected closed polygon") }
            XCTAssertEqual(points.count, 3)
            XCTAssertEqual(points[0].x, first.x, accuracy: 0.000_001)
            XCTAssertEqual(points[0].y, first.y, accuracy: 0.000_001)
        }
    }

    func testPolygonUndoAndFinishIgnoreUncommittedRubberBandPoint() throws {
        var outline = draft(.polygonal)
        for point in [CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 10), CGPoint(x: 50, y: 40), CGPoint(x: 10, y: 40)] {
            _ = outline.end(at: point, closingDistance: 1)
        }
        outline.move(to: CGPoint(x: 100, y: 100))
        outline.undoPoint()
        XCTAssertNil(outline.cursor)
        guard case .polygon(let points) = try XCTUnwrap(outline.finishedShape()) else { return XCTFail("Expected polygon") }
        XCTAssertEqual(points, [CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 10), CGPoint(x: 50, y: 40)])
        outline.undoPoint()
        XCTAssertNil(outline.finishedShape())
        outline.undoPoint(); outline.undoPoint(); outline.undoPoint()
        XCTAssertTrue(outline.points.isEmpty)
    }

    func testRectangleAndEllipseUseSameFrozenShapeGestureAndAllowReverseDrag() throws {
        for kind in [SelectionGestureDraft.Kind.rectangle, .ellipse] {
            var outline = draft(kind, start: CGPoint(x: 40, y: 30), mode: .intersect, feather: 4)
            let shape = try XCTUnwrap(outline.end(at: CGPoint(x: 10, y: 5), closingDistance: 12))
            let rect: CGRect
            switch shape {
            case .rectangle(let box), .ellipse(let box): rect = box
            default: return XCTFail("Marquee must preserve shape kind")
            }
            XCTAssertEqual(rect, CGRect(x: 10, y: 5, width: 30, height: 25))
            XCTAssertEqual(outline.mode, .intersect)
            XCTAssertEqual(outline.feather, 4)
        }
    }

    func testDegenerateTapsAndLinesDoNotReplaceSelectionButEvenOddCrossingCanFinish() {
        var tap = draft(.freehand)
        XCTAssertNil(tap.end(at: CGPoint(x: 10, y: 10), closingDistance: 12))
        var line = draft(.freehand)
        line.move(to: CGPoint(x: 20, y: 20)); line.move(to: CGPoint(x: 30, y: 30))
        XCTAssertNil(line.finishedShape())
        var crossing = draft(.freehand)
        crossing.move(to: CGPoint(x: 40, y: 40)); crossing.move(to: CGPoint(x: 10, y: 40))
        XCTAssertNotNil(crossing.end(at: CGPoint(x: 40, y: 10), closingDistance: 12))
        let count = crossing.points.count
        crossing.move(to: CGPoint(x: CGFloat.nan, y: 0))
        crossing.move(to: CGPoint(x: 0, y: CGFloat.infinity))
        XCTAssertEqual(crossing.points.count, count)
    }

    func testContextChangesInvalidateDraftAndCommandsAlwaysHaveNewIdentity() {
        let documentID = UUID()
        let outline = draft(.polygonal, documentID: documentID)
        XCTAssertTrue(outline.matches(documentID: documentID, revision: 7, kind: .polygonal))
        XCTAssertFalse(outline.matches(documentID: UUID(), revision: 7, kind: .polygonal))
        XCTAssertFalse(outline.matches(documentID: documentID, revision: 8, kind: .polygonal))
        XCTAssertFalse(outline.matches(documentID: documentID, revision: 7, kind: .freehand))
        XCTAssertFalse(outline.matches(documentID: documentID, revision: 7, kind: nil))
        XCTAssertNotEqual(SelectionGestureCommand(.undoPoint).id, SelectionGestureCommand(.undoPoint).id)
    }

    func testLongOutlineRejectsWholeShapeWithoutTruncationOrUnboundedStorage() {
        for kind in [SelectionGestureDraft.Kind.freehand, .polygonal] {
            var outline = draft(kind, start: .zero)
            if kind == .polygonal { _ = outline.end(at: .zero, closingDistance: 0) }
            for i in 1..<20_000 {
                let point = CGPoint(x: i, y: i % 2)
                if kind == .freehand { outline.move(to: point) }
                else { _ = outline.end(at: point, closingDistance: 0) }
            }
            XCTAssertFalse(outline.exceedsPointLimit)
            XCTAssertNotNil(outline.finishedShape())
            _ = outline.end(at: CGPoint(x: 19_999, y: 1), closingDistance: 0)
            XCTAssertFalse(outline.exceedsPointLimit, "A repeated final sample must not count as another vertex")
            XCTAssertNil(outline.end(at: CGPoint(x: 20_000, y: 0), closingDistance: 0))
            XCTAssertTrue(outline.exceedsPointLimit)
            XCTAssertNil(outline.finishedShape(), "A truncated prefix must never become the committed selection")
            for i in 20_001...20_010 { outline.move(to: CGPoint(x: i, y: i % 2)) }
            XCTAssertEqual(outline.points.count, 20_000)
            XCTAssertNil(outline.finishedShape())
        }
    }
}
