import XCTest

final class QuadWarpSmokeTests:XCTestCase {
    func testCornerDragPreviewCancelCommitUndoAndReopen() throws {
        continueAfterFailure=false;XCUIDevice.shared.orientation = .landscapeLeft
        let app=XCUIApplication();app.launch();XCTAssertTrue(app.otherElements["editor.canvas"].waitForExistence(timeout:15))
        app.buttons["文件菜单"].tap();app.buttons["新建画稿"].tap();app.navigationBars.buttons["完成"].tap()
        let fill=app.buttons["editor.fill"],tools=app.scrollViews["editor.tools"]
        for _ in 0..<5 {if fill.isHittable{break};tools.swipeUp()};XCTAssertTrue(fill.isHittable);fill.tap()
        begin(in:app);let geometry=app.staticTexts["warp.geometry"]
        XCTAssertTrue(geometry.waitForExistence(timeout:5));let original=geometry.label
        app.buttons["适合画布"].tap()
        let canvas=app.otherElements["editor.canvas"],frame=canvas.frame
        let scale=min((frame.width-96)/1200,(frame.height-96)/900)
        let topRight=CGPoint(x:frame.midX+600*scale,y:frame.midY-450*scale)
        let origin=canvas.coordinate(withNormalizedOffset:.zero)
        origin.withOffset(CGVector(dx:topRight.x-frame.minX,dy:topRight.y-frame.minY)).press(forDuration:0.1,
            thenDragTo:origin.withOffset(CGVector(dx:topRight.x-frame.minX-65,dy:topRight.y-frame.minY+25)))
        XCTAssertNotEqual(geometry.label,original)
        let changed=geometry.label
        waitEnabled(app.buttons["warp.commit"]);app.buttons["warp.cancel"].tap()
        begin(in:app);XCTAssertEqual(geometry.label,original)
        // The numeric control is a second real editing path, independent of the
        // drag above; the first corner can move right while remaining convex.
        let x=app.textFields["warp.coordinate.x"]
        XCTAssertTrue(x.waitForExistence(timeout:5))
        for (invalid,error) in [("nan","有限"),("1e9","范围"),("1300","交叉")] {
            x.tap();x.typeText(String(repeating:XCUIKeyboardKey.delete.rawValue,count:20)+invalid)
            XCTAssertTrue(app.staticTexts["warp.coordinate.error"].label.contains(error))
            XCTAssertFalse(app.buttons["warp.coordinate.apply"].isEnabled)
            XCTAssertFalse(app.buttons["warp.commit"].isEnabled)
            XCTAssertEqual(geometry.label,original,"Invalid, out-of-range or folded coordinates must preserve the preview")
        }
        x.tap();x.typeText(String(repeating:XCUIKeyboardKey.delete.rawValue,count:20)+"80")
        let y=app.textFields["warp.coordinate.y"]
        y.tap();y.typeText(String(repeating:XCUIKeyboardKey.delete.rawValue,count:20)+"20")
        XCTAssertFalse(app.buttons["warp.commit"].isEnabled,"An unapplied coordinate draft cannot silently complete")
        app.buttons["warp.coordinate.apply"].tap()
        XCTAssertTrue(geometry.label.hasPrefix("80.0,20.0"),"Exact coordinates must update the selected corner together")
        app.buttons["warp.nextPoint"].tap()
        XCTAssertEqual(x.value as?String,"1200.0");XCTAssertEqual(y.value as?String,"0.0")
        x.tap();x.typeText(String(repeating:XCUIKeyboardKey.delete.rawValue,count:20)+"nan")
        XCTAssertTrue(app.staticTexts["warp.coordinate.error"].exists)
        app.buttons["warp.nextPoint"].tap()
        XCTAssertEqual(x.value as?String,"1200.0");XCTAssertEqual(y.value as?String,"900.0")
        XCTAssertFalse(app.staticTexts["warp.coordinate.error"].exists,"Equal X coordinates cannot carry a previous point's invalid draft")
        XCTAssertNotEqual(geometry.label,original);XCTAssertNotEqual(geometry.label,changed)
        waitEnabled(app.buttons["warp.commit"]);app.buttons["warp.commit"].tap()
        app.buttons["editor.undo"].tap();XCTAssertTrue(app.buttons["editor.redo"].isEnabled)
        begin(in:app);app.buttons["warp.commit"].tap()
        XCTAssertTrue(app.buttons["editor.redo"].isEnabled,"Identity completion must preserve redo")
        app.buttons["editor.redo"].tap()
        app.buttons["文件菜单"].tap();app.buttons["保存工程"].tap();app.terminate()
        XCUIDevice.shared.orientation = .portrait
        let reopened=XCUIApplication();reopened.launch();XCTAssertTrue(reopened.otherElements["editor.canvas"].waitForExistence(timeout:15))
        XCTAssertEqual(reopened.staticTexts["layers.count"].label,"1 个图层")
        begin(in:reopened);XCTAssertTrue(reopened.staticTexts["warp.scope"].label.contains("整个图层"))
        reopened.buttons["warp.cancel"].tap();XCTAssertFalse(reopened.alerts["操作未完成"].exists)
    }
    private func begin(in app:XCUIApplication) {
        app.buttons["editor.geometry"].tap();app.buttons["warp.begin.distort"].tap()
        XCTAssertTrue(app.buttons["warp.cancel"].waitForExistence(timeout:5))
    }
    private func waitEnabled(_ element:XCUIElement) {
        let deadline=Date().addingTimeInterval(30)
        repeat {if element.isEnabled{return};Thread.sleep(forTimeInterval:0.2)} while Date()<deadline
        XCTAssertTrue(element.isEnabled)
    }
}
