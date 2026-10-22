import Foundation
import CoreGraphics

/// iPad pass-through group masks interpolate the before/after group result.
/// Compositor FolderMaskClip (365b5745, MIT) instead clips each descendant;
/// persisted iPad state must explicitly identify our different semantics.
enum GroupMaskRules {
    static let semantics = "pass-through-result-v1"
    static let workingByteLimit = 256 * 1024 * 1024

    static func region(for group: RasterLayer, within bounds: CGRect) -> CGRect {
        let corners = [CGPoint.zero, CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)].map(group.transform.point)
        let left = corners.map(\.x).min()!, top = corners.map(\.y).min()!
        let rect = CGRect(x: left, y: top, width: corners.map(\.x).max()! - left, height: corners.map(\.y).max()! - top)
        return rect.insetBy(dx: -2, dy: -2).integral.intersection(bounds)
    }

    /// Conservative peak accounting includes before-image/provider copies, the
    /// after buffer, coverage, and CGImage copy-on-write during final replacement.
    static func workingBytes(region: CGRect, parentBounds: CGRect) -> Int {
        Int(region.width * region.height) * 9 + Int(parentBounds.width * parentBounds.height) * 8
    }

    static func validate(_ layers: [RasterLayer], bounds: CGRect, limit: Int = workingByteLimit) throws {
        let children = Dictionary(grouping: layers, by: \.parentID)
        func visit(_ parent: UUID?, bounds: CGRect, retained: Int) throws {
            for layer in children[parent] ?? [] where layer.isVisible && layer.isGroup {
                if layer.maskPNGData != nil && layer.maskEnabled {
                    let region = region(for: layer, within: bounds)
                    guard !region.isNull, !region.isEmpty else { continue }
                    let total = retained + workingBytes(region: region, parentBounds: bounds)
                    guard total <= limit else { throw DocumentError.unsupported("组蒙版临时合成超出内存预算，请减小画布或减少嵌套组蒙版") }
                    try visit(layer.id, bounds: region, retained: total)
                } else { try visit(layer.id, bounds: bounds, retained: retained) }
            }
        }
        try visit(nil, bounds: bounds, retained: 0)
    }
}
