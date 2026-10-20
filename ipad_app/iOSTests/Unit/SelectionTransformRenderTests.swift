import XCTest
import CoreGraphics
@testable import CompositorPad

final class SelectionTransformRenderTests: XCTestCase {
    private func image(width: Int, height: Int, pixel: (Int, Int) -> [UInt8]) throws -> CGImage {
        let bytes = (0..<height).flatMap { y in (0..<width).flatMap { x in pixel(x, y) } }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func mask(width: Int, height: Int, coverage: (Int, Int) -> UInt8) throws -> CGImage {
        let bytes = (0..<height).flatMap { y in (0..<width).map { x in coverage(x, y) } }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(bytes) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func bytes(_ image: CGImage) throws -> Data {
        try XCTUnwrap(image.dataProvider?.data) as Data
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> [UInt8] {
        XCTAssertEqual(image.bitsPerPixel, 32)
        let bytes = try bytes(image), index = y * image.bytesPerRow + x * 4
        return Array(bytes[index..<index + 4])
    }

    private func fixture() throws -> (CanvasDocument, CGImage, CGImage) {
        let source = try image(width: 8, height: 4) { _, _ in [128, 0, 0, 128] }
        let values: [[UInt8]] = [[0, 64, 128, 255], [255, 128, 64, 0]]
        let originalMask = try mask(width: 4, height: 2) { x, y in values[y][x] }
        let layer = RasterLayer(name: "带软蒙版的合成图层", pngData: try RasterImage.png(source),
            transform: LayerTransform(origin: CGPoint(x: 2, y: 3), size: CGSize(width: 8, height: 4), sampling: .nearest),
            maskPNGData: try RasterImage.png(originalMask))
        let other = RasterLayer(name: "其他图层",
            pngData: try RasterImage.png(image(width: 4, height: 3) { _, _ in [0, 0, 255, 255] }),
            transform: LayerTransform(origin: CGPoint(x: 16, y: 2), size: CGSize(width: 4, height: 3), sampling: .nearest),
            maskPNGData: try RasterImage.png(mask(width: 4, height: 3) { _, _ in 64 }))
        return (CanvasDocument(name: "合成预览蒙版测试", width: 24, height: 18, layers: [layer, other],
                               activeLayerID: layer.id), source, originalMask)
    }

    func testPaddedPreviewMaskMatchesCommittedPixelsWithoutStretchingOrCachingIt() throws {
        let (document, _, originalMask) = try fixture()
        let renderer = DocumentRenderer()
        let original = try renderer.render(document)
        let sourceMaskBytes = try bytes(originalMask)
        let expanded = try image(width: 12, height: 8) { x, y in
            if x >= 2, x < 10, y >= 2, y < 6 { return [128, 0, 0, 128] }
            if x >= 10, y >= 2, y < 6 { return [0, 0, 192, 192] }
            return [0, 0, 0, 0]
        }
        // The mask has half the raster resolution. Two pixels of raster
        // padding therefore add one mask sample, preserving its original grid.
        let expandedMask = try mask(width: 6, height: 4) { x, y in
            if x >= 1, x < 5, y >= 1, y < 3 {
                return sourceMaskBytes[(y - 1) * originalMask.bytesPerRow + x - 1]
            }
            return 255
        }
        var previewDocument = document
        previewDocument.layers[0].transform.origin = CGPoint(x: 0, y: 1)
        previewDocument.layers[0].transform.size = CGSize(width: 12, height: 8)
        let preview = try renderer.render(previewDocument, replacing: document.layers[0].id,
                                          with: expanded, replacementMask: expandedMask)
        var committed = previewDocument
        committed.layers[0].pngData = try RasterImage.png(expanded)
        committed.layers[0].maskPNGData = try RasterImage.png(expandedMask)
        XCTAssertEqual(try bytes(preview), try bytes(renderer.render(committed)))
        XCTAssertEqual(try pixel(preview, x: 10, y: 4), [0, 0, 192, 192], "White padding reveals moved pixels")
        for y in 3..<7 {
            for x in 2..<10 {
                XCTAssertEqual(try pixel(preview, x: x, y: y), try pixel(original, x: x, y: y),
                               "Existing mask samples must remain at the same document coordinates")
            }
        }
        XCTAssertEqual(try pixel(preview, x: 17, y: 3), try pixel(original, x: 17, y: 3),
                       "A replacement mask must not affect a different layer")
        let stretched = try renderer.render(previewDocument, replacing: document.layers[0].id, with: expanded)
        XCTAssertNotEqual(try bytes(preview), try bytes(stretched), "The legacy mask would stretch to the padded geometry")
        XCTAssertEqual(try bytes(renderer.render(document)), try bytes(original),
                       "A temporary mask must not replace the original layer's decoded cache")
    }

    func testExplicitNilRemovesMaskWhileOmittedArgumentKeepsOriginalMask() throws {
        let (document, source, _) = try fixture()
        let renderer = DocumentRenderer()
        let original = try bytes(renderer.render(document))
        let legacy = try renderer.render(document, replacing: document.layers[0].id, with: source)
        XCTAssertEqual(try bytes(legacy), original)
        let noMaskPreview = try renderer.render(document, replacing: document.layers[0].id, with: source, replacementMask: nil)
        var committed = document
        committed.layers[0].maskPNGData = nil
        XCTAssertEqual(try bytes(noMaskPreview), try bytes(renderer.render(committed)))
        XCTAssertNotEqual(try bytes(noMaskPreview), original)
        XCTAssertEqual(try bytes(renderer.render(document)), original)
        XCTAssertEqual(try pixel(noMaskPreview, x: 17, y: 3), try pixel(legacy, x: 17, y: 3))
    }

    func testDisabledMaskRemainsDisabledForReplacementAndAfterCommit() throws {
        let fixture = try fixture()
        var document = fixture.0
        let source = fixture.1
        let renderer = DocumentRenderer()
        document.layers[0].maskEnabled = false
        let black = try mask(width: 8, height: 4) { _, _ in 0 }
        let preview = try renderer.render(document, replacing: document.layers[0].id, with: source, replacementMask: black)
        var committed = document
        committed.layers[0].maskPNGData = try RasterImage.png(black)
        XCTAssertEqual(try bytes(preview), try bytes(renderer.render(committed)))
        XCTAssertEqual(try pixel(preview, x: 3, y: 4), [128, 0, 0, 128])
        committed.layers[0].maskEnabled = true
        XCTAssertEqual(try pixel(renderer.render(committed), x: 3, y: 4), [0, 0, 0, 0])
        XCTAssertNotEqual(try bytes(preview), try bytes(renderer.render(committed)))
    }

    func testSelectionTransformResultWithMaskPaddingRendersExactlyAsItsCommittedDocument() throws {
        for maskEnabled in [true, false] {
            var document = try fixture().0
            document.layers[0].maskEnabled = maskEnabled
            document.selectionMaskPNGData = try RasterImage.png(mask(width: document.width, height: document.height) { x, y in
                x >= 2 && x < 4 && y >= 3 && y < 7 ? 255 : 0
            })
            let before = document
            let renderer = DocumentRenderer()
            let source = try SelectionTransformSource(document: document, layer: document.layers[0], renderer: renderer)
            var moved = source.original
            moved.origin.x -= 2
            let result = try source.preview(moved)
            XCTAssertEqual(result.image.width, 10)
            XCTAssertEqual(result.image.height, 4)
            XCTAssertEqual(result.mask?.width, 5)
            XCTAssertEqual(result.mask?.height, 2)
            XCTAssertEqual(result.transform.origin, CGPoint(x: 0, y: 3))
            var previewDocument = document
            previewDocument.layers[0].transform = result.transform
            let preview = try renderer.render(previewDocument, replacing: document.layers[0].id,
                                              with: result.image, replacementMask: result.mask)
            var committed = previewDocument
            committed.layers[0].pngData = try RasterImage.png(result.image)
            committed.layers[0].maskPNGData = try result.mask.map(RasterImage.png)
            committed.selectionMaskPNGData = try RasterImage.png(result.selection)
            XCTAssertEqual(try bytes(preview), try bytes(renderer.render(committed)))
            XCTAssertEqual(try pixel(preview, x: 0, y: 4), [128, 0, 0, 128],
                           "The moved pixel is in new white mask padding")
            XCTAssertEqual(try pixel(preview, x: 2, y: 4), [0, 0, 0, 0],
                           "The selected source pixel was cut exactly once")
            XCTAssertEqual(committed.layers[0].maskEnabled, maskEnabled)
            XCTAssertEqual(committed.layers[1], before.layers[1])
            XCTAssertEqual(document, before, "Preparing and rendering a preview must not mutate its source")
        }
    }
}
