import XCTest
import UIKit
import Combine
@testable import CompositorPad

final class ColorAdjustmentWorkflowTests: XCTestCase {
    @MainActor private func fixture() throws -> EditorModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("color-adjustment-"+UUID().uuidString)
        let docs = root.appendingPathComponent("Documents"), suite = "color-adjustment-"+UUID().uuidString
        try FileManager.default.createDirectory(at:docs,withIntermediateDirectories:true)
        let preferences = try XCTUnwrap(UserDefaults(suiteName:suite))
        let m = EditorModel(documentsURL:docs,supportURL:root.appendingPathComponent("Support"),preferences:preferences,loadPairing:false)
        m.create(name:"合成测试",width:16,height:12); m.color = .red; m.fill(); m.saveNow()
        addTeardownBlock { try? FileManager.default.removeItem(at:root); UserDefaults.standard.removePersistentDomain(forName:suite) }
        return m
    }
    private func inverted(_ value: LayerAdjustment) -> LayerAdjustment {
        var next = value
        if value.kind == .levels { next.levels.ranges[0] = LevelRange(outputBlack:255,outputWhite:0) }
        else { next.curves.channels[0] = [CurvePoint(x:0,y:255),CurvePoint(x:255,y:0)] }
        return next
    }
    @MainActor private func finishPreview(_ m: EditorModel) async {
        while let worker = m.colorAdjustmentTask { await worker.value }
    }
    private func bytes(_ image: CGImage) throws -> Data { try XCTUnwrap(image.dataProvider?.data) as Data }

    @MainActor func testManyPreviewsCommitOneUndoSaveCommittedThenReopenAndReedit() async throws {
        let m = try fixture(), before = m.document, count = m.editor.undoCount
        XCTAssertTrue(m.beginColorAdjustment(.curves)); let s = try XCTUnwrap(m.colorAdjustmentSession)
        var value = s.value
        for y in 80...95 {
            value.curves.channels[0] = [CurvePoint(x:0,y:0),CurvePoint(x:128,y:Double(y)),CurvePoint(x:255,y:255)]
            XCTAssertTrue(m.updateColorAdjustment(value,sessionID:s.id))
        }
        await finishPreview(m)
        XCTAssertFalse(m.colorAdjustmentPreviewPending); XCTAssertNil(m.colorAdjustmentPreviewError)
        XCTAssertEqual(m.document,before); XCTAssertEqual(m.editor.undoCount,count)
        let preview = try bytes(XCTUnwrap(m.colorAdjustmentPreview))
        m.saveNow(); XCTAssertEqual(try DocumentStore.load(from:m.documentURL),before)
        XCTAssertTrue(m.commitColorAdjustment(sessionID:s.id)); XCTAssertEqual(m.editor.undoCount,count+1)
        XCTAssertEqual(m.document.layers[0].pngData,before.layers[0].pngData)
        XCTAssertNil(m.activeLayer?.pngData); XCTAssertEqual(m.activeLayer?.adjustment,value)
        XCTAssertEqual(try bytes(m.renderer.render(m.document)),preview)
        let done = m.document
        m.undo(); XCTAssertEqual(m.document.layers,before.layers)
        m.redo(); XCTAssertEqual(m.document.layers,done.layers)
        m.saveNow(); let url = m.documentURL
        XCTAssertEqual(try DocumentStore.load(from:url),m.document)
        m.open(url); XCTAssertTrue(m.beginColorAdjustment())
        XCTAssertEqual(m.colorAdjustmentSession?.value,value)
        let edit = try XCTUnwrap(m.colorAdjustmentSession)
        XCTAssertTrue(m.updateColorAdjustment(inverted(edit.value),sessionID:edit.id)); await finishPreview(m)
        XCTAssertTrue(m.commitColorAdjustment(sessionID:edit.id))
        XCTAssertEqual(m.document.layers.count,2); XCTAssertEqual(m.document.layers[0].pngData,before.layers[0].pngData)
    }

    @MainActor func testCancelAndChannelOnlyNoOpPreserveRedoIncludingNewIdentity() async throws {
        let m = try fixture(); m.updateLayer("临时") { $0.opacity = 0.5 }; m.undo()
        let before = m.document; XCTAssertTrue(m.editor.canRedo)
        XCTAssertTrue(m.beginColorAdjustment(.levels)); let first = try XCTUnwrap(m.colorAdjustmentSession)
        XCTAssertTrue(m.updateColorAdjustment(inverted(first.value),sessionID:first.id)); await finishPreview(m)
        m.cancelColorAdjustment(); XCTAssertEqual(m.document,before); XCTAssertTrue(m.editor.canRedo)
        XCTAssertTrue(m.beginColorAdjustment(.levels)); let identity = try XCTUnwrap(m.colorAdjustmentSession)
        var channel = identity.value; channel.levels.channel = .blue
        XCTAssertTrue(m.updateColorAdjustment(channel,sessionID:identity.id)); await finishPreview(m)
        XCTAssertTrue(m.commitColorAdjustment(sessionID:identity.id)); XCTAssertEqual(m.document,before); XCTAssertTrue(m.editor.canRedo)
        m.redo(); XCTAssertEqual(m.activeLayer?.opacity,0.5)
    }

    @MainActor func testOldWorkerAndLateActionsCannotPublishIntoNewSession() async throws {
        let m = try fixture(); XCTAssertTrue(m.beginColorAdjustment(.curves))
        let old = try XCTUnwrap(m.colorAdjustmentSession)
        XCTAssertTrue(m.updateColorAdjustment(inverted(old.value),sessionID:old.id))
        m.cancelColorAdjustment(); XCTAssertTrue(m.beginColorAdjustment(.levels))
        let current = try XCTUnwrap(m.colorAdjustmentSession)
        var newest = current.value; newest.levels.ranges[0].outputWhite = 120
        XCTAssertTrue(m.updateColorAdjustment(newest,sessionID:current.id))
        XCTAssertFalse(m.updateColorAdjustment(inverted(old.value),sessionID:old.id))
        XCTAssertFalse(m.commitColorAdjustment(sessionID:old.id))
        await finishPreview(m)
        XCTAssertEqual(m.colorAdjustmentSession?.id,current.id); XCTAssertFalse(m.colorAdjustmentPreviewPending)
        XCTAssertEqual(try bytes(XCTUnwrap(m.colorAdjustmentPreview)),try bytes(m.renderer.render(current.plan.preview(newest))))
    }

    @MainActor func testSourceChangeSelectionToolAndBackgroundInvalidateDraft() async throws {
        let m = try fixture()
        XCTAssertTrue(m.beginColorAdjustment(.curves)); let first = try XCTUnwrap(m.colorAdjustmentSession)
        try m.editor.transaction("旁路编辑") { $0.layers[0].name = "更名" }
        let before = m.document
        XCTAssertFalse(m.commitColorAdjustment(sessionID:first.id)); XCTAssertEqual(m.document,before)
        XCTAssertTrue(m.beginColorAdjustment(.curves)); m.tool = .eraser; XCTAssertNil(m.colorAdjustmentSession)
        XCTAssertTrue(m.beginColorAdjustment(.curves)); m.suspend(); XCTAssertNil(m.colorAdjustmentSession)
        XCTAssertTrue(m.beginColorAdjustment(.curves)); m.setLayerMultiSelecting(true); XCTAssertNil(m.colorAdjustmentSession)
        m.setLayerMultiSelecting(false); XCTAssertTrue(m.beginColorAdjustment(.curves)); let last = try XCTUnwrap(m.colorAdjustmentSession)
        XCTAssertTrue(m.updateColorAdjustment(inverted(last.value),sessionID:last.id))
        m.clearSelection(); await finishPreview(m); XCTAssertNil(m.colorAdjustmentPreview); XCTAssertNil(m.colorAdjustmentSession)
    }

    @MainActor func testSelectionSoftCoverageBecomesEditableMaskWithoutSquaringOnReedit() async throws {
        let m = try fixture(), gray = try RasterImage.context(width:16,height:12,gray:true)
        memset(try XCTUnwrap(gray.data),128,gray.bytesPerRow*gray.height)
        let mask = try RasterImage.png(XCTUnwrap(gray.makeImage()))
        m.edit("软选区") { $0.selectionMaskPNGData = mask }
        XCTAssertTrue(m.beginColorAdjustment(.curves)); let new = try XCTUnwrap(m.colorAdjustmentSession)
        XCTAssertTrue(m.updateColorAdjustment(inverted(new.value),sessionID:new.id)); await finishPreview(m)
        XCTAssertTrue(m.commitColorAdjustment(sessionID:new.id)); XCTAssertEqual(m.activeLayer?.maskPNGData,mask)
        let output = try bytes(m.renderer.render(m.document))
        XCTAssertTrue(m.beginColorAdjustment()); let edit = try XCTUnwrap(m.colorAdjustmentSession)
        XCTAssertTrue(m.updateColorAdjustment(edit.value,sessionID:edit.id)); await finishPreview(m)
        XCTAssertEqual(try bytes(XCTUnwrap(m.colorAdjustmentPreview)),output)
        XCTAssertTrue(m.commitColorAdjustment(sessionID:edit.id)); XCTAssertEqual(try bytes(m.renderer.render(m.document)),output)
        m.clearSelection(); m.setLayerEditTarget(.mask); m.fillLayerMask(reveal:false)
        XCTAssertNotEqual(m.activeLayer?.maskPNGData,mask); XCTAssertNotNil(m.activeLayer?.adjustment)
        m.undo(); XCTAssertEqual(m.activeLayer?.maskPNGData,mask)
    }

    @MainActor func testAdjustmentCannotBePaintedFilledOrUsedAsClippingBase() async throws {
        let m = try fixture(); XCTAssertTrue(m.beginColorAdjustment(.curves)); let s = try XCTUnwrap(m.colorAdjustmentSession)
        XCTAssertTrue(m.updateColorAdjustment(inverted(s.value),sessionID:s.id)); await finishPreview(m)
        XCTAssertTrue(m.commitColorAdjustment(sessionID:s.id)); let before = m.document
        m.fill(); m.commitPixels(try m.renderer.render(m.document)); XCTAssertEqual(m.document,before)
        XCTAssertFalse(m.beginTransform()); XCTAssertNil(m.transformSession)
        m.addLayerMask(); XCTAssertNotNil(m.activeLayer?.maskPNGData)
        m.fillLayerMask(reveal:false); XCTAssertNotNil(m.activeLayer?.adjustment); XCTAssertNil(m.activeLayer?.pngData)
        m.addLayer(); let candidate = m.document
        m.setLayerClipping(true); XCTAssertEqual(m.document,candidate)
    }

    @MainActor func testClippedAdjustmentDuplicateMoveVisibilityAndSourceAssetsRetained() async throws {
        let m = try fixture(), source = m.document.layers[0]
        XCTAssertTrue(m.beginColorAdjustment(.levels)); let s = try XCTUnwrap(m.colorAdjustmentSession)
        XCTAssertTrue(m.updateColorAdjustment(inverted(s.value),sessionID:s.id)); await finishPreview(m)
        XCTAssertTrue(m.commitColorAdjustment(sessionID:s.id)); let id = try XCTUnwrap(m.activeLayer?.id)
        m.setLayerClipping(true); XCTAssertEqual(m.activeLayer?.maskSourceID,source.id)
        m.duplicate(); XCTAssertEqual(m.activeLayer?.adjustment,inverted(s.value)); XCTAssertEqual(m.activeLayer?.maskSourceID,source.id)
        m.toggleVisible(id); XCTAssertEqual(m.document.layers[0].pngData,source.pngData)
        m.saveNow(); XCTAssertEqual(try DocumentStore.load(from:m.documentURL),m.document)
    }

    @MainActor func testLocksAndMultiSelectionRejectWithoutCreatingSession() throws {
        let m = try fixture(); m.toggleLock(try XCTUnwrap(m.activeLayer?.id))
        XCTAssertFalse(m.beginColorAdjustment(.levels)); XCTAssertNil(m.colorAdjustmentSession)
        m.toggleLock(try XCTUnwrap(m.activeLayer?.id)); m.addLayer(); m.setLayerMultiSelecting(true); m.toggleLayerSelection(m.document.layers[0].id)
        let before = m.document
        XCTAssertFalse(m.beginColorAdjustment(.curves)); XCTAssertEqual(m.document,before)
    }

    @MainActor func testInactiveAdjustmentCancellationDoesNotPublishUnrelatedUIChanges() throws {
        let m = try fixture(), before = m.document
        var updates = 0
        let observation = m.objectWillChange.sink { updates += 1 }
        m.cancelColorAdjustment(); m.cancelColorAdjustment()
        XCTAssertEqual(updates,0,"An unopened adjustment editor must not invalidate unrelated tool/layout snapshots")
        XCTAssertEqual(m.document,before)
        withExtendedLifetime(observation) {}
        XCTAssertTrue(m.beginTransform()); XCTAssertNotNil(m.transformSession)
    }
}
