// CG/CI adaptation of Compositor LayerEffects.swift at 365b5745eda537f984f3d5bed1e53c361dbc9c91.
// MIT © 2026 Wonder Assembly LLC. No AppKit or desktop Metal surface is imported.
import Foundation
import CoreGraphics
import CoreImage

enum LayerEffectsRaster {
    static let workingByteLimit = 256 * 1024 * 1024
    static let cacheByteLimit = 64 * 1024 * 1024
    private static let ci = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    static func workingBytes(source: CGSize, effects: LayerEffects) throws -> Int {
        guard effects.isValid, source.width.isFinite, source.height.isFinite else { throw DocumentError.invalid("图层效果无效") }
        guard effects.hasVisibleEffects else { return 0 }
        let margin = effects.padding, width = source.width + 2 * margin, height = source.height + 2 * margin
        guard source.width > 0, source.height > 0, width <= 4096, height <= 4096, width * height <= 16_000_000 else { throw RasterError.oversized }
        // Alpha arrays, RGBA output/style/provider copies and CI blur staging.
        let bytes = Int(width * height) * 32 + Int(source.width * source.height) * 8
        guard bytes <= workingByteLimit else { throw DocumentError.unsupported("图层效果临时表面超出内存预算") }
        return bytes
    }

    static func bounds(of layer: RasterLayer) throws -> CGRect {
        let t = layer.transform
        guard t.isValid else { throw DocumentError.invalid("图层效果几何无效") }
        let source = try layer.pngData.map { try PNGAsset.inspect($0) }
        let w = layer.shape == nil ? CGFloat(source?.width ?? max(1, Int(ceil(t.size.width)))) : ceil(t.size.width)
        let h = layer.shape == nil ? CGFloat(source?.height ?? max(1, Int(ceil(t.size.height)))) : ceil(t.size.height)
        let margin = layer.effects?.padding ?? 0
        let x = margin / w, y = margin / h
        let corners = [CGPoint(x: -x, y: -y), CGPoint(x: 1 + x, y: -y),
                       CGPoint(x: -x, y: 1 + y), CGPoint(x: 1 + x, y: 1 + y)].map(t.point)
        let left = corners.map(\.x).min()!, top = corners.map(\.y).min()!
        return CGRect(x: left, y: top, width: corners.map(\.x).max()! - left, height: corners.map(\.y).max()! - top)
    }

    /// The own numeric mask is applied before making effect coverage, once. The
    /// caller draws the padded result without clipping that same mask again.
    static func render(_ image: CGImage, mask: CGImage?, effects: LayerEffects) throws -> (image: CGImage, inset: CGFloat) {
        guard effects.isValid else { throw DocumentError.invalid("图层效果参数无效") }
        guard effects.hasVisibleEffects else { return (image, 0) }
        _ = try workingBytes(source: CGSize(width: image.width, height: image.height), effects: effects)
        let inset = effects.padding, width = image.width + Int(inset) * 2, height = image.height + Int(inset) * 2
        let full = CGRect(x: 0, y: 0, width: width, height: height)
        let placed = CGRect(x: inset, y: inset, width: CGFloat(image.width), height: CGFloat(image.height))
        let shown = try masked(image, mask: mask), alphaSource = try alpha(of: shown)
        let base = try placedCoverage(alphaSource, sourceWidth: image.width, sourceHeight: image.height,
                                      placed: placed, width: width, height: height)
        let output = try RasterImage.context(width: width, height: height)
        if let shadow = effects.shadow, shadow.isEnabled, shadow.opacity > 0 {
            let moved = try placedCoverage(alphaSource, sourceWidth: image.width, sourceHeight: image.height,
                placed: placed.offsetBy(dx: shadow.offset.width, dy: shadow.offset.height), width: width, height: height)
            fill(output, coverage: try blurred(moved, width: width, height: height, radius: shadow.blur),
                 color: [shadow.red, shadow.green, shadow.blue], opacity: shadow.opacity)
        }
        if let glow = effects.outerGlow, glow.isEnabled, glow.size > 0, glow.opacity > 0 {
            var coverage = try blurred(base, width: width, height: height, radius: glow.size)
            for i in coverage.indices {
                let outside = 1.0 - Double(base[i]) / 255.0
                coverage[i] = UInt8((Double(coverage[i]) * outside).rounded())
            }
            fill(output, coverage: coverage, color: [glow.red, glow.green, glow.blue], opacity: glow.opacity)
        }
        if let stroke = effects.stroke, stroke.isEnabled, stroke.size > 0, stroke.opacity > 0, !stroke.inside {
            fill(output, coverage: strokeCoverage(base, width: width, height: height, stroke: stroke),
                 color: [stroke.red, stroke.green, stroke.blue], opacity: stroke.opacity)
        }
        let styled = try RasterImage.context(width: width, height: height)
        RasterImage.draw(shown, in: placed, context: styled)
        if let overlay = effects.colorOverlay, overlay.isEnabled, overlay.opacity > 0 {
            recolor(styled, coverage: nil, color: [overlay.red, overlay.green, overlay.blue], opacity: overlay.opacity)
        }
        if let glow = effects.innerGlow, glow.isEnabled, glow.size > 0, glow.opacity > 0 {
            let soft = try blurred(base, width: width, height: height, radius: glow.size)
            recolor(styled, coverage: soft.map { 255 - $0 }, color: [glow.red, glow.green, glow.blue], opacity: glow.opacity)
        }
        if let shadow = effects.innerShadow, shadow.isEnabled, shadow.opacity > 0 {
            let moved = try placedCoverage(alphaSource, sourceWidth: image.width, sourceHeight: image.height,
                placed: placed.offsetBy(dx: shadow.offset.width, dy: shadow.offset.height), width: width, height: height)
            let soft = try blurred(moved, width: width, height: height, radius: shadow.blur)
            recolor(styled, coverage: soft.map { 255 - $0 }, color: [shadow.red, shadow.green, shadow.blue], opacity: shadow.opacity)
        }
        if let stroke = effects.stroke, stroke.isEnabled, stroke.size > 0, stroke.opacity > 0, stroke.inside {
            var coverage = strokeCoverage(base, width: width, height: height, stroke: stroke)
            // The stroke changes color inside existing coverage; source-over here
            // would thicken partially transparent pixels and soft own masks.
            for i in coverage.indices { coverage[i] = base[i] == 0 ? 0 : UInt8(min(255, Int(coverage[i]) * 255 / Int(base[i]))) }
            recolor(styled, coverage: coverage, color: [stroke.red, stroke.green, stroke.blue], opacity: stroke.opacity)
        }
        guard let top = styled.makeImage() else { throw RasterError.allocation }
        output.setBlendMode(.normal); RasterImage.draw(top, in: full, context: output)
        guard let result = output.makeImage() else { throw RasterError.allocation }
        return (result, inset)
    }

    private static func masked(_ image: CGImage, mask: CGImage?) throws -> CGImage {
        guard let mask else { return image }
        let c = try RasterImage.context(width: image.width, height: image.height), rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        RasterImage.clip(mask, to: rect, context: c); RasterImage.draw(image, in: rect, context: c)
        guard let result = c.makeImage() else { throw RasterError.allocation }; return result
    }
    private static func alpha(of image: CGImage) throws -> [UInt8] {
        let c = try RasterImage.context(width: image.width, height: image.height)
        RasterImage.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), context: c)
        guard let p = c.data?.assumingMemoryBound(to: UInt8.self) else { throw RasterError.allocation }
        var result = [UInt8](repeating: 0, count: image.width * image.height)
        for y in 0..<image.height { for x in 0..<image.width { result[y * image.width + x] = p[y * c.bytesPerRow + x * 4 + 3] } }
        return result
    }
    private static func gray(_ values: [UInt8], width: Int, height: Int) throws -> CGImage {
        guard values.count == width * height, let provider = CGDataProvider(data: Data(values) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw RasterError.allocation }
        return image
    }
    private static func samples(_ image: CGImage) throws -> [UInt8] {
        guard let raw = image.dataProvider?.data, let p = CFDataGetBytePtr(raw), CFDataGetLength(raw) >= image.bytesPerRow * image.height else { throw RasterError.invalidImage }
        var values = [UInt8](repeating: 0, count: image.width * image.height)
        for y in 0..<image.height { for x in 0..<image.width { values[y * image.width + x] = p[y * image.bytesPerRow + x] } }
        return values
    }
    private static func placedCoverage(_ values: [UInt8], sourceWidth: Int, sourceHeight: Int, placed: CGRect, width: Int, height: Int) throws -> [UInt8] {
        let c = try RasterImage.context(width: width, height: height, gray: true)
        c.interpolationQuality = .high
        RasterImage.draw(try gray(values, width: sourceWidth, height: sourceHeight), in: placed, context: c)
        guard let image = c.makeImage() else { throw RasterError.allocation }; return try samples(image)
    }
    private static func blurred(_ values: [UInt8], width: Int, height: Int, radius: Double) throws -> [UInt8] {
        guard radius > 0 else { return values }
        let input = CIImage(cgImage: try gray(values, width: width, height: height), options: [.colorSpace: NSNull()])
        let soft = input.clampedToExtent().applyingGaussianBlur(sigma: radius / 2).cropped(to: input.extent)
        guard let image = ci.createCGImage(soft, from: input.extent, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray()) else { throw RasterError.allocation }
        return try samples(image)
    }
    private static func strokeCoverage(_ base: [UInt8], width: Int, height: Int, stroke: StrokeEffect) -> [UInt8] {
        let other = extreme(base, width: width, height: height, reach: max(1, Int(stroke.size.rounded())), smallest: stroke.inside)
        return zip(base, other).map { stroke.inside ? ($0 > $1 ? $0 - $1 : 0) : ($1 > $0 ? $1 - $0 : 0) }
    }
    /// Two monotonic-deque passes, adapted from upstream. Cost is O(pixels), not O(radius * pixels).
    static func extreme(_ input: [UInt8], width: Int, height: Int, reach: Int, smallest: Bool) -> [UInt8] {
        guard width > 0, height > 0, input.count == width * height else { return [] }
        var pass = [UInt8](repeating: 0, count: input.count), result = pass
        var queue = [Int](repeating: 0, count: max(width, height))
        func sweep(_ source: [UInt8], target: inout [UInt8], lines: Int, count: Int, lineStep: Int, elementStep: Int) {
            for line in 0..<lines {
                let base = line * lineStep; var head = 0, tail = 0, next = 0
                for center in 0..<count {
                    while next <= min(count - 1, center + reach) {
                        let value = source[base + next * elementStep]
                        while tail > head {
                            let previous = source[base + queue[tail - 1] * elementStep]
                            if smallest ? previous < value : previous > value { break }; tail -= 1
                        }
                        queue[tail] = next; tail += 1; next += 1
                    }
                    while head < tail, queue[head] < center - reach { head += 1 }
                    let outside = center < reach || center + reach >= count
                    target[base + center * elementStep] = smallest && outside ? 0 : source[base + queue[head] * elementStep]
                }
            }
        }
        sweep(input, target: &pass, lines: height, count: width, lineStep: width, elementStep: 1)
        sweep(pass, target: &result, lines: width, count: height, lineStep: 1, elementStep: width)
        return result
    }
    private static func fill(_ context: CGContext, coverage: [UInt8], color: [Double], opacity: Double) {
        guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return }
        for y in 0..<context.height { for x in 0..<context.width {
            let alpha = Double(coverage[y * context.width + x]) / 255 * opacity
            guard alpha > 0 else { continue }
            let offset = y * context.bytesPerRow + x * 4
            for c in 0..<3 { pixels[offset + c] = UInt8(min(255, max(0, (color[c] * alpha * 255 + Double(pixels[offset + c]) * (1 - alpha)).rounded()))) }
            pixels[offset + 3] = UInt8(min(255, max(0, (alpha * 255 + Double(pixels[offset + 3]) * (1 - alpha)).rounded())))
        } }
    }
    private static func recolor(_ context: CGContext, coverage: [UInt8]?, color: [Double], opacity: Double) {
        guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { return }
        for y in 0..<context.height { for x in 0..<context.width {
            let offset = y * context.bytesPerRow + x * 4, alpha = Double(pixels[offset + 3])
            guard alpha > 0 else { continue }
            let amount = opacity * (coverage.map { Double($0[y * context.width + x]) / 255 } ?? 1)
            for c in 0..<3 { pixels[offset + c] = UInt8(min(alpha, max(0, (Double(pixels[offset + c]) + (color[c] * alpha - Double(pixels[offset + c])) * amount).rounded()))) }
        } }
    }
}
