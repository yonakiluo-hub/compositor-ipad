import XCTest

final class ClippingSmokeTests: XCTestCase {
    func testClippingCreateReleaseUndoAndReopen() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication()
        app.launch()
        let canvas = app.otherElements["editor.canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 15))
        let menu = app.buttons["文件菜单"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: menu)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        menu.tap()
        let create = app.buttons["新建画稿"]
        XCTAssertTrue(create.waitForExistence(timeout: 5)); create.tap()
        let done = app.navigationBars.buttons["完成"]
        XCTAssertTrue(done.waitForExistence(timeout: 5)); done.tap()
        let fill = app.buttons["editor.fill"]
        for _ in 0..<5 where !fill.isHittable { app.scrollViews["editor.tools"].swipeUp() }
        XCTAssertTrue(fill.isHittable); fill.tap()
        app.buttons["layer.add"].tap()
        let clip = app.buttons["layer.clipping"]
        XCTAssertTrue(clip.waitForExistence(timeout: 5))
        for _ in 0..<4 where !clip.isHittable { app.scrollViews["layers.controls"].swipeUp() }
        XCTAssertTrue(clip.isHittable); XCTAssertTrue(clip.isEnabled)
        clip.tap()
        XCTAssertEqual(clip.label, "释放剪贴蒙版")
        XCTAssertTrue(app.staticTexts["layer.clippingSource"].exists)
        fill.tap()
        clip.tap()
        XCTAssertEqual(clip.label, "创建剪贴蒙版")
        app.buttons["editor.undo"].tap()
        XCTAssertEqual(clip.label, "释放剪贴蒙版")
        app.buttons["editor.redo"].tap()
        XCTAssertEqual(clip.label, "创建剪贴蒙版")
        app.buttons["editor.undo"].tap()
        menu.tap()
        let save = app.buttons["保存工程"]
        XCTAssertTrue(save.waitForExistence(timeout: 5)); save.tap()
        XCTAssertFalse(app.alerts["操作未完成"].exists)
        app.terminate(); app.launch()
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["layers.count"].label, "2 个图层")
        XCTAssertEqual(app.buttons["layer.clipping"].label, "释放剪贴蒙版")
        XCTAssertTrue(app.staticTexts["layer.clippingSource"].exists)
        XCTAssertFalse(app.alerts["操作未完成"].exists)
    }
}
