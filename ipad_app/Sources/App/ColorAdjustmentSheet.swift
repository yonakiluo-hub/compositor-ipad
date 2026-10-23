import SwiftUI

struct ColorAdjustmentSheet: View {
    @ObservedObject var model: EditorModel
    @State private var openedSessionID: UUID?

    var body: some View {
        NavigationStack {
            if let session = model.colorAdjustmentSession {
                GeometryReader { geometry in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            if geometry.size.width >= 700 {
                                HStack(alignment: .top, spacing: 24) {
                                    preview.frame(maxWidth: .infinity)
                                    controls(session).frame(maxWidth: .infinity)
                                }
                            } else { preview; controls(session) }
                            Text(session.plan.isNew
                                 ? "作用于此位置下方的合成内容。当前软选区会保存为调整层蒙版；组采用穿透规则，剪贴后只调整基底。"
                                 : "修改参数保留原图像素及现有蒙版。当前选区不会再次叠加；可在图层面板调整顺序、透明度和剪贴范围。")
                                .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("adjustment.scope")
                            if let error = model.colorAdjustmentPreviewError { Text(error).foregroundStyle(.red) }
                        }.padding(24)
                    }
                }
                .navigationTitle((session.plan.isNew ? "新建" : "编辑") + session.value.kind.title + "调整层")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { model.cancelColorAdjustment() }.accessibilityIdentifier("adjustment.cancel")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { model.commitColorAdjustment(sessionID: session.id) }
                            .disabled(model.colorAdjustmentPreviewPending || model.colorAdjustmentPreviewError != nil)
                            .accessibilityIdentifier("adjustment.commit")
                    }
                }
                .onAppear { openedSessionID = session.id }
            }
        }
        .colorAdjustmentPageSizing()
        .presentationDetents([.large])
        .onDisappear {
            if model.colorAdjustmentSession?.id == openedSessionID { model.cancelColorAdjustment() }
        }
    }

    private var preview: some View {
        VStack(spacing: 10) {
            ZStack {
                Rectangle().fill(.white)
                if let image = model.colorAdjustmentPreview ?? model.preview {
                    Image(decorative: image, scale: 1).resizable().scaledToFit()
                }
            }.aspectRatio(model.document.size.width / model.document.size.height, contentMode: .fit)
                .frame(maxHeight: 300).clipped().accessibilityIdentifier("adjustment.preview")
            Text(model.colorAdjustmentPreviewPending ? "正在更新预览…" : "预览已更新 · 原稿在完成前保持不变")
                .font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("adjustment.previewState")
        }
    }

    private func controls(_ session: ColorAdjustmentSession) -> some View {
        let value = Binding(get: { model.colorAdjustmentSession?.value ?? session.value }, set: { model.updateColorAdjustment($0, sessionID: session.id) })
        return VStack(alignment: .leading, spacing: 14) {
            Picker("通道", selection: Binding(get: {
                session.value.kind == .levels ? value.wrappedValue.levels.channel : value.wrappedValue.curves.channel
            }, set: { channel in
                var next = value.wrappedValue
                if next.kind == .levels { next.levels.channel = channel } else { next.curves.channel = channel }
                value.wrappedValue = next
            })) {
                ForEach(LevelsChannel.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier("adjustment.channel")
            if session.value.kind == .levels { levelControls(value) }
            else {
                CurveAdjustmentControls(settings: Binding(get: { value.wrappedValue.curves }, set: { next in
                    var v = value.wrappedValue; v.curves = next; value.wrappedValue = v
                }))
            }
            Button("重置当前通道") {
                var next = value.wrappedValue
                if next.kind == .levels { next.levels.ranges[next.levels.channel.index] = LevelRange() }
                else { next.curves.channels[next.curves.channel.index] = [CurvePoint(x: 0, y: 0), CurvePoint(x: 255, y: 255)] }
                value.wrappedValue = next
            }.accessibilityIdentifier("adjustment.resetChannel")
        }
    }

    private func levelControls(_ value: Binding<LayerAdjustment>) -> some View {
        let range = value.wrappedValue.levels.ranges[value.wrappedValue.levels.channel.index]
        func parameter(_ key: WritableKeyPath<LevelRange, Double>) -> Binding<Double> {
            Binding(get: { value.wrappedValue.levels.ranges[value.wrappedValue.levels.channel.index][keyPath: key] }, set: { number in
                var next = value.wrappedValue
                next.levels.ranges[next.levels.channel.index][keyPath: key] = number
                value.wrappedValue = next
            })
        }
        return VStack(spacing: 14) {
            AdjustmentParameter(title: "输入黑场", value: parameter(\.black), range: 0...max(0, range.white - 1), id: "levels.black")
            AdjustmentParameter(title: "中间调", value: parameter(\.gamma), range: 0.1...9.99, id: "levels.gamma", decimals: 2)
            AdjustmentParameter(title: "输入白场", value: parameter(\.white), range: min(255, range.black + 1)...255, id: "levels.white")
            Divider()
            AdjustmentParameter(title: "输出黑场", value: parameter(\.outputBlack), range: 0...255, id: "levels.outputBlack")
            AdjustmentParameter(title: "输出白场", value: parameter(\.outputWhite), range: 0...255, id: "levels.outputWhite")
        }
    }
}

private struct AdjustmentParameter: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let id: String
    var decimals = 0
    var body: some View {
        VStack(spacing: 4) {
            HStack { Text(title); Spacer(); Text(value, format: .number.precision(.fractionLength(decimals))).monospacedDigit() }
            Slider(value: $value, in: range).accessibilityLabel(title).accessibilityIdentifier(id)
        }.font(.caption)
    }
}

private struct CurveAdjustmentControls: View {
    @Binding var settings: CurvesSettings
    @State private var selectedPoint = 0
    @State private var dragIndex: Int?
    private var points: [CurvePoint] { settings.channels[settings.channel.index] }
    private var index: Int { min(selectedPoint, points.count - 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            GeometryReader { geometry in
                Canvas { context, size in
                    func mapped(_ p: CurvePoint) -> CGPoint { CGPoint(x: p.x / 255 * size.width, y: (1 - p.y / 255) * size.height) }
                    var grid = Path()
                    for i in 0...4 {
                        let t = CGFloat(i) / 4
                        grid.move(to: CGPoint(x: t * size.width, y: 0)); grid.addLine(to: CGPoint(x: t * size.width, y: size.height))
                        grid.move(to: CGPoint(x: 0, y: t * size.height)); grid.addLine(to: CGPoint(x: size.width, y: t * size.height))
                    }
                    context.stroke(grid, with: .color(.secondary.opacity(0.3)), lineWidth: 1)
                    var path = Path()
                    for x in 0...255 {
                        let p = mapped(CurvePoint(x: Double(x), y: settings.value(Double(x), channel: settings.channel.index)))
                        if x == 0 { path.move(to: p) } else { path.addLine(to: p) }
                    }
                    context.stroke(path, with: .color(.accentColor), lineWidth: 2)
                    for (i, p) in points.enumerated() {
                        let center = mapped(p), radius: CGFloat = i == index ? 7 : 5
                        context.fill(Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)),
                                     with: .color(i == index ? .white : .accentColor))
                    }
                }
                .background(.black.opacity(0.3)).contentShape(Rectangle())
                .highPriorityGesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    updateDrag(start: drag.startLocation, location: drag.location, size: geometry.size)
                }.onEnded { _ in dragIndex = nil })
                .accessibilityLabel("曲线控制点画布").accessibilityIdentifier("curves.graph")
            }.frame(height: 230).padding(8)
            HStack {
                Text("控制点 \(index + 1)/\(points.count)").font(.caption).accessibilityIdentifier("curves.pointCount")
                Spacer()
                Button { selectedPoint = (index + 1) % points.count } label: { Image(systemName: "chevron.right") }
                    .accessibilityLabel("下一个控制点").accessibilityIdentifier("curves.nextPoint")
                Button("添加") {
                    guard points.count < 32 else { return }
                    let interval = (0..<(points.count - 1)).max { points[$0 + 1].x - points[$0].x < points[$1 + 1].x - points[$1].x }!
                    let x = (points[interval].x + points[interval + 1].x) / 2
                    var next = points; next.insert(CurvePoint(x: x, y: settings.value(x, channel: settings.channel.index)), at: interval + 1)
                    settings.channels[settings.channel.index] = next; selectedPoint = interval + 1
                }.disabled(points.count >= 32).accessibilityIdentifier("curves.addPoint")
                Button("删除") {
                    var next = points; next.remove(at: index); settings.channels[settings.channel.index] = next
                    selectedPoint = min(index, next.count - 1)
                }.disabled(index == 0 || index == points.count - 1).accessibilityIdentifier("curves.deletePoint")
            }
            if index > 0, index < points.count - 1 {
                AdjustmentParameter(title: "输入", value: pointBinding(\.x), range: points[index - 1].x.nextUp...points[index + 1].x.nextDown, id: "curves.input")
            }
            AdjustmentParameter(title: "输出", value: pointBinding(\.y), range: 0...255, id: "curves.output")
            Text("点按添加控制点，拖动调节；端点输入固定，控制点不能交叉。").font(.caption2).foregroundStyle(.secondary)
        }
        .onChange(of: settings.channel) { _, _ in selectedPoint = 0; dragIndex = nil }
    }

    private func pointBinding(_ key: WritableKeyPath<CurvePoint, Double>) -> Binding<Double> {
        Binding(get: { points[index][keyPath: key] }, set: { settings.channels[settings.channel.index][index][keyPath: key] = $0 })
    }

    private func updateDrag(start: CGPoint, location: CGPoint, size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        var next = points
        if dragIndex == nil {
            let nearest = next.indices.min { a, b in
                hypot(next[a].x / 255 * size.width - start.x, (1 - next[a].y / 255) * size.height - start.y)
                    < hypot(next[b].x / 255 * size.width - start.x, (1 - next[b].y / 255) * size.height - start.y)
            }!
            if hypot(next[nearest].x / 255 * size.width - start.x, (1 - next[nearest].y / 255) * size.height - start.y) <= 24 {
                dragIndex = nearest
            } else if next.count < 32 {
                let x = min(254.9999, max(0.0001, start.x / size.width * 255))
                guard next.allSatisfy({ abs($0.x - x) > 0.0002 }) else { return }
                let position = next.firstIndex { $0.x > x }!
                next.insert(CurvePoint(x: x, y: 0), at: position); dragIndex = position
            } else { return }
        }
        guard let i = dragIndex, next.indices.contains(i) else { return }
        selectedPoint = i
        if i > 0, i < next.count - 1 {
            next[i].x = min(next[i + 1].x.nextDown, max(next[i - 1].x.nextUp, location.x / size.width * 255))
        }
        next[i].y = min(255, max(0, (1 - location.y / size.height) * 255))
        settings.channels[settings.channel.index] = next
    }
}

private extension View {
    @ViewBuilder func colorAdjustmentPageSizing() -> some View {
        if #available(iOS 18.0, *) { presentationSizing(.page) }
        else { self }
    }
}
