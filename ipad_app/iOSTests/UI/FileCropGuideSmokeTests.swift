import XCTest

final class FileCropGuideSmokeTests: XCTestCase {
    private func artwork() -> XCUIApplication {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.otherElements["editor.canvas"].waitForExistence(timeout: 15))
        app.buttons["文件菜单"].tap(); app.buttons["新建画稿"].tap(); app.navigationBars.buttons["完成"].tap()
        return app
    }
    private func crop(_ app: XCUIApplication) {
        app.buttons["文件菜单"].tap(); app.buttons["canvas.crop"].tap()
        XCTAssertTrue(app.buttons["crop.commit"].waitForExistence(timeout: 5))
    }
    private func guides(_ app: XCUIApplication) {
        app.buttons["文件菜单"].tap(); app.buttons["canvas.guides"].tap()
        XCTAssertTrue(app.buttons["guides.done"].waitForExistence(timeout: 5))
    }
    private func reveal(_ element: XCUIElement, in scroll: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        for _ in 0..<6 { if element.isHittable { return }; scroll.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }
    private func closed(_ button: XCUIElement) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: button)], timeout: 10), .completed)
    }

    func testCropRatioPreviewCommitUndoNoOpRedoAndReopen() throws {
        let app = artwork(), original = app.staticTexts["canvas.size"].label
        crop(app)
        app.buttons["crop.cancel"].tap(); closed(app.buttons["crop.cancel"])
        XCTAssertEqual(app.staticTexts["canvas.size"].label, original)
        crop(app)
        app.buttons["crop.ratio"].tap(); app.buttons["16:9"].tap()
        app.buttons["crop.applyRatio"].tap(); reveal(app.buttons["crop.preview"], in: app.scrollViews.firstMatch); app.buttons["crop.preview"].tap()
        XCTAssertTrue(app.images["crop.previewImage"].exists)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); attachment.name = "裁切-保留框外像素预览"; attachment.lifetime = .keepAlways; add(attachment)
        app.buttons["crop.commit"].tap(); closed(app.buttons["crop.commit"])
        let cropped = app.staticTexts["canvas.size"].label
        XCTAssertNotEqual(cropped, original)
        app.buttons["editor.undo"].tap(); XCTAssertEqual(app.staticTexts["canvas.size"].label, original)
        XCTAssertTrue(app.buttons["editor.redo"].isEnabled)
        crop(app); app.buttons["crop.cancel"].tap(); closed(app.buttons["crop.cancel"])
        XCTAssertTrue(app.buttons["editor.redo"].isEnabled)
        crop(app); app.buttons["crop.commit"].tap(); closed(app.buttons["crop.commit"])
        XCTAssertTrue(app.buttons["editor.redo"].isEnabled)
        app.buttons["editor.redo"].tap(); XCTAssertEqual(app.staticTexts["canvas.size"].label, cropped)
        app.buttons["文件菜单"].tap(); app.buttons["保存工程"].tap(); app.terminate(); app.launch()
        XCTAssertTrue(app.otherElements["editor.canvas"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["canvas.size"].label, cropped)
        XCTAssertFalse(app.alerts["操作未完成"].exists)
    }

    func testGuideAddUndoVisibilityNoOpRedoAndSaveReopen() throws {
        let app = artwork()
        guides(app); app.buttons["guides.add"].tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "guides.row.")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        app.buttons["guides.done"].tap(); closed(app.buttons["guides.done"])
        app.buttons["editor.undo"].tap(); XCTAssertTrue(app.buttons["editor.redo"].isEnabled)
        guides(app); app.switches["guides.visible"].tap(); app.buttons["guides.done"].tap(); closed(app.buttons["guides.done"])
        XCTAssertTrue(app.buttons["editor.redo"].isEnabled)
        app.buttons["editor.redo"].tap()
        guides(app); XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap(); app.buttons["guides.update"].tap()
        app.buttons["guides.done"].tap(); closed(app.buttons["guides.done"])
        app.buttons["文件菜单"].tap(); app.buttons["保存工程"].tap(); app.terminate(); app.launch()
        XCTAssertTrue(app.otherElements["editor.canvas"].waitForExistence(timeout: 15))
        guides(app); XCTAssertTrue(row.waitForExistence(timeout: 5))
        app.buttons["guides.clear"].tap(); XCTAssertFalse(row.exists)
        app.buttons["guides.done"].tap(); closed(app.buttons["guides.done"])
        app.buttons["editor.undo"].tap()
        guides(app); XCTAssertTrue(row.waitForExistence(timeout: 5)); app.buttons["guides.done"].tap()
        XCTAssertFalse(app.alerts["操作未完成"].exists)
    }
}
