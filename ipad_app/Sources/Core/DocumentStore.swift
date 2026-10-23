// .comp schema and package validation adapted from Compositor IO/ProjectStore.swift.
// Copyright (c) 2026 Wonder Assembly LLC. MIT; see licenses/Compositor-MIT.txt.
// Upstream: 7c2a5a4a3e7f685a8a0ec282ef0b4284f20b5477.
import Foundation
import CoreGraphics
import ImageIO
import CryptoKit

/// A strict v1–v14 raster subset of Compositor packages, with a separate iPad state file.
/// Masks, transforms, hierarchy and blend metadata use the upstream schema unchanged.
/// A package containing an unsupported editing feature is rejected before replacing a document.
public enum DocumentStore {
    public static let formatVersion = 14
    private static let manifestLimit = 4 * 1024 * 1024
    private static let assetLimit = 512 * 1024 * 1024

    private struct Manifest: Codable {
        var format = "com.compositor.project"
        var version = DocumentStore.formatVersion
        var colorSpace = "sRGB"
        var resolution: Double?
        let documentID: UUID
        let width: Int
        let height: Int
        let activeLayerID: UUID?
        let layers: [LayerRecord]
    }

    private struct LayerRecord: Codable {
        let id: UUID
        let name: String
        let isVisible: Bool
        let transform: LayerTransform
        let imageFile: String?
        var parentID: UUID?
        var isGroup: Bool?
        var opacity: Double?
        var blendMode: LayerBlendMode?
        var maskFile: String?
        var maskEnabled: Bool?
        var maskSourceID: UUID?
        var adjustment: LayerAdjustment?
    }

    private struct IPadState: Codable {
        var format = "com.compositor.ipad-state"
        var version = 1
        let documentID: UUID
        let manifestSHA256: String
        let name: String
        let revision: Int64
        let lockedLayerIDs: Set<UUID>
        let appliedAIResults: Set<AIResultKey>
        let selectionFile: String?
        let groupMaskCompositing: String?
        let adjustmentCompositing: String?
    }

    public static func save(_ document: CanvasDocument, to url: URL) throws {
        try document.validate()
        var assets: [String: FileWrapper] = [:]
        var encodedBytes = 0
        let records = try document.layers.map { layer -> LayerRecord in
            let imageFile = layer.pngData.map { _ in "\(layer.id.uuidString).png" }
            let maskFile = layer.maskPNGData.map { _ in "\(layer.id.uuidString).mask.png" }
            for (filename, data) in [(imageFile, layer.pngData), (maskFile, layer.maskPNGData)] {
                if let filename, let data {
                    try validateDecodable(data)
                    encodedBytes += data.count
                    guard encodedBytes <= assetLimit else { throw DocumentError.tooLarge }
                    assets[filename] = FileWrapper(regularFileWithContents: data)
                }
            }
            return LayerRecord(id: layer.id, name: layer.name, isVisible: layer.isVisible,
                               transform: layer.transform, imageFile: imageFile, parentID: layer.parentID,
                               isGroup: layer.isGroup ? true : nil, opacity: layer.opacity, blendMode: layer.blendMode,
                               maskFile: maskFile, maskEnabled: maskFile == nil ? nil : layer.maskEnabled,
                               maskSourceID: layer.maskSourceID, adjustment: layer.adjustment)
        }
        let manifest = Manifest(resolution: document.resolution, documentID: document.id, width: document.width,
                                height: document.height, activeLayerID: document.activeLayerID, layers: records)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let metadata = try encoder.encode(manifest)
        guard metadata.count <= manifestLimit else { throw DocumentError.tooLarge }
        let state = IPadState(documentID: document.id, manifestSHA256: digest(metadata), name: document.name,
                              revision: document.revision, lockedLayerIDs: Set(document.layers.filter(\.isLocked).map(\.id)),
                              appliedAIResults: document.appliedAIResults,
                              selectionFile: document.selectionMaskPNGData == nil ? nil : "selection.png",
                              groupMaskCompositing: document.layers.contains { $0.isGroup && $0.maskPNGData != nil } ? GroupMaskRules.semantics : nil,
                              adjustmentCompositing: document.layers.contains { $0.adjustment != nil } ? "pass-through-lut-v1" : nil)
        let stateBytes = try encoder.encode(state)
        guard stateBytes.count <= manifestLimit else { throw DocumentError.tooLarge }
        var files = ["manifest.json": FileWrapper(regularFileWithContents: metadata),
                     "images": FileWrapper(directoryWithFileWrappers: assets),
                     "ipad-state.json": FileWrapper(regularFileWithContents: stateBytes)]
        if let selection = document.selectionMaskPNGData {
            try validateDecodable(selection)
            encodedBytes += selection.count
            guard encodedBytes <= assetLimit else { throw DocumentError.tooLarge }
            files["selection.png"] = FileWrapper(regularFileWithContents: selection)
        }
        let package = FileWrapper(directoryWithFileWrappers: files)
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            do { try package.write(to: target, options: .atomic, originalContentsURL: nil) }
            catch { writeError = error }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }

    public static func load(from url: URL) throws -> CanvasDocument {
        var coordinationError: NSError?
        var result: Result<CanvasDocument, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { source in
            result = Result { try readPackage(source) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw DocumentError.invalid("无法读取工程") }
        return try result.get()
    }

    /// Importing an older exported copy must not replace a newer local document with the
    /// same identity. The caller supplies the destination's existence so this decision is
    /// a pure value transformation; opening that actual local package keeps its identity.
    public static func resolvingImportCollision(_ document: CanvasDocument, from sourceURL: URL,
                                                localDestination: URL, destinationExists: Bool) -> CanvasDocument {
        let sourcePath = sourceURL.resolvingSymlinksInPath().standardizedFileURL.path
        let destinationPath = localDestination.resolvingSymlinksInPath().standardizedFileURL.path
        guard destinationExists, sourcePath != destinationPath else { return document }
        let suffix = " 副本"
        var name = document.name
        while name.utf8.count + suffix.utf8.count > 16_384 { name.removeLast() }
        // Layer IDs, source bytes, hierarchy, masks and selection belong to the copied
        // artwork. Generation receipts and revision history belong to its former document.
        return CanvasDocument(name: name + suffix, width: document.width, height: document.height,
                              revision: 0, resolution: document.resolution, layers: document.layers,
                              activeLayerID: document.activeLayerID, selectionMaskPNGData: document.selectionMaskPNGData)
    }

    private static func readPackage(_ url: URL) throws -> CanvasDocument {
        let rootValues = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else { throw DocumentError.invalid("工程必须是目录包") }
        let metadataURL = url.appendingPathComponent("manifest.json")
        _ = try checkFile(metadataURL, inside: url, maximumBytes: manifestLimit)
        let metadata = try Data(contentsOf: metadataURL)
        try checkSupportedJSON(metadata)
        let manifest: Manifest
        do { manifest = try JSONDecoder().decode(Manifest.self, from: metadata) }
        catch { throw DocumentError.invalid("清单字段缺失或类型无效") }
        guard manifest.format == "com.compositor.project", manifest.colorSpace == "sRGB" else { throw DocumentError.unsupported("非 sRGB Compositor 工程") }
        guard (1...formatVersion).contains(manifest.version) else { throw DocumentError.unsupported("工程版本 \(manifest.version)") }
        guard manifest.layers.count <= 10_000 else { throw DocumentError.tooLarge }
        var state: IPadState?
        let stateURL = url.appendingPathComponent("ipad-state.json")
        if FileManager.default.fileExists(atPath: stateURL.path) {
            _ = try checkFile(stateURL, inside: url, maximumBytes: manifestLimit)
            do { state = try JSONDecoder().decode(IPadState.self, from: Data(contentsOf: stateURL)) }
            catch { throw DocumentError.invalid("iPad 编辑状态损坏") }
            guard let state, state.format == "com.compositor.ipad-state", state.version == 1,
                  state.documentID == manifest.documentID, state.manifestSHA256 == digest(metadata),
                  state.groupMaskCompositing == nil || state.groupMaskCompositing == GroupMaskRules.semantics,
                  state.adjustmentCompositing == nil || state.adjustmentCompositing == "pass-through-lut-v1",
                  state.selectionFile == nil || state.selectionFile == "selection.png"
            else { throw DocumentError.invalid("iPad 编辑状态与工程清单不一致") }
            guard state.lockedLayerIDs.isSubset(of: Set(manifest.layers.map(\.id))) else { throw DocumentError.invalid("锁定图层引用无效") }
        }
        var bytesUsed = 0, pixelsUsed = 0, maskPixelsUsed = 0
        func asset(_ filename: String?, layerID: UUID, mask: Bool) throws -> Data? {
            guard let filename else { return nil }
            let expected = "\(layerID.uuidString)\(mask ? ".mask" : "").png"
            guard filename == expected else { throw DocumentError.unsupported("资源路径或非 PNG 图层") }
            let imagesURL = url.appendingPathComponent("images")
            let directory = try imagesURL.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard directory.isDirectory == true, directory.isSymbolicLink != true else { throw DocumentError.invalid("图层资源目录无效") }
            let file = imagesURL.appendingPathComponent(filename)
            bytesUsed += try checkFile(file, inside: url, maximumBytes: assetLimit)
            guard bytesUsed <= assetLimit else { throw DocumentError.tooLarge }
            let data = try Data(contentsOf: file)
            let size = try PNGAsset.inspect(data, requireGrayscale: mask)
            if mask { maskPixelsUsed += size.width * size.height }
            else { pixelsUsed += size.width * size.height }
            guard pixelsUsed <= 100_000_000, maskPixelsUsed <= 100_000_000 else { throw DocumentError.tooLarge }
            try validateDecodable(data)
            return data
        }
        let layers = try manifest.layers.map { record -> RasterLayer in
            guard manifest.version >= 2 || (record.parentID == nil && record.isGroup != true),
                  manifest.version >= 3 || ((record.opacity ?? 1) == 1 && (record.blendMode ?? .normal) == .normal),
                  manifest.version >= 4 || (record.maskFile == nil && record.maskEnabled == nil),
                  manifest.version >= 5 || record.maskSourceID == nil,
                  manifest.version >= 8 || record.isGroup != true || (record.opacity ?? 1) == 1,
                  record.maskEnabled == nil || record.maskFile != nil else { throw DocumentError.invalid("图层字段与工程版本不一致") }
            return RasterLayer(id: record.id, name: record.name,
                               pngData: try asset(record.imageFile, layerID: record.id, mask: false), transform: record.transform,
                               isVisible: record.isVisible, isLocked: state?.lockedLayerIDs.contains(record.id) ?? false,
                               opacity: record.opacity ?? 1, blendMode: record.blendMode ?? .normal,
                               parentID: record.parentID, isGroup: record.isGroup ?? false,
                               maskPNGData: try asset(record.maskFile, layerID: record.id, mask: true), maskEnabled: record.maskEnabled ?? true,
                               maskSourceID: record.maskSourceID, adjustment: record.adjustment)
        }
        if layers.contains(where: { $0.isGroup && $0.maskPNGData != nil }), state?.groupMaskCompositing != GroupMaskRules.semantics {
            throw DocumentError.unsupported("组蒙版合成语义缺失或不兼容；请保留原 iPad 工程状态")
        }
        if layers.contains(where: { $0.adjustment != nil }), state?.adjustmentCompositing != "pass-through-lut-v1" {
            throw DocumentError.unsupported("调整层合成语义缺失或不兼容；请保留原 iPad 工程状态")
        }
        var selection: Data?
        if let selectionFile = state?.selectionFile {
            let file = url.appendingPathComponent(selectionFile)
            bytesUsed += try checkFile(file, inside: url, maximumBytes: assetLimit)
            guard bytesUsed <= assetLimit else { throw DocumentError.tooLarge }
            selection = try Data(contentsOf: file)
            try validateDecodable(selection!)
        }
        // Foreign packages have no iPad revision. A time-based initial value avoids restarting at
        // zero and accidentally matching a previously submitted generation for the same UUID.
        let foreignRevision = Int64(Date().timeIntervalSince1970 * 1_000_000)
        let document = CanvasDocument(id: manifest.documentID, name: state?.name ?? url.deletingPathExtension().lastPathComponent,
                                      width: manifest.width, height: manifest.height, revision: state?.revision ?? foreignRevision,
                                      resolution: manifest.resolution ?? 72, layers: layers, activeLayerID: manifest.activeLayerID,
                                      selectionMaskPNGData: selection, appliedAIResults: state?.appliedAIResults ?? [])
        try document.validate()
        return document
    }

    /// JSONDecoder ignores unknown fields. Explicit checking prevents loading something that
    /// looks right now but silently loses editable text, masks, adjustments or effects on save.
    private static func checkSupportedJSON(_ data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let layers = root["layers"] as? [[String: Any]] else { throw DocumentError.invalid("工程清单不是对象") }
        let rootKeys: Set<String> = ["format", "version", "colorSpace", "resolution", "documentID", "width", "height", "activeLayerID", "layers", "guides"]
        guard Set(root.keys).isSubset(of: rootKeys) else { throw DocumentError.unsupported("未知文稿字段") }
        if let guides = root["guides"], !(guides is NSNull) {
            guard let values = guides as? [Any], values.isEmpty else { throw DocumentError.unsupported("辅助线") }
        }
        let layerKeys: Set<String> = ["id", "name", "isVisible", "transform", "imageFile", "parentID", "isGroup", "opacity", "blendMode", "maskFile", "maskEnabled", "maskSourceID", "adjustment", "maskPlacement", "maskLinked", "shape", "effects", "text"]
        let transformKeys: Set<String> = ["origin", "size", "rotation", "flipX", "flipY", "sampling"]
        for layer in layers {
            guard Set(layer.keys).isSubset(of: layerKeys) else { throw DocumentError.unsupported("未知图层字段") }
            for field in ["maskPlacement", "shape", "effects", "text"] {
                if let value = layer[field], !(value is NSNull) { throw DocumentError.unsupported(field) }
            }
            if let adjustment = layer["adjustment"], !(adjustment is NSNull) {
                try checkAdjustmentJSON(adjustment)
            }
            if let linked = layer["maskLinked"], !(linked is NSNull) {
                guard linked as? Bool == true, layer["maskFile"] as? String != nil else { throw DocumentError.unsupported("未链接蒙版") }
            }
            if let mode = layer["blendMode"] as? String, LayerBlendMode(rawValue: mode) == nil { throw DocumentError.unsupported("混合模式 \(mode)") }
            if let transform = layer["transform"] as? [String: Any], !Set(transform.keys).isSubset(of: transformKeys) {
                throw DocumentError.unsupported("未知变换字段")
            }
        }
    }

    /// Every nested field must be recognized before JSONDecoder can ignore it.
    private static func checkAdjustmentJSON(_ value: Any) throws {
        func object(_ value: Any, keys: Set<String>) throws -> [String: Any] {
            guard let object = value as? [String: Any], Set(object.keys).isSubset(of: keys)
            else { throw DocumentError.unsupported("未知调整层字段") }
            return object
        }
        let a = try object(value, keys: ["kind", "levels", "curves", "hue", "saturation", "lightness", "colorize"])
        if let v = a["levels"], !(v is NSNull) {
            let settings = try object(v, keys: ["channel", "ranges"])
            guard let ranges = settings["ranges"] as? [Any], ranges.count == 4 else { throw DocumentError.invalid("色阶通道无效") }
            for range in ranges { _ = try object(range, keys: ["black", "gamma", "white", "outputBlack", "outputWhite"]) }
        }
        if let v = a["curves"], !(v is NSNull) {
            let settings = try object(v, keys: ["channel", "channels"])
            guard let channels = settings["channels"] as? [[Any]], channels.count == 4 else { throw DocumentError.invalid("曲线通道无效") }
            for points in channels {
                guard (2...32).contains(points.count) else { throw DocumentError.invalid("曲线控制点数量无效") }
                for point in points { _ = try object(point, keys: ["x", "y"]) }
            }
        }
    }

    private static func checkFile(_ file: URL, inside package: URL, maximumBytes: Int) throws -> Int {
        let root = package.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard file.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root) else { throw DocumentError.invalid("工程资源路径越界") }
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let count = values.fileSize, count >= 0, count <= maximumBytes else { throw DocumentError.invalid("资源文件类型或大小无效") }
        return count
    }

    private static func validateDecodable(_ data: Data) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
              image.bitsPerComponent == 8 else { throw DocumentError.invalid("图层 PNG 损坏或无法解码") }
    }

    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
