import SwiftUI
import UIKit

struct CanvasView: UIViewRepresentable {
    @ObservedObject var model: EditorModel
    func makeUIView(context: Context) -> PadCanvasView { PadCanvasView(model: model) }
    func updateUIView(_ view: PadCanvasView, context: Context) { view.update() }
}

final class PadCanvasView: UIView, UIGestureRecognizerDelegate {
    let model: EditorModel
    var viewport = CanvasViewport()
    private var resetToken = -1
    private var rotationResetToken = -1
    private var panGesture: UIPanGestureRecognizer!
    private var transformDrag: FreeTransformGesture?
    private var quadDrag:QuadWarpGesture?
    private var quadSessionID:UUID?
    private var quadInputID=UUID()
    private var quadLastCorners:[CGPoint]?
    private var transformSessionID: UUID?
    private var transformInputID = UUID()
    private var isUpdatingView = false
    private var stroke: PadBrushStroke?
    private var maskStrokeSession: LayerMaskStrokeSession?
    private var strokeEditTarget: LayerEditTarget = .pixels
    private var strokeImage: CGImage?
    private var strokeLayer: RasterLayer?
    private var strokeRevision: Int64 = 0
    private var strokeDocumentID: UUID?
    private var gestureTool: PadTool = .brush
    private var startPoint: CGPoint?
    private var selectionDraft: SelectionGestureDraft?
    private var selectionCommandID: UUID?
    private var moveDelta = CGPoint.zero
    private var inputTouch: UITouch?

    init(model: EditorModel) {
        self.model = model; super.init(frame: .zero)
        isMultipleTouchEnabled = true; isOpaque = true
        backgroundColor = UIColor(red: 0.10, green: 0.12, blue: 0.15, alpha: 1)
        isAccessibilityElement = true
        accessibilityIdentifier = "editor.canvas"
        accessibilityLabel = "绘画画布"
        panGesture = UIPanGestureRecognizer(target: self, action: #selector(pan(_:)))
        panGesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        panGesture.delegate = self; addGestureRecognizer(panGesture)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinch(_:)))
        pinch.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        pinch.delegate = self; addGestureRecognizer(pinch)
        let rotation = UIRotationGestureRecognizer(target: self, action: #selector(rotateView(_:)))
        rotation.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        rotation.delegate = self; addGestureRecognizer(rotation)
        let undo = UITapGestureRecognizer(target: self, action: #selector(undoTap))
        undo.numberOfTouchesRequired = 2; undo.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        addGestureRecognizer(undo)
        let redo = UITapGestureRecognizer(target: self, action: #selector(redoTap))
        redo.numberOfTouchesRequired = 3; redo.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        addGestureRecognizer(redo)
        selectionCommandID = model.selectionGestureCommand?.id
        NotificationCenter.default.addObserver(self, selector: #selector(backgrounded), name: UIApplication.willResignActiveNotification, object: nil)
    }
    deinit { NotificationCenter.default.removeObserver(self) }
    required init?(coder: NSCoder) { fatalError("Use init(model:)") }
    private var inputIsCurrent: Bool {
        model.document.id == strokeDocumentID && model.document.revision == strokeRevision && model.tool == gestureTool
            && (strokeLayer == nil || model.document.activeLayerID == strokeLayer?.id)
            && model.layerEditTarget == strokeEditTarget
            && (maskStrokeSession?.isCurrent(in: model) ?? true)
            && (gestureTool.isSelection || strokeLayer == nil || model.selectedLayerIDs.count <= 1)
    }
    func update() {
        isUpdatingView = true
        defer { isUpdatingView = false }
        if transformDrag != nil && model.transformSession?.id != transformSessionID { cancelInput() }
        if quadDrag != nil && model.quadWarpSession?.id != quadSessionID {cancelInput()}
        if let selectionDraft, !selectionDraft.matches(documentID: model.document.id, revision: model.document.revision,
                                                       kind: selectionKind(model.tool)) { cancelInput() }
        if inputTouch != nil && !inputIsCurrent { cancelInput() }
        if let command = model.selectionGestureCommand, command.id != selectionCommandID {
            selectionCommandID = command.id
            let documentID = model.document.id, revision = model.document.revision, tool = model.tool
            DispatchQueue.main.async { [weak self] in
                guard let self, self.selectionCommandID == command.id, self.model.document.id == documentID,
                      self.model.document.revision == revision, self.model.tool == tool else { return }
                switch command.action {
                case .finish: self.finishSelectionDraft()
                case .undoPoint:
                    self.selectionDraft?.undoPoint()
                    if self.selectionDraft?.points.isEmpty == true { self.cancelInput() }
                    self.publishDraftCount(); self.setNeedsDisplay()
                case .cancel: self.cancelInput()
                }
            }
        }
        if model.viewportRotationReset != rotationResetToken {
            cancelInput(keepingPolygon: true)
            rotationResetToken = model.viewportRotationReset
            viewport.resetRotation(documentSize: model.document.size); publishViewRotation()
        }
        if model.viewportReset != resetToken {
            cancelInput(keepingPolygon: true)
            resetToken = model.viewportReset
            // Fit last: the initial rotation reset must not disable automatic
            // fitting when the device subsequently changes orientation.
            viewport.resetRotation(documentSize: model.document.size); viewport.fit(documentSize: model.document.size)
            publishViewRotation()
        }
        panGesture.minimumNumberOfTouches = model.tool.isTapSelection ? 1 : model.fingerDrawing || model.tool == .transform || model.tool == .quadWarp ? 2 : 1
        setNeedsDisplay()
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        viewport.resize(to: bounds.size, backingScale: window?.screen.scale ?? 2, documentSize: model.document.size)
        setNeedsDisplay()
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        !(inputTouch?.type == .pencil && touch.type == .direct)
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        let navigates: (UIGestureRecognizer) -> Bool = {
            $0 is UIPinchGestureRecognizer || $0 is UIRotationGestureRecognizer || $0 is UIPanGestureRecognizer
        }
        return navigates(gestureRecognizer) && navigates(other)
    }
    @objc private func pan(_ gesture: UIPanGestureRecognizer) {
        cancelInput(keepingPolygon: true)
        let delta = gesture.translation(in: self)
        viewport.translate(by: CGSize(width: delta.x, height: delta.y)); gesture.setTranslation(.zero, in: self); setNeedsDisplay()
    }
    @objc private func pinch(_ gesture: UIPinchGestureRecognizer) {
        cancelInput(keepingPolygon: true)
        viewport.setZoom(viewport.zoom * gesture.scale, anchoredAt: gesture.location(in: self), documentSize: model.document.size)
        gesture.scale = 1; setNeedsDisplay()
    }
    @objc private func rotateView(_ gesture: UIRotationGestureRecognizer) {
        cancelInput(keepingPolygon: true)
        viewport.setRotation(viewport.rotation + gesture.rotation, anchoredAt: gesture.location(in: self), documentSize: model.document.size)
        gesture.rotation = 0; publishViewRotation(); setNeedsDisplay()
    }
    private func publishViewRotation() {
        let degrees = Double(viewport.rotation * 180 / .pi)
        DispatchQueue.main.async { [weak self] in
            guard let self, abs(Double(self.viewport.rotation * 180 / .pi) - degrees) < 0.0001,
                  abs(self.model.viewportRotationDegrees - degrees) > 0.0001 else { return }
            self.model.viewportRotationDegrees = degrees
        }
    }
    @objc private func undoTap() { cancelInput(); model.undo() }
    @objc private func redoTap() { cancelInput(); model.redo() }
    @objc private func backgrounded() { cancelInput(); model.cancelTransform() }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        backgroundColor?.setFill(); context.fill(bounds)
        let canvas = CGRect(origin: .zero, size: model.document.size)
        let scale = max(0.0001, viewport.pointsPerPixel)
        context.saveGState()
        context.concatenate(viewport.documentToViewTransform(documentSize: model.document.size))
        context.clip(to: canvas)
        context.setFillColor(UIColor.white.cgColor); context.fill(canvas)
        let tile: CGFloat = 16 / scale
        if canvas.width / tile < 200, canvas.height / tile < 200 {
            context.setFillColor(UIColor(white: 0.94, alpha: 1).cgColor)
            for y in 0...Int(canvas.height / tile) { for x in 0...Int(canvas.width / tile) where (x + y) % 2 == 0 {
                context.fill(CGRect(x: canvas.minX + CGFloat(x) * tile, y: canvas.minY + CGFloat(y) * tile, width: tile, height: tile))
            } }
        }
        var image = model.colorAdjustmentSession.map { model.colorAdjustmentIsCurrent($0) } == true
            ? (model.colorAdjustmentPreview ?? model.preview) : model.preview
        if let session=model.quadWarpSession,model.quadWarpIsCurrent(session) {
            image=model.quadWarpPreview ?? model.preview
        } else if let session = model.transformSession {
            if let replacement = model.transformPreviewReplacement {
                image = try? model.renderer.render(model.transformPreviewDocument, replacing: session.layerID,
                    with: replacement.image, replacementMask: replacement.mask)
            } else {
                image = try? model.renderer.render(model.transformPreviewDocument)
            }
        } else if let session = maskStrokeSession, let strokeImage {
            image = try? model.renderer.render(model.document, replacing: session.layer.id,
                with: session.sourcePixels, replacementMask: strokeImage)
        } else if let strokeLayer, let strokeImage, !gestureTool.isSelection {
            image = try? model.renderer.render(model.document, replacing: strokeLayer.id, with: strokeImage)
        } else if let layer = strokeLayer, gestureTool == .move, startPoint != nil {
            var doc = model.document
            if let i = doc.layers.firstIndex(where: { $0.id == layer.id }) {
                doc.layers[i].transform.origin.x = layer.transform.origin.x + moveDelta.x
                doc.layers[i].transform.origin.y = layer.transform.origin.y + moveDelta.y
                image = try? model.renderer.render(doc)
            }
        }
        if let image { RasterImage.draw(image, in: canvas, context: context) }
        let selection = gestureTool.isSelection && strokeImage != nil ? strokeImage : model.displayedSelectionPreview
        if let selection {
            context.saveGState(); RasterImage.clip(selection, to: canvas, context: context)
            context.setFillColor(UIColor.systemTeal.withAlphaComponent(0.28).cgColor); context.fill(canvas); context.restoreGState()
        }
        if let draft = selectionDraft {
            context.setStrokeColor(UIColor.systemTeal.cgColor); context.setLineWidth(2 / scale); context.setLineDash(phase: 0, lengths: [6 / scale, 4 / scale])
            if (draft.kind == .rectangle || draft.kind == .ellipse), let rect = draft.rectangle {
                if draft.kind == .ellipse { context.strokeEllipse(in: rect) } else { context.stroke(rect) }
            } else {
                var points = draft.points
                if draft.kind == .polygonal, let cursor = draft.cursor { points.append(cursor) }
                let visible = points
                if visible.count > 1 { context.addLines(between: visible); context.strokePath() }
                if let first = visible.first, visible.count > 2 {
                    context.setStrokeColor(UIColor.systemTeal.withAlphaComponent(0.5).cgColor)
                    context.setLineDash(phase: 0, lengths: [3 / scale, 5 / scale]); context.move(to: visible.last!); context.addLine(to: first); context.strokePath()
                }
                if draft.kind == .polygonal {
                    context.setLineDash(phase: 0, lengths: []); context.setFillColor(UIColor.systemTeal.cgColor)
                    for point in draft.points {
                        context.fillEllipse(in: CGRect(x: point.x - 3 / scale, y: point.y - 3 / scale, width: 6 / scale, height: 6 / scale))
                    }
                    if let first = draft.points.first {
                        context.strokeEllipse(in: CGRect(x: first.x - 8 / scale, y: first.y - 8 / scale, width: 16 / scale, height: 16 / scale))
                    }
                }
            }
        }
        context.restoreGState()
        if let session=model.quadWarpSession,model.quadWarpIsCurrent(session) {
            QuadWarpOverlay(corners:session.corners,viewport:viewport,documentSize:model.document.size).draw(in:context)
        } else if let session = model.transformSession {
            TransformOverlayGeometry(transform: session.current, viewport: viewport, documentSize: model.document.size).draw(in: context)
        } else if model.tool == .move, let layer = model.activeLayer {
            var t = layer.transform
            if startPoint != nil { t.origin.x += moveDelta.x; t.origin.y += moveDelta.y }
            let corners = [CGPoint(x: 0,y: 0), CGPoint(x: 1,y: 0), CGPoint(x: 1,y: 1), CGPoint(x: 0,y: 1)]
                .map { viewport.viewPoint(from: t.point($0), documentSize: model.document.size) }
            context.setStrokeColor(UIColor.systemTeal.cgColor); context.setLineWidth(1.5)
            context.addLines(between: corners + [corners[0]]); context.strokePath()
        }
    }
    private func documentPoint(_ touch: UITouch) -> CGPoint {
        viewport.documentPoint(from: touch.location(in: self), documentSize: model.document.size)
    }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard inputTouch == nil, touches.count == 1, let touch = touches.first,
              touch.type == .pencil || model.fingerDrawing || model.tool == .transform || model.tool == .quadWarp || model.tool.isTapSelection else { return }
        if let draft = selectionDraft, !draft.matches(documentID: model.document.id, revision: model.document.revision, kind: selectionKind(model.tool)) { cancelInput() }
        inputTouch = touch; gestureTool = model.tool; strokeRevision = model.document.revision; strokeDocumentID = model.document.id
        strokeEditTarget = model.layerEditTarget
        let point = documentPoint(touch)
        if gestureTool == .quadWarp {
            guard let session=model.quadWarpSession,
                  let hit=QuadWarpOverlay(corners:session.corners,viewport:viewport,documentSize:model.document.size).hit(touch.location(in:self)) else {cancelInput();return}
            let corner:Int?
            switch hit {case .corner(let index):corner=index;case .translate:corner=nil}
            beginQuadDrag(corner:corner,start:point)
            return
        }
        if gestureTool == .transform {
            guard let session = model.transformSession,
                  let handle = TransformOverlayGeometry(transform: session.current, viewport: viewport, documentSize: model.document.size)
                    .hit(touch.location(in: self), documentPoint: point, transform: session.current) else { cancelInput(); return }
            beginTransformDrag(handle: handle, start: point)
            return
        }
        guard CGRect(origin: .zero, size: model.document.size).contains(point) else { cancelInput(keepingPolygon: true); return }
        startPoint = point
        if gestureTool.isTapSelection { return }
        do {
            if gestureTool == .eyedropper { sampleColor(point); return }
            if let kind = selectionKind(gestureTool) {
                if selectionDraft == nil {
                    selectionDraft = SelectionGestureDraft(kind: kind, at: point, documentID: model.document.id,
                        revision: model.document.revision, mode: model.selectionMode, feather: model.selectionFeather)
                }
                selectionDraft?.move(to: point); publishDraftCount(); setNeedsDisplay(); return
            }
            if gestureTool.isSelection {
                let original = try model.selectionPreview ?? RasterImage.solidMask(width: model.document.width, height: model.document.height, white: gestureTool == .maskErase)
                stroke = try PadBrushStroke(width: model.document.width, height: model.document.height, original: original,
                                            settings: model.brushSettings, selection: nil, maskMode: true)
            } else {
                guard model.selectedLayerIDs.count <= 1 else { throw DocumentError.invalid("请先选择一个图层，再绘画或移动") }
                guard let layer = model.activeLayer,
                      (!layer.isGroup && layer.adjustment == nil) || (model.layerEditTarget == .mask && [.brush, .eraser].contains(gestureTool))
                else { throw DocumentError.invalid("请选择普通图层，或切换到组蒙版绘画") }
                guard !model.document.isEffectivelyLocked(layer.id) else { throw DocumentError.lockedLayer }
                strokeLayer = layer
                if gestureTool == .move { return }
                if model.layerEditTarget == .mask {
                    let session = try LayerMaskStrokeSession(model: model)
                    maskStrokeSession = session; stroke = session.stroke
                } else {
                    let size = try model.renderer.pixelSize(of: layer)
                    stroke = try PadBrushStroke(width: Int(size.width), height: Int(size.height), original: model.renderer.image(for: layer),
                                                settings: model.brushSettings,
                                                selection: model.renderer.localSelection(model.selectionPreview, layer: layer, document: model.document), maskMode: false,
                                                brushToPixels: model.renderer.pixelToDocument(layer, size: size).inverted())
                }
            }
            add(touch, event: event)
        } catch { model.errorMessage = error.localizedDescription; cancelInput() }
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = inputTouch, touches.contains(touch), let startPoint else { return }
        guard inputIsCurrent else { cancelInput(); return }
        let point = documentPoint(touch)
        if gestureTool == .quadWarp {
            updateQuadDrag(to:point)
        } else if gestureTool == .transform {
            if let id = transformSessionID, let next = transformDrag?.updated(to: point) {
                if !model.previewTransform(next, sessionID: id) { cancelInput() }
            }
        } else if gestureTool == .move { moveDelta = CGPoint(x: point.x - startPoint.x, y: point.y - startPoint.y) }
        else if selectionKind(gestureTool) != nil {
            for sample in event?.coalescedTouches(for: touch) ?? [touch] { selectionDraft?.move(to: documentPoint(sample)) }
        } else if gestureTool == .eyedropper { sampleColor(point) }
        else { add(touch, event: event) }
        setNeedsDisplay()
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = inputTouch, touches.contains(touch) else { return }
        if gestureTool == .quadWarp {
            if inputIsCurrent {touchesMoved(touches,with:nil)}
            cancelInput(keepingTransformPreview:inputIsCurrent);return
        }
        if gestureTool.isTapSelection {
            let end = documentPoint(touch), start = startPoint, kind:ImageSelectionKind = gestureTool == .magicWand ? .wand : .object
            let valid = inputIsCurrent && start.map { hypot(end.x-$0.x,end.y-$0.y)*viewport.pointsPerPixel <= 12 } == true
            cancelInput()
            if valid { model.selectImage(at:end,kind:kind) }
            return
        }
        if gestureTool == .transform {
            if inputIsCurrent { touchesMoved(touches, with: nil) }
            cancelInput(keepingTransformPreview: inputIsCurrent)
            return
        }
        if selectionKind(gestureTool) != nil {
            guard inputIsCurrent, var draft = selectionDraft else { cancelInput(); return }
            let shape = draft.end(at: documentPoint(touch), closingDistance: 12 / max(0.0001, viewport.pointsPerPixel))
            selectionDraft = draft
            if draft.exceedsPointLimit {
                cancelInput()
                model.errorMessage = "套索路径过长，请分成几个选区后相加。"
                return
            }
            if let shape { commitSelection(shape, draft: draft) }
            else { cancelInput(keepingPolygon: draft.kind == .polygonal) }
            return
        }
        defer { cancelInput() }
        guard inputIsCurrent else { return }
        touchesMoved(touches, with: nil)
        do {
            if gestureTool == .move, let layer = strokeLayer {
                let delta = moveDelta
                model.updateLayer("移动图层") { $0.transform.origin = CGPoint(x: layer.transform.origin.x + delta.x, y: layer.transform.origin.y + delta.y) }
            } else if let stroke {
                add(touch, event: nil)
                if let session = maskStrokeSession {
                    _ = model.commitLayerMaskStroke(session)
                    return
                }
                let image = try stroke.image()
                if gestureTool.isSelection { model.commitSelection(image) } else { model.commitPixels(image) }
            }
        } catch { model.errorMessage = error.localizedDescription }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { cancelInput(keepingPolygon: true) }
    private func selectionKind(_ tool: PadTool) -> SelectionGestureDraft.Kind? {
        switch tool {
        case .lasso: .freehand
        case .polygonLasso: .polygonal
        case .rectangle: .rectangle
        case .ellipse: .ellipse
        default: nil
        }
    }
    private func finishSelectionDraft() {
        guard let draft = selectionDraft, draft.kind == .polygonal,
              draft.matches(documentID: model.document.id, revision: model.document.revision, kind: selectionKind(model.tool)),
              let shape = draft.finishedShape() else { return }
        commitSelection(shape, draft: draft)
    }
    private func commitSelection(_ shape: SelectionShape, draft: SelectionGestureDraft) {
        cancelInput()
        model.commitSelectionShape(shape, mode: draft.mode, feather: draft.feather, documentID: draft.documentID, revision: draft.revision)
    }
    private func publishDraftCount() {
        let count = selectionDraft?.points.count ?? 0
        // updateUIView may cancel a stale draft. Publish outside SwiftUI's update
        // pass, and ignore callbacks superseded by a later touch/cancellation.
        DispatchQueue.main.async { [weak self] in
            guard let self, (self.selectionDraft?.points.count ?? 0) == count,
                  self.model.selectionDraftPointCount != count else { return }
            self.model.selectionDraftPointCount = count
        }
    }
    private func add(_ touch: UITouch, event: UIEvent?) {
        guard let stroke else { return }
        for sample in event?.coalescedTouches(for: touch) ?? [touch] {
            var point = documentPoint(sample)
            if let layer = strokeLayer { point = point.applying(model.renderer.pixelToDocument(layer, size: stroke.size).inverted()) }
            let pressure = sample.type == .pencil && sample.maximumPossibleForce > 0 ? min(1, max(0.05, sample.force / sample.maximumPossibleForce)) : 1
            stroke.add(BrushSample(point: point, pressure: pressure, altitude: sample.type == .pencil ? sample.altitudeAngle : .pi / 2,
                                   azimuth: sample.type == .pencil ? sample.azimuthAngle(in: self) - viewport.rotation : 0))
        }
        do { strokeImage = try stroke.image(); setNeedsDisplay() } catch { model.errorMessage = error.localizedDescription; cancelInput() }
    }
    private func sampleColor(_ point: CGPoint) {
        guard let image = model.preview, point.x >= 0, point.y >= 0, point.x < CGFloat(image.width), point.y < CGFloat(image.height),
              let crop = image.cropping(to: CGRect(x: Int(point.x), y: Int(point.y), width: 1, height: 1)),
              let context = try? RasterImage.context(width: 1, height: 1) else { return }
        RasterImage.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1), context: context)
        if let bytes = context.data?.assumingMemoryBound(to: UInt8.self) {
            let alpha = CGFloat(bytes[3]); guard alpha > 0 else { return }
            model.color = Color(red: Double(CGFloat(bytes[0]) / alpha), green: Double(CGFloat(bytes[1]) / alpha), blue: Double(CGFloat(bytes[2]) / alpha))
        }
    }
    /// Start from the previous completed preview; cancelling this pointer must only undo this drag.
    func beginQuadDrag(corner:Int?,start:CGPoint) {
        guard let session=model.quadWarpSession else {return}
        quadDrag=QuadWarpGesture(corners:session.corners,corner:corner,start:start,mode:session.mode)
        quadSessionID=session.id;quadInputID=UUID();quadLastCorners=session.corners;startPoint=start
    }
    func updateQuadDrag(to point:CGPoint) {
        guard let id=quadSessionID,let drag=quadDrag,let session=model.quadWarpSession,
              session.id == id,model.quadWarpIsCurrent(session) else {return}
        guard let next=drag.updated(to:point) else {model.quadWarpError="四角不能交叉、折叠或重合。";return}
        if model.updateQuadWarp(next,sessionID:id) {quadLastCorners=next}
    }
    func beginTransformDrag(handle: TransformHandle, start: CGPoint) {
        guard let session = model.transformSession else { return }
        transformInputID = UUID()
        transformSessionID = session.id
        transformDrag = FreeTransformGesture(transform: session.current, handle: handle, start: start,
                                             lockAspect: model.transformAspectLocked || model.transformRequiresAspectLock)
        startPoint = start
    }

    func cancelInput(keepingPolygon: Bool = false, keepingTransformPreview: Bool = false) {
        let cancelledQuad=keepingTransformPreview ? nil:quadDrag,quadID=quadSessionID,quadInput=quadInputID,lastQuad=quadLastCorners
        let cancelledDrag = keepingTransformPreview ? nil : transformDrag
        let cancelledSessionID = transformSessionID
        let cancelledInputID = transformInputID
        let cancelledPreview = model.transformSession?.current
        if keepingPolygon, selectionDraft?.kind == .polygonal, selectionDraft?.points.isEmpty == false {
            selectionDraft?.cancelPointer()
        } else { selectionDraft = nil }
        stroke = nil; maskStrokeSession = nil; strokeLayer = nil; strokeImage = nil; startPoint = nil
        inputTouch = nil; strokeDocumentID = nil; moveDelta = .zero; setNeedsDisplay()
        transformDrag = nil; transformSessionID = nil
        quadDrag=nil;quadSessionID=nil;quadLastCorners=nil
        publishDraftCount()
        if let cancelledQuad,let quadID,let lastQuad,lastQuad != cancelledQuad.corners {
            let restore={ [weak self] in
                guard let self,self.quadInputID == quadInput,self.model.quadWarpSession?.id == quadID,
                      self.model.quadWarpSession?.corners == lastQuad else {return}
                _ = self.model.updateQuadWarp(cancelledQuad.corners,sessionID:quadID)
            }
            if isUpdatingView {DispatchQueue.main.async(execute:restore)} else {restore()}
        }
        guard let cancelledDrag, let cancelledSessionID, let cancelledPreview,
              cancelledPreview != cancelledDrag.original else { return }
        let restorePreview = { [weak self] in
            guard let self, self.transformInputID == cancelledInputID,
                  self.model.transformSession?.id == cancelledSessionID,
                  self.model.transformSession?.current == cancelledPreview else { return }
            _ = self.model.previewTransform(cancelledDrag.original, sessionID: cancelledSessionID)
        }
        // updateUIView must not publish synchronously. A later session, preview or pointer owns
        // its state, so a queued cancellation checks all three before restoring anything.
        if isUpdatingView { DispatchQueue.main.async(execute: restorePreview) }
        else { restorePreview() }
    }
}
