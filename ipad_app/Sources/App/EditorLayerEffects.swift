import SwiftUI

struct LayerEffectsSession: Identifiable, Sendable {
    let id = UUID()
    let plan: LayerEffectsEdit
    let selectedIDs: Set<UUID>
    var value: LayerEffects
}

extension EditorModel {
    @discardableResult
    func beginLayerEffects() -> Bool {
        cancelTransform()
        guard selectedLayerIDs.count <= 1 else { errorMessage = "请先选择一个图层，再编辑图层效果。"; return false }
        do {
            let plan = try LayerEffectsEdit(document: document)
            layerEditTarget = .pixels
            layerEffectsSession = LayerEffectsSession(plan: plan, selectedIDs: selectedLayerIDs, value: plan.original)
            layerEffectsPrepared = document; layerEffectsPreview = preview; layerEffectsPreviewPending = false; layerEffectsPreviewError = nil
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    func layerEffectsIsCurrent(_ session: LayerEffectsSession) -> Bool {
        document == session.plan.source && selectedLayerIDs == session.selectedIDs && layerEditTarget == .pixels
    }
    func updateLayerEffects(_ value: LayerEffects, sessionID: UUID) {
        guard var session = layerEffectsSession, session.id == sessionID else { return }
        guard layerEffectsIsCurrent(session) else { cancelLayerEffects(); return }
        guard value.isValid else { layerEffectsPreviewError = "效果参数超出支持范围。"; return }
        session.value = value; layerEffectsSession = session; layerEffectsPreviewError = nil
        layerEffectsPrepared = nil; layerEffectsPreviewPending = true; layerEffectsPreviewRequest = UUID()
        renderLayerEffectsPreview()
    }
    private func renderLayerEffectsPreview() {
        guard layerEffectsTask == nil, let session = layerEffectsSession, layerEffectsIsCurrent(session) else { return }
        let request = layerEffectsPreviewRequest
        layerEffectsTask = Task { [weak self] in
            let result = await DocumentPreviewQueue.shared.perform {
                let doc = try session.plan.preview(session.value)
                return PreparedLayerContent(document: doc, image: try DocumentRenderer().render(doc))
            }
            guard let self else { return }; self.layerEffectsTask = nil
            guard let current = self.layerEffectsSession, self.layerEffectsIsCurrent(current) else { return }
            guard current.id == session.id, request == self.layerEffectsPreviewRequest else {
                if self.layerEffectsPreviewPending { self.renderLayerEffectsPreview() }; return
            }
            self.layerEffectsPreviewPending = false
            switch result {
            case .success(let prepared): self.layerEffectsPrepared = prepared.document; self.layerEffectsPreview = prepared.image
            case .failure(let error): self.layerEffectsPreviewError = error.localizedDescription
            }
        }
    }
    var canCommitLayerEffects: Bool {
        guard let session = layerEffectsSession else { return false }
        return layerEffectsIsCurrent(session) && layerEffectsPrepared != nil && !layerEffectsPreviewPending && layerEffectsPreviewError == nil
    }
    @discardableResult
    func commitLayerEffects(sessionID: UUID) -> Bool {
        guard let session = layerEffectsSession, session.id == sessionID else { return false }
        guard layerEffectsIsCurrent(session) else { cancelLayerEffects(); errorMessage = "文稿已改变，请重新打开图层效果。"; return false }
        guard canCommitLayerEffects, let prepared = layerEffectsPrepared else { return false }
        do {
            try editor.transaction("图层效果") { doc in
                guard doc == session.plan.source else { throw DocumentError.staleRevision }; doc = prepared
            }
            cancelLayerEffects(); changed(); return true
        } catch { layerEffectsPreviewError = error.localizedDescription; return false }
    }
    func cancelLayerEffects() {
        guard layerEffectsSession != nil || layerEffectsPreview != nil || layerEffectsPreviewPending || layerEffectsPreviewError != nil else { return }
        layerEffectsSession = nil; layerEffectsPreview = nil; layerEffectsPreviewPending = false; layerEffectsPreviewError = nil
        layerEffectsPrepared = nil; layerEffectsPreviewRequest = UUID(); layerEffectsTask?.cancel()
    }
}
