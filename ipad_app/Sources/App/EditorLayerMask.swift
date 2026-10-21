import UIKit

enum LayerEditTarget { case pixels, mask }

/// Numeric coverage, following Compositor LayerMask/BrushRaster at 7c2a5a4.
/// MIT © 2026 Wonder Assembly LLC. White reveals; black hides; gray is not color-managed.
enum PadMaskRaster {
    static func draw(_ image: CGImage, in rect: CGRect, context: CGContext) {
        context.saveGState()
        context.setFillColor(gray: 0, alpha: 1); context.fill(rect)
        RasterImage.clip(image, to: rect, context: context)
        context.setFillColor(gray: 1, alpha: 1); context.fill(rect)
        context.restoreGState()
    }

    static func selection(_ selection: CGImage?, layer: RasterLayer, size: CGSize,
                          document: CanvasDocument, renderer: DocumentRenderer) throws -> CGImage? {
        guard let selection else { return nil }
        let context = try RasterImage.context(width: Int(size.width), height: Int(size.height), gray: true)
        context.concatenate(renderer.pixelToDocument(layer, size: size).inverted())
        draw(selection, in: CGRect(origin: .zero, size: document.size), context: context)
        guard let image = context.makeImage() else { throw RasterError.allocation }
        return image
    }
}

/// A pointer edits its frozen mask only; navigation or other edits invalidate its commit.
@MainActor
final class LayerMaskStrokeSession {
    let documentID: UUID
    let revision: Int64
    let layer: RasterLayer
    let selectionPNGData: Data?
    let tool: PadTool
    let reveals: Bool
    let stroke: PadBrushStroke
    let sourcePixels: CGImage

    init(model: EditorModel) throws {
        guard model.layerEditTarget == .mask, [.brush, .eraser].contains(model.tool),
              model.selectedLayerIDs.count <= 1, let layer = model.activeLayer,
              let data = layer.maskPNGData else { throw DocumentError.invalid("请选择图层或图层组的蒙版") }
        guard !model.document.isEffectivelyLocked(layer.id) else { throw DocumentError.lockedLayer }
        documentID = model.document.id; revision = model.document.revision
        self.layer = layer; selectionPNGData = model.document.selectionMaskPNGData
        tool = model.tool; reveals = model.maskPaintReveals
        let original = try RasterImage.decode(data)
        let size = CGSize(width: original.width, height: original.height)
        stroke = try PadBrushStroke(width: original.width, height: original.height, original: original,
            settings: model.layerMaskBrushSettings,
            selection: PadMaskRaster.selection(model.selectionPreview, layer: layer, size: size,
                document: model.document, renderer: model.renderer), maskMode: true,
            brushToPixels: model.renderer.pixelToDocument(layer, size: size).inverted())
        if let source = try model.renderer.image(for: layer) { sourcePixels = source }
        else {
            // A group preview reads its children, never this placeholder image.
            let pixelSize = try layer.isGroup ? CGSize(width: 1, height: 1) : model.renderer.pixelSize(of: layer)
            let context = try RasterImage.context(width: Int(pixelSize.width), height: Int(pixelSize.height))
            guard let image = context.makeImage() else { throw RasterError.allocation }
            sourcePixels = image
        }
    }

    func isCurrent(in model: EditorModel) -> Bool {
        model.document.id == documentID && model.document.revision == revision &&
        model.layerEditTarget == .mask && model.tool == tool && model.maskPaintReveals == reveals &&
        model.selectedLayerIDs.count <= 1 && model.activeLayer == layer &&
        model.document.selectionMaskPNGData == selectionPNGData && !model.document.isEffectivelyLocked(layer.id)
    }
}

extension EditorModel {
    func chooseMaskPaintMode(reveals: Bool) {
        maskPaintReveals = reveals
        tool = .brush
    }

    var layerMaskBrushSettings: PadBrushSettings {
        var settings = brushSettings
        settings.erasing = tool == .eraser || !maskPaintReveals
        return settings
    }

    func normalizeLayerEditTarget() {
        if layerEditTarget == .mask &&
            (activeLayer?.maskPNGData == nil || selectedLayerIDs.count > 1) {
            layerEditTarget = .pixels
        }
    }

    func setLayerEditTarget(_ target: LayerEditTarget) {
        guard target == .pixels ||
            (activeLayer?.maskPNGData != nil && selectedLayerIDs.count <= 1) else { return }
        cancelTransform()
        layerEditTarget = target
        if target == .mask { tool = .brush }
    }

    func addLayerMask() {
        guard let layer = activeLayer, layer.maskPNGData == nil, selectedLayerIDs.count <= 1 else { return }
        report {
            let size = try layer.isGroup ? document.size : renderer.pixelSize(of: layer)
            let data = try RasterImage.png(RasterImage.solidMask(width: Int(size.width), height: Int(size.height), white: true))
            updateLayer(layer.isGroup ? "添加组蒙版" : "添加图层蒙版") {
                if $0.isGroup { $0.transform = LayerTransform(size: size, sampling: .nearest) }
                $0.maskPNGData = data; $0.maskEnabled = true
            }
            if activeLayer?.maskPNGData != nil { setLayerEditTarget(.mask) }
        }
    }

    func removeLayerMask() {
        guard activeLayer?.maskPNGData != nil, selectedLayerIDs.count <= 1 else { return }
        updateLayer("删除图层蒙版") { $0.maskPNGData = nil }
        normalizeLayerEditTarget()
    }

    func setLayerMaskEnabled(_ enabled: Bool) {
        guard activeLayer?.maskPNGData != nil, selectedLayerIDs.count <= 1 else { return }
        updateLayer(enabled ? "启用图层蒙版" : "停用图层蒙版") { $0.maskEnabled = enabled }
    }

    @discardableResult
    func commitLayerMaskStroke(_ session: LayerMaskStrokeSession) -> Bool {
        guard session.isCurrent(in: self) else { return false }
        do {
            let data = try RasterImage.png(session.stroke.image())
            try editor.updateLayer(session.layer.id, name: "绘制图层蒙版") { $0.maskPNGData = data }
            changed()
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func fillLayerMask(reveal: Bool) {
        guard let layer = activeLayer, let data = layer.maskPNGData, selectedLayerIDs.count <= 1 else { return }
        report {
            let original = try RasterImage.decode(data)
            let size = CGSize(width: original.width, height: original.height), rect = CGRect(origin: .zero, size: size)
            let context = try RasterImage.context(width: original.width, height: original.height, gray: true)
            PadMaskRaster.draw(original, in: rect, context: context)
            if let selection = try PadMaskRaster.selection(selectionPreview, layer: layer, size: size, document: document, renderer: renderer) {
                RasterImage.clip(selection, to: rect, context: context)
            }
            context.setAlpha(brushOpacity); context.setFillColor(gray: reveal ? 1 : 0, alpha: 1); context.fill(rect)
            guard let image = context.makeImage() else { throw RasterError.allocation }
            let png = try RasterImage.png(image)
            updateLayer(reveal ? "填充蒙版为白色" : "填充蒙版为黑色") { $0.maskPNGData = png }
        }
    }

    func invertLayerMask() {
        guard let layer = activeLayer, let data = layer.maskPNGData, selectedLayerIDs.count <= 1 else { return }
        report {
            let original = try RasterImage.decode(data)
            let size = CGSize(width: original.width, height: original.height), rect = CGRect(origin: .zero, size: size)
            let context = try RasterImage.context(width: original.width, height: original.height, gray: true)
            PadMaskRaster.draw(original, in: rect, context: context)
            if let selection = try PadMaskRaster.selection(selectionPreview, layer: layer, size: size, document: document, renderer: renderer) {
                RasterImage.clip(selection, to: rect, context: context)
            }
            context.setBlendMode(.difference); context.setFillColor(gray: 1, alpha: 1); context.fill(rect)
            guard let image = context.makeImage() else { throw RasterError.allocation }
            let png = try RasterImage.png(image)
            updateLayer("反相图层蒙版") { $0.maskPNGData = png }
        }
    }

    func layerMaskToSelection() {
        guard let layer = activeLayer, let data = layer.maskPNGData, selectedLayerIDs.count <= 1 else { return }
        report {
            let mask = try RasterImage.decode(data)
            let context = try RasterImage.context(width: document.width, height: document.height, gray: true)
            context.concatenate(renderer.pixelToDocument(layer, size: CGSize(width: mask.width, height: mask.height)))
            PadMaskRaster.draw(mask, in: CGRect(x: 0, y: 0, width: mask.width, height: mask.height), context: context)
            guard let image = context.makeImage() else { throw RasterError.allocation }
            let png = try RasterImage.png(image)
            edit("从图层蒙版载入选区") { $0.selectionMaskPNGData = png }
        }
    }
}
