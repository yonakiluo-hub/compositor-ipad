import XCTest
import CoreGraphics
import ImageIO
@testable import CompositorKit

final class RenderingTests: XCTestCase {
    private let red: [UInt8] = [255, 0, 0, 255]
    private let green: [UInt8] = [0, 255, 0, 255]
    private let blue: [UInt8] = [0, 0, 255, 255]
    private let white: [UInt8] = [255, 255, 255, 255]

    /// Explicit top-to-bottom byte rows keep these fixtures independent of the renderer's coordinate helpers.
    private func rgbaImage(width: Int, height: Int, pixels: [[UInt8]]) throws -> CGImage {
        XCTAssertEqual(pixels.count, width * height)
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels.flatMap { $0 }) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func grayPNG(width: Int = 1, height: Int = 1, values: [UInt8]) throws -> Data {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(values) as CFData))
        let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        return try RasterImage.png(image)
    }

    private func pixels(_ image: CGImage) throws -> [[UInt8]] {
        // A standard bitmap draw normalizes channel order without using RasterImage.draw or its transforms.
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setBlendMode(.copy)
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<(image.width * image.height)).map { offset in (0..<4).map { bytes[offset * 4 + $0] } }
    }

    private func layer(_ image: CGImage, origin: CGPoint = .zero, opacity: Double = 1,
                       blend: LayerBlendMode = .normal, parent: UUID? = nil) throws -> RasterLayer {
        RasterLayer(pngData: try RasterImage.png(image),
            transform: LayerTransform(origin: origin, size: CGSize(width: image.width, height: image.height), sampling: .nearest),
            opacity: opacity, blendMode: blend, parentID: parent)
    }

    private func assertPixel(_ actual: [UInt8], _ expected: [UInt8], tolerance: Int = 1,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (a, e) in zip(actual, expected) {
            XCTAssertLessThanOrEqual(abs(Int(a) - Int(e)), tolerance, "\(actual) != \(expected)", file: file, line: line)
        }
    }

    func testNonSquarePNGExportKeepsTopLeftCoordinatesAndTransparentOutside() throws {
        let source = try rgbaImage(width: 3, height: 2, pixels: [red, green, blue, white, blue, red])
        let foreground = try layer(source, origin: CGPoint(x: 2, y: 1))
        let document = CanvasDocument(width: 7, height: 5, layers: [foreground])
        let rendered = try DocumentRenderer().render(document)
        let reopened = try RasterImage.decode(RasterImage.png(rendered))
        let output = try pixels(reopened)
        assertPixel(output[1 * 7 + 2], red)
        assertPixel(output[1 * 7 + 4], blue)
        assertPixel(output[2 * 7 + 2], white)
        assertPixel(output[2 * 7 + 4], red)
        assertPixel(output[0], [0, 0, 0, 0])
        assertPixel(output[4 * 7 + 6], [0, 0, 0, 0])
    }

    func testClockwiseRotationAndFlipUseDocumentCoordinates() throws {
        let source = try rgbaImage(width: 2, height: 2, pixels: [red, green, blue, white])
        var foreground = try layer(source)
        foreground.transform.rotation = 90
        var document = CanvasDocument(width: 2, height: 2, layers: [foreground])
        let rotated = try pixels(DocumentRenderer().render(document))
        for (actual, expected) in zip(rotated, [blue, red, white, green]) { assertPixel(actual, expected) }
        foreground.transform.rotation = 0
        foreground.transform.flipX = true
        document.layers = [foreground]
        let flipped = try pixels(DocumentRenderer().render(document))
        for (actual, expected) in zip(flipped, [green, red, white, blue]) { assertPixel(actual, expected) }
    }

    func testLayerMaskAndOpacityAreAppliedOnceWithCorrectMaskOrientation() throws {
        let source = try rgbaImage(width: 2, height: 2, pixels: [red, red, red, red])
        var foreground = try layer(source, opacity: 0.5)
        foreground.maskPNGData = try grayPNG(width: 2, height: 2, values: [0, 128, 255, 64])
        let document = CanvasDocument(width: 2, height: 2, layers: [foreground])
        let output = try pixels(DocumentRenderer().render(document))
        assertPixel(output[0], [0, 0, 0, 0])
        assertPixel(output[1], [64, 0, 0, 64])
        assertPixel(output[2], [128, 0, 0, 128])
        assertPixel(output[3], [32, 0, 0, 32])
    }

    func testAlreadyMaskedAIResultPreservesBottomPixelsWithoutReapplyingSelection() throws {
        let background = try layer(rgbaImage(width: 5, height: 4, pixels: Array(repeating: blue, count: 20)))
        let halfRed = try rgbaImage(width: 2, height: 1, pixels: [[128, 0, 0, 128], [0, 0, 0, 0]])
        let selection = try grayPNG(width: 5, height: 4, values: Array(repeating: 128, count: 20))
        let initial = CanvasDocument(width: 5, height: 4, layers: [background], selectionMaskPNGData: selection)
        let editor = try DocumentEditor(document: initial)
        try editor.insertAIResult(pngData: RasterImage.png(halfRed), key: AIResultKey(jobID: "job", resultID: "0"),
            anchor: GenerationAnchor(documentID: initial.id, baseRevision: 0, canvasWidth: 5, canvasHeight: 4,
                                     cropRect: PixelRect(x: 2, y: 1, width: 2, height: 1)))
        let output = try pixels(DocumentRenderer().render(editor.document))
        assertPixel(output[1 * 5 + 2], [128, 0, 127, 255])
        assertPixel(output[1 * 5 + 3], blue)
        assertPixel(output[0], blue)
        try editor.undo()
        assertPixel(try pixels(DocumentRenderer().render(editor.document))[1 * 5 + 2], blue)
        try editor.redo()
        assertPixel(try pixels(DocumentRenderer().render(editor.document))[1 * 5 + 2], [128, 0, 127, 255])
    }

    func testGroupOrderVisibilityAndPassThroughOpacity() throws {
        let whiteImage = try rgbaImage(width: 1, height: 1, pixels: [white])
        let redImage = try rgbaImage(width: 1, height: 1, pixels: [red])
        let greenImage = try rgbaImage(width: 1, height: 1, pixels: [green])
        let bottom = try layer(whiteImage)
        var group = RasterLayer(name: "Group", transform: LayerTransform(size: CGSize(width: 1, height: 1)), opacity: 0.5, isGroup: true)
        let first = try layer(redImage, opacity: 0.5, parent: group.id)
        let second = try layer(greenImage, parent: group.id)
        var document = CanvasDocument(width: 1, height: 1, layers: [bottom, group, first, second])
        assertPixel(try pixels(DocumentRenderer().render(document))[0], [127, 223, 95, 255], tolerance: 2)
        group.isVisible = false
        document.layers = [bottom, group, first, second]
        assertPixel(try pixels(DocumentRenderer().render(document))[0], white)
    }

    func testMultiplyAndScreenCompositeOverExistingBackdrop() throws {
        let bottom = try layer(rgbaImage(width: 1, height: 1, pixels: [[128, 128, 128, 255]]))
        var top = try layer(rgbaImage(width: 1, height: 1, pixels: [[128, 128, 128, 255]]), blend: .multiply)
        var document = CanvasDocument(width: 1, height: 1, layers: [bottom, top])
        assertPixel(try pixels(DocumentRenderer().render(document))[0], [64, 64, 64, 255], tolerance: 2)
        top.blendMode = .screen
        document.layers = [bottom, top]
        assertPixel(try pixels(DocumentRenderer().render(document))[0], [192, 192, 192, 255], tolerance: 2)
    }

    func testRendererCacheInvalidatesChangedPixelsAndMaskWithStableLayerID() throws {
        let renderer = DocumentRenderer()
        var top = try layer(rgbaImage(width: 1, height: 1, pixels: [red]))
        top.maskPNGData = try grayPNG(values: [0])
        var document = CanvasDocument(width: 1, height: 1, layers: [top])
        assertPixel(try pixels(renderer.render(document))[0], [0, 0, 0, 0])
        top.pngData = try RasterImage.png(rgbaImage(width: 1, height: 1, pixels: [blue]))
        top.maskPNGData = try grayPNG(values: [255])
        document.layers = [top]
        assertPixel(try pixels(renderer.render(document))[0], blue)
    }

    func testSelectionMapsIntoRotatedLayerPixelsWithoutBakingItsExistingMask() throws {
        let renderer = DocumentRenderer()
        let source = try rgbaImage(width: 2, height: 2, pixels: [red, green, blue, white])
        var top = try layer(source, origin: CGPoint(x: 1, y: 1))
        top.transform.rotation = 90
        top.maskPNGData = try grayPNG(values: [0])
        let document = CanvasDocument(width: 4, height: 4, layers: [top])
        var coverage = Array(repeating: UInt8(0), count: 16)
        coverage[1 * 4 + 2] = 255
        coverage[2 * 4 + 1] = 128
        let mask = try RasterImage.decode(grayPNG(width: 4, height: 4, values: coverage))
        let local = try XCTUnwrap(renderer.localSelection(mask, layer: top, document: document))
        let data = try XCTUnwrap(local.dataProvider?.data)
        let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
        XCTAssertEqual(local.bitsPerComponent, 8)
        XCTAssertEqual(local.bitsPerPixel, 8)
        XCTAssertEqual(bytes[0], 255)
        XCTAssertEqual(bytes[1], 0)
        XCTAssertEqual(bytes[local.bytesPerRow], 0)
        XCTAssertEqual(bytes[local.bytesPerRow + 1], 128)
        let unmaskedPixels = try pixels(XCTUnwrap(renderer.image(for: top)))
        assertPixel(unmaskedPixels[0], red)
        assertPixel(try pixels(renderer.render(document))[1 * 4 + 2], [0, 0, 0, 0])
    }

    func testExportedGrayMaskAndRGBAImageSatisfyBridgeWireLayout() throws {
        let mask = try RasterImage.png(RasterImage.solidMask(width: 3, height: 2, white: true))
        let image = try RasterImage.png(rgbaImage(width: 3, height: 2, pixels: Array(repeating: red, count: 6)))
        XCTAssertNoThrow(try bridgeValidatePNG(mask, size: BridgePixelSize(width: 3, height: 2), mask: true))
        XCTAssertNoThrow(try bridgeValidatePNG(image, size: BridgePixelSize(width: 3, height: 2), mask: false))
    }

    func testJPEGExportFlattensTransparencyOnWhiteWithoutFlipping() throws {
        let source = try rgbaImage(width: 32, height: 64,
            pixels: Array(repeating: [0, 0, 0, 0], count: 32 * 32) + Array(repeating: blue, count: 32 * 32))
        let decoded = try RasterImage.decode(RasterImage.jpeg(source))
        let output = try pixels(decoded)
        assertPixel(output[16 * 32 + 16], white, tolerance: 4)
        assertPixel(output[48 * 32 + 16], blue, tolerance: 4)
    }

    func testViewportZoomAnchorRoundTripAndDisplayScaleChange() {
        var viewport = CanvasViewport()
        let document = CGSize(width: 1200, height: 700)
        viewport.resize(to: CGSize(width: 800, height: 600), backingScale: 2, documentSize: document)
        let anchor = CGPoint(x: 137, y: 443)
        let pixel = viewport.documentPoint(from: anchor, documentSize: document)
        viewport.setZoom(4.5, anchoredAt: anchor, documentSize: document)
        let anchored = viewport.viewPoint(from: pixel, documentSize: document)
        XCTAssertEqual(anchored.x, anchor.x, accuracy: 0.000001)
        XCTAssertEqual(anchored.y, anchor.y, accuracy: 0.000001)
        let before = viewport.documentPoint(from: viewport.center, documentSize: document)
        viewport.resize(to: CGSize(width: 1000, height: 700), backingScale: 3, documentSize: document)
        let after = viewport.documentPoint(from: viewport.center, documentSize: document)
        XCTAssertEqual(before.x, after.x, accuracy: 0.000001)
        XCTAssertEqual(before.y, after.y, accuracy: 0.000001)
        let unchanged = viewport
        viewport.setZoom(.nan, anchoredAt: anchor, documentSize: document)
        XCTAssertEqual(viewport, unchanged)
    }

    private func grayValues(_ data: Data) throws -> [UInt8] {
        let image = try RasterImage.decode(data)
        XCTAssertEqual(image.bitsPerPixel, 8)
        let raw = try XCTUnwrap(image.dataProvider?.data)
        let bytes = try XCTUnwrap(CFDataGetBytePtr(raw))
        return (0..<image.height).flatMap { y in (0..<image.width).map { bytes[y * image.bytesPerRow + $0] } }
    }

    func testCanvasGrowthPreservesPixelsAndSoftMaskWithOneUndo() throws {
        let renderer = DocumentRenderer()
        let colors = [red, green, blue, white, blue, red]
        var foreground = try layer(rgbaImage(width: 3, height: 2, pixels: colors))
        foreground.maskPNGData = try grayPNG(width: 3, height: 2, values: [0, 128, 255, 64, 255, 0])
        let selection = try grayPNG(width: 3, height: 2, values: [0, 255, 0, 255, 0, 255])
        let original = CanvasDocument(width: 3, height: 2, layers: [foreground], selectionMaskPNGData: selection)
        let editor = try DocumentEditor(document: original)
        let before = try pixels(renderer.render(original))
        try editor.transaction("画布大小") { try renderer.resizeCanvas(&$0, width: 6, height: 4, resample: false) }
        let resized = editor.document
        XCTAssertEqual(editor.undoCount, 1)
        XCTAssertNil(resized.selectionMaskPNGData)
        let expanded = try XCTUnwrap(resized.layers.first)
        let raw = try pixels(XCTUnwrap(renderer.image(for: expanded)))
        let output = try pixels(renderer.render(resized))
        for y in 0..<2 { for x in 0..<3 {
            assertPixel(raw[y * 6 + x], colors[y * 3 + x]) // Including pixels hidden by the mask.
            assertPixel(output[y * 6 + x], before[y * 3 + x])
        } }
        assertPixel(raw[3 * 6 + 5], [0, 0, 0, 0])
        XCTAssertEqual(try grayValues(XCTUnwrap(expanded.maskPNGData)),
                       [0, 128, 255, 255, 255, 255, 64, 255, 0, 255, 255, 255] + Array(repeating: 255, count: 12))
        try editor.undo()
        XCTAssertEqual(editor.document.layers, original.layers)
        XCTAssertEqual(editor.document.size, original.size)
        XCTAssertEqual(editor.document.selectionMaskPNGData, selection)
        try editor.redo()
        XCTAssertEqual(editor.document.layers, resized.layers)
        XCTAssertEqual(editor.document.size, resized.size)
        XCTAssertNil(editor.document.selectionMaskPNGData)
    }

    func testCanvasGrowthKeepsRotatedFlippedPixelLocationsAndDifferentResolutionMask() throws {
        let renderer = DocumentRenderer()
        let colors = [red, green, blue, white, blue, red]
        for rotation in [CGFloat(0), 90, 180, 270] {
            var foreground = try layer(rgbaImage(width: 3, height: 2, pixels: colors), origin: CGPoint(x: 2, y: 1))
            foreground.transform.size = CGSize(width: 6, height: 4)
            foreground.transform.rotation = rotation
            foreground.transform.flipX = true
            foreground.transform.flipY = true
            foreground.maskPNGData = try grayPNG(width: 2, height: 1, values: [0, 128])
            foreground.maskEnabled = false
            foreground.isLocked = true
            var document = CanvasDocument(width: 10, height: 8, layers: [foreground])
            let before = try pixels(renderer.render(document))
            let oldMap = renderer.pixelToDocument(foreground, size: CGSize(width: 3, height: 2))
            try renderer.resizeCanvas(&document, width: 15, height: 11, resample: false)
            let expanded = document.layers[0]
            XCTAssertEqual(expanded.id, foreground.id)
            XCTAssertTrue(expanded.isLocked)
            XCTAssertFalse(expanded.maskEnabled)
            let newSize = try renderer.pixelSize(of: expanded)
            let newMap = renderer.pixelToDocument(expanded, size: newSize)
            let offset = CGPoint.zero.applying(oldMap).applying(newMap.inverted())
            XCTAssertEqual(offset.x, offset.x.rounded(), accuracy: 0.000001)
            XCTAssertEqual(offset.y, offset.y.rounded(), accuracy: 0.000001)
            let imagePixels = try pixels(XCTUnwrap(renderer.image(for: expanded)))
            for y in 0..<2 { for x in 0..<3 {
                let p = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
                let oldPosition = p.applying(oldMap)
                let newPosition = CGPoint(x: p.x + offset.x, y: p.y + offset.y).applying(newMap)
                XCTAssertEqual(oldPosition.x, newPosition.x, accuracy: 0.000001)
                XCTAssertEqual(oldPosition.y, newPosition.y, accuracy: 0.000001)
                assertPixel(imagePixels[(y + Int(offset.y.rounded())) * Int(newSize.width) + x + Int(offset.x.rounded())], colors[y * 3 + x])
            } }
            let output = try pixels(renderer.render(document))
            for y in 0..<8 { for x in 0..<10 { assertPixel(output[y * 15 + x], before[y * 10 + x]) } }
            let maskData = try XCTUnwrap(expanded.maskPNGData)
            let mask = try RasterImage.decode(maskData), values = try grayValues(maskData)
            let maskX = Int((offset.x * 2 / 3).rounded()), maskY = Int((offset.y / 2).rounded())
            for y in 0..<mask.height { for x in 0..<mask.width {
                let expected: UInt8 = y == maskY && x == maskX ? 0 : (y == maskY && x == maskX + 1 ? 128 : 255)
                XCTAssertEqual(values[y * mask.width + x], expected)
            } }
            for corner in [CGPoint.zero, CGPoint(x: 15, y: 0), CGPoint(x: 0, y: 11), CGPoint(x: 15, y: 11)] {
                let local = corner.applying(newMap.inverted())
                XCTAssertGreaterThanOrEqual(local.x, -0.000001); XCTAssertGreaterThanOrEqual(local.y, -0.000001)
                XCTAssertLessThanOrEqual(local.x, newSize.width + 0.000001); XCTAssertLessThanOrEqual(local.y, newSize.height + 0.000001)
            }
        }
    }

    func testCanvasShrinkAndNoOpPreserveOffCanvasPixelsAndRedo() throws {
        let renderer = DocumentRenderer()
        let foreground = try layer(rgbaImage(width: 3, height: 2, pixels: [red, green, blue, white, blue, red]))
        let original = CanvasDocument(width: 3, height: 2, layers: [foreground])
        let editor = try DocumentEditor(document: original)
        try editor.transaction("画布大小") { try renderer.resizeCanvas(&$0, width: 2, height: 1, resample: false) }
        XCTAssertEqual(editor.document.layers, original.layers)
        try editor.undo()
        let undone = editor.document
        try editor.transaction("画布大小") { try renderer.resizeCanvas(&$0, width: 3, height: 2, resample: false) }
        XCTAssertEqual(editor.document, undone)
        XCTAssertTrue(editor.canRedo)
        try editor.redo()
        try editor.transaction("画布大小") { try renderer.resizeCanvas(&$0, width: 3, height: 2, resample: false) }
        XCTAssertEqual(editor.document.layers, original.layers)
        assertPixel(try pixels(renderer.render(editor.document))[5], red)
    }

    func testCanvasGrowthAllocationLimitFailsAtomically() throws {
        let renderer = DocumentRenderer()
        let blank = RasterLayer(transform: LayerTransform(size: CGSize(width: 2, height: 2)))
        var small = try layer(rgbaImage(width: 2, height: 2, pixels: [red, green, blue, white]))
        small.transform.size = CGSize(width: 1, height: 1)
        let editor = try DocumentEditor(document: CanvasDocument(width: 2, height: 2, layers: [blank, small]))
        try editor.setOpacity(layerID: small.id, opacity: 0.5)
        try editor.undo()
        let original = editor.document
        XCTAssertThrowsError(try editor.transaction("画布大小") { try renderer.resizeCanvas(&$0, width: 4096, height: 2, resample: false) })
        XCTAssertEqual(editor.document, original)
        XCTAssertFalse(editor.canUndo)
        XCTAssertTrue(editor.canRedo)
    }

    func testCanvasGrowthPadsBlankChildButImageResizeKeepsPixelAssets() throws {
        let renderer = DocumentRenderer()
        let group = RasterLayer(transform: LayerTransform(size: CGSize(width: 3, height: 2)), isGroup: true)
        let blank = RasterLayer(transform: LayerTransform(size: CGSize(width: 3, height: 2)), parentID: group.id)
        var document = CanvasDocument(width: 3, height: 2, layers: [group, blank])
        try renderer.resizeCanvas(&document, width: 6, height: 4, resample: false)
        XCTAssertEqual(document.layers[0], group)
        XCTAssertEqual(document.layers[1].parentID, group.id)
        XCTAssertEqual(try renderer.pixelSize(of: document.layers[1]), CGSize(width: 6, height: 4))
        XCTAssertTrue(try pixels(renderer.render(document)).allSatisfy { $0 == [0, 0, 0, 0] })
        let before = document.layers[1]
        try renderer.resizeCanvas(&document, width: 12, height: 8, resample: true)
        XCTAssertEqual(document.layers[1].pngData, before.pngData)
        XCTAssertEqual(document.layers[1].transform.size, CGSize(width: 12, height: 8))
    }

    func testCanvasGrowthRejectsSamplingChangesWithoutRevealingHiddenPixels() throws {
        let renderer = DocumentRenderer()
        for maskValue in [nil, UInt8(0), UInt8(128)] {
            for sampling in [LayerSampling.smooth, .high] {
                var foreground = try layer(rgbaImage(width: 1, height: 1, pixels: [red]))
                foreground.transform.size = CGSize(width: 4, height: 4)
                foreground.transform.sampling = sampling
                foreground.maskPNGData = try maskValue.map { try grayPNG(values: [$0]) }
                let editor = try DocumentEditor(document: CanvasDocument(width: 4, height: 4, layers: [foreground]))
                let original = editor.document, before = try pixels(renderer.render(original))
                XCTAssertThrowsError(try editor.transaction("画布大小") { try renderer.resizeCanvas(&$0, width: 8, height: 8, resample: false) })
                XCTAssertEqual(editor.document, original)
                XCTAssertEqual(try pixels(renderer.render(editor.document)), before)
                XCTAssertFalse(editor.canUndo)
            }
        }
        // Even nearest sampling has an antialiased outer boundary at non-right angles.
        var rotated = try layer(rgbaImage(width: 3, height: 2, pixels: [red, green, blue, white, blue, red]))
        rotated.transform.rotation = 37
        let editor = try DocumentEditor(document: CanvasDocument(width: 4, height: 4, layers: [rotated]))
        let original = editor.document
        XCTAssertThrowsError(try editor.transaction("画布大小") { try renderer.resizeCanvas(&$0, width: 8, height: 8, resample: false) })
        XCTAssertEqual(editor.document, original)
    }
}
