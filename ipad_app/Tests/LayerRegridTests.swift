import XCTest
import CoreGraphics
@testable import CompositorKit

final class LayerRegridTests: XCTestCase {
    private func source(width: Int = 16, height: Int = 12) throws -> CGImage {
        var pixels = [UInt8]()
        for y in 0..<height {
            for x in 0..<width {
                let alpha = (x * 19 + y * 31) % 192 + 64
                pixels += [UInt8(alpha * (x + 1) / width), UInt8(alpha * (y + 1) / height),
                           UInt8(alpha * 2 / 3), UInt8(alpha)]
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func mask(black: Bool = false) throws -> CGImage {
        let pixels: [UInt8] = (0..<6).flatMap { y in (0..<8).map { x in black ? 0 : UInt8((x * 37 + y * 61) % 256) } }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        return try XCTUnwrap(CGImage(width: 8, height: 6, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: 8, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func layer(transform: LayerTransform, hasMask: Bool = true, maskEnabled: Bool = true) throws -> RasterLayer {
        RasterLayer(name: "合成重新采样图层", pngData: try RasterImage.png(source()), transform: transform,
                    maskPNGData: hasMask ? try RasterImage.png(mask()) : nil, maskEnabled: maskEnabled)
    }

    private func bytes(_ image: CGImage) throws -> [UInt8] {
        let context = try RasterImage.context(width: image.width, height: image.height)
        context.setBlendMode(.copy)
        RasterImage.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), context: context)
        return Array(UnsafeBufferPointer(start: try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self),
                                         count: image.width * image.height * 4))
    }

    private func prepared(_ layer: RasterLayer, renderer: DocumentRenderer) throws -> LayerRegridResult {
        try LayerRegrid.prepare(layer: layer, image: XCTUnwrap(renderer.image(for: layer)),
                                mask: layer.maskPNGData.map(RasterImage.decode))
    }

    private func render(_ original: RasterLayer, replacement: LayerRegridResult? = nil,
                        renderer: DocumentRenderer) throws -> CGImage {
        var layer = original
        if let replacement { layer.transform = replacement.transform }
        let document = CanvasDocument(width: 96, height: 96, layers: [layer], activeLayerID: layer.id)
        if let replacement {
            return try renderer.render(document, replacing: layer.id, with: replacement.image, replacementMask: replacement.mask)
        }
        return try renderer.render(document)
    }

    private func assertDifference(_ first: CGImage, _ second: CGImage, atMost tolerance: Int,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(first.width, second.width, file: file, line: line)
        XCTAssertEqual(first.height, second.height, file: file, line: line)
        let a = try bytes(first), b = try bytes(second)
        let maximum = zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? 0
        XCTAssertLessThanOrEqual(maximum, tolerance, "Largest RGBA difference is \(maximum)/255", file: file, line: line)
    }

    func testNativeUnitGridKeepsExactPixelsWithIndependentMaskAndDisabledMask() throws {
        let renderer = DocumentRenderer()
        for enabled in [true, false] {
            let original = try layer(transform: LayerTransform(origin: CGPoint(x: 28, y: 29),
                                                               size: CGSize(width: 16, height: 12)), maskEnabled: enabled)
            let result = try prepared(original, renderer: renderer)
            XCTAssertEqual(result.transform, original.transform)
            XCTAssertNotNil(result.mask)
            try assertDifference(render(original, renderer: renderer), render(original, replacement: result, renderer: renderer), atMost: 0)
        }
    }

    func testRotationScaleFractionAndFlipsPreserveMaskedAppearanceWithinOneByte() throws {
        let renderer = DocumentRenderer()
        let cases: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
            (37, 1, 1, 0), (0, 1.5, 2, 0.25), (37, 1.5, 2, 0.25), (-53, 0.75, 0.5, 0.375)
        ]
        for (angle, sx, sy, fraction) in cases {
            for flips in [(false, false), (true, false), (false, true), (true, true)] {
                let original = try layer(transform: LayerTransform(origin: CGPoint(x: 28 + fraction, y: 29 + fraction),
                    size: CGSize(width: 16 * sx, height: 12 * sy), rotation: angle,
                    flipX: flips.0, flipY: flips.1, sampling: .high))
                let result = try prepared(original, renderer: renderer)
                XCTAssertEqual(result.transform.rotation, 0)
                XCTAssertFalse(result.transform.flipX)
                XCTAssertFalse(result.transform.flipY)
                XCTAssertEqual(result.transform.size, CGSize(width: result.image.width, height: result.image.height))
                XCTAssertEqual(result.mask?.width, result.image.width)
                XCTAssertEqual(result.mask?.height, result.image.height)
                try assertDifference(render(original, renderer: renderer), render(original, replacement: result, renderer: renderer), atMost: 1)
                var disabled = original
                disabled.maskEnabled = false
                try assertDifference(render(disabled, renderer: renderer), render(disabled, replacement: result, renderer: renderer), atMost: 0)
            }
        }
    }

    func testAbsentMaskAndLayerPropertiesAreNotBakedIntoRawPixels() throws {
        let renderer = DocumentRenderer()
        var original = try layer(transform: LayerTransform(origin: CGPoint(x: 24.25, y: 25.5),
            size: CGSize(width: 24, height: 18), rotation: 37, flipX: true), hasMask: false)
        original.opacity = 0.23
        original.blendMode = .multiply
        original.isVisible = false
        original.isLocked = true
        let before = original
        let result = try prepared(original, renderer: renderer)
        XCTAssertNil(result.mask)
        var visible = original
        visible.opacity = 1
        visible.blendMode = .normal
        visible.isVisible = true
        try assertDifference(render(visible, renderer: renderer), render(visible, replacement: result, renderer: renderer), atMost: 0)
        XCTAssertEqual(original, before)
    }

    func testBlackDisabledMaskKeepsHiddenRawPixelsForLaterEditing() throws {
        let renderer = DocumentRenderer()
        var original = try layer(transform: LayerTransform(origin: CGPoint(x: 25.25, y: 24.5),
            size: CGSize(width: 24, height: 18), rotation: 37), maskEnabled: false)
        original.maskPNGData = try RasterImage.png(mask(black: true))
        let result = try prepared(original, renderer: renderer)
        XCTAssertNotNil(result.mask)
        XCTAssertTrue(try bytes(result.image).enumerated().contains { $0.offset % 4 == 3 && $0.element > 0 })
        try assertDifference(render(original, renderer: renderer), render(original, replacement: result, renderer: renderer), atMost: 0)
        original.maskEnabled = true
        let masked = try bytes(render(original, replacement: result, renderer: renderer))
        XCTAssertTrue(masked.enumerated().filter { $0.offset % 4 == 3 }.allSatisfy { $0.element == 0 })
    }

    func testBoundsRetainTheEntireTransformedLayerOutsideTheDocument() throws {
        let renderer = DocumentRenderer()
        let original = try layer(transform: LayerTransform(origin: CGPoint(x: -10, y: -8),
            size: CGSize(width: 16, height: 12), rotation: 90, sampling: .nearest), hasMask: false)
        let result = try prepared(original, renderer: renderer)
        XCTAssertEqual(result.transform.origin, CGPoint(x: -8, y: -10))
        XCTAssertEqual(result.transform.size, CGSize(width: 12, height: 16))
        XCTAssertEqual(result.image.width, 12)
        XCTAssertEqual(result.image.height, 16)
        // Move both representations into a larger visible document only after
        // preparation, proving that off-canvas pixels were retained.
        var translated = original
        translated.transform.origin.x += 40
        translated.transform.origin.y += 40
        var placement = result.transform
        placement.origin.x += 40
        placement.origin.y += 40
        let shiftedResult = LayerRegridResult(image: result.image, mask: result.mask, transform: placement)
        try assertDifference(render(translated, renderer: renderer),
                             render(translated, replacement: shiftedResult, renderer: renderer), atMost: 0)
    }

    func testOversizedOrInvalidRegridsFailBeforeRendering() throws {
        let image = try source()
        var original = try layer(transform: LayerTransform(size: CGSize(width: 5000, height: 12)), hasMask: false)
        XCTAssertThrowsError(try LayerRegrid.prepare(layer: original, image: image, mask: nil)) {
            guard case RasterError.oversized = $0 else { return XCTFail("Expected the explicit surface size limit") }
        }
        original.transform = LayerTransform(size: CGSize(width: 4096, height: 4096))
        XCTAssertThrowsError(try LayerRegrid.prepare(layer: original, image: image, mask: nil))
        original.transform = LayerTransform(size: CGSize(width: 16, height: 12), rotation: .nan)
        XCTAssertThrowsError(try LayerRegrid.prepare(layer: original, image: image, mask: nil))
        original.transform = LayerTransform(size: CGSize(width: 16, height: 12))
        XCTAssertThrowsError(try LayerRegrid.prepare(layer: original, image: image, mask: image))
    }
}
