// Adapted from Compositor Curves.swift, Levels.swift and LayerAdjustment.swift,
// 365b5745eda537f984f3d5bed1e53c361dbc9c91. MIT © 2026 Wonder Assembly LLC.
// UIKit-independent parameter subset; unknown adjustment fields are rejected by DocumentStore.
import Foundation

public enum LevelsChannel: String, Codable, CaseIterable, Sendable {
    case rgb = "RGB", red = "Red", green = "Green", blue = "Blue"
    public var index: Int { Self.allCases.firstIndex(of: self)! }
    public var title: String {
        switch self { case .rgb: "RGB"; case .red: "红"; case .green: "绿"; case .blue: "蓝" }
    }
}

public struct LevelRange: Codable, Equatable, Sendable {
    public var black: Double = 0
    public var gamma: Double = 1
    public var white: Double = 255
    public var outputBlack: Double = 0
    public var outputWhite: Double = 255
    public init(black: Double = 0, gamma: Double = 1, white: Double = 255,
                outputBlack: Double = 0, outputWhite: Double = 255) {
        self.black = black; self.gamma = gamma; self.white = white
        self.outputBlack = outputBlack; self.outputWhite = outputWhite
    }
    public var isValid: Bool {
        [black, gamma, white, outputBlack, outputWhite].allSatisfy(\.isFinite)
            && (0...254).contains(black) && (black + 1...255).contains(white)
            && (0.1...9.99).contains(gamma) && (0...255).contains(outputBlack) && (0...255).contains(outputWhite)
    }
    /// Individual channel first, composite RGB second. Output endpoints may invert.
    public func apply(_ value: Double) -> Double {
        let input = min(1, max(0, (value * 255 - black) / (white - black)))
        return (outputBlack + pow(input, 1 / gamma) * (outputWhite - outputBlack)) / 255
    }
}

public struct LevelsSettings: Codable, Equatable, Sendable {
    public var channel: LevelsChannel = .rgb
    public var ranges = Array(repeating: LevelRange(), count: 4)
    public init() {}
    public var isValid: Bool { ranges.count == 4 && ranges.allSatisfy(\.isValid) }
    public var isIdentity: Bool { ranges == Array(repeating: LevelRange(), count: 4) }
    public func apply(_ value: Double, channel: LevelsChannel) -> Double {
        ranges[0].apply(ranges[channel.index].apply(value))
    }
}

public struct CurvePoint: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) { self.x = x; self.y = y }
}

public struct CurvesSettings: Codable, Equatable, Sendable {
    public var channel: LevelsChannel = .rgb
    public var channels = Array(repeating: [CurvePoint(x: 0, y: 0), CurvePoint(x: 255, y: 255)], count: 4)
    public init() {}
    public var isValid: Bool {
        channels.count == 4 && channels.allSatisfy { points in
            (2...32).contains(points.count) && points.first?.x == 0 && points.last?.x == 255
                && points.allSatisfy { $0.x.isFinite && $0.y.isFinite && (0...255).contains($0.x) && (0...255).contains($0.y) }
                && zip(points, points.dropFirst()).allSatisfy {
                    $0.x < $1.x && (($1.y - $0.y) / ($1.x - $0.x)).isFinite
                }
        }
    }
    public var isIdentity: Bool { channels.allSatisfy { $0.allSatisfy { $0.x == $0.y } } }
    /// Upstream shape-preserving cubic Hermite interpolation, with no overshoot at extrema.
    public func value(_ x: Double, channel: Int) -> Double {
        let p = channels[channel]
        let i = min(p.count - 2, max(0, p.lastIndex(where: { $0.x <= x }) ?? 0))
        let d = zip(p, p.dropFirst()).map { ($1.y - $0.y) / ($1.x - $0.x) }
        func slope(_ j: Int) -> Double {
            if j == 0 { return d[0] }
            if j == p.count - 1 { return d.last! }
            if d[j - 1] * d[j] <= 0 { return 0 }
            // Equivalent harmonic mean without reciprocal underflow for near-flat segments.
            let a = d[j - 1], b = d[j]
            let low = abs(a) < abs(b) ? a : b, high = abs(a) < abs(b) ? b : a
            return low / (0.5 + 0.5 * (low / high))
        }
        let h = p[i + 1].x - p[i].x, t = min(1, max(0, (x - p[i].x) / h))
        let y = (2*t*t*t - 3*t*t + 1)*p[i].y + (t*t*t - 2*t*t + t)*h*slope(i)
            + (-2*t*t*t + 3*t*t)*p[i + 1].y + (t*t*t - t*t)*h*slope(i + 1)
        return min(255, max(0, y))
    }
}

public enum AdjustmentKind: String, Codable, CaseIterable, Sendable {
    case levels = "Levels", curves = "Curves"
    public var title: String { self == .levels ? "色阶" : "曲线" }
    public var symbol: String { self == .levels ? "slider.horizontal.3" : "point.topleft.down.to.point.bottomright.curvepath" }
}

public struct LayerAdjustment: Codable, Equatable, Sendable {
    public var kind: AdjustmentKind
    public var levels = LevelsSettings()
    public var curves = CurvesSettings()
    public init(kind: AdjustmentKind) { self.kind = kind }
    public var isValid: Bool { levels.isValid && curves.isValid }
    public var isIdentity: Bool { kind == .levels ? levels.isIdentity : curves.isIdentity }
    public func hasSameEffect(as other: Self) -> Bool {
        kind == other.kind && (kind == .levels ? levels.ranges == other.levels.ranges : curves.channels == other.curves.channels)
    }
    /// Match the upstream record's required neutral HSV fields, without accepting an HSV edit.
    private enum CodingKeys: String, CodingKey { case kind, levels, curves, hue, saturation, lightness, colorize }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(AdjustmentKind.self, forKey: .kind)
        levels = try c.decodeIfPresent(LevelsSettings.self, forKey: .levels) ?? LevelsSettings()
        curves = try c.decodeIfPresent(CurvesSettings.self, forKey: .curves) ?? CurvesSettings()
        for key in [CodingKeys.hue, .saturation, .lightness] {
            guard (try c.decodeIfPresent(Double.self, forKey: key) ?? 0) == 0 else { throw DocumentError.unsupported("调整层的色相/饱和度参数") }
        }
        guard (try c.decodeIfPresent(Bool.self, forKey: .colorize) ?? false) == false, isValid
        else { throw DocumentError.invalid("调整层参数无效") }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind); try c.encode(levels, forKey: .levels); try c.encode(curves, forKey: .curves)
        for key in [CodingKeys.hue, .saturation, .lightness] { try c.encode(0.0, forKey: key) }
        try c.encode(false, forKey: .colorize)
    }
    /// Three 256-entry tables use the same channel order and Float interpolation as LevelsPixels.c.
    func lookupTables() throws -> [[Float]] {
        guard isValid else { throw DocumentError.invalid("曲线或色阶参数无效") }
        return [LevelsChannel.red, .green, .blue].map { channel in
            (0...255).map { x in
                Float(kind == .levels ? levels.apply(Double(x) / 255, channel: channel)
                      : curves.value(curves.value(Double(x), channel: channel.index), channel: 0) / 255)
            }
        }
    }
}
