import Foundation

extension EditorModel {
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
