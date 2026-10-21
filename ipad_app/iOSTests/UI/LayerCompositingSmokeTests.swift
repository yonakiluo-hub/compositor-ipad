import XCTest

/// All artwork is created through the editor in the isolated QA simulator.
/// Numeric mask and compositing fidelity are covered by the native unit tests;
/// these flows exercise the actual target controls, touch path and persistence.
final class LayerCompositingSmokeTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
    }

    func testMaskPaintHideRevealUndoAndReopen() throws {
        let app = XCUIApplication()
        let canvas = newDocument(in: app)
        enableFingerDrawing(in: app)
        fillPixels(in: app)

        let addMask = app.buttons["mask.add"]
        reveal(addMask, in: app.scrollViews["layers.controls"], direction: .up)
        addMask.tap()
        let thumbnail = app.buttons["layer.mask.图层 1"]
        XCTAssertTrue(thumbnail.waitForExistence(timeout: 5))
        let target = app.segmentedControls["layer.editTarget"]
        XCTAssertTrue(target.buttons["蒙版"].isSelected)
        XCTAssertEqual(app.staticTexts["mask.editingState"].label, "正在绘制蒙版")
        XCTAssertEqual(app.staticTexts["selection.state"].label, "无选区")

        let hide = app.segmentedControls["mask.paintMode"].buttons["黑色隐藏"]
        reveal(hide, in: app.scrollViews["editor.brushBar"], direction: .right)
        hide.tap()
        XCTAssertTrue(hide.isSelected)
        drawAcrossCenter(canvas)
        XCTAssertTrue(app.buttons["editor.undo"].isEnabled)
        XCTAssertFalse(app.buttons["editor.redo"].isEnabled)
        XCTAssertTrue(thumbnail.exists)
        XCTAssertFalse(app.alerts["操作未完成"].exists)
        app.buttons["editor.undo"].tap()
        XCTAssertTrue(app.buttons["editor.redo"].isEnabled)
        XCTAssertTrue(thumbnail.exists, "Undoing the stroke must keep the mask")
        XCTAssertTrue(target.buttons["蒙版"].isSelected)
        app.buttons["editor.redo"].tap()
        XCTAssertFalse(app.buttons["editor.redo"].isEnabled)

        let revealWhite = app.segmentedControls["mask.paintMode"].buttons["白色显示"]
        reveal(revealWhite, in: app.scrollViews["editor.brushBar"], direction: .right)
        revealWhite.tap()
        XCTAssertTrue(revealWhite.isSelected)
        drawAcrossCenter(canvas)
        XCTAssertFalse(app.alerts["操作未完成"].exists)
        app.buttons["editor.undo"].tap()
        app.buttons["editor.redo"].tap()
        XCTAssertEqual(app.staticTexts["layers.count"].label, "1 个图层")
        saveAndReopen(app, canvas: canvas)
        XCTAssertTrue(thumbnail.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["layers.count"].label, "1 个图层")
        XCTAssertTrue(target.buttons["图像"].isSelected, "The document opens with its image as the editing target")
        reveal(thumbnail, in: app.scrollViews["layers.rows"], direction: .down)
        thumbnail.tap()
        XCTAssertTrue(target.buttons["蒙版"].isSelected)
        XCTAssertEqual(app.staticTexts["mask.editingState"].label, "正在绘制蒙版")
        XCTAssertFalse(app.alerts["操作未完成"].exists)
    }

    func testMultiSelectMergeUndoRestoresSourceMaskAndReopenKeepsMergedLayer() throws {
        let app = XCUIApplication()
        let canvas = newDocument(in: app)
        fillPixels(in: app)
        let addMask = app.buttons["mask.add"]
        reveal(addMask, in: app.scrollViews["layers.controls"], direction: .up)
        addMask.tap()
        XCTAssertTrue(app.buttons["layer.mask.图层 1"].waitForExistence(timeout: 5))
        let hideAll = app.buttons["mask.fillBlack"]
        reveal(hideAll, in: app.scrollViews["layers.controls"], direction: .up)
        hideAll.tap()
        let imageTarget = app.segmentedControls["layer.editTarget"].buttons["图像"]
        reveal(imageTarget, in: app.scrollViews["layers.controls"], direction: .down)
        imageTarget.tap()
        XCTAssertTrue(imageTarget.isSelected)
        app.buttons["layer.add"].tap()
        XCTAssertEqual(app.staticTexts["layers.count"].label, "2 个图层")
        fillPixels(in: app)

        app.buttons["layers.multiselect"].tap()
        let selectedCount = app.staticTexts["layers.selectionCount"]
        XCTAssertEqual(selectedCount.label, "已选 1 项")
        let first = app.buttons["layer.select.图层 1"], second = app.buttons["layer.select.图层 2"]
        reveal(second, in: app.scrollViews["layers.rows"], direction: .down)
        second.tap()
        XCTAssertEqual(selectedCount.label, "已选 0 项")
        XCTAssertFalse(app.buttons["layers.mergeSelected"].isEnabled)
        first.tap()
        XCTAssertEqual(selectedCount.label, "已选 1 项")
        second.tap()
        XCTAssertEqual(selectedCount.label, "已选 2 项")
        XCTAssertTrue(app.buttons["layers.mergeSelected"].isEnabled)
        app.buttons["layers.mergeSelected"].tap()
        XCTAssertEqual(app.staticTexts["layers.count"].label, "1 个图层")
        XCTAssertTrue(app.buttons["layer.row.图层 2"].exists)
        XCTAssertFalse(app.buttons["layer.mask.图层 1"].exists)
        XCTAssertFalse(app.buttons["layers.mergeSelected"].exists)
        XCTAssertFalse(app.alerts["操作未完成"].exists)

        app.buttons["editor.undo"].tap()
        XCTAssertEqual(app.staticTexts["layers.count"].label, "2 个图层")
        XCTAssertTrue(app.buttons["layer.row.图层 1"].exists)
        XCTAssertTrue(app.buttons["layer.row.图层 2"].exists)
        XCTAssertTrue(app.buttons["layer.mask.图层 1"].exists, "One undo must restore the editable source mask")
        app.buttons["editor.redo"].tap()
        XCTAssertEqual(app.staticTexts["layers.count"].label, "1 个图层")
        XCTAssertFalse(app.buttons["layer.mask.图层 1"].exists)
        saveAndReopen(app, canvas: canvas)
        XCTAssertEqual(app.staticTexts["layers.count"].label, "1 个图层")
        XCTAssertTrue(app.buttons["layer.row.图层 2"].exists)
        XCTAssertFalse(app.buttons["layer.mask.图层 1"].exists)
        XCTAssertFalse(app.alerts["操作未完成"].exists)
    }

    private func newDocument(in app: XCUIApplication) -> XCUIElement {
        app.launch()
        let canvas = app.otherElements["editor.canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 15))
        let menu = app.buttons["文件菜单"]
        wait(NSPredicate(format: "hittable == true"), on: menu)
        menu.tap()
        let create = app.buttons["新建画稿"]
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        create.tap()
        let done = app.navigationBars.buttons["完成"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["layers.count"].label, "1 个图层")
        XCTAssertFalse(app.buttons["editor.undo"].isEnabled)
        return canvas
    }

    private func enableFingerDrawing(in app: XCUIApplication) {
        let finger = app.switches["finger.drawing"]
        reveal(finger, in: app.scrollViews["editor.brushBar"], direction: .left)
        if finger.value as? String != "1" { finger.tap() }
        XCTAssertEqual(finger.value as? String, "1")
    }

    private func fillPixels(in app: XCUIApplication) {
        let fill = app.buttons["editor.fill"]
        reveal(fill, in: app.scrollViews["editor.tools"], direction: .up)
        XCTAssertEqual(fill.label, "填充图层或选区")
        fill.tap()
        XCTAssertFalse(app.alerts["操作未完成"].exists)
    }

    private func drawAcrossCenter(_ canvas: XCUIElement) {
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.40, dy: 0.46))
            .press(forDuration: 0.1, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.60, dy: 0.54)))
    }

    private func saveAndReopen(_ app: XCUIApplication, canvas: XCUIElement) {
        app.buttons["文件菜单"].tap()
        let save = app.buttons["保存工程"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()
        XCTAssertFalse(app.alerts["操作未完成"].exists)
        app.terminate()
        app.launch()
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))
    }

    private enum Direction { case up, down, left, right }

    private func reveal(_ element: XCUIElement, in scrollView: XCUIElement, direction: Direction,
                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), file: file, line: line)
        for _ in 0..<5 where !element.isHittable {
            XCTAssertTrue(scrollView.exists, file: file, line: line)
            switch direction {
            case .up: scrollView.swipeUp()
            case .down: scrollView.swipeDown()
            case .left: scrollView.swipeLeft()
            case .right: scrollView.swipeRight()
            }
        }
        XCTAssertTrue(element.isHittable, file: file, line: line)
    }

    private func wait(_ predicate: NSPredicate, on element: XCUIElement,
                      file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed, file: file, line: line)
    }
}
