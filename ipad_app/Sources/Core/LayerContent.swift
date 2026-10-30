// Adapted from Compositor TypeTool.swift and ShapeTool.swift at
// 365b5745eda537f984f3d5bed1e53c361dbc9c91. MIT © 2026 Wonder Assembly LLC.
// iPad keeps the standard PNG fallback and editable metadata separately.
import Foundation
import CoreGraphics

public enum TextAlignment: String, Codable, CaseIterable, Sendable {
    case left = "Left", center = "Center", right = "Right"
    public var title: String { self == .left ? "左对齐" : self == .center ? "居中" : "右对齐" }
}

public struct LayerTextColorRun: Codable, Equatable, Sendable {
    public var location: Int
    public var length: Int
    public var red: Double
    public var green: Double
    public var blue: Double
    public init(location: Int, length: Int, red: Double, green: Double, blue: Double) {
        self.location = location; self.length = length; self.red = red; self.green = green; self.blue = blue
    }
}

public struct LayerTextFontRun: Codable, Equatable, Sendable {
    public var location: Int
    public var length: Int
    public var fontName: String
    public init(location: Int, length: Int, fontName: String) { self.location = location; self.length = length; self.fontName = fontName }
}

public struct LayerTextStyle: Codable, Equatable, Sendable {
    public var content: String = "文字"
    public var fontName: String = "Helvetica"
    public var fontSize: Double = 48
    public var red: Double = 0
    public var green: Double = 0
    public var blue: Double = 0
    public var alignment: TextAlignment = .left
    public var tracking: Double = 0
    /// Baseline-to-baseline distance; zero uses 120% of the font size.
    public var leading: Double = 0
    public var boxSize: CGSize? = nil
    public var colorRuns: [LayerTextColorRun]? = nil
    public var fontRuns: [LayerTextFontRun]? = nil
    public static let padding: CGFloat = 12
    public init(content: String = "文字", fontName: String = "Helvetica", fontSize: Double = 48,
                red: Double = 0, green: Double = 0, blue: Double = 0, alignment: TextAlignment = .left,
                tracking: Double = 0, leading: Double = 0, boxSize: CGSize? = nil,
                colorRuns: [LayerTextColorRun]? = nil, fontRuns: [LayerTextFontRun]? = nil) {
        self.content = content; self.fontName = fontName; self.fontSize = fontSize
        self.red = red; self.green = green; self.blue = blue; self.alignment = alignment
        self.tracking = tracking; self.leading = leading; self.boxSize = boxSize
        self.colorRuns = colorRuns; self.fontRuns = fontRuns
    }
    public var lineHeight: Double { leading > 0 ? leading : fontSize * 1.2 }
    var estimatedBytes: Int {
        content.utf8.count + fontName.utf8.count + (colorRuns?.count ?? 0) * 80
            + (fontRuns ?? []).reduce(0) { $0 + $1.fontName.utf8.count + 48 }
    }
    static func validFontName(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 512 && !value.contains(where: \.isNewline) }
    static func validColor(_ values: Double...) -> Bool { values.allSatisfy { $0.isFinite && (0...1).contains($0) } }
    public var isValid: Bool {
        guard content.utf16.count <= 100_000, Self.validFontName(fontName), fontSize.isFinite, (1...2000).contains(fontSize),
              Self.validColor(red, green, blue), tracking.isFinite, (-100...1000).contains(tracking),
              leading.isFinite, (0...5000).contains(leading) else { return false }
        if let size = boxSize {
            guard size.width.isFinite, size.height.isFinite, (16...4096).contains(size.width), (16...4096).contains(size.height),
                  size.width * size.height <= 16_000_000 else { return false }
        }
        if let runs = colorRuns {
            guard !runs.isEmpty, runs.count <= content.utf16.count else { return false }
            var end = 0
            for r in runs {
                guard r.location >= end, r.length > 0, r.location <= content.utf16.count - r.length,
                      Self.validColor(r.red, r.green, r.blue) else { return false }
                end = r.location + r.length
            }
        }
        if let runs = fontRuns {
            guard !runs.isEmpty, runs.count <= content.utf16.count else { return false }
            var end = 0
            for r in runs {
                guard r.location >= end, r.length > 0, r.location <= content.utf16.count - r.length,
                      Self.validFontName(r.fontName) else { return false }
                end = r.location + r.length
            }
        }
        return true
    }
}

public enum ShapeKind: String, Codable, CaseIterable, Sendable {
    case rectangle = "Rectangle", ellipse = "Ellipse", line = "Line"
    public var title: String { self == .rectangle ? "矩形" : self == .ellipse ? "椭圆" : "直线" }
}

public struct LayerShapeStyle: Codable, Equatable, Sendable {
    public var kind: ShapeKind
    public var red: Double
    public var green: Double
    public var blue: Double
    /// Document pixels. Free-transform redraws shape pixels at their new size.
    public var cornerRadius: Double
    public var smoothing: Bool?
    public var lineWidth: Double?
    public var start: CGPoint?
    public var end: CGPoint?
    public init(kind: ShapeKind = .rectangle, red: Double = 0.2, green: Double = 0.7, blue: Double = 0.6,
                cornerRadius: Double = 0, smoothing: Bool? = nil, lineWidth: Double? = nil,
                start: CGPoint? = nil, end: CGPoint? = nil) {
        self.kind = kind; self.red = red; self.green = green; self.blue = blue; self.cornerRadius = cornerRadius
        self.smoothing = smoothing; self.lineWidth = lineWidth; self.start = start; self.end = end
    }
    public var isValid: Bool {
        guard LayerTextStyle.validColor(red, green, blue), cornerRadius.isFinite, (0...4096).contains(cornerRadius) else { return false }
        if let lineWidth, (!lineWidth.isFinite || !(1...500).contains(lineWidth)) { return false }
        for point in [start, end].compactMap({ $0 }) {
            guard point.x.isFinite, point.y.isFinite, (0...1).contains(point.x), (0...1).contains(point.y) else { return false }
        }
        guard (start == nil) == (end == nil) else { return false }
        return kind == .line || (lineWidth == nil && start == nil && end == nil)
    }
}

public extension RasterLayer {
    var hasEditableContent: Bool { text != nil || shape != nil }
    /// Explicit rasterization leaves the current cached pixels and all effects untouched.
    mutating func rasterizeContent() { text = nil; shape = nil }
}
