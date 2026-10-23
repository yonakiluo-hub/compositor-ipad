import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
final class EditorModel: ObservableObject {
    @Published private(set) var editor: DocumentEditor
    @Published var tool: PadTool = .brush {
        didSet {
            if tool != oldValue { cancelColorAdjustment() }
            if tool != .transform, transformSession != nil { transformSession = nil }
            if tool == .eraser, layerEditTarget == .mask { maskPaintReveals = false }
        }
    }
    @Published var colorAdjustmentSession: ColorAdjustmentSession?
    @Published var colorAdjustmentPreview: CGImage?
    @Published var colorAdjustmentPreviewPending = false
    @Published var colorAdjustmentPreviewError: String?
    var colorAdjustmentTask: Task<Void, Never>?
    var colorAdjustmentPreviewRequest = UUID()
    @Published var transformSession: LayerTransformSession?
    @Published var transformAspectLocked = true
    @Published var layerEditTarget: LayerEditTarget = .pixels
    @Published var maskPaintReveals = false
    @Published var selectedLayerIDs: Set<UUID> = []
    @Published var isLayerMultiSelecting = false
    var layerSelectionDocumentID: UUID?
    @Published var color: Color = Color(red: 0.18, green: 0.22, blue: 0.28)
    @Published var diameter: Double = 28
    @Published var hardness: Double = 0.8
    @Published var brushOpacity: Double = 1
    @Published var fingerDrawing = false
    @Published var errorMessage: String?
    @Published var status = "离线编辑 · 自动保存"
    @Published var saveFailed = false
    @Published var preview: CGImage?
    @Published var selectionPreview: CGImage?
    @Published var selectionMode: SelectionCombineMode = .replace
    @Published var selectionFeather: Double = 0
    @Published var selectionGestureCommand: SelectionGestureCommand?
    @Published var selectionDraftPointCount = 0
    @Published var viewportReset = 0
    @Published var viewportRotationReset = 0
    @Published var viewportRotationDegrees: Double = 0
    @Published var pairing: BridgePairing?
    @Published var capabilities: BridgeCapabilities?
    @Published var selectedPresetID: String?
    @Published var presetStatus: BridgeBackendStatus?
    @Published var presetCheckMessage = ""
    @Published var isCheckingPresets = false
    var presetCheckOperation: UUID?
    @Published var jobs: [BridgeJob] = []
    @Published var candidates = CandidatePreviewCache()
    @Published var loadingCandidateKeys: Set<String> = []
    @Published var removingJobIDs: Set<String> = []
    @Published var candidateManagementStatus = ""
    @Published var locallyRemovedJobIDs: Set<String> = []
    @Published var pendingDeletionJobIDs: Set<String> = []
    @Published var unavailableJobIDs: Set<String> = []
    var hiddenJobIDs: Set<String> = []
    var candidateLoadOperations: [String: UUID] = [:]
    var candidateRemovalOperations: [String: UUID] = [:]
    @Published var pendingRequests: [String] = []
    @Published var networkBusy = false
    @Published var backupStatus = ""
    @Published var prompt = "保留轮廓与构图，尝试柔和自然的光影"
    @Published var library: [URL] = []
    let renderer = DocumentRenderer()
    let documentsURL: URL
    private let preferences: UserDefaults
    var taskStore: BridgeSubmissionStore?
    private var autosave: Task<Void, Never>?
    var recoveryTask: Task<Void, Never>?
    var bridge: BridgeClient?
    var isRefreshing = false
    var isRestoringCandidates = false

    var document: CanvasDocument { editor.document }
    var activeLayer: RasterLayer? { document.activeLayer }
    var brushSettings: PadBrushSettings { PadBrushSettings(diameter: diameter, hardness: hardness, opacity: brushOpacity, color: UIColor(color), erasing: tool == .eraser || tool == .maskErase) }

    init(documentsURL: URL? = nil, supportURL: URL? = nil, preferences: UserDefaults = .standard, loadPairing: Bool = true) {
        let manager = FileManager.default
        self.documentsURL = documentsURL ?? manager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.preferences = preferences
        let support = supportURL ?? manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let initial = Self.blankDocument(name: "未命名画稿", width: 1200, height: 900)
        editor = try! DocumentEditor(document: initial)
        do { taskStore = try BridgeSubmissionStore(directory: support.appendingPathComponent("BridgeTasks")) }
        catch { errorMessage = "无法准备任务恢复目录：\(error.localizedDescription)" }
        do {
            try manager.createDirectory(at: self.documentsURL, withIntermediateDirectories: true)
            if let last = preferences.string(forKey: "lastDocument"),
               UUID(uuidString: last) != nil {
                let url = self.documentsURL.appendingPathComponent(last + ".comp")
                if manager.fileExists(atPath: url.path) {
                    let loaded = try DocumentStore.load(from: url)
                    try Self.checkRenderLimits(loaded)
                    editor = try DocumentEditor(document: loaded)
                }
            }
            if loadPairing { pairing = try KeychainPairingStore().load() }
            if let pairing { bridge = try BridgeClient(pairing: pairing) }
        } catch { errorMessage = error.localizedDescription }
        refresh(); refreshLibrary()
    }
    static func blankDocument(name: String, width: Int, height: Int) -> CanvasDocument {
        let layer = RasterLayer(name: "图层 1", transform: LayerTransform(size: CGSize(width: width, height: height)))
        return CanvasDocument(name: name, width: width, height: height, layers: [layer], activeLayerID: layer.id)
    }
    static func checkRenderLimits(_ document: CanvasDocument) throws {
        guard document.width <= 4096, document.height <= 4096, document.width * document.height <= 16_000_000 else { throw RasterError.oversized }
        for layer in document.layers {
            if let data = layer.pngData { _ = try RasterImage.decode(data) }
            if let data = layer.maskPNGData { _ = try RasterImage.decode(data) }
        }
        if let data = document.selectionMaskPNGData { _ = try RasterImage.decode(data) }
    }
    func report(_ operation: () throws -> Void) {
        do { try operation() } catch { errorMessage = error.localizedDescription }
    }
    func edit(_ name: String, _ operation: (inout CanvasDocument) throws -> Void) {
        cancelTransform()
        report { try editor.transaction(name, operation); changed() }
    }
    func updateLayer(_ name: String, _ update: (inout RasterLayer) -> Void) {
        guard selectedLayerIDs.count <= 1 else {
            errorMessage = "请先选择一个图层，再编辑它。"
            return
        }
        guard let id = document.activeLayerID else { return }
        edit(name) { document in
            guard !document.isEffectivelyLocked(id), let index = document.layers.firstIndex(where: { $0.id == id }) else { throw DocumentError.lockedLayer }
            update(&document.layers[index])
        }
    }
    func select(_ layer: RasterLayer) {
        if isLayerMultiSelecting { toggleLayerSelection(layer.id); return }
        if document.activeLayerID != layer.id { cancelTransform() }
        layerEditTarget = .pixels
        report {
            try editor.selectLayer(layer.id)
            selectedLayerIDs = [layer.id]
            objectWillChange.send(); scheduleSave()
        }
    }
    func undo() { cancelTransform(); report { try editor.undo(); changed() } }
    func redo() { cancelTransform(); report { try editor.redo(); changed() } }
    func changed() { cancelTransform(); refresh(); scheduleSave() }
    func refresh() {
        synchronizeLayerSelection()
        normalizeLayerEditTarget()
        objectWillChange.send()
        report {
            preview = try renderer.render(document)
            selectionPreview = try document.selectionMaskPNGData.map(RasterImage.decode)
        }
    }
    func scheduleSave() {
        autosave?.cancel()
        autosave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }
    func saveNow() {
        autosave?.cancel()
        do {
            try DocumentStore.save(document, to: documentURL)
            editor.markSaved()
            preferences.set(document.id.uuidString.lowercased(), forKey: "lastDocument")
            status = "已保存 · 版本 \(document.revision)"; saveFailed = false
            refreshLibrary()
        } catch { status = "保存失败"; saveFailed = true; errorMessage = error.localizedDescription }
    }
    var documentURL: URL { documentsURL.appendingPathComponent(document.id.uuidString.lowercased() + ".comp") }
    func refreshLibrary() {
        library = ((try? FileManager.default.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "comp" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    func open(_ url: URL) {
        cancelTransform()
        layerEditTarget = .pixels
        saveNow(); guard !saveFailed else { return }
        report {
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            let loaded = try DocumentStore.load(from: url); try Self.checkRenderLimits(loaded)
            let destination = documentsURL.appendingPathComponent(loaded.id.uuidString.lowercased() + ".comp")
            let imported = DocumentStore.resolvingImportCollision(loaded, from: url, localDestination: destination,
                destinationExists: FileManager.default.fileExists(atPath: destination.path))
            editor = try DocumentEditor(document: imported); renderer.clearCache(); resetCandidateContext(); jobs.removeAll(); pendingRequests.removeAll()
            viewportReset += 1; changed(); restartRecovery()
        }
    }
    func create(name: String, width: Int, height: Int) {
        cancelTransform()
        layerEditTarget = .pixels
        saveNow(); guard !saveFailed else { return }
        report {
            _ = try RasterImage.context(width: width, height: height)
            editor = try DocumentEditor(document: Self.blankDocument(name: name.isEmpty ? "未命名画稿" : name, width: width, height: height))
            renderer.clearCache(); resetCandidateContext(); jobs.removeAll(); pendingRequests.removeAll(); viewportReset += 1; changed(); restartRecovery()
        }
    }
    func addLayer(group: Bool = false) {
        edit(group ? "新建图层组" : "新建图层") { document in
            let parent = document.activeLayer?.isGroup == true ? document.activeLayerID : document.activeLayer?.parentID
            let layer = RasterLayer(name: group ? "图层组" : "图层 \(document.layers.count + 1)",
                                    transform: LayerTransform(size: document.size), parentID: parent, isGroup: group)
            if let parent, document.isEffectivelyLocked(parent) { throw DocumentError.lockedLayer }
            document.layers.append(layer); document.activeLayerID = layer.id
        }
    }
    func toggleVisible(_ id: UUID) {
        edit("图层可见性") { document in if let i = document.layers.firstIndex(where: { $0.id == id }) { document.layers[i].isVisible.toggle() } }
    }
    func toggleLock(_ id: UUID) {
        edit("图层锁定") { document in if let i = document.layers.firstIndex(where: { $0.id == id }) { document.layers[i].isLocked.toggle() } }
    }
    func duplicate() { cancelTransform(); guard let id = document.activeLayerID else { return }; report { _ = try editor.duplicateLayer(id); changed() } }
    func deleteLayer() { cancelTransform(); guard let id = document.activeLayerID else { return }; report { try editor.deleteLayer(id); changed() } }
    func moveLayer(_ delta: Int) {
        cancelTransform()
        guard let id = document.activeLayerID else { return }
        report { try editor.reorderLayer(id, offset: delta); changed() }
    }
    func importImage(_ url: URL) {
        report {
            let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
            let data = try Data(contentsOf: url)
            guard let source = UIImage(data: data) else { throw RasterError.invalidImage }
            let pixelSize = CGSize(width: source.size.width * source.scale, height: source.size.height * source.scale)
            guard pixelSize.width <= 4096, pixelSize.height <= 4096, pixelSize.width * pixelSize.height <= 16_000_000 else { throw RasterError.oversized }
            // UIKit applies EXIF orientation; the stored source is upright sRGB RGBA8.
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.preferredRange = .standard
            let upright = UIGraphicsImageRenderer(size: pixelSize, format: format).image { _ in source.draw(in: CGRect(origin: .zero, size: pixelSize)) }
            guard let cg = upright.cgImage else { throw RasterError.invalidImage }
            let context = try RasterImage.context(width: cg.width, height: cg.height)
            RasterImage.draw(cg, in: CGRect(origin: .zero, size: pixelSize), context: context)
            guard let normalized = context.makeImage() else { throw RasterError.allocation }
            let png = try RasterImage.png(normalized)
            edit("导入图片") { document in
                let factor = min(1, min(CGFloat(document.width) / pixelSize.width, CGFloat(document.height) / pixelSize.height))
                let size = CGSize(width: pixelSize.width * factor, height: pixelSize.height * factor)
                let layer = RasterLayer(name: url.deletingPathExtension().lastPathComponent, pngData: png,
                                        transform: LayerTransform(origin: CGPoint(x: (CGFloat(document.width) - size.width) / 2, y: (CGFloat(document.height) - size.height) / 2), size: size))
                document.layers.append(layer); document.activeLayerID = layer.id
            }
        }
    }
    func exportImage(jpeg: Bool = false) -> URL? {
        do {
            let image = try renderer.render(document)
            let data = try jpeg ? RasterImage.jpeg(image) : RasterImage.png(image)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Compositor-" + UUID().uuidString + (jpeg ? ".jpg" : ".png"))
            try data.write(to: url, options: .atomic); return url
        } catch { errorMessage = error.localizedDescription; return nil }
    }
    func clearSelection() {
        selectionGestureCommand = .init(.cancel)
        edit("取消选区") { $0.selectionMaskPNGData = nil }
    }
    func invertSelection() {
        report {
            let context = try RasterImage.context(width: document.width, height: document.height, gray: true)
            let rect = CGRect(origin: .zero, size: document.size)
            context.setFillColor(gray: 1, alpha: 1); context.fill(rect)
            if let mask = selectionPreview { context.setBlendMode(.difference); RasterImage.draw(mask, in: rect, context: context) }
            guard let mask = context.makeImage() else { throw RasterError.allocation }
            let data = try RasterImage.png(mask); edit("反选") { $0.selectionMaskPNGData = data }
        }
    }
    func selectionToLayerMask() {
        guard var layer = activeLayer, selectedLayerIDs.count <= 1 else { return }
        report {
            if layer.isGroup && layer.maskPNGData == nil { layer.transform = LayerTransform(size: document.size, sampling: .nearest) }
            let full = try selectionPreview ?? RasterImage.solidMask(width: document.width, height: document.height, white: true)
            let size = try renderer.pixelSize(of: layer)
            guard let mask = try PadMaskRaster.selection(full, layer: layer, size: size, document: document, renderer: renderer) else { return }
            let data = try RasterImage.png(mask)
            updateLayer("选区转图层蒙版") { $0.transform = layer.transform; $0.maskPNGData = data; $0.maskEnabled = true }
        }
    }
    func fill() {
        if layerEditTarget == .mask {
            fillLayerMask(reveal: tool != .eraser && maskPaintReveals)
            return
        }
        guard selectedLayerIDs.count <= 1 else {
            errorMessage = "请先选择一个图层，再填充。"
            return
        }
        guard let layer = activeLayer, !layer.isGroup, layer.adjustment == nil else {
            errorMessage = "调整层请编辑参数，或切换到蒙版绘画。"; return
        }
        report {
            let size = try renderer.pixelSize(of: layer)
            let context = try RasterImage.context(width: Int(size.width), height: Int(size.height))
            let rect = CGRect(origin: .zero, size: size)
            if let image = try renderer.image(for: layer) { RasterImage.draw(image, in: rect, context: context) }
            if let selection = try renderer.localSelection(selectionPreview, layer: layer, document: document) { RasterImage.clip(selection, to: rect, context: context) }
            context.setFillColor(UIColor(color).cgColor); context.setAlpha(brushOpacity); context.fill(rect)
            guard let filled = context.makeImage() else { throw RasterError.allocation }
            commitPixels(filled)
        }
    }
    func commitPixels(_ image: CGImage) {
        guard activeLayer?.adjustment == nil else { errorMessage = "调整层没有可绘制的像素，请编辑参数或蒙版。"; return }
        report {
            let data = try RasterImage.png(image)
            updateLayer("绘画") { $0.pngData = data }
        }
    }
    func commitSelection(_ image: CGImage) {
        report { let data = try RasterImage.png(image); edit("编辑选区") { $0.selectionMaskPNGData = data } }
    }
    func adjustmentImage(brightness: Double, contrast: Double, saturation: Double, blur: Double) throws -> CGImage? {
        guard let layer = activeLayer, !layer.isGroup, layer.adjustment == nil, let source = try renderer.image(for: layer) else { return nil }
        let adjusted = try renderer.adjusted(source, brightness: brightness, contrast: contrast, saturation: saturation, blur: blur)
        let context = try RasterImage.context(width: source.width, height: source.height)
        let rect = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        RasterImage.draw(source, in: rect, context: context)
        if let selection = try renderer.localSelection(selectionPreview, layer: layer, document: document) { RasterImage.clip(selection, to: rect, context: context) }
        context.setBlendMode(.copy); RasterImage.draw(adjusted, in: rect, context: context)
        return context.makeImage()
    }
    func applyAdjustment(brightness: Double, contrast: Double, saturation: Double, blur: Double) {
        report {
            guard let image = try adjustmentImage(brightness: brightness, contrast: contrast, saturation: saturation, blur: blur) else { return }
            let png = try RasterImage.png(image)
            updateLayer("应用调整") { $0.pngData = png }
        }
    }
    func rename(_ name: String) { if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { edit("重命名文稿") { $0.name = name } } }
    func resizeCanvas(width: Int, height: Int, resample: Bool) {
        cancelTransform()
        report {
            try editor.transaction(resample ? "图像大小" : "画布大小") { document in
                try renderer.resizeCanvas(&document, width: width, height: height, resample: resample)
            }
            renderer.clearCache(); changed()
            viewportReset += 1
        }
    }
}

enum PadTool: String, CaseIterable, Identifiable {
    case brush = "画笔", eraser = "橡皮", move = "移动", transform = "自由变换", mask = "选区笔", maskErase = "减选", rectangle = "矩形选区", ellipse = "椭圆选区", lasso = "自由套索", polygonLasso = "多边形套索", eyedropper = "吸色"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .brush: "paintbrush.pointed"; case .eraser: "eraser"; case .move: "arrow.up.and.down.and.arrow.left.and.right"
        case .transform: "arrow.up.left.and.arrow.down.right"
        case .mask: "paintbrush.pointed.fill"; case .maskErase: "minus.circle"; case .rectangle: "rectangle.dashed"
        case .ellipse: "circle.dashed"; case .lasso: "lasso"; case .polygonLasso: "pentagon"; case .eyedropper: "eyedropper"
        }
    }
    var isShapeSelection: Bool { [.rectangle, .ellipse, .lasso, .polygonLasso].contains(self) }
    var isSelection: Bool { [.mask, .maskErase].contains(self) || isShapeSelection }
}
