import SwiftUI

struct LayerContentSession: Identifiable, Sendable {
    let id = UUID()
    let plan: EditableLayerEdit
    let selectedIDs: Set<UUID>
    var value: LayerContentDraft
    var missingFonts: [String]
}

extension EditorModel {
    @discardableResult
    func beginLayerContent(_ kind: LayerContentKind? = nil) -> Bool {
        cancelTransform()
        guard selectedLayerIDs.count <= 1 else { errorMessage = "请先选择一个图层或组。"; return false }
        do {
            let plan = try EditableLayerEdit(document: document, new: kind)
            layerEditTarget = .pixels
            let fonts = plan.original.text.map(LayerContentRaster.missingFonts) ?? []
            let session = LayerContentSession(plan: plan, selectedIDs: selectedLayerIDs, value: plan.original, missingFonts: fonts)
            layerContentSession = session; layerContentPreview = preview; layerContentPreviewError = nil
            layerContentPrepared = plan.isNew ? nil : document
            layerContentPreviewPending = plan.isNew
            if plan.isNew { layerContentPreviewRequest = UUID(); renderLayerContentPreview() }
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    func layerContentIsCurrent(_ session: LayerContentSession) -> Bool {
        document == session.plan.source && selectedLayerIDs == session.selectedIDs && layerEditTarget == .pixels
    }

    func updateLayerContent(_ value: LayerContentDraft, sessionID: UUID) {
        guard var session = layerContentSession, session.id == sessionID else { return }
        guard layerContentIsCurrent(session) else { cancelLayerContent(); return }
        guard value.isValid else { layerContentPreviewError = "文字或形状参数超出支持范围。"; return }
        session.value = value; session.missingFonts = value.text.map(LayerContentRaster.missingFonts) ?? []
        layerContentSession = session; layerContentPreviewError = nil
        layerContentPreviewPending = true; layerContentPrepared = nil; layerContentPreviewRequest = UUID()
        renderLayerContentPreview()
    }

    private func renderLayerContentPreview() {
        guard layerContentTask == nil, let session = layerContentSession, layerContentIsCurrent(session) else { return }
        let request = layerContentPreviewRequest
        layerContentTask = Task { [weak self] in
            let result = await DocumentPreviewQueue.shared.perform {
                let prepared = try session.plan.preview(session.value)
                return PreparedLayerContent(document: prepared, image: try DocumentRenderer().render(prepared))
            }
            guard let self else { return }
            self.layerContentTask = nil
            guard let current = self.layerContentSession, self.layerContentIsCurrent(current) else { return }
            guard current.id == session.id, request == self.layerContentPreviewRequest else {
                if self.layerContentPreviewPending { self.renderLayerContentPreview() }; return
            }
            self.layerContentPreviewPending = false
            switch result {
            case .success(let prepared): self.layerContentPrepared = prepared.document; self.layerContentPreview = prepared.image
            case .failure(let error): self.layerContentPreviewError = error.localizedDescription
            }
        }
    }

    var canCommitLayerContent: Bool {
        guard let session = layerContentSession, layerContentIsCurrent(session), layerContentPrepared != nil,
              !layerContentPreviewPending, layerContentPreviewError == nil else { return false }
        return !session.plan.hasChanges(session.value) || session.missingFonts.isEmpty
    }

    @discardableResult
    func commitLayerContent(sessionID: UUID) -> Bool {
        guard let session = layerContentSession, session.id == sessionID else { return false }
        guard layerContentIsCurrent(session) else { cancelLayerContent(); errorMessage = "文稿已改变，请重新打开编辑面板。"; return false }
        guard canCommitLayerContent, let prepared = layerContentPrepared else { return false }
        do {
            try prepared.validate()
            try editor.transaction(session.plan.kind.title + "图层") { document in
                guard document == session.plan.source else { throw DocumentError.staleRevision }
                document = prepared
            }
            cancelLayerContent(); changed(); return true
        } catch { layerContentPreviewError = error.localizedDescription; return false }
    }

    func cancelLayerContent() {
        guard layerContentSession != nil || layerContentPreview != nil || layerContentPreviewPending || layerContentPreviewError != nil else { return }
        layerContentSession = nil; layerContentPreview = nil; layerContentPreviewPending = false; layerContentPreviewError = nil
        layerContentPrepared = nil; layerContentPreviewRequest = UUID()
        layerContentTask?.cancel()
        // The old background worker owns its allocation until it actually exits.
    }

    func rasterizeLayerContent() {
        guard let layer = activeLayer, layer.hasEditableContent, selectedLayerIDs.count <= 1 else { return }
        cancelTransform()
        report {
            var replacement = try LayerContentRaster.redrawShape(layer)
            replacement.rasterizeContent()
            try editor.updateLayer(layer.id, name: "栅格化" + (layer.text != nil ? "文字" : "形状")) { $0 = replacement }
            changed()
        }
    }
}
