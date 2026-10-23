import SwiftUI

struct ColorAdjustmentSession: Identifiable {
    let id = UUID()
    let plan: AdjustmentLayerEdit
    let selectedIDs: Set<UUID>
    var value: LayerAdjustment
}

extension EditorModel {
    @discardableResult
    func beginColorAdjustment(_ kind: AdjustmentKind? = nil) -> Bool {
        cancelColorAdjustment(); cancelTransform()
        guard selectedLayerIDs.count <= 1 else { errorMessage = "请先选择一个图层或组，再添加或编辑调整层。"; return false }
        do {
            let plan = try AdjustmentLayerEdit(document: document, kind: kind)
            layerEditTarget = .pixels
            colorAdjustmentSession = ColorAdjustmentSession(plan: plan, selectedIDs: selectedLayerIDs, value: plan.original)
            colorAdjustmentPreview = preview; colorAdjustmentPreviewError = nil
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func colorAdjustmentIsCurrent(_ session: ColorAdjustmentSession) -> Bool {
        document == session.plan.source && selectedLayerIDs == session.selectedIDs && layerEditTarget == .pixels
    }

    @discardableResult
    func updateColorAdjustment(_ value: LayerAdjustment, sessionID: UUID) -> Bool {
        guard var session = colorAdjustmentSession, session.id == sessionID else { return false }
        guard colorAdjustmentIsCurrent(session) else { cancelColorAdjustment(); return false }
        guard value.isValid, value.kind == session.plan.original.kind else { return false }
        session.value = value; colorAdjustmentSession = session
        colorAdjustmentPreviewError = nil; colorAdjustmentPreviewPending = true
        colorAdjustmentPreviewRequest = UUID()
        renderColorAdjustmentPreview()
        return true
    }

    /// One background render at a time; rapid drags coalesce to the most recent value.
    /// A canceled renderer may finish, but cannot publish into a later editor or document.
    private func renderColorAdjustmentPreview() {
        guard colorAdjustmentTask == nil, let session = colorAdjustmentSession, colorAdjustmentIsCurrent(session) else { return }
        let request = colorAdjustmentPreviewRequest
        colorAdjustmentTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try DocumentRenderer().render(session.plan.preview(session.value)) }
            }.value
            guard let self else { return }
            self.colorAdjustmentTask = nil
            guard let current = self.colorAdjustmentSession, self.colorAdjustmentIsCurrent(current) else { return }
            guard current.id == session.id else {
                if self.colorAdjustmentPreviewPending { self.renderColorAdjustmentPreview() }
                return
            }
            if request == self.colorAdjustmentPreviewRequest {
                self.colorAdjustmentPreviewPending = false
                switch result {
                case .success(let image): self.colorAdjustmentPreview = image
                case .failure(let error): self.colorAdjustmentPreviewError = error.localizedDescription
                }
            } else { self.renderColorAdjustmentPreview() }
        }
    }

    @discardableResult
    func commitColorAdjustment(sessionID: UUID) -> Bool {
        guard let session = colorAdjustmentSession, session.id == sessionID else { return false }
        guard colorAdjustmentIsCurrent(session) else { cancelColorAdjustment(); errorMessage = "文稿已改变，请重新打开调整层。"; return false }
        do {
            // Full validation and render before committing: an allocation or unsupported scope fails atomically.
            if session.plan.hasChanges(session.value) { _ = try renderer.render(session.plan.preview(session.value)) }
            try editor.transaction(session.plan.original.kind.title + "调整层") {
                try session.plan.apply(session.value, to: &$0)
            }
            cancelColorAdjustment(); changed()
            return true
        } catch { colorAdjustmentPreviewError = error.localizedDescription; return false }
    }

    func cancelColorAdjustment() {
        guard colorAdjustmentSession != nil || colorAdjustmentPreview != nil || colorAdjustmentPreviewPending
                || colorAdjustmentPreviewError != nil else { return }
        colorAdjustmentSession = nil; colorAdjustmentPreview = nil
        colorAdjustmentPreviewPending = false; colorAdjustmentPreviewError = nil
        // Keep the worker until it actually exits to bound concurrent allocations.
        colorAdjustmentPreviewRequest = UUID()
    }
}
