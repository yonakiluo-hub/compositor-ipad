import SwiftUI

struct ImageSelectionControls: View {
    @ObservedObject var model:EditorModel
    var body:some View {
        HStack(spacing:14) {
            Picker("选区组合",selection:$model.selectionMode) {
                ForEach(SelectionCombineMode.allCases,id:\.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).frame(width:240).accessibilityIdentifier("selection.mode")
            Toggle("可见合成",isOn:$model.imageSelectionSettings.sampleAllLayers).fixedSize().accessibilityIdentifier("selection.sampleAll")
            if model.tool == .magicWand {
                Text("容差 \(model.imageSelectionSettings.tolerance)").monospacedDigit()
                Slider(value:Binding(get:{Double(model.imageSelectionSettings.tolerance)},set:{model.imageSelectionSettings.tolerance=Int($0.rounded())}),in:0...255,step:1)
                    .frame(width:160).accessibilityIdentifier("wand.tolerance")
                Picker("取样",selection:$model.imageSelectionSettings.sampleRadius) {
                    Text("单点").tag(0);Text("3 × 3").tag(1);Text("5 × 5").tag(2)
                }.frame(width:130).accessibilityIdentifier("wand.sampleRadius")
                Toggle("连续",isOn:$model.imageSelectionSettings.contiguous).fixedSize().accessibilityIdentifier("wand.contiguous")
            } else {
                Text("点按前景对象，或")
                Button("选取全部主体") { model.selectImage(kind:.subject) }
                    .disabled(model.imageSelectionBusy).accessibilityIdentifier("selection.subject")
            }
            if model.imageSelectionBusy {
                ProgressView();Text("计算选区中…")
                Button("取消") { model.cancelImageSelection() }.accessibilityIdentifier("selection.cancelDetection")
            }
        }.font(.caption)
    }
}

struct SelectionResizeContext: Identifiable {
    let id = UUID()
    let documentID: UUID
    let revision: Int64
}

struct SelectionResizeSheet: View {
    @ObservedObject var model:EditorModel
    @Environment(\.dismiss) private var dismiss
    let documentID:UUID
    let revision:Int64
    @State private var amount = 10.0
    @State private var expand = true
    var body:some View {
        NavigationStack {
            Form {
                Picker("操作",selection:$expand) { Text("扩展").tag(true);Text("收缩").tag(false) }.pickerStyle(.segmented)
                Text("\(Int(amount)) 像素").monospacedDigit().accessibilityIdentifier("selection.resizeAmount")
                Slider(value:$amount,in:0...100,step:1).accessibilityIdentifier("selection.resizeRadius")
                Text("在数值灰度选区上作方形邻域扩缩；软边灰度保留，画布外视为未选中。收缩至空仍保护全部像素。")
                    .font(.caption).foregroundStyle(.secondary)
            }.navigationTitle("选区扩缩")
                .toolbar {
                    ToolbarItem(placement:.cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement:.confirmationAction) { Button("完成") {
                        model.resizeSelection(amount:Int(amount)*(expand ? 1 : -1),documentID:documentID,revision:revision);dismiss()
                    }.accessibilityIdentifier("selection.resizeApply") }
                }
        }.presentationDetents([.medium,.large])
    }
}
