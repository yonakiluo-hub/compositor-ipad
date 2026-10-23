// Adapted from Compositor TransformGroup and LayerTransform.following/placing,
// 365b5745eda537f984f3d5bed1e53c361dbc9c91, MIT © 2026 Wonder Assembly LLC.
// iPad rejects shear instead of dropping it; freezes subtree/selection and commits once.
import Foundation
import CoreGraphics

enum LayerBatchTransformError: LocalizedError {
    case selection, empty, bounds, shear, stale
    var errorDescription: String? {
        switch self {
        case .selection: "多层或整组变换目前作用于整层，请先取消选区；单个普通图层仍可变换选中内容。"
        case .empty: "所选图层或组内还没有像素内容，请先绘画或导入图片。"
        case .bounds: "共同变换超出当前几何范围；请缩小变换幅度或分开操作。"
        case .shear: "该非等比缩放会产生斜切，请锁定比例；当前工程不会自动丢弃斜切。"
        case .stale: "文稿或图层选择已改变，请重新开始共同变换。"
        }
    }
}

struct LayerBatchTransformPlan {
    let selectedIDs: Set<UUID>
    let rootIDs: [UUID]
    let carriedIDs: Set<UUID>
    let original: LayerTransform
    let allowsNonUniformScale: Bool
    private let geometryIDs: Set<UUID>
    private let source: CanvasDocument

    init(document: CanvasDocument, selectedIDs: Set<UUID>) throws {
        try document.validate()
        guard document.selectionMaskPNGData == nil else { throw LayerBatchTransformError.selection }
        let roots = try LayerOrganization.roots(document: document, selectedIDs: selectedIDs)
        self.selectedIDs = selectedIDs; rootIDs = roots.map(\.id)
        var carried = Set(rootIDs), locked = Set<UUID>()
        for entry in document.hierarchy {
            let layer = entry.layer
            if layer.parentID.map(carried.contains) == true { carried.insert(layer.id) }
            if layer.isLocked || layer.parentID.map(locked.contains) == true { locked.insert(layer.id) }
        }
        guard carried.isDisjoint(with: locked) else { throw DocumentError.lockedLayer }
        guard document.layers.contains(where: { carried.contains($0.id) && !$0.isGroup && $0.pngData != nil })
        else { throw LayerBatchTransformError.empty }
        let placed = document.layers.filter { carried.contains($0.id) && (!$0.isGroup || $0.maskPNGData != nil) }
        geometryIDs = Set(placed.map(\.id)); carriedIDs = carried
        let corners = placed.flatMap { layer in
            [CGPoint.zero, CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)].map(layer.transform.point)
        }
        let left = corners.map(\.x).min()!, top = corners.map(\.y).min()!
        original = LayerTransform(origin: CGPoint(x: left, y: top),
            size: CGSize(width: max(1, corners.map(\.x).max()! - left), height: max(1, corners.map(\.y).max()! - top)), sampling: .nearest)
        guard original.isValid else { throw LayerBatchTransformError.bounds }
        allowsNonUniformScale = placed.allSatisfy { abs(sin(2 * $0.transform.radians)) <= 1e-10 }
        source = document
    }

    func matches(_ document: CanvasDocument) -> Bool { document == source }

    func layers(following next: LayerTransform) throws -> [RasterLayer] {
        guard next.isValid else { throw LayerBatchTransformError.bounds }
        if next == original { return source.layers }
        let sx = next.size.width / original.size.width * (next.flipX ? -1 : 1)
        let sy = next.size.height / original.size.height * (next.flipY ? -1 : 1)
        let cosine = cos(next.radians), sine = sin(next.radians)
        func vector(_ p: CGPoint) -> CGPoint {
            CGPoint(x: p.x * sx * cosine - p.y * sy * sine, y: p.x * sx * sine + p.y * sy * cosine)
        }
        let translationOnly = next.size == original.size && next.rotation == original.rotation
            && next.flipX == original.flipX && next.flipY == original.flipY
        var result = source.layers
        for i in result.indices where geometryIDs.contains(result[i].id) {
            let old = result[i].transform
            var t = old
            if translationOnly {
                t.origin.x += next.origin.x - original.origin.x
                t.origin.y += next.origin.y - original.origin.y
            } else {
                let u = vector(CGPoint(x: cos(old.radians) * old.size.width, y: sin(old.radians) * old.size.width))
                let v = vector(CGPoint(x: -sin(old.radians) * old.size.height, y: cos(old.radians) * old.size.height))
                let width = hypot(u.x, u.y), height = hypot(v.x, v.y)
                guard width.isFinite, height.isFinite, width > 0, height > 0,
                      abs((u.x * v.x + u.y * v.y) / (width * height)) <= 1e-10
                else { throw LayerBatchTransformError.shear }
                let offset = vector(CGPoint(x: old.center.x - original.center.x, y: old.center.y - original.center.y))
                t.size = CGSize(width: width, height: height)
                t.origin = CGPoint(x: next.center.x + offset.x - width / 2, y: next.center.y + offset.y - height / 2)
                if next.rotation == 0, next.flipX == next.flipY { t.rotation = old.rotation }
                else {
                    let sign: CGFloat = next.flipX ? -1 : 1
                    let angle = atan2(u.y * sign, u.x * sign) * 180 / .pi
                    t.rotation = angle
                }
                t.flipX = old.flipX != next.flipX; t.flipY = old.flipY != next.flipY
            }
            guard t.isValid else { throw LayerBatchTransformError.bounds }
            result[i].transform = t
        }
        // Resources/hierarchy never change. Validate temporary group-mask cost
        // before exposing a preview or attempting the atomic history transaction.
        try GroupMaskRules.validate(result, bounds: CGRect(origin: .zero, size: source.size))
        return result
    }

    func apply(_ transform: LayerTransform, to document: inout CanvasDocument) throws {
        guard matches(document) else { throw LayerBatchTransformError.stale }
        document.layers = try layers(following: transform)
    }
}
