// Adapted from Compositor LayerTransform.swift and LayerGroups.swift.
// Copyright (c) 2026 Wonder Assembly LLC. MIT; see licenses/Compositor-MIT.txt.
// Upstream: 7c2a5a4a3e7f685a8a0ec282ef0b4284f20b5477.
import Foundation
import CoreGraphics

public enum LayerSampling: String, Codable, CaseIterable, Sendable {
    case nearest = "Nearest", smooth = "Smooth", high = "High quality"
    public var quality: CGInterpolationQuality {
        switch self { case .nearest: .none; case .smooth: .low; case .high: .high }
    }
}

/// Document pixels, with a top-left origin and clockwise rotation around the center.
public struct LayerTransform: Codable, Equatable, Sendable {
    public var origin: CGPoint
    public var size: CGSize
    public var rotation: CGFloat
    public var flipX: Bool
    public var flipY: Bool
    public var sampling: LayerSampling

    public init(origin: CGPoint = .zero, size: CGSize, rotation: CGFloat = 0,
                flipX: Bool = false, flipY: Bool = false, sampling: LayerSampling = .high) {
        self.origin = origin; self.size = size; self.rotation = rotation
        self.flipX = flipX; self.flipY = flipY; self.sampling = sampling
    }

    public var center: CGPoint { CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2) }
    public var radians: CGFloat { rotation.truncatingRemainder(dividingBy: 360) * .pi / 180 }
    public var isValid: Bool {
        [origin.x, origin.y, size.width, size.height, rotation].allSatisfy(\.isFinite)
            && (1...300_000).contains(size.width) && (1...300_000).contains(size.height)
            && abs(origin.x) <= 1_000_000 && abs(origin.y) <= 1_000_000
    }

    public func point(_ unit: CGPoint) -> CGPoint {
        let x = (unit.x - 0.5) * size.width, y = (unit.y - 0.5) * size.height
        return CGPoint(x: center.x + x * cos(radians) - y * sin(radians),
                       y: center.y + x * sin(radians) + y * cos(radians))
    }

    public func contains(_ point: CGPoint) -> Bool {
        let x = point.x - center.x, y = point.y - center.y
        return abs(x * cos(radians) + y * sin(radians)) <= size.width / 2
            && abs(-x * sin(radians) + y * cos(radians)) <= size.height / 2
    }
}

/// Only modes rendered directly by this milestone are offered or accepted on import.
public enum LayerBlendMode: String, Codable, CaseIterable, Sendable {
    case normal = "Normal", multiply = "Multiply", screen = "Screen", overlay = "Overlay"
    case darken = "Darken", lighten = "Lighten", difference = "Difference", exclusion = "Exclusion"
    case hue = "Hue", saturation = "Saturation", color = "Color", luminosity = "Luminosity"
    public var cgMode: CGBlendMode {
        switch self {
        case .normal: .normal; case .multiply: .multiply; case .screen: .screen; case .overlay: .overlay
        case .darken: .darken; case .lighten: .lighten; case .difference: .difference; case .exclusion: .exclusion
        case .hue: .hue; case .saturation: .saturation; case .color: .color; case .luminosity: .luminosity
        }
    }
}

public struct PixelRect: Codable, Equatable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    public func isInside(width canvasWidth: Int, height canvasHeight: Int) -> Bool {
        x >= 0 && y >= 0 && width > 0 && height > 0 && x <= canvasWidth && y <= canvasHeight
            && width <= canvasWidth - x && height <= canvasHeight - y
    }
}

public struct LayerHierarchyEntry: Sendable {
    public let layer: RasterLayer
    public let depth: Int
    public let isVisible: Bool
    public let effectiveOpacity: Double
}

public enum LayerHierarchy {
    /// Groups use Compositor's pass-through semantics: opacity multiplies each descendant.
    public static func entries(_ layers: [RasterLayer], topFirst: Bool = false) -> [LayerHierarchyEntry] {
        let children = Dictionary(grouping: layers, by: \.parentID)
        var result: [LayerHierarchyEntry] = []
        func visit(_ parent: UUID?, depth: Int, visible: Bool, opacity: Double) {
            guard depth <= 64 else { return }
            let siblings = children[parent] ?? []
            for layer in topFirst ? Array(siblings.reversed()) : siblings {
                let effective = visible && layer.isVisible
                let effectiveOpacity = opacity * layer.opacity
                result.append(LayerHierarchyEntry(layer: layer, depth: depth, isVisible: effective,
                                                  effectiveOpacity: effectiveOpacity))
                if layer.isGroup { visit(layer.id, depth: depth + 1, visible: effective, opacity: effectiveOpacity) }
            }
        }
        visit(nil, depth: 0, visible: true, opacity: 1)
        return result
    }

    public static func validate(_ layers: [RasterLayer]) throws {
        var byID: [UUID: RasterLayer] = [:]
        for layer in layers {
            guard byID.updateValue(layer, forKey: layer.id) == nil,
                  !layer.isGroup || (layer.pngData == nil && layer.maskPNGData == nil && layer.blendMode == .normal)
            else { throw DocumentError.invalid("重复图层 ID 或不支持的图层组内容") }
        }
        for layer in layers {
            var seen: Set<UUID> = [layer.id]
            var parent = layer.parentID
            while let id = parent {
                guard seen.count <= 64, seen.insert(id).inserted, let node = byID[id], node.isGroup
                else { throw DocumentError.invalid("图层组引用无效、循环或过深") }
                parent = node.parentID
            }
            if layer.isGroup && seen.count > 64 { throw DocumentError.invalid("图层组嵌套过深") }
        }
    }
}
