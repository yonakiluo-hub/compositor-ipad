import Foundation
import CoreGraphics

enum LayerTransformScope { case layer, selection, layers }

/// The handle box may describe selected pixels rather than the source layer.
/// Frozen source state and cached raster output keep previews out of history and
/// let the final commit encode exactly the buffers that were last displayed.
struct LayerTransformSession: Identifiable, Equatable {
    let id = UUID()
    let documentID: UUID
    let revision: Int64
    let layerID: UUID
    let scope: LayerTransformScope
    let sourceLayer: RasterLayer
    let sourceSelectionPNG: Data?
    let sourceSelectedIDs: Set<UUID>
    let original: LayerTransform
    var current: LayerTransform
    fileprivate let selectionSource: SelectionTransformSource?
    fileprivate var selectionResult: SelectionTransformResult?
    fileprivate let batchPlan: LayerBatchTransformPlan?
    fileprivate var batchLayers: [RasterLayer]?
    var hasChanges: Bool { current != original }

    static func == (lhs: Self, rhs: Self) -> Bool {
        // A session ID identifies one immutable source snapshot. The raster cache
        // is published together with current and is never changed independently.
        lhs.id == rhs.id && lhs.current == rhs.current
    }

    fileprivate func matches(_ document: CanvasDocument, selection: Set<UUID>) -> Bool {
        guard selection == sourceSelectedIDs else { return false }
        if scope == .layers { return batchPlan?.matches(document) == true }
        guard document.id == documentID, document.revision == revision,
              document.activeLayerID == layerID, let layer = document.activeLayer else { return false }
        return !layer.isGroup && !document.isEffectivelyLocked(layerID) && layer == sourceLayer
            && document.selectionMaskPNGData == sourceSelectionPNG
    }
}

extension EditorModel {
    /// Render this copy only while displaying transform handles. Saving, exporting
    /// and AI submission continue to use the committed document.
    var transformPreviewDocument: CanvasDocument {
        var result = document
        guard tool == .transform, let session = transformSession, session.matches(result, selection: selectedLayerIDs), session.current.isValid,
              let index = result.layers.firstIndex(where: { $0.id == session.layerID }) else { return result }
        if session.scope == .layers {
            if let layers = session.batchLayers { result.layers = layers }
        } else if session.scope == .selection {
            // The renderer must pair this geometry with transformPreviewReplacement.
            // No PNG is encoded as the pointer moves.
            if session.hasChanges, let replacement = session.selectionResult {
                result.layers[index].transform = replacement.transform
            }
        } else { result.layers[index].transform = session.current }
        return result
    }

    var transformPreviewReplacement: SelectionTransformResult? {
        guard tool == .transform, let session = transformSession, session.scope == .selection,
              session.matches(document, selection: selectedLayerIDs), session.current.isValid, session.hasChanges else { return nil }
        return session.selectionResult
    }

    var transformFixesLayerGeometry: Bool {
        transformPreviewReplacement?.rasterized == true
    }

    var transformRequiresAspectLock: Bool { transformSession?.batchPlan?.allowsNonUniformScale == false }

    func flipCommonTransform(horizontal: Bool) {
        guard let session = transformSession, session.scope == .layers else { return }
        var next = session.current
        if horizontal { next.flipX.toggle() } else { next.flipY.toggle() }
        _ = previewTransform(next, sessionID: session.id)
    }

    var displayedSelectionPreview: CGImage? {
        if let session=quadWarpSession,quadWarpIsCurrent(session) {return session.result?.selection ?? selectionPreview}
        return transformPreviewReplacement?.selection ?? selectionPreview
    }

    @discardableResult
    func beginTransform() -> Bool {
        layerEditTarget = .pixels
        if tool == .transform, let session = transformSession, session.matches(document, selection: selectedLayerIDs) { return true }
        cancelTransform()
        guard let layer = activeLayer else {
            errorMessage = "请选择一个普通图层，再使用自由变换。"
            return false
        }
        guard !layer.hasEditableContent || document.selectionMaskPNGData == nil else {
            errorMessage = "选中像素变换需要先栅格化文字或形状；取消选区可变换整个可编辑图层。"; return false
        }
        guard layer.effects?.isEmpty != false || document.selectionMaskPNGData == nil else {
            errorMessage = "选中像素变换前请移除图层效果或使用盖印副本；取消选区可变换整个图层。"; return false
        }
        if selectedLayerIDs.count > 1 || layer.isGroup {
            do {
                let plan = try LayerBatchTransformPlan(document: document, selectedIDs: selectedLayerIDs)
                let session = LayerTransformSession(documentID: document.id, revision: document.revision,
                    layerID: layer.id, scope: .layers, sourceLayer: layer, sourceSelectionPNG: document.selectionMaskPNGData,
                    sourceSelectedIDs: selectedLayerIDs, original: plan.original, current: plan.original,
                    selectionSource: nil, selectionResult: nil, batchPlan: plan, batchLayers: nil)
                if !plan.allowsNonUniformScale { transformAspectLocked = true }
                tool = .transform; transformSession = session
                return true
            } catch { errorMessage = error.localizedDescription; return false }
        }
        guard !document.isEffectivelyLocked(layer.id) else {
            errorMessage = DocumentError.lockedLayer.localizedDescription
            return false
        }
        guard layer.pngData != nil else {
            errorMessage = "这个图层还没有内容，请先绘画或导入图片。"
            return false
        }
        do {
            // An explicit empty selection is not unrestricted editing. Preparation
            // rejects empty coverage or no selected source content without falling
            // back to an entire-layer transform.
            let selected = document.selectionMaskPNGData != nil
            let source = try selected ? SelectionTransformSource(document: document, layer: layer, renderer: renderer) : nil
            let original = source?.original ?? layer.transform
            let session = LayerTransformSession(documentID: document.id, revision: document.revision,
                layerID: layer.id, scope: selected ? .selection : .layer, sourceLayer: layer,
                sourceSelectionPNG: document.selectionMaskPNGData, sourceSelectedIDs: selectedLayerIDs,
                original: original, current: original, selectionSource: source, selectionResult: nil,
                batchPlan: nil, batchLayers: nil)
            tool = .transform
            transformSession = session
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Each drag captures its session ID. A delayed drag cannot alter a new session
    /// even when the document, layer and revision happen to be unchanged.
    @discardableResult
    func previewTransform(_ transform: LayerTransform, sessionID: UUID) -> Bool {
        guard var session = transformSession, session.id == sessionID else { return false }
        guard tool == .transform, session.matches(document, selection: selectedLayerIDs) else { cancelTransform(); return false }
        guard transform.isValid else { return false }
        guard transform != session.current else { return true }
        do {
            if session.scope == .layers {
                guard let plan = session.batchPlan else { return false }
                session.batchLayers = try plan.layers(following: transform)
            } else if session.scope == .selection {
                if transform == session.original { session.selectionResult = nil }
                else {
                    guard let source = session.selectionSource else { return false }
                    session.selectionResult = try source.preview(transform)
                }
            }
            session.current = transform
            transformSession = session
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func commitTransform(sessionID: UUID? = nil) -> Bool {
        guard let session = transformSession, sessionID == nil || session.id == sessionID else { return false }
        guard tool == .transform, session.matches(document, selection: selectedLayerIDs), session.current.isValid else {
            cancelTransform()
            errorMessage = "文稿或图层已改变，请重新开始自由变换。"
            return false
        }
        guard session.hasChanges else { cancelTransform(); return true }
        do {
            if session.scope == .layers {
                guard let plan = session.batchPlan else { throw LayerBatchTransformError.stale }
                try editor.transaction("共同变换图层") { document in
                    try plan.apply(session.current, to: &document)
                }
                cancelTransform(); changed()
                return true
            }
            let imagePNG: Data?, maskPNG: Data?, selectionPNG: Data?
            let placement: LayerTransform
            if session.scope == .selection {
                guard let result = session.selectionResult,
                      (result.mask != nil) == (session.sourceLayer.maskPNGData != nil) else {
                    throw DocumentError.invalid("选区变换预览不完整，请重新开始")
                }
                imagePNG = try RasterImage.png(result.image)
                maskPNG = try result.mask.map(RasterImage.png)
                selectionPNG = try RasterImage.png(result.selection)
                placement = result.transform
            } else {
                imagePNG = session.sourceLayer.pngData
                maskPNG = session.sourceLayer.maskPNGData
                selectionPNG = session.sourceSelectionPNG
                placement = session.current
            }
            try editor.transaction(session.scope == .selection ? "变换选区内容" : "自由变换") { document in
                guard session.matches(document, selection: selectedLayerIDs), let index = document.layers.firstIndex(where: { $0.id == session.layerID }) else {
                    throw DocumentError.invalid("文稿或图层已改变，请重新开始自由变换")
                }
                document.layers[index].pngData = imagePNG
                document.layers[index].maskPNGData = maskPNG
                document.layers[index].transform = placement
                document.selectionMaskPNGData = selectionPNG
            }
            cancelTransform()
            changed()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func cancelTransform() {
        cancelLayerEffects()
        cancelLayerContent()
        cancelColorAdjustment()
        cancelImageSelection()
        cancelQuadWarp()
        guard transformSession != nil || tool == .transform else { return }
        transformSession = nil
        if tool == .transform { tool = .move }
    }
}
