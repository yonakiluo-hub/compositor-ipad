import Foundation

/// Freeze the whole composition: changes below a live adjustment invalidate an old editor too.
struct AdjustmentLayerEdit {
    let source: CanvasDocument
    let layer: RasterLayer
    let isNew: Bool
    let original: LayerAdjustment
    private let insertion: Int

    init(document: CanvasDocument, kind: AdjustmentKind? = nil) throws {
        try document.validate()
        guard let active = document.activeLayer else { throw DocumentError.missingLayer }
        guard !document.isEffectivelyLocked(active.id) else { throw DocumentError.lockedLayer }
        source = document
        if let kind {
            isNew = true; original = LayerAdjustment(kind: kind)
            let parent = active.isGroup ? active.id : active.parentID
            layer = RasterLayer(name: kind.title + "调整", transform: LayerTransform(size: document.size, sampling: .nearest),
                                parentID: parent, maskPNGData: document.selectionMaskPNGData, adjustment: original)
            // Insert above the complete clipping stack, never between its base and children.
            let siblings = document.layers.filter { $0.parentID == parent }
            let base = active.maskSourceID ?? active.id
            let anchor = siblings.last(where: { $0.id == active.id || $0.id == base || $0.maskSourceID == base })
            insertion = active.isGroup ? document.layers.count : anchor.flatMap { a in document.layers.firstIndex { $0.id == a.id } }.map { $0 + 1 } ?? document.layers.count
        } else {
            guard let value = active.adjustment else { throw DocumentError.invalid("请选择一个曲线或色阶调整层") }
            isNew = false; original = value; layer = active
            insertion = document.layers.firstIndex { $0.id == active.id }!
        }
    }

    func hasChanges(_ value: LayerAdjustment) -> Bool {
        isNew ? !value.isIdentity : !value.hasSameEffect(as: original)
    }

    func preview(_ value: LayerAdjustment) throws -> CanvasDocument {
        guard value.isValid, value.kind == original.kind else { throw DocumentError.invalid("调整层参数无效") }
        var document = source, next = layer
        next.adjustment = value
        if isNew { document.layers.insert(next, at: insertion) }
        else { document.layers[insertion] = next }
        document.activeLayerID = next.id
        try document.validate()
        return document
    }

    func apply(_ value: LayerAdjustment, to document: inout CanvasDocument) throws {
        guard document == source else { throw DocumentError.staleRevision }
        guard value.isValid, value.kind == original.kind else { throw DocumentError.invalid("调整层参数无效") }
        guard hasChanges(value) else { return }
        document = try preview(value)
    }
}
