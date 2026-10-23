// Float LUT interpolation and alpha handling adapted from Compositor LevelsPixels.c,
// 365b5745eda537f984f3d5bed1e53c361dbc9c91. MIT © 2026 Wonder Assembly LLC.
import CoreGraphics

enum ColorAdjustmentRaster {
    /// Adjust the existing premultiplied surface in place. Coverage changes color, never alpha.
    /// The optional mask is numeric L8 sampled in document coordinates, once per adjustment.
    static func apply(_ value: LayerAdjustment, to context: CGContext, opacity: Double,
                      coverage: CGContext? = nil) throws {
        guard value.isValid, opacity.isFinite, (0...1).contains(opacity) else {
            throw DocumentError.invalid("调整层参数无效")
        }
        guard !value.isIdentity, opacity > 0 else { return }
        let tables = try value.lookupTables()
        guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else { throw RasterError.allocation }
        let mask = coverage?.data?.assumingMemoryBound(to: UInt8.self)
        for y in 0..<context.height { for x in 0..<context.width {
            let offset = y * context.bytesPerRow + x * 4
            let alpha = Float(pixels[offset + 3])
            guard alpha > 0 else { continue }
            let weight = Float(opacity) * (mask.map { Float($0[y * coverage!.bytesPerRow + x]) / 255 } ?? 1)
            guard weight > 0 else { continue }
            for channel in 0..<3 {
                let old = Float(pixels[offset + channel])
                let input = min(255, old * 255 / alpha), lo = Int(input), hi = min(255, lo + 1)
                let table = tables[channel]
                let result = table[lo] + (table[hi] - table[lo]) * (input - Float(lo))
                let adjusted = min(alpha, max(0, (result * alpha).rounded()))
                pixels[offset + channel] = UInt8(min(alpha, max(0, (old + (adjusted - old) * weight).rounded())))
            }
        } }
    }
}
