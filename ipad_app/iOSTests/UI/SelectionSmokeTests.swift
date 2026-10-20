import XCTest

/// Run on an isolated simulator. This test creates its own blank document through
/// the normal UI and never imports pairing, sends artwork or erases existing files.
final class SelectionSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    func testPolygonFinishFeatherUndoRedoSaveAndReopen() throws {
        let app = XCUIApplication()
        app.launch()
        let canvas = app.otherElements["editor.canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 15))
        app.buttons["文件菜单"].tap()
        app.buttons["新建画稿"].tap()
        app.buttons["完成"].tap()
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        let selection = app.staticTexts["selection.state"]
        waitForLabel("无选区", on: selection)
        let undo = app.buttons["editor.undo"], redo = app.buttons["editor.redo"]
        XCTAssertFalse(undo.isEnabled)

        let finger = app.switches["finger.drawing"]
        XCTAssertTrue(finger.waitForExistence(timeout: 5))
        if finger.value as? String != "1" { finger.tap() }
        let polygon = app.buttons["tool.多边形套索"]
        XCTAssertTrue(polygon.waitForExistence(timeout: 5))
        polygon.tap()
        for offset in [CGVector(dx: 0.35, dy: 0.35), CGVector(dx: 0.65, dy: 0.35),
                       CGVector(dx: 0.65, dy: 0.60), CGVector(dx: 0.35, dy: 0.60)] {
            canvas.coordinate(withNormalizedOffset: offset).tap()
        }
        let finish = app.buttons["selection.finish"]
        let canFinish = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: finish)
        XCTAssertEqual(XCTWaiter.wait(for: [canFinish], timeout: 5), .completed)
        finish.tap()
        waitForLabel("选区已启用", on: selection)
        XCTAssertTrue(undo.isEnabled)
        XCTAssertFalse(app.alerts["操作未完成"].exists)

        // The marquee toolbar exposes the same current-selection feather sheet;
        // changing tools after completion must preserve the committed selection.
        app.buttons["tool.矩形选区"].tap()
        app.buttons["羽化当前选区…"].tap()
        let applyFeather = app.buttons["selection.applyFeather"]
        XCTAssertTrue(applyFeather.waitForExistence(timeout: 5))
        XCTAssertTrue(app.sliders["selection.existingFeather"].exists)
        applyFeather.tap() // Default radius is 8 document pixels.
        waitForLabel("选区已启用", on: selection)
        XCTAssertFalse(app.alerts["操作未完成"].exists)

        undo.tap() // Feather is exactly one transaction.
        waitForLabel("选区已启用", on: selection)
        undo.tap() // All polygon vertices form exactly one transaction.
        waitForLabel("无选区", on: selection)
        XCTAssertFalse(undo.isEnabled, "Vertex taps must never create paint strokes or extra edits")
        redo.tap()
        waitForLabel("选区已启用", on: selection)
        redo.tap()
        waitForLabel("选区已启用", on: selection)
        XCTAssertFalse(redo.isEnabled)

        app.buttons["文件菜单"].tap()
        app.buttons["保存工程"].tap()
        app.terminate()
        app.launch()
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        waitForLabel("选区已启用", on: app.staticTexts["selection.state"])
        XCTAssertFalse(app.alerts["操作未完成"].exists)
    }

    private func waitForLabel(_ value: String, on element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", value), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 5), .completed, file: file, line: line)
    }
}
