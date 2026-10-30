import XCTest
import CoreGraphics
@testable import CompositorKit

final class EditableContentTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var active = 0, peak = 0, calls = 0
        func enter() { lock.lock(); active += 1; calls += 1; peak = max(peak, active); lock.unlock() }
        func leave() { lock.lock(); active -= 1; lock.unlock() }
        func values() -> (Int, Int) { lock.lock(); defer { lock.unlock() }; return (peak, calls) }
    }
    private func png(_ color: CGColor = CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1), width: Int = 64, height: Int = 64) throws -> Data {
        let c = try RasterImage.context(width: width, height: height); c.setFillColor(color); c.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try RasterImage.png(XCTUnwrap(c.makeImage()))
    }
    private func shape(_ style: LayerShapeStyle = LayerShapeStyle(cornerRadius: 12), size: CGSize = CGSize(width: 64, height: 64)) throws -> RasterLayer {
        RasterLayer(name: "形状", pngData: try RasterImage.png(LayerContentRaster.shapeImage(style, size: size)), transform: .init(size: size), shape: style)
    }
    private func doc(_ layer: RasterLayer) -> CanvasDocument { CanvasDocument(width: 256, height: 256, layers: [layer], activeLayerID: layer.id) }
    private func rgba(_ image: CGImage) throws -> [UInt8] {
        let c = try RasterImage.context(width: image.width, height: image.height)
        RasterImage.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), context: c)
        return Array(UnsafeBufferPointer(start: try XCTUnwrap(c.data).assumingMemoryBound(to: UInt8.self), count: c.bytesPerRow * c.height))
    }
    private func package() throws -> URL {
        let p = FileManager.default.temporaryDirectory.appendingPathComponent("content-" + UUID().uuidString).appendingPathExtension("comp")
        addTeardownBlock { try? FileManager.default.removeItem(at: p) }; return p
    }
    private func mutateManifest(_ url: URL, _ change: (inout [String: Any]) -> Void) throws {
        let path = url.appendingPathComponent("manifest.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any]); change(&object)
        try JSONSerialization.data(withJSONObject: object).write(to: path)
        try? FileManager.default.removeItem(at: url.appendingPathComponent("ipad-state.json"))
    }

    func testStyleValidationRejectsInvalidRangesGeometryAndMetadata() {
        var t = LayerTextStyle(); XCTAssertTrue(t.isValid)
        t.fontSize = .nan; XCTAssertFalse(t.isValid); t.fontSize = 48
        t.fontName = ""; XCTAssertFalse(t.isValid); t.fontName = "Helvetica"
        t.content = "中文测试"; t.colorRuns = [LayerTextColorRun(location: 1, length: 3, red: 1, green: 0, blue: 0), LayerTextColorRun(location: 2, length: 1, red: 0, green: 1, blue: 0)]
        XCTAssertFalse(t.isValid)
        t.colorRuns = nil; t.fontRuns = [LayerTextFontRun(location: Int.max, length: 2, fontName: "Helvetica")]; XCTAssertFalse(t.isValid)
        var s = LayerShapeStyle(kind: .line, lineWidth: 2, start: .zero, end: CGPoint(x: 1, y: 1)); XCTAssertTrue(s.isValid)
        s.end = CGPoint(x: 2, y: 1); XCTAssertFalse(s.isValid)
        s.end = nil; XCTAssertFalse(s.isValid)
    }

    func testChineseCoreTextRendersMultipleLinesAndPreservesInlineRuns() throws {
        let style = LayerTextStyle(content: "中文图层\n可继续编辑", fontSize: 24, boxSize: CGSize(width: 220, height: 130),
            colorRuns: [LayerTextColorRun(location: 0, length: 2, red: 1, green: 0, blue: 0)])
        let image = try LayerContentRaster.textImage(style), p = try rgba(image)
        XCTAssertEqual(image.width, 220); XCTAssertEqual(image.height, 130)
        let rows = (0..<image.height).filter { y in (0..<image.width).contains { p[(y * image.width + $0) * 4 + 3] > 0 } }
        XCTAssertGreaterThan(try XCTUnwrap(rows.last) - XCTUnwrap(rows.first), 24)
        XCTAssertTrue(stride(from: 0, to: p.count, by: 4).contains { p[$0] > p[$0 + 1] && p[$0 + 3] > 0 })
    }

    func testMissingFontKeepsSavedFallbackPixelsUntilAnExplicitEdit() throws {
        let data = try png(), style = LayerTextStyle(content: "字体缺失", fontName: "Compositor-Missing-Font", fontSize: 20)
        let layer = RasterLayer(name: "文字", pngData: data, transform: .init(size: CGSize(width: 64, height: 64)), text: style)
        let source = doc(layer), p = try package(); try DocumentStore.save(source, to: p)
        let loaded = try DocumentStore.load(from: p)
        XCTAssertEqual(loaded, source); XCTAssertEqual(loaded.activeLayer?.pngData, data)
        XCTAssertEqual(LayerContentRaster.missingFonts(style), ["Compositor-Missing-Font"])
        XCTAssertEqual(try rgba(DocumentRenderer().render(loaded)), try rgba(DocumentRenderer().render(source)))
        XCTAssertEqual(try rgba(RasterImage.decode(data)).prefix(4), [0, 0, 255, 255])
    }

    func testNewTextOneTransactionEmptyNoOpAndStalePlanKeepsRedo() throws {
        let source = doc(try shape()), editor = try DocumentEditor(document: source)
        try editor.updateLayer(source.layers[0].id) { $0.opacity = 0.5 }; try editor.undo(); XCTAssertTrue(editor.canRedo)
        let plan = try EditableLayerEdit(document: editor.document, new: .text)
        var empty = plan.original; empty.text?.content = " \n"
        try editor.transaction("空文字") { try plan.apply(empty, to: &$0) }; XCTAssertTrue(editor.canRedo); XCTAssertEqual(editor.undoCount, 0)
        var value = plan.original; value.text?.content = "标题"
        try editor.transaction("文字") { try plan.apply(value, to: &$0) }
        XCTAssertEqual(editor.undoCount, 1); XCTAssertEqual(editor.document.layers.count, 2); XCTAssertEqual(editor.document.activeLayer?.text?.content, "标题")
        let done = editor.document; try editor.undo(); try editor.redo(); XCTAssertEqual(editor.document.layers, done.layers)
        XCTAssertThrowsError(try editor.transaction("过期") { try plan.apply(value, to: &$0) })
        XCTAssertEqual(editor.document.layers, done.layers)
    }

    func testNewContentInsertsAboveFullClippingStackAndInsideGroup() throws {
        let base = try shape(), child = RasterLayer(name: "剪贴", pngData: try png(), transform: base.transform, maskSourceID: base.id)
        let source = CanvasDocument(width: 256, height: 256, layers: [base, child], activeLayerID: base.id)
        let plan = try EditableLayerEdit(document: source, new: .shape), prepared = try plan.preview(plan.original)
        XCTAssertEqual(prepared.layers.map(\.id), [base.id, child.id, plan.layer.id]); XCTAssertEqual(prepared.layers[1].maskSourceID, base.id)
        let group = RasterLayer(name: "组", transform: .init(size: source.size), isGroup: true)
        let grouped = CanvasDocument(width: 256, height: 256, layers: [group], activeLayerID: group.id)
        let inside = try EditableLayerEdit(document: grouped, new: .text)
        XCTAssertEqual(try inside.preview(inside.original).activeLayer?.parentID, group.id)
    }

    func testShapeResizeRedrawsDocumentRadiusAndPreviewMatchesCommit() throws {
        var layer = try shape(); layer.maskPNGData = try RasterImage.png(RasterImage.solidMask(width: 64, height: 64, white: true))
        let source = doc(layer), editor = try DocumentEditor(document: source)
        var preview = source; preview.layers[0].transform.size = CGSize(width: 128, height: 128)
        let expected = try rgba(DocumentRenderer().render(preview))
        try editor.updateLayer(layer.id) { $0.transform.size = CGSize(width: 128, height: 128) }
        let actual = try XCTUnwrap(editor.document.activeLayer)
        XCTAssertEqual(actual.shape, layer.shape); XCTAssertEqual(actual.maskPNGData, layer.maskPNGData)
        XCTAssertEqual(try PNGAsset.inspect(XCTUnwrap(actual.pngData)).width, 128)
        XCTAssertEqual(expected, try rgba(DocumentRenderer().render(editor.document)))
        let pixels = try rgba(RasterImage.decode(XCTUnwrap(actual.pngData)))
        XCTAssertGreaterThan(pixels[18 * 4 + 3], 200)
    }

    func testGeometryDuplicationAndReopenPreserveEditableContentAndOriginalPixels() throws {
        let style = LayerTextStyle(content: "保留结构", fontSize: 24, boxSize: CGSize(width: 200, height: 100))
        let image = try LayerContentRaster.textImage(style), data = try RasterImage.png(image)
        let layer = RasterLayer(name: "文字", pngData: data, transform: .init(size: CGSize(width: 200, height: 100)), text: style)
        let editor = try DocumentEditor(document: doc(layer))
        try editor.updateLayer(layer.id) { $0.transform.origin = CGPoint(x: 17.5, y: -9); $0.transform.rotation = 30; $0.transform.size = CGSize(width: 400, height: 200) }
        XCTAssertEqual(editor.document.activeLayer?.pngData, data); XCTAssertEqual(editor.document.activeLayer?.text, style)
        let duplicate = try editor.duplicateLayer(layer.id), copy = try XCTUnwrap(editor.document.layers.first { $0.id == duplicate })
        XCTAssertEqual(copy.text, style); XCTAssertEqual(copy.pngData, data); XCTAssertEqual(copy.transform, editor.document.layers[0].transform)
        let p = try package(); try DocumentStore.save(editor.document, to: p); XCTAssertEqual(try DocumentStore.load(from: p), editor.document)
    }

    func testFractionalShapeResizePreviewAndCommitUseTheSamePreciseSize() throws {
        var layer = try shape(LayerShapeStyle(cornerRadius: 24))
        layer.transform.origin = CGPoint(x: 32, y: 32)
        let source = CanvasDocument(width: 128, height: 128, layers: [layer], activeLayerID: layer.id)
        for size in [CGSize(width: 63.2, height: 64), CGSize(width: 64, height: 63.2), CGSize(width: 63.2, height: 63.6)] {
            let editor = try DocumentEditor(document: source), renderer = DocumentRenderer()
            _ = try renderer.render(source)
            var preview = source; preview.layers[0].transform.size = size
            let expected = try rgba(renderer.render(preview))
            XCTAssertEqual(expected, try rgba(DocumentRenderer().render(preview)))
            try editor.updateLayer(layer.id) { $0.transform.size = size }
            XCTAssertNotEqual(editor.document.activeLayer?.pngData, layer.pngData)
            XCTAssertEqual(expected, try rgba(renderer.render(editor.document)))
            XCTAssertEqual(expected, try rgba(DocumentRenderer().render(editor.document)))
            try editor.undo(); XCTAssertEqual(editor.document.layers, source.layers)
            try editor.redo(); XCTAssertEqual(expected, try rgba(renderer.render(editor.document)))
        }
    }

    func testCanvasGrowthThenRasterizationPreservesShapeAppearanceAndUndoStructure() throws {
        var layer = try shape(LayerShapeStyle(cornerRadius: 24))
        layer.transform.origin = CGPoint(x: 32, y: 32)
        let source = CanvasDocument(width: 128, height: 128, layers: [layer], activeLayerID: layer.id)
        let editor = try DocumentEditor(document: source), renderer = DocumentRenderer()
        try editor.transaction("扩大画布") { try renderer.resizeCanvas(&$0, width: 160, height: 128, resample: false) }
        XCTAssertEqual(editor.document.layers, source.layers)
        let expanded = editor.document, expected = try rgba(renderer.render(expanded))
        var raster = try LayerContentRaster.redrawShape(XCTUnwrap(expanded.activeLayer)); raster.rasterizeContent()
        try editor.updateLayer(layer.id, name: "栅格化形状") { $0 = raster }
        XCTAssertNil(editor.document.activeLayer?.shape)
        XCTAssertEqual(expected, try rgba(renderer.render(editor.document)))
        XCTAssertEqual(expected, try rgba(DocumentRenderer().render(editor.document)))
        try editor.undo(); XCTAssertEqual(editor.document.layers, expanded.layers)
        XCTAssertEqual(expected, try rgba(renderer.render(editor.document)))
        try editor.redo(); XCTAssertNil(editor.document.activeLayer?.shape)
        XCTAssertEqual(expected, try rgba(renderer.render(editor.document)))
    }

    func testPixelEditingRequiresExplicitRasterizationAndUndoRestoresStructure() throws {
        let layer = try shape(), editor = try DocumentEditor(document: doc(layer)), replacement = try png()
        XCTAssertThrowsError(try editor.setPixels(layerID: layer.id, pngData: replacement))
        try editor.updateLayer(layer.id, name: "栅格化") { $0.rasterizeContent() }
        XCTAssertFalse(try XCTUnwrap(editor.document.activeLayer).hasEditableContent)
        try editor.setPixels(layerID: layer.id, pngData: replacement)
        try editor.undo(); try editor.undo(); XCTAssertEqual(editor.document.activeLayer?.shape, layer.shape); XCTAssertEqual(editor.document.activeLayer?.pngData, layer.pngData)
    }

    func testLockedSourceAndUnknownNestedFieldsRejectWithoutTouchingOriginal() throws {
        var layer = try shape(); layer.isLocked = true
        XCTAssertThrowsError(try EditableLayerEdit(document: doc(layer)))
        layer.isLocked = false; let source = doc(layer), p = try package(); try DocumentStore.save(source, to: p)
        try mutateManifest(p) { object in
            var layers = object["layers"] as! [[String: Any]], shape = layers[0]["shape"] as! [String: Any]
            shape["unknownFill"] = true; layers[0]["shape"] = shape; object["layers"] = layers
        }
        let before = try Data(contentsOf: p.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(try DocumentStore.load(from: p)); XCTAssertEqual(try Data(contentsOf: p.appendingPathComponent("manifest.json")), before)
    }

    func testRichTextVersionAndUnknownRunFieldsAreStrict() throws {
        let style = LayerTextStyle(content: "样式", fontSize: 20, colorRuns: [LayerTextColorRun(location: 0, length: 1, red: 1, green: 0, blue: 0)])
        let layer = RasterLayer(name: "文字", pngData: try RasterImage.png(LayerContentRaster.textImage(style)), transform: .init(size: CGSize(width: 100, height: 60)), text: style)
        let p = try package(); try DocumentStore.save(doc(layer), to: p)
        try mutateManifest(p) { $0["version"] = 9 }; XCTAssertThrowsError(try DocumentStore.load(from: p))
        try DocumentStore.save(doc(layer), to: p)
        try mutateManifest(p) { object in
            var layers = object["layers"] as! [[String: Any]], text = layers[0]["text"] as! [String: Any], runs = text["colorRuns"] as! [[String: Any]]
            runs[0]["extra"] = 1; text["colorRuns"] = runs; layers[0]["text"] = text; object["layers"] = layers
        }
        XCTAssertThrowsError(try DocumentStore.load(from: p))
    }

    func testEllipseLineAndSmoothedRectangleRenderDistinctEditablePixels() throws {
        let size = CGSize(width: 80, height: 60)
        let ellipse = try rgba(LayerContentRaster.shapeImage(LayerShapeStyle(kind: .ellipse), size: size))
        let rect = try rgba(LayerContentRaster.shapeImage(LayerShapeStyle(cornerRadius: 12, smoothing: true), size: size))
        let line = try rgba(LayerContentRaster.shapeImage(LayerShapeStyle(kind: .line, lineWidth: 6,
            start: CGPoint(x: 0.1, y: 0.5), end: CGPoint(x: 0.9, y: 0.5)), size: size))
        XCTAssertNotEqual(ellipse, rect); XCTAssertNotEqual(line, rect); XCTAssertEqual(line[3], 0)
        XCTAssertEqual(line[(30 * 80 + 40) * 4 + 3], 255)
    }

    func testSharedPreviewQueueNeverRunsTwoAllocationClosuresTogether() async {
        let queue = DocumentPreviewQueue(), counter = Counter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask {
                    _ = await queue.perform { counter.enter(); Thread.sleep(forTimeInterval:0.02); counter.leave(); return 1 }
                }
            }
        }
        XCTAssertEqual(counter.values().0, 1); XCTAssertEqual(counter.values().1, 4)
    }

    func testCanceledQueuedPreviewSkipsItsAllocationClosure() async {
        let queue = DocumentPreviewQueue(), counter = Counter(), started = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let first = Task { await queue.perform { started.signal(); release.wait(); return 1 } }
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        let second = Task { await queue.perform { counter.enter(); counter.leave(); return 2 } }
        await Task.yield(); second.cancel(); release.signal(); _ = await first.value
        let result = await second.value
        switch result { case .failure(let error): XCTAssertTrue(error is CancellationError); case .success: XCTFail("Canceled preview must not render") }
        XCTAssertEqual(counter.values().1, 0)
    }
}
