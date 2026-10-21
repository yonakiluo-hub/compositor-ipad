import Foundation
import CoreGraphics

struct LayerRegridResult {
    let image: CGImage
    let mask: CGImage?
    let transform: LayerTransform
}

/// Freezes a layer's current appearance into a document-aligned pixel grid.
/// It keeps the full transformed layer, including content outside the canvas,
/// and keeps its mask independent. The caller retains the original source for
/// cancellation/undo and applies layer opacity, blend mode and visibility later.
enum LayerRegrid {
    static func prepare(layer: RasterLayer, image: CGImage, mask: CGImage?) throws -> LayerRegridResult {
        guard !layer.isGroup, layer.transform.isValid else { throw DocumentError.invalid("图层几何无效") }
        try checkSize(width: image.width, height: image.height)
        if let mask {
            try checkSize(width: mask.width, height: mask.height)
            guard mask.bitsPerComponent == 8, mask.bitsPerPixel == 8, mask.alphaInfo == .none,
                  mask.colorSpace?.model == .monochrome, mask.decode == nil else {
                throw DocumentError.invalid("图层蒙版必须是 8 位灰度图")
            }
        }
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
                       CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)].map(layer.transform.point)
        guard corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            throw DocumentError.invalid("图层范围无效")
        }
        func aligned(_ value: CGFloat, upward: Bool) -> CGFloat {
            let exact = abs(value - value.rounded()) < 0.0000001 ? value.rounded() : value
            return upward ? ceil(exact) : floor(exact)
        }
        let left = aligned(corners.map(\.x).min()!, upward: false)
        let top = aligned(corners.map(\.y).min()!, upward: false)
        let right = aligned(corners.map(\.x).max()!, upward: true)
        let bottom = aligned(corners.map(\.y).max()!, upward: true)
        let width = right - left, height = bottom - top
        guard width.isFinite, height.isFinite, width >= 1, height >= 1,
              width <= 4096, height <= 4096, width * height <= 16_000_000 else { throw RasterError.oversized }
        let bounds = CGRect(x: left, y: top, width: width, height: height)
        let transform = LayerTransform(origin: bounds.origin, size: bounds.size, sampling: layer.transform.sampling)
        guard transform.isValid else { throw DocumentError.invalid("重新采样后的图层几何无效") }

        // Never apply the linked mask to these pixels. In particular, currently
        // hidden pixels must still exist when the user later disables the mask.
        let raw = try render(image, mask: nil, transform: layer.transform, bounds: bounds)
        var projectedMask: CGImage?
        if let mask {
            // Independently drawing gray into a new rectangle changes both the
            // image-mask sampling and geometric edge coverage. Instead, measure
            // the original renderer's mask coverage against the same opaque
            // reference without a mask. The ratio avoids applying its outer
            // edge antialiasing to the regridded raw pixels a second time.
            let white = try opaqueReference()
            var coverage = try alphaCoverage(white, mask: nil, transform: layer.transform, bounds: bounds)
            let maskedCoverage = try alphaCoverage(white, mask: mask, transform: layer.transform, bounds: bounds)
            for index in coverage.indices {
                let geometric = Int(coverage[index])
                coverage[index] = geometric == 0 ? 255
                    : UInt8(min(255, (Int(maskedCoverage[index]) * 255 + geometric / 2) / geometric))
            }
            projectedMask = try grayImage(coverage, width: Int(width), height: Int(height))
        }
        return LayerRegridResult(image: raw, mask: projectedMask, transform: transform)
    }

    private static func render(_ image: CGImage, mask: CGImage?, transform: LayerTransform,
                               bounds: CGRect) throws -> CGImage {
        let context = try RasterImage.context(width: Int(bounds.width), height: Int(bounds.height))
        // The integer translation preserves the document's pixel sampling phase.
        context.translateBy(x: transform.center.x - bounds.minX, y: transform.center.y - bounds.minY)
        context.rotate(by: transform.radians)
        context.scaleBy(x: transform.flipX ? -1 : 1, y: transform.flipY ? -1 : 1)
        let rectangle = CGRect(x: -transform.size.width / 2, y: -transform.size.height / 2,
                               width: transform.size.width, height: transform.size.height)
        context.interpolationQuality = transform.sampling.quality
        if let mask { RasterImage.clip(mask, to: rectangle, context: context) }
        RasterImage.draw(image, in: rectangle, context: context)
        guard let rendered = context.makeImage() else { throw RasterError.allocation }
        return rendered
    }

    private static func alphaCoverage(_ image: CGImage, mask: CGImage?, transform: LayerTransform,
                                      bounds: CGRect) throws -> [UInt8] {
        let rendered = try render(image, mask: mask, transform: transform, bounds: bounds)
        guard let data = rendered.dataProvider?.data, let bytes = CFDataGetBytePtr(data),
              CFDataGetLength(data) >= rendered.bytesPerRow * rendered.height else { throw RasterError.allocation }
        var alpha = [UInt8](repeating: 0, count: rendered.width * rendered.height)
        for row in 0..<rendered.height {
            for column in 0..<rendered.width {
                alpha[row * rendered.width + column] = bytes[row * rendered.bytesPerRow + column * 4 + 3]
            }
        }
        return alpha
    }

    private static func opaqueReference() throws -> CGImage {
        // A constant texture needs only one texel; the layer's original rectangle
        // still supplies exactly the same transformed geometric boundary.
        let context = try RasterImage.context(width: 1, height: 1)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let image = context.makeImage() else { throw RasterError.allocation }
        return image
    }

    private static func grayImage(_ pixels: [UInt8], width: Int, height: Int) throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                  bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw RasterError.allocation }
        return image
    }

    private static func checkSize(width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= 4096, height <= 4096,
              width * height <= 16_000_000 else { throw RasterError.oversized }
    }
}
