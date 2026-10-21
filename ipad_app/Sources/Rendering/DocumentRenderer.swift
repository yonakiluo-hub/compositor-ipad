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
    private let groupMaskWorkingByteLimit: Int

    init(groupMaskWorkingByteLimit: Int = GroupMaskRules.workingByteLimit) {
        self.groupMaskWorkingByteLimit = groupMaskWorkingByteLimit
    }

    func image(for layer: RasterLayer) throws -> CGImage? {
        guard let data = layer.pngData else { return nil }
        if let hit = images[layer.id], hit.0 == data { return hit.1 }
        let image = try RasterImage.decode(data)
        images[layer.id] = (data, image)
        return image
    }
    func clearCache() { images.removeAll(); masks.removeAll() }
    func pixelSize(of layer: RasterLayer) throws -> CGSize {
        if layer.isGroup, let data = layer.maskPNGData {
            let size = try PNGAsset.inspect(data, requireGrayscale: true)
            return CGSize(width: size.width, height: size.height)
        }
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
    func render(_ document: CanvasDocument, replacing layerID: UUID, with replacement: CGImage?,
                replacementMask: CGImage?) throws -> CGImage {
        try render(document, replacing: layerID, with: replacement, maskReplacement: .replacement(replacementMask))
    }

    private func render(_ document: CanvasDocument, replacing layerID: UUID?, with replacement: CGImage?,
                        maskReplacement: MaskReplacement) throws -> CGImage {
        let image = try composite(document.layers, bounds: CGRect(origin: .zero, size: document.size),
                                  replacing: layerID, with: replacement, maskReplacement: maskReplacement)
        let ids = Set(document.layers.map(\.id))
        images = images.filter { ids.contains($0.key) }; masks = masks.filter { ids.contains($0.key) }
        return image
    }

    /// Shared by the canvas, exports and full-bounds layer merges. A merge must
    /// use the same clipping-stack compositor instead of drawing each leaf alone.
    func render(layers: [RasterLayer], bounds: CGRect) throws -> CGImage {
        try composite(layers, bounds: bounds, replacing: nil, with: nil, maskReplacement: .original)
    }

    private func composite(_ layers: [RasterLayer], bounds: CGRect, replacing layerID: UUID?,
                           with replacement: CGImage?, maskReplacement: MaskReplacement) throws -> CGImage {
        try LayerHierarchy.validate(layers)
        try GroupMaskRules.validate(layers, bounds: bounds, limit: groupMaskWorkingByteLimit)
        let width = Int(bounds.width), height = Int(bounds.height)
        let context = try RasterImage.context(width: width, height: height)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        let entries = LayerHierarchy.entries(layers)
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.layer.id, $0) })
        let siblings = Dictionary(grouping: layers, by: \.parentID)
        let clipped = Dictionary(grouping: entries.filter { $0.layer.maskSourceID != nil }, by: { $0.layer.maskSourceID! })
        func drawOwn(_ entry: LayerHierarchyEntry, in target: CGContext, mode: LayerBlendMode? = nil) throws {
            let layer = entry.layer
            guard let image = layer.id == layerID ? replacement : try self.image(for: layer) else { return }
            target.saveGState()
            defer { target.restoreGState() }
            target.setAlpha(entry.effectiveOpacity)
            target.setBlendMode((mode ?? layer.blendMode).cgMode)
            try drawLayer(layer, image: image, context: target,
                          maskReplacement: layer.id == layerID ? maskReplacement : .original)
        }
        func drawStack(_ entry: LayerHierarchyEntry, in target: CGContext, bounds: CGRect) throws {
            let children = (clipped[entry.layer.id] ?? []).filter(\.isVisible)
            guard !children.isEmpty else { try drawOwn(entry, in: target); return }
            // Ported from Compositor LiveMaskRenderer and BrushPixels.c at
            // 7c2a5a4, MIT © 2026 Wonder Assembly LLC. Stack colors are composed
            // on an opaque base, then its original coverage is restored ONCE.
            // Source-over of individually clipped children would thicken soft
            // edges and apply base opacity/mask repeatedly.
            // Only the base can supply final coverage. Keep the surface on the
            // document's integer pixel grid and include an antialiasing margin;
            // small cropped layers do not allocate or scan the entire canvas.
            let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
                           CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)].map(entry.layer.transform.point)
            let x = corners.map(\.x).min()!, y = corners.map(\.y).min()!
            let quad = CGRect(x: x, y: y, width: corners.map(\.x).max()! - x,
                              height: corners.map(\.y).max()! - y)
            let region = quad.insetBy(dx: -2, dy: -2).integral.intersection(bounds)
            guard !region.isNull, !region.isEmpty else { return }
            let stackWidth = Int(region.width), stackHeight = Int(region.height)
            let stack = try RasterImage.context(width: stackWidth, height: stackHeight)
            stack.translateBy(x: -region.minX, y: -region.minY)
            try drawOwn(entry, in: stack, mode: .normal)
            guard let data = stack.data else { throw RasterError.allocation }
            let pixels = data.assumingMemoryBound(to: UInt8.self)
            var coverage = [UInt8](repeating: 0, count: stackWidth * stackHeight)
            for y in 0..<stackHeight {
                for x in 0..<stackWidth {
                    let offset = y * stack.bytesPerRow + x * 4, alpha = Int(pixels[offset + 3])
                    coverage[y * stackWidth + x] = UInt8(alpha)
                    for channel in 0..<3 {
                        pixels[offset + channel] = alpha == 0 ? 0 : UInt8(min(255, (Int(pixels[offset + channel]) * 255 + alpha / 2) / alpha))
                    }
                    pixels[offset + 3] = 255
                }
            }
            for child in children { try drawOwn(child, in: stack) }
            for y in 0..<stackHeight {
                for x in 0..<stackWidth {
                    let offset = y * stack.bytesPerRow + x * 4, alpha = Int(coverage[y * stackWidth + x])
                    for channel in 0..<3 { pixels[offset + channel] = UInt8((Int(pixels[offset + channel]) * alpha + 127) / 255) }
                    pixels[offset + 3] = UInt8(alpha)
                }
            }
            guard let image = stack.makeImage() else { throw RasterError.allocation }
            target.saveGState()
            target.setBlendMode(entry.layer.blendMode.cgMode)
            RasterImage.draw(image, in: region, context: target)
            target.restoreGState()
        }
        func drawChildren(_ parent: UUID?, in target: CGContext, bounds: CGRect) throws {
            for layer in siblings[parent] ?? [] {
                guard let entry = byID[layer.id], entry.isVisible else { continue }
                if layer.isGroup {
                    let selectedMask = layer.id == layerID ? maskReplacement : .original
                    if layer.maskEnabled, let mask = try maskImage(for: layer, replacement: selectedMask) {
                        try drawMaskedGroup(layer, mask: mask, in: target, bounds: bounds) { group, region in
                            try drawChildren(layer.id, in: group, bounds: region)
                        }
                    } else { try drawChildren(layer.id, in: target, bounds: bounds) }
                } else if layer.maskSourceID == nil { try drawStack(entry, in: target, bounds: bounds) }
            }
        }
        try drawChildren(nil, in: context, bounds: bounds)
        // A hidden base hides its clipping stack; a hidden child never breaks
        // the remaining siblings' stack. Arbitrary live-mask graphs are rejected.
        guard let image = context.makeImage() else { throw RasterError.allocation }
        return image
    }

    /// Preserve pass-through blending by interpolating the group's before/after
    /// backdrop in premultiplied RGBA. Applying a soft clip to each child would
    /// thicken overlap coverage. This rule is deliberately distinct from upstream
    /// FolderMaskClip; GroupMaskRules identifies it in persisted iPad state.
    private func drawMaskedGroup(_ layer: RasterLayer, mask: CGImage, in target: CGContext, bounds: CGRect,
                                 draw: (CGContext, CGRect) throws -> Void) throws {
        let region = GroupMaskRules.region(for: layer, within: bounds)
        guard !region.isNull, !region.isEmpty else { return }
        let width = Int(region.width), height = Int(region.height)
        guard let before = target.makeImage(), let raw = before.dataProvider?.data,
              let old = CFDataGetBytePtr(raw), CFDataGetLength(raw) >= before.bytesPerRow * before.height
        else { throw RasterError.allocation }
        let after = try RasterImage.context(width: width, height: height)
        after.translateBy(x: -region.minX, y: -region.minY)
        after.interpolationQuality = .none; after.setBlendMode(.copy)
        RasterImage.draw(before, in: bounds, context: after)
        after.setBlendMode(.normal)
        try draw(after, region)
        let coverage = try RasterImage.context(width: width, height: height, gray: true)
        coverage.translateBy(x: -region.minX, y: -region.minY)
        let t = layer.transform
        coverage.translateBy(x: t.center.x, y: t.center.y); coverage.rotate(by: t.radians)
        coverage.scaleBy(x: t.flipX ? -1 : 1, y: t.flipY ? -1 : 1)
        coverage.interpolationQuality = t.sampling.quality
        let rect = CGRect(x: -t.size.width / 2, y: -t.size.height / 2, width: t.size.width, height: t.size.height)
        RasterImage.clip(mask, to: rect, context: coverage)
        coverage.setFillColor(gray: 1, alpha: 1); coverage.fill(rect)
        guard let result = after.data?.assumingMemoryBound(to: UInt8.self),
              let weights = coverage.data?.assumingMemoryBound(to: UInt8.self) else { throw RasterError.allocation }
        let dx = Int(region.minX - bounds.minX), dy = Int(region.minY - bounds.minY)
        for y in 0..<height { for x in 0..<width {
            let weight = Int(weights[y * coverage.bytesPerRow + x])
            let source = (dy + y) * before.bytesPerRow + (dx + x) * 4
            let destination = y * after.bytesPerRow + x * 4
            for channel in 0..<4 {
                result[destination + channel] = UInt8((Int(old[source + channel]) * (255 - weight)
                    + Int(result[destination + channel]) * weight + 127) / 255)
            }
        } }
        guard let image = after.makeImage() else { throw RasterError.allocation }
        target.saveGState(); defer { target.restoreGState() }
        target.setBlendMode(.copy)
        RasterImage.draw(image, in: region, context: target)
    }

    private func maskImage(for layer: RasterLayer, replacement: MaskReplacement) throws -> CGImage? {
        switch replacement {
        case .replacement(let image): return image
        case .original:
            guard let data = layer.maskPNGData else { return nil }
            if let hit = masks[layer.id], hit.0 == data { return hit.1 }
            let image = try RasterImage.decode(data)
            masks[layer.id] = (data, image)
            return image
        }
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
            if let mask = try maskImage(for: layer, replacement: maskReplacement) { RasterImage.clip(mask, to: rect, context: context) }
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
            for (layer, plan) in zip(document.layers, plans) {
                let size = try pixelSize(of: layer)
                if !layer.isGroup { pixels += plan.map { Int($0.bounds.width * $0.bounds.height) } ?? Int(size.width * size.height) }
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
        guard !layer.isGroup || layer.maskPNGData != nil else { return nil }
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
        if !layer.isGroup {
            let context = try RasterImage.context(width: Int(plan.bounds.width), height: Int(plan.bounds.height))
            context.interpolationQuality = .none; context.setBlendMode(.copy)
            if let source = try image(for: layer) {
                RasterImage.draw(source, in: CGRect(origin: CGPoint(x: -plan.bounds.minX, y: -plan.bounds.minY), size: plan.oldSize), context: context)
            }
            guard let image = context.makeImage() else { throw RasterError.allocation }
            result.pngData = try RasterImage.png(image)
        }
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
