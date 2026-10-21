import SwiftUI

/// A preset is a fixed model/workflow combination advertised by this Windows
/// installation. The client cannot enable experiments or invent sampler controls.
struct AIPresetPicker: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("模型与生成组合").font(.subheadline.bold())
            if let capabilities = model.capabilities {
                ForEach(capabilities.presets, id: \.id) { preset in
                    presetCard(preset, capabilities: capabilities)
                }
            } else {
                Text("先检查连接，读取 Windows 当前提供的组合。").font(.caption).foregroundStyle(.secondary)
            }
            if !model.presetCheckMessage.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    if model.isCheckingPresets { ProgressView().controlSize(.small) }
                    Text(model.presetCheckMessage).font(.caption)
                }.accessibilityIdentifier("ai.presetStatus")
            }
            if let status = model.presetStatus, model.pairing?.backend != "mock" {
                VStack(alignment: .leading, spacing: 3) {
                    Text("模型安装：\(checkName(status.installed)) · 依赖结构：\(checkName(status.structuralPreflight))")
                    Text("本机生成测试：\(qualificationName(status.gpuSmoke)) · 绘画质量：\(qualityName(status.qualityAdmission))")
                    if status.executorHeld == true {
                        Text("Windows 仍保留一次推理的占用记录；后续任务会等待服务核对。")
                    }
                }.font(.caption2).foregroundStyle(.secondary)
            }
            Text("使用固定组合；选区在生成后控制候选透明度。原画保留，候选仍需预览后加入图层。")
                .font(.caption2).foregroundStyle(.secondary)
        }.accessibilityIdentifier("ai.presets")
    }

    private func presetCard(_ preset: BridgePreset, capabilities: BridgeCapabilities) -> some View {
        let selected = model.selectedPresetID == preset.id
        return VStack(alignment: .leading, spacing: 5) {
            Button { model.choosePreset(preset.id) } label: {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    Text(preset.displayName).multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
            }.buttonStyle(.plain).font(.caption.bold())
                .disabled(!preset.isAvailable || model.networkBusy)
                .accessibilityIdentifier("ai.preset.\(preset.id)")
            HStack {
                if preset.id == capabilities.defaultPresetID { Text("默认") }
                if preset.experimental == true { Text("实验") }
                Text(preset.unavailableReason ?? (selected ? (model.isCheckingPresets ? "检查中" : model.presetStatus?.ok == true ? "可提交" : "待检查 / 未就绪") : "选用后检查"))
            }.font(.caption2).foregroundStyle(preset.isAvailable ? Color.secondary : Color.orange)
            if let limits = try? capabilities.inputLimits(for: preset) {
                Text(limitText(limits)).font(.caption2).foregroundStyle(.secondary)
            }
            if !capabilities.isSimulation {
                Text(preset.license?.summary ?? "服务未提供许可用途说明").font(.caption2).foregroundStyle(.secondary)
                if let rawURL = preset.license?.url, let url = URL(string: rawURL), url.scheme == "https", url.host != nil {
                    Link("查看模型许可", destination: url).font(.caption2)
                }
            }
        }.padding(10)
            .background(selected ? Color.accentColor.opacity(0.12) : Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private func limitText(_ limits: BridgeInputLimits) -> String {
        let aspect = limits.maximumAspectRatio.map { " · 长宽比 ≤\($0.formatted(.number.precision(.fractionLength(0...2)))):1" } ?? ""
        return "短边 ≥\(limits.minimumSide) px · 最多 \(limits.maximumPixels.formatted()) 像素" + aspect
    }
    private func checkName(_ value: Bool?) -> String {
        value.map { $0 ? "通过" : "未通过" } ?? "未检查"
    }
    private func qualificationName(_ value: String?) -> String {
        switch value {
        case "passed": "服务记录为通过"
        case "failed": "未通过"
        default: "未验证"
        }
    }
    private func qualityName(_ value: String?) -> String {
        switch value {
        case "passed", "approved": "服务记录为通过"
        case "failed", "rejected": "未通过"
        default: "待审阅"
        }
    }
}
