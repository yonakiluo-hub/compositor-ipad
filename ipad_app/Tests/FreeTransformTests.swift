import XCTest
import CoreGraphics
@testable import CompositorKit

final class FreeTransformTests: XCTestCase {
    private let resizeHandles = TransformHandle.allCases.filter { $0.unitPoint != nil }

    private func moved(_ point: CGPoint, by delta: CGPoint) -> CGPoint {
        CGPoint(x: point.x + delta.x, y: point.y + delta.y)
    }

    private func rotated(_ vector: CGPoint, degrees: CGFloat) -> CGPoint {
        let angle = degrees * .pi / 180
        return CGPoint(x: vector.x * cos(angle) - vector.y * sin(angle),
                       y: vector.x * sin(angle) + vector.y * cos(angle))
    }

    private func assertPoint(_ actual: CGPoint, _ expected: CGPoint,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.x, expected.x, accuracy: 0.000001, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: 0.000001, file: file, line: line)
    }

    func testHandlesFollowClockwiseBoundsAndExcludeMoveAndRotation() {
        XCTAssertEqual(resizeHandles, [.topLeft, .top, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .left])
        XCTAssertEqual(resizeHandles.compactMap(\.unitPoint), [CGPoint(x: 0, y: 0), CGPoint(x: 0.5, y: 0),
            CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 0.5), CGPoint(x: 1, y: 1), CGPoint(x: 0.5, y: 1),
            CGPoint(x: 0, y: 1), CGPoint(x: 0, y: 0.5)])
        XCTAssertNil(TransformHandle.rotate.unitPoint)
        XCTAssertNil(TransformHandle.translate.unitPoint)
    }

    func testEveryRotatedAndFlippedHandleKeepsItsOppositeAnchor() throws {
        for rotation: CGFloat in [0, 37, 90, -145] {
            for flipX in [false, true] { for flipY in [false, true] {
                let original = LayerTransform(origin: CGPoint(x: 31.25, y: -19.5), size: CGSize(width: 200, height: 100),
                                              rotation: rotation, flipX: flipX, flipY: flipY, sampling: .nearest)
                for handle in resizeHandles { for lock in [false, true] {
                    let unit = try XCTUnwrap(handle.unitPoint)
                    let opposite = CGPoint(x: 1 - unit.x, y: 1 - unit.y)
                    let start = moved(original.point(unit), by: CGPoint(x: 3.25, y: -4.5))
                    let gesture = FreeTransformGesture(transform: original, handle: handle, start: start, lockAspect: lock)
                    XCTAssertEqual(gesture.updated(to: start), original, "An imprecise grab must not jump")
                    let delta = rotated(CGPoint(x: (unit.x * 2 - 1) * 34, y: (unit.y * 2 - 1) * 17), degrees: rotation)
                    let changed = try XCTUnwrap(gesture.updated(to: moved(start, by: delta)))
                    assertPoint(changed.point(opposite), original.point(opposite))
                    XCTAssertEqual(changed.size.width, unit.x == 0.5 && !lock ? 200 : 234, accuracy: 0.000001)
                    XCTAssertEqual(changed.size.height, unit.y == 0.5 && !lock ? 100 : 117, accuracy: 0.000001)
                    XCTAssertEqual(changed.rotation, original.rotation)
                    XCTAssertEqual(changed.flipX, flipX)
                    XCTAssertEqual(changed.flipY, flipY)
                    XCTAssertEqual(changed.sampling, .nearest)
                    XCTAssertTrue(changed.isValid)
                }}
            }}
        }
    }

    func testLockedCornersProjectOntoOriginalDiagonal() throws {
        let original = LayerTransform(origin: CGPoint(x: 20, y: 30), size: CGSize(width: 200, height: 100))
        for handle in [TransformHandle.topLeft, .topRight, .bottomRight, .bottomLeft] {
            let unit = try XCTUnwrap(handle.unitPoint)
            let start = original.point(unit)
            let pointer = moved(start, by: CGPoint(x: (unit.x * 2 - 1) * 20, y: (unit.y * 2 - 1) * 40))
            let locked = try XCTUnwrap(FreeTransformGesture(transform: original, handle: handle, start: start,
                                                           lockAspect: true).updated(to: pointer))
            // (220, 140) projects onto the (200, 100) diagonal at 1.16 times its original length.
            XCTAssertEqual(locked.size.width, 232, accuracy: 0.000001)
            XCTAssertEqual(locked.size.height, 116, accuracy: 0.000001)
            let free = try XCTUnwrap(FreeTransformGesture(transform: original, handle: handle, start: start,
                                                         lockAspect: false).updated(to: pointer))
            XCTAssertEqual(free.size, CGSize(width: 220, height: 140))
            assertPoint(locked.point(CGPoint(x: 1 - unit.x, y: 1 - unit.y)),
                        original.point(CGPoint(x: 1 - unit.x, y: 1 - unit.y)))
        }
    }

    func testEdgeHandlesIgnoreTangentialMovementAndLockAspectAroundOppositeMidpoint() throws {
        let original = LayerTransform(origin: CGPoint(x: 20, y: 30), size: CGSize(width: 200, height: 100))
        let start = original.point(CGPoint(x: 0.5, y: 0))
        let free = FreeTransformGesture(transform: original, handle: .top, start: start)
        XCTAssertEqual(free.updated(to: moved(start, by: CGPoint(x: 50, y: 0))), original)
        let locked = try XCTUnwrap(FreeTransformGesture(transform: original, handle: .top, start: start,
                                                       lockAspect: true).updated(to: moved(start, by: CGPoint(x: 50, y: -20))))
        XCTAssertEqual(locked.size, CGSize(width: 240, height: 120))
        XCTAssertEqual(locked.origin, CGPoint(x: 0, y: 10))
        assertPoint(locked.point(CGPoint(x: 0.5, y: 1)), original.point(CGPoint(x: 0.5, y: 1)))
    }

    func testCrossingEveryOppositeEdgeClampsWithoutTogglingFlips() throws {
        for flipX in [false, true] { for flipY in [false, true] {
            let original = LayerTransform(origin: CGPoint(x: 100, y: 70), size: CGSize(width: 200, height: 100),
                                          rotation: 37, flipX: flipX, flipY: flipY)
            for handle in resizeHandles { for lock in [false, true] {
                let unit = try XCTUnwrap(handle.unitPoint)
                let start = original.point(unit)
                let delta = rotated(CGPoint(x: -(unit.x * 2 - 1) * 600, y: -(unit.y * 2 - 1) * 300), degrees: 37)
                let changed = try XCTUnwrap(FreeTransformGesture(transform: original, handle: handle, start: start,
                                                               lockAspect: lock).updated(to: moved(start, by: delta)))
                XCTAssertEqual(changed.size.width, lock ? 2 : (unit.x == 0.5 ? 200 : 1), accuracy: 0.000001)
                XCTAssertEqual(changed.size.height, lock ? 1 : (unit.y == 0.5 ? 100 : 1), accuracy: 0.000001)
                XCTAssertEqual(changed.flipX, flipX)
                XCTAssertEqual(changed.flipY, flipY)
                assertPoint(changed.point(CGPoint(x: 1 - unit.x, y: 1 - unit.y)),
                            original.point(CGPoint(x: 1 - unit.x, y: 1 - unit.y)))
            }}
        }}
    }

    func testTranslationUsesFrozenStartAndAllowsValidOffCanvasPlacement() throws {
        let original = LayerTransform(origin: CGPoint(x: 10, y: 20), size: CGSize(width: 200, height: 100),
                                      rotation: 37, flipX: true, flipY: true, sampling: .smooth)
        let start = CGPoint(x: 70, y: 90)
        let gesture = FreeTransformGesture(transform: original, handle: .translate, start: start, lockAspect: true)
        let first = try XCTUnwrap(gesture.updated(to: CGPoint(x: 100, y: 140)))
        XCTAssertEqual(first.origin, CGPoint(x: 40, y: 70))
        let second = try XCTUnwrap(gesture.updated(to: CGPoint(x: -200, y: -100)))
        XCTAssertEqual(second.origin, CGPoint(x: -260, y: -170))
        var expected = original
        expected.origin = second.origin
        XCTAssertEqual(second, expected)
        XCTAssertEqual(gesture.updated(to: start), original)
    }

    func testRotationUsesClockwiseCenterAngleAndNormalizesAcrossBranchCut() throws {
        let original = LayerTransform(origin: CGPoint(x: 20, y: 30), size: CGSize(width: 200, height: 100),
                                      rotation: 170, flipX: true, flipY: true, sampling: .nearest)
        let center = original.center
        let start = moved(center, by: CGPoint(x: 50, y: 0))
        let gesture = FreeTransformGesture(transform: original, handle: .rotate, start: start)
        let rotated = try XCTUnwrap(gesture.updated(to: moved(center, by: CGPoint(x: 0, y: 50))))
        var expected = original
        expected.rotation = -100
        XCTAssertEqual(rotated, expected)
        let branchStart = moved(center, by: self.rotated(CGPoint(x: 50, y: 0), degrees: 179))
        let branchEnd = moved(center, by: self.rotated(CGPoint(x: 50, y: 0), degrees: -179))
        let branch = try XCTUnwrap(FreeTransformGesture(transform: original, handle: .rotate, start: branchStart)
            .updated(to: branchEnd))
        XCTAssertEqual(branch.rotation, 172, accuracy: 0.000001)
        XCTAssertEqual(branch.center, center)
        XCTAssertEqual(gesture.updated(to: start), original)
    }

    func testNoMotionKeepsUnnormalizedAngleAndMaximumFiniteAngleCanRotate() throws {
        var original = LayerTransform(origin: CGPoint(x: 10, y: 20), size: CGSize(width: 80, height: 40), rotation: 720.5)
        for handle in TransformHandle.allCases {
            let start = original.point(handle.unitPoint ?? CGPoint(x: 1, y: 0))
            XCTAssertEqual(FreeTransformGesture(transform: original, handle: handle, start: start).updated(to: start), original)
        }
        let radialStart = moved(original.center, by: CGPoint(x: 40, y: 0))
        XCTAssertEqual(FreeTransformGesture(transform: original, handle: .rotate, start: radialStart)
            .updated(to: moved(original.center, by: CGPoint(x: 80, y: 0))), original)
        original.rotation = .greatestFiniteMagnitude
        let start = moved(original.center, by: CGPoint(x: 40, y: 0))
        let target = moved(original.center, by: CGPoint(x: 0, y: 40))
        let rotated = try XCTUnwrap(FreeTransformGesture(transform: original, handle: .rotate, start: start).updated(to: target))
        XCTAssertTrue(rotated.rotation.isFinite)
        XCTAssertTrue((-180..<180).contains(rotated.rotation))
        XCTAssertEqual(rotated.center, original.center)
    }

    func testInvalidInputsAndUnsupportedPlacementsReturnNil() throws {
        let original = LayerTransform(size: CGSize(width: 200, height: 100))
        for invalid: CGFloat in [.nan, .infinity, -.infinity] {
            for handle in TransformHandle.allCases {
                let start = CGPoint(x: 200, y: 100)
                XCTAssertNil(FreeTransformGesture(transform: original, handle: handle, start: start)
                    .updated(to: CGPoint(x: invalid, y: 50)))
                XCTAssertNil(FreeTransformGesture(transform: original, handle: handle, start: CGPoint(x: 50, y: invalid))
                    .updated(to: start))
            }
            var bad = original
            bad.rotation = invalid
            XCTAssertNil(FreeTransformGesture(transform: bad, handle: .translate, start: .zero).updated(to: .zero))
        }
        var bad = original
        bad.size.width = 0
        XCTAssertNil(FreeTransformGesture(transform: bad, handle: .right, start: .zero).updated(to: .zero))
        let move = FreeTransformGesture(transform: original, handle: .translate, start: .zero)
        XCTAssertNil(move.updated(to: CGPoint(x: 1_000_001, y: 0)))
        XCTAssertNil(move.updated(to: CGPoint(x: CGFloat.greatestFiniteMagnitude, y: 0)))
        XCTAssertNotNil(move.updated(to: CGPoint(x: -1_000_000, y: 1_000_000)))
        let resize = FreeTransformGesture(transform: original, handle: .bottomRight, start: CGPoint(x: 200, y: 100))
        XCTAssertNotNil(resize.updated(to: CGPoint(x: 300_000, y: 300_000)))
        XCTAssertNil(resize.updated(to: CGPoint(x: 300_001, y: 100)))
        XCTAssertNil(resize.updated(to: CGPoint(x: 200, y: 300_001)))
        let hugeStart = CGPoint(x: -CGFloat.greatestFiniteMagnitude, y: 0)
        XCTAssertNil(FreeTransformGesture(transform: original, handle: .right, start: hugeStart)
            .updated(to: CGPoint(x: CGFloat.greatestFiniteMagnitude, y: 0)))
    }

    func testRotationAtCenterIsUndefinedAndRejected() {
        let original = LayerTransform(origin: CGPoint(x: 20, y: 30), size: CGSize(width: 200, height: 100))
        let start = moved(original.center, by: CGPoint(x: 50, y: 0))
        XCTAssertNil(FreeTransformGesture(transform: original, handle: .rotate, start: original.center).updated(to: start))
        XCTAssertNil(FreeTransformGesture(transform: original, handle: .rotate, start: start).updated(to: original.center))
        XCTAssertNil(FreeTransformGesture(transform: original, handle: .rotate, start: original.center).updated(to: original.center))
    }
}
