import SwiftUI

struct CanvasCropSheet: View {
    @ObservedObject var model: EditorModel
    @State private var x = 0
    @State private var y = 0
    @State private var width = 1200
    @State private var height = 900
    @State private var ratio = "自由"
    @State private var openedID: UUID?
    private var rect: PixelRect { PixelRect(x: x, y: y, width: width, height: height) }
    var body: some View {
        NavigationStack {
            if let session = model.cropSession {
                Form {
                    Section("裁切范围 · 文稿像素") {
                        number("左边 X", value: $x, id: "crop.x")
                        number("顶边 Y", value: $y, id: "crop.y")
                        number("宽度", value: $width, id: "crop.width")
                        number("高度", value: $height, id: "crop.height")
                        Picker("比例", selection: $ratio) {
                            ForEach(["自由", "原比例", "1:1", "4:3", "16:9"], id: \.self) { Text($0) }
                        }.pickerStyle(.menu).accessibilityIdentifier("crop.ratio")
                        Button("应用比例") { applyRatio(session) }.disabled(ratio == "自由").accessibilityIdentifier("crop.applyRatio")
                        Button("恢复全画布") { x = 0; y = 0; width = session.plan.source.width; height = session.plan.source.height }.accessibilityIdentifier("crop.reset")
                    }
                    Section("结果预览") {
                        Button("更新预览") { model.previewCanvasCrop(rect, sessionID: session.id) }.accessibilityIdentifier("crop.preview")
                        if let image = model.cropPreview {
                            Image(decorative: image, scale: 1).resizable().scaledToFit().frame(maxHeight: 280)
                                .background(.white).accessibilityHidden(false).accessibilityLabel("裁切结果预览").accessibilityIdentifier("crop.previewImage")
                        }
                        if let error = model.cropPreviewError { Text(error).foregroundStyle(.red) }
                        Text("原图像素和图层蒙版不会裁掉或重采样。框外内容仍保存在分层工程中，可通过扩大裁切框重新显露。选区与辅助线随新原点平移；完成只记一次撤销。")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("裁切画布")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { model.cancelCanvasCrop() }.accessibilityIdentifier("crop.cancel") }
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { model.commitCanvasCrop(rect, sessionID: session.id) }.accessibilityIdentifier("crop.commit") }
                }
                .onAppear {
                    guard openedID != session.id else { return }
                    openedID = session.id; x = session.rect.x; y = session.rect.y; width = session.rect.width; height = session.rect.height
                }
            }
        }.presentationDetents([.large])
        .onDisappear { if model.cropSession?.id == openedID { model.cancelCanvasCrop() } }
    }
    private func number(_ title: String, value: Binding<Int>, id: String) -> some View {
        HStack {
            Text(title); Spacer()
            TextField(title, value: value, format: .number.grouping(.never)).multilineTextAlignment(.trailing)
                .keyboardType(.numbersAndPunctuation).frame(width: 140).accessibilityIdentifier(id)
        }
    }
    private func applyRatio(_ session: CanvasCropSession) {
        let value: Double
        switch ratio {
        case "原比例": value = Double(session.plan.source.width) / Double(session.plan.source.height)
        case "1:1": value = 1
        case "4:3": value = 4 / 3
        case "16:9": value = 16 / 9
        default: return
        }
        guard (1...4096).contains(width) else { return }
        height = min(4096, max(1, Int((Double(width) / value).rounded())))
    }
}

struct CanvasGuidesSheet: View {
    @ObservedObject var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var axis = CanvasGuide.Axis.vertical
    @State private var position = 0.0
    @State private var selected: UUID?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("显示辅助线", isOn: $model.showsGuides).accessibilityIdentifier("guides.visible")
                    Text("辅助线只显示在画布上，不进入图片、PSD 合成预览或 AI 输入。显隐不改变文稿历史。位置以文稿像素计算，画布旋转时一起旋转。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section(selected == nil ? "添加辅助线" : "编辑辅助线") {
                    Picker("方向", selection: $axis) { Text("垂直").tag(CanvasGuide.Axis.vertical); Text("水平").tag(CanvasGuide.Axis.horizontal) }
                        .pickerStyle(.segmented).disabled(selected != nil).accessibilityIdentifier("guides.axis")
                    TextField("位置（像素）", value: $position, format: .number.grouping(.never))
                        .keyboardType(.numbersAndPunctuation).accessibilityIdentifier("guides.position")
                    if let selected {
                        Button("更新位置") { model.moveGuide(selected, position: position); self.selected = nil }.accessibilityIdentifier("guides.update")
                        Button("取消编辑") { self.selected = nil }
                    } else {
                        Button("添加") { model.addGuide(axis: axis, position: position) }.disabled(model.document.guides.count >= CanvasGuide.limit)
                            .accessibilityIdentifier("guides.add")
                    }
                }
                Section("已保存的辅助线 · \(model.document.guides.count)") {
                    ForEach(model.document.guides) { guide in
                        HStack {
                            Button("\(guide.axis == .vertical ? "垂直" : "水平") · \(guide.position.formatted(.number.precision(.fractionLength(0...3)))) px") {
                                selected = guide.id; axis = guide.axis; position = guide.position
                            }.accessibilityIdentifier("guides.row.\(guide.id)")
                            Spacer()
                            Button(role: .destructive) { model.removeGuide(guide.id); if selected == guide.id { selected = nil } } label: { Image(systemName: "trash") }
                                .accessibilityLabel("删除辅助线").accessibilityIdentifier("guides.remove.\(guide.id)")
                        }.buttonStyle(.borderless)
                    }
                    Button("清除全部辅助线", role: .destructive) { model.clearGuides(); selected = nil }
                        .disabled(model.document.guides.isEmpty).accessibilityIdentifier("guides.clear")
                }
            }
            .navigationTitle("辅助线")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.accessibilityIdentifier("guides.done") } }
        }.presentationDetents([.large])
    }
}
