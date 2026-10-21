import XCTest
import CoreGraphics
@testable import CompositorKit

final class SelectionTransformTests: XCTestCase {
    private let red: [UInt8] = [255, 0, 0, 255]
    private let blue: [UInt8] = [0, 0, 255, 255]
    private let green: [UInt8] = [0, 255, 0, 255]

    private func image(_ pixels: [[UInt8]], width: Int, height: Int) throws -> CGImage {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels.flatMap { $0 }) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func gray(_ pixels: [UInt8], width: Int, height: Int) throws -> CGImage {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func pixels(_ image: CGImage) throws -> [[UInt8]] {
        let context = try RasterImage.context(width: image.width, height: image.height)
        context.setBlendMode(.copy); context.interpolationQuality = .none
        RasterImage.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), context: context)
        let bytes = try XCTUnwrap(context.data?.assumingMemoryBound(to: UInt8.self))
        return (0..<image.height).flatMap { y in (0..<image.width).map { x in
            Array(UnsafeBufferPointer(start: bytes + y * context.bytesPerRow + x * 4, count: 4))
        } }
    }

    private func values(_ image: CGImage) throws -> [UInt8] {
        XCTAssertEqual(image.bitsPerComponent, 8); XCTAssertEqual(image.bitsPerPixel, 8); XCTAssertEqual(image.alphaInfo, .none)
        let data = try XCTUnwrap(image.dataProvider?.data), bytes = try XCTUnwrap(CFDataGetBytePtr(data))
        return (0..<image.height).flatMap { row in Array(UnsafeBufferPointer(start: bytes + row * image.bytesPerRow, count: image.width)) }
    }

    private func document(width: Int, height: Int, pixels: [[UInt8]], selection: [UInt8],
                          sampling: LayerSampling = .nearest) throws -> CanvasDocument {
        let layer = RasterLayer(name: "选择像素", pngData: try RasterImage.png(image(pixels, width: width, height: height)),
                                transform: LayerTransform(size: CGSize(width: width, height: height), sampling: sampling))
        return CanvasDocument(width: width, height: height, layers: [layer], activeLayerID: layer.id,
                              selectionMaskPNGData: try RasterImage.png(gray(selection, width: width, height: height)))
    }

    private func moved(_ transform: LayerTransform, x: CGFloat, y: CGFloat = 0) -> LayerTransform {
        var result = transform; result.origin.x += x; result.origin.y += y; return result
    }

    private func assertPixel(_ actual: [UInt8], _ expected: [UInt8], tolerance: Int = 0,
                              file: StaticString = #filePath, line: UInt = #line) {
        for channel in 0..<4 { XCTAssertLessThanOrEqual(abs(Int(actual[channel]) - Int(expected[channel])), tolerance, file: file, line: line) }
    }

    func testPreparationUsesNonzeroDocumentBoundsAndRejectsEmptyInput() throws {
        var selection = [UInt8](repeating: 0, count: 35)
        selection[1 * 7 + 2] = 1; selection[3 * 7 + 4] = 128
        var doc = try document(width: 7, height: 5, pixels: Array(repeating: red, count: 35), selection: selection)
        let source = try SelectionTransformSource(document: doc, layer: doc.layers[0], renderer: DocumentRenderer())
        XCTAssertEqual(source.original.origin, CGPoint(x: 2, y: 1))
        XCTAssertEqual(source.original.size, CGSize(width: 3, height: 3))
        doc.selectionMaskPNGData = nil
        XCTAssertThrowsError(try SelectionTransformSource(document: doc, layer: doc.layers[0], renderer: DocumentRenderer()))
        doc.selectionMaskPNGData = try RasterImage.png(gray(Array(repeating: 0, count: 35), width: 7, height: 5))
        XCTAssertThrowsError(try SelectionTransformSource(document: doc, layer: doc.layers[0], renderer: DocumentRenderer()))
        doc.selectionMaskPNGData = try RasterImage.png(gray(selection, width: 7, height: 5))
        doc.layers[0].pngData = try RasterImage.png(image(Array(repeating: [0, 0, 0, 0], count: 35), width: 7, height: 5))
        XCTAssertThrowsError(try SelectionTransformSource(document: doc, layer: doc.layers[0], renderer: DocumentRenderer()))
        doc.layers[0].isLocked = true
        XCTAssertThrowsError(try SelectionTransformSource(document: doc, layer: doc.layers[0], renderer: DocumentRenderer())) {
            XCTAssertEqual($0 as? DocumentError, .lockedLayer)
        }
    }

    func testIdentityReturnsFrozenImagesWithoutChangingSoftPixelsOrDisabledMask() throws {
        let selection: [UInt8] = [0, 1, 64, 128, 200, 255]
        var doc = try document(width: 3, height: 2, pixels: [[128, 0, 0, 128], red, blue, green, [20, 40, 60, 80], [0, 0, 0, 0]], selection: selection)
        doc.layers[0].maskPNGData = try RasterImage.png(gray([0, 128], width: 2, height: 1))
        doc.layers[0].maskEnabled = false
        let renderer = DocumentRenderer(), originalLayer = doc.layers[0]
        let source = try SelectionTransformSource(document: doc, layer: originalLayer, renderer: renderer)
        let result = try source.preview(source.original)
        XCTAssertTrue(result.image === (try renderer.image(for: originalLayer)))
        XCTAssertEqual(result.transform, originalLayer.transform)
        XCTAssertEqual(try values(result.selection), selection)
        XCTAssertEqual(try values(XCTUnwrap(result.mask)), [0, 128])
        XCTAssertEqual(doc.layers[0], originalLayer)
    }

    func testSoftOverlapPreservesOpaqueAndHalfTransparentPixelsInsteadOfDimming() throws {
        for alpha in [UInt8(128), 255] {
            let rgba: [UInt8] = [alpha, 0, 0, alpha]
            let selection: [UInt8] = (0..<32).map { index in
                (1...4).contains(index % 8) && (1...2).contains(index / 8) ? 128 : 0
            }
            let doc = try document(width: 8, height: 4, pixels: Array(repeating: rgba, count: 32), selection: selection)
            let source = try SelectionTransformSource(document: doc, layer: doc.layers[0], renderer: DocumentRenderer())
            let result = try source.preview(moved(source.original, x: 1)), output = try pixels(result.image)
            let cut = UInt8((Int(alpha) * 128 + 127) / 255)
            assertPixel(output[1 * 8 + 1], [alpha - cut, 0, 0, alpha - cut])
            // Upstream .normal source-over produces 191/255 or 112/255 here. The two
            // complementary pieces are from the same cut and must restore 255 or 128.
            for x in 2...4 { assertPixel(output[1 * 8 + x], rgba) }
            let destinationAlpha = UInt8((Double(cut) + Double(alpha) * (1 - Double(cut) / 255)).rounded())
            assertPixel(output[1 * 8 + 5], [destinationAlpha, 0, 0, destinationAlpha])
            for index in [0, 7, 3 * 8 + 4, 1 * 8 + 6] { assertPixel(output[index], rgba) }
            let movedSelection = try values(result.selection)
            XCTAssertEqual(movedSelection[1 * 8 + 1], 0)
            for x in 2...5 { XCTAssertEqual(movedSelection[1 * 8 + x], 128, "The selected alpha is not multiplied twice") }
        }
    }

    func testArrivalOutsideOriginalSelectionUsesOrdinarySourceOverColorMixing() throws {
        var raster = Array(repeating: blue, count: 12)
        raster[1] = [128, 0, 0, 128]
        var selection = [UInt8](repeating: 0, count: 12); selection[1] = 128
        let doc = try document(width: 6, height: 2, pixels: raster, selection: selection)
        let source = try SelectionTransformSource(document: doc, layer: doc.layers[0], renderer: DocumentRenderer())
        let output = try pixels(source.preview(moved(source.original, x: 3)).image)
        assertPixel(output[1], [64, 0, 0, 64])
        assertPixel(output[4], [64, 0, 191, 255])
        for index in raster.indices where index != 1 && index != 4 { assertPixel(output[index], raster[index]) }
    }

    func testBilinearFractionalMoveKeepsUniformSoftOverlapAndNumericCoverage() throws {
        let rgba: [UInt8] = [128, 0, 0, 128]
        let selection: [UInt8] = (0..<128).map { index in
            (3...10).contains(index % 16) && (2...5).contains(index / 16) ? 128 : 0
        }
        let doc = try document(width: 16, height: 8, pixels: Array(repeating: rgba, count: 128), selection: selection, sampling: .high)
        let source = try SelectionTransformSource(document: doc, layer: doc.layers[0], renderer: DocumentRenderer())
        let result = try source.preview(moved(source.original, x: 0.25)), output = try pixels(result.image)
        let mask = try values(result.selection)
        assertPixel(output[3 * 16 + 5], rgba)
        XCTAssertEqual(mask[3 * 16 + 5], 128)
        XCTAssertEqual(mask[3 * 16 + 3], 96)
        XCTAssertEqual(mask[3 * 16 + 11], 32)
        for index in [0, 127, 3 * 16 + 1, 3 * 16 + 13] { assertPixel(output[index], rgba) }
        XCTAssertTrue(output.allSatisfy { $0[0] <= $0[3] && $0[1] <= $0[3] && $0[2] <= $0[3] })
        XCTAssertEqual(try values(RasterImage.decode(RasterImage.png(result.selection))), mask)
    }

    func testAllPreviewsUseFrozenSourcesRatherThanResamplingPreviousPreview() throws {
        let raster = (0..<24).map { $0.isMultiple(of: 2) ? red : blue }
        let selection: [UInt8] = (0..<24).map { (1...3).contains($0 % 6) ? 128 : 0 }
        let doc = try document(width: 6, height: 4, pixels: raster, selection: selection)
        let source = try SelectionTransformSource(document: doc, layer: doc.layers[0], renderer: DocumentRenderer())
        let first = try source.preview(moved(source.original, x: 1))
        _ = try source.preview(moved(source.original, x: 2))
        let again = try source.preview(moved(source.original, x: 1))
        XCTAssertEqual(try pixels(first.image), try pixels(again.image))
        XCTAssertEqual(try values(first.selection), try values(again.selection))
        XCTAssertEqual(try pixels(source.preview(source.original).image), raster)
        XCTAssertEqual(try values(source.preview(source.original).selection), selection)
    }

    func testNativeGridTranslationRespectsExistingRotationScaleAndFlips() throws {
        let renderer = DocumentRenderer()
        for angle: CGFloat in [0, 37, 90] { for flipX in [false, true] { for flipY in [false, true] {
            var raster = Array(repeating: red, count: 64); raster[3 * 8 + 3] = green; raster[0] = blue
            let layer = RasterLayer(name: "已变换图层", pngData: try RasterImage.png(image(raster, width: 8, height: 8)),
                transform: LayerTransform(origin: CGPoint(x: 12, y: 12), size: CGSize(width: 16, height: 8), rotation: angle,
                                          flipX: flipX, flipY: flipY, sampling: .nearest))
            let map = renderer.pixelToDocument(layer, size: CGSize(width: 8, height: 8))
            let corners = [CGPoint(x: 1, y: 1), CGPoint(x: 5, y: 1), CGPoint(x: 5, y: 5), CGPoint(x: 1, y: 5)].map { $0.applying(map) }
            let selection = try SelectionMask.rasterize(.polygon(corners), width: 40, height: 40)
            let doc = CanvasDocument(width: 40, height: 40, layers: [layer], activeLayerID: layer.id, selectionMaskPNGData: try RasterImage.png(selection))
            let source = try SelectionTransformSource(document: doc, layer: layer, renderer: renderer)
            let delta = CGPoint(x: map.a, y: map.b) // One native pixel right, expressed in document coordinates.
            let result = try source.preview(moved(source.original, x: delta.x, y: delta.y)), output = try pixels(result.image)
            XCTAssertEqual(result.transform, layer.transform)
            XCTAssertEqual(result.image.width, 8); XCTAssertEqual(result.image.height, 8)
            assertPixel(output[3 * 8 + 4], green)
            assertPixel(output[3 * 8 + 3], red)
            assertPixel(output[0], blue)
        } } }
    }

    func testSelectionRotationAndScalingMoveItsPixelsAndNumericMaskTogether() throws {
        var raster = Array(repeating: [UInt8](repeating: 0, count: 4), count: 64)
        raster[2 * 8 + 2] = red; raster[2 * 8 + 3] = blue
        var selection = [UInt8](repeating: 0, count: 64)
        selection[2 * 8 + 2] = 255; selection[2 * 8 + 3] = 128
        let doc = try document(width: 8, height: 8, pixels: raster, selection: selection)
        let source = try SelectionTransformSource(document: doc, layer: doc.layers[0], renderer: DocumentRenderer())
        var transform = source.original
        transform.origin = CGPoint(x: 4, y: 3); transform.size = CGSize(width: 4, height: 2); transform.rotation = 90
        let result = try source.preview(transform), output = try pixels(result.image), mask = try values(result.selection)
        // Destination centers: red occupies x5...6,y2...3; blue's 128 coverage x5...6,y4...5.
        for y in 2...3 { for x in 5...6 { assertPixel(output[y * 8 + x], red); XCTAssertEqual(mask[y * 8 + x], 255) } }
        for y in 4...5 { for x in 5...6 { assertPixel(output[y * 8 + x], [0, 0, 128, 128]); XCTAssertEqual(mask[y * 8 + x], 128) } }
        assertPixel(output[2 * 8 + 2], [0, 0, 0, 0])
        assertPixel(output[2 * 8 + 3], [0, 0, 127, 127])
    }

    func testPaddingAlignsDifferentResolutionMaskAndPreservesItsDocumentPosition() throws {
        let renderer = DocumentRenderer()
        for angle: CGFloat in [0, 90, 180, 270] { for enabled in [false, true] {
            let raster = [red, green, blue, blue, red, green]
            let layer = RasterLayer(name: "带蒙版图层", pngData: try RasterImage.png(image(raster, width: 3, height: 2)),
                transform: LayerTransform(origin: CGPoint(x: 7, y: 7), size: CGSize(width: 6, height: 4), rotation: angle,
                                          flipX: true, flipY: true, sampling: .nearest),
                maskPNGData: try RasterImage.png(gray([0, 128], width: 2, height: 1)), maskEnabled: enabled)
            let map = renderer.pixelToDocument(layer, size: CGSize(width: 3, height: 2))
            let corners = [CGPoint.zero, CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)].map { $0.applying(map) }
            let selection = try SelectionMask.rasterize(.polygon(corners), width: 24, height: 24)
            let doc = CanvasDocument(width: 24, height: 24, layers: [layer], selectionMaskPNGData: try RasterImage.png(selection))
            let source = try SelectionTransformSource(document: doc, layer: layer, renderer: renderer)
            let result = try source.preview(moved(source.original, x: -2 * map.a, y: -2 * map.b))
            XCTAssertEqual(result.image.width, 6); XCTAssertEqual(result.image.height, 2)
            let mask = try XCTUnwrap(result.mask)
            XCTAssertEqual(mask.width, 4); XCTAssertEqual(mask.height, 1)
            XCTAssertEqual(try values(mask), [255, 255, 0, 128])
            var expanded = layer; expanded.transform = result.transform
            let newMap = renderer.pixelToDocument(expanded, size: CGSize(width: 6, height: 2))
            let oldOrigin = CGPoint.zero.applying(map), newOrigin = CGPoint(x: 3, y: 0).applying(newMap)
            XCTAssertEqual(oldOrigin.x, newOrigin.x, accuracy: 0.000001)
            XCTAssertEqual(oldOrigin.y, newOrigin.y, accuracy: 0.000001)
            let output = try pixels(result.image)
            assertPixel(output[1], red)
            assertPixel(output[3], [0, 0, 0, 0])
            for y in 0..<2 { for x in 0..<3 where x != 0 || y != 0 { assertPixel(output[y * 6 + x + 3], raster[y * 3 + x]) } }
            XCTAssertEqual(result.transform.rotation, angle)
            XCTAssertTrue(result.transform.flipX); XCTAssertTrue(result.transform.flipY)
            XCTAssertEqual(doc.layers[0].maskEnabled, enabled)
        } }
    }

    func testMaskIsNotBakedOrMovedWhenPixelSelectionStaysInsideNativeGrid() throws {
        var selection = [UInt8](repeating: 0, count: 12); selection[1] = 255
        var doc = try document(width: 6, height: 2, pixels: Array(repeating: red, count: 12), selection: selection)
        doc.layers[0].maskPNGData = try RasterImage.png(gray([0, 64, 128], width: 3, height: 1))
        let source = try SelectionTransformSource(document: doc, layer: doc.layers[0], renderer: DocumentRenderer())
        let result = try source.preview(moved(source.original, x: 3))
        assertPixel(try pixels(result.image)[4], red, tolerance: 0)
        XCTAssertEqual(try values(XCTUnwrap(result.mask)), [0, 64, 128])
    }

    func testInvalidTransformsFailButUnsafeExpansionUsesDocumentGrid() throws {
        let selection: [UInt8] = [255, 0, 0, 0]
        let doc = try document(width: 2, height: 2, pixels: Array(repeating: red, count: 4), selection: selection)
        let source = try SelectionTransformSource(document: doc, layer: doc.layers[0], renderer: DocumentRenderer())
        var bad = source.original; bad.origin.x = .nan
        XCTAssertThrowsError(try source.preview(bad))
        bad = source.original; bad.size.width = 0
        XCTAssertThrowsError(try source.preview(bad))
        XCTAssertThrowsError(try source.preview(moved(source.original, x: 5000)))
        XCTAssertEqual(try pixels(source.preview(source.original).image), Array(repeating: red, count: 4))

        for (rotation, scale, sampling): (CGFloat, CGFloat, LayerSampling) in [(37, 1, .nearest), (0, 2, .high)] {
            var changed = doc
            changed.layers[0].transform = LayerTransform(size: CGSize(width: 2 * scale, height: 2 * scale),
                                                        rotation: rotation, sampling: sampling)
            let transformedSource = try SelectionTransformSource(document: changed, layer: changed.layers[0], renderer: DocumentRenderer())
            let result = try transformedSource.preview(moved(transformedSource.original, x: 10))
            XCTAssertTrue(result.rasterized)
            XCTAssertEqual(result.transform.rotation, 0)
            XCTAssertEqual(result.transform.size, CGSize(width: result.image.width, height: result.image.height))
            XCTAssertFalse(result.transform.flipX); XCTAssertFalse(result.transform.flipY)
            let identity = try transformedSource.preview(transformedSource.original)
            XCTAssertFalse(identity.rasterized)
            XCTAssertEqual(identity.transform, changed.layers[0].transform)
            XCTAssertEqual(try pixels(identity.image), Array(repeating: red, count: 4))
        }
    }

    func testRegriddedPreviewsKeepFrozenSourcesHandleBoxAndDisabledMask() throws {
        for enabled in [false, true] {
            let raster = (0..<48).map { $0.isMultiple(of: 3) ? [UInt8(128), 0, 0, 128] : blue }
            let originalMask: [UInt8] = [0, 64, 128, 255, 128, 200, 0, 255, 255, 0, 128, 64]
            let layer = RasterLayer(name: "文稿网格回退", pngData: try RasterImage.png(image(raster, width: 8, height: 6)),
                transform: LayerTransform(origin: CGPoint(x: -3.25, y: 4.4), size: CGSize(width: 12.8, height: 7.2),
                    rotation: 37, flipX: true, flipY: true, sampling: .high),
                maskPNGData: try RasterImage.png(gray(originalMask, width: 4, height: 3)), maskEnabled: enabled)
            let renderer = DocumentRenderer(), map = renderer.pixelToDocument(layer, size: CGSize(width: 8, height: 6))
            let corners = [CGPoint(x: 2, y: 1), CGPoint(x: 6, y: 1), CGPoint(x: 6, y: 5), CGPoint(x: 2, y: 5)]
                .map { $0.applying(map) }
            let selection = try SelectionMask.rasterize(.polygon(corners), width: 32, height: 24)
            let doc = CanvasDocument(width: 32, height: 24, layers: [layer], selectionMaskPNGData: try RasterImage.png(selection))
            let source = try SelectionTransformSource(document: doc, layer: layer, renderer: renderer)
            let original = source.original
            let target = moved(original, x: 20.25, y: 7.5)
            let first = try source.preview(target)
            XCTAssertTrue(first.rasterized)
            XCTAssertNotNil(first.mask)
            XCTAssertEqual(first.transform.size, CGSize(width: first.image.width, height: first.image.height))
            XCTAssertEqual(first.mask?.width, first.image.width)
            XCTAssertEqual(first.mask?.height, first.image.height)
            XCTAssertEqual(source.original, original, "Regridding must not move the user's handles")
            XCTAssertEqual(first.transform.origin.x, first.transform.origin.x.rounded())
            XCTAssertEqual(first.transform.origin.y, first.transform.origin.y.rounded())

            // Dragging back into the old native bounds continues from the same sampled
            // snapshot. Previous preview output must never become a new input image.
            let near = try source.preview(moved(original, x: 0.25))
            XCTAssertTrue(near.rasterized)
            _ = try source.preview(moved(original, x: -8, y: 3))
            let again = try source.preview(target)
            XCTAssertEqual(first.transform, again.transform)
            XCTAssertEqual(try pixels(first.image), try pixels(again.image))
            XCTAssertEqual(try values(XCTUnwrap(first.mask)), try values(XCTUnwrap(again.mask)))
            XCTAssertEqual(try values(first.selection), try values(again.selection))

            let identity = try source.preview(original)
            XCTAssertFalse(identity.rasterized)
            XCTAssertTrue(identity.image === (try renderer.image(for: layer)))
            XCTAssertEqual(identity.transform, layer.transform)
            XCTAssertEqual(try values(XCTUnwrap(identity.mask)), originalMask)
            XCTAssertEqual(try values(identity.selection), try values(selection))
            XCTAssertEqual(doc.layers[0], layer)
            XCTAssertTrue(try source.preview(target).rasterized, "Identity must not discard the frozen fallback")
        }
    }

    func testNativeOversizeCanRegridButFailedFallbackDoesNotChangeSource() throws {
        // A 64-pixel source shown at four document pixels needs thousands of native
        // pixels to move across a modest document. Decide its document-grid fallback
        // before rejecting the unnecessary native allocation.
        let raster = Array(repeating: red, count: 64 * 64)
        let layer = RasterLayer(name: "缩小图层", pngData: try RasterImage.png(image(raster, width: 64, height: 64)),
            transform: LayerTransform(origin: CGPoint(x: 2.25, y: 2.25), size: CGSize(width: 4, height: 4), sampling: .high))
        let selection = try SelectionMask.rasterize(.rectangle(CGRect(x: 3, y: 3, width: 2, height: 2)), width: 16, height: 16)
        let doc = CanvasDocument(width: 16, height: 16, layers: [layer], selectionMaskPNGData: try RasterImage.png(selection))
        let renderer = DocumentRenderer(), source = try SelectionTransformSource(document: doc, layer: layer, renderer: renderer)
        XCTAssertThrowsError(try source.preview(moved(source.original, x: 5000)))
        let stillNative = try source.preview(moved(source.original, x: 0.125))
        XCTAssertFalse(stillNative.rasterized, "Failed fallback must not change subsequent native previews")
        let result = try source.preview(moved(source.original, x: 300))
        XCTAssertTrue(result.rasterized)
        XCTAssertLessThan(result.image.width, 400)
        let identity = try source.preview(source.original)
        XCTAssertFalse(identity.rasterized)
        XCTAssertEqual(identity.image.width, 64)
        XCTAssertTrue(identity.image === (try renderer.image(for: layer)))
    }

    func testSmoothInternalEdgeKeepsFractionalSupportAfterTranslationAndRotation() throws {
        var raster = Array(repeating: [UInt8](repeating: 0, count: 4), count: 36)
        var selection = [UInt8](repeating: 0, count: 36)
        raster[2 * 6 + 2] = red; selection[2 * 6 + 2] = 128
        let doc = try document(width: 6, height: 6, pixels: raster, selection: selection, sampling: .high)
        let source = try SelectionTransformSource(document: doc, layer: doc.layers[0], renderer: DocumentRenderer())
        let translated = try source.preview(moved(source.original, x: 0.25, y: 0.25))
        let translatedPixels = try pixels(translated.image), translatedMask = try values(translated.selection)
        for (x,y,coverage,alpha): (Int,Int,UInt8,UInt8) in [(2,2,72,199),(3,2,24,24),(2,3,24,24),(3,3,8,8)] {
            XCTAssertEqual(translatedMask[y * 6 + x], coverage)
            assertPixel(translatedPixels[y * 6 + x], [alpha,0,0,alpha])
        }
        var transform = source.original; transform.rotation = 45
        let rotated = try source.preview(transform), rotatedPixels = try pixels(rotated.image), rotatedMask = try values(rotated.selection)
        XCTAssertEqual(rotatedMask[2 * 6 + 2], 128)
        assertPixel(rotatedPixels[2 * 6 + 2], red)
        for (x,y) in [(1,2),(3,2),(2,1),(2,3)] {
            XCTAssertEqual(rotatedMask[y * 6 + x], 11)
            assertPixel(rotatedPixels[y * 6 + x], [11,0,0,11])
        }
    }

    func testSmoothImageBoundaryClampsInsideAndReturnsZeroOutside() throws {
        var raster = Array(repeating: [UInt8](repeating: 0, count: 4), count: 12)
        var selection = [UInt8](repeating: 0, count: 12)
        raster[0] = red; selection[0] = 128
        let doc = try document(width: 6, height: 2, pixels: raster, selection: selection, sampling: .high)
        let source = try SelectionTransformSource(document: doc, layer: doc.layers[0], renderer: DocumentRenderer())
        let right = try source.preview(moved(source.original, x: 0.25)), rightMask = try values(right.selection)
        let rightPixels = try pixels(right.image)
        XCTAssertEqual(rightMask[0], 128); XCTAssertEqual(rightMask[1], 32)
        assertPixel(rightPixels[0], red); assertPixel(rightPixels[1], [32,0,0,32])
        let left = try source.preview(moved(source.original, x: -0.75))
        XCTAssertEqual(try values(left.selection)[0], 32)
        XCTAssertEqual(left.image.width, 7)
        // The moved raster expands, while the selection remains clipped to document size.
        let leftPixels = try pixels(left.image)
        assertPixel(leftPixels[0], [128,0,0,128])
        assertPixel(leftPixels[1], [159,0,0,159])
    }

}
