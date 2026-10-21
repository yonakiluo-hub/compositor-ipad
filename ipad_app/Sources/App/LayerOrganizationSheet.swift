import SwiftUI

struct LayerOrganizationSheet: View {
    @ObservedObject var model: EditorModel
    let context: LayerOrganizationContext
    @Environment(\.dismiss) private var dismiss
    @State private var operation = 0
    @State private var parentID: UUID?
    @State private var placement = 0
    @State private var anchorID: UUID?

    init(model: EditorModel, context: LayerOrganizationContext) {
        self.model = model; self.context = context
        _parentID = State(initialValue: model.activeLayer?.parentID)
    }

    private var action: LayerOrganizationAction? {
        if operation == 1 { return .group }
        if operation == 2 { return .moveOut }
        let position: LayerInsertionPosition
        if placement == 1 { position = .bottom }
        else if placement == 2 || placement == 3 {
            guard let anchorID else { return nil }
            position = placement == 2 ? .above(anchorID) : .below(anchorID)
        }
        else { position = .top }
        return .move(parentID: parentID, position: position)
    }
    private var issue: String? {
        guard let action else { return "请选择目标组内的同级项目。" }
        do { _ = try model.layerOrganizationPlan(context, action: action); return nil }
        catch { return error.localizedDescription }
    }
    private var anchors: [RasterLayer] {
        model.document.layers.filter { $0.parentID == parentID && !context.selectedIDs.contains($0.id) }.reversed()
    }
    private func label(_ layer: RasterLayer) -> String {
        let siblings = model.document.layers.filter { $0.parentID == layer.parentID }
        guard siblings.filter({ $0.name == layer.name }).count > 1,
              let index = siblings.firstIndex(where: { $0.id == layer.id }) else { return layer.name }
        return "\(layer.name)（自下数第 \(index + 1) 项）"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("已选 \(context.selectedIDs.count) 项；选中组会携带全部子层，重复选中的后代只处理一次。")
                        .font(.caption).foregroundStyle(.secondary)
                    Picker("操作", selection: $operation) {
                        Text("移动").tag(0); Text("成组").tag(1); Text("移出组").tag(2)
                    }.pickerStyle(.segmented).accessibilityIdentifier("organization.operation")
                }
                if operation == 0 {
                    Section("移动到") {
                        Picker("目标组", selection: $parentID) {
                            Text("画稿顶层").tag(nil as UUID?)
                            ForEach(model.document.hierarchy.filter { $0.layer.isGroup }, id: \.layer.id) { entry in
                                Text(String(repeating: "　", count: entry.depth) + label(entry.layer)).tag(Optional(entry.layer.id))
                            }
                        }.accessibilityIdentifier("organization.parent")
                        Picker("插入位置", selection: $placement) {
                            Text("最上方").tag(0); Text("最下方").tag(1)
                            Text("指定项目上方").tag(2); Text("指定项目下方").tag(3)
                        }.accessibilityIdentifier("organization.position")
                        if placement >= 2 {
                            Picker("同级项目", selection: $anchorID) {
                                Text("请选择").tag(nil as UUID?)
                                ForEach(anchors) { layer in Text(label(layer)).tag(Optional(layer.id)) }
                            }.accessibilityIdentifier("organization.anchor")
                        }
                    }
                }
                Section {
                    if operation == 1 {
                        Text("把同一父组内连续的项目放入新穿透组，保留原来的同级位置。")
                    } else if operation == 2 {
                        Text("把同一父组内的所选项目移至父组上方，空组保留。")
                    }
                    Text("原像素、蒙版和剪贴关系保留。移动会改变叠放次序；跨组后继承新上级的可见性与不透明度，画面可能改变。")
                        .accessibilityIdentifier("organization.appearanceNotice")
                    Text("隐藏项目可整理；锁定项目及含锁定子层的组需先解锁。剪贴基底和全部剪贴层须一起选择。")
                    if let issue {
                        Text(issue).foregroundStyle(.orange).accessibilityIdentifier("organization.issue")
                    }
                }.font(.caption)
            }
            .navigationTitle("整理图层")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.accessibilityIdentifier("organization.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") { if let action, model.organizeLayers(context, action: action) { dismiss() } }
                        .disabled(issue != nil).accessibilityIdentifier("organization.apply")
                }
            }
            .onChange(of: parentID) { _, _ in anchorID = nil }
        }
    }
}
