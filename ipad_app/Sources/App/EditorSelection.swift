import Foundation
import CoreGraphics

extension EditorModel {
    /// A completed gesture contributes one coverage mask and one undo entry.
    /// Its options and source revision were frozen when the gesture began.
    func commitSelectionShape(_ shape: SelectionShape, mode: SelectionCombineMode, feather: Double,
                              documentID: UUID, revision: Int64) {
        report {
            guard document.id == documentID else { throw DocumentError.wrongDocument }
            guard document.revision == revision else { throw DocumentError.staleRevision }
            if selectionPreview == nil && (mode == .subtract || mode == .intersect) {
                throw DocumentError.invalid("请先创建选区，再使用减去或相交")
            }
            let hard = try SelectionMask.rasterize(shape, width: document.width, height: document.height)
            let incoming = try SelectionMask.feather(mask: hard, radius: feather)
            guard let combined = try SelectionMask.combine(existing: selectionPreview, incoming: incoming, mode: mode) else { return }
            let data = try RasterImage.png(combined)
            edit("\(mode.title)选区") { $0.selectionMaskPNGData = data }
        }
    }

    func featherSelection(radius: Double, documentID: UUID, revision: Int64) {
        report {
            guard document.id == documentID else { throw DocumentError.wrongDocument }
            guard document.revision == revision else { throw DocumentError.staleRevision }
            guard let selectionPreview else { throw DocumentError.invalid("请先创建选区") }
            let softened = try SelectionMask.feather(mask: selectionPreview, radius: radius)
            guard radius > 0 else { return }
            let data = try RasterImage.png(softened)
            edit("羽化选区") { $0.selectionMaskPNGData = data }
        }
    }
}

extension SelectionCombineMode {
    var title: String {
        switch self { case .replace: "新建"; case .add: "添加"; case .subtract: "减去"; case .intersect: "相交" }
    }
}
