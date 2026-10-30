import XCTest
import CoreGraphics
@testable import CompositorKit

final class LayerEffectsTests: XCTestCase {
    private func layer(_ effects: LayerEffects? = nil, alpha: CGFloat = 1) throws -> RasterLayer {
        let c = try RasterImage.context(width: 16, height: 12)
        c.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: alpha)); c.fill(CGRect(x: 0, y: 0, width: 16, height: 12))
        return RasterLayer(name: "效果", pngData: try RasterImage.png(XCTUnwrap(c.makeImage())),
                           transform: .init(origin: CGPoint(x: 30, y: 30), size: CGSize(width: 16, height: 12)), effects: effects)
    }
    private func document(_ layers: [RasterLayer]) -> CanvasDocument {
        CanvasDocument(width: 96, height: 96, layers: layers, activeLayerID: layers.first?.id)
    }
    private func bytes(_ image: CGImage) throws -> [UInt8] {
        let c = try RasterImage.context(width: image.width, height: image.height)
        RasterImage.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), context: c)
        return Array(UnsafeBufferPointer(start: try XCTUnwrap(c.data).assumingMemoryBound(to: UInt8.self), count: image.width * image.height * 4))
    }
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) throws -> [UInt8] {
        Array(try bytes(image)[(y * image.width + x) * 4..<(y * image.width + x) * 4 + 4])
    }
    private func gray(_ value: UInt8, width: Int = 16, height: Int = 12) throws -> CGImage {
        let c = try RasterImage.context(width: width, height: height, gray: true)
        let p = try XCTUnwrap(c.data).assumingMemoryBound(to: UInt8.self)
        for y in 0..<height { for x in 0..<width { p[y * c.bytesPerRow + x] = value } }
        return try XCTUnwrap(c.makeImage())
    }
    private func allEffects() -> LayerEffects {
        LayerEffects(stroke: StrokeEffect(size: 2, red: 1), shadow: ShadowEffect(distance: 4, blur: 2),
                     colorOverlay: ColorOverlayEffect(red: 0.2, green: 0.4, blue: 0.8, opacity: 0.3),
                     innerShadow: InnerShadowEffect(distance: 2, blur: 2), outerGlow: OuterGlowEffect(size: 2), innerGlow: InnerGlowEffect(size: 2))
    }
    func testSixEffectsValidateFiniteRangesAndWorkBudgetBeforeAllocating() throws {
        XCTAssertTrue(allEffects().isValid)
        XCTAssertFalse(LayerEffects(stroke: StrokeEffect(size: .infinity)).isValid)
        XCTAssertFalse(LayerEffects(shadow: ShadowEffect(distance: -1)).isValid)
        XCTAssertFalse(LayerEffects(innerGlow: InnerGlowEffect(opacity: 2)).isValid)
        XCTAssertThrowsError(try LayerEffectsRaster.workingBytes(source: CGSize(width: 4096, height: 4096), effects: allEffects()))
        var big = try layer(LayerEffects(shadow: ShadowEffect(distance: 5000)))
        big.isVisible = false; XCTAssertNoThrow(try DocumentRenderer().render(document([big])))
        big.isVisible = true; XCTAssertThrowsError(try DocumentRenderer().render(document([big])))
        let scaled = try allEffects().scaled(by: 2)
        XCTAssertEqual(scaled.stroke?.size, 4); XCTAssertEqual(scaled.shadow?.distance, 8)
        XCTAssertThrowsError(try allEffects().scaled(by: .nan)); XCTAssertThrowsError(try allEffects().scaled(by: 1000))
    }
    func testCanvasGrowthPreservesStructuredLayerCachedRectangleMaskAndEffects() throws {
        let style = LayerShapeStyle(cornerRadius: 4), size = CGSize(width: 16, height: 12)
        var l = try layer(allEffects()); l.shape = style; l.pngData = try RasterImage.png(LayerContentRaster.shapeImage(style, size: size))
        l.maskPNGData = try RasterImage.png(gray(128))
        let editor = try DocumentEditor(document: document([l])), renderer = DocumentRenderer()
        try editor.transaction("扩大画布") { try renderer.resizeCanvas(&$0, width: 120, height: 120, resample: false) }
        XCTAssertEqual(editor.document.layers, [l]); XCTAssertEqual(editor.document.width, 120)
        try editor.undo(); XCTAssertEqual(editor.document.layers, [l]); XCTAssertEqual(editor.document.width, 96)
    }
    func testSoftOwnMaskIsAppliedExactlyOnceBeforeColorOverlay() throws {
        var l = try layer(LayerEffects(colorOverlay: ColorOverlayEffect(red: 1)))
        l.maskPNGData = try RasterImage.png(gray(128))
        let rendered = try DocumentRenderer().render(document([l]))
        let p = try pixel(rendered, 35, 35)
        XCTAssertEqual(p[0], 128, accuracy: 1); XCTAssertEqual(p[3], 128, accuracy: 1)
        XCTAssertEqual(p[2], 0)
        l.maskEnabled = false
        XCTAssertEqual(try pixel(DocumentRenderer().render(document([l])), 35, 35)[3], 255)
    }
    func testOutsideStrokeExtendsGeometryAndMergePreservesAppearance() throws {
        let l = try layer(LayerEffects(stroke: StrokeEffect(size: 3, red: 1)))
        var empty = try layer(alpha: 0); empty.transform.origin = l.transform.origin
        let source = document([l, empty])
        let renderer = DocumentRenderer(), before = try renderer.render(source)
        XCTAssertEqual(try pixel(before, 28, 35), [255, 0, 0, 255])
        let bounds = try LayerEffectsRaster.bounds(of: l)
        XCTAssertEqual(bounds, CGRect(x: 25, y: 25, width: 26, height: 22))
        let plan = try LayerMerge.plan(document: source, selectedIDs: [l.id, empty.id])
        let merged = try LayerMerge.render(plan: plan, document: source, renderer: renderer)
        XCTAssertNil(merged.effects); XCTAssertLessThan(merged.transform.origin.x, l.transform.origin.x)
        var result = source; try LayerMerge.apply(plan: plan, mergedLayer: merged, to: &result)
        XCTAssertEqual(try bytes(renderer.render(result)), try bytes(before))
    }
    func testShadowAngleIsTopLeftDocumentConventionAndTransformsWithFlipRotation() throws {
        var l = try layer(LayerEffects(shadow: ShadowEffect(angle: 90, distance: 8, blur: 0, red: 1, opacity: 1)))
        let renderer = DocumentRenderer()
        XCTAssertEqual(try pixel(renderer.render(document([l])), 35, 47), [255, 0, 0, 255])
        XCTAssertEqual(try pixel(renderer.render(document([l])), 35, 25)[3], 0)
        l.transform.flipY = true
        XCTAssertEqual(try pixel(renderer.render(document([l])), 35, 25), [255, 0, 0, 255])
        l.transform.flipY = false; l.transform.rotation = 90
        let rotated = try renderer.render(document([l]))
        XCTAssertEqual(try pixel(rotated, 24, 35), [255, 0, 0, 255])
    }
    func testClippingStackUsesBaseFinishedAlphaIncludingStrokeAndSoftMask() throws {
        var base = try layer(LayerEffects(stroke: StrokeEffect(size: 3, red: 1)))
        base.maskPNGData = try RasterImage.png(gray(128)); base.opacity = 0.7
        var child = try layer(); child.maskSourceID = base.id; child.transform.origin = CGPoint(x: 20, y: 20); child.transform.size = CGSize(width: 50, height: 50)
        let renderer = DocumentRenderer(), alone = try renderer.render(document([base])), stack = try renderer.render(document([base, child]))
        let a = try bytes(alone), b = try bytes(stack)
        XCTAssertEqual(stride(from: 3, to: a.count, by: 4).map { a[$0] }, stride(from: 3, to: b.count, by: 4).map { b[$0] })
        XCTAssertGreaterThan(try pixel(stack, 28, 35)[2], 0)
        XCTAssertEqual(try pixel(stack, 28, 35)[0], 0)
    }
    func testOverlayInnerShadowAndGlowPreserveOriginalCoverage() throws {
        let source = try layer(alpha: 0.5), original = try RasterImage.decode(XCTUnwrap(source.pngData))
        for effect in [LayerEffects(colorOverlay: ColorOverlayEffect(red: 1)), LayerEffects(innerShadow: InnerShadowEffect(distance: 3, blur: 2)), LayerEffects(innerGlow: InnerGlowEffect(size: 3)), LayerEffects(stroke: StrokeEffect(size: 3, red: 1, inside: true))] {
            let result = try LayerEffectsRaster.render(original, mask: nil, effects: effect)
            XCTAssertEqual(try pixel(result.image, Int(result.inset) + 4, Int(result.inset) + 4)[3], 128, accuracy: 1)
            XCTAssertEqual(try pixel(result.image, 0, 0)[3], 0)
        }
        let glow = try LayerEffectsRaster.render(original, mask: nil, effects: LayerEffects(outerGlow: OuterGlowEffect(size: 4)))
        XCTAssertGreaterThan(try pixel(glow.image, Int(glow.inset) - 1, Int(glow.inset) + 4)[3], 0)
    }
    func testInsideStrokeDoesNotInventOutsideCoverageOnOpaqueSource() throws {
        let l = try layer(LayerEffects(stroke: StrokeEffect(size: 3, red: 1, inside: true)))
        let image = try DocumentRenderer().render(document([l]))
        XCTAssertEqual(try pixel(image, 29, 35)[3], 0); XCTAssertEqual(try pixel(image, 30, 35), [255, 0, 0, 255])
        XCTAssertEqual(try pixel(image, 37, 35), [0, 0, 255, 255])
    }
    func testMorphologyDequeMatchesNaiveSquareKernelIncludingLargeReach() {
        let w = 9, h = 7, source: [UInt8] = (0..<63).map { UInt8(($0 * 53) % 256) }
        for radius in [1, 3, 20] { for smallest in [false, true] {
            let expected: [UInt8] = (0..<w*h).map { i in
                let x = i % w, y = i / w
                var values = [UInt8]()
                for dy in -radius...radius { for dx in -radius...radius {
                    values.append((0..<w).contains(x + dx) && (0..<h).contains(y + dy) ? source[(y+dy)*w+x+dx] : 0)
                } }
                return smallest ? values.min()! : values.max()!
            }
            XCTAssertEqual(LayerEffectsRaster.extreme(source, width: w, height: h, reach: radius, smallest: smallest), expected)
        } }
    }
    func testEffectsMetadataRoundTripDuplicationAndStrictNestedFields() throws {
        let l = try layer(allEffects()), source = document([l]), editor = try DocumentEditor(document: source)
        let id = try editor.duplicateLayer(l.id); XCTAssertEqual(editor.document.layers.first { $0.id == id }?.effects, l.effects)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("comp")
        defer { try? FileManager.default.removeItem(at: url) }
        try DocumentStore.save(source, to: url); XCTAssertEqual(try DocumentStore.load(from: url), source)
        let path = url.appendingPathComponent("manifest.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        var layers = json["layers"] as! [[String: Any]], effects = layers[0]["effects"] as! [String: Any], stroke = effects["stroke"] as! [String: Any]
        stroke["blendMode"] = "Multiply"; effects["stroke"] = stroke; layers[0]["effects"] = effects; json["layers"] = layers
        try JSONSerialization.data(withJSONObject: json).write(to: path)
        XCTAssertThrowsError(try DocumentStore.load(from: url))
    }
    func testAtomicEditNoOpNormalizationDisabledEffectsAndUndoRestore() throws {
        let l = try layer(allEffects()), editor = try DocumentEditor(document: document([l]))
        try editor.updateLayer(l.id) { $0.opacity = 0.5 }; try editor.undo(); XCTAssertTrue(editor.canRedo)
        let plan = try LayerEffectsEdit(document: editor.document)
        var equivalent = plan.original; equivalent.stroke?.enabled = true
        try editor.transaction("无操作") { try plan.apply(equivalent, to: &$0) }; XCTAssertTrue(editor.canRedo); XCTAssertEqual(editor.undoCount, 0)
        var value = equivalent; value.stroke?.enabled = false; value.shadow?.distance = 9
        try editor.transaction("效果") { try plan.apply(value, to: &$0) }
        XCTAssertEqual(editor.undoCount, 1); XCTAssertEqual(editor.document.activeLayer?.pngData, l.pngData)
        XCTAssertEqual(editor.document.activeLayer?.effects?.stroke?.enabled, false)
        try editor.undo(); XCTAssertEqual(editor.document.layers, [l]); try editor.redo()
        XCTAssertThrowsError(try editor.transaction("过期") { try plan.apply(value, to: &$0) })
    }
    func testMaskReplacementInvalidatesEffectCacheAndFormalExportsSharePixels() throws {
        var l = try layer(LayerEffects(colorOverlay: ColorOverlayEffect(red: 1)))
        l.maskPNGData = try RasterImage.png(gray(64))
        let source = document([l]), renderer = DocumentRenderer()
        let before = try renderer.render(source)
        let preview = try renderer.render(source, replacing: l.id, with: RasterImage.decode(XCTUnwrap(l.pngData)), replacementMask: gray(192))
        l.maskPNGData = try RasterImage.png(gray(192))
        XCTAssertEqual(try bytes(preview), try bytes(renderer.render(document([l]))))
        XCTAssertNotEqual(try bytes(before), try bytes(preview))
        XCTAssertEqual(try bytes(renderer.render(source)), try bytes(before))
    }
    func testSelectedPixelTransformRejectsStoredEffectsWithoutChangingFrameOrHistory() throws {
        // Before the guard, translating this entire selection by one pixel
        // regridded rotation 90° / scale 2 to an unrotated 1:1 cache: its red
        // shadow moved from the left to below and shrank from 16 to 8 pixels.
        for enabled: Bool? in [nil, false] {
            var l = try layer(LayerEffects(shadow: ShadowEffect(enabled: enabled, angle: 90, distance: 8, blur: 0, red: 1, opacity: 1)))
            l.transform = .init(origin: CGPoint(x: 30, y: 30), size: CGSize(width: 32, height: 24), rotation: 90)
            var doc = document([l]); doc.selectionMaskPNGData = try RasterImage.png(gray(255, width: 96, height: 96))
            let editor = try DocumentEditor(document: doc), renderer = DocumentRenderer()
            try editor.updateLayer(l.id) { $0.opacity = 0.5 }; try editor.undo()
            let frozen = editor.document, original = try bytes(renderer.render(frozen))
            if enabled == nil { XCTAssertEqual(try pixel(renderer.render(frozen), 25, 40), [255, 0, 0, 255]) }
            XCTAssertThrowsError(try editor.transaction("变换选中像素") { candidate in
                let source = try SelectionTransformSource(document: candidate, layer: candidate.layers[0], renderer: renderer)
                var moved = source.original; moved.origin.x += 1
                _ = try source.preview(moved)
            }) { XCTAssertTrue($0.localizedDescription.contains("取消选区可变换整个图层")) }
            XCTAssertEqual(editor.document, frozen); XCTAssertTrue(editor.canRedo); XCTAssertEqual(editor.undoCount, 0)
            XCTAssertEqual(try bytes(renderer.render(editor.document)), original)
        }
        var unstyled = try layer(LayerEffects()), doc = document([])
        doc.layers = [unstyled]; doc.activeLayerID = unstyled.id
        doc.selectionMaskPNGData = try RasterImage.png(gray(255, width: 96, height: 96))
        XCTAssertNoThrow(try SelectionTransformSource(document: doc, layer: unstyled, renderer: DocumentRenderer()))
        unstyled.effects = nil; doc.layers = [unstyled]
        XCTAssertNoThrow(try SelectionTransformSource(document: doc, layer: unstyled, renderer: DocumentRenderer()))
    }
}
