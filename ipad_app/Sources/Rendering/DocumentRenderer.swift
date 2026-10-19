import Foundation
import CoreGraphics
import CoreImage

final class DocumentRenderer {
    private var images: [UUID: (Data, CGImage)] = [:]
    private var masks: [UUID: (Data, CGImage)] = [:]
    private let ciContext = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])

    func image(for layer: RasterLayer) throws -> CGImage? {
        guard let data = layer.pngData else { return nil }
        if let hit = images[layer.id], hit.0 == data { return hit.1 }
        let image = try RasterImage.decode(data)
        images[layer.id] = (data, image)
        return image
    }
    func clearCache() { images.removeAll(); masks.removeAll() }
    func pixelSize(of layer: RasterLayer) throws -> CGSize {
        if let image = try image(for: layer) { return CGSize(width: image.width, height: image.height) }
        return CGSize(width: max(1, Int(layer.transform.size.width)), height: max(1, Int(layer.transform.size.height)))
    }
    func pixelToDocument(_ layer: RasterLayer, size: CGSize) -> CGAffineTransform {
        let t = layer.transform
        return CGAffineTransform(translationX: t.center.x, y: t.center.y)
            .rotated(by: t.radians)
            .scaledBy(x: t.size.width / size.width * (t.flipX ? -1 : 1),
                      y: t.size.height / size.height * (t.flipY ? -1 : 1))
            .translatedBy(x: -size.width / 2, y: -size.height / 2)
    }
    func localSelection(_ mask: CGImage?, layer: RasterLayer, document: CanvasDocument) throws -> CGImage? {
        guard let mask else { return nil }
        let size = try pixelSize(of: layer)
        let context = try RasterImage.context(width: Int(size.width), height: Int(size.height), gray: true)
        context.concatenate(pixelToDocument(layer, size: size).inverted())
        RasterImage.draw(mask, in: CGRect(origin: .zero, size: document.size), context: context)
        return context.makeImage()
    }
    func render(_ document: CanvasDocument, replacing layerID: UUID? = nil, with replacement: CGImage? = nil) throws -> CGImage {
        let context = try RasterImage.context(width: document.width, height: document.height)
        for entry in document.renderLayers {
            let layer = entry.layer
            guard let image = layer.id == layerID ? replacement : try self.image(for: layer) else { continue }
            context.saveGState()
            context.setAlpha(entry.effectiveOpacity)
            context.setBlendMode(layer.blendMode.cgMode)
            try drawLayer(layer, image: image, context: context)
            context.restoreGState()
        }
        let ids = Set(document.layers.map(\.id))
        images = images.filter { ids.contains($0.key) }; masks = masks.filter { ids.contains($0.key) }
        guard let image = context.makeImage() else { throw RasterError.allocation }
        return image
    }
    func drawLayer(_ layer: RasterLayer, image: CGImage, context: CGContext) throws {
        let transform = layer.transform
        context.translateBy(x: transform.center.x, y: transform.center.y)
        context.rotate(by: transform.radians)
        context.scaleBy(x: transform.flipX ? -1 : 1, y: transform.flipY ? -1 : 1)
        let rect = CGRect(x: -transform.size.width / 2, y: -transform.size.height / 2,
                          width: transform.size.width, height: transform.size.height)
        context.interpolationQuality = transform.sampling.quality
        if layer.maskEnabled, let data = layer.maskPNGData {
            let mask: CGImage
            if let hit = masks[layer.id], hit.0 == data { mask = hit.1 }
            else { mask = try RasterImage.decode(data); masks[layer.id] = (data, mask) }
            RasterImage.clip(mask, to: rect, context: context)
        }
        RasterImage.draw(image, in: rect, context: context)
    }
    func layerOnCanvas(_ layer: RasterLayer, document: CanvasDocument) throws -> CGImage {
        let context = try RasterImage.context(width: document.width, height: document.height)
        if let image = try image(for: layer) { try drawLayer(layer, image: image, context: context) }
        guard let image = context.makeImage() else { throw RasterError.allocation }
        return image
    }
    func adjusted(_ image: CGImage, brightness: Double, contrast: Double, saturation: Double, blur: Double) throws -> CGImage {
        let source = CIImage(cgImage: image)
        var output = source.applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: brightness,
                                                                            kCIInputContrastKey: contrast,
                                                                            kCIInputSaturationKey: saturation])
        if blur > 0 { output = output.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: blur]).cropped(to: source.extent) }
        guard let result = ciContext.createCGImage(output, from: source.extent, format: .RGBA8,
                                                  colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else { throw RasterError.allocation }
        return result
    }
}
