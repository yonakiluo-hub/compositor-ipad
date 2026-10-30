import XCTest
import CoreGraphics
import ImageIO
@testable import CompositorKit

final class PSDWorkflowTests: XCTestCase {
    /// Independent minimal Adobe PSD fixture writer; it does not call the production codec.
    private struct Bytes {
        var data = Data()
        mutating func byte(_ n: Int) { data.append(UInt8(n & 255)) }
        mutating func word(_ n: Int) { byte(n >> 8); byte(n) }
        mutating func long(_ n: Int) { word(n >> 16); word(n) }
        mutating func text(_ s: String) { data.append(contentsOf: s.utf8) }
        mutating func block(_ d: Data) { long(d.count); data.append(d) }
    }
    private struct LayerFixture {
        var name = "Layer"
        var x = 0, y = 0, width = 2, height = 2
        var pixels: [[UInt8]] = [[255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 128], [128, 128, 128, 255]]
        var opacity = 255, blend = "norm", clipping = 0, flags = 0
        var extra: [(String, Data)] = []
        var mask: (x: Int, y: Int, width: Int, height: Int, values: [UInt8], enabled: Bool)?
        var rle = false
        var channelOverride: Data?
        var channelIDs = [0, 1, 2, -1]
    }
    private func fixture(layers: [LayerFixture], width: Int = 2, height: Int = 2,
                         resources: [(Int, Data)] = []) -> Data {
        var info = Bytes(); info.word(-layers.count)
        var payloads: [Data] = []
        for layer in layers {
            var channels: [(Int, Data)] = []
            for id in layer.channelIDs {
                let values = layer.pixels.map { $0[id < 0 ? 3 : id] }
                channels.append((id, layer.channelOverride ?? channel(values, width: layer.width, height: layer.height, rle: layer.rle)))
            }
            if let mask = layer.mask { channels.append((-2, channel(mask.values, width: mask.width, height: mask.height, rle: false))) }
            info.long(layer.y); info.long(layer.x); info.long(layer.y + layer.height); info.long(layer.x + layer.width)
            info.word(channels.count)
            for (id, payload) in channels { info.word(id); info.long(payload.count); payloads.append(payload) }
            info.text("8BIM"); info.text(layer.blend); info.byte(layer.opacity); info.byte(layer.clipping); info.byte(layer.flags); info.byte(0)
            var extra = Bytes()
            if let mask = layer.mask {
                extra.long(20); extra.long(mask.y); extra.long(mask.x); extra.long(mask.y + mask.height); extra.long(mask.x + mask.width)
                extra.byte(255); extra.byte(mask.enabled ? 0 : 2); extra.word(0)
            } else { extra.long(0) }
            extra.long(0); extra.byte(1); extra.text("L"); extra.word(0)
            var unicode = Bytes(); unicode.long(layer.name.utf16.count)
            for unit in layer.name.utf16 { unicode.word(Int(unit)) }
            for (key, value) in [("luni", unicode.data)] + layer.extra {
                extra.text("8BIM"); extra.text(key); extra.block(value); if value.count % 2 != 0 { extra.byte(0) }
            }
            info.block(extra.data)
        }
        for payload in payloads { info.data.append(payload) }
        if info.data.count % 2 != 0 { info.byte(0) }
        var section = Bytes(); section.block(info.data); section.long(0)
        var out = Bytes(); out.text("8BPS"); out.word(1); out.data.append(Data(repeating: 0, count: 6)); out.word(4)
        out.long(height); out.long(width); out.word(8); out.word(3); out.long(0)
        var imageResources = Bytes()
        for (id, value) in resources { imageResources.text("8BIM"); imageResources.word(id); imageResources.word(0); imageResources.block(value); if value.count % 2 != 0 { imageResources.byte(0) } }
        out.block(imageResources.data); out.block(section.data)
        out.word(0); out.data.append(Data(repeating: 0, count: width * height * 4))
        return out.data
    }
    private func channel(_ values: [UInt8], width: Int, height: Int, rle: Bool) -> Data {
        var b = Bytes(); b.word(rle ? 1 : 0)
        if rle {
            for _ in 0..<height { b.word(width + 1) }
            for row in 0..<height { b.byte(width - 1); b.data.append(contentsOf: values[(row * width)..<(row * width + width)]) }
        } else { b.data.append(contentsOf: values) }
        return b.data
    }
    private func rgba(_ image: CGImage) throws -> [[UInt8]] {
        let context = try XCTUnwrap(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.setBlendMode(.copy); context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<(image.width * image.height)).map { i in Array(UnsafeBufferPointer(start: bytes + i * 4, count: 4)) }
    }
    private func assertImages(_ a: CGImage, _ b: CGImage, tolerance: Int = 1, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(a.width, b.width, file: file, line: line); XCTAssertEqual(a.height, b.height, file: file, line: line)
        for (p, q) in zip(try rgba(a), try rgba(b)) { for (x, y) in zip(p, q) { XCTAssertLessThanOrEqual(abs(Int(x) - Int(y)), tolerance, "\(p) != \(q)", file: file, line: line) } }
    }

    /// Opt-in synthetic artifacts for independent PSD tools, never user documents.
    private func exportInteropFixture(_ document: CanvasDocument, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["COMPOSITOR_PSD_FIXTURE_DIRECTORY"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try PSDCodec.write(document).write(to: directory.appendingPathComponent(name + ".psd"))
        try RasterImage.png(DocumentRenderer().render(document)).write(to: directory.appendingPathComponent(name + "-expected.png"))
    }

    func testIndependentRawAndPackBitsFixturesPreserveUnicodeRowsAlphaAndMetadata() throws {
        for rle in [false, true] {
            let input = LayerFixture(name: "图层 🦋", x: -1, y: 1, opacity: 128, flags: 1, rle: rle)
            let document = try PSDCodec.read(fixture(layers: [input], width: 3, height: 4), name: "Fixture")
            let layer = try XCTUnwrap(document.layers.first)
            XCTAssertEqual(layer.name, input.name); XCTAssertEqual(layer.transform.origin, CGPoint(x: -1, y: 1))
            XCTAssertTrue(layer.isLocked); XCTAssertEqual(layer.opacity, 128.0 / 255)
            let pixels = try rgba(RasterImage.decode(try XCTUnwrap(layer.pngData)))
            XCTAssertEqual(pixels[0], [255, 0, 0, 255]); XCTAssertEqual(pixels[1], [0, 255, 0, 255])
            XCTAssertEqual(pixels[2], [0, 0, 128, 128]); XCTAssertEqual(pixels[3], [128, 128, 128, 255])
        }
    }

    func testFileAndNativeLayersUseBottomFirstOrderForClipping() throws {
        let top = LayerFixture(name: "Top", opacity: 128, blend: "mul ", clipping: 1)
        var base = LayerFixture(name: "Base")
        for i in base.pixels.indices { base.pixels[i][3] = 255 }
        let document = try PSDCodec.read(fixture(layers: [base, top]))
        XCTAssertEqual(document.layers.map(\.name), ["Base", "Top"])
        XCTAssertEqual(document.layers[1].maskSourceID, document.layers[0].id)
        XCTAssertEqual(document.layers[1].blendMode, .multiply)
    }

    func testIndependentStandardBottomToTopColorsAndNestedGroupRecords() throws {
        var base = LayerFixture(name: "Base"); base.pixels = Array(repeating: [0, 0, 255, 255], count: 4)
        var top = LayerFixture(name: "Top"); top.pixels = Array(repeating: [255, 0, 0, 128], count: 4)
        let ordinary = try PSDCodec.read(fixture(layers: [base, top]))
        XCTAssertEqual(ordinary.layers.map(\.name), ["Base", "Top"])
        try exportInteropFixture(ordinary, name: "standard-layer-order")
        for pixel in try rgba(DocumentRenderer().render(ordinary)) {
            XCTAssertEqual(pixel[0], 128, accuracy: 1); XCTAssertEqual(pixel[1], 0)
            XCTAssertEqual(pixel[2], 127, accuracy: 1); XCTAssertEqual(pixel[3], 255)
        }
        func folder(_ name: String, kind: Int) -> LayerFixture {
            var payload = Bytes(); payload.long(kind)
            var layer = LayerFixture(name: name, width: 0, height: 0, pixels: [], blend: "pass")
            layer.channelIDs = []; layer.extra = [("lsct", payload.data)]; return layer
        }
        // This sequence is written directly from Adobe section-divider types,
        // independently of the production writer: 3, children, 1/2, bottom-to-top.
        top.clipping = 1
        let input = fixture(layers: [folder("Outer end", kind: 3), folder("Inner end", kind: 3), base, top,
                                    folder("Inner", kind: 2), folder("Outer", kind: 1)])
        let document = try PSDCodec.read(input)
        XCTAssertEqual(document.hierarchy.map { $0.layer.name }, ["Outer", "Inner", "Base", "Top"])
        XCTAssertEqual(document.hierarchy.map(\.depth), [0, 1, 2, 2])
        XCTAssertEqual(document.layers[3].maskSourceID, document.layers[2].id)
        XCTAssertEqual(document.layers[2].parentID, document.layers[1].id)
        XCTAssertEqual(document.layers[1].parentID, document.layers[0].id)
    }

    func testIndependentMaskOutsideImageExpandsTransparentSourceWithoutDiscardingMaskSamples() throws {
        let layer = LayerFixture(name: "Masked", mask: (x: -1, y: 0, width: 4, height: 2, values: [0, 32, 128, 255, 255, 128, 32, 0], enabled: false))
        let document = try PSDCodec.read(fixture(layers: [layer], width: 3, height: 3))
        let imported = try XCTUnwrap(document.layers.first)
        XCTAssertEqual(imported.transform.origin, CGPoint(x: -1, y: 0)); XCTAssertEqual(imported.transform.size, CGSize(width: 4, height: 2))
        XCTAssertFalse(imported.maskEnabled)
        let mask = try RasterImage.decode(try XCTUnwrap(imported.maskPNGData))
        let raw = try XCTUnwrap(mask.dataProvider?.data) as Data
        XCTAssertEqual(Array(raw.prefix(8)), [0, 32, 128, 255, 255, 128, 32, 0])
        let pixels = try rgba(RasterImage.decode(try XCTUnwrap(imported.pngData)))
        XCTAssertEqual(pixels[0][3], 0); XCTAssertEqual(pixels[3][3], 0)
    }

    func testWriterCreatesRealLayersAndImageIOReadableMergedPreview() throws {
        var document = try PSDCodec.read(fixture(layers: [LayerFixture(name: "底层"), LayerFixture(name: "顶层", opacity: 128)]))
        document.guides = [CanvasGuide(axis: .vertical, position: 0.25), CanvasGuide(axis: .horizontal, position: -1)]
        let sourceBytes = document.layers.map(\.pngData)
        let data = try PSDCodec.write(document)
        let decoded = try PSDCodec.read(data)
        XCTAssertEqual(decoded.layers.count, 2); XCTAssertEqual(decoded.layers.map(\.name), ["底层", "顶层"])
        XCTAssertEqual(decoded.guides.map(\.position), [0.25, -1]); XCTAssertEqual(decoded.guides.map(\.axis), [.vertical, .horizontal])
        try assertImages(DocumentRenderer().render(document), DocumentRenderer().render(decoded))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let preview = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(preview.width, document.width); XCTAssertEqual(preview.height, document.height)
        // ImageIO's decoder does not undo PSD's white matte consistently. Verify
        // standard file samples independently of that decoder's alpha tagging.
        let bytes = Array(data.suffix(document.width * document.height * 4))
        let expected = try rgba(DocumentRenderer().render(document))
        for i in expected.indices {
            let alpha = expected[i][3]
            XCTAssertEqual(bytes[expected.count * 3 + i], alpha)
            for channel in 0..<3 { XCTAssertEqual(Int(bytes[expected.count * channel + i]), Int(expected[i][channel]) + 255 - Int(alpha)) }
        }
        XCTAssertEqual(document.layers.map(\.pngData), sourceBytes)
    }

    func testNonPrimaryGrayAlphaMergedPreviewUsesWhiteMatteWithoutChangingLayerPlanes() throws {
        let samples: [[UInt8]] = [[145, 122, 94, 0], [145, 122, 94, 1], [177, 102, 43, 64],
                                  [145, 122, 94, 128], [73, 159, 206, 254], [73, 159, 206, 255]]
        let document = try PSDCodec.read(fixture(layers: [LayerFixture(name: "Gray Alpha", width: samples.count, height: 1, pixels: samples)], width: samples.count, height: 1))
        let data = try PSDCodec.write(document), expected = try rgba(DocumentRenderer().render(document))
        let merged = Array(data.suffix(samples.count * 4))
        for i in samples.indices {
            let alpha = expected[i][3]
            XCTAssertEqual(merged[samples.count * 3 + i], alpha)
            for channel in 0..<3 {
                XCTAssertEqual(Int(merged[samples.count * channel + i]), Int(expected[i][channel]) + 255 - Int(alpha))
            }
        }
        try assertImages(DocumentRenderer().render(PSDCodec.read(data)), DocumentRenderer().render(document))
        try exportInteropFixture(document, name: "gray-alpha-preview")
    }

    func testLayerlessMergedTransparencyUnmattesRGBButThreeChannelRGBRemainsUnchanged() throws {
        let samples: [[UInt8]] = [[145, 122, 94, 0], [145, 122, 94, 1], [177, 102, 43, 64],
                                  [145, 122, 94, 128], [73, 159, 206, 254], [73, 159, 206, 255]]
        func mergedFile(alpha: Bool) -> Data {
            var section = Bytes(); section.long(0); section.long(0)
            if alpha { section.text("8BIM"); section.text("Mtrn"); section.long(0) }
            var out = Bytes(); out.text("8BPS"); out.word(1); out.data.append(Data(repeating: 0, count: 6))
            out.word(alpha ? 4 : 3); out.long(1); out.long(samples.count); out.word(8); out.word(3)
            out.long(0); out.long(0); out.block(section.data); out.word(0)
            for channel in 0..<(alpha ? 4 : 3) { for pixel in samples {
                if channel == 3 { out.byte(Int(pixel[3])) }
                else if alpha { out.byte((Int(pixel[channel]) * Int(pixel[3]) + 127) / 255 + 255 - Int(pixel[3])) }
                else { out.byte(Int(pixel[channel])) }
            } }
            return out.data
        }
        for alpha in [false, true] {
            let decoded = try PSDCodec.read(mergedFile(alpha: alpha)), actual = try rgba(DocumentRenderer().render(decoded))
            for i in samples.indices {
                let a = alpha ? Int(samples[i][3]) : 255
                XCTAssertEqual(actual[i][3], UInt8(a))
                for channel in 0..<3 {
                    XCTAssertEqual(Int(actual[i][channel]), (Int(samples[i][channel]) * a + 127) / 255, accuracy: 1)
                }
            }
        }
    }

    func testWriterRoundTripsGroupsClippingHiddenLayersMasksAndOffCanvasGeometry() throws {
        var document = try PSDCodec.read(fixture(layers: [LayerFixture(name: "Base"), LayerFixture(name: "Child", clipping: 1)], width: 4, height: 4))
        let group = RasterLayer(name: "组", transform: LayerTransform(size: document.size), isGroup: true)
        for i in document.layers.indices { document.layers[i].parentID = group.id; document.layers[i].transform.origin.x = -1 }
        document.layers.insert(group, at: 0)
        var hidden = document.layers[1]; hidden = RasterLayer(name: "Hidden", pngData: hidden.pngData, transform: hidden.transform, isVisible: false)
        document.layers.append(hidden)
        let data = try PSDCodec.write(document), decoded = try PSDCodec.read(data)
        XCTAssertEqual(decoded.hierarchy.map { $0.layer.name }, ["组", "Base", "Child", "Hidden"])
        XCTAssertTrue(decoded.layers.contains { $0.name == "Hidden" && !$0.isVisible })
        XCTAssertTrue(decoded.layers.contains { $0.name == "Base" && $0.transform.origin.x == -1 })
        XCTAssertNotNil(decoded.layers.first { $0.name == "Child" }?.maskSourceID)
        try exportInteropFixture(document, name: "standard-groups")
        try assertImages(DocumentRenderer().render(document), DocumentRenderer().render(decoded))
    }

    func testWriterPreservesNestedGroupsWithDifferentColorsAndContinuousClipping() throws {
        let canvas = CGSize(width: 8, height: 6)
        let outer = RasterLayer(name: "外组", transform: LayerTransform(size: canvas), isGroup: true)
        let inner = RasterLayer(name: "内组", transform: LayerTransform(size: canvas), isLocked: true, parentID: outer.id, isGroup: true)
        let background = RasterLayer(name: "Background", pngData: try RasterImage.png(RasterImage.solidMask(width: 8, height: 6, white: true)), transform: LayerTransform(size: canvas))
        var baseInput = LayerFixture(name: "Base")
        baseInput.pixels = [[255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255], [255, 255, 0, 0]]
        var childInput = LayerFixture(name: "Child", opacity: 153, blend: "mul ")
        childInput.pixels = [[0, 255, 255, 255], [255, 0, 255, 255], [255, 255, 255, 255], [255, 0, 0, 255]]
        var base = try XCTUnwrap(PSDCodec.read(fixture(layers: [baseInput])).layers.first)
        var child = try XCTUnwrap(PSDCodec.read(fixture(layers: [childInput])).layers.first)
        base.parentID = inner.id; child.parentID = inner.id; child.maskSourceID = base.id
        base.transform.origin = CGPoint(x: -1, y: 1); child.transform.origin = base.transform.origin
        var sibling = RasterLayer(name: "Sibling", pngData: child.pngData, transform: LayerTransform(origin: CGPoint(x: 4, y: 2), size: CGSize(width: 2, height: 2)), opacity: 0.7, parentID: outer.id)
        sibling.blendMode = .screen
        let hidden = RasterLayer(name: "Hidden", pngData: base.pngData, transform: LayerTransform(size: CGSize(width: 2, height: 2)), isVisible: false)
        let document = CanvasDocument(width: 8, height: 6, layers: [background, outer, inner, base, child, sibling, hidden], activeLayerID: child.id)
        let decoded = try PSDCodec.read(PSDCodec.write(document))
        XCTAssertEqual(decoded.hierarchy.map { $0.layer.name }, ["Background", "外组", "内组", "Base", "Child", "Sibling", "Hidden"])
        XCTAssertEqual(decoded.hierarchy.map(\.depth), [0, 0, 1, 2, 2, 1, 0])
        XCTAssertEqual(decoded.layers[4].maskSourceID, decoded.layers[3].id)
        try assertImages(DocumentRenderer().render(document), DocumentRenderer().render(decoded))
        try exportInteropFixture(document, name: "standard-nested-opaque-base")
    }

    func testWriterPreservesAlignedMaskAndRejectsNonEquivalentMaskedSampling() throws {
        var document = try PSDCodec.read(fixture(layers: [LayerFixture(name: "Soft", mask: (x: 0, y: 0, width: 2, height: 2, values: [0, 128, 255, 64], enabled: true))], width: 6, height: 5))
        document.layers[0].transform.origin = CGPoint(x: 2, y: 1)
        for rotation: CGFloat in [0, 90, 180, 270] {
            document.layers[0].transform.rotation = rotation
            document.layers[0].transform.flipX = true
            let decoded = try PSDCodec.read(PSDCodec.write(document))
            try assertImages(DocumentRenderer().render(document), DocumentRenderer().render(decoded))
            XCTAssertNotNil(decoded.layers[0].maskPNGData)
            XCTAssertEqual(decoded.layers[0].transform.origin, CGPoint(x: 2, y: 1))
            XCTAssertEqual(decoded.layers[0].transform.size, CGSize(width: 2, height: 2))
            try exportInteropFixture(document, name: "standard-mask-\(Int(rotation))")
        }
        let original = document
        document.layers[0].transform.rotation = 25
        XCTAssertThrowsError(try PSDCodec.write(document))
        document = original; document.layers[0].transform.size.width = 4
        XCTAssertThrowsError(try PSDCodec.write(document))
        document = original; document.layers[0].transform.origin.x += 0.5
        XCTAssertThrowsError(try PSDCodec.write(document))
        document = original; document.layers[0].maskPNGData = nil
        document.layers[0].transform.rotation = 25
        let decoded = try PSDCodec.read(PSDCodec.write(document))
        try assertImages(DocumentRenderer().render(document), DocumentRenderer().render(decoded), tolerance: 2)
    }

    func testNonNormalClippingRejectsFractionalImageMaskAndOpacityCoverageOnReadAndWrite() throws {
        let opaque = Array(repeating: [UInt8(0), 255, 0, 255], count: 4)
        var cases: [LayerFixture] = []
        var imageAlpha = LayerFixture(name: "Alpha"); imageAlpha.pixels = Array(repeating: [0, 255, 0, 128], count: 4); cases.append(imageAlpha)
        var grayMask = LayerFixture(name: "Mask"); grayMask.pixels = opaque
        grayMask.mask = (x: 0, y: 0, width: 2, height: 2, values: [255, 128, 0, 255], enabled: true); cases.append(grayMask)
        var opacity = LayerFixture(name: "Opacity", opacity: 128); opacity.pixels = opaque; cases.append(opacity)
        for base in cases {
            let child = LayerFixture(name: "Child", blend: "mul ", clipping: 1)
            XCTAssertThrowsError(try PSDCodec.read(fixture(layers: [base, child]))) { error in
                guard case PSDFileError.unsupported(let detail) = error else { return XCTFail("Wrong rejection: \(error)") }
                XCTAssertTrue(detail.contains("半透明基底") && detail.contains(".comp"))
            }
            var normalChild = child; normalChild.blend = "norm"
            var document = try PSDCodec.read(fixture(layers: [base, normalChild]))
            document.layers[1].blendMode = .multiply; let original = document
            XCTAssertThrowsError(try PSDCodec.write(document))
            XCTAssertEqual(document, original)
        }
        // Preserve strictness before Double opacity is quantized to a PSD byte.
        var base = LayerFixture(name: "Opaque"); base.pixels = opaque
        var document = try PSDCodec.read(fixture(layers: [base, LayerFixture(name: "Child", blend: "mul ", clipping: 1)]))
        document.layers[0].opacity = 0.999
        XCTAssertThrowsError(try PSDCodec.write(document))
        document.layers[0].opacity = 1; document.layers[0].transform.rotation = 25
        XCTAssertThrowsError(try PSDCodec.write(document), "Prepared geometric antialiasing also makes base coverage fractional")
    }

    func testSafeNormalAndOpaqueBaseClippingRemainSupportedAndCLBLIsStrict() throws {
        var base = LayerFixture(name: "Base"); base.pixels = Array(repeating: [0, 255, 0, 255], count: 4)
        var child = LayerFixture(name: "Child", opacity: 153, blend: "mul ", clipping: 1)
        child.pixels = Array(repeating: [255, 0, 255, 255], count: 4)
        let opaque = try PSDCodec.read(fixture(layers: [base, child]))
        try assertImages(DocumentRenderer().render(opaque), DocumentRenderer().render(PSDCodec.read(PSDCodec.write(opaque))))
        try exportInteropFixture(opaque, name: "safe-multiply-opaque-base")
        var disabled = base
        disabled.mask = (x: 0, y: 0, width: 2, height: 2, values: [128, 128, 128, 128], enabled: false)
        let disabledMask = try PSDCodec.read(fixture(layers: [disabled, child]))
        _ = try PSDCodec.write(disabledMask)
        try exportInteropFixture(disabledMask, name: "safe-multiply-disabled-mask")
        var hardMask = base
        hardMask.mask = (x: 0, y: 0, width: 2, height: 2, values: [255, 0, 255, 0], enabled: true)
        let hardMasked = try PSDCodec.read(fixture(layers: [hardMask, child]))
        _ = try PSDCodec.write(hardMasked)
        try exportInteropFixture(hardMasked, name: "safe-multiply-binary-mask")
        base.pixels = Array(repeating: [0, 255, 0, 128], count: 4)
        child.blend = "norm"; child.opacity = 255
        let normal = try PSDCodec.read(fixture(layers: [base, child]))
        _ = try PSDCodec.write(normal)
        try exportInteropFixture(normal, name: "safe-normal-soft-base")
        // The known Adobe default is grouped clipping. Explicit false, unknown
        // booleans and malformed padding must not be reinterpreted as that default.
        for payload in [Data([0, 0, 0, 0]), Data([2, 0, 0, 0]), Data([1, 0, 1, 0]), Data([1])] {
            base.extra = [("clbl", payload)]
            XCTAssertThrowsError(try PSDCodec.read(fixture(layers: [base, child])))
        }
        base.extra = [("clbl", Data([1, 0, 0, 0]))]
        XCTAssertNoThrow(try PSDCodec.read(fixture(layers: [base, child])))
    }

    func testOrthogonalBoundsSnapIntegerNoiseWithoutRoundingRealSubpixelsOrRejecting4096Edges() throws {
        let context = try RasterImage.context(width: 4096, height: 1)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 0.5)); context.fill(CGRect(x: 0, y: 0, width: 4096, height: 1))
        let pixels = try RasterImage.png(XCTUnwrap(context.makeImage()))
        let maskContext = try RasterImage.context(width: 4096, height: 1, gray: true)
        maskContext.setFillColor(gray: 0.5, alpha: 1); maskContext.fill(CGRect(x: 0, y: 0, width: 4096, height: 1))
        let mask = try RasterImage.png(XCTUnwrap(maskContext.makeImage()))
        // Only a 4096-by-one row: about 20 KiB of decoded color + mask, not a large canvas.
        for angle: CGFloat in [0, 90, 180, 270] {
            let vertical = angle == 90 || angle == 270
            let origin = vertical ? CGPoint(x: -0.5, y: -0.5) : .zero
            let transform = LayerTransform(origin: origin, size: CGSize(width: 4096, height: 1), rotation: angle, sampling: .nearest)
            let layer = RasterLayer(name: "Limit row", pngData: pixels, transform: transform, maskPNGData: mask)
            let bounds = try PSDCodec.exportBounds(layer)
            XCTAssertEqual(bounds, vertical ? CGRect(x: 2047, y: -2048, width: 1, height: 4096) : CGRect(x: 0, y: 0, width: 4096, height: 1))
            let document = CanvasDocument(width: 4, height: 4, layers: [layer], activeLayerID: layer.id)
            let decoded = try PSDCodec.read(PSDCodec.write(document))
            XCTAssertEqual(decoded.layers[0].transform.origin, bounds.origin)
            XCTAssertEqual(decoded.layers[0].transform.size, bounds.size)
            try exportInteropFixture(document, name: "standard-limit-row-\(Int(angle))")
        }
        let small = try XCTUnwrap(PSDCodec.read(fixture(layers: [LayerFixture()])).layers.first)
        var fractional = small; fractional.transform.origin = CGPoint(x: 2.25, y: 1.25)
        XCTAssertEqual(try PSDCodec.exportBounds(fractional), CGRect(x: 2, y: 1, width: 3, height: 3))
    }

    func testGroupRasterPayloadsRejectDuringMetadataParsingBeforeAnyChannelDecode() throws {
        var openTag = Bytes(); openTag.long(1)
        var closeTag = Bytes(); closeTag.long(3)
        let expected = PSDFileError.unsupported("图层组记录包含像素通道数据或蒙版")
        // A truncated PackBits payload would fail in the channel decoder. The
        // unsupported-group error instead proves metadata rejected it first.
        var rasterGroup = LayerFixture(name: "RLE group", blend: "pass")
        rasterGroup.extra = [("lsct", openTag.data)]
        rasterGroup.channelOverride = Data([0, 1, 0, 4])
        XCTAssertThrowsError(try PSDCodec.read(fixture(layers: [rasterGroup]))) { error in
            XCTAssertEqual(error as? PSDFileError, expected)
        }
        rasterGroup.channelOverride = nil; rasterGroup.rle = true
        XCTAssertThrowsError(try PSDCodec.read(fixture(layers: [rasterGroup]))) { error in
            XCTAssertEqual(error as? PSDFileError, expected)
        }
        // Even empty bounds may not hide channel data. Also poison an earlier
        // ordinary layer: no channel can be decoded before all records validate.
        var priorLayer = LayerFixture(); priorLayer.channelOverride = Data([0, 1])
        var emptyGroup = LayerFixture(name: "Empty", width: 0, height: 0, pixels: [], blend: "pass")
        emptyGroup.extra = [("lsct", closeTag.data)]
        emptyGroup.channelOverride = Data([0, 1, 255])
        XCTAssertThrowsError(try PSDCodec.read(fixture(layers: [priorLayer, emptyGroup]))) { error in
            XCTAssertEqual(error as? PSDFileError, expected)
        }
        // Photoshop-style zero-sized group records, with empty raw or PackBits
        // channel headers, remain compatible around an ordinary child layer.
        var open = LayerFixture(name: "Group", width: 0, height: 0, pixels: [], blend: "pass")
        open.extra = [("lsct", openTag.data)]
        var close = open; close.name = "End"; close.extra = [("lsct", closeTag.data)]; close.rle = true
        let document = try PSDCodec.read(fixture(layers: [close, LayerFixture(name: "Child"), open]))
        XCTAssertEqual(document.layers.count, 2)
        XCTAssertTrue(document.layers[0].isGroup); XCTAssertEqual(document.layers[1].parentID, document.layers[0].id)
    }

    func testGroupBoundingBoxesAreMetadataAndEmptyChannelsNeverDecodeAsPixels() throws {
        var openTag = Bytes(); openTag.long(1)
        var closeTag = Bytes(); closeTag.long(3)
        // The group box deliberately exceeds raster limits. It must neither
        // allocate that many pixels nor replace any child's document geometry.
        var open = LayerFixture(name: "Bounds only", x: -10_000, y: -20_000, width: 30_000, height: 50_000, pixels: [], blend: "pass")
        open.extra = [("lsct", openTag.data)]
        var close = open; close.name = "End"; close.extra = [("lsct", closeTag.data)]
        let child = LayerFixture(name: "Child", x: -1, y: 1)
        for channels in [[], [0, 1, 2, -1]] {
            for compression: UInt8 in [0, 1] {
                open.channelIDs = channels; close.channelIDs = channels
                open.channelOverride = Data([0, compression]); close.channelOverride = Data([0, compression])
                let document = try PSDCodec.read(fixture(layers: [close, child, open], width: 4, height: 4))
                XCTAssertEqual(document.layers.count, 2); XCTAssertTrue(document.layers[0].isGroup)
                XCTAssertEqual(document.layers[0].transform, LayerTransform(size: CGSize(width: 4, height: 4)))
                XCTAssertEqual(document.layers[1].parentID, document.layers[0].id)
                XCTAssertEqual(document.layers[1].transform.origin, CGPoint(x: -1, y: 1))
                XCTAssertEqual(document.layers[1].transform.size, CGSize(width: 2, height: 2))
                let reference = try PSDCodec.read(fixture(layers: [child], width: 4, height: 4))
                try assertImages(DocumentRenderer().render(document), DocumentRenderer().render(reference))
            }
        }
        // A two-byte ZIP/unknown header is still invalid. Poison an earlier
        // ordinary channel to prove group header validation runs before decodes.
        var prior = LayerFixture(); prior.channelOverride = Data([0, 1])
        open.channelOverride = Data([0, 2]); open.channelIDs = [0]
        XCTAssertThrowsError(try PSDCodec.read(fixture(layers: [prior, open]))) { error in
            XCTAssertEqual(error as? PSDFileError, .unsupported("组空通道压缩方式"))
        }
        open.channelOverride = Data([0, 255])
        XCTAssertThrowsError(try PSDCodec.read(fixture(layers: [prior, open]))) { error in
            XCTAssertEqual(error as? PSDFileError, .unsupported("组空通道压缩方式"))
        }
    }

    func testStrictUnknownFeaturesInvalidDepthAndTruncationsReject() throws {
        var unknown = LayerFixture(); unknown.extra = [("TySh", Data(repeating: 0, count: 8))]
        XCTAssertThrowsError(try PSDCodec.read(fixture(layers: [unknown])))
        let good = fixture(layers: [LayerFixture()])
        for count in stride(from: 0, to: good.count, by: 3) { XCTAssertThrowsError(try PSDCodec.read(good.prefix(count))) }
        var deep = good; deep[22] = 0; deep[23] = 16
        XCTAssertThrowsError(try PSDCodec.read(deep))
        var psb = good; psb[5] = 2; XCTAssertThrowsError(try PSDCodec.read(psb))
        var corrupt = good; corrupt[34] = 127; corrupt[35] = 255; XCTAssertThrowsError(try PSDCodec.read(corrupt))
        XCTAssertThrowsError(try PSDChannelCodec.decode(Data([0, 1, 0, 2, 254, 2]), width: 2, height: 1))
        XCTAssertThrowsError(try PSDChannelCodec.decode(Data([0, 0, 255, 0]), width: 1, height: 1))
        XCTAssertThrowsError(try PSDChannelCodec.decode(Data([0, 2]), width: 1, height: 1))
    }

    func testUnsupportedNativeRecordsRejectWithoutChangingSource() throws {
        var document = try PSDCodec.read(fixture(layers: [LayerFixture()]))
        let original = document
        var adjustment = RasterLayer(name: "Levels", transform: LayerTransform(size: document.size))
        adjustment.adjustment = LayerAdjustment(kind: .levels)
        document.layers.append(adjustment)
        XCTAssertThrowsError(try PSDCodec.write(document)); XCTAssertEqual(document.layers.dropLast(), original.layers[...])
        var group = RasterLayer(name: "Masked Group", transform: LayerTransform(size: original.size), isGroup: true)
        group.maskPNGData = try RasterImage.png(RasterImage.solidMask(width: 2, height: 2, white: true))
        document = original; document.layers.append(group)
        XCTAssertThrowsError(try PSDCodec.write(document))
        document = original; document.guides = [CanvasGuide(axis: .horizontal, position: 0.1)]
        XCTAssertThrowsError(try PSDCodec.write(document))
    }

    func testRGBICCIsReadAndInvalidICCRejects() throws {
        let profile = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3)?.copyICCData()) as Data
        var layer = LayerFixture(); layer.pixels = Array(repeating: [128, 64, 32, 255], count: 4)
        let data = fixture(layers: [layer], resources: [(1039, profile)])
        let document = try PSDCodec.read(data)
        let image = try RasterImage.decode(try XCTUnwrap(document.layers[0].pngData))
        XCTAssertEqual(image.colorSpace?.model, .rgb)
        XCTAssertEqual(image.width, 2)
        let untagged = try PSDCodec.read(fixture(layers: [layer]))
        let untaggedImage = try RasterImage.decode(XCTUnwrap(untagged.layers[0].pngData))
        XCTAssertNotEqual(try rgba(image), try rgba(untaggedImage), "An embedded P3 profile must affect sRGB conversion")
        let roundTrip = try PSDCodec.read(PSDCodec.write(document))
        try assertImages(DocumentRenderer().render(document), DocumentRenderer().render(roundTrip))
        XCTAssertThrowsError(try PSDCodec.read(fixture(layers: [LayerFixture()], resources: [(1039, Data("broken profile".utf8))])))
    }
}
