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
}
