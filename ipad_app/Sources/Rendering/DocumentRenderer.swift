import Foundation
import CoreGraphics
import CoreImage

final class DocumentRenderer {
    private enum MaskReplacement {
        case original
        case replacement(CGImage?)
    }

    private var images: [UUID: (Data, CGImage)] = [:]
    private var masks: [UUID: (Data, CGImage)] = [:]
    private let ciContext = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

    func image(for layer: RasterLayer) throws -> CGImage? {
        guard let data = layer.pngData else { return nil }
        if let hit = images[layer.id], hit.0 == data { return hit.1 }
        let image = try RasterImage.decode(data)
        images[layer.id] = (data, image)
        return image
    }
    func clearCache() { images.removeAll(); masks.removeAll() }
    func pixelSize(of layer: RasterLayer) throws -> CGSize {
        if let image = try image(for: layer) { return CGSize(width: image.width, height: image.height) }
        return CGSize(width: max(1, Int(layer.transform.size.width)), height: max(1, Int(layer.transform.size.height)))
    }
    func pixelToDocument(_ layer: RasterLayer, size: CGSize) -> CGAffineTransform {
        let t = layer.transform
        return CGAffineTransform(translationX: t.center.x, y: t.center.y)
            .rotated(by: t.radians)
            .scaledBy(x: t.size.width / size.width * (t.flipX ? -1 : 1),
                      y: t.size.height / size.height * (t.flipY ? -1 : 1))
            .translatedBy(x: -size.width / 2, y: -size.height / 2)
    }
    func localSelection(_ mask: CGImage?, layer: RasterLayer, document: CanvasDocument) throws -> CGImage? {
        guard let mask else { return nil }
        let size = try pixelSize(of: layer)
        let context = try RasterImage.context(width: Int(size.width), height: Int(size.height), gray: true)
        context.concatenate(pixelToDocument(layer, size: size).inverted())
        RasterImage.draw(mask, in: CGRect(origin: .zero, size: document.size), context: context)
        return context.makeImage()
    }
    func render(_ document: CanvasDocument, replacing layerID: UUID? = nil, with replacement: CGImage? = nil) throws -> CGImage {
        try render(document, replacing: layerID, with: replacement, maskReplacement: .original)
    }

    /// An explicit mask replacement belongs to the temporary image's geometry.
    /// Passing nil here removes the mask for this preview; omitting this argument
    /// uses the original mask through the overload above. The temporary mask
    /// never enters the original layer's decoded mask cache.
    func render(_ document: CanvasDocument, replacing layerID: UUID, with replacement: CGImage,
                replacementMask: CGImage?) throws -> CGImage {
        try render(document, replacing: layerID, with: replacement, maskReplacement: .replacement(replacementMask))
    }

    private func render(_ document: CanvasDocument, replacing layerID: UUID?, with replacement: CGImage?,
                        maskReplacement: MaskReplacement) throws -> CGImage {
        let context = try RasterImage.context(width: document.width, height: document.height)
        for entry in document.renderLayers {
            let layer = entry.layer
            guard let image = layer.id == layerID ? replacement : try self.image(for: layer) else { continue }
            context.saveGState()
            context.setAlpha(entry.effectiveOpacity)
            context.setBlendMode(layer.blendMode.cgMode)
            try drawLayer(layer, image: image, context: context,
                          maskReplacement: layer.id == layerID ? maskReplacement : .original)
            context.restoreGState()
        }
        let ids = Set(document.layers.map(\.id))
        images = images.filter { ids.contains($0.key) }; masks = masks.filter { ids.contains($0.key) }
        guard let image = context.makeImage() else { throw RasterError.allocation }
        return image
    }
    func drawLayer(_ layer: RasterLayer, image: CGImage, context: CGContext) throws {
        try drawLayer(layer, image: image, context: context, maskReplacement: .original)
    }

    private func drawLayer(_ layer: RasterLayer, image: CGImage, context: CGContext,
                           maskReplacement: MaskReplacement) throws {
        let transform = layer.transform
        context.translateBy(x: transform.center.x, y: transform.center.y)
        context.rotate(by: transform.radians)
        context.scaleBy(x: transform.flipX ? -1 : 1, y: transform.flipY ? -1 : 1)
        let rect = CGRect(x: -transform.size.width / 2, y: -transform.size.height / 2,
                          width: transform.size.width, height: transform.size.height)
        context.interpolationQuality = transform.sampling.quality
        if layer.maskEnabled {
            let mask: CGImage?
            switch maskReplacement {
            case .replacement(let replacement):
                mask = replacement
            case .original:
                if let data = layer.maskPNGData {
                    if let hit = masks[layer.id], hit.0 == data { mask = hit.1 }
                    else {
                        let decoded = try RasterImage.decode(data)
                        masks[layer.id] = (data, decoded)
                        mask = decoded
                    }
                } else { mask = nil }
            }
            if let mask { RasterImage.clip(mask, to: rect, context: context) }
        }
        RasterImage.draw(image, in: rect, context: context)
    }
    func layerOnCanvas(_ layer: RasterLayer, document: CanvasDocument) throws -> CGImage {
        let context = try RasterImage.context(width: document.width, height: document.height)
        if let image = try image(for: layer) { try drawLayer(layer, image: image, context: context) }
        guard let image = context.makeImage() else { throw RasterError.allocation }
        return image
    }

    /// Canvas growth pads each raster in its own pixel grid. Existing pixels are neither
    /// resampled nor flattened with their mask; the caller commits the whole resize once.
    func resizeCanvas(_ document: inout CanvasDocument, width: Int, height: Int, resample: Bool) throws {
        guard width > 0, height > 0, width <= 4096, height <= 4096,
              width * height <= 16_000_000 else { throw RasterError.oversized }
        guard width != document.width || height != document.height else { return }
        if resample {
            let x = CGFloat(width) / CGFloat(document.width), y = CGFloat(height) / CGFloat(document.height)
            if abs(x - y) > 0.000001 && document.layers.contains(where: { abs($0.transform.rotation.truncatingRemainder(dividingBy: 180)) > 0.000001 }) {
                throw DocumentError.unsupported("旋转图层暂不支持非等比例图像缩放，请保持宽高比例")
            }
            for i in document.layers.indices {
                document.layers[i].transform.origin.x *= x; document.layers[i].transform.origin.y *= y
                document.layers[i].transform.size.width *= x; document.layers[i].transform.size.height *= y
            }
        } else if width > document.width || height > document.height {
            // Plan all allocations first so an unsupported layer leaves the transaction intact.
            let canvas = CGSize(width: width, height: height)
            let plans = try document.layers.map { try expansionPlan($0, canvas: canvas) }
            var pixels = 0, maskPixels = 0
            for (layer, plan) in zip(document.layers, plans) where !layer.isGroup {
                let size = try pixelSize(of: layer)
                pixels += plan.map { Int($0.bounds.width * $0.bounds.height) } ?? Int(size.width * size.height)
                if let plan, let mask = plan.maskSize { maskPixels += Int(mask.width * mask.height) }
                else if let data = layer.maskPNGData { let size = try PNGAsset.inspect(data); maskPixels += size.width * size.height }
            }
            guard pixels <= 100_000_000, maskPixels <= 100_000_000 else { throw DocumentError.tooLarge }
            for i in document.layers.indices {
                if let plan = plans[i] { document.layers[i] = try expanded(document.layers[i], plan: plan) }
            }
        }
        document.width = width; document.height = height
        document.selectionMaskPNGData = nil
    }

    private struct ExpansionPlan {
        let oldSize: CGSize
        let bounds: CGRect
        let transform: LayerTransform
        let maskSize: CGSize?
    }

    private func expansionPlan(_ layer: RasterLayer, canvas: CGSize) throws -> ExpansionPlan? {
        guard !layer.isGroup else { return nil }
        let size = try pixelSize(of: layer), mapping = pixelToDocument(layer, size: size)
        let corners = [CGPoint.zero, CGPoint(x: canvas.width, y: 0),
                       CGPoint(x: 0, y: canvas.height), CGPoint(x: canvas.width, y: canvas.height)]
            .map { $0.applying(mapping.inverted()) }
        let mask = try layer.maskPNGData.map { try PNGAsset.inspect($0, requireGrayscale: true) }
        func gcd(_ a: Int, _ b: Int) -> Int { var a = a, b = b; while b != 0 { (a, b) = (b, a % b) }; return a }
        // Align both grids for masks whose resolution differs from the raster. This keeps
        // their original samples and soft edges intact without stretching or interpolation.
        let stepX = mask.map { Int(size.width) / gcd(Int(size.width), $0.width) } ?? 1
        let stepY = mask.map { Int(size.height) / gcd(Int(size.height), $0.height) } ?? 1
        func aligned(_ value: CGFloat, step: Int, up: Bool) -> CGFloat {
            let value = value / CGFloat(step)
            let exact = abs(value - value.rounded()) < 0.0000001 ? value.rounded() : value
            return (up ? ceil(exact) : floor(exact)) * CGFloat(step)
        }
        let x = aligned(min(0, corners.map(\.x).min()!), step: stepX, up: false)
        let y = aligned(min(0, corners.map(\.y).min()!), step: stepY, up: false)
        let right = aligned(max(size.width, corners.map(\.x).max()!), step: stepX, up: true)
        let bottom = aligned(max(size.height, corners.map(\.y).max()!), step: stepY, up: true)
        let bounds = CGRect(x: x, y: y, width: right - x, height: bottom - y)
        guard bounds != CGRect(origin: .zero, size: size) else { return nil }
        if layer.pngData != nil || mask != nil {
            // Extending a texture changes its edge-clamp samples. Arbitrary rotation also
            // moves Core Graphics' antialiased outer boundary into the texture interior.
            // Until those sampling domains can be represented separately, reject such
            // growth rather than fading old pixels or revealing masked content.
            func near(_ a: CGFloat, _ b: CGFloat = 0) -> Bool { abs(a - b) < 0.0000001 }
            let axisAligned = (near(mapping.b) && near(mapping.c)) || (near(mapping.a) && near(mapping.d))
            let oldCorners = [CGPoint.zero, CGPoint(x: size.width, y: 0),
                              CGPoint(x: 0, y: size.height), CGPoint(x: size.width, y: size.height)]
                .map { $0.applying(mapping) }
            let integerEdges = oldCorners.allSatisfy { near($0.x, $0.x.rounded()) && near($0.y, $0.y.rounded()) }
            let scaleX = hypot(mapping.a, mapping.b), scaleY = hypot(mapping.c, mapping.d)
            let rasterExact = layer.pngData == nil || (near(scaleX, 1) && near(scaleY, 1))
            let maskExact = mask.map { near(scaleX * size.width / CGFloat($0.width), 1)
                && near(scaleY * size.height / CGFloat($0.height), 1) } ?? true
            guard axisAligned, integerEdges,
                  layer.transform.sampling == .nearest || (rasterExact && maskExact) else {
                throw DocumentError.unsupported("图层变换或蒙版采样暂不支持无损扩展画布；请先恢复图层原始像素大小、整像素位置和直角旋转后重试")
            }
        }
        func check(_ size: CGSize) throws {
            guard size.width.isFinite, size.height.isFinite, size.width >= 1, size.height >= 1,
                  size.width <= 4096, size.height <= 4096, size.width * size.height <= 16_000_000 else { throw RasterError.oversized }
        }
        try check(bounds.size)
        let maskSize = mask.map { CGSize(width: Int(bounds.width) / stepX * ($0.width / gcd(Int(size.width), $0.width)),
                                         height: Int(bounds.height) / stepY * ($0.height / gcd(Int(size.height), $0.height))) }
        if let maskSize { try check(maskSize) }
        var transform = layer.transform
        let center = CGPoint(x: bounds.midX, y: bounds.midY).applying(mapping)
        transform.size = CGSize(width: transform.size.width * bounds.width / size.width,
                                height: transform.size.height * bounds.height / size.height)
        transform.origin = CGPoint(x: center.x - transform.size.width / 2, y: center.y - transform.size.height / 2)
        guard transform.isValid else { throw DocumentError.invalid("扩展后的图层几何无效") }
        return ExpansionPlan(oldSize: size, bounds: bounds, transform: transform, maskSize: maskSize)
    }

    private func expanded(_ layer: RasterLayer, plan: ExpansionPlan) throws -> RasterLayer {
        var result = layer
        let context = try RasterImage.context(width: Int(plan.bounds.width), height: Int(plan.bounds.height))
        context.interpolationQuality = .none; context.setBlendMode(.copy)
        if let source = try image(for: layer) {
            RasterImage.draw(source, in: CGRect(origin: CGPoint(x: -plan.bounds.minX, y: -plan.bounds.minY), size: plan.oldSize), context: context)
        }
        guard let image = context.makeImage() else { throw RasterError.allocation }
        result.pngData = try RasterImage.png(image)
        if let data = layer.maskPNGData, let size = plan.maskSize {
            let source = try RasterImage.decode(data)
            guard source.bitsPerPixel == 8, source.bitsPerComponent == 8, source.alphaInfo == .none,
                  let raw = source.dataProvider?.data, let bytes = CFDataGetBytePtr(raw),
                  CFDataGetLength(raw) >= source.bytesPerRow * source.height else { throw RasterError.invalidImage }
            let mask = try RasterImage.context(width: Int(size.width), height: Int(size.height), gray: true)
            guard let target = mask.data else { throw RasterError.allocation }
            // New coverage is white so newly available canvas can be painted. Existing
            // hidden pixels remain hidden, including when the mask is currently disabled.
            memset(target, 255, mask.bytesPerRow * mask.height)
            let x = Int((-plan.bounds.minX * CGFloat(source.width) / plan.oldSize.width).rounded())
            let y = Int((-plan.bounds.minY * CGFloat(source.height) / plan.oldSize.height).rounded())
            for row in 0..<source.height {
                memcpy(target.advanced(by: (row + y) * mask.bytesPerRow + x), bytes.advanced(by: row * source.bytesPerRow), source.width)
            }
            guard let image = mask.makeImage() else { throw RasterError.allocation }
            result.maskPNGData = try RasterImage.png(image)
        }
        result.transform = plan.transform
        return result
    }
    func adjusted(_ image: CGImage, brightness: Double, contrast: Double, saturation: Double, blur: Double) throws -> CGImage {
        let source = CIImage(cgImage: image)
        var output = source.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: brightness,
                                                                            kCIInputContrastKey: contrast,
                                                                            kCIInputSaturationKey: saturation])
        if blur > 0 { output = output.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blur]).cropped(to: source.extent) }
        guard let result = ciContext.createCGImage(output, from: source.extent, format: .RGBA8,
                                                  colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { throw RasterError.allocation }
        return result
    }
}
