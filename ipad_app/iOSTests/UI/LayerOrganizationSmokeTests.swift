import XCTest

final class LayerOrganizationSmokeTests: XCTestCase {
    private func launchNew() throws -> XCUIApplication {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = XCUIApplication(); app.launch()
        XCTAssertTrue(app.otherElements["editor.canvas"].waitForExistence(timeout: 15))
        let menu = app.buttons["文件菜单"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: menu)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        menu.tap(); app.buttons["新建画稿"].tap(); app.navigationBars.buttons["完成"].tap()
        return app
    }

    func testGroupMoveOutExplicitInsertionUndoAndReopen() throws {
        let app = try launchNew()
        app.buttons["layer.add"].tap()
        app.buttons["layers.multiselect"].tap(); app.buttons["layer.select.图层 1"].tap()
        app.buttons["layers.organize"].tap()
        app.segmentedControls["organization.operation"].buttons["成组"].tap()
        snapshot(app, "组整理-横屏成组")
        XCTAssertTrue(app.buttons["organization.apply"].isEnabled); app.buttons["organization.apply"].tap()
        XCTAssertTrue(app.buttons["layer.row.图层组"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["layers.count"].label, "3 个图层")
        app.buttons["editor.undo"].tap(); XCTAssertEqual(app.staticTexts["layers.count"].label, "2 个图层")
        app.buttons["editor.redo"].tap(); XCTAssertEqual(app.staticTexts["layers.count"].label, "3 个图层")

        app.buttons["layer.row.图层 2"].tap(); app.buttons["layers.organize"].tap()
        app.segmentedControls["organization.operation"].buttons["移出组"].tap()
        app.buttons["organization.apply"].tap()
        let first = app.buttons["layer.row.图层 1"], second = app.buttons["layer.row.图层 2"]
        XCTAssertLessThan(second.frame.minY, app.buttons["layer.row.图层组"].frame.minY)

        app.buttons["layers.organize"].tap()
        app.buttons["organization.parent"].tap(); app.buttons["图层组"].tap()
        app.buttons["organization.position"].tap(); app.buttons["指定项目下方"].tap()
        app.buttons["organization.anchor"].tap(); app.buttons["图层 1"].tap()
        XCTAssertFalse(app.staticTexts["organization.issue"].exists)
        app.buttons["organization.apply"].tap()
        XCTAssertGreaterThan(second.frame.minY, first.frame.minY)
        app.buttons["editor.undo"].tap()
        XCTAssertLessThan(second.frame.minY, first.frame.minY)
        app.buttons["editor.redo"].tap()
        XCTAssertGreaterThan(second.frame.minY, first.frame.minY)
        app.buttons["文件菜单"].tap(); app.buttons["保存工程"].tap()
        app.terminate(); app.launch()
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertGreaterThan(second.frame.minY, first.frame.minY)
        snapshot(app, "组整理-指定位置重开")
        XCTAssertEqual(app.staticTexts["layers.count"].label, "3 个图层")
        XCTAssertFalse(app.alerts["操作未完成"].exists)
    }

    func testIncompleteClippingDisabledAndCancelKeepsLayers() throws {
        let app = try launchNew()
        app.buttons["layer.add"].tap()
        let clip = app.buttons["layer.clipping"]
        for _ in 0..<4 where !clip.isHittable { app.scrollViews["layers.controls"].swipeUp() }
        clip.tap()
        app.buttons["layers.organize"].tap()
        app.segmentedControls["organization.operation"].buttons["成组"].tap()
        XCTAssertFalse(app.buttons["organization.apply"].isEnabled)
        XCTAssertTrue(app.staticTexts["organization.issue"].label.contains("剪贴"))
        app.buttons["organization.cancel"].tap()
        XCTAssertEqual(app.staticTexts["layers.count"].label, "2 个图层")
        app.buttons["editor.undo"].tap()
        XCTAssertEqual(app.buttons["layer.clipping"].label, "创建剪贴蒙版")
        XCTAssertEqual(app.staticTexts["layers.count"].label, "2 个图层")
    }

    func testPortraitOrganizerCancelAndNoOpKeepRedo() throws {
        let app = try launchNew()
        app.buttons["layer.add"].tap(); app.buttons["editor.undo"].tap()
        XCTAssertTrue(app.buttons["editor.redo"].isEnabled)
        XCUIDevice.shared.orientation = .portrait
        let organizer = app.buttons["layers.organize"]
        // Rotation can finish before accessibility has the button's new frame.
        // Wait for a portrait, in-window target that stays put across snapshots;
        // tap once, then retain the original presentation/history assertions.
        var previousFrame = CGRect.null
        var stableSnapshots = 0
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let window = app.frame, frame = organizer.frame
            guard window.height > window.width, organizer.isHittable,
                  !frame.isEmpty, window.contains(frame) else {
                previousFrame = .null; stableSnapshots = 0
                return false
            }
            stableSnapshots = frame == previousFrame ? stableSnapshots + 1 : 0
            previousFrame = frame
            return stableSnapshots >= 2
        }, object: organizer)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 10), .completed)
        organizer.tap()
        XCTAssertTrue(app.buttons["organization.apply"].waitForExistence(timeout: 5))
        snapshot(app, "组整理-竖屏移动")
        app.buttons["organization.cancel"].tap()
        XCTAssertTrue(app.buttons["editor.redo"].isEnabled)
        app.buttons["layers.organize"].tap(); app.buttons["organization.apply"].tap()
        XCTAssertTrue(app.buttons["editor.redo"].isEnabled)
        XCTAssertEqual(app.staticTexts["layers.count"].label, "1 个图层")
    }

    private func snapshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
