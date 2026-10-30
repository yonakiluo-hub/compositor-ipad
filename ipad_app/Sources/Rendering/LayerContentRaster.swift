// CoreText/CG adaptation of Compositor TypeTool.swift and ShapeTool.swift,
// 365b5745eda537f984f3d5bed1e53c361dbc9c91. MIT © 2026 Wonder Assembly LLC.
import Foundation
import CoreGraphics
import CoreText

enum LayerContentRaster {
    static func missingFonts(_ style: LayerTextStyle) -> [String] {
        let requested = Set([style.fontName] + (style.fontRuns ?? []).map(\.fontName))
        return requested.filter { name in
            let font = CTFontCreateWithName(name as CFString, style.fontSize, nil)
            return (CTFontCopyPostScriptName(font) as String).caseInsensitiveCompare(name) != .orderedSame
        }.sorted()
    }

    private static func attributed(_ style: LayerTextStyle) -> NSAttributedString {
        var alignment: CTTextAlignment = style.alignment == .left ? .left : style.alignment == .center ? .center : .right
        var height = CGFloat(style.lineHeight), mode = CTLineBreakMode.byWordWrapping
        let paragraph = withUnsafePointer(to: &alignment) { a in withUnsafePointer(to: &height) { h in withUnsafePointer(to: &mode) { m in
            let settings = [CTParagraphStyleSetting(spec: .alignment, valueSize: MemoryLayout<CTTextAlignment>.size, value: a),
                            CTParagraphStyleSetting(spec: .minimumLineHeight, valueSize: MemoryLayout<CGFloat>.size, value: h),
                            CTParagraphStyleSetting(spec: .maximumLineHeight, valueSize: MemoryLayout<CGFloat>.size, value: h),
                            CTParagraphStyleSetting(spec: .lineBreakMode, valueSize: MemoryLayout<CTLineBreakMode>.size, value: m)]
            return CTParagraphStyleCreate(settings, settings.count)
        } } }
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(style.fontName as CFString, style.fontSize, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(srgbRed: style.red, green: style.green, blue: style.blue, alpha: 1),
            NSAttributedString.Key(kCTKernAttributeName as String): style.tracking,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph]
        let result = NSMutableAttributedString(string: style.content, attributes: attrs)
        for r in style.colorRuns ?? [] {
            result.addAttribute(NSAttributedString.Key(kCTForegroundColorAttributeName as String),
                                value: CGColor(srgbRed: r.red, green: r.green, blue: r.blue, alpha: 1),
                                range: NSRange(location: r.location, length: r.length))
        }
        for r in style.fontRuns ?? [] {
            result.addAttribute(NSAttributedString.Key(kCTFontAttributeName as String),
                                value: CTFontCreateWithName(r.fontName as CFString, style.fontSize, nil),
                                range: NSRange(location: r.location, length: r.length))
        }
        return result
    }

    static func textImage(_ style: LayerTextStyle) throws -> CGImage {
        guard style.isValid else { throw DocumentError.invalid("文字参数无效") }
        let string = attributed(style), padding = LayerTextStyle.padding
        let framesetter = CTFramesetterCreateWithAttributedString(string)
        let size: CGSize
        if let box = style.boxSize { size = box }
        else {
            let measured = CTFramesetterSuggestFrameSizeWithConstraints(framesetter, CFRange(location: 0, length: string.length), nil,
                CGSize(width: 100_000, height: 100_000), nil)
            size = CGSize(width: max(16, ceil(measured.width + padding * 2 + style.fontSize * 0.1)),
                          height: max(16, ceil(max(measured.height, style.lineHeight) + padding * 2)))
        }
        guard size.width.isFinite, size.height.isFinite, size.width <= 4096, size.height <= 4096 else { throw RasterError.oversized }
        let width = Int(ceil(size.width)), height = Int(ceil(size.height))
        let context = try RasterImage.context(width: width, height: height)
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        let path = CGPath(rect: CGRect(x: padding, y: CGFloat(height) - size.height + padding,
                                      width: max(1, size.width - padding * 2), height: max(1, size.height - padding * 2)), transform: nil)
        CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: string.length), path, nil), context)
        guard let image = context.makeImage() else { throw RasterError.allocation }
        return image
    }

    static func shapeImage(_ style: LayerShapeStyle, size: CGSize) throws -> CGImage {
        guard style.isValid, size.width.isFinite, size.height.isFinite, size.width >= 1, size.height >= 1,
              size.width <= 4096, size.height <= 4096 else { throw DocumentError.invalid("形状参数或尺寸无效") }
        let width = Int(ceil(size.width)), height = Int(ceil(size.height))
        let context = try RasterImage.context(width: width, height: height)
        context.scaleBy(x: CGFloat(width) / size.width, y: CGFloat(height) / size.height)
        let bounds = CGRect(origin: .zero, size: size)
        let color = CGColor(srgbRed: style.red, green: style.green, blue: style.blue, alpha: 1)
        if style.kind == .line {
            let lineWidth = style.lineWidth ?? 1
            let inset = bounds.insetBy(dx: min(lineWidth, size.width) / 2, dy: min(lineWidth, size.height) / 2)
            let from = style.start.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) } ?? CGPoint(x: inset.minX, y: inset.minY)
            let to = style.end.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) } ?? CGPoint(x: inset.maxX, y: inset.maxY)
            context.setStrokeColor(color); context.setLineWidth(lineWidth); context.setLineCap(.round)
            context.move(to: from); context.addLine(to: to); context.strokePath()
        } else {
            context.setFillColor(color); context.addPath(path(style, in: bounds)); context.fillPath()
        }
        guard let image = context.makeImage() else { throw RasterError.allocation }
        return image
    }

    static func path(_ style: LayerShapeStyle, in rect: CGRect) -> CGPath {
        if style.kind == .ellipse { return CGPath(ellipseIn: rect, transform: nil) }
        let radius = min(max(0, style.cornerRadius), rect.width / 2, rect.height / 2)
        guard radius > 0 else { return CGPath(rect: rect, transform: nil) }
        let smoothing = style.smoothing == true ? min(CGFloat(0.6), max(0, min(rect.width, rect.height) / (2 * radius) - 1)) : 0
        guard smoothing > 0 else { return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil) }
        let reach = (1 + smoothing) * radius, angle = smoothing * .pi / 4
        let tangent = radius * tan(angle / 2), c = tangent * cos(angle), d = tangent * sin(angle)
        let arcLength = radius * sqrt(2) * sin((1 - smoothing) * .pi / 4), b = (reach - arcLength - c - d) / 3, a = 2 * b
        let result = CGMutablePath()
        let corners = [CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY),
                       CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.minY)]
        for (i, corner) in corners.enumerated() {
            let transform = CGAffineTransform(translationX: corner.x, y: corner.y).rotated(by: CGFloat(i) * .pi / 2)
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y).applying(transform) }
            if i == 0 { result.move(to: point(-reach, 0)) } else { result.addLine(to: point(-reach, 0)) }
            result.addCurve(to: point(-reach + a + b + c, d), control1: point(-reach + a, 0), control2: point(-reach + a + b, 0))
            result.addArc(center: CGPoint(x: -radius, y: radius), radius: radius, startAngle: -.pi / 2 + angle,
                          endAngle: -angle, clockwise: false, transform: transform)
            result.addCurve(to: point(0, reach), control1: point(0, reach - a - b), control2: point(0, reach - a))
        }
        result.closeSubpath(); return result
    }

    /// Keep shape radii in document pixels rather than stretching their cached raster.
    static func redrawShape(_ layer: RasterLayer) throws -> RasterLayer {
        guard let style = layer.shape else { return layer }
        var result = layer
        result.pngData = try RasterImage.png(shapeImage(style, size: layer.transform.size))
        return result
    }
}
