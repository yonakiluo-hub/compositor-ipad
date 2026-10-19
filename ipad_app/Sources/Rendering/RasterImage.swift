import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum RasterError: LocalizedError {
    case invalidImage, allocation, encoding, oversized
    var errorDescription: String? {
        switch self {
        case .invalidImage: return "无法读取这张图片。"
        case .allocation: return "没有足够内存处理画布。"
        case .encoding: return "图片编码失败。"
        case .oversized: return "当前预览版本支持最多 4096 × 4096 像素、总计 1600 万像素的画布。"
        }
    }
}

enum RasterImage {
    static func decode(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 4096, height <= 4096, width * height <= 16_000_000,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw RasterError.invalidImage }
        return image
    }

    static func context(width: Int, height: Int, gray: Bool = false) throws -> CGContext {
        guard width > 0, height > 0, width <= 4096, height <= 4096,
              width * height <= 16_000_000 else { throw RasterError.oversized }
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * (gray ? 1 : 4),
                                      space: gray ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { throw RasterError.allocation }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        return context
    }

    /// Draw into a top-left document coordinate system. The PNG decoder has already premultiplied alpha.
    static func draw(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw RasterError.encoding }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw RasterError.encoding }
        let encoded = data as Data
        if image.bitsPerComponent == 8, image.bitsPerPixel == 8,
           image.alphaInfo == .none, image.colorSpace?.model == .monochrome {
            return try numericMaskPNG(encoded)
        }
        return encoded
    }

    /// A decoded grayscale selection acquires an ImageIO gray profile. Re-encoding a crop
    /// can then add iCCP. Masks are numeric coverage, so preserve compressed sample bytes
    /// and remove color-management metadata instead of performing a color conversion.
    private static func numericMaskPNG(_ encoded: Data) throws -> Data {
        guard encoded.count >= 33, encoded[24] == 8, encoded[25] == 0 else { throw RasterError.encoding }
        var output = Data(encoded.prefix(8))
        var offset = 8
        var ended = false
        while offset + 12 <= encoded.count {
            let count = encoded[offset..<offset + 4].reduce(0) { ($0 << 8) | Int($1) }
            guard count <= encoded.count - offset - 12 else { throw RasterError.encoding }
            let type = String(decoding: encoded[offset + 4..<offset + 8], as: UTF8.self)
            let end = offset + count + 12
            // Removing transparency could silently change coverage; reject it instead.
            guard type != "tRNS", type != "acTL" else { throw RasterError.encoding }
            if !["iCCP", "sRGB", "gAMA", "cHRM"].contains(type) {
                output.append(encoded[offset..<end])
            }
            offset = end
            if type == "IEND" { ended = count == 0 && offset == encoded.count; break }
        }
        guard ended else { throw RasterError.encoding }
        return output
    }

    static func jpeg(_ image: CGImage) throws -> Data {
        let context = try self.context(width: image.width, height: image.height)
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(rect)
        draw(image, in: rect, context: context)
        guard let flattened = context.makeImage() else { throw RasterError.allocation }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw RasterError.encoding }
        CGImageDestinationAddImage(destination, flattened, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw RasterError.encoding }
        return data as Data
    }

    static func solidMask(width: Int, height: Int, white: Bool) throws -> CGImage {
        let context = try self.context(width: width, height: height, gray: true)
        context.setFillColor(gray: white ? 1 : 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw RasterError.allocation }
        return image
    }

    static func clip(_ mask: CGImage, to rect: CGRect, context: CGContext) {
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.clip(to: CGRect(origin: .zero, size: rect.size), mask: mask)
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -rect.minX, y: -rect.maxY)
    }

    // Adapted from Compositor BrushRaster.falloff at 7c2a5a4; MIT © 2026 Wonder Assembly LLC.
    static func brushFalloff(_ u: CGFloat) -> CGFloat {
        let k: CGFloat = 2.5
        return max(0, (exp(-k * u * u) - exp(-k)) / (1 - exp(-k)))
    }
}
