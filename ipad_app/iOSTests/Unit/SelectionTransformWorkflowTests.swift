import XCTest
import UIKit
@testable import CompositorPad

final class SelectionTransformWorkflowTests: XCTestCase {
    private enum Coverage { case hard, soft, empty, outside, none }

    @MainActor
    private func fixture(_ coverage: Coverage = .hard, maskEnabled: Bool = true) throws
        -> (model: EditorModel, root: URL, preferences: UserDefaults) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("selection-transform-" + UUID().uuidString)
        let documents = root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let suite = "selection-transform-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let pixels = try RasterImage.context(width: 32, height: 24)
        let mask = try RasterImage.context(width: 32, height: 24, gray: true)
        for y in 0..<24 { for x in 0..<32 {
            pixels.setFillColor(CGColor(red: CGFloat(x + 1) / 33, green: CGFloat(y + 1) / 25, blue: 0.6, alpha: 1))
            pixels.fill(CGRect(x: x, y: y, width: 1, height: 1))
            mask.setFillColor(gray: x < 16 ? 0.5 : 1, alpha: 1)
            mask.fill(CGRect(x: x, y: y, width: 1, height: 1))
        } }
        let layer = RasterLayer(name: "选中源图层", pngData: try RasterImage.png(XCTUnwrap(pixels.makeImage())),
            transform: LayerTransform(origin: CGPoint(x: 4, y: 6), size: CGSize(width: 32, height: 24), sampling: .nearest),
            maskPNGData: try RasterImage.png(XCTUnwrap(mask.makeImage())), maskEnabled: maskEnabled)
        let other = RasterLayer(name: "其他图层", pngData: layer.pngData,
            transform: LayerTransform(origin: CGPoint(x: 44, y: 36), size: CGSize(width: 4, height: 3), sampling: .nearest))
        let selection = try RasterImage.context(width: 48, height: 40, gray: true)
        if coverage == .hard || coverage == .soft {
            selection.setFillColor(gray: coverage == .soft ? 0.5 : 1, alpha: 1)
            selection.fill(CGRect(x: 8, y: 10, width: 8, height: 6))
            if coverage == .soft {
                selection.setFillColor(gray: 1, alpha: 1)
                selection.fill(CGRect(x: 10, y: 12, width: 4, height: 2))
            }
        } else if coverage == .outside {
            selection.setFillColor(gray: 1, alpha: 1)
            selection.fill(CGRect(x: 40, y: 32, width: 4, height: 4))
        }
        let document = CanvasDocument(name: "选区变换事务测试", width: 48, height: 40, layers: [layer, other], activeLayerID: layer.id,
            selectionMaskPNGData: coverage == .none ? nil : try RasterImage.png(XCTUnwrap(selection.makeImage())))
        try DocumentStore.save(document, to: documents.appendingPathComponent(document.id.uuidString.lowercased() + ".comp"))
        preferences.set(document.id.uuidString.lowercased(), forKey: "lastDocument")
        let model = EditorModel(documentsURL: documents, supportURL: root.appendingPathComponent("Support"),
                                preferences: preferences, loadPairing: false)
        addTeardownBlock {
            await MainActor.run { model.suspend(); UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
            try? FileManager.default.removeItem(at: root)
        }
        XCTAssertNil(model.errorMessage)
        return (model, root, preferences)
    }

    private func samples(_ image: CGImage) throws -> [[UInt8]] {
        let data = try XCTUnwrap(image.dataProvider?.data)
        let bytes = try XCTUnwrap(CFDataGetBytePtr(data)), channels = image.bitsPerPixel / 8
        return (0..<image.height).flatMap { y in
            (0..<image.width).map { x in (0..<channels).map { bytes[y * image.bytesPerRow + x * channels + $0] } }
        }
    }

    private func shifted(_ transform: LayerTransform, x: CGFloat = 12, y: CGFloat = 8) -> LayerTransform {
        var result = transform
        result.origin.x += x; result.origin.y += y
        return result
    }

    @MainActor
    private func previewImage(_ model: EditorModel) throws -> CGImage {
        if let replacement = model.transformPreviewReplacement, let session = model.transformSession {
            return try model.renderer.render(model.transformPreviewDocument, replacing: session.layerID,
                                             with: replacement.image, replacementMask: replacement.mask)
        }
        return try model.renderer.render(model.transformPreviewDocument)
    }

    @MainActor
    func testSelectedPixelsAndCoverageMoveTogetherInOneUndoWithoutMovingOutsideContent() throws {
        let model = try fixture().model
        let before = model.document, source = try XCTUnwrap(model.activeLayer)
        let originalPixels = try samples(RasterImage.decode(XCTUnwrap(source.pngData)))
        let originalMask = try samples(RasterImage.decode(XCTUnwrap(source.maskPNGData)))
        XCTAssertTrue(model.beginTransform())
        let session = try XCTUnwrap(model.transformSession)
        XCTAssertEqual(session.scope, .selection)
        XCTAssertEqual(session.original.origin, CGPoint(x: 8, y: 10))
        XCTAssertEqual(session.original.size, CGSize(width: 8, height: 6))
        XCTAssertNotEqual(session.original, source.transform, "The handles describe the selection, not the whole layer")
        for x in 1...12 {
            XCTAssertTrue(model.previewTransform(shifted(session.original, x: CGFloat(x)), sessionID: session.id))
            XCTAssertEqual(model.document, before)
            XCTAssertEqual(model.editor.undoCount, 0)
            XCTAssertFalse(model.editor.isModified)
        }
        let replacement = try XCTUnwrap(model.transformPreviewReplacement)
        XCTAssertEqual(replacement.transform, source.transform)
        XCTAssertEqual(replacement.image.width, 32)
        XCTAssertEqual(replacement.image.height, 24)
        XCTAssertEqual(try samples(XCTUnwrap(replacement.mask)), originalMask, "The independent layer mask stays in place")
        let movedPixels = try samples(replacement.image)
        for y in 0..<24 { for x in 0..<32 {
            let oldRegion = (4..<12).contains(x) && (4..<10).contains(y)
            let newRegion = (16..<24).contains(x) && (12..<18).contains(y)
            if oldRegion { XCTAssertEqual(movedPixels[y * 32 + x][3], 0) }
            else if newRegion { XCTAssertEqual(movedPixels[y * 32 + x], originalPixels[(y - 8) * 32 + x - 12]) }
            else { XCTAssertEqual(movedPixels[y * 32 + x], originalPixels[y * 32 + x]) }
        } }
        let movedCoverage = try samples(replacement.selection).map { $0[0] }
        for y in 0..<40 { for x in 0..<48 {
            XCTAssertEqual(movedCoverage[y * 48 + x], (20..<28).contains(x) && (18..<24).contains(y) ? 255 : 0)
        } }
        XCTAssertEqual(try samples(XCTUnwrap(model.displayedSelectionPreview)).map { $0[0] }, movedCoverage)
        let visiblePreview = try samples(previewImage(model))
        XCTAssertTrue(model.commitTransform(sessionID: session.id))
        XCTAssertNil(model.transformSession)
        XCTAssertNil(model.transformPreviewReplacement)
        XCTAssertEqual(model.editor.undoCount, 1)
        XCTAssertEqual(model.editor.undoName, "变换选区内容")
        XCTAssertEqual(model.document.revision, before.revision + 1)
        XCTAssertEqual(model.document.layers[1], before.layers[1])
        XCTAssertEqual(model.activeLayer?.maskEnabled, source.maskEnabled)
        XCTAssertEqual(try samples(RasterImage.decode(XCTUnwrap(model.activeLayer?.pngData))), movedPixels)
        XCTAssertEqual(try samples(XCTUnwrap(model.selectionPreview)).map { $0[0] }, movedCoverage)
        XCTAssertEqual(try samples(model.renderer.render(model.document)), visiblePreview)
        let committed = model.document
        model.undo()
        XCTAssertEqual(model.document.layers, before.layers)
        XCTAssertEqual(model.document.selectionMaskPNGData, before.selectionMaskPNGData)
        model.redo()
        XCTAssertEqual(model.document.layers, committed.layers)
        XCTAssertEqual(model.document.selectionMaskPNGData, committed.selectionMaskPNGData)
    }

    @MainActor
    func testSoftSelectionCancelAndReturnToIdentityKeepOriginalBytesAndRedo() throws {
        let model = try fixture(.soft).model
        model.rename("等待重做"); model.undo()
        let before = model.document, redoName = model.editor.redoName
        XCTAssertTrue(model.beginTransform())
        var session = try XCTUnwrap(model.transformSession)
        XCTAssertTrue(model.previewTransform(shifted(session.original), sessionID: session.id))
        let moved = try XCTUnwrap(model.transformPreviewReplacement)
        let softCoverage = try samples(moved.selection).map { $0[0] }
        XCTAssertTrue(softCoverage.contains { $0 > 0 && $0 < 255 })
        model.cancelTransform()
        XCTAssertEqual(model.document, before)
        XCTAssertTrue(model.editor.canRedo)
        XCTAssertEqual(model.editor.redoName, redoName)

        XCTAssertTrue(model.beginTransform())
        session = try XCTUnwrap(model.transformSession)
        XCTAssertTrue(model.previewTransform(shifted(session.original), sessionID: session.id))
        XCTAssertTrue(model.previewTransform(session.original, sessionID: session.id))
        XCTAssertNil(model.transformPreviewReplacement)
        XCTAssertEqual(model.transformPreviewDocument, before)
        XCTAssertEqual(try samples(XCTUnwrap(model.displayedSelectionPreview)), try samples(XCTUnwrap(model.selectionPreview)))
        XCTAssertTrue(model.commitTransform())
        XCTAssertEqual(model.document, before, "A no-op must preserve exact encoded source, mask and soft-selection bytes")
        XCTAssertTrue(model.editor.canRedo)
        XCTAssertEqual(model.editor.redoName, redoName)
    }

    @MainActor
    func testSessionScopeRejectsEmptyAndUncoveredSelectionsWithoutFallingBackToLayer() throws {
        for kind in [Coverage.empty, .outside] {
            let model = try fixture(kind).model, before = model.document
            XCTAssertFalse(model.beginTransform())
            XCTAssertNil(model.transformSession)
            XCTAssertNotNil(model.errorMessage)
            XCTAssertEqual(model.document, before)
            XCTAssertEqual(model.editor.undoCount, 0)
        }
        let model = try fixture(.none).model
        XCTAssertTrue(model.beginTransform())
        XCTAssertEqual(model.transformSession?.scope, .layer)
        XCTAssertEqual(model.transformSession?.original, model.activeLayer?.transform)
        XCTAssertNil(model.displayedSelectionPreview)
    }

    @MainActor
    func testLateEventsLayerSelectionChangesAndBackgroundDiscardOnlyPreview() throws {
        let model = try fixture().model, before = model.document
        XCTAssertTrue(model.beginTransform())
        let old = try XCTUnwrap(model.transformSession)
        XCTAssertTrue(model.previewTransform(shifted(old.original), sessionID: old.id))
        model.cancelTransform()
        XCTAssertTrue(model.beginTransform())
        let fresh = try XCTUnwrap(model.transformSession)
        XCTAssertFalse(model.previewTransform(shifted(old.original), sessionID: old.id))
        XCTAssertFalse(model.commitTransform(sessionID: old.id))
        XCTAssertEqual(model.transformSession, fresh)
        model.select(model.document.layers[1])
        XCTAssertNil(model.transformSession)
        XCTAssertFalse(model.previewTransform(shifted(fresh.original), sessionID: fresh.id))
        model.select(model.document.layers[0])
        XCTAssertEqual(model.document, before)
        XCTAssertTrue(model.beginTransform())
        var session = try XCTUnwrap(model.transformSession)
        XCTAssertTrue(model.previewTransform(shifted(session.original), sessionID: session.id))
        model.suspend()
        XCTAssertNil(model.transformSession)
        XCTAssertEqual(model.document, before)
        XCTAssertEqual(try DocumentStore.load(from: model.documentURL), before)

        XCTAssertTrue(model.beginTransform())
        session = try XCTUnwrap(model.transformSession)
        model.clearSelection()
        XCTAssertNil(model.transformSession)
        XCTAssertFalse(model.previewTransform(shifted(session.original), sessionID: session.id))
        XCTAssertFalse(model.commitTransform(sessionID: session.id))
        XCTAssertEqual(model.editor.undoCount, 1, "Only the explicit clear-selection edit enters history")
    }

    @MainActor
    func testExpandedPreviewSavesOnlyAfterCommitAndReopensWithSelectionAndStationaryMask() throws {
        let fixture = try fixture(), model = fixture.model, before = fixture.model.document
        XCTAssertTrue(model.beginTransform())
        let session = try XCTUnwrap(model.transformSession)
        XCTAssertTrue(model.previewTransform(shifted(session.original, x: 32, y: 19), sessionID: session.id))
        let replacement = try XCTUnwrap(model.transformPreviewReplacement)
        XCTAssertGreaterThan(replacement.image.width, 32)
        XCTAssertGreaterThan(replacement.image.height, 24)
        let grownMask = try XCTUnwrap(replacement.mask), grownSamples = try samples(grownMask).map { $0[0] }
        let originalMask = try samples(RasterImage.decode(XCTUnwrap(before.activeLayer?.maskPNGData))).map { $0[0] }
        for y in 0..<grownMask.height { for x in 0..<grownMask.width {
            XCTAssertEqual(grownSamples[y * grownMask.width + x], x < 32 && y < 24 ? originalMask[y * 32 + x] : 255)
        } }
        let previewPixels = try samples(previewImage(model))
        model.saveNow()
        XCTAssertNotNil(model.transformSession)
        XCTAssertEqual(try DocumentStore.load(from: model.documentURL), before)
        XCTAssertTrue(model.commitTransform())
        XCTAssertEqual(model.editor.undoCount, 1)
        XCTAssertEqual(try samples(model.renderer.render(model.document)), previewPixels)
        model.saveNow()
        let reopened = EditorModel(documentsURL: model.documentsURL, supportURL: fixture.root.appendingPathComponent("ReopenedSupport"),
                                   preferences: fixture.preferences, loadPairing: false)
        defer { reopened.suspend() }
        XCTAssertNil(reopened.errorMessage)
        XCTAssertNil(reopened.transformSession)
        XCTAssertEqual(reopened.document, model.document)
        XCTAssertEqual(try samples(XCTUnwrap(reopened.selectionPreview)), try samples(replacement.selection))
        XCTAssertEqual(try samples(reopened.renderer.render(reopened.document)), previewPixels)
        XCTAssertEqual(reopened.document.layers[1], before.layers[1])
    }

    @MainActor
    func testDisabledIndependentMaskStaysDisabledAndPreviewEqualsCommit() throws {
        let model = try fixture(.soft, maskEnabled: false).model
        let originalMask = try samples(RasterImage.decode(XCTUnwrap(model.activeLayer?.maskPNGData)))
        XCTAssertTrue(model.beginTransform())
        let session = try XCTUnwrap(model.transformSession)
        XCTAssertTrue(model.previewTransform(shifted(session.original), sessionID: session.id))
        let replacement = try XCTUnwrap(model.transformPreviewReplacement)
        XCTAssertEqual(try samples(XCTUnwrap(replacement.mask)), originalMask)
        let previewPixels = try samples(previewImage(model))
        XCTAssertTrue(model.commitTransform())
        XCTAssertEqual(model.activeLayer?.maskEnabled, false)
        XCTAssertEqual(try samples(RasterImage.decode(XCTUnwrap(model.activeLayer?.maskPNGData))), originalMask)
        XCTAssertEqual(try samples(model.renderer.render(model.document)), previewPixels)
    }

    @MainActor
    func testFailedRasterPreviewKeepsLastValidCachedResultAndCommittedDocument() throws {
        let model = try fixture().model, before = model.document
        XCTAssertTrue(model.beginTransform())
        let session = try XCTUnwrap(model.transformSession), valid = shifted(session.original)
        XCTAssertTrue(model.previewTransform(valid, sessionID: session.id))
        let cached = try XCTUnwrap(model.transformPreviewReplacement)
        var tooLarge = valid
        tooLarge.size = CGSize(width: 300_000, height: 300_000)
        XCTAssertTrue(tooLarge.isValid)
        XCTAssertFalse(model.previewTransform(tooLarge, sessionID: session.id))
        XCTAssertEqual(model.transformSession?.current, valid)
        XCTAssertTrue(try XCTUnwrap(model.transformPreviewReplacement).image === cached.image)
        XCTAssertEqual(model.document, before)
        XCTAssertEqual(model.editor.undoCount, 0)
        XCTAssertTrue(model.commitTransform())
        XCTAssertEqual(try samples(RasterImage.decode(XCTUnwrap(model.activeLayer?.pngData))), try samples(cached.image))
    }
}
