import Foundation
import CoreGraphics
import ImageIO

public enum DocumentError: LocalizedError, Equatable {
    case invalid(String), unsupported(String), missingLayer, lockedLayer, tooLarge
    case wrongDocument, staleRevision, changedCanvas, duplicateResult, revisionExhausted
    public var errorDescription: String? {
        switch self {
        case .invalid(let reason): "工程无效：\(reason)"
        case .unsupported(let reason): "暂不支持此工程内容：\(reason)。原文件未修改。"
        case .missingLayer: "找不到图层。"
        case .lockedLayer: "图层已锁定。"
        case .tooLarge: "工程超出当前安全大小限制。"
        case .wrongDocument: "候选属于另一份文稿。"
        case .staleRevision: "文稿已改变。候选仍然保留，请基于当前文稿重新生成。"
        case .changedCanvas: "画布尺寸已改变，无法按原坐标插入候选。"
        case .duplicateResult: "此候选已加入过文稿；如刚撤销，可使用重做恢复。"
        case .revisionExhausted: "文稿版本已达到上限，请另存为新文稿。"
        }
    }
}

public struct AIResultKey: Hashable, Codable, Sendable {
    public let jobID: String
    public let resultID: String
    public init(jobID: String, resultID: String) { self.jobID = jobID; self.resultID = resultID }
}

public struct GenerationAnchor: Equatable, Sendable {
    public let documentID: UUID
    public let baseRevision: Int64
    public let canvasWidth: Int
    public let canvasHeight: Int
    public let cropRect: PixelRect
    public init(documentID: UUID, baseRevision: Int64, canvasWidth: Int, canvasHeight: Int, cropRect: PixelRect) {
        self.documentID = documentID; self.baseRevision = baseRevision
        self.canvasWidth = canvasWidth; self.canvasHeight = canvasHeight; self.cropRect = cropRect
    }
}

public struct RasterLayer: Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    /// Immutable encoded source pixels; nil represents a transparent blank layer.
    public var pngData: Data?
    public var transform: LayerTransform
    public var isVisible: Bool
    public var isLocked: Bool
    public var opacity: Double
    public var blendMode: LayerBlendMode
    public var parentID: UUID?
    public var isGroup: Bool
    /// 8-bit grayscale coverage, normalized to the layer rectangle; white reveals.
    public var maskPNGData: Data?
    public var maskEnabled: Bool

    public init(id: UUID = UUID(), name: String = "图层", pngData: Data? = nil, transform: LayerTransform,
                isVisible: Bool = true, isLocked: Bool = false, opacity: Double = 1,
                blendMode: LayerBlendMode = .normal, parentID: UUID? = nil, isGroup: Bool = false,
                maskPNGData: Data? = nil, maskEnabled: Bool = true) {
        self.id = id; self.name = name; self.pngData = pngData; self.transform = transform
        self.isVisible = isVisible; self.isLocked = isLocked; self.opacity = opacity; self.blendMode = blendMode
        self.parentID = parentID; self.isGroup = isGroup; self.maskPNGData = maskPNGData; self.maskEnabled = maskEnabled
    }
}

public struct CanvasDocument: Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var width: Int
    public var height: Int
    /// Increases on edits, undo and redo; never rewinds with history.
    public var revision: Int64
    public var resolution: Double
    public var layers: [RasterLayer]
    public var activeLayerID: UUID?
    public var selectionMaskPNGData: Data?
    /// Persistent receipt ledger, kept across undo and redo to prevent a repeated download applying twice.
    public var appliedAIResults: Set<AIResultKey>

    public init(id: UUID = UUID(), name: String = "未命名", width: Int, height: Int,
                revision: Int64 = 0, resolution: Double = 72, layers: [RasterLayer] = [],
                activeLayerID: UUID? = nil, selectionMaskPNGData: Data? = nil,
                appliedAIResults: Set<AIResultKey> = []) {
        self.id = id; self.name = name; self.width = width; self.height = height; self.revision = revision
        self.resolution = resolution; self.layers = layers; self.activeLayerID = activeLayerID
        self.selectionMaskPNGData = selectionMaskPNGData; self.appliedAIResults = appliedAIResults
    }

    public var size: CGSize { CGSize(width: width, height: height) }
    public var activeLayer: RasterLayer? { layers.first { $0.id == activeLayerID } }
    public var hierarchy: [LayerHierarchyEntry] { LayerHierarchy.entries(layers) }
    public var renderLayers: [LayerHierarchyEntry] { hierarchy.filter { $0.isVisible && !$0.layer.isGroup } }
    public func isEffectivelyLocked(_ id: UUID) -> Bool {
        let byID = Dictionary(layers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var cursor: UUID? = id, seen: Set<UUID> = []
        while let current = cursor, let layer = byID[current], seen.insert(current).inserted {
            if layer.isLocked { return true }; cursor = layer.parentID
        }
        return false
    }

    public func validate() throws {
        guard width > 0, height > 0, width <= 30_000, height <= 30_000,
              width * height <= 100_000_000, layers.count <= 10_000 else { throw DocumentError.tooLarge }
        guard revision >= 0, resolution.isFinite, (1...9600).contains(resolution),
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 16_384
        else { throw DocumentError.invalid("文稿名称、版本或分辨率无效") }
        try LayerHierarchy.validate(layers)
        var pixels = 0, maskPixels = 0
        for layer in layers {
            guard layer.transform.isValid, layer.opacity.isFinite, (0...1).contains(layer.opacity),
                  !layer.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, layer.name.utf8.count <= 16_384
            else { throw DocumentError.invalid("图层参数无效") }
            if let data = layer.pngData {
                let size = try PNGAsset.inspect(data)
                pixels += size.width * size.height
                guard pixels <= 100_000_000 else { throw DocumentError.tooLarge }
            }
            if let data = layer.maskPNGData {
                let size = try PNGAsset.inspect(data, requireGrayscale: true)
                maskPixels += size.width * size.height
                guard maskPixels <= 100_000_000 else { throw DocumentError.tooLarge }
            }
        }
        if let activeLayerID, !layers.contains(where: { $0.id == activeLayerID }) { throw DocumentError.missingLayer }
        if let selectionMaskPNGData {
            let size = try PNGAsset.inspect(selectionMaskPNGData, requireGrayscale: true)
            guard size.width == width, size.height == height else { throw DocumentError.invalid("选区尺寸与画布不一致") }
        }
        guard appliedAIResults.count <= 100_000,
              appliedAIResults.allSatisfy({ !$0.jobID.isEmpty && !$0.resultID.isEmpty && $0.jobID.utf8.count <= 512 && $0.resultID.utf8.count <= 512 })
        else { throw DocumentError.invalid("候选应用记录无效") }
    }
}

public enum PNGAsset {
    public struct Size: Equatable, Sendable { public let width: Int; public let height: Int }
    public static func inspect(_ data: Data, requireGrayscale: Bool = false, requireRGBA: Bool = false) throws -> Size {
        guard data.count <= 512 * 1024 * 1024 else { throw DocumentError.tooLarge }
        let header = Array(data.prefix(33))
        guard header.count == 33, Array(header.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10],
              String(bytes: header[12..<16], encoding: .ascii) == "IHDR", header[24] == 8,
              [0, 2, 4, 6].contains(header[25]) else { throw DocumentError.unsupported("仅支持 8 位 PNG 栅格图层") }
        if requireGrayscale && header[25] != 0 { throw DocumentError.invalid("蒙版必须是无 alpha 的 8 位灰度 PNG") }
        if requireRGBA && header[25] != 6 { throw DocumentError.invalid("候选必须是 8 位 RGBA PNG") }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == "public.png", CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 30_000, height <= 30_000, width * height <= 100_000_000
        else { throw DocumentError.invalid("PNG 数据或尺寸无效") }
        return Size(width: width, height: height)
    }
}
