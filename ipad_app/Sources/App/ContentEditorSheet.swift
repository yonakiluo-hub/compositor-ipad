import SwiftUI
import UIKit

struct ContentEditorSheet: View {
    @ObservedObject var model: EditorModel
    @State private var openedSessionID: UUID?
    @State private var showFonts = false
    @State private var invalidNumbers: Set<String> = []

    var body: some View {
        NavigationStack {
            if let session = model.layerContentSession {
                GeometryReader { geometry in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 20) {
                            if geometry.size.width >= 700 {
                                HStack(alignment: .top, spacing: 24) {
                                    preview.frame(maxWidth: .infinity)
                                    controls(session).frame(maxWidth: .infinity)
                                }
                            } else { preview; controls(session) }
                            Text("预览不会写入原稿。完成后仍可在图层面板编辑；绘画像素前请先栅格化，蒙版与普通图层变换保留编辑结构。")
                                .font(.caption).foregroundStyle(.secondary)
                            if let error = model.layerContentPreviewError { Text(error).foregroundStyle(.red) }
                        }.padding(24)
                    }
                }
                .navigationTitle((session.plan.isNew ? "新建" : "编辑") + session.plan.kind.title + "图层")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { model.cancelLayerContent() }.accessibilityIdentifier("content.cancel")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { model.commitLayerContent(sessionID: session.id) }
                            .disabled(!model.canCommitLayerContent || !invalidNumbers.isEmpty).accessibilityIdentifier("content.commit")
                    }
                }
                .onAppear { openedSessionID = session.id }
                .sheet(isPresented: $showFonts) {
                    ContentFontPicker { name in
                        if !name.isEmpty, var current = model.layerContentSession?.value, var text = current.text {
                            text.fontName = name; text.fontRuns = nil; current.text = text
                            model.updateLayerContent(current, sessionID: session.id)
                        }
                        showFonts = false
                    }
                }
            }
        }
        .onPreferenceChange(ContentNumberValidation.self) { invalidNumbers = $0 }
        .contentPageSizing().presentationDetents([.large])
        .onDisappear { if model.layerContentSession?.id == openedSessionID { model.cancelLayerContent() } }
    }

    private var preview: some View {
        VStack(spacing: 8) {
            ZStack {
                Rectangle().fill(.white)
                if let image = model.layerContentPreview ?? model.preview { Image(decorative: image, scale: 1).resizable().scaledToFit() }
            }.aspectRatio(model.document.size.width / model.document.size.height, contentMode: .fit).frame(maxHeight: 300).clipped()
                .accessibilityIdentifier("content.preview")
            Text(model.layerContentPreviewPending ? "正在更新预览…" : "预览已更新 · 一次完成，一步撤销")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func controls(_ session: LayerContentSession) -> some View {
        let binding = Binding(get: { model.layerContentSession?.value ?? session.value }, set: { model.updateLayerContent($0, sessionID: session.id) })
        return VStack(alignment: .leading, spacing: 16) {
            if session.value.text != nil { textControls(binding, missing: session.missingFonts) }
            else { shapeControls(binding) }
        }.id(session.id)
    }

    private func textControls(_ value: Binding<LayerContentDraft>, missing: [String]) -> some View {
        let text = Binding<LayerTextStyle>(get: { value.wrappedValue.text! }, set: { var v = value.wrappedValue; v.text = $0; value.wrappedValue = v })
        func number(_ key: WritableKeyPath<LayerTextStyle, Double>) -> Binding<Double> {
            Binding(get: { text.wrappedValue[keyPath: key] }, set: { text.wrappedValue[keyPath: key] = $0 })
        }
        return VStack(alignment: .leading, spacing: 14) {
            TextEditor(text: Binding(get: { text.wrappedValue.content }, set: { content in
                var v = text.wrappedValue; v.content = content; v.colorRuns = nil; v.fontRuns = nil; text.wrappedValue = v
            })).frame(minHeight: 110).padding(5).background(.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("文字内容").accessibilityIdentifier("content.text")
            if text.wrappedValue.colorRuns != nil || text.wrappedValue.fontRuns != nil {
                Text("当前含局部字体或颜色。修改正文、统一字体或颜色时会统一相应局部样式；取消保留原稿。")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Text("字体"); Spacer(); Text(text.wrappedValue.fontName).lineLimit(1)
                Button("选择字体…") { showFonts = true }.accessibilityIdentifier("content.font")
            }.font(.caption)
            if !missing.isEmpty {
                Text("缺少字体：\(missing.joined(separator: "、"))。原 PNG 保持不变；更改参数后请先选择可用字体再完成。")
                    .font(.caption).foregroundStyle(.orange).accessibilityIdentifier("content.missingFonts")
                Button("替换为系统字体") {
                    var v = text.wrappedValue; v.fontName = UIFont.systemFont(ofSize: v.fontSize).fontName; v.fontRuns = nil; text.wrappedValue = v
                }.accessibilityIdentifier("content.replaceFont")
            }
            ContentNumber(title: "字号", value: number(\.fontSize), range: 1...2000, id: "content.fontSize")
            Picker("对齐", selection: text.alignment) {
                ForEach(TextAlignment.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).accessibilityIdentifier("content.alignment")
            ColorPicker("文字颜色", selection: Binding(get: { Color(red: text.wrappedValue.red, green: text.wrappedValue.green, blue: text.wrappedValue.blue) }, set: { color in
                let c = contentRGB(color); var v = text.wrappedValue; v.red = c.0; v.green = c.1; v.blue = c.2; v.colorRuns = nil; text.wrappedValue = v
            }), supportsOpacity: false).accessibilityIdentifier("content.color")
            ContentNumber(title: "字距", value: number(\.tracking), range: -100...1000, id: "content.tracking")
            ContentNumber(title: "行距（0 为自动）", value: number(\.leading), range: 0...5000, id: "content.leading")
            ContentNumber(title: "文本框宽度", value: Binding(get: { Double(text.wrappedValue.boxSize?.width ?? value.wrappedValue.size.width) }, set: { width in
                var v = text.wrappedValue; var size = v.boxSize ?? value.wrappedValue.size; size.width = CGFloat(width); v.boxSize = size; text.wrappedValue = v
            }), range: 16...4096, id: "content.width")
            ContentNumber(title: "文本框高度", value: Binding(get: { Double(text.wrappedValue.boxSize?.height ?? value.wrappedValue.size.height) }, set: { height in
                var v = text.wrappedValue; var size = v.boxSize ?? value.wrappedValue.size; size.height = CGFloat(height); v.boxSize = size; text.wrappedValue = v
            }), range: 16...4096, id: "content.height")
        }
    }

    private func shapeControls(_ value: Binding<LayerContentDraft>) -> some View {
        let shape = Binding<LayerShapeStyle>(get: { value.wrappedValue.shape! }, set: { var v = value.wrappedValue; v.shape = $0; value.wrappedValue = v })
        return VStack(alignment: .leading, spacing: 14) {
            Picker("形状", selection: Binding(get: { shape.wrappedValue.kind }, set: { kind in
                var v = shape.wrappedValue; v.kind = kind
                if kind != .line { v.lineWidth = nil; v.start = nil; v.end = nil }
                else { v.lineWidth = v.lineWidth ?? 6; v.start = CGPoint(x: 0.05, y: 0.5); v.end = CGPoint(x: 0.95, y: 0.5) }
                shape.wrappedValue = v
            })) { ForEach(ShapeKind.allCases, id: \.self) { Text($0.title).tag($0) } }
                .pickerStyle(.segmented).accessibilityIdentifier("content.shapeKind")
            ColorPicker("填充／线条颜色", selection: Binding(get: { Color(red: shape.wrappedValue.red, green: shape.wrappedValue.green, blue: shape.wrappedValue.blue) }, set: { color in
                let c = contentRGB(color); var v = shape.wrappedValue; v.red = c.0; v.green = c.1; v.blue = c.2; shape.wrappedValue = v
            }), supportsOpacity: false).accessibilityIdentifier("content.color")
            ContentNumber(title: "宽度", value: Binding(get: { Double(value.wrappedValue.size.width) }, set: { value.wrappedValue.size.width = CGFloat($0) }), range: 1...4096, id: "content.width")
            ContentNumber(title: "高度", value: Binding(get: { Double(value.wrappedValue.size.height) }, set: { value.wrappedValue.size.height = CGFloat($0) }), range: 1...4096, id: "content.height")
            if shape.wrappedValue.kind == .rectangle {
                ContentNumber(title: "圆角（文稿像素）", value: shape.cornerRadius, range: 0...4096, id: "content.cornerRadius")
                Toggle("平滑圆角", isOn: Binding(get: { shape.wrappedValue.smoothing == true }, set: { shape.wrappedValue.smoothing = $0 }))
                    .accessibilityIdentifier("content.smoothing")
            }
            if shape.wrappedValue.kind == .line {
                ContentNumber(title: "线宽", value: Binding(get: { shape.wrappedValue.lineWidth ?? 1 }, set: { shape.wrappedValue.lineWidth = $0 }), range: 1...500, id: "content.lineWidth")
                Toggle("垂直直线", isOn: Binding(get: { abs((shape.wrappedValue.start?.x ?? 0) - (shape.wrappedValue.end?.x ?? 1)) < 0.01 }, set: { vertical in
                    var v = shape.wrappedValue
                    v.start = vertical ? CGPoint(x: 0.5, y: 0.05) : CGPoint(x: 0.05, y: 0.5)
                    v.end = vertical ? CGPoint(x: 0.5, y: 0.95) : CGPoint(x: 0.95, y: 0.5); shape.wrappedValue = v
                })).accessibilityIdentifier("content.verticalLine")
            }
            Text("完成后可使用自由变换手柄移动、缩放与旋转；圆角在缩放时保持文稿像素尺寸。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ContentNumber: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let id: String
    @Environment(\.locale) private var locale
    @State private var text = ""
    @State private var publishedValue: Double?
    @FocusState private var isFocused: Bool
    private var isInvalid: Bool {
        guard let number = ContentNumberInput.number(text, locale: locale) else { return true }
        return !range.contains(number)
    }
    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack {
                Text(title); Spacer()
                // Formatted value fields can defer their binding write until focus
                // ends. An async preview or another control can then restore the old
                // model number. Publish each complete numeric input immediately and
                // keep partial text local across those preview notifications.
                TextField(title, text: Binding(get: { text }, set: update))
                    .focused($isFocused).submitLabel(.done)
                    .keyboardType(range.lowerBound < 0 ? .numbersAndPunctuation : .decimalPad).textFieldStyle(.roundedBorder).frame(width: 100).accessibilityIdentifier(id)
                    .onSubmit { isFocused = false; synchronize() }
                Stepper(title, value: $value, in: range, step: 1).labelsHidden()
            }
            if isInvalid {
                Text("请输入 \(ContentNumberInput.format(range.lowerBound, locale: locale)) 至 \(ContentNumberInput.format(range.upperBound, locale: locale)) 之间的数值。")
                    .foregroundStyle(.red).accessibilityIdentifier(id + ".invalid")
            }
        }.font(.caption)
            .preference(key: ContentNumberValidation.self, value: isInvalid ? Set([id]) : [])
            .onAppear(perform: synchronize)
            .onChange(of: value) { next in
                // A stepper or another model edit still updates the field even
                // if it has focus; our own keystrokes keep their exact draft.
                if !isFocused || publishedValue != next { synchronize() }
            }
            .onChange(of: isFocused) { if !$0 { synchronize() } }
            .onChange(of: locale.identifier) { _ in synchronize() }
    }
    private func update(_ proposed: String) {
        text = proposed
        guard let next = ContentNumberInput.parse(proposed, range: range, locale: locale) else { return }
        publishedValue = next; value = next
    }
    private func synchronize() {
        text = ContentNumberInput.format(value, locale: locale); publishedValue = value
    }
}

struct ContentNumberValidation: PreferenceKey {
    static let defaultValue: Set<String> = []
    static func reduce(value: inout Set<String>, nextValue: () -> Set<String>) { value.formUnion(nextValue()) }
}

enum ContentNumberInput {
    static func format(_ value: Double, locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale; formatter.numberStyle = .decimal; formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0; formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
    static func parse(_ text: String, range: ClosedRange<Double>, locale: Locale) -> Double? {
        guard let value = number(text, locale: locale) else { return nil }
        return min(range.upperBound, max(range.lowerBound, value))
    }
    static func number(_ text: String, locale: Locale) -> Double? {
        let formatter = NumberFormatter(); formatter.locale = locale; formatter.numberStyle = .decimal
        var normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let separator = formatter.decimalSeparator, separator != "." {
            normalized = normalized.replacingOccurrences(of: separator, with: ".")
        }
        for (sign, ascii) in [(formatter.minusSign, "-"), (formatter.plusSign, "+")] {
            if let sign, !sign.isEmpty, sign != ascii { normalized = normalized.replacingOccurrences(of: sign, with: ascii) }
        }
        var ascii = ""
        for character in normalized {
            if character == "." || character == "-" || character == "+" { ascii.append(character) }
            else if let digit = character.wholeNumberValue, (0...9).contains(digit),
                    character.unicodeScalars.allSatisfy({ $0.properties.generalCategory == .decimalNumber }) {
                ascii += String(digit)
            } else { return nil }
        }
        guard let value = Double(ascii), value.isFinite else { return nil }
        return value
    }
}

func contentRGB(_ color: Color) -> (Double, Double, Double) {
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
    UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
    return (Double(r), Double(g), Double(b))
}

private struct ContentFontPicker: UIViewControllerRepresentable {
    let selected: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(selected: selected) }
    func makeUIViewController(context: Context) -> UIFontPickerViewController {
        let picker = UIFontPickerViewController(); picker.delegate = context.coordinator; return picker
    }
    func updateUIViewController(_ uiViewController: UIFontPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIFontPickerViewControllerDelegate {
        let selected: (String) -> Void
        init(selected: @escaping (String) -> Void) { self.selected = selected }
        func fontPickerViewControllerDidPickFont(_ viewController: UIFontPickerViewController) {
            if let descriptor = viewController.selectedFontDescriptor { selected(descriptor.postscriptName) }
        }
        func fontPickerViewControllerDidCancel(_ viewController: UIFontPickerViewController) { selected("") }
    }
}

private extension View {
    @ViewBuilder func contentPageSizing() -> some View { if #available(iOS 18.0, *) { presentationSizing(.page) } else { self } }
}
