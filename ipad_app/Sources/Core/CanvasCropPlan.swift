// Non-destructive crop coordinates adapted from Compositor Document/Crop.swift,
// 365b5745eda537f984f3d5bed1e53c361dbc9c91. MIT © 2026 Wonder Assembly LLC.
// Frozen source validation and numeric selection cropping are iPad adaptations.
import Foundation
import CoreGraphics

struct CanvasCropPlan {
    let source: CanvasDocument
    init(document: CanvasDocument) throws { try document.validate(); source = document }
    var original: PixelRect { PixelRect(x: 0, y: 0, width: source.width, height: source.height) }

    func preview(_ rect: PixelRect) throws -> CanvasDocument {
        guard (-1_000_000...1_000_000).contains(rect.x), (-1_000_000...1_000_000).contains(rect.y),
              rect.width > 0, rect.height > 0, rect.width <= 4096, rect.height <= 4096,
              rect.width * rect.height <= 16_000_000 else { throw RasterError.oversized }
        guard rect != original else { return source }
        var result = source
        result.width = rect.width; result.height = rect.height
        // Coordinates are global, including group/adjustment mask placements. Shift each record once;
        // do not resample or trim immutable sources, even when they now lie outside the canvas.
        for i in result.layers.indices {
            result.layers[i].transform.origin.x -= CGFloat(rect.x)
            result.layers[i].transform.origin.y -= CGFloat(rect.y)
        }
        result.guides = result.guides.map { $0.offset(x: Double(-rect.x), y: Double(-rect.y)) }
        if let data = source.selectionMaskPNGData {
            let mask = try RasterImage.decode(data), target = try RasterImage.context(width: rect.width, height: rect.height, gray: true)
            let canvas = CGRect(x: 0, y: 0, width: rect.width, height: rect.height)
            target.setFillColor(gray: 0, alpha: 1); target.fill(canvas)
            target.interpolationQuality = .none
            let sourceRect = CGRect(x: -rect.x, y: -rect.y, width: source.width, height: source.height)
            RasterImage.clip(mask, to: sourceRect, context: target)
            target.setFillColor(gray: 1, alpha: 1); target.fill(sourceRect)
            guard let cropped = target.makeImage() else { throw RasterError.allocation }
            result.selectionMaskPNGData = try RasterImage.png(cropped)
        }
        try result.validate()
        return result
    }

    func apply(_ rect: PixelRect, to document: inout CanvasDocument) throws {
        guard document == source else { throw DocumentError.staleRevision }
        document = try preview(rect)
    }
}
