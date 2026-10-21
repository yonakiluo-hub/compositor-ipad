// Adapted from Compositor Document/LayerGroups.swift, commit
// 365b5745eda537f984f3d5bed1e53c361dbc9c91.
// Copyright (c) 2026 Wonder Assembly LLC. MIT; see licenses/Compositor-MIT.txt.
// iPad: batch planning, strict clipping/lock checks and explicit sibling anchors.
import Foundation

public enum LayerInsertionPosition: Equatable, Sendable {
    case top, bottom, above(UUID), below(UUID)
}

enum LayerOrganizationError: LocalizedError, Equatable {
    case nothingSelected, missingLayer, invalidParent, cycle, locked, clippingDependency
    case invalidAnchor, differentParents, nonAdjacent, noParent, stalePlan

    var errorDescription: String? {
        switch self {
        case .nothingSelected: "请先选择要整理的图层。"
        case .missingLayer: "选中的图层已不存在，请重新选择。"
        case .invalidParent: "目标必须是现有图层组或画稿顶层。"
        case .cycle: "不能把图层组移入自己或其后代。"
        case .locked: "所选图层、子图层、上级组或目标组已锁定，请先解锁。"
        case .clippingDependency: "请完整选择剪贴基底和全部剪贴层，并将它们放在其他剪贴堆栈之外。"
        case .invalidAnchor: "插入位置已失效，请选择目标组内未移动的同级项目。"
        case .differentParents: "成组或移出组需要选择同一父组内的项目；可先用移动到位置整理。"
        case .nonAdjacent: "成组需要选择同一父组内连续的项目，以保留其他图层的层序。"
        case .noParent: "所选项目已在画稿顶层。"
        case .stalePlan: "文稿或图层选择已改变，请重新打开图层整理。"
        }
    }
}

struct LayerOrganizationPlan {
    let rootIDs: [UUID]
    let layers: [RasterLayer]
    let groupID: UUID?
    let actionName: String
    fileprivate let documentID: UUID
    fileprivate let revision: Int64
    fileprivate let sourceLayers: [RasterLayer]
}

enum LayerOrganization {
    /// Visual drawing order, rather than raw storage order: children can have
    /// been appended after unrelated siblings. An ancestor carries its subtree.
    static func roots(document: CanvasDocument, selectedIDs: Set<UUID>) throws -> [RasterLayer] {
        guard !selectedIDs.isEmpty else { throw LayerOrganizationError.nothingSelected }
        try LayerHierarchy.validate(document.layers)
        let byID = Dictionary(uniqueKeysWithValues: document.layers.map { ($0.id, $0) })
        guard selectedIDs.allSatisfy({ byID[$0] != nil }) else { throw LayerOrganizationError.missingLayer }
        return document.hierarchy.map(\.layer).filter { layer in
            guard selectedIDs.contains(layer.id) else { return false }
            var parent = layer.parentID
            while let id = parent {
                if selectedIDs.contains(id) { return false }
                parent = byID[id]?.parentID
            }
            return true
        }
    }

    static func movePlan(document: CanvasDocument, selectedIDs: Set<UUID>, into parentID: UUID?,
                         position: LayerInsertionPosition = .top) throws -> LayerOrganizationPlan {
        let roots = try roots(document: document, selectedIDs: selectedIDs)
        let moved = try checkedSubtree(document: document, roots: roots)
        if let parentID {
            guard let parent = document.layers.first(where: { $0.id == parentID }), parent.isGroup
            else { throw LayerOrganizationError.invalidParent }
            guard !moved.contains(parentID) else { throw LayerOrganizationError.cycle }
            guard !document.isEffectivelyLocked(parentID) else { throw LayerOrganizationError.locked }
        }
        let rootIDs = Set(roots.map(\.id))
        var next = document.layers.filter { !rootIDs.contains($0.id) }
        let insertion: Int
        switch position {
        case .top: insertion = next.lastIndex(where: { $0.parentID == parentID }).map { $0 + 1 } ?? next.count
        case .bottom: insertion = next.firstIndex(where: { $0.parentID == parentID }) ?? next.count
        case .above(let id), .below(let id):
            guard !moved.contains(id), let index = next.firstIndex(where: { $0.id == id && $0.parentID == parentID })
            else { throw LayerOrganizationError.invalidAnchor }
            insertion = index + (position == .above(id) ? 1 : 0)
        }
        next.insert(contentsOf: roots.map { layer in
            var copy = layer; copy.parentID = parentID; return copy
        }, at: insertion)
        try validatePlacement(next)
        // Repositioning at the same logical place must not normalize raw storage
        // or create a spurious edit that destroys redo.
        if roots.allSatisfy({ $0.parentID == parentID }),
           LayerHierarchy.entries(next).map(\.layer.id) == document.hierarchy.map(\.layer.id) {
            next = document.layers
        }
        return plan(document: document, roots: roots, layers: next, action: "移动图层")
    }

    static func groupPlan(document: CanvasDocument, selectedIDs: Set<UUID>, name: String = "图层组") throws -> LayerOrganizationPlan {
        let roots = try roots(document: document, selectedIDs: selectedIDs)
        guard document.layers.count < 10_000 else { throw DocumentError.tooLarge }
        _ = try checkedSubtree(document: document, roots: roots)
        let first = roots[0]
        guard roots.allSatisfy({ $0.parentID == first.parentID }) else { throw LayerOrganizationError.differentParents }
        let ids = Set(roots.map(\.id)), siblings = document.layers.filter { $0.parentID == first.parentID }
        let positions = siblings.indices.filter { ids.contains(siblings[$0].id) }
        guard positions.last! - positions.first! + 1 == positions.count else { throw LayerOrganizationError.nonAdjacent }
        let group = RasterLayer(name: name, transform: LayerTransform(size: document.size), parentID: first.parentID, isGroup: true)
        // Replacing the lowest selected root keeps the wrapper at the same slot
        // among siblings, even when descendant records are interleaved in storage.
        var next: [RasterLayer] = []
        for var layer in document.layers {
            if layer.id == first.id { next.append(group) }
            if ids.contains(layer.id) { layer.parentID = group.id }
            next.append(layer)
        }
        try validatePlacement(next)
        return plan(document: document, roots: roots, layers: next, groupID: group.id, action: "所选图层成组")
    }

    static func moveOutPlan(document: CanvasDocument, selectedIDs: Set<UUID>) throws -> LayerOrganizationPlan {
        let roots = try roots(document: document, selectedIDs: selectedIDs)
        guard roots.allSatisfy({ $0.parentID == roots[0].parentID }) else { throw LayerOrganizationError.differentParents }
        guard let parentID = roots[0].parentID, let parent = document.layers.first(where: { $0.id == parentID })
        else { throw LayerOrganizationError.noParent }
        return try movePlan(document: document, selectedIDs: selectedIDs, into: parent.parentID, position: .above(parentID))
    }

    static func apply(_ plan: LayerOrganizationPlan, to document: inout CanvasDocument) throws {
        guard document.id == plan.documentID, document.revision == plan.revision, document.layers == plan.sourceLayers
        else { throw LayerOrganizationError.stalePlan }
        document.layers = plan.layers
        if let groupID = plan.groupID { document.activeLayerID = groupID }
    }

    private static func checkedSubtree(document: CanvasDocument, roots: [RasterLayer]) throws -> Set<UUID> {
        let children = Dictionary(grouping: document.layers, by: \.parentID)
        var moved = Set(roots.map(\.id)), pending = Array(moved)
        while let id = pending.popLast() {
            for child in children[id] ?? [] where moved.insert(child.id).inserted { pending.append(child.id) }
        }
        var locked: Set<UUID> = []
        for entry in document.hierarchy {
            let layer = entry.layer
            if layer.isLocked || layer.parentID.map(locked.contains) == true { locked.insert(layer.id) }
        }
        guard moved.isDisjoint(with: locked) else { throw LayerOrganizationError.locked }
        guard !document.layers.contains(where: { layer in
            layer.maskSourceID.map { moved.contains(layer.id) != moved.contains($0) } ?? false
        }) else { throw LayerOrganizationError.clippingDependency }
        return moved
    }

    private static func validatePlacement(_ layers: [RasterLayer]) throws {
        do { try LayerHierarchy.validate(layers) }
        catch DocumentError.unsupported { throw LayerOrganizationError.clippingDependency }
    }

    private static func plan(document: CanvasDocument, roots: [RasterLayer], layers: [RasterLayer],
                             groupID: UUID? = nil, action: String) -> LayerOrganizationPlan {
        LayerOrganizationPlan(rootIDs: roots.map(\.id), layers: layers, groupID: groupID, actionName: action,
                              documentID: document.id, revision: document.revision, sourceLayers: document.layers)
    }
}
