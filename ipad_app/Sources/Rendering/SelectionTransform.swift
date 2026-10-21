// Adapted from Compositor Document/FloatingSelection.swift and BrushStroke.swift.
// Copyright (c) 2026 Wonder Assembly LLC. MIT; see licenses/Compositor-MIT.txt.
// Upstream: 7c2a5a4a3e7f685a8a0ec282ef0b4284f20b5477.
// iPad: frozen raster selection, numeric gray sampling, and alpha-preserving soft overlap.
import Foundation
import CoreGraphics

struct SelectionTransformResult {
    let image: CGImage
    let transform: LayerTransform
    let mask: CGImage?
    let selection: CGImage
    /// The current layer's displayed scale/rotation was sampled once onto document pixels.
    let rasterized: Bool

    init(image: CGImage, transform: LayerTransform, mask: CGImage?, selection: CGImage, rasterized: Bool = false) {
        self.image = image; self.transform = transform; self.mask = mask; self.selection = selection
        self.rasterized = rasterized
    }
}

/// A frozen selected-pixel edit. Preview never mutates the source document, encodes PNG,
/// applies the layer's opacity/blend mode, or bakes its separate linked mask into the pixels.
final class SelectionTransformSource {
    /// The nonzero selection's document-space bounds, used by ordinary transform handles.
    let original: LayerTransform
    private let layer: RasterLayer
    private let sourceImage: CGImage
    private let remaining: [UInt8]
    private let lifted: [UInt8]
    private let liftedBounds: CGRect
    private let selectionImage: CGImage
    private let selectionPixels: [UInt8]
    private let layerMask: CGImage?
    private let maskPixels: [UInt8]?
    private let toDocument: CGAffineTransform
    private let nearest: Bool
    private var cachedRegriddedSource: SelectionTransformSource?
    private enum ExpansionRequirement: Error { case regrid }

    convenience init(document: CanvasDocument, layer: RasterLayer, renderer: DocumentRenderer) throws {
        guard !layer.isGroup, layer.transform.isValid,
              document.layers.contains(where: { $0 == layer }) else { throw DocumentError.invalid("选区变换的图层无效") }
        guard !document.isEffectivelyLocked(layer.id) else { throw DocumentError.lockedLayer }
        guard let selectionData = document.selectionMaskPNGData else { throw DocumentError.invalid("请先创建选区") }
        let selection = try RasterImage.decode(selectionData)
        guard selection.width == document.width, selection.height == document.height else {
            throw DocumentError.invalid("选区尺寸与画布不一致")
        }
        guard let image = try renderer.image(for: layer) else { throw DocumentError.invalid("这个图层还没有内容") }
        try self.init(layer: layer, image: image, mask: layer.maskPNGData.map(RasterImage.decode), selection: selection)
    }

    /// Decoded sources keep the one-time document-grid fallback out of PNG encoding.
    private init(layer: RasterLayer, image: CGImage, mask: CGImage?, selection: CGImage,
                 handleBox: LayerTransform? = nil) throws {
        let gray = try Self.grayBytes(selection)
        guard let bounds = Self.nonzeroBounds(gray, width: selection.width, height: selection.height, stride: 1, channel: 0) else {
            throw DocumentError.invalid("选区为空，无法变换")
        }
        let pixels = try Self.rgbaBytes(image)
        let mapping = Self.placement(layer.transform, size: CGSize(width: image.width, height: image.height))
        guard Self.valid(mapping), Self.valid(mapping.inverted()) else { throw DocumentError.invalid("图层变换不可逆") }
        let nearest = layer.transform.sampling == .nearest
        var cut = [UInt8](repeating: 0, count: pixels.count)
        for y in 0..<image.height { for x in 0..<image.width {
            let point = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5).applying(mapping)
            let amount = Int(Self.graySample(gray, width: selection.width, height: selection.height, at: point, nearest: nearest).rounded())
            let offset = (y * image.width + x) * 4
            // Integer complements make a soft cut exactly reversible before any spatial resampling.
            for channel in 0..<4 { cut[offset + channel] = UInt8((Int(pixels[offset + channel]) * amount + 127) / 255) }
        } }
        guard let selectedPixels = Self.nonzeroBounds(cut, width: image.width, height: image.height, stride: 4, channel: 3) else {
            throw DocumentError.invalid("当前图层的选区内没有可变换像素")
        }
        self.layer = layer
        sourceImage = image; lifted = cut
        remaining = zip(pixels, cut).map { $0 - $1 }
        // Bilinear interpolation reads an adjacent zero texel at an internal cut edge.
        // Include that support in the allocation, never silently clip a transformed soft edge.
        liftedBounds = nearest ? selectedPixels : selectedPixels.insetBy(dx: -1, dy: -1)
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        selectionImage = selection; selectionPixels = gray
        layerMask = mask; maskPixels = try mask.map(Self.grayBytes)
        toDocument = mapping; self.nearest = nearest
        original = handleBox ?? LayerTransform(origin: bounds.origin, size: bounds.size, sampling: layer.transform.sampling)
    }

    func preview(_ transform: LayerTransform) throws -> SelectionTransformResult {
        guard transform.isValid else { throw DocumentError.invalid("选区变换参数无效") }
        if transform == original {
            return SelectionTransformResult(image: sourceImage, transform: layer.transform, mask: layerMask, selection: selectionImage)
        }
        // Once the preview needs a document-grid source, retain that same frozen source
        // for all later nonidentity previews, including dragging back inside the old bounds.
        // Returning to identity still restores the original native image and mask above.
        if let source = cachedRegriddedSource { return try regriddedPreview(transform, source: source) }
        let from = Self.placement(original, size: original.size)
        let to = Self.placement(transform, size: original.size)
        // CGPoint applies concatenations left to right: document T, then native A^-1 T A.
        let documentMap = from.inverted().concatenating(to)
        let nativeMap = toDocument.concatenating(documentMap).concatenating(toDocument.inverted())
        guard Self.valid(documentMap), Self.valid(documentMap.inverted()),
              Self.valid(nativeMap), Self.valid(nativeMap.inverted()) else { throw DocumentError.invalid("选区变换不可逆") }
        let movedBounds = try Self.bounds(liftedBounds, applying: nativeMap)
        let extent: CGRect
        do { extent = try expandedExtent(including: movedBounds) }
        catch ExpansionRequirement.regrid {
            let regridded = try LayerRegrid.prepare(layer: layer, image: sourceImage, mask: layerMask)
            var projectedLayer = layer
            projectedLayer.transform = regridded.transform
            let source = try SelectionTransformSource(layer: projectedLayer, image: regridded.image,
                mask: regridded.mask, selection: selectionImage, handleBox: original)
            let result = try regriddedPreview(transform, source: source)
            // A failed allocation or out-of-range preview must not change this session's
            // behavior. Cache only after the first fallback preview succeeds.
            cachedRegriddedSource = source
            return result
        }
        let width = Int(extent.width), height = Int(extent.height)
        let shiftX = -Int(extent.minX), shiftY = -Int(extent.minY)
        let expandedTransform = try transformForExtent(extent)
        // Keep the cut complement frozen too: dragging pays one copy-on-write buffer
        // copy, not a full-canvas, four-channel subtraction on every input event.
        var output: [UInt8]
        if width == sourceImage.width, height == sourceImage.height {
            output = remaining
        } else {
            output = [UInt8](repeating: 0, count: width * height * 4)
            for y in 0..<sourceImage.height {
                let source = y * sourceImage.width * 4, target = ((y + shiftY) * width + shiftX) * 4
                output.replaceSubrange(target..<target + sourceImage.width * 4,
                                       with: remaining[source..<source + sourceImage.width * 4])
            }
        }
        let inverse = nativeMap.inverted()
        let affected = movedBounds.integral.intersection(extent)
        if !affected.isNull, !affected.isEmpty {
            for y in Int(affected.minY)..<Int(affected.maxY) { for x in Int(affected.minX)..<Int(affected.maxX) {
                let sample = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5).applying(inverse)
                let floating = Self.rgbaSample(lifted, width: sourceImage.width, height: sourceImage.height, at: sample, nearest: nearest)
                guard floating.3 > 0 else { continue }
                let removed: Double
                if x >= 0, y >= 0, x < sourceImage.width, y < sourceImage.height {
                    removed = Double(lifted[(y * sourceImage.width + x) * 4 + 3])
                } else { removed = 0 }
                let target = ((y + shiftY) * width + x + shiftX) * 4
                // Upstream source-over dims overlapping soft cuts: with A=1 and S=.5,
                // .5 over .5 yields .75. First refill the alpha removed at this location;
                // any excess has ordinary source-over behavior. At identity F + H = P;
                // where no alpha was removed, k = 1-Fa. Premultiplied RGB stays <= alpha.
                let factor = removed >= 255 ? 0 : min(1, (255 - floating.3) / (255 - removed))
                output[target] = Self.byte(floating.0 + factor * Double(output[target]))
                output[target + 1] = Self.byte(floating.1 + factor * Double(output[target + 1]))
                output[target + 2] = Self.byte(floating.2 + factor * Double(output[target + 2]))
                output[target + 3] = Self.byte(floating.3 + factor * Double(output[target + 3]))
            } }
        }
        return SelectionTransformResult(image: try Self.rgbaImage(output, width: width, height: height),
            transform: expandedTransform, mask: try expandedMask(extent), selection: try movedSelection(documentMap))
    }

    private func regriddedPreview(_ transform: LayerTransform, source: SelectionTransformSource) throws -> SelectionTransformResult {
        let result = try source.preview(transform)
        return SelectionTransformResult(image: result.image, transform: result.transform, mask: result.mask,
                                        selection: result.selection, rasterized: true)
    }

    private func movedSelection(_ mapping: CGAffineTransform) throws -> CGImage {
        let width = selectionImage.width, height = selectionImage.height
        var output = [UInt8](repeating: 0, count: width * height)
        // The stored numeric coverage moves once. No new feather or color conversion is applied.
        let support = nearest ? CGRect(origin: original.origin, size: original.size)
            : CGRect(origin: original.origin, size: original.size).insetBy(dx: -1, dy: -1)
                .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        let affected = try Self.bounds(support, applying: mapping).integral
            .intersection(CGRect(x: 0, y: 0, width: width, height: height))
        let inverse = mapping.inverted()
        if !affected.isNull, !affected.isEmpty {
            for y in Int(affected.minY)..<Int(affected.maxY) { for x in Int(affected.minX)..<Int(affected.maxX) {
                let source = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5).applying(inverse)
                output[y * width + x] = Self.byte(Self.graySample(selectionPixels, width: width, height: height, at: source, nearest: nearest))
            } }
        }
        return try Self.grayImage(output, width: width, height: height)
    }

    private func expandedExtent(including moved: CGRect) throws -> CGRect {
        let old = CGRect(x: 0, y: 0, width: sourceImage.width, height: sourceImage.height)
        let needed = old.union(moved)
        func gcd(_ a: Int, _ b: Int) -> Int { var a = a, b = b; while b != 0 { (a, b) = (b, a % b) }; return a }
        let stepX = layerMask.map { sourceImage.width / gcd(sourceImage.width, $0.width) } ?? 1
        let stepY = layerMask.map { sourceImage.height / gcd(sourceImage.height, $0.height) } ?? 1
        func align(_ value: CGFloat, step: Int, up: Bool) -> CGFloat {
            let scaled = value / CGFloat(step)
            let exact = abs(scaled - scaled.rounded()) < 0.0000001 ? scaled.rounded() : scaled
            return (up ? ceil(exact) : floor(exact)) * CGFloat(step)
        }
        let left = align(needed.minX, step: stepX, up: false), top = align(needed.minY, step: stepY, up: false)
        let extent = CGRect(x: left, y: top, width: align(needed.maxX, step: stepX, up: true) - left,
                            height: align(needed.maxY, step: stepY, up: true) - top)
        if extent != old {
            // Same preservation boundary as DocumentRenderer.expansionPlan: padding changes
            // edge-clamp sampling and moves antialiased rotated bounds into the texture interior.
            func near(_ a: CGFloat, _ b: CGFloat = 0) -> Bool { abs(a - b) < 0.0000001 }
            let map = toDocument
            let axisAligned = (near(map.b) && near(map.c)) || (near(map.a) && near(map.d))
            let integerEdges = Self.corners(old).map { $0.applying(map) }
                .allSatisfy { near($0.x, $0.x.rounded()) && near($0.y, $0.y.rounded()) }
            let scaleX = hypot(map.a, map.b), scaleY = hypot(map.c, map.d)
            let rasterExact = near(scaleX, 1) && near(scaleY, 1)
            let maskExact = layerMask.map { near(scaleX * CGFloat(sourceImage.width) / CGFloat($0.width), 1)
                && near(scaleY * CGFloat(sourceImage.height) / CGFloat($0.height), 1) } ?? true
            guard axisAligned, integerEdges, nearest || (rasterExact && maskExact) else {
                // Transparent/white padding would change the old texture's edge clamps
                // and can reveal pixels hidden by a black mask. Resample the frozen layer
                // once at its existing document resolution instead of blocking the edit.
                throw ExpansionRequirement.regrid
            }
        }
        // Decide the sampling domain before checking native allocation size: an extremely
        // downscaled layer may need a huge native padding but a small document-grid raster.
        try Self.checkSize(extent.size)
        if let mask = layerMask {
            try Self.checkSize(CGSize(width: extent.width * CGFloat(mask.width) / CGFloat(sourceImage.width),
                                     height: extent.height * CGFloat(mask.height) / CGFloat(sourceImage.height)))
        }
        return extent
    }

    private func transformForExtent(_ extent: CGRect) throws -> LayerTransform {
        guard extent != CGRect(x: 0, y: 0, width: sourceImage.width, height: sourceImage.height) else { return layer.transform }
        var result = layer.transform
        result.size = CGSize(width: extent.width * layer.transform.size.width / CGFloat(sourceImage.width),
                             height: extent.height * layer.transform.size.height / CGFloat(sourceImage.height))
        let center = CGPoint(x: extent.midX, y: extent.midY).applying(toDocument)
        result.origin = CGPoint(x: center.x - result.size.width / 2, y: center.y - result.size.height / 2)
        guard result.isValid else { throw DocumentError.invalid("扩展后的图层几何无效") }
        return result
    }

    private func expandedMask(_ extent: CGRect) throws -> CGImage? {
        guard let mask = layerMask, let pixels = maskPixels else { return nil }
        guard extent != CGRect(x: 0, y: 0, width: sourceImage.width, height: sourceImage.height) else { return mask }
        let width = Int((extent.width * CGFloat(mask.width) / CGFloat(sourceImage.width)).rounded())
        let height = Int((extent.height * CGFloat(mask.height) / CGFloat(sourceImage.height)).rounded())
        let x = Int((-extent.minX * CGFloat(mask.width) / CGFloat(sourceImage.width)).rounded())
        let y = Int((-extent.minY * CGFloat(mask.height) / CGFloat(sourceImage.height)).rounded())
        var output = [UInt8](repeating: 255, count: width * height)
        // Even a disabled mask is retained exactly. It stays at its old document position,
        // with white only in newly allocated space; it does not follow the selected pixels.
        for row in 0..<mask.height {
            output.replaceSubrange((row + y) * width + x..<(row + y) * width + x + mask.width,
                                   with: pixels[row * mask.width..<(row + 1) * mask.width])
        }
        return try Self.grayImage(output, width: width, height: height)
    }

    private static func placement(_ transform: LayerTransform, size: CGSize) -> CGAffineTransform {
        CGAffineTransform(translationX: transform.center.x, y: transform.center.y)
            .rotated(by: transform.radians)
            .scaledBy(x: transform.size.width / size.width * (transform.flipX ? -1 : 1),
                      y: transform.size.height / size.height * (transform.flipY ? -1 : 1))
            .translatedBy(x: -size.width / 2, y: -size.height / 2)
    }

    private static func valid(_ map: CGAffineTransform) -> Bool {
        [map.a, map.b, map.c, map.d, map.tx, map.ty].allSatisfy(\.isFinite)
            && (map.a * map.d - map.b * map.c).isFinite && map.a * map.d - map.b * map.c != 0
    }

    private static func corners(_ rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
    }

    private static func bounds(_ rect: CGRect, applying map: CGAffineTransform) throws -> CGRect {
        let points = corners(rect).map { $0.applying(map) }
        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { throw DocumentError.invalid("选区变换范围无效") }
        let left = points.map(\.x).min()!, top = points.map(\.y).min()!
        let width = points.map(\.x).max()! - left, height = points.map(\.y).max()! - top
        guard width.isFinite, height.isFinite else { throw RasterError.oversized }
        return CGRect(x: left, y: top, width: width, height: height)
    }

    private static func checkSize(_ size: CGSize) throws {
        guard size.width.isFinite, size.height.isFinite, size.width >= 1, size.height >= 1,
              size.width <= 4096, size.height <= 4096, size.width * size.height <= 16_000_000 else { throw RasterError.oversized }
    }

    private static func nonzeroBounds(_ pixels: [UInt8], width: Int, height: Int, stride: Int, channel: Int) -> CGRect? {
        var left = width, top = height, right = -1, bottom = -1
        for y in 0..<height { for x in 0..<width where pixels[(y * width + x) * stride + channel] > 0 {
            left = min(left, x); top = min(top, y); right = max(right, x); bottom = max(bottom, y)
        } }
        guard right >= left, bottom >= top else { return nil }
        return CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
    }

    private static func rgbaBytes(_ image: CGImage) throws -> [UInt8] {
        let context = try RasterImage.context(width: image.width, height: image.height)
        context.setBlendMode(.copy); context.interpolationQuality = .none
        RasterImage.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), context: context)
        guard let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { throw RasterError.allocation }
        return (0..<image.height).flatMap { row in Array(UnsafeBufferPointer(start: bytes + row * context.bytesPerRow, count: image.width * 4)) }
    }

    private static func grayBytes(_ image: CGImage) throws -> [UInt8] {
        try checkSize(CGSize(width: image.width, height: image.height))
        guard image.bitsPerComponent == 8, image.bitsPerPixel == 8, image.alphaInfo == .none,
              image.colorSpace?.model == .monochrome, image.decode == nil, image.bytesPerRow >= image.width,
              let data = image.dataProvider?.data, CFDataGetLength(data) >= image.bytesPerRow * image.height,
              let bytes = CFDataGetBytePtr(data) else { throw DocumentError.invalid("选区与图层蒙版必须是 8 位灰度图") }
        return (0..<image.height).flatMap { row in Array(UnsafeBufferPointer(start: bytes + row * image.bytesPerRow, count: image.width)) }
    }

    private static func grayImage(_ pixels: [UInt8], width: Int, height: Int) throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw RasterError.allocation }
        return image
    }

    private static func rgbaImage(_ pixels: [UInt8], width: Int, height: Int) throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw RasterError.allocation }
        return image
    }

    private static func byte(_ value: Double) -> UInt8 { UInt8(min(255, max(0, value.rounded()))) }

    private static func graySample(_ pixels: [UInt8], width: Int, height: Int, at point: CGPoint, nearest: Bool) -> Double {
        guard point.x >= 0, point.y >= 0, point.x < CGFloat(width), point.y < CGFloat(height) else { return 0 }
        if nearest { return Double(pixels[Int(point.y) * width + Int(point.x)]) }
        let x = Double(point.x) - 0.5, y = Double(point.y) - 0.5
        let left = Int(floor(x)), top = Int(floor(y)), fx = x - floor(x), fy = y - floor(y)
        let x0 = max(0, left), x1 = min(width - 1, left + 1), y0 = max(0, top), y1 = min(height - 1, top + 1)
        return (Double(pixels[y0 * width + x0]) * (1 - fx) + Double(pixels[y0 * width + x1]) * fx) * (1 - fy)
            + (Double(pixels[y1 * width + x0]) * (1 - fx) + Double(pixels[y1 * width + x1]) * fx) * fy
    }

    private static func rgbaSample(_ pixels: [UInt8], width: Int, height: Int, at point: CGPoint, nearest: Bool) -> (Double, Double, Double, Double) {
        guard point.x >= 0, point.y >= 0, point.x < CGFloat(width), point.y < CGFloat(height) else { return (0, 0, 0, 0) }
        if nearest {
            let i = (Int(point.y) * width + Int(point.x)) * 4
            return (Double(pixels[i]), Double(pixels[i + 1]), Double(pixels[i + 2]), Double(pixels[i + 3]))
        }
        let x = Double(point.x) - 0.5, y = Double(point.y) - 0.5
        let left = Int(floor(x)), top = Int(floor(y)), fx = x - floor(x), fy = y - floor(y)
        let x0 = max(0, left), x1 = min(width - 1, left + 1), y0 = max(0, top), y1 = min(height - 1, top + 1)
        let a = (y0 * width + x0) * 4, b = (y0 * width + x1) * 4
        let c = (y1 * width + x0) * 4, d = (y1 * width + x1) * 4
        func value(_ channel: Int) -> Double {
            (Double(pixels[a + channel]) * (1 - fx) + Double(pixels[b + channel]) * fx) * (1 - fy)
                + (Double(pixels[c + channel]) * (1 - fx) + Double(pixels[d + channel]) * fx) * fy
        }
        return (value(0), value(1), value(2), value(3))
    }
}
