import XCTest
import UIKit
@testable import CompositorPad

final class LayerMaskWorkflowTests: XCTestCase {
    @MainActor
    private func fixture(maskValue: UInt8? = 255, enabled: Bool = true, maskWidth: Int = 16,
                         maskHeight: Int = 12, transform: LayerTransform? = nil,
                         selectionValue: UInt8? = nil, emptyLayer: Bool = false) throws -> EditorModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("layer-mask-" + UUID().uuidString)
        let documents = root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let suite = "layer-mask-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let pixels = try RasterImage.context(width: 16, height: 12)
        pixels.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.6, alpha: 1))
        pixels.fill(CGRect(x: 0, y: 0, width: 16, height: 12))
        let layer = RasterLayer(name: "蒙版源图层",
            pngData: emptyLayer ? nil : try RasterImage.png(XCTUnwrap(pixels.makeImage())),
            transform: transform ?? LayerTransform(origin: CGPoint(x: 8, y: 10), size: CGSize(width: 16, height: 12), sampling: .nearest),
            maskPNGData: try maskValue.map { try RasterImage.png(gray(width: maskWidth, height: maskHeight, value: $0)) },
            maskEnabled: enabled)
        let other = RasterLayer(name: "另一个图层", transform: LayerTransform(size: CGSize(width: 64, height: 48)))
        let document = CanvasDocument(name: "图层蒙版测试", width: 64, height: 48, layers: [layer, other], activeLayerID: layer.id,
            selectionMaskPNGData: try selectionValue.map { try RasterImage.png(gray(width: 64, height: 48, value: $0)) })
        try DocumentStore.save(document, to: documents.appendingPathComponent(document.id.uuidString.lowercased() + ".comp"))
        preferences.set(document.id.uuidString.lowercased(), forKey: "lastDocument")
        let model = EditorModel(documentsURL: documents, supportURL: root.appendingPathComponent("Support"),
                                preferences: preferences, loadPairing: false)
        addTeardownBlock {
            await MainActor.run { model.suspend(); UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
            try? FileManager.default.removeItem(at: root)
        }
        XCTAssertNil(model.errorMessage)
        return model
    }

    private func gray(width: Int, height: Int, value: UInt8) throws -> CGImage {
        let context = try RasterImage.context(width: width, height: height, gray: true)
        memset(try XCTUnwrap(context.data), Int32(value), context.bytesPerRow * height)
        return try XCTUnwrap(context.makeImage())
    }

    private func bytes(_ image: CGImage) throws -> [UInt8] {
        let data = try XCTUnwrap(image.dataProvider?.data), pointer = try XCTUnwrap(CFDataGetBytePtr(data))
        return (0..<image.height).flatMap { row in
            (0..<image.width * image.bitsPerPixel / 8).map { pointer[row * image.bytesPerRow + $0] }
        }
    }

    @MainActor
    private func mask(_ model: EditorModel) throws -> CGImage {
        try RasterImage.decode(XCTUnwrap(model.activeLayer?.maskPNGData))
    }

    @MainActor
    private func stroke(_ model: EditorModel, at point: CGPoint = CGPoint(x: 8, y: 6)) throws -> LayerMaskStrokeSession {
        model.setLayerEditTarget(.mask); model.maskPaintReveals = false
        model.diameter = 100; model.hardness = 1
        let session = try LayerMaskStrokeSession(model: model)
        session.stroke.add(BrushSample(point: point, pressure: 1, altitude: .pi / 2, azimuth: 0))
        return session
    }

    @MainActor
    func testAddingWhiteMaskKeepsSourceAndSelectionAndCreatesOneUndo() throws {
        let model = try fixture(maskValue: nil, selectionValue: 128)
        let before = model.document
        model.addLayerMask()
        XCTAssertEqual(model.layerEditTarget, .mask)
        XCTAssertTrue(try bytes(mask(model)).allSatisfy { $0 == 255 })
        XCTAssertEqual(model.activeLayer?.pngData, before.activeLayer?.pngData)
        XCTAssertEqual(model.document.selectionMaskPNGData, before.selectionMaskPNGData)
        XCTAssertEqual(model.editor.undoCount, 1)
        let after = model.document
        model.addLayerMask()
        XCTAssertEqual(model.document, after)
        model.undo()
        XCTAssertNil(model.activeLayer?.maskPNGData)
        XCTAssertEqual(model.layerEditTarget, .pixels)
        model.redo()
        XCTAssertEqual(model.document.layers, after.layers)
    }

    @MainActor
    func testSoftSelectedStrokeAppliesCoverageAndOpacityOnceAndPreservesSource() throws {
        let model = try fixture(selectionValue: 128)
        model.brushOpacity = 0.5
        let before = model.document
        let session = try stroke(model)
        for _ in 0..<12 {
            session.stroke.add(BrushSample(point: CGPoint(x: 8, y: 6), pressure: 1, altitude: .pi / 2, azimuth: 0))
        }
        XCTAssertEqual(model.document, before, "Live previews never mutate the document")
        let preview = try session.stroke.image()
        XCTAssertTrue(try bytes(preview).allSatisfy { abs(Int($0) - 191) <= 1 })
        XCTAssertEqual(preview.bitsPerPixel, 8)
        XCTAssertEqual(preview.alphaInfo, .none)
        XCTAssertTrue(model.commitLayerMaskStroke(session))
        XCTAssertEqual(model.editor.undoCount, 1)
        XCTAssertEqual(model.activeLayer?.pngData, before.activeLayer?.pngData)
        XCTAssertEqual(model.document.selectionMaskPNGData, before.selectionMaskPNGData)
        XCTAssertEqual(model.activeLayer?.transform, before.activeLayer?.transform)
        XCTAssertEqual(try bytes(mask(model)), try bytes(preview))
        XCTAssertFalse(model.commitLayerMaskStroke(session), "A completed stroke cannot be committed twice")
    }

    @MainActor
    func testRevealFillAndInvertKeepPartialGraysNumericAndUseSelectionOnce() throws {
        let model = try fixture(maskValue: 64, selectionValue: 128)
        model.fillLayerMask(reveal: true)
        XCTAssertTrue(try bytes(mask(model)).allSatisfy { abs(Int($0) - 160) <= 1 })
        model.undo()
        model.fillLayerMask(reveal: false)
        XCTAssertTrue(try bytes(mask(model)).allSatisfy { abs(Int($0) - 32) <= 1 })
        model.undo()
        model.invertLayerMask()
        XCTAssertTrue(try bytes(mask(model)).allSatisfy { abs(Int($0) - 128) <= 1 })
        model.undo(); model.clearSelection(); model.invertLayerMask()
        XCTAssertTrue(try bytes(mask(model)).allSatisfy { $0 == 191 })
    }

    @MainActor
    func testMaskStrokePreservesDisabledStateAndPreviewMatchesCommit() throws {
        let model = try fixture(maskValue: 173, enabled: false)
        let before = model.document, renderedBefore = try bytes(model.renderer.render(before))
        let session = try stroke(model)
        let live = try model.renderer.render(model.document, replacing: session.layer.id, with: session.sourcePixels,
                                             replacementMask: session.stroke.image())
        XCTAssertEqual(try bytes(live), renderedBefore)
        XCTAssertTrue(model.commitLayerMaskStroke(session))
        XCTAssertEqual(model.activeLayer?.maskEnabled, false)
        XCTAssertTrue(try bytes(mask(model)).allSatisfy { $0 == 0 })
        XCTAssertEqual(try bytes(model.renderer.render(model.document)), renderedBefore)
        model.setLayerMaskEnabled(true)
        XCTAssertTrue(try bytes(model.renderer.render(model.document)).allSatisfy { $0 == 0 })
    }

    @MainActor
    func testMaskOwnGridMapsFlippedRotatedSelectionAndStrokeToSamePlace() throws {
        let transform = LayerTransform(origin: CGPoint(x: 14, y: 14), size: CGSize(width: 16, height: 12),
                                       rotation: 90, flipX: true, sampling: .nearest)
        let model = try fixture(maskWidth: 8, maskHeight: 6, transform: transform)
        let layer = try XCTUnwrap(model.activeLayer)
        let mapping = model.renderer.pixelToDocument(layer, size: CGSize(width: 8, height: 6))
        let local = CGPoint(x: 2.5, y: 1.5), documentPoint = local.applying(mapping)
        let selection = try RasterImage.context(width: 64, height: 48, gray: true)
        selection.setFillColor(gray: 1, alpha: 1)
        selection.fill(CGRect(x: documentPoint.x - 1, y: documentPoint.y - 1, width: 2, height: 2))
        model.commitSelection(try XCTUnwrap(selection.makeImage()))
        model.setLayerEditTarget(.mask); model.maskPaintReveals = false; model.diameter = 4; model.hardness = 1
        let session = try LayerMaskStrokeSession(model: model)
        XCTAssertEqual(session.stroke.size, CGSize(width: 8, height: 6))
        let mappedPoint = documentPoint.applying(mapping.inverted())
        XCTAssertEqual(mappedPoint.x, local.x, accuracy: 0.000001)
        XCTAssertEqual(mappedPoint.y, local.y, accuracy: 0.000001)
        session.stroke.add(BrushSample(point: mappedPoint, pressure: 1, altitude: .pi / 2, azimuth: 0))
        let live = try model.renderer.render(model.document, replacing: layer.id, with: session.sourcePixels,
                                             replacementMask: session.stroke.image())
        XCTAssertTrue(model.commitLayerMaskStroke(session))
        let values = try bytes(mask(model))
        for y in 0..<6 { for x in 0..<8 { XCTAssertEqual(values[y * 8 + x], x == 2 && y == 1 ? 0 : 255) } }
        XCTAssertEqual(try bytes(model.renderer.render(model.document)), try bytes(live))
        XCTAssertEqual(model.activeLayer?.transform, transform)
    }

    @MainActor
    func testCancelledPreviewAndInvalidatedTargetCannotCommit() throws {
        let model = try fixture()
        let original = model.document
        let cancelled = try stroke(model)
        _ = try cancelled.stroke.image()
        XCTAssertEqual(model.document, original)
        XCTAssertEqual(model.editor.undoCount, 0)
        model.setLayerEditTarget(.pixels)
        XCTAssertFalse(model.commitLayerMaskStroke(cancelled))
        XCTAssertEqual(model.document, original)

        let changedMode = try stroke(model)
        model.maskPaintReveals = true
        XCTAssertFalse(model.commitLayerMaskStroke(changedMode))
        let changedTool = try stroke(model)
        model.tool = .mask
        XCTAssertFalse(model.commitLayerMaskStroke(changedTool))
        let changedLayer = try stroke(model)
        model.select(model.document.layers[1])
        XCTAssertFalse(model.commitLayerMaskStroke(changedLayer))
        XCTAssertEqual(model.document.layers, original.layers)
    }

    @MainActor
    func testRevisionSelectionAndMultipleSelectionInvalidateStroke() throws {
        let model = try fixture()
        let beforeSelection = try stroke(model)
        model.commitSelection(try gray(width: 64, height: 48, value: 128))
        XCTAssertFalse(model.commitLayerMaskStroke(beforeSelection))
        let beforeMulti = try stroke(model)
        model.selectedLayerIDs = Set(model.document.layers.map(\.id))
        XCTAssertFalse(model.commitLayerMaskStroke(beforeMulti))
        XCTAssertThrowsError(try LayerMaskStrokeSession(model: model))
        XCTAssertTrue(try bytes(mask(model)).allSatisfy { $0 == 255 })
    }

    @MainActor
    func testStrokeUndoRedoAndSaveReopenKeepMaskSourceSelectionAndEnabledState() throws {
        let model = try fixture(maskValue: 171, enabled: false, maskWidth: 8, maskHeight: 6, selectionValue: 128)
        let before = model.document
        let session = try stroke(model, at: CGPoint(x: 4, y: 3))
        XCTAssertTrue(model.commitLayerMaskStroke(session))
        let after = model.document
        XCTAssertEqual(model.editor.undoCount, 1)
        model.undo()
        XCTAssertEqual(model.document.layers, before.layers)
        XCTAssertEqual(model.document.selectionMaskPNGData, before.selectionMaskPNGData)
        model.redo()
        XCTAssertEqual(model.document.layers, after.layers)
        model.saveNow()
        XCTAssertFalse(model.saveFailed)
        let reopened = try DocumentStore.load(from: model.documentURL)
        XCTAssertEqual(reopened.layers, after.layers)
        XCTAssertEqual(reopened.selectionMaskPNGData, before.selectionMaskPNGData)
        XCTAssertEqual(reopened.activeLayer?.pngData, before.activeLayer?.pngData)
        XCTAssertEqual(reopened.activeLayer?.maskEnabled, false)
        XCTAssertEqual(try RasterImage.decode(XCTUnwrap(reopened.activeLayer?.maskPNGData)).width, 8)
    }

    @MainActor
    func testMaskOnEmptySourceNeverCreatesSourcePixelsAndCanBeRemovedUndone() throws {
        let model = try fixture(emptyLayer: true)
        let session = try stroke(model)
        XCTAssertTrue(try bytes(session.sourcePixels).allSatisfy { $0 == 0 })
        XCTAssertTrue(model.commitLayerMaskStroke(session))
        XCTAssertNil(model.activeLayer?.pngData)
        let painted = model.activeLayer?.maskPNGData
        model.removeLayerMask()
        XCTAssertNil(model.activeLayer?.maskPNGData)
        XCTAssertEqual(model.layerEditTarget, .pixels)
        model.undo()
        XCTAssertEqual(model.activeLayer?.maskPNGData, painted)
        XCTAssertNil(model.activeLayer?.pngData)
    }

    @MainActor
    func testLoadDisabledPartialMaskAsSelectionKeepsMaskAndPixelBytes() throws {
        let model = try fixture(maskValue: 128, enabled: false, maskWidth: 8, maskHeight: 6)
        let before = model.document
        model.layerMaskToSelection()
        XCTAssertEqual(model.document.layers, before.layers)
        XCTAssertEqual(model.editor.undoCount, 1)
        let selection = try bytes(XCTUnwrap(model.selectionPreview))
        for y in 0..<48 { for x in 0..<64 {
            XCTAssertEqual(selection[y * 64 + x], (8..<24).contains(x) && (10..<22).contains(y) ? 128 : 0)
        } }
        model.undo()
        XCTAssertNil(model.document.selectionMaskPNGData)
    }

    @MainActor
    func testSelectionBrushRemainsSeparateFromLayerMaskTarget() throws {
        let model = try fixture(maskValue: 173)
        model.setLayerEditTarget(.mask)
        let before = model.activeLayer
        model.tool = .mask
        var settings = model.brushSettings
        settings.diameter = 1000; settings.hardness = 1
        let stroke = try PadBrushStroke(width: 64, height: 48, original: gray(width: 64, height: 48, value: 64),
                                       settings: settings, selection: nil, maskMode: true)
        stroke.add(BrushSample(point: CGPoint(x: 32, y: 24), pressure: 1, altitude: .pi / 2, azimuth: 0))
        model.commitSelection(try stroke.image())
        XCTAssertEqual(model.activeLayer, before)
        XCTAssertTrue(try bytes(XCTUnwrap(model.selectionPreview)).allSatisfy { $0 == 255 })
    }
}
