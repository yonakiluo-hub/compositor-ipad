import XCTest
import CoreGraphics
@testable import CompositorKit

final class EditableFileIntegrationTests: XCTestCase {
    func bounds(_ image: CGImage) throws -> CGRect {
        let c = try RasterImage.context(width: image.width, height: image.height)
        c.setBlendMode(.copy)
        RasterImage.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), context: c)
        let p = try XCTUnwrap(c.data).assumingMemoryBound(to: UInt8.self)
        var minX = image.width, minY = image.height, maxX = -1, maxY = -1
        for y in 0..<image.height { for x in 0..<image.width {
            if p[y * c.bytesPerRow + x * 4 + 3] > 0 {
                minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
            }
        } }
        return CGRect(x: minX, y: minY, width: maxX-minX+1, height: maxY-minY+1)
    }
    func testResampleEffectSizeUnits() throws {
        let c = try RasterImage.context(width: 4, height: 4)
        c.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1)); c.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        var effects = LayerEffects(); effects.stroke = StrokeEffect(size: 2)
        let layer = RasterLayer(name: "pixel", pngData: try RasterImage.png(XCTUnwrap(c.makeImage())),
            transform: LayerTransform(origin: CGPoint(x: 12, y: 12), size: CGSize(width: 4, height: 4), sampling: .nearest), effects: effects)
        var source = CanvasDocument(width: 32, height: 32, layers: [layer])
        let before = try bounds(DocumentRenderer().render(source))
        try DocumentRenderer().resizeCanvas(&source, width: 64, height: 64, resample: true)
        let transformOnly = try bounds(DocumentRenderer().render(source))
        XCTAssertEqual(transformOnly, CGRect(x: 20, y: 20, width: 16, height: 16))
        XCTAssertEqual(before, CGRect(x: 10, y: 10, width: 8, height: 8))
        XCTAssertEqual(source.layers[0].effects, effects)
        XCTAssertEqual(source.layers[0].pngData, layer.pngData)
    }
    private func fixture() throws -> CanvasDocument {
        let context = try RasterImage.context(width: 16, height: 12)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 16, height: 12))
        let layer = RasterLayer(name: "可编辑内容", pngData: try RasterImage.png(XCTUnwrap(context.makeImage())),
            transform: LayerTransform(origin: CGPoint(x: 8, y: 6), size: CGSize(width: 16, height: 12)))
        return CanvasDocument(width: 64, height: 48, layers: [layer], activeLayerID: layer.id,
            guides: [CanvasGuide(axis: .vertical, position: 12), CanvasGuide(axis: .horizontal, position: 10)])
    }
    func testPSDRejectsEachEditablePayloadBeforeExportAndPreservesNativeProject() throws {
        let base = try fixture()
        for kind in 0..<4 {
            var document = base
            switch kind {
            case 0: document.layers[0].text = LayerTextStyle(content: "中文", fontName: "Helvetica", fontSize: 12)
            case 1: document.layers[0].shape = LayerShapeStyle(kind: .rectangle)
            case 2: document.layers[0].effects = LayerEffects(stroke: StrokeEffect(enabled: false))
            default: document.layers[0].effects = LayerEffects()
            }
            try document.validate()
            let before = document
            XCTAssertThrowsError(try PSDCodec.write(document))
            XCTAssertEqual(document, before)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".comp")
            defer { try? FileManager.default.removeItem(at: url) }
            try DocumentStore.save(document, to: url)
            XCTAssertEqual(try DocumentStore.load(from: url), before)
        }
    }
    func testCropKeepsEditableMetadataAndCachedPixelsWhileTranslatingGuides() throws {
        var document = try fixture()
        document.layers[0].shape = LayerShapeStyle(kind: .rectangle)
        document.layers[0].effects = LayerEffects(shadow: ShadowEffect(distance: 4, blur: 1))
        let text = RasterLayer(name: "文字", pngData: document.layers[0].pngData, transform: document.layers[0].transform,
            text: LayerTextStyle(content: "标题", fontName: "Helvetica", fontSize: 12), effects: document.layers[0].effects)
        document.layers.append(text)
        let result = try CanvasCropPlan(document: document).preview(PixelRect(x: 3, y: 2, width: 40, height: 32))
        for (original, cropped) in zip(document.layers, result.layers) {
            XCTAssertEqual(cropped.pngData, original.pngData); XCTAssertEqual(cropped.maskPNGData, original.maskPNGData)
            XCTAssertEqual(cropped.text, original.text); XCTAssertEqual(cropped.shape, original.shape)
            XCTAssertEqual(cropped.effects, original.effects); XCTAssertEqual(cropped.id, original.id)
            XCTAssertEqual(cropped.transform.origin, CGPoint(x: original.transform.origin.x - 3, y: original.transform.origin.y - 2))
        }
        XCTAssertEqual(result.guides.map(\.position), [9, 8])
    }
    func testImageResizeRequiresExplicitRasterizationButCanvasResizePreservesContent() throws {
        for isText in [false, true] {
            var document = try fixture()
            if isText { document.layers[0].text = LayerTextStyle(content: "标题", fontName: "Helvetica", fontSize: 12) }
            else { document.layers[0].shape = LayerShapeStyle(kind: .rectangle) }
            let original = document
            XCTAssertThrowsError(try DocumentRenderer().resizeCanvas(&document, width: 128, height: 96, resample: true))
            XCTAssertEqual(document, original)
            try DocumentRenderer().resizeCanvas(&document, width: 128, height: 96, resample: false)
            XCTAssertEqual(document.layers, original.layers)
            XCTAssertEqual(document.guides, original.guides)
            document.layers[0].rasterizeContent()
            let pixels = document.layers[0].pngData
            try DocumentRenderer().resizeCanvas(&document, width: 256, height: 192, resample: true)
            XCTAssertEqual(document.layers[0].pngData, pixels)
            XCTAssertEqual(document.guides.map(\.position), [24, 20])
        }
    }

}
