import XCTest

final class LayerContentSmokeTests: XCTestCase {
    private func launch() -> XCUIApplication {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.otherElements["editor.canvas"].waitForExistence(timeout:15))
        app.buttons["文件菜单"].tap(); app.buttons["新建画稿"].tap(); app.navigationBars.buttons["完成"].tap()
        return app
    }
    private func begin(_ kind: String, app: XCUIApplication) {
        app.buttons["editor.content"].tap(); app.buttons["content.new." + kind].tap()
        XCTAssertTrue(app.buttons["content.commit"].waitForExistence(timeout:5))
    }
    private func edit(_ app: XCUIApplication) {
        app.buttons["editor.content"].tap(); app.buttons["content.edit"].tap()
        XCTAssertTrue(app.buttons["content.cancel"].waitForExistence(timeout:5))
    }
    private func complete(_ app: XCUIApplication) {
        let button = app.buttons["content.commit"], until = ProcessInfo.processInfo.systemUptime + 15
        while !button.isEnabled, ProcessInfo.processInfo.systemUptime < until { Thread.sleep(forTimeInterval:0.2) }
        XCTAssertTrue(button.isEnabled); button.tap(); XCTAssertTrue(app.staticTexts["layers.count"].waitForExistence(timeout:5))
    }
    private func set(_ field: XCUIElement, _ value: String) {
        field.tap(); let count = (field.value as? String)?.count ?? 0
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: count) + value + "\n")
    }
    private func reveal(_ element: XCUIElement, scroll: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout:5))
        for _ in 0..<5 { if element.isHittable { return }; scroll.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }
    private func snapshot(_ name: String) {
        let a = XCTAttachment(screenshot:XCUIScreen.main.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }

    func testTextCreateUndoSaveReopenContinueEditingAndRasterizeUndo() throws {
        let app = launch(); begin("text", app:app)
        let text = app.textViews["content.text"]; XCTAssertTrue(text.waitForExistence(timeout:5)); text.tap(); text.typeText(" editable")
        snapshot("文字-可编辑正文与预览")
        complete(app); XCTAssertEqual(app.staticTexts["layers.count"].label,"2 个图层")
        app.buttons["editor.undo"].tap(); XCTAssertEqual(app.staticTexts["layers.count"].label,"1 个图层")
        app.buttons["editor.redo"].tap(); XCTAssertEqual(app.staticTexts["layers.count"].label,"2 个图层")
        app.buttons["文件菜单"].tap(); app.buttons["保存工程"].tap(); app.terminate()
        let reopened = XCUIApplication(); reopened.launch(); XCTAssertTrue(reopened.otherElements["editor.canvas"].waitForExistence(timeout:15))
        edit(reopened); XCTAssertTrue((reopened.textViews["content.text"].value as? String ?? "").contains("editable"))
        reopened.textViews["content.text"].tap(); reopened.textViews["content.text"].typeText(" again"); complete(reopened)
        XCTAssertEqual(reopened.staticTexts["layers.count"].label,"2 个图层")
        let rasterize = reopened.buttons["layer.rasterizeContent"]
        reveal(rasterize, scroll:reopened.scrollViews["layers.controls"]); rasterize.tap()
        XCTAssertFalse(reopened.buttons["layer.editContent"].exists); reopened.buttons["editor.undo"].tap()
        XCTAssertTrue(reopened.buttons["layer.editContent"].waitForExistence(timeout:5))
        XCTAssertFalse(reopened.alerts["操作未完成"].exists)
    }

    func testShapeRoundedCornersSurviveScalingAndPortraitReopenThenChangeToLine() throws {
        let app = launch(); begin("shape", app:app)
        set(app.textFields["content.cornerRadius"],"20"); app.switches["content.smoothing"].tap()
        snapshot("形状-圆角参数预览"); complete(app)
        let enlarge = app.buttons["放大"]
        reveal(enlarge, scroll:app.scrollViews["layers.controls"]); enlarge.tap()
        edit(app)
        XCTAssertEqual(app.textFields["content.cornerRadius"].value as? String,"20")
        let scaled = try XCTUnwrap(Double((app.textFields["content.width"].value as? String ?? "").replacingOccurrences(of:",",with:"")))
        XCTAssertGreaterThan(scaled,260); app.buttons["content.cancel"].tap()
        app.buttons["文件菜单"].tap(); app.buttons["保存工程"].tap(); app.terminate(); XCUIDevice.shared.orientation = .portrait
        let reopened = XCUIApplication(); reopened.launch(); XCTAssertTrue(reopened.otherElements["editor.canvas"].waitForExistence(timeout:15)); edit(reopened)
        let picker = reopened.segmentedControls["content.shapeKind"]; reveal(picker,scroll:reopened.scrollViews.firstMatch)
        picker.buttons["直线"].tap(); reveal(reopened.switches["content.verticalLine"],scroll:reopened.scrollViews.firstMatch)
        reopened.switches["content.verticalLine"].tap(); snapshot("形状-竖屏直线再编辑"); complete(reopened)
        XCTAssertEqual(reopened.staticTexts["layers.count"].label,"2 个图层")
        XCTAssertFalse(reopened.alerts["操作未完成"].exists)
    }

    func testEmptyNumericDraftBlocksCompletionUntilCorrected() {
        let app = launch(); begin("shape", app: app)
        let commit = app.buttons["content.commit"], deadline = ProcessInfo.processInfo.systemUptime + 15
        while !commit.isEnabled, ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertTrue(commit.isEnabled)
        let radius = app.textFields["content.cornerRadius"]
        radius.tap(); radius.typeText(XCUIKeyboardKey.delete.rawValue)
        XCTAssertTrue(app.staticTexts["content.cornerRadius.invalid"].exists)
        XCTAssertFalse(commit.isEnabled, "An empty number must not silently apply the previous value")
        radius.typeText("20"); app.switches["content.smoothing"].tap()
        XCTAssertFalse(app.staticTexts["content.cornerRadius.invalid"].exists)
        complete(app); edit(app)
        XCTAssertEqual(app.textFields["content.cornerRadius"].value as? String, "20")
        app.buttons["content.cancel"].tap()
    }
}
