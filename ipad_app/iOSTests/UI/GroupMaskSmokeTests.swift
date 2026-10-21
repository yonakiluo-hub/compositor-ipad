import XCTest

final class GroupMaskSmokeTests: XCTestCase {
    private func groupedDocument() -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.otherElements["editor.canvas"].waitForExistence(timeout:15))
        let menu = app.buttons["文件菜单"]
        let ready = XCTNSPredicateExpectation(predicate:NSPredicate(format:"hittable == true"),object:menu)
        XCTAssertEqual(XCTWaiter.wait(for:[ready],timeout:5),.completed)
        menu.tap(); app.buttons["新建画稿"].tap(); app.navigationBars.buttons["完成"].tap()
        // Set the input mode before the wider mask toolbar scrolls this switch
        // outside the viewport; the mask flow itself must still draw and undo.
        let finger = app.switches["finger.drawing"]
        XCTAssertTrue(finger.waitForExistence(timeout:5))
        if finger.value as? String != "1" { finger.tap() }
        let fill = app.buttons["editor.fill"]
        reveal(fill,in:app.scrollViews["editor.tools"])
        fill.tap(); app.buttons["layer.add"].tap(); fill.tap()
        app.buttons["layers.multiselect"].tap(); app.buttons["layer.select.图层 1"].tap()
        app.buttons["layers.organize"].tap()
        app.segmentedControls["organization.operation"].buttons["成组"].tap()
        app.buttons["organization.apply"].tap()
        XCTAssertEqual(app.staticTexts["layers.count"].label,"3 个图层")
        return app
    }
    private func reveal(_ element: XCUIElement, in scroll: XCUIElement, horizontal: Bool = false, forward: Bool = true) {
        XCTAssertTrue(element.waitForExistence(timeout:5))
        for _ in 0..<5 where !element.isHittable {
            if horizontal { if forward { scroll.swipeLeft() } else { scroll.swipeRight() } }
            else { if forward { scroll.swipeUp() } else { scroll.swipeDown() } }
        }
        XCTAssertTrue(element.isHittable)
    }
    private func stroke(_ app: XCUIApplication) {
        let canvas = app.otherElements["editor.canvas"]
        canvas.coordinate(withNormalizedOffset:CGVector(dx:0.4,dy:0.45)).press(forDuration:0.1,
            thenDragTo:canvas.coordinate(withNormalizedOffset:CGVector(dx:0.6,dy:0.55)))
    }
    private func screenshot(_ name: String) {
        // Full-screen captures avoid app-bounds clipping during landscape rotation.
        let attachment = XCTAttachment(screenshot:XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func saveReopen(_ app: XCUIApplication) {
        app.buttons["文件菜单"].tap(); app.buttons["保存工程"].tap()
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["layer.mask.图层组"].waitForExistence(timeout:10))
        XCTAssertEqual(app.staticTexts["layers.count"].label,"3 个图层")
        XCTAssertFalse(app.alerts["操作未完成"].exists)
    }

    func testGroupMaskPaintFillDisableUndoAndReopen() {
        let app = groupedDocument(), controls = app.scrollViews["layers.controls"]
        let add = app.buttons["mask.add"]; reveal(add,in:controls); XCTAssertEqual(add.label,"添加组蒙版"); add.tap()
        let thumbnail = app.buttons["layer.mask.图层组"]
        XCTAssertTrue(thumbnail.waitForExistence(timeout:5))
        XCTAssertTrue(app.segmentedControls["layer.editTarget"].buttons["蒙版"].isSelected)
        let bar = app.scrollViews["editor.brushBar"]
        stroke(app)
        app.buttons["editor.undo"].tap(); XCTAssertTrue(thumbnail.exists,"One undo must undo the stroke, keeping the group mask")
        app.buttons["editor.redo"].tap()
        let black = app.buttons["mask.fillBlack"]; reveal(black,in:controls); black.tap()
        let whiteBrush = app.segmentedControls["mask.paintMode"].buttons["白色显示"]
        reveal(whiteBrush,in:bar,horizontal:true,forward:false); whiteBrush.tap(); stroke(app)
        XCTAssertFalse(app.alerts["操作未完成"].exists)
        app.buttons["editor.undo"].tap(); app.buttons["editor.redo"].tap()
        screenshot("组蒙版-黑底白色恢复")
        let menu = app.buttons["mask.menu"]; reveal(menu,in:controls,forward:false)
        menu.tap(); app.buttons["停用蒙版"].tap()
        menu.tap(); app.buttons["启用蒙版"].tap()
        saveReopen(app)
        XCTAssertTrue(app.segmentedControls["layer.editTarget"].buttons["图层组"].isSelected)
        screenshot("组蒙版-工程重开")
    }

    func testSelectionCreatesGroupMaskAndRemovalUndoes() {
        let app = groupedDocument(), canvas = app.otherElements["editor.canvas"]
        let finger = app.switches["finger.drawing"]
        if finger.value as? String != "1" { finger.tap() }
        let rectangle = app.buttons["tool.矩形选区"]
        reveal(rectangle,in:app.scrollViews["editor.tools"]); rectangle.tap()
        canvas.coordinate(withNormalizedOffset:CGVector(dx:0.35,dy:0.35)).press(forDuration:0.1,
            thenDragTo:canvas.coordinate(withNormalizedOffset:CGVector(dx:0.65,dy:0.65)))
        XCTAssertTrue(app.buttons["selection.clear"].exists)
        let menu = app.buttons["mask.menu"], controls = app.scrollViews["layers.controls"]
        reveal(menu,in:controls); menu.tap(); app.buttons["使用当前选区"].tap()
        let thumbnail = app.buttons["layer.mask.图层组"]
        XCTAssertTrue(thumbnail.waitForExistence(timeout:5))
        app.buttons["selection.clear"].tap(); thumbnail.tap()
        menu.tap(); app.buttons["移除蒙版"].tap()
        XCTAssertFalse(thumbnail.exists)
        app.buttons["editor.undo"].tap(); XCTAssertTrue(thumbnail.exists)
        app.buttons["editor.redo"].tap(); XCTAssertFalse(thumbnail.exists)
        app.buttons["editor.undo"].tap()
        saveReopen(app)
    }
}
