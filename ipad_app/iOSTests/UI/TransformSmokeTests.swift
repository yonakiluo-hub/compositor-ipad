import XCTest

/// Uses a new synthetic document in an isolated simulator; no files or pairing
/// are imported. Geometry assertions read only the app's visible transform bar.
final class TransformSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    func testResizeRotateMoveCommitUndoCancelAndReopen() throws {
        let app = XCUIApplication()
        app.launch()
        let canvas = app.otherElements["editor.canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 15))
        app.buttons["文件菜单"].tap()
        app.buttons["新建画稿"].tap()
        app.buttons["完成"].tap()
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        let undo = app.buttons["editor.undo"], redo = app.buttons["editor.redo"]
        XCTAssertFalse(undo.isEnabled)

        // Viewing rotation must never become an artwork edit.
        canvas.rotate(.pi / 6, withVelocity: 1)
        let resetRotation = app.buttons["viewport.resetRotation"]
        wait(NSPredicate(format: "label != %@", "回正 0°"), on: resetRotation)
        XCTAssertFalse(undo.isEnabled)
        resetRotation.tap()
        wait(NSPredicate(format: "label == %@", "回正 0°"), on: resetRotation)
        XCTAssertFalse(undo.isEnabled)
        XCTAssertFalse(redo.isEnabled)

        let fill = app.buttons["填充图层或选区"]
        reveal(fill, in: app, upward: true)
        fill.tap()
        XCTAssertTrue(undo.isEnabled)
        let transformTool = app.buttons["tool.自由变换"]
        reveal(transformTool, in: app, upward: false)
        transformTool.tap()
        let geometry = app.staticTexts["transform.geometry"]
        XCTAssertTrue(geometry.waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["transform.aspect"].exists)
        let original = try readGeometry(geometry)
        XCTAssertEqual(original.width, 1200, accuracy: 0.1)
        XCTAssertEqual(original.height, 900, accuracy: 0.1)
        XCTAssertEqual(original.angle, 0, accuracy: 0.1)
        app.buttons["适合画布"].tap()

        // Fit uses a total 96 point inset. The new layer occupies all 1200×900
        // document pixels, so its handles can be located without a test-only API.
        let frame = canvas.frame
        let scale = min((frame.width - 96) / 1200, (frame.height - 96) / 900)
        let documentTopLeft = CGPoint(x: frame.midX - 600 * scale, y: frame.midY - 450 * scale)
        let bottomRight = CGPoint(x: documentTopLeft.x + 1200 * scale, y: documentTopLeft.y + 900 * scale)
        let smallerCorner = CGPoint(x: documentTopLeft.x + 660 * scale, y: documentTopLeft.y + 495 * scale)
        drag(canvas, from: bottomRight, to: smallerCorner)
        let resized = try readGeometry(geometry)
        XCTAssertLessThan(resized.width, 1000)
        XCTAssertGreaterThan(resized.width, 400)
        XCTAssertEqual(resized.width / resized.height, 4 / 3, accuracy: 0.01)

        let center = CGPoint(x: documentTopLeft.x + resized.width * scale / 2,
                             y: documentTopLeft.y + resized.height * scale / 2)
        let rotationRadius = resized.height * scale / 2 + 36
        let rotationStart = CGPoint(x: center.x, y: center.y - rotationRadius)
        let rotationEnd = CGPoint(x: center.x + sin(.pi / 6) * rotationRadius,
                                  y: center.y - cos(.pi / 6) * rotationRadius)
        drag(canvas, from: rotationStart, to: rotationEnd)
        let rotated = try readGeometry(geometry)
        XCTAssertGreaterThan(rotated.angle, 15)
        XCTAssertLessThan(rotated.angle, 45)
        XCTAssertEqual(rotated.width, resized.width, accuracy: 0.2)
        XCTAssertEqual(rotated.height, resized.height, accuracy: 0.2)

        let movedCenter = CGPoint(x: center.x + 40, y: center.y + 30)
        drag(canvas, from: center, to: movedCenter)
        let committedLabel = geometry.label
        XCTAssertEqual(try readGeometry(geometry), rotated, "Moving the interior preserves size and rotation")
        XCTAssertFalse(redo.isEnabled)
        XCTAssertFalse(app.alerts["操作未完成"].exists)
        app.buttons["transform.commit"].tap()
        XCTAssertFalse(app.buttons["transform.commit"].exists)

        // Many pointer samples and three separate drags must still be one edit.
        undo.tap()
        transformTool.tap()
        XCTAssertTrue(geometry.waitForExistence(timeout: 5))
        XCTAssertEqual(try readGeometry(geometry), original)
        app.buttons["transform.cancel"].tap()
        undo.tap() // The only remaining history entry is the initial fill.
        XCTAssertFalse(undo.isEnabled, "Preview samples must not create extra history entries")
        redo.tap() // Restore source pixels.
        XCTAssertTrue(redo.isEnabled)
        redo.tap() // Restore the entire completed transform.
        XCTAssertFalse(redo.isEnabled)
        transformTool.tap()
        XCTAssertTrue(geometry.waitForExistence(timeout: 5))
        XCTAssertEqual(geometry.label, committedLabel)

        // Start another resize, then cancel it. The committed transform survives.
        app.buttons["适合画布"].tap()
        let nextFrame = canvas.frame
        let nextScale = min((nextFrame.width - 96) / 1200, (nextFrame.height - 96) / 900)
        let nextTopLeft = CGPoint(x: nextFrame.midX - 600 * nextScale, y: nextFrame.midY - 450 * nextScale)
        let currentCenter = CGPoint(x: nextTopLeft.x + (resized.width / 2 + 40 / scale) * nextScale,
                                    y: nextTopLeft.y + (resized.height / 2 + 30 / scale) * nextScale)
        let angle = rotated.angle * .pi / 180
        let x = resized.width * nextScale / 2, y = resized.height * nextScale / 2
        let corner = CGPoint(x: currentCenter.x + x * cos(angle) - y * sin(angle),
                             y: currentCenter.y + x * sin(angle) + y * cos(angle))
        let cancelledCorner = CGPoint(x: currentCenter.x + (corner.x - currentCenter.x) * 0.8,
                                      y: currentCenter.y + (corner.y - currentCenter.y) * 0.8)
        drag(canvas, from: corner, to: cancelledCorner)
        XCTAssertLessThan(try readGeometry(geometry).width, rotated.width - 20)
        app.buttons["transform.cancel"].tap()
        transformTool.tap()
        XCTAssertTrue(geometry.waitForExistence(timeout: 5))
        XCTAssertEqual(geometry.label, committedLabel)
        app.buttons["transform.cancel"].tap()

        app.buttons["文件菜单"].tap()
        app.buttons["保存工程"].tap()
        app.terminate()
        app.launch()
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["transform.commit"].exists, "A draft session is never restored from disk")
        reveal(transformTool, in: app, upward: false)
        transformTool.tap()
        XCTAssertTrue(geometry.waitForExistence(timeout: 5))
        XCTAssertEqual(geometry.label, committedLabel)
        XCTAssertFalse(app.alerts["操作未完成"].exists)
        app.buttons["transform.cancel"].tap()
    }

    private struct Geometry: Equatable {
        let width: CGFloat
        let height: CGFloat
        let angle: CGFloat
    }

    private func readGeometry(_ element: XCUIElement) throws -> Geometry {
        let label = element.label
        let expression = try NSRegularExpression(pattern: #"-?\d+(?:\.\d+)?"#)
        let values = expression.matches(in: label, range: NSRange(label.startIndex..., in: label)).compactMap { match -> CGFloat? in
            guard let range = Range(match.range, in: label), let number = Double(label[range]) else { return nil }
            return CGFloat(number)
        }
        XCTAssertEqual(values.count, 3, "Unexpected transform summary: \(label)")
        guard values.count == 3 else { throw NSError(domain: "TransformSmokeTests", code: 1) }
        return Geometry(width: values[0], height: values[1], angle: values[2])
    }

    private func drag(_ canvas: XCUIElement, from start: CGPoint, to end: CGPoint) {
        let frame = canvas.frame
        let origin = canvas.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: start.x - frame.minX, dy: start.y - frame.minY))
            .press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: end.x - frame.minX, dy: end.y - frame.minY)))
    }

    private func reveal(_ button: XCUIElement, in app: XCUIApplication, upward: Bool) {
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        for _ in 0..<4 where !button.isHittable {
            if upward { app.scrollViews.firstMatch.swipeUp() } else { app.scrollViews.firstMatch.swipeDown() }
        }
        XCTAssertTrue(button.isHittable)
    }

    private func wait(_ predicate: NSPredicate, on element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let expected = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 5), .completed, file: file, line: line)
    }
}
