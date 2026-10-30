import Foundation
import CoreGraphics

enum LayerContentKind: String, CaseIterable, Sendable {
    case text, shape
    var title: String { self == .text ? "文字" : "形状" }
}

struct LayerContentDraft: Equatable, Sendable {
    var text: LayerTextStyle?
    var shape: LayerShapeStyle?
    var size: CGSize
    var isValid: Bool {
        guard size.width.isFinite, size.height.isFinite, (1...4096).contains(size.width),
              (1...4096).contains(size.height), size.width * size.height <= 16_000_000 else { return false }
        return (text != nil && text!.isValid && shape == nil) || (shape != nil && shape!.isValid && text == nil)
    }
}

/// The whole document is immutable while a content sheet is open. Rendering and
/// allocation happen before applying this plan through one editor transaction.
struct EditableLayerEdit: Sendable {
    let source: CanvasDocument
    let layer: RasterLayer
    let kind: LayerContentKind
    let isNew: Bool
    let original: LayerContentDraft
    private let insertion: Int

    init(document: CanvasDocument, new kind: LayerContentKind? = nil) throws {
        try document.validate()
        guard let active = document.activeLayer else { throw DocumentError.missingLayer }
        guard !document.isEffectivelyLocked(active.id) else { throw DocumentError.lockedLayer }
        source = document
        if let kind {
            isNew = true; self.kind = kind
            let size = CGSize(width: max(16, min(kind == .text ? 480 : 260, document.width)),
                              height: max(16, min(180, document.height)))
            let parent = active.isGroup ? active.id : active.parentID
            layer = RasterLayer(name: kind.title, transform: LayerTransform(origin: CGPoint(x: (document.size.width - size.width) / 2,
                               y: (document.size.height - size.height) / 2), size: size), parentID: parent)
            original = LayerContentDraft(text: kind == .text ? LayerTextStyle(boxSize: size) : nil,
                                        shape: kind == .shape ? LayerShapeStyle() : nil, size: size)
            let siblings = document.layers.filter { $0.parentID == parent }, base = active.maskSourceID ?? active.id
            let anchor = siblings.last { $0.id == active.id || $0.id == base || $0.maskSourceID == base }
            insertion = active.isGroup ? document.layers.count : anchor.flatMap { a in document.layers.firstIndex { $0.id == a.id } }.map { $0 + 1 } ?? document.layers.count
        } else {
            guard active.hasEditableContent else { throw DocumentError.invalid("请选择可编辑文字或形状图层") }
            isNew = false; self.kind = active.text != nil ? .text : .shape; layer = active
            original = LayerContentDraft(text: active.text, shape: active.shape, size: active.transform.size)
            insertion = document.layers.firstIndex { $0.id == active.id }!
        }
    }

    func hasChanges(_ value: LayerContentDraft) -> Bool {
        if isNew, let text = value.text { return !text.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if isNew { return true }
        return value != original
    }

    func preview(_ value: LayerContentDraft) throws -> CanvasDocument {
        guard value.isValid, (kind == .text) == (value.text != nil) else { throw DocumentError.invalid("文字或形状参数无效") }
        guard hasChanges(value) else { return source }
        var next = layer
        if let text = value.text {
            let image = try LayerContentRaster.textImage(text)
            let old = try layer.pngData.map { try PNGAsset.inspect($0) }
            let scaleX = old.map { layer.transform.size.width / CGFloat($0.width) } ?? 1
            let scaleY = old.map { layer.transform.size.height / CGFloat($0.height) } ?? 1
            next.pngData = try RasterImage.png(image)
            next.transform.size = CGSize(width: CGFloat(image.width) * scaleX, height: CGFloat(image.height) * scaleY)
            next.text = text; next.shape = nil
            if isNew { next.name = String(text.content.prefix(40)).replacingOccurrences(of: "\n", with: " ") }
        } else if let shape = value.shape {
            next.pngData = try RasterImage.png(LayerContentRaster.shapeImage(shape, size: value.size))
            next.transform.size = value.size; next.shape = shape; next.text = nil
            if isNew { next.name = shape.kind.title }
        }
        var document = source
        if isNew { document.layers.insert(next, at: insertion) } else { document.layers[insertion] = next }
        document.activeLayerID = next.id
        try document.validate()
        return document
    }

    func apply(_ value: LayerContentDraft, to document: inout CanvasDocument) throws {
        guard document == source else { throw DocumentError.staleRevision }
        guard value.isValid else { throw DocumentError.invalid("文字或形状参数无效") }
        guard hasChanges(value) else { return }
        document = try preview(value)
    }
}
