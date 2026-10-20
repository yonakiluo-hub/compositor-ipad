import XCTest

/// Synthetic artwork created through the ordinary editor in the isolated QA
/// simulator. A soft selection must choose content scope and survive the edit.
final class SelectionTransformSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    func testMovingSelectionBeyondScaledLayerShowsNoticeAndCompletesWithoutAlert() throws {
        let app = XCUIApplication()
        app.launch()
        let canvas = app.otherElements["editor.canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 15))
        app.buttons["文件菜单"].tap()
        app.buttons["新建画稿"].tap()
        app.buttons["完成"].tap()
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        let finger = app.switches["finger.drawing"]
        if finger.value as? String != "1" { finger.tap() }
        let fill = app.buttons["填充图层或选区"]
        reveal(fill, in: app, upward: true)
        fill.tap()
        let tool = app.buttons["tool.自由变换"]
        reveal(tool, in: app, upward: false)
        tool.tap()
        let geometry = app.staticTexts["transform.geometry"]
        XCTAssertTrue(geometry.waitForExistence(timeout: 5))
        app.buttons["适合画布"].tap()
        let frame = canvas.frame, scale = fitScale(canvas.frame)
        let topLeft = CGPoint(x: frame.midX - 600 * scale, y: frame.midY - 450 * scale)
        drag(canvas, from: CGPoint(x: topLeft.x + 1200 * scale, y: topLeft.y + 900 * scale),
             to: CGPoint(x: topLeft.x + 660 * scale, y: topLeft.y + 495 * scale))
        XCTAssertLessThan(try values(geometry)[0], 800)
        app.buttons["transform.commit"].tap()

        let rectangle = app.buttons["tool.矩形选区"]
        reveal(rectangle, in: app, upward: false)
        rectangle.tap()
        app.buttons["适合画布"].tap()
        let selectionFrame = canvas.frame, selectionScale = fitScale(canvas.frame)
        let selectionOrigin = CGPoint(x: selectionFrame.midX - 600 * selectionScale,
                                      y: selectionFrame.midY - 450 * selectionScale)
        drag(canvas, from: CGPoint(x: selectionOrigin.x + 100 * selectionScale, y: selectionOrigin.y + 100 * selectionScale),
             to: CGPoint(x: selectionOrigin.x + 300 * selectionScale, y: selectionOrigin.y + 250 * selectionScale))
        XCTAssertEqual(app.staticTexts["selection.state"].label, "选区已启用")
        tool.tap()
        XCTAssertTrue(geometry.waitForExistence(timeout: 5))
        app.buttons["适合画布"].tap()
        let dragFrame = canvas.frame, dragScale = fitScale(canvas.frame)
        let origin = CGPoint(x: dragFrame.midX - 600 * dragScale, y: dragFrame.midY - 450 * dragScale)
        drag(canvas, from: CGPoint(x: origin.x + 200 * dragScale, y: origin.y + 175 * dragScale),
             to: CGPoint(x: origin.x + 900 * dragScale, y: origin.y + 175 * dragScale))
        let notice = app.staticTexts["transform.rasterizationNotice"]
        XCTAssertTrue(notice.label.contains("固定本层的缩放与旋转"))
        XCTAssertFalse(app.alerts["操作未完成"].exists)
        XCTAssertEqual(canvas.frame, dragFrame, "The notice must not resize the canvas and cancel its active drag")
        app.buttons["transform.commit"].tap()
        XCTAssertFalse(app.alerts["操作未完成"].exists)
        XCTAssertEqual(app.staticTexts["selection.state"].label, "选区已启用")
        app.buttons["editor.undo"].tap()
        app.buttons["editor.redo"].tap()
        XCTAssertEqual(app.staticTexts["selection.state"].label, "选区已启用")
        app.buttons["文件菜单"].tap()
        app.buttons["保存工程"].tap()
        app.terminate()
        app.launch()
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        tool.tap()
        XCTAssertTrue(geometry.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["transform.scope"].label.contains("变换选中内容"))
        XCTAssertFalse(app.alerts["操作未完成"].exists)
        app.buttons["transform.cancel"].tap()
    }

    func testFeatheredSelectionTransformUndoRedoAndReopen() throws {
        let app = XCUIApplication()
        app.launch()
        let canvas = app.otherElements["editor.canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 15))
        app.buttons["文件菜单"].tap()
        app.buttons["新建画稿"].tap()
        app.buttons["完成"].tap()
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        let finger = app.switches["finger.drawing"]
        if finger.value as? String != "1" { finger.tap() }
        let fill = app.buttons["填充图层或选区"]
        reveal(fill, in: app, upward: true)
        fill.tap()
        let rectangle = app.buttons["tool.矩形选区"]
        reveal(rectangle, in: app, upward: false)
        rectangle.tap()
        app.buttons["适合画布"].tap()
        let frame = canvas.frame
        let scale = fitScale(frame)
        // 360×300 document pixels, centered on the canvas.
        drag(canvas, from: CGPoint(x: frame.midX - 180 * scale, y: frame.midY - 150 * scale),
             to: CGPoint(x: frame.midX + 180 * scale, y: frame.midY + 150 * scale))
        let state = app.staticTexts["selection.state"]
        XCTAssertEqual(state.label, "选区已启用")
        app.buttons["羽化当前选区…"].tap()
        let apply = app.buttons["selection.applyFeather"]
        XCTAssertTrue(apply.waitForExistence(timeout: 5))
        apply.tap()

        let tool = app.buttons["tool.自由变换"]
        reveal(tool, in: app, upward: false)
        tool.tap()
        let geometry = app.staticTexts["transform.geometry"]
        XCTAssertTrue(geometry.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["transform.scope"].label.contains("变换选中内容"))
        let original = try values(geometry)
        XCTAssertGreaterThan(original[0], 360, "Feathered support belongs to the transform")
        XCTAssertLessThan(original[0], 500, "The handles must bound the selection, not the layer")
        XCTAssertLessThan(original[1], 450)
        app.buttons["适合画布"].tap()
        let transformFrame = canvas.frame
        let transformScale = fitScale(transformFrame)
        let topLeft = CGPoint(x: transformFrame.midX - original[0] * transformScale / 2,
                              y: transformFrame.midY - original[1] * transformScale / 2)
        let corner = CGPoint(x: topLeft.x + original[0] * transformScale,
                             y: topLeft.y + original[1] * transformScale)
        let smaller = CGPoint(x: topLeft.x + original[0] * transformScale * 0.7,
                              y: topLeft.y + original[1] * transformScale * 0.7)
        drag(canvas, from: corner, to: smaller)
        let resized = try values(geometry)
        XCTAssertLessThan(resized[0], original[0] * 0.9)
        XCTAssertEqual(resized[0] / resized[1], original[0] / original[1], accuracy: 0.01)
        let center = CGPoint(x: topLeft.x + resized[0] * transformScale / 2,
                             y: topLeft.y + resized[1] * transformScale / 2)
        let moved = CGPoint(x: center.x + 30, y: center.y + 15)
        drag(canvas, from: center, to: moved)
        let radius = resized[1] * transformScale / 2 + 36
        drag(canvas, from: CGPoint(x: moved.x, y: moved.y - radius),
             to: CGPoint(x: moved.x + sin(.pi / 6) * radius, y: moved.y - cos(.pi / 6) * radius))
        XCTAssertGreaterThan(try values(geometry)[2], 15)
        XCTAssertFalse(app.alerts["操作未完成"].exists)
        app.buttons["transform.commit"].tap()
        XCTAssertEqual(state.label, "选区已启用")
        app.buttons["editor.undo"].tap()
        tool.tap()
        XCTAssertTrue(geometry.waitForExistence(timeout: 5))
        XCTAssertEqual(try values(geometry), original, "One undo restores the original selection and pixels")
        app.buttons["transform.cancel"].tap()
        app.buttons["editor.redo"].tap()
        XCTAssertEqual(state.label, "选区已启用")
        tool.tap()
        XCTAssertTrue(geometry.waitForExistence(timeout: 5))
        // A committed selection uses its new axis-aligned nonzero bounds on the
        // next session; compare reopening with those bounds, not the rotated box.
        let committed = try values(geometry)
        XCTAssertNotEqual(committed, original)
        app.buttons["transform.cancel"].tap()
        app.buttons["文件菜单"].tap()
        app.buttons["保存工程"].tap()
        app.terminate()
        app.launch()
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        XCTAssertEqual(state.label, "选区已启用")
        reveal(tool, in: app, upward: false)
        tool.tap()
        XCTAssertTrue(geometry.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["transform.scope"].label.contains("变换选中内容"))
        XCTAssertEqual(try values(geometry), committed)
        XCTAssertFalse(app.alerts["操作未完成"].exists)
        app.buttons["transform.cancel"].tap()
    }

    private func fitScale(_ frame: CGRect) -> CGFloat {
        min((frame.width - 96) / 1200, (frame.height - 96) / 900)
    }

    private func values(_ element: XCUIElement) throws -> [CGFloat] {
        let label = element.label
        let expression = try NSRegularExpression(pattern: #"-?\d+(?:\.\d+)?"#)
        let result = expression.matches(in: label, range: NSRange(label.startIndex..., in: label)).compactMap { match -> CGFloat? in
            guard let range = Range(match.range, in: label), let value = Double(label[range]) else { return nil }
            return CGFloat(value)
        }
        XCTAssertEqual(result.count, 3)
        guard result.count == 3 else { throw NSError(domain: "SelectionTransformSmokeTests", code: 1) }
        return result
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
}
