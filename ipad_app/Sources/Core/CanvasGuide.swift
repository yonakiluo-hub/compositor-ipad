// CanvasGuide data model adapted from Compositor Document/Guides.swift,
// 365b5745eda537f984f3d5bed1e53c361dbc9c91. MIT © 2026 Wonder Assembly LLC.
import Foundation
import CoreGraphics

public struct CanvasGuide: Codable, Equatable, Identifiable, Sendable {
    public enum Axis: String, Codable, CaseIterable, Sendable { case horizontal, vertical }
    public static let limit = 1000
    public var id: UUID
    public var axis: Axis
    /// Document pixels, independent of display zoom and rotation. Off-canvas lines are retained after cropping.
    public var position: Double
    public init(id: UUID = UUID(), axis: Axis, position: Double) { self.id = id; self.axis = axis; self.position = position }
    public static func validate(_ guides: [CanvasGuide]) throws {
        guard guides.count <= limit, Set(guides.map(\.id)).count == guides.count,
              guides.allSatisfy({ $0.position.isFinite && (-1_000_000...1_000_000).contains($0.position) }) else {
            throw DocumentError.invalid("辅助线重复、过多或位置无效")
        }
    }
    public func offset(x: Double, y: Double) -> CanvasGuide {
        var result = self; result.position += axis == .vertical ? x : y; return result
    }
}
