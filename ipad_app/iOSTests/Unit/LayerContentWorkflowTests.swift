import XCTest
import UIKit
import Combine
@testable import CompositorPad

final class LayerContentWorkflowTests: XCTestCase {
    func testNumericInputPublishesLocalizedValuesAndRejectsIncompleteOrNonfiniteText() {
        let en = Locale(identifier: "en_US"), de = Locale(identifier: "de_DE"), ar = Locale(identifier: "ar_EG")
        let range = -100.0...4096.0
        XCTAssertEqual(ContentNumberInput.parse("20", range: range, locale: en), 20)
        XCTAssertEqual(ContentNumberInput.parse("20\n", range: range, locale: en), 20)
        XCTAssertEqual(ContentNumberInput.parse("-0.5", range: range, locale: en), -0.5)
        XCTAssertEqual(ContentNumberInput.parse("20,5", range: range, locale: de), 20.5)
        XCTAssertEqual(ContentNumberInput.parse("١٢٫٥", range: range, locale: ar), 12.5)
        XCTAssertEqual(ContentNumberInput.parse("9000", range: range, locale: en), 4096)
        XCTAssertEqual(ContentNumberInput.parse("-9000", range: range, locale: en), -100)
        XCTAssertEqual(ContentNumberInput.number("9000", locale: en), 9000, "Draft validation must see out-of-range input before clamping")
        for input in ["", "-", ".", "NaN", "inf", "2..0", "20px"] {
            XCTAssertNil(ContentNumberInput.parse(input, range: range, locale: en), input)
        }
        XCTAssertEqual(ContentNumberInput.format(20, locale: en), "20")
        XCTAssertEqual(ContentNumberInput.format(20.5, locale: de), "20,5")
    }
    @MainActor private func fixture() throws -> EditorModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("editable-content-" + UUID().uuidString)
        let docs = root.appendingPathComponent("Documents"), suite = "editable-content-" + UUID().uuidString
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let m = EditorModel(documentsURL: docs, supportURL: root.appendingPathComponent("Support"), preferences: preferences, loadPairing: false)
        m.create(name: "合成测试", width: 320, height: 240); m.color = .red; m.fill(); m.saveNow()
        addTeardownBlock { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
        return m
    }
    @MainActor private func finish(_ m: EditorModel) async { while let worker = m.layerContentTask { await worker.value } }
    private func bytes(_ image: CGImage) throws -> Data { try XCTUnwrap(image.dataProvider?.data) as Data }

    @MainActor func testTextPreviewCommitOneUndoSaveReopenAndEditAgain() async throws {
        let m = try fixture(), source = m.document, count = m.editor.undoCount
        XCTAssertTrue(m.beginLayerContent(.text)); let session = try XCTUnwrap(m.layerContentSession)
        var value = session.value
        for n in 0..<12 { value.text?.content = "中文标题 \(n)"; value.text?.fontSize = 24; m.updateLayerContent(value, sessionID: session.id) }
        await finish(m)
        XCTAssertTrue(m.canCommitLayerContent); XCTAssertEqual(m.document, source)
        let preview = try bytes(XCTUnwrap(m.layerContentPreview))
        m.saveNow(); XCTAssertEqual(try DocumentStore.load(from: m.documentURL), source)
        XCTAssertTrue(m.commitLayerContent(sessionID: session.id)); XCTAssertEqual(m.editor.undoCount, count + 1)
        XCTAssertEqual(m.activeLayer?.text?.content, "中文标题 11"); XCTAssertEqual(m.document.layers[0].pngData, source.layers[0].pngData)
        XCTAssertEqual(try bytes(m.renderer.render(m.document)), preview)
        let done = m.document; m.undo(); XCTAssertEqual(m.document.layers, source.layers); m.redo(); XCTAssertEqual(m.document.layers, done.layers)
        m.saveNow(); m.open(m.documentURL)
        XCTAssertTrue(m.beginLayerContent()); let edit = try XCTUnwrap(m.layerContentSession)
        var next = edit.value; next.text?.content = "保存后仍可编辑"; m.updateLayerContent(next, sessionID: edit.id); await finish(m)
        XCTAssertTrue(m.commitLayerContent(sessionID: edit.id)); XCTAssertEqual(m.activeLayer?.text?.content, "保存后仍可编辑")
    }

    @MainActor func testCancelEmptyTextAndUnchangedReeditPreserveRedo() async throws {
        let m = try fixture(); m.updateLayer("临时") { $0.opacity = 0.5 }; m.undo(); XCTAssertTrue(m.editor.canRedo)
        let source = m.document
        XCTAssertTrue(m.beginLayerContent(.shape)); await finish(m); m.cancelLayerContent()
        XCTAssertEqual(m.document, source); XCTAssertTrue(m.editor.canRedo)
        XCTAssertTrue(m.beginLayerContent(.text)); let s = try XCTUnwrap(m.layerContentSession)
        var value = s.value; value.text?.content = ""; m.updateLayerContent(value, sessionID: s.id); await finish(m)
        XCTAssertTrue(m.commitLayerContent(sessionID: s.id)); XCTAssertEqual(m.document, source); XCTAssertTrue(m.editor.canRedo)
        m.redo(); XCTAssertEqual(m.activeLayer?.opacity, 0.5)
    }

    @MainActor func testOldWorkerAndLateCommitCannotAffectNewContentSession() async throws {
        let m = try fixture(); XCTAssertTrue(m.beginLayerContent(.text)); let old = try XCTUnwrap(m.layerContentSession)
        var value = old.value; value.text?.content = "旧预览"; m.updateLayerContent(value, sessionID: old.id)
        m.cancelLayerContent(); XCTAssertTrue(m.beginLayerContent(.shape)); let new = try XCTUnwrap(m.layerContentSession)
        var shape = new.value; shape.shape?.kind = .ellipse; m.updateLayerContent(shape, sessionID: new.id)
        m.updateLayerContent(value, sessionID: old.id); XCTAssertFalse(m.commitLayerContent(sessionID: old.id)); await finish(m)
        XCTAssertEqual(m.layerContentSession?.id, new.id); XCTAssertNil(m.layerContentPreviewError); XCTAssertTrue(m.canCommitLayerContent)
        XCTAssertTrue(m.commitLayerContent(sessionID: new.id)); XCTAssertEqual(m.activeLayer?.shape?.kind, .ellipse); XCTAssertNil(m.activeLayer?.text)
    }

    @MainActor func testPixelsRequireRasterizationWhileMaskAndGeometryKeepStructure() async throws {
        let m = try fixture(); XCTAssertTrue(m.beginLayerContent(.shape)); await finish(m)
        XCTAssertTrue(m.commitLayerContent(sessionID: try XCTUnwrap(m.layerContentSession).id)); let layer = try XCTUnwrap(m.activeLayer)
        let source = m.document
        m.fill(); m.applyAdjustment(brightness: 0.2, contrast: 1, saturation: 1, blur: 0)
        m.commitPixels(try XCTUnwrap(RasterImage.context(width: 5, height: 5).makeImage()))
        XCTAssertEqual(m.document, source)
        m.addLayerMask(); XCTAssertNotNil(m.activeLayer?.shape); m.fillLayerMask(reveal: false); XCTAssertNotNil(m.activeLayer?.shape)
        m.setLayerEditTarget(.pixels); XCTAssertTrue(m.beginTransform()); let t = try XCTUnwrap(m.transformSession)
        var next = t.current; next.origin.x += 9; XCTAssertTrue(m.previewTransform(next, sessionID: t.id)); XCTAssertTrue(m.commitTransform())
        XCTAssertEqual(m.activeLayer?.shape, layer.shape)
        m.rasterizeLayerContent(); XCTAssertNil(m.activeLayer?.shape); m.undo(); XCTAssertNotNil(m.activeLayer?.shape)
    }

    @MainActor func testQuadWarpRequiresExplicitRasterizationAndUndoRestoresEditableShape() async throws {
        let m = try fixture()
        XCTAssertTrue(m.beginLayerContent(.shape)); await finish(m)
        XCTAssertTrue(m.commitLayerContent(sessionID: try XCTUnwrap(m.layerContentSession).id))
        let source = m.document, history = m.editor.undoCount
        XCTAssertFalse(m.beginQuadWarp(.distort))
        XCTAssertTrue(m.errorMessage?.contains("栅格化") == true)
        XCTAssertEqual(m.document, source); XCTAssertEqual(m.editor.undoCount, history)
        XCTAssertThrowsError(try LayerWarpSource(document: source, selectedIDs: m.selectedLayerIDs, renderer: m.renderer))
        m.rasterizeLayerContent()
        XCTAssertTrue(m.beginQuadWarp(.distort)); m.cancelQuadWarp()
        m.undo(); XCTAssertEqual(m.document.layers, source.layers)
    }

    @MainActor func testMissingFontPreservesPixelsAndRequiresReplacementBeforeChangedCommit() async throws {
        let m = try fixture(), original = try XCTUnwrap(m.activeLayer?.pngData)
        m.updateLayer("可编辑文字") { $0.text = LayerTextStyle(content: "原字体", fontName: "Compositor-Missing-Font", fontSize: 20) }
        let source = m.document
        XCTAssertTrue(m.beginLayerContent()); let s = try XCTUnwrap(m.layerContentSession)
        XCTAssertEqual(s.missingFonts, ["Compositor-Missing-Font"]); XCTAssertTrue(m.canCommitLayerContent)
        XCTAssertEqual(m.activeLayer?.pngData, original)
        var value = s.value; value.text?.content = "新正文"; m.updateLayerContent(value, sessionID: s.id); await finish(m)
        XCTAssertFalse(m.canCommitLayerContent); XCTAssertFalse(m.commitLayerContent(sessionID: s.id)); XCTAssertEqual(m.document, source)
        value.text?.fontName = "Helvetica"; value.text?.fontRuns = nil; m.updateLayerContent(value, sessionID: s.id); await finish(m)
        XCTAssertTrue(m.canCommitLayerContent); XCTAssertTrue(m.commitLayerContent(sessionID: s.id)); XCTAssertEqual(m.activeLayer?.text?.fontName, "Helvetica")
    }

    @MainActor func testToolBackgroundChangedSourceAndSelectionInvalidatePreview() async throws {
        let m = try fixture(); XCTAssertTrue(m.beginLayerContent(.shape)); m.tool = .move; XCTAssertNil(m.layerContentSession)
        XCTAssertTrue(m.beginLayerContent(.text)); m.suspend(); XCTAssertNil(m.layerContentSession)
        XCTAssertTrue(m.beginLayerContent(.shape)); let s = try XCTUnwrap(m.layerContentSession)
        try m.editor.updateLayer(m.document.layers[0].id) { $0.opacity = 0.4 }
        XCTAssertFalse(m.commitLayerContent(sessionID: s.id)); XCTAssertNil(m.layerContentSession)
        XCTAssertTrue(m.beginLayerContent(.text)); let pending = try XCTUnwrap(m.layerContentSession)
        m.selectedLayerIDs = []
        XCTAssertFalse(m.commitLayerContent(sessionID: pending.id)); XCTAssertNil(m.layerContentSession)
        await finish(m)
    }

    @MainActor func testInactiveContentCancellationDoesNotPublishAndLockedTargetRejects() throws {
        let m = try fixture(); var changes = 0
        let sink = m.objectWillChange.sink { changes += 1 }
        m.cancelLayerContent(); m.cancelLayerContent(); XCTAssertEqual(changes, 0); withExtendedLifetime(sink) {}
        m.updateLayer("锁定") { $0.isLocked = true }; XCTAssertFalse(m.beginLayerContent(.text)); XCTAssertNil(m.layerContentSession)
    }
}
