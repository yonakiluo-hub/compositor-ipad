import XCTest

final class ImageSelectionSmokeTests:XCTestCase {
    func testWandResizeUndoRedoAndReopen() throws {
        continueAfterFailure=false;XCUIDevice.shared.orientation = .landscapeLeft
        let app=XCUIApplication();app.launch()
        XCTAssertTrue(app.otherElements["editor.canvas"].waitForExistence(timeout:15))
        app.buttons["文件菜单"].tap();app.buttons["新建画稿"].tap();app.navigationBars.buttons["完成"].tap()
        let tools=app.scrollViews["editor.tools"],fill=app.buttons["editor.fill"]
        reveal(fill,in:tools);fill.tap()
        let wand=tools.buttons["tool.魔棒"];reveal(wand,in:tools);wand.tap()
        XCTAssertTrue(app.sliders["wand.tolerance"].exists)
        let canvas=app.otherElements["editor.canvas"]
        canvas.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).tap()
        label("选区已启用",in:app.staticTexts["selection.state"])
        app.buttons["editor.undo"].tap();label("无选区",in:app.staticTexts["selection.state"])
        XCTAssertTrue(app.buttons["editor.redo"].isEnabled);app.buttons["editor.redo"].tap()
        label("选区已启用",in:app.staticTexts["selection.state"])
        let operations=tools.buttons["选区操作"];reveal(operations,in:tools);operations.tap()
        app.buttons["selection.resize"].tap()
        XCTAssertTrue(app.sliders["selection.resizeRadius"].waitForExistence(timeout:5))
        app.segmentedControls.buttons["收缩"].tap();app.buttons["selection.resizeApply"].tap()
        label("选区已启用",in:app.staticTexts["selection.state"])
        app.buttons["editor.undo"].tap();XCTAssertTrue(app.buttons["editor.redo"].isEnabled)
        app.buttons["editor.redo"].tap();app.buttons["文件菜单"].tap();app.buttons["保存工程"].tap()
        app.terminate();let reopened=XCUIApplication();reopened.launch()
        XCTAssertTrue(reopened.otherElements["editor.canvas"].waitForExistence(timeout:15))
        label("选区已启用",in:reopened.staticTexts["selection.state"])
        XCTAssertEqual(reopened.staticTexts["layers.count"].label,"1 个图层")
        XCTAssertFalse(reopened.alerts["操作未完成"].exists)
    }
    private func reveal(_ element:XCUIElement,in scroll:XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout:5))
        for _ in 0..<5 {if element.isHittable {return};scroll.swipeUp()}
        XCTAssertTrue(element.isHittable)
    }
    private func label(_ value:String,in element:XCUIElement) {
        let deadline=Date().addingTimeInterval(20)
        repeat {if element.exists,element.label == value{return};Thread.sleep(forTimeInterval:0.2)} while Date()<deadline
        XCTAssertEqual(element.label,value)
    }
}
