// Parameter records and bounds adapted from Compositor LayerEffects.swift,
// 365b5745eda537f984f3d5bed1e53c361dbc9c91. MIT © 2026 Wonder Assembly LLC.
import Foundation
import CoreGraphics

public struct StrokeEffect: Codable, Equatable, Sendable {
    public var enabled: Bool? = nil
    public var size: Double = 4
    public var red: Double = 0
    public var green: Double = 0
    public var blue: Double = 0
    public var opacity: Double = 1
    public var inside = false
    public init(enabled: Bool? = nil, size: Double = 4, red: Double = 0, green: Double = 0, blue: Double = 0,
                opacity: Double = 1, inside: Bool = false) {
        self.enabled = enabled; self.size = size; self.red = red; self.green = green; self.blue = blue
        self.opacity = opacity; self.inside = inside
    }
    public var isEnabled: Bool { enabled ?? true }
    public var isValid: Bool { size.isFinite && (0...500).contains(size) && LayerTextStyle.validColor(red, green, blue, opacity) }
}

public struct ShadowEffect: Codable, Equatable, Sendable {
    public var enabled: Bool? = nil
    public var angle: Double = 90
    public var distance: Double = 20
    public var blur: Double = 20
    public var red: Double = 0
    public var green: Double = 0
    public var blue: Double = 0
    public var opacity: Double = 0.5
    public init(enabled: Bool? = nil, angle: Double = 90, distance: Double = 20, blur: Double = 20,
                red: Double = 0, green: Double = 0, blue: Double = 0, opacity: Double = 0.5) {
        self.enabled = enabled; self.angle = angle; self.distance = distance; self.blur = blur
        self.red = red; self.green = green; self.blue = blue; self.opacity = opacity
    }
    public var isEnabled: Bool { enabled ?? true }
    public var offset: CGSize { CGSize(width: -cos(angle * .pi / 180) * distance, height: sin(angle * .pi / 180) * distance) }
    public var isValid: Bool {
        angle.isFinite && (-360...360).contains(angle) && distance.isFinite && (0...5000).contains(distance)
            && blur.isFinite && (0...500).contains(blur) && LayerTextStyle.validColor(red, green, blue, opacity)
    }
}

public struct ColorOverlayEffect: Codable, Equatable, Sendable {
    public var enabled: Bool? = nil
    public var red: Double = 0
    public var green: Double = 0
    public var blue: Double = 0
    public var opacity: Double = 1
    public init(enabled: Bool? = nil, red: Double = 0, green: Double = 0, blue: Double = 0, opacity: Double = 1) {
        self.enabled = enabled; self.red = red; self.green = green; self.blue = blue; self.opacity = opacity
    }
    public var isEnabled: Bool { enabled ?? true }
    public var isValid: Bool { LayerTextStyle.validColor(red, green, blue, opacity) }
}

public struct InnerShadowEffect: Codable, Equatable, Sendable {
    public var enabled: Bool? = nil
    public var angle: Double = 90
    public var distance: Double = 10
    public var blur: Double = 10
    public var red: Double = 0
    public var green: Double = 0
    public var blue: Double = 0
    public var opacity: Double = 0.5
    public init(enabled: Bool? = nil, angle: Double = 90, distance: Double = 10, blur: Double = 10,
                red: Double = 0, green: Double = 0, blue: Double = 0, opacity: Double = 0.5) {
        self.enabled = enabled; self.angle = angle; self.distance = distance; self.blur = blur
        self.red = red; self.green = green; self.blue = blue; self.opacity = opacity
    }
    public var isEnabled: Bool { enabled ?? true }
    public var offset: CGSize { CGSize(width: -cos(angle * .pi / 180) * distance, height: sin(angle * .pi / 180) * distance) }
    public var isValid: Bool {
        angle.isFinite && (-360...360).contains(angle) && distance.isFinite && (0...5000).contains(distance)
            && blur.isFinite && (0...500).contains(blur) && LayerTextStyle.validColor(red, green, blue, opacity)
    }
}

public struct OuterGlowEffect: Codable, Equatable, Sendable {
    public var enabled: Bool? = nil
    public var size: Double = 20
    public var red: Double = 1
    public var green: Double = 1
    public var blue: Double = 1
    public var opacity: Double = 0.75
    public init(enabled: Bool? = nil, size: Double = 20, red: Double = 1, green: Double = 1, blue: Double = 1, opacity: Double = 0.75) {
        self.enabled = enabled; self.size = size; self.red = red; self.green = green; self.blue = blue; self.opacity = opacity
    }
    public var isEnabled: Bool { enabled ?? true }
    public var isValid: Bool { size.isFinite && (0...500).contains(size) && LayerTextStyle.validColor(red, green, blue, opacity) }
}

public struct InnerGlowEffect: Codable, Equatable, Sendable {
    public var enabled: Bool? = nil
    public var size: Double = 10
    public var red: Double = 1
    public var green: Double = 1
    public var blue: Double = 1
    public var opacity: Double = 0.75
    public init(enabled: Bool? = nil, size: Double = 10, red: Double = 1, green: Double = 1, blue: Double = 1, opacity: Double = 0.75) {
        self.enabled = enabled; self.size = size; self.red = red; self.green = green; self.blue = blue; self.opacity = opacity
    }
    public var isEnabled: Bool { enabled ?? true }
    public var isValid: Bool { size.isFinite && (0...500).contains(size) && LayerTextStyle.validColor(red, green, blue, opacity) }
}

public struct LayerEffects: Codable, Equatable, Sendable {
    public var stroke: StrokeEffect?
    public var shadow: ShadowEffect?
    public var colorOverlay: ColorOverlayEffect?
    public var innerShadow: InnerShadowEffect?
    public var outerGlow: OuterGlowEffect?
    public var innerGlow: InnerGlowEffect?
    public init(stroke: StrokeEffect? = nil, shadow: ShadowEffect? = nil, colorOverlay: ColorOverlayEffect? = nil,
                innerShadow: InnerShadowEffect? = nil, outerGlow: OuterGlowEffect? = nil, innerGlow: InnerGlowEffect? = nil) {
        self.stroke = stroke; self.shadow = shadow; self.colorOverlay = colorOverlay
        self.innerShadow = innerShadow; self.outerGlow = outerGlow; self.innerGlow = innerGlow
    }
    public var isEmpty: Bool { stroke == nil && shadow == nil && colorOverlay == nil && innerShadow == nil && outerGlow == nil && innerGlow == nil }
    public var isValid: Bool { (stroke?.isValid ?? true) && (shadow?.isValid ?? true) && (colorOverlay?.isValid ?? true)
        && (innerShadow?.isValid ?? true) && (outerGlow?.isValid ?? true) && (innerGlow?.isValid ?? true) }
    public var hasVisibleEffects: Bool {
        (stroke.map { $0.isEnabled && $0.size > 0 && $0.opacity > 0 } ?? false)
            || (shadow.map { $0.isEnabled && $0.opacity > 0 } ?? false)
            || (colorOverlay.map { $0.isEnabled && $0.opacity > 0 } ?? false)
            || (innerShadow.map { $0.isEnabled && $0.opacity > 0 } ?? false)
            || (outerGlow.map { $0.isEnabled && $0.size > 0 && $0.opacity > 0 } ?? false)
            || (innerGlow.map { $0.isEnabled && $0.size > 0 && $0.opacity > 0 } ?? false)
    }
    public var padding: CGFloat {
        guard hasVisibleEffects else { return 0 }
        var value: Double = 0
        if let stroke, stroke.isEnabled, !stroke.inside, stroke.opacity > 0 { value = max(value, stroke.size) }
        if let shadow, shadow.isEnabled, shadow.opacity > 0 { value = max(value, shadow.distance + shadow.blur * 3) }
        if let outerGlow, outerGlow.isEnabled, outerGlow.opacity > 0 { value = max(value, outerGlow.size * 3) }
        return ceil(value) + 2
    }
    public func scaled(by factor: Double) throws -> Self {
        guard factor.isFinite, factor > 0 else { throw DocumentError.invalid("效果缩放比例无效") }
        var result = self
        result.stroke?.size = (stroke?.size ?? 0) * factor
        result.shadow?.distance = (shadow?.distance ?? 0) * factor
        result.shadow?.blur = (shadow?.blur ?? 0) * factor
        result.innerShadow?.distance = (innerShadow?.distance ?? 0) * factor
        result.innerShadow?.blur = (innerShadow?.blur ?? 0) * factor
        result.outerGlow?.size = (outerGlow?.size ?? 0) * factor
        result.innerGlow?.size = (innerGlow?.size ?? 0) * factor
        guard result.isValid else { throw DocumentError.unsupported("缩放后的图层效果超出支持范围") }
        return result
    }
}
