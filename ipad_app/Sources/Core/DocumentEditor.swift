import Foundation

/// Value snapshots share Data storage. A gesture should commit its finished pixels in one transaction.
/// Use from one owning actor (the UI uses MainActor); this class deliberately performs no network work.
public final class DocumentEditor {
    public private(set) var document: CanvasDocument
    private struct Entry {
        let name: String
        let before: CanvasDocument
        let after: CanvasDocument
    }
    private var past: [Entry] = []
    private var future: [Entry] = []
    private var savedRevision: Int64
    private let historyLimit: Int
    private let historyByteLimit: Int

    public init(document: CanvasDocument, historyLimit: Int = 50, historyByteLimit: Int = 128 * 1024 * 1024) throws {
        try document.validate()
        self.document = document; self.savedRevision = document.revision
        self.historyLimit = max(0, historyLimit); self.historyByteLimit = max(0, historyByteLimit)
    }

    public var canUndo: Bool { !past.isEmpty }
    public var canRedo: Bool { !future.isEmpty }
    public var undoName: String { past.last?.name ?? "" }
    public var redoName: String { future.last?.name ?? "" }
    public var undoCount: Int { past.count }
    public var isModified: Bool { document.revision != savedRevision }
    public func markSaved(_ revision: Int64? = nil) { savedRevision = revision ?? document.revision }

    public func selectLayer(_ id: UUID?) throws {
        if let id, !document.layers.contains(where: { $0.id == id }) { throw DocumentError.missingLayer }
        document.activeLayerID = id
    }

    /// Failure and no-op edits leave the document, revision, and redo history intact.
    public func transaction(_ name: String, _ edit: (inout CanvasDocument) throws -> Void) throws {
        let before = document
        var after = before
        try edit(&after)
        // A shape's radius stays in document pixels when its geometry is resized.
        // Preserve already prepared caches; do not touch unchanged source PNGs.
        let oldLayers = Dictionary(uniqueKeysWithValues: before.layers.map { ($0.id, $0) })
        for i in after.layers.indices {
            let layer = after.layers[i]
            if layer.shape != nil, let old = oldLayers[layer.id], layer.pngData == old.pngData,
               layer.shape != old.shape || layer.transform.size != old.transform.size {
                after.layers[i] = try LayerContentRaster.redrawShape(layer)
            }
        }
        guard after.id == before.id else { throw DocumentError.wrongDocument }
        after.revision = before.revision
        // Selecting a layer is navigation, not an edit.
        var comparable = after
        comparable.activeLayerID = before.activeLayerID
        guard comparable != before else {
            try after.validate()
            document.activeLayerID = after.activeLayerID
            return
        }
        guard before.revision < Int64.max else { throw DocumentError.revisionExhausted }
        after.revision = before.revision + 1
        // A receipt is never lost by a caller replacing document contents.
        after.appliedAIResults.formUnion(before.appliedAIResults)
        try after.validate()
        past.append(Entry(name: name, before: before, after: after))
        future.removeAll()
        document = after
        trimHistory()
    }

    public func undo() throws {
        guard let entry = past.last else { return }
        guard document.revision < Int64.max else { throw DocumentError.revisionExhausted }
        var restored = entry.before
        restored.revision = document.revision + 1
        restored.appliedAIResults.formUnion(document.appliedAIResults)
        past.removeLast(); future.append(entry); document = restored
    }

    public func redo() throws {
        guard let entry = future.last else { return }
        guard document.revision < Int64.max else { throw DocumentError.revisionExhausted }
        var restored = entry.after
        restored.revision = document.revision + 1
        restored.appliedAIResults.formUnion(document.appliedAIResults)
        future.removeLast(); past.append(entry); document = restored
    }

    @discardableResult
    public func addLayer(_ layer: RasterLayer, name: String = "新建图层") throws -> UUID {
        if let parent = layer.parentID, document.isEffectivelyLocked(parent) { throw DocumentError.lockedLayer }
        try transaction(name) { document in
            document.layers.append(layer); document.activeLayerID = layer.id
        }
        return layer.id
    }

    public func updateLayer(_ id: UUID, name: String = "编辑图层", _ edit: (inout RasterLayer) throws -> Void) throws {
        guard let index = document.layers.firstIndex(where: { $0.id == id }) else { throw DocumentError.missingLayer }
        guard !document.isEffectivelyLocked(id) else { throw DocumentError.lockedLayer }
        try transaction(name) { document in try edit(&document.layers[index]) }
    }

    public func setPixels(layerID: UUID, pngData: Data?, name: String = "绘画") throws {
        try updateLayer(layerID, name: name) { layer in
            guard !layer.isGroup, layer.adjustment == nil, !layer.hasEditableContent else { throw DocumentError.invalid("请先将文字或形状栅格化，再编辑像素") }
            layer.pngData = pngData
        }
    }

    public func setVisibility(layerID: UUID, isVisible: Bool) throws {
        // Visibility and unlocking remain possible for a locked layer.
        guard let index = document.layers.firstIndex(where: { $0.id == layerID }) else { throw DocumentError.missingLayer }
        try transaction("图层可见性") { $0.layers[index].isVisible = isVisible }
    }

    public func setLocked(layerID: UUID, isLocked: Bool) throws {
        guard let index = document.layers.firstIndex(where: { $0.id == layerID }) else { throw DocumentError.missingLayer }
        try transaction("锁定图层") { $0.layers[index].isLocked = isLocked }
    }

    public func setOpacity(layerID: UUID, opacity: Double) throws {
        try updateLayer(layerID, name: "图层不透明度") { $0.opacity = opacity }
    }

    public func setSelection(_ maskPNGData: Data?) throws {
        try transaction("选区") { $0.selectionMaskPNGData = maskPNGData }
    }

    public func deleteLayer(_ id: UUID) throws {
        guard document.layers.contains(where: { $0.id == id }) else { throw DocumentError.missingLayer }
        let ids = descendants(including: id)
        guard !ids.contains(where: { document.isEffectivelyLocked($0) }) else { throw DocumentError.lockedLayer }
        guard !document.layers.contains(where: { !ids.contains($0.id) && $0.maskSourceID.map(ids.contains) == true }) else {
            throw DocumentError.unsupported("仍有图层剪贴到待删除的基底层，请先解除剪贴关系，或删除包含它们的整个组")
        }
        try transaction("删除图层") { document in
            document.layers.removeAll { ids.contains($0.id) }
            if let active = document.activeLayerID, ids.contains(active) { document.activeLayerID = document.layers.last?.id }
        }
    }

    @discardableResult
    public func duplicateLayer(_ id: UUID) throws -> UUID {
        guard let source = document.layers.first(where: { $0.id == id }) else { throw DocumentError.missingLayer }
        if let parent = source.parentID, document.isEffectivelyLocked(parent) { throw DocumentError.lockedLayer }
        let ids = descendants(including: id)
        let mapping = Dictionary(uniqueKeysWithValues: ids.map { ($0, UUID()) })
        let duplicateID = mapping[id]!
        let copies = document.layers.filter { ids.contains($0.id) }.map { layer in
            RasterLayer(id: mapping[layer.id]!, name: layer.id == id ? layer.name + " 副本" : layer.name,
                        pngData: layer.pngData, transform: layer.transform, isVisible: layer.isVisible,
                        isLocked: layer.isLocked, opacity: layer.opacity, blendMode: layer.blendMode,
                        parentID: layer.parentID.map { mapping[$0] ?? $0 }, isGroup: layer.isGroup,
                        maskPNGData: layer.maskPNGData, maskEnabled: layer.maskEnabled,
                        maskSourceID: layer.maskSourceID.map { mapping[$0] ?? $0 }, adjustment: layer.adjustment,
                        text: layer.text, shape: layer.shape, effects: layer.effects)
        }
        try transaction("复制图层") { document in
            // Sibling order follows each root record, not the last descendant's array
            // position: children added later may sit beyond unrelated higher siblings.
            // Copying a base must not split its existing stack. A clipped copy
            // instead stays immediately above its source and shares the same base.
            let siblings = document.layers.filter { $0.parentID == source.parentID }
            let position = siblings.firstIndex { $0.id == id }!
            let clippedAbove = siblings.dropFirst(position + 1).prefix { $0.maskSourceID == id }
            let anchor = source.maskSourceID == nil ? (clippedAbove.last?.id ?? id) : id
            let index = document.layers.firstIndex { $0.id == anchor }! + 1
            document.layers.insert(contentsOf: copies, at: index)
            document.activeLayerID = duplicateID
        }
        return duplicateID
    }

    /// The next lower sibling determines the clipping base, as in Compositor's
    /// LiveLayerMask. A clipped sibling shares its original base, not its own alpha.
    public func clippingBase(for layerID: UUID) throws -> UUID {
        guard let layer = document.layers.first(where: { $0.id == layerID }) else { throw DocumentError.missingLayer }
        guard !document.isEffectivelyLocked(layerID) else { throw DocumentError.lockedLayer }
        guard !layer.isGroup else { throw DocumentError.unsupported("图层组暂不支持作为剪贴图层") }
        if let source = layer.maskSourceID { return source }
        guard !document.layers.contains(where: { $0.maskSourceID == layerID }) else {
            throw DocumentError.unsupported("当前图层已有剪贴子层，请先解除它们的剪贴关系")
        }
        let siblings = document.layers.filter { $0.parentID == layer.parentID }
        guard let index = siblings.firstIndex(where: { $0.id == layerID }), index > 0,
              !siblings[index - 1].isGroup,
              siblings[index - 1].adjustment == nil || siblings[index - 1].maskSourceID != nil else {
            throw DocumentError.unsupported("请在同组普通图层的上方创建剪贴蒙版")
        }
        return siblings[index - 1].maskSourceID ?? siblings[index - 1].id
    }

    public func setClipping(layerID: UUID, enabled: Bool) throws {
        guard let layer = document.layers.first(where: { $0.id == layerID }) else { throw DocumentError.missingLayer }
        guard !document.isEffectivelyLocked(layerID) else { throw DocumentError.lockedLayer }
        if enabled {
            guard layer.maskSourceID == nil else { return }
            let source = try clippingBase(for: layerID)
            try updateLayer(layerID, name: "创建剪贴蒙版") { $0.maskSourceID = source }
        } else {
            guard let source = layer.maskSourceID else { return }
            let siblings = document.layers.filter { $0.parentID == layer.parentID }
            let index = siblings.firstIndex { $0.id == layerID }!
            // Releasing inside a stack also releases the children above it. This
            // explicit action is undoable and never creates a detached dependency.
            let releases = Set(siblings.dropFirst(index).prefix { $0.maskSourceID == source }.map(\.id))
            guard !releases.contains(where: { document.isEffectivelyLocked($0) }) else { throw DocumentError.lockedLayer }
            try transaction("解除剪贴蒙版") { document in
                for index in document.layers.indices where releases.contains(document.layers[index].id) {
                    document.layers[index].maskSourceID = nil
                }
            }
        }
    }

    /// Offset among siblings in bottom-to-top order; +1 raises the layer one position.
    public func reorderLayer(_ id: UUID, offset: Int) throws {
        guard let layer = document.layers.first(where: { $0.id == id }) else { throw DocumentError.missingLayer }
        guard !document.isEffectivelyLocked(id) else { throw DocumentError.lockedLayer }
        let siblings = document.layers.filter { $0.parentID == layer.parentID }
        guard let position = siblings.firstIndex(where: { $0.id == id }), offset != 0 else { return }
        let target = max(0, min(siblings.count - 1, position + min(max(offset, -siblings.count), siblings.count)))
        guard target != position else { return }
        let otherID = siblings[target].id
        try transaction("图层排序") { document in
            let originalIndex = document.layers.firstIndex { $0.id == id }!
            let moved = document.layers.remove(at: originalIndex)
            let targetIndex = document.layers.firstIndex { $0.id == otherID }!
            document.layers.insert(moved, at: target > position ? targetIndex + 1 : targetIndex)
        }
    }

    public func moveLayer(_ id: UUID, into parentID: UUID?) throws {
        try moveLayers([id], into: parentID)
    }

    public func moveLayers(_ ids: Set<UUID>, into parentID: UUID?, position: LayerInsertionPosition = .top) throws {
        try organizeLayers(LayerOrganization.movePlan(document: document, selectedIDs: ids, into: parentID, position: position))
    }

    @discardableResult
    public func groupLayers(_ ids: Set<UUID>, name: String = "图层组") throws -> UUID {
        let plan = try LayerOrganization.groupPlan(document: document, selectedIDs: ids, name: name)
        try organizeLayers(plan)
        return plan.groupID!
    }

    public func moveLayersOutOfGroup(_ ids: Set<UUID>) throws {
        try organizeLayers(LayerOrganization.moveOutPlan(document: document, selectedIDs: ids))
    }

    func organizeLayers(_ plan: LayerOrganizationPlan) throws {
        try transaction(plan.actionName) { try LayerOrganization.apply(plan, to: &$0) }
    }

    /// A changed revision requires an explicit user choice to insert at the original
    /// coordinates. The candidate still belongs to the original document and canvas;
    /// consent never changes its anchor or permits replacing existing layers.
    @discardableResult
    public func insertAIResult(pngData: Data, key: AIResultKey, anchor: GenerationAnchor,
                               name: String = "AI 候选", allowChangedRevision: Bool = false) throws -> UUID {
        guard anchor.documentID == document.id else { throw DocumentError.wrongDocument }
        guard !document.appliedAIResults.contains(key) else { throw DocumentError.duplicateResult }
        guard anchor.canvasWidth == document.width, anchor.canvasHeight == document.height else { throw DocumentError.changedCanvas }
        guard anchor.baseRevision >= 0, anchor.baseRevision <= document.revision,
              anchor.baseRevision == document.revision || allowChangedRevision
        else { throw DocumentError.staleRevision }
        guard anchor.cropRect.isInside(width: document.width, height: document.height) else { throw DocumentError.invalid("候选裁切区域越界") }
        let size = try PNGAsset.inspect(pngData, requireRGBA: true)
        guard size.width == anchor.cropRect.width, size.height == anchor.cropRect.height
        else { throw DocumentError.invalid("候选像素尺寸与裁切区域不符") }
        let layer = RasterLayer(name: name, pngData: pngData,
                                transform: LayerTransform(origin: anchor.cropRect.cgRect.origin, size: anchor.cropRect.cgRect.size))
        try transaction("加入 AI 候选") { document in
            document.layers.append(layer); document.activeLayerID = layer.id; document.appliedAIResults.insert(key)
        }
        return layer.id
    }

    private func descendants(including id: UUID) -> Set<UUID> {
        var result: Set<UUID> = [id], pending = [id]
        let children = Dictionary(grouping: document.layers, by: \.parentID)
        while let parent = pending.popLast() {
            for child in children[parent] ?? [] where result.insert(child.id).inserted { pending.append(child.id) }
        }
        return result
    }

    private func trimHistory() {
        // Conservative accounting deliberately overcounts shared immutable Data rather than
        // retaining an unbounded history of full-resolution brush images on an iPad.
        func bytes(_ doc: CanvasDocument) -> Int {
            doc.layers.reduce(doc.selectionMaskPNGData?.count ?? 0) {
                $0 + ($1.pngData?.count ?? 0) + ($1.maskPNGData?.count ?? 0) + ($1.text?.estimatedBytes ?? 0)
                    + ($1.shape == nil ? 0 : 128) + ($1.effects == nil ? 0 : 768)
            }
        }
        var retained = past.reduce(0) { $0 + bytes($1.before) + bytes($1.after) }
        while !past.isEmpty && (past.count > historyLimit || retained > historyByteLimit) {
            let removed = past.removeFirst(); retained -= bytes(removed.before) + bytes(removed.after)
        }
    }
}
