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
            guard !layer.isGroup else { throw DocumentError.invalid("不能在图层组上绘画") }
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
                        maskPNGData: layer.maskPNGData, maskEnabled: layer.maskEnabled)
        }
        try transaction("复制图层") { document in
            // Sibling order follows each root record, not the last descendant's array
            // position: children added later may sit beyond unrelated higher siblings.
            let index = document.layers.firstIndex { $0.id == id }! + 1
            document.layers.insert(contentsOf: copies, at: index)
            document.activeLayerID = duplicateID
        }
        return duplicateID
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
        guard let index = document.layers.firstIndex(where: { $0.id == id }) else { throw DocumentError.missingLayer }
        guard !document.isEffectivelyLocked(id), parentID.map({ !document.isEffectivelyLocked($0) }) ?? true
        else { throw DocumentError.lockedLayer }
        try transaction("移动图层") { $0.layers[index].parentID = parentID }
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
            doc.layers.reduce(doc.selectionMaskPNGData?.count ?? 0) { $0 + ($1.pngData?.count ?? 0) + ($1.maskPNGData?.count ?? 0) }
        }
        var retained = past.reduce(0) { $0 + bytes($1.before) + bytes($1.after) }
        while !past.isEmpty && (past.count > historyLimit || retained > historyByteLimit) {
            let removed = past.removeFirst(); retained -= bytes(removed.before) + bytes(removed.after)
        }
    }
}
