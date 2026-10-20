import XCTest
import UIKit
@testable import CompositorPad

final class PadBrushStrokeTests: XCTestCase {
    private func sample(_ x: CGFloat = 16, _ y: CGFloat = 16, pressure: CGFloat = 1,
                        altitude: CGFloat = .pi / 2) -> BrushSample {
        BrushSample(point: CGPoint(x: x, y: y), pressure: pressure, altitude: altitude, azimuth: 0)
    }
    private func settings(opacity: CGFloat = 1, erasing: Bool = false) -> PadBrushSettings {
        PadBrushSettings(diameter: 20, hardness: 1, opacity: opacity, color: .red, erasing: erasing)
    }
    private func pixel(_ image: CGImage, x: Int = 16, y: Int = 16) throws -> [UInt8] {
        let data = try XCTUnwrap(image.dataProvider?.data)
        let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
        let offset = y * image.bytesPerRow + x * image.bitsPerPixel / 8
        return (0..<(image.bitsPerPixel / 8)).map { bytes[offset + $0] }
    }
    private func solid(alpha: CGFloat) throws -> CGImage {
        let context = try RasterImage.context(width: 32, height: 32)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: alpha))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        return try XCTUnwrap(context.makeImage())
    }
    private func gray(_ value: CGFloat) throws -> CGImage {
        let context = try RasterImage.context(width: 32, height: 32, gray: true)
        context.setFillColor(gray: value, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        return try XCTUnwrap(context.makeImage())
    }

    func testRepeatedDabsCapOpacityAndRepeatedPreviewsDoNotAccumulate() throws {
        let stroke = try PadBrushStroke(width: 32, height: 32, original: nil, settings: settings(opacity: 0.5), selection: nil, maskMode: false)
        for _ in 0..<20 { stroke.add(sample()) }
        let first = try stroke.image(), second = try stroke.image()
        XCTAssertEqual(try pixel(first)[3], 128, accuracy: 1)
        XCTAssertEqual(try pixel(first), try pixel(second))
        XCTAssertEqual(try pixel(first, x: 0, y: 0)[3], 0)
    }

    func testEraserAndSoftSelectionEachApplyOnce() throws {
        let erase = try PadBrushStroke(width: 32, height: 32, original: solid(alpha: 1), settings: settings(opacity: 0.5, erasing: true), selection: nil, maskMode: false)
        erase.add(sample())
        XCTAssertEqual(try pixel(erase.image())[3], 128, accuracy: 1)
        let paint = try PadBrushStroke(width: 32, height: 32, original: nil, settings: settings(opacity: 0.5), selection: gray(0.5), maskMode: false)
        paint.add(sample())
        XCTAssertEqual(try pixel(paint.image())[3], 64, accuracy: 1)
    }

    func testMaskPaintingUsesNumericGrayscaleWithoutAlpha() throws {
        let stroke = try PadBrushStroke(width: 32, height: 32, original: gray(0), settings: settings(opacity: 0.5), selection: nil, maskMode: true)
        stroke.add(sample())
        let mask = try stroke.image()
        XCTAssertEqual(mask.bitsPerPixel, 8)
        XCTAssertEqual(mask.alphaInfo, .none)
        XCTAssertEqual(try pixel(mask)[0], 128, accuracy: 1)
        XCTAssertNoThrow(try bridgeValidatePNG(RasterImage.png(mask), size: BridgePixelSize(width: 32, height: 32), mask: true))
    }

    func testSavedSelectionCropUploadsAsProfileFreeNumericMask() throws {
        let context = try RasterImage.context(width: 32, height: 24, gray: true)
        for (x, width, value) in [(0, 10, 0.0), (10, 10, 128.0 / 255), (20, 12, 1.0)] {
            context.setFillColor(gray: value, alpha: 1)
            context.fill(CGRect(x: x, y: 0, width: width, height: 24))
        }
        let saved = try RasterImage.png(XCTUnwrap(context.makeImage()))
        let decoded = try RasterImage.decode(saved)
        let crop = try XCTUnwrap(decoded.cropping(to: CGRect(x: 8, y: 5, width: 16, height: 12)))
        let upload = try RasterImage.png(crop)
        try bridgeValidatePNG(upload, size: .init(width: 16, height: 12), mask: true)
        let reopened = try RasterImage.decode(upload)
        XCTAssertEqual(reopened.bitsPerPixel, 8)
        XCTAssertEqual(reopened.alphaInfo, .none)
        XCTAssertEqual(try pixel(reopened, x: 0, y: 0)[0], 0)
        XCTAssertEqual(try pixel(reopened, x: 4, y: 0)[0], 128)
        XCTAssertEqual(try pixel(reopened, x: 14, y: 0)[0], 255)
    }

    func testPressureChangesCoverageAndTiltBroadensTip() throws {
        let light = try PadBrushStroke(width: 32, height: 32, original: nil, settings: settings(), selection: nil, maskMode: false)
        let heavy = try PadBrushStroke(width: 32, height: 32, original: nil, settings: settings(), selection: nil, maskMode: false)
        light.add(sample(pressure: 0.1)); heavy.add(sample())
        XCTAssertEqual(try pixel(light.image(), x: 23, y: 16)[3], 0)
        XCTAssertGreaterThan(try pixel(heavy.image(), x: 23, y: 16)[3], 200)
        let tilted = try PadBrushStroke(width: 32, height: 32, original: nil, settings: settings(), selection: nil, maskMode: false)
        tilted.add(sample(altitude: 0.1))
        XCTAssertEqual(try pixel(heavy.image(), x: 16, y: 29)[3], 0)
        XCTAssertGreaterThan(try pixel(tilted.image(), x: 16, y: 29)[3], 200)
    }

    func testTransformedLayerKeepsBrushFootprintInDocumentCoordinates() throws {
        let scaled = try PadBrushStroke(width: 64, height: 64, original: nil, settings: settings(), selection: nil,
            maskMode: false, brushToPixels: CGAffineTransform(scaleX: 2, y: 0.5))
        scaled.add(sample(32, 32))
        XCTAssertGreaterThan(try pixel(scaled.image(), x: 48, y: 32)[3], 200)
        XCTAssertEqual(try pixel(scaled.image(), x: 32, y: 40)[3], 0)
        let rotated = try PadBrushStroke(width: 64, height: 64, original: nil, settings: settings(), selection: nil,
            maskMode: false, brushToPixels: CGAffineTransform(rotationAngle: -.pi / 2))
        rotated.add(sample(32, 32, altitude: 0.1))
        XCTAssertGreaterThan(try pixel(rotated.image(), x: 45, y: 32)[3], 200)
        XCTAssertEqual(try pixel(rotated.image(), x: 32, y: 45)[3], 0)
    }

    func testExpandedCanvasAcceptsBrushInNewAreaAndUndoesResizeSeparately() throws {
        let renderer = DocumentRenderer()
        let originalRect = CGRect(x: 0, y: 0, width: 1200, height: 900)
        func originalPixels(_ image: CGImage) throws -> Data {
            let crop = try XCTUnwrap(image.cropping(to: originalRect))
            let context = try RasterImage.context(width: 1200, height: 900)
            RasterImage.draw(crop, in: originalRect, context: context)
            return Data(bytes: try XCTUnwrap(context.data), count: context.bytesPerRow * context.height)
        }

        let initialStroke = try PadBrushStroke(width: 1200, height: 900, original: nil,
            settings: settings(), selection: nil, maskMode: false)
        initialStroke.add(sample(300, 450)); initialStroke.add(sample(600, 450))
        let maskContext = try RasterImage.context(width: 1200, height: 900, gray: true)
        maskContext.setFillColor(gray: 1, alpha: 1); maskContext.fill(originalRect)
        maskContext.setFillColor(gray: 0, alpha: 1)
        maskContext.fill(CGRect(x: 580, y: 430, width: 40, height: 40))
        let layer = RasterLayer(name: "已有笔迹", pngData: try RasterImage.png(initialStroke.image()),
            transform: .init(size: originalRect.size),
            maskPNGData: try RasterImage.png(XCTUnwrap(maskContext.makeImage())))
        let original = CanvasDocument(width: 1200, height: 900, layers: [layer], activeLayerID: layer.id)
        let originalRenderedPixels = try originalPixels(renderer.render(original))
        let originalLayerPixels = try originalPixels(XCTUnwrap(renderer.image(for: layer)))
        let editor = try DocumentEditor(document: original)

        try editor.transaction("画布大小") { document in
            try renderer.resizeCanvas(&document, width: 1800, height: 900, resample: false)
        }
        renderer.clearCache()
        let resized = editor.document
        let expandedLayer = try XCTUnwrap(resized.layers.first)
        let expandedMask = try RasterImage.decode(XCTUnwrap(expandedLayer.maskPNGData))
        XCTAssertEqual(resized.size, CGSize(width: 1800, height: 900))
        XCTAssertEqual(expandedMask.width, 1800)
        XCTAssertEqual(try pixel(expandedMask, x: 600, y: 450), [0])
        XCTAssertEqual(try pixel(expandedMask, x: 1500, y: 450), [255])
        XCTAssertEqual(try originalPixels(XCTUnwrap(renderer.image(for: expandedLayer))), originalLayerPixels,
                       "Canvas growth must preserve even pixels hidden by the layer mask")
        XCTAssertEqual(try originalPixels(renderer.render(resized)), originalRenderedPixels)
        XCTAssertEqual(try pixel(renderer.render(resized), x: 1500, y: 450)[3], 0)
        XCTAssertEqual(editor.undoCount, 1)

        // Match CanvasView: both the stroke buffer and touch conversion use the layer's
        // current pixel size and transform, rather than the document size directly.
        let size = try renderer.pixelSize(of: expandedLayer)
        let documentToPixels = renderer.pixelToDocument(expandedLayer, size: size).inverted()
        let stroke = try PadBrushStroke(width: Int(size.width), height: Int(size.height),
            original: renderer.image(for: expandedLayer), settings: settings(),
            selection: renderer.localSelection(nil, layer: expandedLayer, document: resized),
            maskMode: false, brushToPixels: documentToPixels)
        let point = CGPoint(x: 1500, y: 450).applying(documentToPixels)
        stroke.add(sample(point.x, point.y))
        let paintedPNG = try RasterImage.png(stroke.image())
        try editor.transaction("绘画") { document in
            let index = try XCTUnwrap(document.layers.firstIndex { $0.id == layer.id })
            document.layers[index].pngData = paintedPNG
        }
        let painted = editor.document
        let result = try renderer.render(painted)
        XCTAssertEqual(try pixel(result, x: 1500, y: 450), [255, 0, 0, 255])
        XCTAssertEqual(try pixel(result, x: 600, y: 450)[3], 0)
        XCTAssertEqual(try originalPixels(result), originalRenderedPixels)
        XCTAssertEqual(try originalPixels(XCTUnwrap(renderer.image(for: painted.layers[0]))), originalLayerPixels)
        XCTAssertEqual(painted.layers[0].maskPNGData, expandedLayer.maskPNGData)
        XCTAssertEqual(editor.undoCount, 2)

        try editor.undo()
        XCTAssertEqual(editor.document.size, resized.size)
        XCTAssertEqual(editor.document.layers, resized.layers)
        XCTAssertEqual(try pixel(renderer.render(editor.document), x: 1500, y: 450)[3], 0)
        try editor.undo()
        XCTAssertEqual(editor.document.size, original.size)
        XCTAssertEqual(editor.document.layers, original.layers)
        XCTAssertEqual(try originalPixels(renderer.render(editor.document)), originalRenderedPixels)
        try editor.redo()
        XCTAssertEqual(editor.document.size, resized.size)
        XCTAssertEqual(editor.document.layers, resized.layers)
        XCTAssertEqual(try pixel(renderer.render(editor.document), x: 1500, y: 450)[3], 0)
        try editor.redo()
        XCTAssertEqual(editor.document.size, painted.size)
        XCTAssertEqual(editor.document.layers, painted.layers)
        XCTAssertEqual(editor.document.activeLayerID, layer.id)
        XCTAssertEqual(try pixel(renderer.render(editor.document), x: 1500, y: 450), [255, 0, 0, 255])
        XCTAssertEqual(try originalPixels(renderer.render(editor.document)), originalRenderedPixels)
    }
}
