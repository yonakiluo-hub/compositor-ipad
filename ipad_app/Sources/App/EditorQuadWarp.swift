import Foundation
import CoreGraphics

struct QuadWarpSession:Identifiable,Sendable {
    let id=UUID()
    let plan:LayerWarpSource
    let selectedIDs:Set<UUID>
    var mode:QuadWarpMode
    var corners:[CGPoint]
    var result:QuadWarpResult?
    var hasChanges:Bool {corners != plan.original}
}

extension EditorModel {
    func quadWarpIsCurrent(_ session:QuadWarpSession) -> Bool {
        document == session.plan.source && selectedLayerIDs == session.selectedIDs && tool == .quadWarp && layerEditTarget == .pixels
    }
    @discardableResult
    func beginQuadWarp(_ mode:QuadWarpMode) -> Bool {
        cancelTransform();layerEditTarget = .pixels
        do {
            let plan=try LayerWarpSource(document:document,selectedIDs:selectedLayerIDs,renderer:renderer)
            tool = .quadWarp
            quadWarpSession=QuadWarpSession(plan:plan,selectedIDs:selectedLayerIDs,mode:mode,corners:plan.original)
            quadWarpPreview=preview;quadWarpError=nil;quadWarpPending=false
            return true
        } catch {errorMessage=error.localizedDescription;return false}
    }
    @discardableResult
    func updateQuadWarp(_ corners:[CGPoint],sessionID:UUID) -> Bool {
        guard var session=quadWarpSession,session.id == sessionID else {return false}
        guard quadWarpIsCurrent(session) else {cancelQuadWarp();return false}
        do {_=try QuadWarp(source:CGRect(x:0,y:0,width:1,height:1),corners:corners).bounds()}
        catch {quadWarpError=error.localizedDescription;return false}
        guard corners != session.corners else {
            if !session.hasChanges || session.result != nil {quadWarpError=nil}
            return true
        }
        session.corners=corners;session.result=nil;quadWarpSession=session
        quadWarpRequest=UUID();quadWarpError=nil
        if !session.hasChanges {quadWarpPreview=preview;quadWarpPending=false;return true}
        quadWarpPending=true;renderQuadWarp()
        return true
    }
    func setQuadWarpMode(_ mode:QuadWarpMode) {
        guard var session=quadWarpSession,quadWarpIsCurrent(session),session.mode != mode else {return}
        session.mode=mode;quadWarpSession=session
    }
    private func renderQuadWarp() {
        guard quadWarpTask == nil,let session=quadWarpSession,quadWarpIsCurrent(session),quadWarpPending else {return}
        let request=quadWarpRequest
        quadWarpTask=Task { [weak self] in
            let result=await DocumentPreviewQueue.shared.perform { () throws -> (QuadWarpResult,DocumentPreviewImage) in
                    let replacement=try session.plan.preview(session.corners)
                    var candidate=session.plan.source
                    guard let index=candidate.layers.firstIndex(where:{$0.id == session.plan.layer.id}) else {throw DocumentError.missingLayer}
                    candidate.layers[index].transform=replacement.transform
                    let preview=try DocumentRenderer().render(candidate,replacing:session.plan.layer.id,
                        with:replacement.image,replacementMask:replacement.mask)
                    return (replacement,DocumentPreviewImage(image:preview))
            }
            guard let self else {return}
            self.quadWarpTask=nil
            guard var current=self.quadWarpSession,self.quadWarpIsCurrent(current) else {return}
            guard current.id == session.id,request == self.quadWarpRequest else {
                if self.quadWarpPending {self.renderQuadWarp()};return
            }
            self.quadWarpPending=false
            switch result {
            case .success(let value):current.result=value.0;self.quadWarpSession=current;self.quadWarpPreview=value.1.image
            case .failure(let error):self.quadWarpError=error.localizedDescription
            }
        }
    }
    @discardableResult
    func commitQuadWarp(sessionID:UUID) -> Bool {
        guard let session=quadWarpSession,session.id == sessionID else {return false}
        guard quadWarpIsCurrent(session) else {cancelQuadWarp();errorMessage="文稿已改变，请重新打开四角变换。";return false}
        guard !quadWarpPending else {return false}
        guard session.hasChanges else {cancelQuadWarp();return true}
        guard let result=session.result,quadWarpError == nil else {return false}
        do {
            var candidate=session.plan.source
            guard let index=candidate.layers.firstIndex(where:{$0.id == session.plan.layer.id}) else {throw DocumentError.missingLayer}
            candidate.layers[index].pngData=try RasterImage.png(result.image)
            candidate.layers[index].transform=result.transform
            candidate.layers[index].maskPNGData=try result.mask.map(RasterImage.png)
            if let selection=result.selection {candidate.selectionMaskPNGData=try RasterImage.png(selection)}
            try candidate.validate();_=try DocumentRenderer().render(candidate)
            try editor.transaction(session.mode.title) { document in
                guard document == session.plan.source else {throw DocumentError.staleRevision}
                document=candidate
            }
            cancelQuadWarp();changed();return true
        } catch {quadWarpError=error.localizedDescription;return false}
    }
    func cancelQuadWarp() {
        guard quadWarpSession != nil || quadWarpPreview != nil || quadWarpPending || quadWarpError != nil else {return}
        quadWarpSession=nil;quadWarpPreview=nil;quadWarpPending=false;quadWarpError=nil;quadWarpRequest=UUID()
        if tool == .quadWarp {tool = .move}
        // A superseded worker finishes without publishing. Keep its handle so
        // cancel/reopen cannot start overlapping full-size warp allocations.
        quadWarpTask?.cancel()
    }
}
