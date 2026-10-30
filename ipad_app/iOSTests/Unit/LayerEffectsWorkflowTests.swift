import XCTest
import UIKit
import Combine
@testable import CompositorPad

final class LayerEffectsWorkflowTests: XCTestCase {
    @MainActor private func fixture() throws -> EditorModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("effects-" + UUID().uuidString)
        let suite = "effects-" + UUID().uuidString, preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let m = EditorModel(documentsURL: root.appendingPathComponent("Documents"), supportURL: root.appendingPathComponent("Support"), preferences: preferences, loadPairing: false)
        m.create(name: "效果测试", width: 240, height: 180); m.color = .blue; m.fill()
        addTeardownBlock { try? FileManager.default.removeItem(at: root); UserDefaults.standard.removePersistentDomain(forName: suite) }
        return m
    }
    @MainActor private func finish(_ m: EditorModel) async {
        while m.layerEffectsTask != nil || m.layerContentTask != nil || m.colorAdjustmentTask != nil {
            if let t = m.layerEffectsTask { await t.value }
            if let t = m.layerContentTask { await t.value }
            if let t = m.colorAdjustmentTask { await t.value }
        }
    }
    private func bytes(_ image: CGImage) throws -> Data { try XCTUnwrap(image.dataProvider?.data) as Data }

    @MainActor func testFrozenPreviewOneUndoSaveReopenAndSixEffectsRemainEditable() async throws {
        let m = try fixture(), source = m.document, count = m.editor.undoCount
        XCTAssertTrue(m.beginLayerEffects()); let s = try XCTUnwrap(m.layerEffectsSession)
        var value = s.value
        for kind in LayerEffectKind.allCases { value.set(kind.defaultParameters, kind: kind) }
        for i in 0..<10 { value.shadow?.distance = Double(i); m.updateLayerEffects(value, sessionID: s.id) }
        await finish(m); XCTAssertTrue(m.canCommitLayerEffects); XCTAssertEqual(m.document, source)
        m.saveNow(); XCTAssertEqual(try DocumentStore.load(from: m.documentURL), source)
        let preview = try bytes(XCTUnwrap(m.layerEffectsPreview))
        XCTAssertTrue(m.commitLayerEffects(sessionID: s.id)); XCTAssertEqual(m.editor.undoCount, count + 1)
        XCTAssertEqual(m.activeLayer?.pngData, source.activeLayer?.pngData); XCTAssertEqual(try bytes(m.renderer.render(m.document)), preview)
        let done = m.document; m.undo(); XCTAssertEqual(m.document.layers, source.layers); m.redo(); XCTAssertEqual(m.document.layers, done.layers)
        m.saveNow(); m.open(m.documentURL); XCTAssertTrue(m.beginLayerEffects())
        let reopened = try XCTUnwrap(m.layerEffectsSession)
        for kind in LayerEffectKind.allCases { XCTAssertNotNil(reopened.value.parameters(kind)) }
        var changed = reopened.value; changed.stroke?.size = 9; m.updateLayerEffects(changed, sessionID: reopened.id); await finish(m)
        XCTAssertTrue(m.commitLayerEffects(sessionID: reopened.id)); XCTAssertEqual(m.activeLayer?.effects?.stroke?.size, 9)
    }
    @MainActor func testCancelUnchangedAndEnabledNormalizationPreserveRedo() async throws {
        let m = try fixture(); m.updateLayer("原效果") { $0.effects = LayerEffects(stroke: StrokeEffect()) }
        m.updateLayer("临时") { $0.opacity = 0.5 }; m.undo(); let source = m.document
        XCTAssertTrue(m.beginLayerEffects()); let s = try XCTUnwrap(m.layerEffectsSession)
        var value = s.value; value.stroke?.size = 8; m.updateLayerEffects(value, sessionID: s.id); m.cancelLayerEffects(); await finish(m)
        XCTAssertEqual(m.document, source); XCTAssertTrue(m.editor.canRedo)
        XCTAssertTrue(m.beginLayerEffects()); let n = try XCTUnwrap(m.layerEffectsSession)
        value = n.value; value.stroke?.enabled = true; m.updateLayerEffects(value, sessionID: n.id); await finish(m)
        XCTAssertTrue(m.commitLayerEffects(sessionID: n.id)); XCTAssertEqual(m.document, source); XCTAssertTrue(m.editor.canRedo)
    }
    @MainActor func testLateWorkerCrossToolSelectionAndSourceInvalidationCannotCommit() async throws {
        let m = try fixture(); XCTAssertTrue(m.beginLayerEffects()); let old = try XCTUnwrap(m.layerEffectsSession)
        var value = old.value; value.shadow = ShadowEffect(); m.updateLayerEffects(value, sessionID: old.id)
        XCTAssertTrue(m.beginLayerContent(.shape)); XCTAssertNil(m.layerEffectsSession)
        let shape = try XCTUnwrap(m.layerContentSession); await finish(m)
        XCTAssertFalse(m.commitLayerEffects(sessionID: old.id)); XCTAssertTrue(m.commitLayerContent(sessionID: shape.id))
        XCTAssertTrue(m.beginLayerEffects()); let changed = try XCTUnwrap(m.layerEffectsSession)
        try m.editor.updateLayer(try XCTUnwrap(m.activeLayer).id) { $0.opacity = 0.5 }
        XCTAssertFalse(m.commitLayerEffects(sessionID: changed.id)); XCTAssertNil(m.layerEffectsSession)
        XCTAssertTrue(m.beginLayerEffects()); m.tool = .move; XCTAssertNil(m.layerEffectsSession)
        XCTAssertTrue(m.beginLayerEffects()); m.suspend(); XCTAssertNil(m.layerEffectsSession)
        await finish(m)
    }
    @MainActor func testQuietCancellationBudgetFailureAndStructuredLayerMaskKeepEffects() async throws {
        let m = try fixture(); var publications = 0
        let sink = m.objectWillChange.sink { publications += 1 }; m.cancelLayerEffects(); XCTAssertEqual(publications, 0); withExtendedLifetime(sink) {}
        XCTAssertTrue(m.beginLayerContent(.shape)); await finish(m)
        XCTAssertTrue(m.commitLayerContent(sessionID: try XCTUnwrap(m.layerContentSession).id))
        XCTAssertTrue(m.beginLayerEffects()); let s = try XCTUnwrap(m.layerEffectsSession), source = m.document
        var v = s.value; v.shadow = ShadowEffect(distance: 5000); m.updateLayerEffects(v, sessionID: s.id); await finish(m)
        XCTAssertFalse(m.canCommitLayerEffects); XCTAssertNotNil(m.layerEffectsPreviewError); XCTAssertEqual(m.document, source)
        v.shadow?.distance = 5; m.updateLayerEffects(v, sessionID: s.id); await finish(m)
        XCTAssertTrue(m.commitLayerEffects(sessionID: s.id)); let effects = m.activeLayer?.effects
        m.addLayerMask(); m.fillLayerMask(reveal: false); XCTAssertEqual(m.activeLayer?.effects, effects); XCTAssertNotNil(m.activeLayer?.shape)
        m.setLayerEditTarget(.pixels); m.rasterizeLayerContent(); XCTAssertNil(m.activeLayer?.shape); XCTAssertEqual(m.activeLayer?.effects, effects)
        m.undo(); XCTAssertNotNil(m.activeLayer?.shape); XCTAssertEqual(m.activeLayer?.effects, effects)
    }
    @MainActor func testSelectedPixelTransformRefusesEffectsButWholeLayerKeepsThemAndRedo() throws {
        let m = try fixture()
        m.updateLayer("带效果的旋转层") {
            $0.effects = LayerEffects(shadow: ShadowEffect(angle: 90, distance: 8, blur: 0, red: 1))
            $0.transform.rotation = 90; $0.transform.size = CGSize(width: 120, height: 90)
        }
        let selection = try RasterImage.context(width: m.document.width, height: m.document.height, gray: true)
        selection.setFillColor(gray: 1, alpha: 1); selection.fill(CGRect(origin: .zero, size: m.document.size))
        m.commitSelection(try XCTUnwrap(selection.makeImage()))
        m.updateLayer("临时") { $0.opacity = 0.5 }; m.undo()
        let source = m.document, count = m.editor.undoCount
        XCTAssertFalse(m.beginTransform()); XCTAssertNil(m.transformSession)
        XCTAssertTrue(try XCTUnwrap(m.errorMessage).contains("取消选区可变换整个图层"))
        XCTAssertEqual(m.document, source); XCTAssertEqual(m.editor.undoCount, count); XCTAssertTrue(m.editor.canRedo)
        m.clearSelection(); XCTAssertTrue(m.beginTransform())
        let session = try XCTUnwrap(m.transformSession); var moved = session.current; moved.origin.x += 1
        XCTAssertTrue(m.previewTransform(moved, sessionID: session.id)); XCTAssertTrue(m.commitTransform(sessionID: session.id))
        XCTAssertEqual(m.activeLayer?.effects, source.activeLayer?.effects); XCTAssertEqual(m.activeLayer?.pngData, source.activeLayer?.pngData)
    }
}
