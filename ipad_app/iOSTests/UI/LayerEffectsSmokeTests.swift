import XCTest

final class LayerEffectsSmokeTests: XCTestCase {
    func testStrokePreviewCancelCommitUndoSaveReopenAndEditShadowInPortrait() throws {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.otherElements["editor.canvas"].waitForExistence(timeout: 15))
        app.buttons["文件菜单"].tap(); app.buttons["新建画稿"].tap(); app.navigationBars.buttons["完成"].tap()
        app.buttons["editor.content"].tap(); app.buttons["content.new.shape"].tap(); complete(app, id: "content.commit")
        edit(app); app.buttons["effects.add"].tap()
        XCTAssertTrue(app.textFields["effects.size"].waitForExistence(timeout: 5))
        app.buttons["effects.cancel"].tap()
        edit(app); XCTAssertTrue(app.buttons["effects.add"].exists); app.buttons["effects.add"].tap()
        complete(app, id: "effects.commit"); app.buttons["editor.undo"].tap()
        edit(app); XCTAssertTrue(app.buttons["effects.add"].exists); app.buttons["effects.cancel"].tap()
        app.buttons["editor.redo"].tap(); app.buttons["文件菜单"].tap(); app.buttons["保存工程"].tap(); app.terminate()
        XCUIDevice.shared.orientation = .portrait
        let reopened = XCUIApplication(); reopened.launch(); XCTAssertTrue(reopened.otherElements["editor.canvas"].waitForExistence(timeout: 15))
        edit(reopened); XCTAssertTrue(reopened.textFields["effects.size"].exists)
        reopened.buttons["effects.kind"].tap(); reopened.buttons["投影"].tap(); reopened.buttons["effects.add"].tap()
        XCTAssertTrue(reopened.textFields["effects.distance"].waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); attachment.name = "图层效果-竖屏再编辑投影"; attachment.lifetime = .keepAlways; add(attachment)
        complete(reopened, id: "effects.commit"); XCTAssertFalse(reopened.alerts["操作未完成"].exists)
    }
    private func edit(_ app: XCUIApplication) {
        app.buttons["editor.content"].tap(); app.buttons["effects.edit"].tap(); XCTAssertTrue(app.buttons["effects.cancel"].waitForExistence(timeout: 5))
    }
    private func complete(_ app: XCUIApplication, id: String) {
        let button = app.buttons[id]; XCTAssertTrue(button.waitForExistence(timeout: 5))
        let until = ProcessInfo.processInfo.systemUptime + 15
        while !button.isEnabled, ProcessInfo.processInfo.systemUptime < until { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertTrue(button.isEnabled); button.tap(); XCTAssertTrue(app.staticTexts["layers.count"].waitForExistence(timeout: 5))
    }
}
