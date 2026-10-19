import XCTest

final class EditorSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    func testLaunchFingerPaintLayersUndoAndRelaunch() throws {
        let app = XCUIApplication()
        app.launch()
        let canvas = app.otherElements["editor.canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 15))
        app.buttons["文件菜单"].tap()
        app.buttons["新建画稿"].tap()
        app.buttons["完成"].tap()
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["editor.undo"].isEnabled)

        let finger = app.switches["finger.drawing"]
        XCTAssertTrue(finger.waitForExistence(timeout: 5))
        if finger.value as? String != "1" { finger.tap() }
        let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.45))
        let end = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.6, dy: 0.55))
        start.press(forDuration: 0.1, thenDragTo: end)
        XCTAssertTrue(app.buttons["editor.undo"].isEnabled)
        app.buttons["layer.add"].tap()
        XCTAssertTrue(app.staticTexts["2 个图层"].exists)
        app.buttons["editor.undo"].tap()
        XCTAssertTrue(app.staticTexts["1 个图层"].exists)
        app.buttons["editor.redo"].tap()
        XCTAssertTrue(app.staticTexts["2 个图层"].exists)
        app.buttons["文件菜单"].tap()
        app.buttons["保存工程"].tap()
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["2 个图层"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.alerts["操作未完成"].exists)
    }
}
