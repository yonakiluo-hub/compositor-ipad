import Foundation
import CoreGraphics

enum ImageSelectionKind { case wand, object, subject }

struct ImageSelectionContext: Sendable {
    let id = UUID()
    let source: CanvasDocument
    let selectedIDs: Set<UUID>
    let tool: PadTool
    let settings: ImageSelectionSettings
    let mode: SelectionCombineMode
    let feather: Double
    let editTarget: LayerEditTarget
}

extension EditorModel {
    func cancelImageSelection() {
        guard imageSelectionContext != nil || imageSelectionBusy else { return }
        imageSelectionContext = nil; imageSelectionBusy = false
        imageSelectionTask?.cancel()
        // Keep a canceled worker until it exits; a later tap cannot allocate a
        // second recognition request while the old one is still completing.
    }

    @discardableResult
    func selectImage(at point:CGPoint? = nil,kind:ImageSelectionKind) -> Bool {
        guard imageSelectionTask == nil else {
            if !imageSelectionBusy { errorMessage = "上一次选区任务仍在结束，请稍后重试。" }
            return false
        }
        cancelTransform()
        guard imageSelectionSettings.isValid else { errorMessage = ImageSelectionError.invalid.localizedDescription;return false }
        if selectionPreview == nil && (selectionMode == .subtract || selectionMode == .intersect) {
            errorMessage = "请先创建选区，再使用减去或相交。";return false
        }
        do {
            let context = ImageSelectionContext(source:document,selectedIDs:selectedLayerIDs,tool:tool,
                settings:imageSelectionSettings,mode:selectionMode,feather:selectionFeather,editTarget:layerEditTarget)
            if !context.settings.sampleAllLayers {
                guard let layer=context.source.activeLayer,!layer.isGroup,layer.adjustment == nil else {
                    throw DocumentError.invalid("请选择普通图层，或改为取样可见合成。")
                }
            }
            imageSelectionContext = context;imageSelectionBusy = true
            let detector = imageSubjectDetector
            imageSelectionTask = Task { [weak self] in
                let result = await DocumentPreviewQueue.shared.perform {
                    let image = try Self.makeImageSelectionSample(context.source,allLayers:context.settings.sampleAllLayers)
                    let mask:CGImage
                        switch kind {
                        case .wand:
                            guard let point else { throw ImageSelectionError.outside }
                            mask = try ImageSelectionRaster.wand(image,at:point,settings:context.settings)
                        case .object: mask = try detector(image,point)
                        case .subject: mask = try detector(image,nil)
                        }
                    return DocumentPreviewImage(image:mask)
                }
                guard let self else { return }
                self.imageSelectionTask = nil
                guard self.imageSelectionContext?.id == context.id else { return }
                self.imageSelectionContext = nil;self.imageSelectionBusy = false
                guard self.document == context.source,self.selectedLayerIDs == context.selectedIDs,self.tool == context.tool,
                      self.imageSelectionSettings == context.settings,self.selectionMode == context.mode,
                      self.selectionFeather == context.feather,self.layerEditTarget == context.editTarget else { return }
                do {
                    let mask = try result.get().image
                    let incoming = try SelectionMask.feather(mask:mask,radius:context.feather)
                    let existing = try context.source.selectionMaskPNGData.map(RasterImage.decode)
                    guard let combined = try SelectionMask.combine(existing:existing,incoming:incoming,mode:context.mode) else { return }
                    if let existing, try NumericSelectionRaster.gray(existing) == NumericSelectionRaster.gray(combined) { return }
                    let data = try RasterImage.png(combined)
                    self.edit(kind == .wand ? "魔棒选区" : "自动选区") { document in
                        guard document == context.source else { throw DocumentError.staleRevision }
                        document.selectionMaskPNGData = data
                    }
                } catch { self.errorMessage = error.localizedDescription }
            }
            return true
        } catch { errorMessage = error.localizedDescription;return false }
    }

    func imageSelectionSample(_ source:CanvasDocument,allLayers:Bool) throws -> CGImage {
        try Self.makeImageSelectionSample(source,allLayers:allLayers)
    }

    nonisolated static func makeImageSelectionSample(_ source:CanvasDocument,allLayers:Bool) throws -> CGImage {
        if allLayers { return try DocumentRenderer().render(source) }
        guard let layer = source.activeLayer,!layer.isGroup,layer.adjustment == nil else {
            throw DocumentError.invalid("请选择普通图层，或改为取样可见合成。")
        }
        var sample = source
        var raw = layer;raw.parentID = nil;raw.maskSourceID = nil;raw.maskPNGData = nil
        raw.opacity = 1;raw.blendMode = .normal;raw.isVisible = true;raw.effects = nil
        sample.layers = [raw];sample.activeLayerID = raw.id
        return try DocumentRenderer().render(sample)
    }

    func resizeSelection(amount:Int,documentID:UUID,revision:Int64) {
        report {
            guard document.id == documentID,document.revision == revision else { throw DocumentError.staleRevision }
            guard let selectionPreview else { throw DocumentError.invalid("请先创建选区。") }
            guard amount != 0 else { return }
            let mask = try ImageSelectionRaster.resized(selectionPreview,amount:amount)
            guard try NumericSelectionRaster.gray(mask) != NumericSelectionRaster.gray(selectionPreview) else { return }
            let data = try RasterImage.png(mask)
            edit(amount > 0 ? "扩展选区" : "收缩选区") { $0.selectionMaskPNGData = data }
        }
    }
}
