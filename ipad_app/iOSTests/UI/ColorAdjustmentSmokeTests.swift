import XCTest

final class ColorAdjustmentSmokeTests: XCTestCase {
    private func launchArtwork() -> XCUIApplication {
        continueAfterFailure = false; XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.otherElements["editor.canvas"].waitForExistence(timeout:15))
        expect(NSPredicate(format:"hittable == true"),on:app.buttons["文件菜单"])
        app.buttons["文件菜单"].tap(); app.buttons["新建画稿"].tap(); app.navigationBars.buttons["完成"].tap()
        let fill = app.buttons["editor.fill"]
        reveal(fill,in:app.scrollViews["editor.tools"]); fill.tap()
        return app
    }
    private func begin(_ kind: String,in app: XCUIApplication) {
        app.buttons["editor.adjustments"].tap(); app.buttons["adjustment.new."+kind].tap()
        XCTAssertTrue(app.buttons["adjustment.commit"].waitForExistence(timeout:5))
    }
    private func commit(in app: XCUIApplication) {
        let button = app.buttons["adjustment.commit"]
        expect(NSPredicate(format:"enabled == true"),on:button); button.tap()
        expect(NSPredicate(format:"exists == false"),on:button)
    }
    private func edit(in app: XCUIApplication) {
        app.buttons["editor.adjustments"].tap(); app.buttons["adjustment.edit"].tap()
        XCTAssertTrue(app.buttons["adjustment.cancel"].waitForExistence(timeout:5))
    }

    func testLevelsPreviewCancelUndoReopenAndContinueEditing() throws {
        let app = launchArtwork()
        begin("Levels",in:app)
        app.sliders["levels.gamma"].adjust(toNormalizedSliderPosition:0.24)
        expect(NSPredicate(format:"enabled == true"),on:app.buttons["adjustment.commit"])
        snapshot("色阶-预览与通道")
        app.buttons["adjustment.cancel"].tap(); XCTAssertEqual(app.staticTexts["layers.count"].label,"1 个图层")
        begin("Levels",in:app)
        app.segmentedControls["adjustment.channel"].buttons["红"].tap()
        app.sliders["levels.outputWhite"].adjust(toNormalizedSliderPosition:0.55)
        let stored = try XCTUnwrap(app.sliders["levels.outputWhite"].value as? String)
        commit(in:app); XCTAssertEqual(app.staticTexts["layers.count"].label,"2 个图层")
        app.buttons["editor.undo"].tap(); XCTAssertEqual(app.staticTexts["layers.count"].label,"1 个图层")
        XCTAssertTrue(app.buttons["editor.redo"].isEnabled)
        begin("Levels",in:app); commit(in:app)
        XCTAssertTrue(app.buttons["editor.redo"].isEnabled,"Identity new adjustment must leave redo intact")
        app.buttons["editor.redo"].tap(); XCTAssertEqual(app.staticTexts["layers.count"].label,"2 个图层")
        app.buttons["文件菜单"].tap(); app.buttons["保存工程"].tap(); app.terminate(); app.launch()
        XCTAssertTrue(app.otherElements["editor.canvas"].waitForExistence(timeout:15)); edit(in:app)
        XCTAssertEqual(app.sliders["levels.outputWhite"].value as? String,stored)
        XCTAssertTrue(app.segmentedControls["adjustment.channel"].buttons["红"].isSelected)
        app.sliders["levels.outputBlack"].adjust(toNormalizedSliderPosition:0.25); commit(in:app)
        XCTAssertEqual(app.staticTexts["layers.count"].label,"2 个图层"); XCTAssertTrue(app.buttons["editor.undo"].isEnabled)
        XCTAssertFalse(app.alerts["操作未完成"].exists)
    }

    func testCurvesTouchPointsClippingMaskAndPortraitReedit() throws {
        let app = launchArtwork()
        begin("Curves",in:app)
        let graph = app.otherElements["curves.graph"]
        XCTAssertTrue(graph.waitForExistence(timeout:5))
        reveal(graph,in:app.scrollViews.firstMatch)
        let start = graph.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5))
        let end = graph.coordinate(withNormalizedOffset:CGVector(dx:0.55,dy:0.23))
        start.press(forDuration:0.1,thenDragTo:end)
        XCTAssertEqual(app.staticTexts["curves.pointCount"].label,"控制点 2/3")
        let output = try XCTUnwrap(app.sliders["curves.output"].value as? String)
        snapshot("曲线-触控点编辑")
        commit(in:app)
        let clipping = app.buttons["layer.clipping"]
        reveal(clipping,in:app.scrollViews["layers.controls"]); clipping.tap()
        XCTAssertTrue(app.staticTexts["layer.clippingSource"].waitForExistence(timeout:5))
        let addMask = app.buttons["mask.add"]
        reveal(addMask,in:app.scrollViews["layers.controls"]); addMask.tap()
        XCTAssertTrue(app.buttons["mask.exit"].waitForExistence(timeout:5)); app.buttons["mask.exit"].tap()
        app.buttons["文件菜单"].tap(); app.buttons["保存工程"].tap(); app.terminate()
        XCUIDevice.shared.orientation = .portrait; app.launch()
        XCTAssertTrue(app.otherElements["editor.canvas"].waitForExistence(timeout:15)); edit(in:app)
        let portraitGraph = app.otherElements["curves.graph"]
        XCTAssertTrue(portraitGraph.waitForExistence(timeout:5))
        reveal(app.buttons["curves.nextPoint"],in:app.scrollViews.firstMatch)
        // Navigate to the saved middle point without altering its persisted geometry.
        app.buttons["curves.nextPoint"].tap()
        XCTAssertEqual(app.staticTexts["curves.pointCount"].label,"控制点 2/3")
        XCTAssertEqual(app.sliders["curves.output"].value as? String,output)
        snapshot("曲线-竖屏重开与蒙版")
        app.buttons["adjustment.cancel"].tap()
        XCTAssertEqual(app.staticTexts["layers.count"].label,"2 个图层")
        XCTAssertTrue(app.buttons["layer.mask.曲线调整"].exists)
        XCTAssertFalse(app.alerts["操作未完成"].exists)
    }

    private func reveal(_ element: XCUIElement,in scroll: XCUIElement) {
        XCTAssertTrue(element.waitForExistence(timeout:5))
        for _ in 0..<8 { if element.isHittable { return }; scroll.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }
    private func expect(_ predicate: NSPredicate,on element: XCUIElement,file: StaticString = #filePath,line: UInt = #line) {
        XCTAssertEqual(XCTWaiter.wait(for:[XCTNSPredicateExpectation(predicate:predicate,object:element)],timeout:20),.completed,file:file,line:line)
    }
    private func snapshot(_ name: String) {
        let attachment = XCTAttachment(screenshot:XCUIScreen.main.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
