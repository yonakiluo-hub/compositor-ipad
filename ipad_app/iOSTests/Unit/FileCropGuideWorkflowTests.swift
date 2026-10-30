import XCTest
import UIKit
import ImageIO
@testable import CompositorPad

final class FileCropGuideWorkflowTests: XCTestCase {
    @MainActor private func fixture() throws -> EditorModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("files-crop-" + UUID().uuidString)
        let docs = root.appendingPathComponent("Documents"), suite = "files-crop-" + UUID().uuidString
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let context = try RasterImage.context(width: 8, height: 6)
        context.setFillColor(UIColor.red.withAlphaComponent(0.5).cgColor); context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        context.setFillColor(UIColor.blue.cgColor); context.fill(CGRect(x: 2, y: 1, width: 3, height: 4))
        let layer = RasterLayer(name: "像素", pngData: try RasterImage.png(XCTUnwrap(context.makeImage())),
            transform: LayerTransform(origin: CGPoint(x: -2, y: 3), size: CGSize(width: 8, height: 6), sampling: .nearest),
            maskPNGData: try RasterImage.png(RasterImage.solidMask(width: 8, height: 6, white: true)))
        let doc = CanvasDocument(width: 40, height: 30, layers: [layer], activeLayerID: layer.id,
            guides: [CanvasGuide(axis: .vertical, position: 5), CanvasGuide(axis: .horizontal, position: 6)])
        try DocumentStore.save(doc, to: docs.appendingPathComponent(doc.id.uuidString.lowercased() + ".comp"))
        preferences.set(doc.id.uuidString.lowercased(), forKey: "lastDocument")
        let model = EditorModel(documentsURL: docs, supportURL: root.appendingPathComponent("Support"), preferences: preferences, loadPairing: false)
        addTeardownBlock {
            await MainActor.run { model.suspend(); UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
            try? FileManager.default.removeItem(at: root)
        }
        return model
    }
    private func pixels(_ image: CGImage) throws -> Data { try XCTUnwrap(image.dataProvider?.data) as Data }

    @MainActor func testFrozenCropPreviewOneCommitUndoAndSaveReopen() throws {
        let model = try fixture(), before = model.document
        XCTAssertTrue(model.beginCanvasCrop()); let session = try XCTUnwrap(model.cropSession)
        var rect = PixelRect(x: 2, y: 1, width: 20, height: 18)
        for i in 1...4 {
            rect.x = i
            XCTAssertTrue(model.previewCanvasCrop(rect, sessionID: session.id))
            XCTAssertEqual(model.document, before); XCTAssertEqual(model.editor.undoCount, 0)
        }
        let expected = try session.plan.preview(rect), preview = try pixels(XCTUnwrap(model.cropPreview))
        model.saveNow(); XCTAssertEqual(try DocumentStore.load(from: model.documentURL), before)
        XCTAssertTrue(model.commitCanvasCrop(rect, sessionID: session.id)); XCTAssertNil(model.cropSession)
        XCTAssertEqual(model.editor.undoCount, 1); XCTAssertEqual(model.document.layers, expected.layers)
        XCTAssertEqual(try pixels(model.renderer.render(model.document)), preview)
        XCTAssertEqual(model.document.layers[0].pngData, before.layers[0].pngData)
        XCTAssertEqual(model.document.layers[0].maskPNGData, before.layers[0].maskPNGData)
        model.saveNow(); XCTAssertEqual(try DocumentStore.load(from: model.documentURL), model.document)
        model.undo(); XCTAssertEqual(model.document.layers, before.layers); XCTAssertEqual(model.document.guides, before.guides)
        model.redo(); XCTAssertEqual(model.document.layers, expected.layers)
    }

    @MainActor func testCancelNoOpStaleEventsAndNavigationPreserveRedo() throws {
        let model = try fixture(); model.updateLayer("opacity") { $0.opacity = 0.5 }; model.undo()
        let before = model.document; XCTAssertTrue(model.editor.canRedo)
        XCTAssertTrue(model.beginCanvasCrop()); let old = try XCTUnwrap(model.cropSession)
        XCTAssertTrue(model.previewCanvasCrop(PixelRect(x: 1, y: 1, width: 20, height: 20), sessionID: old.id))
        model.cancelCanvasCrop(); XCTAssertEqual(model.document, before); XCTAssertTrue(model.editor.canRedo)
        XCTAssertTrue(model.beginCanvasCrop()); let current = try XCTUnwrap(model.cropSession)
        XCTAssertFalse(model.commitCanvasCrop(old.plan.original, sessionID: old.id))
        XCTAssertEqual(model.cropSession?.id, current.id)
        XCTAssertTrue(model.commitCanvasCrop(current.plan.original, sessionID: current.id))
        XCTAssertEqual(model.document, before); XCTAssertTrue(model.editor.canRedo)
        XCTAssertTrue(model.beginCanvasCrop()); let stale = try XCTUnwrap(model.cropSession)
        try model.editor.transaction("out-of-band") { $0.guides[0].position = 7 }
        let updated = model.document
        XCTAssertFalse(model.previewCanvasCrop(stale.plan.original, sessionID: stale.id))
        XCTAssertEqual(model.document, updated); XCTAssertNil(model.cropSession)
        XCTAssertTrue(model.beginCanvasCrop()); model.tool = .eraser; XCTAssertNil(model.cropSession)
    }

    @MainActor func testGuideTransactionsVisibilityNoOpInvalidAndPersistence() throws {
        let model = try fixture(), initial = model.document, first = initial.guides[0].id
        model.moveGuide(first, position: 9); XCTAssertEqual(model.editor.undoCount, 1)
        model.undo(); XCTAssertTrue(model.editor.canRedo)
        let restored = model.document
        model.moveGuide(first, position: initial.guides[0].position)
        model.showsGuides = false; XCTAssertTrue(model.editor.canRedo); XCTAssertEqual(model.document, restored)
        model.addGuide(axis: .vertical, position: .nan)
        XCTAssertEqual(model.document, restored); XCTAssertTrue(model.editor.canRedo)
        model.errorMessage = nil; model.redo(); XCTAssertEqual(model.document.guides[0].position, 9)
        model.addGuide(axis: .horizontal, position: 12); XCTAssertEqual(model.document.guides.count, 3)
        model.saveNow(); XCTAssertEqual(try DocumentStore.load(from: model.documentURL), model.document)
        model.clearGuides(); XCTAssertTrue(model.document.guides.isEmpty)
        model.undo(); XCTAssertEqual(model.document.guides.count, 3)
        XCTAssertEqual(model.document.layers, initial.layers)
    }

    @MainActor func testExportUsesCommittedDocumentAndPSDOpensAsNewEditableDocument() throws {
        let model = try fixture(), before = model.document
        XCTAssertTrue(model.beginCanvasCrop()); let session = try XCTUnwrap(model.cropSession)
        XCTAssertTrue(model.previewCanvasCrop(PixelRect(x: 1, y: 2, width: 10, height: 9), sessionID: session.id))
        for format in [EditorFileExport.psd, .tiff, .pdf] {
            let url = try XCTUnwrap(model.exportFile(format)); defer { try? FileManager.default.removeItem(at: url) }
            let data = try Data(contentsOf: url)
            if format == .psd {
                let decoded = try PSDCodec.read(data)
                XCTAssertEqual(decoded.width, before.width); XCTAssertEqual(decoded.height, before.height)
                XCTAssertEqual(decoded.layers.count, before.layers.count); XCTAssertEqual(decoded.guides.map(\.position), [5, 6])
                model.openPSD(url)
                XCTAssertNotEqual(model.document.id, before.id); XCTAssertNil(model.cropSession)
                XCTAssertEqual(model.document.layers[0].name, "像素"); XCTAssertEqual(model.editor.undoCount, 0)
                model.saveNow(); XCTAssertEqual(try DocumentStore.load(from: model.documentURL), model.document)
            } else if format == .tiff {
                let image = try ImageFileCodec.decode(data)
                XCTAssertEqual(image.width, before.width); XCTAssertEqual(image.height, before.height)
            } else {
                let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
                XCTAssertEqual(try XCTUnwrap(CGPDFDocument(provider)).numberOfPages, 1)
            }
        }
    }

    @MainActor func testInvalidPSDAndUnsupportedExportNeverReplaceNativeDocument() throws {
        let model = try fixture(), before = model.document
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".psd")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("8BPS bad".utf8).write(to: url)
        model.openPSD(url); XCTAssertEqual(model.document, before); XCTAssertNotNil(model.errorMessage)
        model.errorMessage = nil
        model.edit("adjustment") { doc in
            doc.layers.append(RasterLayer(name: "色阶", transform: LayerTransform(size: doc.size), adjustment: LayerAdjustment(kind: .levels)))
        }
        let adjusted = model.document
        XCTAssertNil(model.exportFile(.psd)); XCTAssertEqual(model.document, adjusted)
        model.saveNow(); XCTAssertEqual(try DocumentStore.load(from: model.documentURL), adjusted)
    }
}
