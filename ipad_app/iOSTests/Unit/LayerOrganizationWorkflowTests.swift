import XCTest
import UIKit
@testable import CompositorPad

final class LayerOrganizationWorkflowTests: XCTestCase {
    @MainActor
    private func fixture() throws -> EditorModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("organization-" + UUID().uuidString)
        let docs = root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let suite = "organization-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let image = try RasterImage.context(width: 16, height: 12)
        image.setFillColor(UIColor.systemBlue.cgColor); image.fill(CGRect(x: 0, y: 0, width: 16, height: 12))
        let group = RasterLayer(name: "组", transform: .init(size: CGSize(width: 32, height: 24)), isGroup: true)
        let first = RasterLayer(name: "一", pngData: try RasterImage.png(XCTUnwrap(image.makeImage())), transform: .init(size: CGSize(width: 16, height: 12)))
        let second = RasterLayer(name: "二", transform: .init(size: CGSize(width: 16, height: 12)))
        let document = CanvasDocument(width: 32, height: 24, layers: [group, first, second], activeLayerID: first.id)
        try DocumentStore.save(document, to: docs.appendingPathComponent(document.id.uuidString.lowercased() + ".comp"))
        preferences.set(document.id.uuidString.lowercased(), forKey: "lastDocument")
        let model = EditorModel(documentsURL: docs, supportURL: root.appendingPathComponent("Support"), preferences: preferences, loadPairing: false)
        addTeardownBlock {
            await MainActor.run { model.suspend(); UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
            try? FileManager.default.removeItem(at: root)
        }
        return model
    }

    @MainActor
    func testGroupingMultiSelectionOneTransactionAndReopens() throws {
        let model = try fixture(), before = model.document
        model.setLayerMultiSelecting(true); model.toggleLayerSelection(before.layers[2].id)
        let context = model.beginLayerOrganization()
        _ = try model.layerOrganizationPlan(context, action: .group)
        XCTAssertEqual(model.document.layers, before.layers); XCTAssertEqual(model.editor.undoCount, 0)
        XCTAssertTrue(model.organizeLayers(context, action: .group))
        let group = try XCTUnwrap(model.activeLayer)
        XCTAssertTrue(group.isGroup); XCTAssertFalse(model.isLayerMultiSelecting)
        XCTAssertEqual(model.selectedLayerIDs, [group.id]); XCTAssertEqual(model.layerEditTarget, .pixels)
        XCTAssertEqual(model.editor.undoCount, 1)
        let grouped = model.document
        model.undo(); XCTAssertEqual(model.document.layers, before.layers)
        model.redo(); XCTAssertEqual(model.document.layers, grouped.layers)
        model.saveNow(); XCTAssertEqual(try DocumentStore.load(from: model.documentURL), model.document)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testMoveAndMoveOutRetainMultiSelectionWithoutNavigationHistory() throws {
        let model = try fixture(), before = model.document, ids: Set<UUID> = [before.layers[1].id, before.layers[2].id]
        model.setLayerMultiSelecting(true); model.toggleLayerSelection(before.layers[2].id)
        XCTAssertTrue(model.organizeLayers(model.beginLayerOrganization(), action: .move(parentID: before.layers[0].id, position: .bottom)))
        XCTAssertEqual(model.selectedLayerIDs, ids); XCTAssertTrue(model.isLayerMultiSelecting)
        XCTAssertTrue(model.document.layers.filter { ids.contains($0.id) }.allSatisfy { $0.parentID == before.layers[0].id })
        XCTAssertEqual(model.editor.undoCount, 1)
        XCTAssertTrue(model.organizeLayers(model.beginLayerOrganization(), action: .moveOut))
        XCTAssertEqual(model.selectedLayerIDs, ids); XCTAssertEqual(model.editor.undoCount, 2)
        XCTAssertTrue(model.document.layers.filter { ids.contains($0.id) }.allSatisfy { $0.parentID == nil })
    }

    @MainActor
    func testOpeningOrCancelingOrganizerCancelsTransformWithoutCommittingPreview() throws {
        let model = try fixture(), before = model.document
        XCTAssertTrue(model.beginTransform())
        let session = try XCTUnwrap(model.transformSession)
        var transform = session.original; transform.origin.x += 10
        XCTAssertTrue(model.previewTransform(transform, sessionID: session.id))
        _ = model.beginLayerOrganization()
        XCTAssertNil(model.transformSession)
        XCTAssertFalse(model.commitTransform(sessionID: session.id))
        XCTAssertEqual(model.document, before); XCTAssertEqual(model.editor.undoCount, 0)
    }

    @MainActor
    func testStaleContextRejectsChangedRevisionDocumentAndSelection() throws {
        let model = try fixture(), context = model.beginLayerOrganization()
        model.setLayerMultiSelecting(true); model.toggleLayerSelection(model.document.layers[2].id)
        let before = model.document
        XCTAssertFalse(model.organizeLayers(context, action: .group))
        XCTAssertEqual(model.document, before); XCTAssertEqual(model.editor.undoCount, 0)
        model.errorMessage = nil
        let newContext = model.beginLayerOrganization()
        model.addLayer()
        let edited = model.document
        XCTAssertFalse(model.organizeLayers(newContext, action: .group)); XCTAssertEqual(model.document, edited)
        model.errorMessage = nil
        let oldDocument = model.beginLayerOrganization()
        model.create(name: "另一稿", width: 24, height: 16)
        let replacement = model.document
        XCTAssertFalse(model.organizeLayers(oldDocument, action: .moveOut)); XCTAssertEqual(model.document, replacement)
    }

    @MainActor
    func testIncompleteClippingKeepsSelectionDocumentAndRedo() throws {
        let model = try fixture()
        model.select(model.document.layers[2]); model.setLayerClipping(true)
        model.updateLayer("临时透明度") { $0.opacity = 0.5 }; model.undo()
        let original = model.document, selected = model.selectedLayerIDs
        XCTAssertFalse(model.organizeLayers(model.beginLayerOrganization(), action: .move(parentID: original.layers[0].id, position: .top)))
        XCTAssertEqual(model.document, original); XCTAssertEqual(model.selectedLayerIDs, selected)
        XCTAssertTrue(model.editor.canRedo)
        XCTAssertTrue(model.errorMessage?.contains("剪贴") == true)
    }

    @MainActor
    func testNoOpOrganizerPreservesRedoAndDoesNotEndMultiSelection() throws {
        let model = try fixture()
        model.select(model.document.layers[2]); model.updateLayer("透明度") { $0.opacity = 0.5 }; model.undo()
        model.setLayerMultiSelecting(true)
        let before = model.document
        XCTAssertTrue(model.organizeLayers(model.beginLayerOrganization(), action: .move(parentID: nil, position: .top)))
        XCTAssertEqual(model.document, before); XCTAssertTrue(model.editor.canRedo)
        XCTAssertTrue(model.isLayerMultiSelecting); XCTAssertEqual(model.status, "图层已在此位置")
    }
}
