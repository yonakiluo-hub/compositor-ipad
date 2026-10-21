// Rasterization and feather semantics adapted from Compositor Document/Selection.swift.
// Copyright (c) 2026 Wonder Assembly LLC. MIT; see licenses/Compositor-MIT.txt.
// Upstream: 7c2a5a4a3e7f685a8a0ec282ef0b4284f20b5477.
import Foundation
import CoreGraphics
import CoreImage

enum SelectionCombineMode: String, CaseIterable, Sendable {
    case replace, add, subtract, intersect
}

enum SelectionShape: Equatable, Sendable {
    case rectangle(CGRect)
    case ellipse(CGRect)
    case polygon([CGPoint])
}

/// Selection pixels are numeric coverage, not colors: 0 protects and 255 selects.
/// Every returned image is an 8-bit, alpha-free grayscale mask in top-left coordinates.
enum SelectionMask {
    private static let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])

    static func rasterize(_ shape: SelectionShape, width: Int, height: Int) throws -> CGImage {
        let path = CGMutablePath()
        func valid(_ values: [CGFloat]) -> Bool { values.allSatisfy { $0.isFinite && abs($0) <= 1_000_000 } }
        switch shape {
        case .rectangle(let rect), .ellipse(let rect):
            guard valid([rect.origin.x, rect.origin.y, rect.size.width, rect.size.height]),
                  rect.width != 0, rect.height != 0 else { throw DocumentError.invalid("选区形状无效") }
            if case .ellipse = shape { path.addEllipse(in: rect.standardized) }
            else { path.addRect(rect.standardized) }
        case .polygon(let points):
            guard points.count >= 3, points.count <= 100_000,
                  points.allSatisfy({ valid([$0.x, $0.y]) }),
                  let first = points.first, let second = points.dropFirst().first(where: { $0 != first }),
                  points.contains(where: {
                      abs((second.x - first.x) * ($0.y - first.y) - (second.y - first.y) * ($0.x - first.x)) > 1e-9
                  }) else { throw DocumentError.invalid("套索至少需要三个不共线的点") }
            path.addLines(between: points)
            path.closeSubpath()
        }
        let bitmap = try RasterImage.context(width: width, height: height, gray: true)
        bitmap.setFillColor(gray: 0, alpha: 1)
        bitmap.fill(CGRect(x: 0, y: 0, width: width, height: height))
        bitmap.setShouldAntialias(true)
        bitmap.setFillColor(gray: 1, alpha: 1)
        bitmap.addPath(path)
        // Unlike the upstream winding path, a crossed freehand outline uses the
        // even-odd rule so its enclosed lobes do not depend on drawing direction.
        bitmap.fillPath(using: .evenOdd)
        guard let image = bitmap.makeImage() else { throw RasterError.allocation }
        return image
    }

    /// These are raster coverage operations, rather than the upstream's vector
    /// Boolean paths. Max/min avoid applying an already-soft edge a second time.
    /// No selection is distinct from an explicit black (empty) selection: creating
    /// with add/replace starts fresh; subtract/intersect require an existing mask.
    static func combine(existing: CGImage?, incoming: CGImage, mode: SelectionCombineMode) throws -> CGImage? {
        try validate(incoming)
        guard mode != .replace else { return incoming }
        guard let existing else { return mode == .add ? incoming : nil }
        try validate(existing)
        guard existing.width == incoming.width, existing.height == incoming.height else {
            throw DocumentError.invalid("选区尺寸不一致")
        }
        let before = try samples(existing), added = try samples(incoming)
        var output = [UInt8](repeating: 0, count: before.count)
        for index in output.indices {
            switch mode {
            case .replace: output[index] = added[index]
            case .add: output[index] = max(before[index], added[index])
            case .subtract: output[index] = UInt8(max(0, Int(before[index]) - Int(added[index])))
            case .intersect: output[index] = min(before[index], added[index])
            }
        }
        return try image(output, width: incoming.width, height: incoming.height)
    }

    /// Matches the upstream's radius/2 Gaussian sigma and clamped canvas edges.
    /// Coverage is blurred once and stored as pixels; consumers must not feather again.
    static func feather(mask: CGImage, radius: Double) throws -> CGImage {
        try validate(mask)
        guard radius.isFinite, (0...100).contains(radius) else { throw DocumentError.invalid("羽化半径必须在 0 到 100 像素之间") }
        guard radius > 0 else { return mask }
        // Copy numeric bytes to remove a decoded PNG's gray profile. Both CI input
        // and working/output spaces disable color conversion, preserving 128 as 128.
        let numeric = try image(samples(mask), width: mask.width, height: mask.height)
        let source = CIImage(cgImage: numeric, options: [.colorSpace: NSNull()])
        let blurred = source.clampedToExtent().applyingGaussianBlur(sigma: radius / 2).cropped(to: source.extent)
        guard let result = context.createCGImage(blurred, from: source.extent, format: .L8,
                                                 colorSpace: CGColorSpaceCreateDeviceGray()) else { throw RasterError.allocation }
        try validate(result)
        return result
    }

    private static func validate(_ mask: CGImage) throws {
        guard mask.width > 0, mask.height > 0, mask.width <= 4096, mask.height <= 4096,
              mask.width * mask.height <= 16_000_000 else { throw RasterError.oversized }
        guard mask.bitsPerComponent == 8, mask.bitsPerPixel == 8, mask.alphaInfo == .none,
              mask.colorSpace?.model == .monochrome, mask.bytesPerRow >= mask.width,
              mask.decode == nil else { throw DocumentError.invalid("选区必须是无透明度的 8 位灰度蒙版") }
    }

    private static func samples(_ mask: CGImage) throws -> [UInt8] {
        guard let data = mask.dataProvider?.data, CFDataGetLength(data) >= mask.bytesPerRow * mask.height,
              let bytes = CFDataGetBytePtr(data) else { throw RasterError.invalidImage }
        var output = [UInt8](repeating: 0, count: mask.width * mask.height)
        output.withUnsafeMutableBytes { target in
            for row in 0..<mask.height {
                memcpy(target.baseAddress!.advanced(by: row * mask.width), bytes.advanced(by: row * mask.bytesPerRow), mask.width)
            }
        }
        return output
    }

    private static func image(_ samples: [UInt8], width: Int, height: Int) throws -> CGImage {
        guard let provider = CGDataProvider(data: Data(samples) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw RasterError.allocation }
        return image
    }
}
