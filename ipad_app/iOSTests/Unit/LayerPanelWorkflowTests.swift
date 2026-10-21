import XCTest
import UIKit
@testable import CompositorPad

final class LayerPanelWorkflowTests: XCTestCase {
    @MainActor
    private func fixture() throws -> EditorModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("layer-panel-" + UUID().uuidString)
        let docs = root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let suite = "layer-panel-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let layers = try (0..<3).map { index -> RasterLayer in
            let context = try RasterImage.context(width: 16, height: 12)
            context.setFillColor(CGColor(red: index == 0 ? 1 : 0, green: index == 1 ? 1 : 0,
                                         blue: index == 2 ? 1 : 0, alpha: 0.5))
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 12))
            return RasterLayer(name: "图层 \(index + 1)", pngData: try RasterImage.png(XCTUnwrap(context.makeImage())),
                               transform: LayerTransform(origin: CGPoint(x: index * 4 - 4, y: -2), size: CGSize(width: 16, height: 12)),
                               maskPNGData: index == 1 ? try RasterImage.png(RasterImage.solidMask(width: 16, height: 12, white: true)) : nil)
        }
        let document = CanvasDocument(name: "多选测试", width: 32, height: 24, layers: layers, activeLayerID: layers.last!.id)
        try DocumentStore.save(document, to: docs.appendingPathComponent(document.id.uuidString.lowercased() + ".comp"))
        preferences.set(document.id.uuidString.lowercased(), forKey: "lastDocument")
        let model = EditorModel(documentsURL: docs, supportURL: root.appendingPathComponent("Support"),
                                preferences: preferences, loadPairing: false)
        addTeardownBlock {
            await MainActor.run { model.suspend(); preferences.removePersistentDomain(forName: suite) }
            try? FileManager.default.removeItem(at: root)
        }
        return model
    }

    @MainActor
    func testMultiSelectionNavigationDoesNotEditOrConsumeHistory() throws {
        let model = try fixture(), before = model.document
        model.setLayerMultiSelecting(true)
        model.toggleLayerSelection(before.layers[0].id)
        XCTAssertEqual(model.selectedLayerIDs, [before.layers[0].id, before.layers[2].id])
        model.toggleLayerSelection(before.layers[0].id)
        XCTAssertEqual(model.document.activeLayerID, before.layers[2].id)
        model.toggleLayerSelection(before.layers[2].id)
        XCTAssertNil(model.document.activeLayerID)
        XCTAssertTrue(model.selectedLayerIDs.isEmpty)
        model.toggleLayerSelection(before.layers[1].id)
        model.setLayerMultiSelecting(false)
        XCTAssertEqual(model.selectedLayerIDs, [before.layers[1].id])
        XCTAssertEqual(model.document.layers, before.layers)
        XCTAssertEqual(model.document.revision, before.revision)
        XCTAssertEqual(model.editor.undoCount, 0)
    }

    @MainActor
    func testMultiSelectionCannotAccidentallyPaintAdjustOrTransformOnlyActiveLayer() throws {
        let model = try fixture()
        model.setLayerMultiSelecting(true)
        model.toggleLayerSelection(model.document.layers[1].id)
        let before = model.document
        model.fill()
        XCTAssertNotNil(model.errorMessage)
        model.errorMessage = nil
        model.updateLayer("不应应用") { $0.opacity = 0.2 }
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.beginTransform())
        XCTAssertEqual(model.document, before)
        XCTAssertEqual(model.editor.undoCount, 0)
    }

    @MainActor
    func testMergeOneTransactionRestoresMaskedSourcesAndReopens() throws {
        let model = try fixture(), before = model.document
        model.setLayerMultiSelecting(true)
        model.toggleLayerSelection(before.layers[1].id)
        model.mergeSelectedLayers()
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.document.layers.count, 2)
        XCTAssertEqual(model.document.layers[0], before.layers[0])
        XCTAssertEqual(model.editor.undoCount, 1)
        XCTAssertFalse(model.isLayerMultiSelecting)
        XCTAssertEqual(model.selectedLayerIDs, [try XCTUnwrap(model.document.activeLayerID)])
        let merged = model.document
        model.undo()
        XCTAssertEqual(model.document.layers, before.layers)
        XCTAssertTrue(model.selectedLayerIDs.isSubset(of: Set(before.layers.map(\.id))))
        model.redo()
        XCTAssertEqual(model.document.layers, merged.layers)
        model.saveNow()
        XCTAssertEqual(try DocumentStore.load(from: model.documentURL).layers, merged.layers)
    }

    @MainActor
    func testUnsupportedMergeKeepsDocumentAndRedo() throws {
        let model = try fixture()
        model.updateLayer("临时改名") { $0.name = "临时" }
        model.undo()
        model.setLayerMultiSelecting(true)
        model.toggleLayerSelection(model.document.layers[0].id)
        let before = model.document
        model.mergeSelectedLayers()
        XCTAssertTrue(model.errorMessage?.contains("连续") == true)
        XCTAssertEqual(model.document, before)
        XCTAssertTrue(model.editor.canRedo)
    }

    @MainActor
    func testStampStartsHiddenAndPreservesSourcesAcrossUndoReopen() throws {
        let model = try fixture(), before = model.document
        let original = try RasterImage.png(model.renderer.render(before))
        model.stampVisibleLayers()
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(Array(model.document.layers.prefix(before.layers.count)), before.layers)
        XCTAssertFalse(try XCTUnwrap(model.activeLayer).isVisible)
        XCTAssertEqual(try RasterImage.png(model.renderer.render(model.document)), original)
        XCTAssertEqual(model.activeLayer?.pngData, original)
        XCTAssertEqual(model.editor.undoCount, 1)
        model.undo()
        XCTAssertEqual(model.document.layers, before.layers)
        model.redo(); model.saveNow()
        XCTAssertEqual(try DocumentStore.load(from: model.documentURL).layers, model.document.layers)
    }

    @MainActor
    func testMaskSelectionAndDocumentChangeResetNavigationTarget() throws {
        let model = try fixture()
        let masked = model.document.layers[1]
        model.selectLayerTarget(masked, target: .mask)
        XCTAssertEqual(model.layerEditTarget, .mask)
        model.setLayerMultiSelecting(true)
        XCTAssertEqual(model.layerEditTarget, .pixels)
        model.toggleLayerSelection(model.document.layers[0].id)
        model.addLayer()
        XCTAssertEqual(model.selectedLayerIDs, [try XCTUnwrap(model.document.activeLayerID)])
        model.create(name: "新画稿", width: 24, height: 16)
        XCTAssertFalse(model.isLayerMultiSelecting)
        XCTAssertEqual(model.selectedLayerIDs, [try XCTUnwrap(model.document.activeLayerID)])
        XCTAssertEqual(model.layerEditTarget, .pixels)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testMaskEraserShowsHideAndWhiteChoiceReturnsToPaint() throws {
        let model = try fixture()
        model.selectLayerTarget(model.document.layers[1], target: .mask)
        model.chooseMaskPaintMode(reveals: true)
        model.tool = .eraser
        XCTAssertFalse(model.maskPaintReveals)
        XCTAssertTrue(model.layerMaskBrushSettings.erasing)
        model.chooseMaskPaintMode(reveals: true)
        XCTAssertEqual(model.tool, .brush)
        XCTAssertFalse(model.layerMaskBrushSettings.erasing)
        let original = model.activeLayer?.maskPNGData
        model.tool = .mask
        XCTAssertTrue(model.tool.isSelection)
        model.tool = .brush
        XCTAssertEqual(model.layerEditTarget, .mask)
        XCTAssertEqual(model.activeLayer?.maskPNGData, original)
    }
}
