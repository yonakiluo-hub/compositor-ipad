import XCTest
import UIKit
@testable import CompositorPad

final class ClippingWorkflowTests: XCTestCase {
    @MainActor
    private func fixture() throws -> EditorModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clipping-workflow-" + UUID().uuidString)
        let docs = root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let suite = "clipping-workflow-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let context = try RasterImage.context(width: 24, height: 16)
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 0.5))
        context.fill(CGRect(x: 4, y: 3, width: 10, height: 8))
        let base = RasterLayer(name: "轮廓", pngData: try RasterImage.png(XCTUnwrap(context.makeImage())),
                               transform: LayerTransform(size: CGSize(width: 24, height: 16)))
        let top = RasterLayer(name: "上色", transform: base.transform)
        let document = CanvasDocument(name: "剪贴测试", width: 24, height: 16, layers: [base, top], activeLayerID: top.id)
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
    func testCreateFillReleaseUndoAndReopenPreserveSourcePixels() throws {
        let model = try fixture(), base = model.document.layers[0]
        XCTAssertNil(model.clippingIssue)
        model.setLayerClipping(true)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.activeLayer?.maskSourceID, base.id)
        XCTAssertEqual(model.clippingSourceName, "轮廓")
        XCTAssertEqual(model.editor.undoCount, 1)
        model.color = .blue
        model.fill()
        let clipped = try RasterImage.png(model.renderer.render(model.document))
        let originalTop = model.activeLayer?.pngData
        XCTAssertNotNil(originalTop)
        XCTAssertEqual(model.document.layers[0], base)
        model.setLayerClipping(false)
        XCTAssertNil(model.activeLayer?.maskSourceID)
        XCTAssertEqual(model.activeLayer?.pngData, originalTop)
        XCTAssertNotEqual(try RasterImage.png(model.renderer.render(model.document)), clipped)
        model.undo()
        XCTAssertEqual(model.activeLayer?.maskSourceID, base.id)
        XCTAssertEqual(try RasterImage.png(model.renderer.render(model.document)), clipped)
        model.redo()
        XCTAssertNil(model.activeLayer?.maskSourceID)
        model.undo(); model.saveNow()
        let loaded = try DocumentStore.load(from: model.documentURL)
        XCTAssertEqual(loaded.layers, model.document.layers)
        XCTAssertEqual(try RasterImage.png(model.renderer.render(loaded)), clipped)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testClippingAndEditableMaskCoexistAcrossWholeStackMergeUndo() throws {
        let model = try fixture(), base = model.document.layers[0]
        model.fill()
        model.setLayerClipping(true)
        model.addLayerMask()
        model.fillLayerMask(reveal: false)
        let source = model.document
        XCTAssertNotNil(model.activeLayer?.maskPNGData)
        XCTAssertEqual(model.activeLayer?.maskSourceID, base.id)
        model.setLayerEditTarget(.pixels)
        model.mergeLayerDown()
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.document.layers.count, 1)
        XCTAssertNil(model.activeLayer?.maskSourceID)
        model.undo()
        XCTAssertEqual(model.document.layers, source.layers)
        model.redo(); model.saveNow()
        XCTAssertEqual(try DocumentStore.load(from: model.documentURL).layers, model.document.layers)
    }

    @MainActor
    func testLockedOrMultipleLayerActionsDoNotConsumeHistory() throws {
        let model = try fixture()
        model.setLayerMultiSelecting(true)
        model.toggleLayerSelection(model.document.layers[0].id)
        let before = model.document
        model.setLayerClipping(true)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.document, before)
        XCTAssertEqual(model.editor.undoCount, 0)
        model.errorMessage = nil
        model.setLayerMultiSelecting(false)
        model.select(model.document.layers[1])
        model.toggleLock(try XCTUnwrap(model.activeLayer).id)
        let locked = model.document
        XCTAssertNotNil(model.clippingIssue)
        model.setLayerClipping(true)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.document, locked)
        XCTAssertEqual(model.editor.undoCount, 1)
    }

    @MainActor
    func testBaseDeletionExplainsDependencyWithoutLosingArtwork() throws {
        let model = try fixture()
        model.setLayerClipping(true)
        model.select(model.document.layers[0])
        let before = model.document
        model.deleteLayer()
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.document, before)
        XCTAssertEqual(model.editor.undoCount, 1)
    }
}
