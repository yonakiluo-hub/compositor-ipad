import Foundation

struct LayerOrganizationContext: Identifiable {
    let id = UUID()
    let documentID: UUID
    let revision: Int64
    let selectedIDs: Set<UUID>
}

enum LayerOrganizationAction {
    case move(parentID: UUID?, position: LayerInsertionPosition)
    case group, moveOut
}

extension EditorModel {
    func beginLayerOrganization() -> LayerOrganizationContext {
        cancelTransform()
        return LayerOrganizationContext(documentID: document.id, revision: document.revision, selectedIDs: selectedLayerIDs)
    }

    func layerOrganizationPlan(_ context: LayerOrganizationContext, action: LayerOrganizationAction) throws -> LayerOrganizationPlan {
        guard document.id == context.documentID, document.revision == context.revision,
              selectedLayerIDs == context.selectedIDs else { throw LayerOrganizationError.stalePlan }
        switch action {
        case .move(let parent, let position):
            return try LayerOrganization.movePlan(document: document, selectedIDs: context.selectedIDs, into: parent, position: position)
        case .group: return try LayerOrganization.groupPlan(document: document, selectedIDs: context.selectedIDs)
        case .moveOut: return try LayerOrganization.moveOutPlan(document: document, selectedIDs: context.selectedIDs)
        }
    }

    @discardableResult
    func organizeLayers(_ context: LayerOrganizationContext, action: LayerOrganizationAction) -> Bool {
        do {
            let plan = try layerOrganizationPlan(context, action: action)
            let previous = document.revision
            cancelTransform()
            try editor.organizeLayers(plan)
            if plan.groupID != nil { isLayerMultiSelecting = false }
            layerEditTarget = .pixels
            changed()
            status = previous == document.revision ? "图层已在此位置" : "已整理图层 · 可一步撤销"
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }

    var clippingIssue: String? {
        guard let layer = activeLayer, !layer.isGroup else { return "请选择一个普通图层。" }
        guard selectedLayerIDs.count <= 1 else { return "请先选择一个图层。" }
        guard !document.isEffectivelyLocked(layer.id) else { return "图层已锁定，请先解锁。" }
        if layer.maskSourceID != nil { return nil }
        do { _ = try editor.clippingBase(for: layer.id); return nil }
        catch { return error.localizedDescription }
    }

    var clippingSourceName: String? {
        guard let source = activeLayer?.maskSourceID else { return nil }
        return document.layers.first { $0.id == source }?.name
    }

    func setLayerClipping(_ enabled: Bool) {
        guard let layer = activeLayer else { return }
        guard selectedLayerIDs.count <= 1 else { errorMessage = "请先选择一个图层。"; return }
        cancelTransform()
        report {
            try editor.setClipping(layerID: layer.id, enabled: enabled)
            changed()
            status = enabled ? "已创建剪贴蒙版 · 原像素保留" : "已释放剪贴蒙版 · 可撤销"
        }
    }

    /// Multi-selection is panel navigation, not a persistent edit or undo step.
    func synchronizeLayerSelection() {
        let ids = Set(document.layers.map(\.id))
        if layerSelectionDocumentID != document.id {
            layerSelectionDocumentID = document.id
            isLayerMultiSelecting = false
            selectedLayerIDs = Set(document.activeLayerID.map { [$0] } ?? [])
            layerEditTarget = .pixels
            return
        }
        selectedLayerIDs.formIntersection(ids)
        if !isLayerMultiSelecting || document.activeLayerID.map({ !selectedLayerIDs.contains($0) }) == true {
            selectedLayerIDs = Set(document.activeLayerID.map { [$0] } ?? [])
        }
    }

    func setLayerMultiSelecting(_ enabled: Bool) {
        cancelTransform()
        layerEditTarget = .pixels
        isLayerMultiSelecting = enabled
        selectedLayerIDs = Set(document.activeLayerID.map { [$0] } ?? [])
    }

    func toggleLayerSelection(_ id: UUID) {
        guard document.layers.contains(where: { $0.id == id }) else { return }
        cancelTransform()
        layerEditTarget = .pixels
        if selectedLayerIDs.contains(id) {
            selectedLayerIDs.remove(id)
            if document.activeLayerID == id {
                let next = document.hierarchy.last { selectedLayerIDs.contains($0.layer.id) }?.layer.id
                report { try editor.selectLayer(next) }
            }
        } else {
            selectedLayerIDs.insert(id)
            report { try editor.selectLayer(id) }
        }
        objectWillChange.send()
        scheduleSave()
    }

    func selectLayerTarget(_ layer: RasterLayer, target: LayerEditTarget) {
        isLayerMultiSelecting = false
        select(layer)
        setLayerEditTarget(target)
    }

    var selectedMergePlan: Result<LayerMergePlan, Error> {
        Result {
            if selectedLayerIDs.count == 1, let id = selectedLayerIDs.first,
               document.layers.first(where: { $0.id == id })?.isGroup == true {
                return try LayerMerge.groupPlan(document: document, groupID: id)
            }
            return try LayerMerge.plan(document: document, selectedIDs: selectedLayerIDs)
        }
    }

    var mergeDownPlan: Result<LayerMergePlan, Error>? {
        guard let id = document.activeLayerID else { return nil }
        return Result { try LayerMerge.mergeDownPlan(document: document, layerID: id) }
    }

    func mergeSelectedLayers() {
        switch selectedMergePlan {
        case .success(let plan): commitLayerMerge(plan)
        case .failure(let error): errorMessage = error.localizedDescription
        }
    }

    func mergeLayerDown() {
        guard let plan = mergeDownPlan else { return }
        switch plan {
        case .success(let plan): commitLayerMerge(plan)
        case .failure(let error): errorMessage = error.localizedDescription
        }
    }

    private func commitLayerMerge(_ plan: LayerMergePlan) {
        cancelTransform()
        report {
            let merged = try LayerMerge.render(plan: plan, document: document, renderer: renderer)
            try editor.transaction(plan.actionName) {
                try LayerMerge.apply(plan: plan, mergedLayer: merged, to: &$0)
            }
            isLayerMultiSelecting = false
            layerEditTarget = .pixels
            changed()
            status = "已合并图层 · 可撤销"
        }
    }

    func stampVisibleLayers() {
        cancelTransform()
        report {
            let layer = try LayerMerge.stampVisible(document: document, renderer: renderer)
            try editor.addLayer(layer, name: "盖印画布副本")
            isLayerMultiSelecting = false
            layerEditTarget = .pixels
            changed()
            status = "已创建隐藏的盖印副本 · 源图层保留"
        }
    }
}
