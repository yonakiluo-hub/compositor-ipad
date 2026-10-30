import XCTest
import UIKit
@testable import CompositorPad

final class QuadWarpWorkflowTests:XCTestCase {
    @MainActor private func fixture() throws -> EditorModel {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("quad-warp-"+UUID().uuidString),suite="quad-warp-"+UUID().uuidString
        let docs=root.appendingPathComponent("Documents");try FileManager.default.createDirectory(at:docs,withIntermediateDirectories:true)
        let m=EditorModel(documentsURL:docs,supportURL:root.appendingPathComponent("Support"),preferences:try XCTUnwrap(UserDefaults(suiteName:suite)),loadPairing:false)
        m.create(name:"四角测试",width:24,height:18);m.color = .red;m.fill();m.saveNow()
        addTeardownBlock {try? FileManager.default.removeItem(at:root);UserDefaults.standard.removePersistentDomain(forName:suite)}
        return m
    }
    @MainActor private func finish(_ m:EditorModel) async {while let worker=m.quadWarpTask {await worker.value}}
    private func bytes(_ image:CGImage)throws->[UInt8] {try NumericSelectionRaster.rgba(image)}
    @MainActor func testPreviewUsesFormalSnapshotCommitsOnceAndReopens() async throws {
        let m=try fixture(),before=m.document,count=m.editor.undoCount
        XCTAssertTrue(m.beginQuadWarp(.distort));let session=try XCTUnwrap(m.quadWarpSession)
        for amount in 1...5 {
            var corners=session.plan.original;corners[0].x+=CGFloat(amount);corners[0].y+=1
            XCTAssertTrue(m.updateQuadWarp(corners,sessionID:session.id))
        }
        await finish(m);XCTAssertNil(m.quadWarpError);XCTAssertEqual(m.document,before);XCTAssertEqual(m.editor.undoCount,count)
        let preview=try bytes(XCTUnwrap(m.quadWarpPreview));m.saveNow()
        XCTAssertEqual(try DocumentStore.load(from:m.documentURL),before)
        XCTAssertTrue(m.commitQuadWarp(sessionID:session.id));XCTAssertEqual(m.editor.undoCount,count+1)
        XCTAssertEqual(m.document.layers[0].id,before.layers[0].id);XCTAssertNotEqual(m.document.layers[0].pngData,before.layers[0].pngData)
        XCTAssertEqual(try bytes(m.renderer.render(m.document)),preview)
        let done=m.document.layers;m.undo();XCTAssertEqual(m.document.layers,before.layers)
        m.redo();XCTAssertEqual(m.document.layers,done)
        m.saveNow();XCTAssertEqual(try DocumentStore.load(from:m.documentURL),m.document)
    }
    @MainActor func testCancelResetIdentityAndRejectedFoldKeepRedo() async throws {
        let m=try fixture();m.updateLayer("暂改"){$0.opacity=0.5};m.undo()
        let before=m.document;XCTAssertTrue(m.editor.canRedo)
        XCTAssertTrue(m.beginQuadWarp(.perspective));let identity=try XCTUnwrap(m.quadWarpSession)
        XCTAssertTrue(m.commitQuadWarp(sessionID:identity.id));XCTAssertEqual(m.document,before);XCTAssertTrue(m.editor.canRedo)
        XCTAssertTrue(m.beginQuadWarp(.distort));let session=try XCTUnwrap(m.quadWarpSession)
        var corners=session.corners;corners[0].x+=3
        XCTAssertTrue(m.updateQuadWarp(corners,sessionID:session.id));await finish(m)
        let folded=[corners[0],corners[2],corners[1],corners[3]]
        XCTAssertFalse(m.updateQuadWarp(folded,sessionID:session.id));XCTAssertNotNil(m.quadWarpError)
        XCTAssertEqual(m.document,before)
        XCTAssertTrue(m.updateQuadWarp(session.plan.original,sessionID:session.id))
        XCTAssertTrue(m.commitQuadWarp(sessionID:session.id));XCTAssertTrue(m.editor.canRedo)
        XCTAssertEqual(m.document,before)
    }
    @MainActor func testOldWorkerAndOldSessionCannotOverwriteNewSourceOrTool() async throws {
        let m=try fixture();XCTAssertTrue(m.beginQuadWarp(.distort));let first=try XCTUnwrap(m.quadWarpSession)
        var old=first.corners;old[0].x+=3;XCTAssertTrue(m.updateQuadWarp(old,sessionID:first.id))
        m.cancelQuadWarp();XCTAssertTrue(m.beginQuadWarp(.distort));let second=try XCTUnwrap(m.quadWarpSession)
        var new=second.corners;new[1].y+=2;XCTAssertTrue(m.updateQuadWarp(new,sessionID:second.id))
        XCTAssertFalse(m.updateQuadWarp(old,sessionID:first.id));XCTAssertFalse(m.commitQuadWarp(sessionID:first.id))
        await finish(m);XCTAssertEqual(m.quadWarpSession?.corners,new);XCTAssertNotNil(m.quadWarpSession?.result)
        m.updateLayer("改变源"){$0.opacity=0.7};let changed=m.document
        XCTAssertFalse(m.commitQuadWarp(sessionID:second.id));await finish(m);XCTAssertEqual(m.document,changed)
        XCTAssertTrue(m.beginQuadWarp(.distort));let third=try XCTUnwrap(m.quadWarpSession)
        XCTAssertTrue(m.updateQuadWarp(new,sessionID:third.id));m.tool = .brush;await finish(m)
        XCTAssertNil(m.quadWarpSession);XCTAssertEqual(m.document,changed)
    }
    @MainActor func testSelectionMovesCoverageOnceAndMaskStaysFixedAcrossUndoAndSave() async throws {
        let m=try fixture()
        let mask=try NumericSelectionRaster.grayImage((0..<432).map{$0%24<12 ? 64:192},width:24,height:18)
        let selection=try NumericSelectionRaster.grayImage((0..<432).map{let x=$0%24,y=$0/24;return (4..<14).contains(x) && (4..<12).contains(y) ? 128:0},width:24,height:18)
        m.updateLayer("蒙版"){$0.maskPNGData=try? RasterImage.png(mask);$0.maskEnabled=false}
        m.commitSelection(selection);let before=m.document,count=m.editor.undoCount
        XCTAssertTrue(m.beginQuadWarp(.distort));let session=try XCTUnwrap(m.quadWarpSession)
        XCTAssertTrue(session.plan.selected)
        XCTAssertTrue(m.updateQuadWarp(session.corners.map{CGPoint(x:$0.x+2,y:$0.y)},sessionID:session.id));await finish(m)
        XCTAssertTrue(m.commitQuadWarp(sessionID:session.id));XCTAssertEqual(m.editor.undoCount,count+1)
        XCTAssertFalse(try XCTUnwrap(m.activeLayer).maskEnabled)
        XCTAssertEqual(try NumericSelectionRaster.gray(RasterImage.decode(XCTUnwrap(m.activeLayer?.maskPNGData))),try NumericSelectionRaster.gray(mask))
        let moved=try NumericSelectionRaster.gray(XCTUnwrap(m.selectionPreview));XCTAssertEqual(moved[6*24+8],128)
        m.saveNow();XCTAssertEqual(try DocumentStore.load(from:m.documentURL),m.document)
        m.undo();XCTAssertEqual(m.document.layers,before.layers);XCTAssertEqual(m.document.selectionMaskPNGData,before.selectionMaskPNGData)
    }
    @MainActor func testInterruptedPointerRestoresOnlyItsOwnPreview() async throws {
        let m=try fixture();XCTAssertTrue(m.beginQuadWarp(.distort));let session=try XCTUnwrap(m.quadWarpSession)
        let view=PadCanvasView(model:m),start=session.corners[0]
        view.beginQuadDrag(corner:0,start:start);view.updateQuadDrag(to:CGPoint(x:start.x+2,y:start.y+1))
        let valid=m.quadWarpSession?.corners
        view.updateQuadDrag(to:CGPoint(x:100,y:100));XCTAssertNotNil(m.quadWarpError);XCTAssertEqual(m.quadWarpSession?.corners,valid)
        view.cancelInput()
        XCTAssertEqual(m.quadWarpSession?.corners,session.corners);await finish(m)
        view.beginQuadDrag(corner:0,start:start);view.updateQuadDrag(to:CGPoint(x:start.x+3,y:start.y+1))
        var external=session.corners;external[1].y+=2
        XCTAssertTrue(m.updateQuadWarp(external,sessionID:session.id));view.cancelInput()
        XCTAssertEqual(m.quadWarpSession?.corners,external);await finish(m)
        view.beginQuadDrag(corner:0,start:external[0]);view.updateQuadDrag(to:CGPoint(x:external[0].x+1,y:external[0].y))
        m.cancelQuadWarp();XCTAssertTrue(m.beginQuadWarp(.distort));let next=try XCTUnwrap(m.quadWarpSession)
        view.cancelInput();XCTAssertEqual(m.quadWarpSession?.id,next.id);XCTAssertEqual(m.quadWarpSession?.corners,next.plan.original)
        m.cancelQuadWarp();await finish(m)
    }
    @MainActor func testLockedGroupAndMultiSelectionRejectWithoutHistory() throws {
        let m=try fixture(),count=m.editor.undoCount
        m.selectedLayerIDs.insert(UUID());XCTAssertFalse(m.beginQuadWarp(.distort));XCTAssertEqual(m.editor.undoCount,count)
        m.selectedLayerIDs=[try XCTUnwrap(m.activeLayer).id]
        m.updateLayer("锁定"){$0.isLocked=true};let locked=m.document
        XCTAssertFalse(m.beginQuadWarp(.perspective));XCTAssertEqual(m.document,locked)
        m.addLayer(group:true);let grouped=m.document
        XCTAssertTrue(try XCTUnwrap(m.activeLayer).isGroup)
        XCTAssertFalse(m.beginQuadWarp(.distort));XCTAssertEqual(m.document,grouped)
    }
}
