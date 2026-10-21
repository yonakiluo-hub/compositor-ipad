// Adapted from Compositor Document/LayerMerge.swift.
// Copyright (c) 2026 Wonder Assembly LLC. MIT; see licenses/Compositor-MIT.txt.
// Upstream: 7c2a5a4a3e7f685a8a0ec282ef0b4284f20b5477; also reviewed at 365b5745.
// iPad adaptations preserve full transformed bounds and reject backdrop-dependent
// merges instead of silently changing unselected layers or discarding hidden work.
import Foundation
import CoreGraphics

enum LayerMergeError: LocalizedError, Equatable {
    case nothingSelected, missingLayer, singleLayer, noLayerBelow, noRasterContent
    case differentParents, nonAdjacent, locked, hiddenContent, externalOpacity, backdropBlend, clippingDependency, stalePlan

    var errorDescription: String? {
        switch self {
        case .nothingSelected: "请先选择要合并的图层。"
        case .missingLayer: "选中的图层已不存在，请重新选择。"
        case .singleLayer: "请至少选择两个图层，或选择一个图层组。"
        case .noLayerBelow: "当前图层下方没有同组图层可合并。"
        case .noRasterContent: "这个图层组中没有可合并的像素图层。"
        case .differentParents: "请选择同一组内的图层；也可使用盖印画布副本保留所有源层。"
        case .nonAdjacent: "请选择同一组内连续排列的图层；可先调整层序，或使用盖印画布副本。"
        case .locked: "待合并图层或其中的子图层已锁定，请先解锁。"
        case .hiddenContent: "待合并内容含有隐藏图层，请先显示它们；盖印画布副本会保留隐藏的源层。"
        case .externalOpacity: "上级图层组的不透明度未满，直接合并会改变叠色；请选中整个组，或使用盖印画布副本。"
        case .backdropBlend: "待合并图层使用了依赖背景的混合模式；请改为正常模式，或使用盖印画布副本保留外观。"
        case .clippingDependency: "请将剪贴基底及其全部剪贴图层一起合并，或先解除剪贴关系；也可使用盖印画布副本。"
        case .stalePlan: "合并准备后文稿已有变化，请重新选择并合并。"
        }
    }
}

struct LayerMergePlan {
    let rootIDs: [UUID]
    let removedIDs: Set<UUID>
    let parentID: UUID?
    let anchorID: UUID
    let name: String
    let actionName: String
    let bounds: CGRect
    fileprivate let documentID: UUID
    fileprivate let revision: Int64
    fileprivate let canvasSize: CGSize
    fileprivate let sourceLayers: [RasterLayer]
}

enum LayerMerge {
    /// The roots must be consecutive siblings. Children selected together with their
    /// ancestor are counted once, independent of where their raw records were appended.
    static func plan(document: CanvasDocument, selectedIDs: Set<UUID>) throws -> LayerMergePlan {
        try makePlan(document: document, selectedIDs: selectedIDs, actionName: nil)
    }

    static func mergeDownPlan(document: CanvasDocument, layerID: UUID) throws -> LayerMergePlan {
        guard let layer = document.layers.first(where: { $0.id == layerID }) else { throw LayerMergeError.missingLayer }
        let siblings = document.layers.filter { $0.parentID == layer.parentID }
        guard let position = siblings.firstIndex(where: { $0.id == layerID }), position > 0
        else { throw LayerMergeError.noLayerBelow }
        return try makePlan(document: document, selectedIDs: [siblings[position - 1].id, layerID],
                            actionName: "向下合并", name: siblings[position - 1].name)
    }

    static func groupPlan(document: CanvasDocument, groupID: UUID) throws -> LayerMergePlan {
        guard let group = document.layers.first(where: { $0.id == groupID }), group.isGroup
        else { throw LayerMergeError.missingLayer }
        return try makePlan(document: document, selectedIDs: [groupID], actionName: "合并图层组")
    }

    /// Render only the selected subtree. Ancestors are deliberately excluded: the
    /// planner has checked their opacity is one, and the result keeps their parent.
    /// Selection coverage never enters a layer merge.
    static func render(plan: LayerMergePlan, document: CanvasDocument,
                       renderer: DocumentRenderer) throws -> RasterLayer {
        try check(plan, document: document)
        let subset = document.layers.filter { plan.removedIDs.contains($0.id) }.map { layer in
            var copy = layer
            if let parent = copy.parentID, !plan.removedIDs.contains(parent) { copy.parentID = nil }
            return copy
        }
        let image = try renderer.render(layers: subset, bounds: plan.bounds)
        return RasterLayer(name: plan.name, pngData: try RasterImage.png(image),
                           transform: LayerTransform(origin: plan.bounds.origin, size: plan.bounds.size),
                           parentID: plan.parentID)
    }

    /// Call inside the editor's one transaction after rendering succeeded.
    static func apply(plan: LayerMergePlan, mergedLayer: RasterLayer, to document: inout CanvasDocument) throws {
        try check(plan, document: document)
        guard mergedLayer.parentID == plan.parentID, !mergedLayer.isGroup,
              !document.layers.contains(where: { $0.id == mergedLayer.id }),
              let anchor = document.layers.firstIndex(where: { $0.id == plan.anchorID })
        else { throw LayerMergeError.stalePlan }
        let insertion = document.layers[..<anchor].filter { !plan.removedIDs.contains($0.id) }.count
        var next = document.layers.filter { !plan.removedIDs.contains($0.id) }
        next.insert(mergedLayer, at: insertion)
        try LayerHierarchy.validate(next)
        document.layers = next
        document.activeLayerID = mergedLayer.id
    }

    /// A canvas-sized, selection-independent snapshot. It starts hidden so alpha
    /// is not composited twice over the unchanged sources; the user can show it later.
    static func stampVisible(document: CanvasDocument, renderer: DocumentRenderer,
                             name: String = "画布盖印") throws -> RasterLayer {
        let image = try renderer.render(document)
        return RasterLayer(name: name, pngData: try RasterImage.png(image),
                           transform: LayerTransform(size: document.size), isVisible: false)
    }

    private static func makePlan(document: CanvasDocument, selectedIDs: Set<UUID>,
                                 actionName: String?, name: String? = nil) throws -> LayerMergePlan {
        guard !selectedIDs.isEmpty else { throw LayerMergeError.nothingSelected }
        try LayerHierarchy.validate(document.layers)
        let byID = Dictionary(uniqueKeysWithValues: document.layers.map { ($0.id, $0) })
        guard selectedIDs.allSatisfy({ byID[$0] != nil }) else { throw LayerMergeError.missingLayer }
        let roots = document.layers.filter { layer in
            guard selectedIDs.contains(layer.id) else { return false }
            var cursor = layer.parentID
            while let id = cursor {
                if selectedIDs.contains(id) { return false }
                cursor = byID[id]?.parentID
            }
            return true
        }
        guard let first = roots.first, let top = roots.last else { throw LayerMergeError.nothingSelected }
        guard roots.count > 1 || first.isGroup else { throw LayerMergeError.singleLayer }
        guard roots.allSatisfy({ $0.parentID == first.parentID }) else { throw LayerMergeError.differentParents }
        let rootIDs = Set(roots.map(\.id))
        let siblings = document.layers.filter { $0.parentID == first.parentID }
        let positions = siblings.indices.filter { rootIDs.contains(siblings[$0].id) }
        guard positions.last! - positions.first! + 1 == positions.count else { throw LayerMergeError.nonAdjacent }
        let children = Dictionary(grouping: document.layers, by: \.parentID)
        var removed = rootIDs, pending = Array(rootIDs)
        while let id = pending.popLast() {
            for child in children[id] ?? [] where removed.insert(child.id).inserted { pending.append(child.id) }
        }
        // Baking only one side of a clipping dependency would either reveal the
        // clipped source pixels or change still-live children to use a new alpha.
        guard !document.layers.contains(where: { layer in
            layer.maskSourceID.map { removed.contains(layer.id) != removed.contains($0) } ?? false
        }) else { throw LayerMergeError.clippingDependency }
        let sources = document.layers.filter { removed.contains($0.id) }
        guard sources.contains(where: { !$0.isGroup }) else { throw LayerMergeError.noRasterContent }
        guard !sources.contains(where: { source in
            var cursor: RasterLayer? = source
            while let layer = cursor {
                if layer.isLocked { return true }
                cursor = layer.parentID.flatMap { byID[$0] }
            }
            return false
        }) else { throw LayerMergeError.locked }
        guard sources.allSatisfy(\.isVisible) else { throw LayerMergeError.hiddenContent }
        var parent = first.parentID
        while let id = parent, let ancestor = byID[id] {
            guard ancestor.opacity == 1 else { throw LayerMergeError.externalOpacity }
            parent = ancestor.parentID
        }
        guard sources.filter({ !$0.isGroup }).allSatisfy({ $0.blendMode == .normal })
        else { throw LayerMergeError.backdropBlend }
        let bounds = try bounds(of: sources.filter { !$0.isGroup })
        return LayerMergePlan(rootIDs: roots.map(\.id), removedIDs: removed, parentID: first.parentID,
                              anchorID: top.id, name: name ?? top.name,
                              actionName: actionName ?? (roots.count == 1 ? "合并图层组" : "合并图层"),
                              bounds: bounds, documentID: document.id, revision: document.revision,
                              canvasSize: document.size, sourceLayers: document.layers)
    }

    private static func bounds(of layers: [RasterLayer]) throws -> CGRect {
        var extent = CGRect.null
        for layer in layers {
            guard layer.transform.isValid else { throw DocumentError.invalid("图层变换无效") }
            let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
                           CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1)].map(layer.transform.point)
            for point in corners {
                extent = extent.union(CGRect(origin: point, size: .zero))
            }
        }
        // Right-angle rotations have tiny trigonometric residue; do not grow their
        // integer rectangle by an extra pixel solely because of that residue.
        func snapped(_ value: CGFloat) -> CGFloat {
            abs(value - value.rounded()) < 0.0000001 ? value.rounded() : value
        }
        let left = floor(snapped(extent.minX)), top = floor(snapped(extent.minY))
        let right = ceil(snapped(extent.maxX)), bottom = ceil(snapped(extent.maxY))
        let result = CGRect(x: left, y: top, width: right - left, height: bottom - top)
        guard result.width.isFinite, result.height.isFinite, result.width >= 1, result.height >= 1,
              result.width <= 4096, result.height <= 4096, result.width * result.height <= 16_000_000
        else { throw RasterError.oversized }
        return result
    }

    private static func check(_ plan: LayerMergePlan, document: CanvasDocument) throws {
        guard plan.documentID == document.id, plan.revision == document.revision,
              plan.canvasSize == document.size, plan.sourceLayers == document.layers
        else { throw LayerMergeError.stalePlan }
    }
}
