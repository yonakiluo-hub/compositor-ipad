import Foundation

enum LayerEffectKind: String, CaseIterable, Sendable {
    case stroke, shadow, colorOverlay, innerShadow, outerGlow, innerGlow
    var title: String {
        switch self { case .stroke: "描边"; case .shadow: "投影"; case .colorOverlay: "颜色叠加"
        case .innerShadow: "内阴影"; case .outerGlow: "外发光"; case .innerGlow: "内发光" }
    }
    var defaultParameters: LayerEffectParameters {
        var p = LayerEffectParameters()
        switch self {
        case .stroke: p.size = 4; p.opacity = 1
        case .shadow: break
        case .colorOverlay: p.opacity = 1
        case .innerShadow: p.distance = 10; p.blur = 10
        case .outerGlow: p.red = 1; p.green = 1; p.blue = 1; p.opacity = 0.75
        case .innerGlow: p.red = 1; p.green = 1; p.blue = 1; p.opacity = 0.75; p.size = 10
        }
        return p
    }
}

struct LayerEffectParameters {
    var enabled = true
    var red: Double = 0, green: Double = 0, blue: Double = 0
    var opacity: Double = 0.5, size: Double = 20, angle: Double = 90, distance: Double = 20, blur: Double = 20
    var inside = false
}

extension LayerEffects {
    var normalized: Self {
        var v = self
        if v.stroke?.enabled == true { v.stroke?.enabled = nil }
        if v.shadow?.enabled == true { v.shadow?.enabled = nil }
        if v.colorOverlay?.enabled == true { v.colorOverlay?.enabled = nil }
        if v.innerShadow?.enabled == true { v.innerShadow?.enabled = nil }
        if v.outerGlow?.enabled == true { v.outerGlow?.enabled = nil }
        if v.innerGlow?.enabled == true { v.innerGlow?.enabled = nil }
        return v
    }
    func parameters(_ kind: LayerEffectKind) -> LayerEffectParameters? {
        var p = kind.defaultParameters
        switch kind {
        case .stroke:
            guard let v = stroke else { return nil }; p.enabled = v.isEnabled; p.size = v.size; p.inside = v.inside
            p.red = v.red; p.green = v.green; p.blue = v.blue; p.opacity = v.opacity
        case .shadow:
            guard let v = shadow else { return nil }; p.enabled = v.isEnabled; p.angle = v.angle; p.distance = v.distance; p.blur = v.blur
            p.red = v.red; p.green = v.green; p.blue = v.blue; p.opacity = v.opacity
        case .colorOverlay:
            guard let v = colorOverlay else { return nil }; p.enabled = v.isEnabled
            p.red = v.red; p.green = v.green; p.blue = v.blue; p.opacity = v.opacity
        case .innerShadow:
            guard let v = innerShadow else { return nil }; p.enabled = v.isEnabled; p.angle = v.angle; p.distance = v.distance; p.blur = v.blur
            p.red = v.red; p.green = v.green; p.blue = v.blue; p.opacity = v.opacity
        case .outerGlow:
            guard let v = outerGlow else { return nil }; p.enabled = v.isEnabled; p.size = v.size
            p.red = v.red; p.green = v.green; p.blue = v.blue; p.opacity = v.opacity
        case .innerGlow:
            guard let v = innerGlow else { return nil }; p.enabled = v.isEnabled; p.size = v.size
            p.red = v.red; p.green = v.green; p.blue = v.blue; p.opacity = v.opacity
        }
        return p
    }
    mutating func set(_ p: LayerEffectParameters, kind: LayerEffectKind) {
        let enabled: Bool? = p.enabled ? nil : false
        switch kind {
        case .stroke: stroke = StrokeEffect(enabled: enabled, size: p.size, red: p.red, green: p.green, blue: p.blue, opacity: p.opacity, inside: p.inside)
        case .shadow: shadow = ShadowEffect(enabled: enabled, angle: p.angle, distance: p.distance, blur: p.blur, red: p.red, green: p.green, blue: p.blue, opacity: p.opacity)
        case .colorOverlay: colorOverlay = ColorOverlayEffect(enabled: enabled, red: p.red, green: p.green, blue: p.blue, opacity: p.opacity)
        case .innerShadow: innerShadow = InnerShadowEffect(enabled: enabled, angle: p.angle, distance: p.distance, blur: p.blur, red: p.red, green: p.green, blue: p.blue, opacity: p.opacity)
        case .outerGlow: outerGlow = OuterGlowEffect(enabled: enabled, size: p.size, red: p.red, green: p.green, blue: p.blue, opacity: p.opacity)
        case .innerGlow: innerGlow = InnerGlowEffect(enabled: enabled, size: p.size, red: p.red, green: p.green, blue: p.blue, opacity: p.opacity)
        }
    }
    mutating func remove(_ kind: LayerEffectKind) {
        switch kind {
        case .stroke: stroke = nil; case .shadow: shadow = nil; case .colorOverlay: colorOverlay = nil
        case .innerShadow: innerShadow = nil; case .outerGlow: outerGlow = nil; case .innerGlow: innerGlow = nil
        }
    }
}

struct LayerEffectsEdit: Sendable {
    let source: CanvasDocument
    let layerID: UUID
    let original: LayerEffects
    private let index: Int
    init(document: CanvasDocument) throws {
        try document.validate()
        guard let layer = document.activeLayer, !layer.isGroup, layer.adjustment == nil, layer.pngData != nil,
              let index = document.layers.firstIndex(where: { $0.id == layer.id }) else { throw DocumentError.invalid("请选择有内容的普通图层、文字或形状图层") }
        guard !document.isEffectivelyLocked(layer.id) else { throw DocumentError.lockedLayer }
        source = document; layerID = layer.id; self.index = index; original = (layer.effects ?? LayerEffects()).normalized
    }
    func hasChanges(_ value: LayerEffects) -> Bool { value.normalized != original }
    func preview(_ value: LayerEffects) throws -> CanvasDocument {
        guard value.isValid else { throw DocumentError.invalid("效果参数无效") }
        guard hasChanges(value) else { return source }
        var doc = source
        doc.layers[index].effects = value.isEmpty ? nil : value.normalized
        try doc.validate(); return doc
    }
    func apply(_ value: LayerEffects, to document: inout CanvasDocument) throws {
        guard document == source else { throw DocumentError.staleRevision }
        document = try preview(value)
    }
}
