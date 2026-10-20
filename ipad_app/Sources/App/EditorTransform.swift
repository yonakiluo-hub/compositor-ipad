import Foundation

/// A value-only preview. Source pixels and the linked mask remain in the document
/// until one transform-only transaction is committed by the user.
struct LayerTransformSession: Identifiable, Equatable {
    let id = UUID()
    let documentID: UUID
    let revision: Int64
    let layerID: UUID
    let original: LayerTransform
    var current: LayerTransform
    var hasChanges: Bool { current != original }

    fileprivate func matches(_ document: CanvasDocument) -> Bool {
        guard document.id == documentID, document.revision == revision,
              document.activeLayerID == layerID, let layer = document.activeLayer else { return false }
        return !layer.isGroup && !document.isEffectivelyLocked(layerID) && layer.transform == original
    }
}

extension EditorModel {
    /// Render this copy only while displaying transform handles. Saving, exporting
    /// and AI submission continue to use the committed document.
    var transformPreviewDocument: CanvasDocument {
        var result = document
        guard tool == .transform, let session = transformSession, session.matches(result), session.current.isValid,
              let index = result.layers.firstIndex(where: { $0.id == session.layerID }) else { return result }
        result.layers[index].transform = session.current
        return result
    }

    @discardableResult
    func beginTransform() -> Bool {
        if tool == .transform, let session = transformSession, session.matches(document) { return true }
        cancelTransform()
        guard let layer = activeLayer, !layer.isGroup else {
            errorMessage = "请选择一个普通图层，再使用自由变换。"
            return false
        }
        guard !document.isEffectivelyLocked(layer.id) else {
            errorMessage = DocumentError.lockedLayer.localizedDescription
            return false
        }
        guard layer.pngData != nil else {
            errorMessage = "这个图层还没有内容，请先绘画或导入图片。"
            return false
        }
        let session = LayerTransformSession(documentID: document.id, revision: document.revision,
            layerID: layer.id, original: layer.transform, current: layer.transform)
        tool = .transform
        transformSession = session
        return true
    }

    /// Each drag captures its session ID. A delayed drag cannot alter a new session
    /// even when the document, layer and revision happen to be unchanged.
    @discardableResult
    func previewTransform(_ transform: LayerTransform, sessionID: UUID) -> Bool {
        guard var session = transformSession, session.id == sessionID else { return false }
        guard tool == .transform, session.matches(document) else { cancelTransform(); return false }
        guard transform.isValid else { return false }
        guard transform != session.current else { return true }
        session.current = transform
        transformSession = session
        return true
    }

    @discardableResult
    func commitTransform(sessionID: UUID? = nil) -> Bool {
        guard let session = transformSession, sessionID == nil || session.id == sessionID else { return false }
        guard tool == .transform, session.matches(document), session.current.isValid else {
            cancelTransform()
            errorMessage = "文稿或图层已改变，请重新开始自由变换。"
            return false
        }
        cancelTransform()
        guard session.hasChanges else { return true }
        do {
            try editor.transaction("自由变换") { document in
                guard session.matches(document), let index = document.layers.firstIndex(where: { $0.id == session.layerID }) else {
                    throw DocumentError.invalid("文稿或图层已改变，请重新开始自由变换")
                }
                document.layers[index].transform = session.current
            }
            changed()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func cancelTransform() {
        guard transformSession != nil || tool == .transform else { return }
        transformSession = nil
        if tool == .transform { tool = .move }
    }
}
