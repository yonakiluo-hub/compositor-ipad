import SwiftUI

struct QuadWarpControls:View {
    @ObservedObject var model:EditorModel
    let session:QuadWarpSession
    @State private var point=0
    @State private var xText=""
    @State private var yText=""
    private enum CoordinateAxis:Hashable {case x,y}
    @FocusState private var coordinateFocus:CoordinateAxis?
    private var coordinateRange:ClosedRange<Double> {
        let values=session.plan.original.flatMap{[Double($0.x),Double($0.y)]}
        let span=Double(max(model.document.width,model.document.height))
        return max(-1_000_000,min(-span,(values.min() ?? 0)-span))...min(1_000_000,max(2*span,(values.max() ?? span)+span))
    }
    private func coordinate(_ horizontal:Bool)->Binding<Double> {
        // Use a normalized control value so accessibility and the visible thumb
        // agree even when the document-coordinate range includes negative values.
        let range=coordinateRange,span=range.upperBound-range.lowerBound
        return Binding(get:{
            let value=Double(horizontal ? session.corners[point].x:session.corners[point].y)
            return (value-range.lowerBound)/span
        },set:{position in
            let value=range.lowerBound+position*span
            let old=session.corners[point]
            let new=CGPoint(x:horizontal ? CGFloat(value):old.x,y:horizontal ? old.y:CGFloat(value))
            if let next=QuadWarpGesture(corners:session.corners,corner:point,start:old,mode:session.mode).updated(to:new) {
                model.updateQuadWarp(next,sessionID:session.id)
            } else if model.quadWarpSession?.id == session.id {
                model.quadWarpError="四角不能交叉、折叠或重合。"
            }
        })
    }
    private func syncCoordinateText(_ corners:[CGPoint]) {
        xText=String(Double(corners[point].x));yText=String(Double(corners[point].y))
    }
    private var coordinateDraft: (corners:[CGPoint]?,error:String?) {
        guard let x=Double(xText.trimmingCharacters(in:.whitespacesAndNewlines)),
              let y=Double(yText.trimmingCharacters(in:.whitespacesAndNewlines)),x.isFinite,y.isFinite else {
            return (nil,"请输入有限的 X/Y 数值，可使用负号和小数点。")
        }
        guard abs(x)<=1_000_000,abs(y)<=1_000_000 else {
            return (nil,"坐标范围为 −1000000 到 1000000 像素。")
        }
        guard let next=QuadWarpGesture(corners:session.corners,corner:point,start:session.corners[point],mode:session.mode)
            .updated(to:CGPoint(x:x,y:y)) else {
            return (nil,"四角不能交叉、折叠或重合。")
        }
        return (next,nil)
    }
    private var hasCoordinateDraft:Bool {
        Double(xText.trimmingCharacters(in:.whitespacesAndNewlines)) != Double(session.corners[point].x)
            || Double(yText.trimmingCharacters(in:.whitespacesAndNewlines)) != Double(session.corners[point].y)
    }
    private func applyCoordinates() {
        guard let corners=coordinateDraft.corners,model.updateQuadWarp(corners,sessionID:session.id) else {return}
        coordinateFocus=nil;syncCoordinateText(corners)
    }
    private func coordinateField(_ horizontal:Bool)->some View {
        // Keep text drafts across asynchronous preview updates. Coordinates apply
        // explicitly as a pair, so a prefix of invalid input cannot become a warp.
        TextField(horizontal ? "X 坐标":"Y 坐标",text:horizontal ? $xText:$yText)
            .textFieldStyle(.roundedBorder).keyboardType(.numbersAndPunctuation)
            .autocorrectionDisabled().textInputAutocapitalization(.never)
            .focused($coordinateFocus,equals:horizontal ? .x:.y)
            .onSubmit {applyCoordinates()}
            .frame(width:82).monospacedDigit()
            .accessibilityLabel(horizontal ? "X 精确坐标":"Y 精确坐标")
            .accessibilityIdentifier(horizontal ? "warp.coordinate.x":"warp.coordinate.y")
    }
    var body:some View {
        VStack(alignment:.leading,spacing:7) {
            HStack(spacing:14) {
                Picker("模式",selection:Binding(get:{session.mode},set:{model.setQuadWarpMode($0)})) {
                    ForEach(QuadWarpMode.allCases,id:\.self) {Text($0.title).tag($0)}
                }.pickerStyle(.segmented).frame(width:240).accessibilityIdentifier("warp.mode")
                Spacer()
                Button("重置四角") {
                    coordinateFocus=nil;syncCoordinateText(session.plan.original)
                    model.updateQuadWarp(session.plan.original,sessionID:session.id)
                }.accessibilityIdentifier("warp.reset")
                if model.quadWarpPending {ProgressView().accessibilityIdentifier("warp.pending")}
                Button("取消") {model.cancelQuadWarp()}.accessibilityIdentifier("warp.cancel")
                Button("完成") {model.commitQuadWarp(sessionID:session.id)}
                    .disabled(hasCoordinateDraft || coordinateDraft.error != nil || model.quadWarpPending || model.quadWarpError != nil || (session.hasChanges && session.result == nil)).accessibilityIdentifier("warp.commit")
            }
            HStack(spacing:14) {
                Button("控制点 \(point+1)/4") {
                    coordinateFocus=nil;point=(point+1)%4;syncCoordinateText(session.corners)
                }.accessibilityIdentifier("warp.nextPoint")
                Text("X");Slider(value:coordinate(true),in:0...1).accessibilityLabel("X 坐标").accessibilityIdentifier("warp.x");coordinateField(true)
                Text("Y");Slider(value:coordinate(false),in:0...1).accessibilityLabel("Y 坐标").accessibilityIdentifier("warp.y");coordinateField(false)
                Button("应用坐标") {applyCoordinates()}
                    .disabled(coordinateDraft.error != nil || !hasCoordinateDraft).accessibilityIdentifier("warp.coordinate.apply")
            }.font(.caption)
            Text(session.plan.selected ? "选中像素 · 图层蒙版保持原位":"整个图层 · 链接蒙版随动")
                .font(.caption).accessibilityIdentifier("warp.scope")
            Text(session.mode == .perspective
                 ? "透视：拖动角点对称收拢同边；框内移动。完成会重采样像素，取消或撤销恢复原层。"
                 : "扭曲：独立拖动四角；框内移动。仅支持凸四边形，交叉/折叠明确拒绝；完成会重采样像素。")
                .font(.caption).foregroundStyle(.secondary)
            if let error=coordinateDraft.error {Text(error).font(.caption).foregroundStyle(.red).accessibilityIdentifier("warp.coordinate.error")}
            if let error=model.quadWarpError {Text(error).font(.caption).foregroundStyle(.red).accessibilityIdentifier("warp.error")}
            Text(session.corners.map{String(format:"%.1f,%.1f",Double($0.x),Double($0.y))}.joined(separator:" · "))
                .font(.caption2).monospacedDigit().accessibilityIdentifier("warp.geometry")
        }.padding(.horizontal,20).padding(.vertical,10)
            .onAppear {syncCoordinateText(session.corners)}
            .onChange(of:session.corners) {_,corners in syncCoordinateText(corners)}
    }
}
