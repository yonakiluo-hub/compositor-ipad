import UIKit

struct BrushSample {
    let point: CGPoint
    let pressure: CGFloat
    let altitude: CGFloat
    let azimuth: CGFloat
}

struct PadBrushSettings {
    var diameter: CGFloat = 28
    var hardness: CGFloat = 0.8
    var opacity: CGFloat = 1
    var color: UIColor = .black
    var erasing = false
}

/// A stroke owns one coverage buffer; opacity is applied once to the original pixels.
final class PadBrushStroke {
    let coverage: CGContext
    let original: CGImage?
    let settings: PadBrushSettings
    let size: CGSize
    let selection: CGImage?
    let maskMode: Bool
    private var previous: BrushSample?
    private let brushToPixels: CGAffineTransform
    init(width: Int, height: Int, original: CGImage?, settings: PadBrushSettings,
         selection: CGImage?, maskMode: Bool, brushToPixels: CGAffineTransform = .identity) throws {
        self.brushToPixels = CGAffineTransform(a: brushToPixels.a, b: brushToPixels.b, c: brushToPixels.c, d: brushToPixels.d, tx: 0, ty: 0)
        self.original = original; self.settings = settings; self.selection = selection; self.maskMode = maskMode
        size = CGSize(width: width, height: height)
        coverage = try RasterImage.context(width: width, height: height, gray: true)
        coverage.setBlendMode(.lighten)
    }
    func add(_ sample: BrushSample) {
        if let previous {
            let distance = hypot(sample.point.x - previous.point.x, sample.point.y - previous.point.y)
            let scale = min(hypot(brushToPixels.a, brushToPixels.b), hypot(brushToPixels.c, brushToPixels.d))
            let count = min(20_000, max(1, Int(ceil(distance / max(0.5, settings.diameter * scale * 0.1)))))
            for i in 1...count {
                let t = CGFloat(i) / CGFloat(count)
                dab(BrushSample(point: CGPoint(x: previous.point.x + (sample.point.x - previous.point.x) * t,
                                              y: previous.point.y + (sample.point.y - previous.point.y) * t),
                                pressure: previous.pressure + (sample.pressure - previous.pressure) * t,
                                altitude: sample.altitude, azimuth: sample.azimuth))
            }
        } else { dab(sample) }
        previous = sample
    }
    private func dab(_ sample: BrushSample) {
        let radius = max(0.5, settings.diameter / 2 * (0.15 + 0.85 * sample.pressure))
        coverage.saveGState()
        coverage.translateBy(x: sample.point.x, y: sample.point.y)
        coverage.concatenate(brushToPixels)
        coverage.rotate(by: sample.azimuth)
        // A tilted Pencil broadens the tip perpendicular to the barrel, within a bounded range.
        coverage.scaleBy(x: 1, y: 1 + max(0, 1 - sin(sample.altitude)) * 0.65)
        if settings.hardness >= 0.98 {
            coverage.setFillColor(gray: 1, alpha: 1)
            coverage.fillEllipse(in: CGRect(x: -radius, y: -radius, width: 2 * radius, height: 2 * radius))
        } else {
            let locations: [CGFloat] = [0, settings.hardness, settings.hardness + (1 - settings.hardness) * 0.33,
                                       settings.hardness + (1 - settings.hardness) * 0.66, 1]
            let colors = [CGFloat(1), 1, RasterImage.brushFalloff(0.33), RasterImage.brushFalloff(0.66), 0]
                .map { CGColor(gray: $0, alpha: 1) }
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceGray(), colors: colors as CFArray, locations: locations) {
                coverage.drawRadialGradient(gradient, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: radius, options: [])
            }
        }
        coverage.restoreGState()
    }
    func image() throws -> CGImage {
        let context = try RasterImage.context(width: Int(size.width), height: Int(size.height), gray: maskMode)
        let rect = CGRect(origin: .zero, size: size)
        if let original { RasterImage.draw(original, in: rect, context: context) }
        guard let mask = coverage.makeImage() else { throw RasterError.allocation }
        if let selection { RasterImage.clip(selection, to: rect, context: context) }
        RasterImage.clip(mask, to: rect, context: context)
        context.setAlpha(settings.opacity)
        if maskMode {
            context.setFillColor(gray: settings.erasing ? 0 : 1, alpha: 1)
        } else if settings.erasing {
            context.setBlendMode(.destinationOut); context.setFillColor(CGColor(gray: 0, alpha: 1))
        } else { context.setFillColor(settings.color.cgColor) }
        context.fill(rect)
        guard let image = context.makeImage() else { throw RasterError.allocation }
        return image
    }
}
