import SwiftUI
import UniformTypeIdentifiers

struct EditorView: View {
    @ObservedObject var model: EditorModel
    @State private var panel = 0
    @State private var showImporter = false
    @State private var importKind = 0
    @State private var showNew = false
    @State private var showLibrary = false
    @State private var showAdjustments = false
    @State private var showSize = false
    @State private var shareURL: URL?
    @State private var showShare = false
    @State private var sidebar = true
    @State private var documentName = ""
    @State private var compactLayout = false
    @State private var editingOpacity = false
    @State private var draftOpacity = 1.0
    @State private var showRename = false
    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                topBar
                Divider()
                HStack(spacing: 0) {
                    tools
                    ZStack(alignment: .bottomLeading) {
                        CanvasView(model: model)
                        HStack(spacing: 14) {
                            Text("\(model.document.width) × \(model.document.height) px")
                            Text(model.fingerDrawing ? "手指绘画 · 双指平移缩放" : "Pencil 绘画 · 手指平移")
                            Spacer()
                            Button { model.viewportReset += 1 } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.accessibilityLabel("适合画布")
                        }
                        .font(.caption).foregroundStyle(.secondary).padding(12)
                        .background(.ultraThinMaterial)
                    }
                    if sidebar && geometry.size.width >= 700 {
                        Divider()
                        sidebarContent.frame(width: min(310, geometry.size.width * 0.31))
                    }
                }
                Divider()
                ScrollView(.horizontal, showsIndicators: false) { brushBar.frame(minWidth: min(900, geometry.size.width)) }
            }
            .background(Color(red: 0.12, green: 0.14, blue: 0.17))
            .onAppear { compactLayout = geometry.size.width < 700; if compactLayout { sidebar = false } }
            .onChange(of: geometry.size.width) { _, width in
                let compact = width < 700
                if compact && !compactLayout { sidebar = false }
                compactLayout = compact
            }
        }
        .alert("操作未完成", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("好", role: .cancel) { model.errorMessage = nil }
        } message: { Text(model.errorMessage ?? "") }
        .alert("文稿名称", isPresented: $showRename) {
            TextField("名称", text: $documentName)
            Button("保存") { model.rename(documentName) }; Button("取消", role: .cancel) {}
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: importKind == 2 ? [.json] : importKind == 1 ? [UTType(importedAs: "com.compositor.project"), .folder] : [.png, .jpeg, .heic, .tiff], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): if let url = urls.first { if importKind == 2 { model.importPairing(url) } else if importKind == 1 { model.open(url) } else { model.importImage(url) } }
            case .failure(let error): model.errorMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: Binding(get: { compactLayout && sidebar }, set: { sidebar = $0 })) { sidebarContent.presentationDetents([.medium, .large]) }
        .sheet(isPresented: $showNew) { NewDocumentSheet(model: model) }
        .sheet(isPresented: $showSize) { NewDocumentSheet(model: model, resizing: true) }
        .sheet(isPresented: $showAdjustments) { AdjustmentSheet(model: model) }
        .sheet(isPresented: $showLibrary) { libraryView }
        .sheet(isPresented: $showShare) { if let shareURL { ShareSheet(url: shareURL) } }
    }
    private var topBar: some View {
        HStack(spacing: 18) {
            Menu {
                Button("新建画稿", systemImage: "doc.badge.plus") { showNew = true }
                Button("画稿库", systemImage: "square.grid.2x2") { model.refreshLibrary(); showLibrary = true }
                Button("打开 .comp 工程", systemImage: "folder") { importKind = 1; showImporter = true }
                Button("导入图片为图层", systemImage: "photo") { importKind = 0; showImporter = true }
                Divider()
                Button("保存工程", systemImage: "square.and.arrow.down") { model.saveNow() }
                Button("分享分层 .comp 工程") { model.saveNow(); if !model.saveFailed { shareURL = model.documentURL; showShare = true } }
                Button("导出 PNG") { share(model.exportImage()) }
                Button("导出 JPEG（白底）") { share(model.exportImage(jpeg: true)) }
                Divider()
                Button("画布与图像大小") { showSize = true }
            } label: { Image(systemName: "square.grid.2x2").font(.title3) }.accessibilityLabel("文件菜单")
            VStack(alignment: .leading, spacing: 3) {
                Button(model.document.name) { documentName = model.document.name; showRename = true }
                    .font(.headline).foregroundStyle(.primary).accessibilityIdentifier("document.title")
                Text(model.status).font(.caption2).foregroundStyle(model.saveFailed ? .red : .secondary)
            }
            Spacer()
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!model.editor.canUndo).accessibilityLabel("撤销").accessibilityIdentifier("editor.undo")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(!model.editor.canRedo).accessibilityLabel("重做").accessibilityIdentifier("editor.redo")
            Divider().frame(height: 22)
            Button { showAdjustments = true } label: { Image(systemName: "slider.horizontal.3") }.disabled(model.activeLayer?.pngData == nil).accessibilityLabel("调整图层")
            Button { panel = 1; sidebar = true } label: { Label("AI", systemImage: "sparkles") }.accessibilityIdentifier("editor.ai")
            Button { sidebar.toggle() } label: { Image(systemName: "sidebar.right") }.accessibilityLabel("图层与 AI 面板")
        }.padding(.horizontal, 20).frame(height: 64)
    }
    private var tools: some View {
        ScrollView {
            VStack(spacing: 6) {
                ForEach(PadTool.allCases) { tool in
                    Button { model.tool = tool } label: {
                        Image(systemName: tool.symbol).font(.system(size: 20)).frame(width: 46, height: 44)
                            .foregroundStyle(model.tool == tool ? Color.black : Color.primary)
                            .background(model.tool == tool ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 10))
                    }.accessibilityLabel(tool.rawValue).accessibilityIdentifier("tool.\(tool.id)")
                }
                Divider().padding(.vertical, 8)
                ColorPicker("前景色", selection: $model.color, supportsOpacity: false).labelsHidden().frame(width: 40, height: 44)
                Button { model.fill() } label: { Image(systemName: "drop.fill").font(.title3).frame(width: 46, height: 44) }.accessibilityLabel("填充图层或选区")
                Menu {
                    Button("取消选区") { model.clearSelection() }
                    Button("反选") { model.invertSelection() }
                    Button("选区转图层蒙版") { model.selectionToLayerMask() }
                } label: { Image(systemName: "selection.pin.in.out").font(.title3).frame(width: 46, height: 44) }.accessibilityLabel("选区操作")
            }.padding(.vertical, 16).padding(.horizontal, 6)
        }.frame(width: 60)
    }
    private var brushBar: some View {
        HStack(spacing: 20) {
            Text(model.tool.rawValue).font(.subheadline.bold()).frame(width: 70, alignment: .leading)
            HStack { Text("大小"); Slider(value: $model.diameter, in: 1...200); Text("\(Int(model.diameter))").monospacedDigit().frame(width: 30) }.frame(maxWidth: 260)
            HStack { Text("硬度"); Slider(value: $model.hardness, in: 0...1) }.frame(maxWidth: 180)
            HStack { Text("浓度"); Slider(value: $model.brushOpacity, in: 0.05...1) }.frame(maxWidth: 180)
            Spacer(minLength: 0)
            Toggle("手指绘画", isOn: $model.fingerDrawing).fixedSize().accessibilityIdentifier("finger.drawing")
        }.font(.caption).padding(.horizontal, 20).frame(height: 58)
    }
    private var sidebarContent: some View {
        VStack(spacing: 0) {
            Picker("面板", selection: $panel) { Text("图层").tag(0); Text("AI 工作台").tag(1) }.pickerStyle(.segmented).padding(14)
            if panel == 0 { layersPanel } else { aiPanel }
        }
    }
    private var layersPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(model.document.layers.count) 个图层").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { model.addLayer(group: true) } label: { Image(systemName: "folder.badge.plus") }.accessibilityLabel("新建图层组")
                Button { model.addLayer() } label: { Image(systemName: "plus") }.accessibilityLabel("新建图层").accessibilityIdentifier("layer.add")
            }.padding(.horizontal, 16).padding(.bottom, 12)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(LayerHierarchy.entries(model.document.layers, topFirst: true), id: \.layer.id) { entry in
                        layerRow(entry)
                    }
                }.padding(.horizontal, 10)
            }
            if let layer = model.activeLayer { layerControls(layer) }
        }
    }
    private func layerRow(_ entry: LayerHierarchyEntry) -> some View {
        let layer = entry.layer
        return HStack(spacing: 9) {
            Button { model.toggleVisible(layer.id) } label: { Image(systemName: layer.isVisible ? "eye" : "eye.slash").frame(width: 24) }.accessibilityLabel("切换 \(layer.name) 可见性")
            Button { model.select(layer) } label: {
                HStack(spacing: 9) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.12))
                        if let data = layer.pngData, let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFit() }
                        else { Image(systemName: layer.isGroup ? "folder" : "square.dashed").foregroundStyle(.secondary) }
                    }.frame(width: 40, height: 36)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(layer.name).lineLimit(1).foregroundStyle(.primary)
                        Text(layer.isGroup ? "穿透组" : "\(Int(layer.opacity * 100))% · \(layer.blendMode.rawValue)\(layer.maskPNGData == nil ? "" : " · 蒙版")").font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if layer.isLocked { Image(systemName: "lock.fill").font(.caption) }
                }
            }.buttonStyle(.plain)
        }.font(.caption).padding(8).padding(.leading, CGFloat(entry.depth) * 12)
            .background(model.document.activeLayerID == layer.id ? Color.accentColor.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
    }
    private func layerControls(_ layer: RasterLayer) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            HStack { Text("不透明度"); Spacer(); Text("\(Int((editingOpacity ? draftOpacity : layer.opacity) * 100))%").monospacedDigit() }
            Slider(value: Binding(get: { editingOpacity ? draftOpacity : model.activeLayer?.opacity ?? 1 }, set: { draftOpacity = $0 }), in: 0...1, onEditingChanged: { editing in
                if editing { draftOpacity = model.activeLayer?.opacity ?? 1; editingOpacity = true }
                else { editingOpacity = false; model.updateLayer("图层不透明度") { $0.opacity = draftOpacity } }
            })
            if !layer.isGroup {
                Picker("混合模式", selection: Binding(get: { model.activeLayer?.blendMode ?? .normal }, set: { mode in model.updateLayer("混合模式") { $0.blendMode = mode } })) {
                    ForEach(LayerBlendMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.menu)
                HStack {
                    Button("水平翻转") { model.updateLayer("翻转") { $0.transform.flipX.toggle() } }
                    Button("旋转 90°") { model.updateLayer("旋转") { $0.transform.rotation += 90 } }
                }
                HStack {
                    Button("缩小") { scaleLayer(0.9) }; Button("放大") { scaleLayer(1.1) }
                    Menu("蒙版") {
                        Button("使用当前选区") { model.selectionToLayerMask() }
                        Button(layer.maskEnabled ? "停用蒙版" : "启用蒙版") { model.updateLayer("蒙版状态") { $0.maskEnabled.toggle() } }.disabled(layer.maskPNGData == nil)
                        Button("移除蒙版") { model.updateLayer("移除蒙版") { $0.maskPNGData = nil } }.disabled(layer.maskPNGData == nil)
                    }
                }
            }
            HStack(spacing: 20) {
                Button { model.moveLayer(1) } label: { Image(systemName: "arrow.up") }.accessibilityLabel("图层上移")
                Button { model.moveLayer(-1) } label: { Image(systemName: "arrow.down") }.accessibilityLabel("图层下移")
                Button { model.duplicate() } label: { Image(systemName: "plus.square.on.square") }.accessibilityLabel("复制图层")
                Button { model.toggleLock(layer.id) } label: { Image(systemName: layer.isLocked ? "lock.open" : "lock") }.accessibilityLabel("锁定或解锁图层")
                Button(role: .destructive) { model.deleteLayer() } label: { Image(systemName: "trash") }.accessibilityLabel("删除图层")
            }.frame(maxWidth: .infinity)
        }.font(.caption).padding(16)
    }
    private var aiPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Circle().fill(model.capabilities == nil ? Color.gray : Color.accentColor).frame(width: 7, height: 7)
                    Text(model.pairing == nil ? "尚未连接" : model.pairing?.backend == "mock" ? "模拟服务 · 不执行 AI" : "Windows · ComfyUI").font(.caption.bold())
                }
                if model.pairing == nil {
                    Text("导入 Windows 提供的配对文件。绘画、保存和导出可独立使用。").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("参考图编辑后应用输出蒙版。先预览候选，再加入新图层。").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button("导入配对文件") { importKind = 2; showImporter = true }
                    if model.pairing != nil { Button("检查连接") { Task { await model.connect() } } }
                }.font(.caption)
                if model.pairing != nil {
                    Text("生成描述").font(.subheadline.bold())
                    TextEditor(text: $model.prompt).frame(height: 100).padding(8).background(.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                    Text(model.document.selectionMaskPNGData == nil ? "范围：全画布" : "范围：青色选区 + 周边上下文").font(.caption).foregroundStyle(.secondary)
                    Button { Task { await model.submitGeneration() } } label: {
                        HStack { if model.networkBusy { ProgressView() } else { Image(systemName: "sparkles") }; Text(model.networkBusy ? "正在提交…" : "生成候选"); Spacer() }
                    }.buttonStyle(.borderedProminent).disabled(model.networkBusy || model.taskStore == nil).accessibilityIdentifier("ai.generate")
                    Button("恢复 / 刷新任务") { model.restartRecovery() }.font(.caption)
                    Button("备份当前分层工程到 Windows") { Task { await model.backupCurrentDocument() } }.font(.caption).disabled(model.networkBusy || model.taskStore == nil)
                    if !model.backupStatus.isEmpty { Text(model.backupStatus).font(.caption).foregroundStyle(.secondary) }
                    ForEach(model.pendingRequests, id: \.self) { id in
                        Button("重试未确认请求 \(id.prefix(6))") { Task { await model.retryPending(id) } }.font(.caption).disabled(model.networkBusy || model.taskStore == nil)
                    }
                    Divider()
                    ForEach(model.jobs, id: \.jobId) { job in jobCard(job) }
                    Button("断开配对", role: .destructive) { model.disconnect() }.font(.caption)
                }
            }.padding(16)
        }
    }
    private func jobCard(_ job: BridgeJob) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text(job.isSimulation ? "模拟候选" : "生成候选").font(.subheadline.bold()); Spacer(); Text(stateName(job.state)).font(.caption) }
            if let error = job.error { Text("\(error.code)：\(error.message)").font(.caption).foregroundStyle(.red) }
            ForEach(job.results, id: \.resultId) { result in
                if let data = model.candidates[model.candidateKey(job, result)], let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 180).background(.white.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 8))
                    let applied = model.document.appliedAIResults.contains(AIResultKey(jobID: job.jobId, resultID: result.resultId))
                    let stale = job.source.baseRevision != model.document.revision
                    Button(applied ? "已加入图层" : stale ? "文稿已改变 · 保留候选" : "加入新图层") { model.applyCandidate(job, result) }
                        .buttonStyle(.bordered).disabled(applied || stale).font(.caption)
                }
            }
            Text("源版本 \(job.source.baseRevision) · \(job.jobId.prefix(8))").font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(12).background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }
    private var libraryView: some View {
        NavigationStack {
            List(model.library, id: \.self) { url in
                let doc = try? DocumentStore.load(from: url)
                Button { model.open(url); showLibrary = false } label: {
                    VStack(alignment: .leading) { Text(doc?.name ?? "无法读取的工程"); Text("\(doc?.width ?? 0) × \(doc?.height ?? 0) · \(doc?.layers.count ?? 0) 图层").font(.caption).foregroundStyle(.secondary) }
                }
            }.navigationTitle("本机画稿").toolbar { Button("完成") { showLibrary = false } }
        }
    }
    private func share(_ url: URL?) { if let url { shareURL = url; showShare = true } }
    private func scaleLayer(_ factor: CGFloat) {
        model.updateLayer("缩放图层") { layer in
            let center = layer.transform.center
            layer.transform.size.width *= factor; layer.transform.size.height *= factor
            layer.transform.origin = CGPoint(x: center.x - layer.transform.size.width / 2, y: center.y - layer.transform.size.height / 2)
        }
    }
    private func stateName(_ state: BridgeJobState) -> String {
        switch state { case .queued: "排队中"; case .running: "处理中"; case .succeeded: "已完成"; case .failed: "失败" }
    }
}

struct NewDocumentSheet: View {
    @ObservedObject var model: EditorModel
    var resizing = false
    @Environment(\.dismiss) private var dismiss
    @State private var name = "新画稿"
    @State private var width = "1200"
    @State private var height = "900"
    @State private var resample = false
    var body: some View {
        NavigationStack {
            Form {
                if !resizing { TextField("画稿名称", text: $name) }
                TextField("宽度（像素）", text: $width).keyboardType(.numberPad)
                TextField("高度（像素）", text: $height).keyboardType(.numberPad)
                if resizing { Toggle("同时缩放图层", isOn: $resample); Text("关闭时保持图层位置，从右侧和下侧改变画布边界。操作可撤销。").font(.caption) }
                Text("当前版本：单边最多 4096 像素、总计 1600 万像素；性能仍待真机评估。").font(.caption).foregroundStyle(.secondary)
            }
            .navigationTitle(resizing ? "画布大小" : "新建画稿")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("完成") {
                    guard let w = Int(width), let h = Int(height) else { return }
                    if resizing { model.resizeCanvas(width: w, height: h, resample: resample) } else { model.create(name: name, width: w, height: h) }
                    dismiss()
                }.disabled(Int(width) == nil || Int(height) == nil) }
            }
            .onAppear { if resizing { width = String(model.document.width); height = String(model.document.height) } }
        }.presentationDetents([.medium])
    }
}
struct AdjustmentSheet: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var brightness = 0.0
    @State private var contrast = 1.0
    @State private var saturation = 1.0
    @State private var blur = 0.0
    @State private var preview: CGImage?
    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                if let preview { Image(decorative: preview, scale: 1).resizable().scaledToFit().frame(maxHeight: 230) }
                Text("应用到当前图层，可撤销；现有图层蒙版会保留。选区之外保持原样。").font(.caption).foregroundStyle(.secondary)
                HStack { Text("亮度").frame(width: 50); Slider(value: $brightness, in: -0.5...0.5) }
                HStack { Text("对比度").frame(width: 50); Slider(value: $contrast, in: 0...2) }
                HStack { Text("饱和度").frame(width: 50); Slider(value: $saturation, in: 0...2) }
                HStack { Text("模糊").frame(width: 50); Slider(value: $blur, in: 0...20) }
            }.padding(24).navigationTitle("图层调整")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("应用") { model.applyAdjustment(brightness: brightness, contrast: contrast, saturation: saturation, blur: blur); dismiss() } }
                }
                .onAppear(perform: updatePreview).onChange(of: [brightness, contrast, saturation, blur]) { _, _ in updatePreview() }
        }.presentationDetents([.large])
    }
    private func updatePreview() {
        preview = try? model.adjustmentImage(brightness: brightness, contrast: contrast, saturation: saturation, blur: blur)
    }
}
struct ShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
