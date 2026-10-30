import SwiftUI

struct LayerEffectsSheet: View {
    @ObservedObject var model: EditorModel
    @State private var kind = LayerEffectKind.stroke
    @State private var openedSessionID: UUID?
    @State private var invalidNumbers: Set<String> = []
    var body: some View {
        NavigationStack {
            if let session = model.layerEffectsSession {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        ZStack {
                            Rectangle().fill(.white)
                            if let image = model.layerEffectsPreview ?? model.preview { Image(decorative: image, scale: 1).resizable().scaledToFit() }
                        }.aspectRatio(model.document.size.width / model.document.size.height, contentMode: .fit)
                            .frame(maxHeight: 260).clipped().accessibilityIdentifier("effects.preview")
                        Text(model.layerEffectsPreviewPending ? "正在更新预览…" : "预览已更新 · 一次完成，一步撤销")
                            .font(.caption).foregroundStyle(.secondary)
                        Picker("效果", selection: $kind) {
                            ForEach(LayerEffectKind.allCases, id: \.self) { Text($0.title).tag($0) }
                        }.accessibilityIdentifier("effects.kind")
                        if session.value.parameters(kind) != nil { controls(session).id(kind).id(session.id) }
                        else {
                            Button("添加" + kind.title) {
                                var value = session.value; value.set(kind.defaultParameters, kind: kind)
                                model.updateLayerEffects(value, sessionID: session.id)
                            }.buttonStyle(.borderedProminent).accessibilityIdentifier("effects.add")
                        }
                        Text("效果保留独立参数，保存后仍可修改。关闭开关可暂时隐藏；移除只删除当前效果。")
                            .font(.caption).foregroundStyle(.secondary)
                        if let error = model.layerEffectsPreviewError { Text(error).foregroundStyle(.red) }
                    }.padding(24)
                }
                .navigationTitle("图层效果")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { model.cancelLayerEffects() }.accessibilityIdentifier("effects.cancel") }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { model.commitLayerEffects(sessionID: session.id) }
                            .disabled(!model.canCommitLayerEffects || !invalidNumbers.isEmpty).accessibilityIdentifier("effects.commit")
                    }
                }
                .onAppear { openedSessionID = session.id }
            }
        }.presentationDetents([.large])
            .onPreferenceChange(ContentNumberValidation.self) { invalidNumbers = $0 }
            .onDisappear { if model.layerEffectsSession?.id == openedSessionID { model.cancelLayerEffects() } }
    }
    private func controls(_ session: LayerEffectsSession) -> some View {
        let parameters = Binding<LayerEffectParameters>(get: {
            model.layerEffectsSession?.value.parameters(kind) ?? kind.defaultParameters
        }, set: { p in
            guard var value = model.layerEffectsSession?.value else { return }
            value.set(p, kind: kind); model.updateLayerEffects(value, sessionID: session.id)
        })
        func number(_ key: WritableKeyPath<LayerEffectParameters, Double>) -> Binding<Double> {
            Binding(get: { parameters.wrappedValue[keyPath: key] }, set: { parameters.wrappedValue[keyPath: key] = $0 })
        }
        return VStack(alignment: .leading, spacing: 16) {
            Toggle("启用" + kind.title, isOn: parameters.enabled).accessibilityIdentifier("effects.enabled")
            ColorPicker("颜色", selection: Binding(get: {
                let p = parameters.wrappedValue; return Color(red: p.red, green: p.green, blue: p.blue)
            }, set: { color in
                let rgb = contentRGB(color); var p = parameters.wrappedValue; p.red = rgb.0; p.green = rgb.1; p.blue = rgb.2; parameters.wrappedValue = p
            }), supportsOpacity: false).accessibilityIdentifier("effects.color")
            ContentNumber(title: "不透明度", value: number(\.opacity), range: 0...1, id: "effects.opacity")
            if kind == .stroke || kind == .innerGlow || kind == .outerGlow {
                ContentNumber(title: "大小（图层像素）", value: number(\.size), range: 0...500, id: "effects.size")
            }
            if kind == .stroke { Toggle("内部描边", isOn: parameters.inside).accessibilityIdentifier("effects.inside") }
            if kind == .shadow || kind == .innerShadow {
                ContentNumber(title: "角度", value: number(\.angle), range: -360...360, id: "effects.angle")
                ContentNumber(title: "距离", value: number(\.distance), range: 0...5000, id: "effects.distance")
                ContentNumber(title: "模糊", value: number(\.blur), range: 0...500, id: "effects.blur")
            }
            Button("移除" + kind.title, role: .destructive) {
                var value = session.value; value.remove(kind); model.updateLayerEffects(value, sessionID: session.id)
            }.accessibilityIdentifier("effects.remove")
        }
    }
}
