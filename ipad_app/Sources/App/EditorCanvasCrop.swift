import SwiftUI

struct CanvasCropSession: Identifiable {
    let id = UUID()
    let plan: CanvasCropPlan
    let selectedIDs: Set<UUID>
    var rect: PixelRect
}

extension EditorModel {
    @discardableResult func beginCanvasCrop() -> Bool {
        cancelTransform(); layerEditTarget = .pixels
        do {
            let plan = try CanvasCropPlan(document: document)
            cropSession = CanvasCropSession(plan: plan, selectedIDs: selectedLayerIDs, rect: plan.original)
            cropPreview = preview; cropPreviewError = nil
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    func cropIsCurrent(_ session: CanvasCropSession) -> Bool {
        document == session.plan.source && selectedLayerIDs == session.selectedIDs && layerEditTarget == .pixels
    }
    @discardableResult func previewCanvasCrop(_ rect: PixelRect, sessionID: UUID) -> Bool {
        guard var session = cropSession, session.id == sessionID else { return false }
        guard cropIsCurrent(session) else { cancelCanvasCrop(); return false }
        do {
            cropPreview = try renderer.render(session.plan.preview(rect))
            session.rect = rect; cropSession = session; cropPreviewError = nil
            return true
        } catch { cropPreviewError = error.localizedDescription; return false }
    }
    @discardableResult func commitCanvasCrop(_ rect: PixelRect, sessionID: UUID) -> Bool {
        guard let session = cropSession, session.id == sessionID else { return false }
        guard cropIsCurrent(session) else { cancelCanvasCrop(); errorMessage = "文稿已改变，请重新打开裁切。"; return false }
        do {
            let result = try session.plan.preview(rect)
            if result != session.plan.source { _ = try renderer.render(result) }
            try editor.transaction("裁切画布") { try session.plan.apply(rect, to: &$0) }
            cancelCanvasCrop(); renderer.clearCache(); changed(); viewportReset += 1
            return true
        } catch { cropPreviewError = error.localizedDescription; return false }
    }
    func cancelCanvasCrop() {
        guard cropSession != nil || cropPreview != nil || cropPreviewError != nil else { return }
        cropSession = nil; cropPreview = nil; cropPreviewError = nil
    }

    func addGuide(axis: CanvasGuide.Axis, position: Double) {
        edit("添加辅助线") { $0.guides.append(CanvasGuide(axis: axis, position: position)) }
    }
    func moveGuide(_ id: UUID, position: Double) {
        edit("移动辅助线") { document in
            guard let i = document.guides.firstIndex(where: { $0.id == id }) else { throw DocumentError.invalid("辅助线已不存在") }
            document.guides[i].position = position
        }
    }
    func removeGuide(_ id: UUID) { edit("删除辅助线") { $0.guides.removeAll { $0.id == id } } }
    func clearGuides() { edit("清除辅助线") { $0.guides = [] } }
}
