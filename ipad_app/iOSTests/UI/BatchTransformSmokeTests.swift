import XCTest

final class BatchTransformSmokeTests: XCTestCase {
    private func launchTwoLayers() throws -> XCUIApplication {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.otherElements["editor.canvas"].waitForExistence(timeout:15))
        let menu = app.buttons["文件菜单"]
        expect(NSPredicate(format:"hittable == true"),on:menu)
        menu.tap(); app.buttons["新建画稿"].tap(); app.navigationBars.buttons["完成"].tap()
        let fill = app.buttons["editor.fill"]
        reveal(fill,in:app.scrollViews["editor.tools"],up:true); fill.tap()
        app.buttons["layer.add"].tap(); fill.tap()
        app.buttons["layers.multiselect"].tap(); app.buttons["layer.select.图层 1"].tap()
        XCTAssertEqual(app.staticTexts["layers.selectionCount"].label,"已选 2 项")
        return app
    }

    func testCommonResizeRotateMoveFlipsOneUndoAndReopen() throws {
        let app = try launchTwoLayers(), canvas = app.otherElements["editor.canvas"]
        app.buttons["layers.transform"].tap()
        let geometry = app.staticTexts["transform.geometry"]
        XCTAssertTrue(geometry.waitForExistence(timeout:5)); let original = geometry.label
        XCTAssertTrue(app.staticTexts["transform.scope"].label.contains("共同变换"))
        app.buttons["适合画布"].tap()
        let frame = canvas.frame, scale = min((frame.width-96)/1200,(frame.height-96)/900)
        let topLeft = CGPoint(x:frame.midX-600*scale,y:frame.midY-450*scale)
        drag(canvas,from:CGPoint(x:topLeft.x+1200*scale,y:topLeft.y+900*scale),
             to:CGPoint(x:topLeft.x+780*scale,y:topLeft.y+585*scale))
        let resized = try numbers(geometry)
        XCTAssertLessThan(resized[0],1000); XCTAssertGreaterThan(resized[0],500)
        XCTAssertEqual(resized[0]/resized[1],4/3,accuracy:0.01)
        let center = CGPoint(x:topLeft.x+resized[0]*scale/2,y:topLeft.y+resized[1]*scale/2)
        let radius = resized[1]*scale/2+36
        drag(canvas,from:CGPoint(x:center.x,y:center.y-radius),
             to:CGPoint(x:center.x+sin(.pi/6)*radius,y:center.y-cos(.pi/6)*radius))
        XCTAssertGreaterThan(try numbers(geometry)[2],15); XCTAssertLessThan(try numbers(geometry)[2],45)
        drag(canvas,from:center,to:CGPoint(x:center.x+35,y:center.y+25))
        let committed = geometry.label
        let flipX = app.buttons["transform.flipX"], flipY = app.buttons["transform.flipY"]
        flipX.tap(); expect(NSPredicate(format:"value == %@","已翻转"),on:flipX)
        flipY.tap(); expect(NSPredicate(format:"value == %@","已翻转"),on:flipY)
        snapshot("多层-旋转缩放翻转预览")
        app.buttons["transform.commit"].tap()
        app.buttons["editor.undo"].tap(); app.buttons["layers.transform"].tap()
        XCTAssertTrue(geometry.waitForExistence(timeout:5)); XCTAssertEqual(geometry.label,original)
        app.buttons["transform.cancel"].tap(); XCTAssertTrue(app.buttons["editor.redo"].isEnabled)
        app.buttons["editor.redo"].tap()
        // A newly opened common box is upright. Inspect one carried layer to
        // verify its persisted size/angle rather than expecting a saved draft box.
        app.buttons["layers.multiselect"].tap()
        let tool = app.buttons["tool.自由变换"]
        reveal(tool,in:app.scrollViews["editor.tools"],up:false); tool.tap()
        XCTAssertTrue(geometry.waitForExistence(timeout:5)); XCTAssertEqual(geometry.label,committed)
        app.buttons["transform.cancel"].tap()
        app.buttons["layers.multiselect"].tap(); app.buttons["layer.select.图层 2"].tap()
        app.buttons["layers.transform"].tap()
        XCTAssertTrue(geometry.waitForExistence(timeout:5))
        XCTAssertFalse(app.switches["transform.aspect"].isEnabled)
        XCTAssertTrue(app.staticTexts["transform.rasterizationNotice"].label.contains("斜切"))
        app.buttons["transform.cancel"].tap(); app.buttons["layers.multiselect"].tap()
        app.buttons["文件菜单"].tap(); app.buttons["保存工程"].tap(); app.terminate()
        // CI retained a tool snapshot from the terminated PID after relaunch.
        // Rebuild the application/query tree for the new process; never retap on failure.
        let reopened = XCUIApplication(); reopened.launch()
        XCTAssertTrue(reopened.otherElements["editor.canvas"].waitForExistence(timeout:10))
        XCTAssertEqual(reopened.staticTexts["layers.count"].label,"2 个图层")
        let reopenedTool = reopened.buttons["tool.自由变换"], reopenedGeometry = reopened.staticTexts["transform.geometry"]
        reveal(reopenedTool,in:reopened.scrollViews["editor.tools"],up:false); reopenedTool.tap()
        XCTAssertTrue(reopenedGeometry.waitForExistence(timeout:5)); XCTAssertEqual(reopenedGeometry.label,committed)
        XCTAssertFalse(reopened.alerts["操作未完成"].exists); snapshot("多层-分层重开")
        reopened.buttons["transform.cancel"].tap()
    }

    func testGroupMaskMoveCancelNoOpPreservesRedoAndReopens() throws {
        let app = try launchTwoLayers(), canvas = app.otherElements["editor.canvas"]
        app.buttons["layers.organize"].tap(); app.segmentedControls["organization.operation"].buttons["成组"].tap()
        app.buttons["organization.apply"].tap()
        XCTAssertTrue(app.buttons["layer.row.图层组"].waitForExistence(timeout:5))
        let finger = app.switches["finger.drawing"]
        if (finger.value as? String) == "0" { finger.tap() }
        let addMask = app.buttons["mask.add"]
        reveal(addMask,in:app.scrollViews["layers.controls"],up:true); addMask.tap()
        XCTAssertTrue(app.buttons["mask.exit"].waitForExistence(timeout:5))
        let frame = canvas.frame
        drag(canvas,from:CGPoint(x:frame.midX-25,y:frame.midY),to:CGPoint(x:frame.midX+35,y:frame.midY+10))
        app.buttons["mask.exit"].tap()
        let tool = app.buttons["tool.自由变换"]
        reveal(tool,in:app.scrollViews["editor.tools"],up:false); tool.tap()
        let geometry = app.staticTexts["transform.geometry"]
        XCTAssertTrue(geometry.waitForExistence(timeout:5))
        XCTAssertTrue(app.staticTexts["transform.scope"].label.contains("组内子层"))
        let groupFrame = canvas.frame
        drag(canvas,from:CGPoint(x:groupFrame.midX,y:groupFrame.midY),to:CGPoint(x:groupFrame.midX+30,y:groupFrame.midY+20))
        app.buttons["transform.commit"].tap(); app.buttons["editor.undo"].tap()
        XCTAssertTrue(app.buttons["editor.redo"].isEnabled)
        tool.tap(); XCTAssertTrue(geometry.waitForExistence(timeout:5))
        let draftFrame = canvas.frame
        drag(canvas,from:CGPoint(x:draftFrame.midX,y:draftFrame.midY),to:CGPoint(x:draftFrame.midX-20,y:draftFrame.midY+10))
        app.buttons["transform.cancel"].tap(); XCTAssertTrue(app.buttons["editor.redo"].isEnabled)
        tool.tap(); XCTAssertTrue(geometry.waitForExistence(timeout:5)); app.buttons["transform.commit"].tap()
        XCTAssertTrue(app.buttons["editor.redo"].isEnabled,"An unchanged common frame must preserve redo")
        app.buttons["editor.redo"].tap()
        app.buttons["文件菜单"].tap(); app.buttons["保存工程"].tap(); app.terminate()
        XCUIDevice.shared.orientation = .portrait
        let reopened = XCUIApplication(); reopened.launch()
        XCTAssertTrue(reopened.otherElements["editor.canvas"].waitForExistence(timeout:10))
        XCTAssertTrue(reopened.buttons["layer.mask.图层组"].exists); XCTAssertEqual(reopened.staticTexts["layers.count"].label,"3 个图层")
        let reopenedTool = reopened.buttons["tool.自由变换"], reopenedGeometry = reopened.staticTexts["transform.geometry"]
        reveal(reopenedTool,in:reopened.scrollViews["editor.tools"],up:false); reopenedTool.tap()
        XCTAssertTrue(reopenedGeometry.waitForExistence(timeout:5)); XCTAssertTrue(reopened.staticTexts["transform.scope"].label.contains("组内子层"))
        XCTAssertFalse(reopened.alerts["操作未完成"].exists); snapshot("整组-蒙版与子层重开")
        reopened.buttons["transform.cancel"].tap()
    }

    private func reveal(_ button: XCUIElement,in scroll: XCUIElement,up: Bool) {
        XCTAssertTrue(button.waitForExistence(timeout:5))
        for _ in 0..<4 where !button.isHittable { if up { scroll.swipeUp() } else { scroll.swipeDown() } }
        XCTAssertTrue(button.isHittable)
    }
    private func expect(_ predicate: NSPredicate,on element: XCUIElement) {
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:predicate,object:element)],timeout:5),.completed)
    }
    private func numbers(_ element: XCUIElement) throws -> [CGFloat] {
        let text = element.label, expression = try NSRegularExpression(pattern:#"-?\d+(?:\.\d+)?"#)
        let values = expression.matches(in:text,range:NSRange(text.startIndex...,in:text)).compactMap { match -> CGFloat? in
            guard let r = Range(match.range,in:text), let n = Double(text[r]) else { return nil }; return CGFloat(n)
        }
        XCTAssertEqual(values.count,3); return values
    }
    private func drag(_ canvas: XCUIElement,from start: CGPoint,to end: CGPoint) {
        let frame = canvas.frame, origin = canvas.coordinate(withNormalizedOffset:.zero)
        origin.withOffset(CGVector(dx:start.x-frame.minX,dy:start.y-frame.minY)).press(forDuration:0.1,
            thenDragTo:origin.withOffset(CGVector(dx:end.x-frame.minX,dy:end.y-frame.minY)))
    }
    private func snapshot(_ name: String) {
        let a = XCTAttachment(screenshot:XCUIScreen.main.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
}
