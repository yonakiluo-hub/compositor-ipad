import XCTest
import UIKit
@testable import CompositorPad

final class BatchTransformWorkflowTests: XCTestCase {
    @MainActor private func fixture() throws -> EditorModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("batch-transform-"+UUID().uuidString)
        let docs = root.appendingPathComponent("Documents"), suite = "batch-transform-"+UUID().uuidString
        try FileManager.default.createDirectory(at:docs,withIntermediateDirectories:true)
        let preferences = try XCTUnwrap(UserDefaults(suiteName:suite))
        let context = try RasterImage.context(width:8,height:6)
        context.setFillColor(UIColor.red.cgColor); context.fill(CGRect(x:0,y:0,width:8,height:6))
        context.setFillColor(UIColor.blue.cgColor); context.fill(CGRect(x:0,y:0,width:3,height:4))
        let png = try RasterImage.png(XCTUnwrap(context.makeImage()))
        let mask = try RasterImage.png(RasterImage.solidMask(width:2,height:2,white:true))
        let g = RasterLayer(name:"组",transform:.init(size:CGSize(width:64,height:48),sampling:.nearest),isGroup:true,maskPNGData:mask)
        let a = RasterLayer(name:"一",pngData:png,transform:.init(origin:CGPoint(x:8,y:6),size:CGSize(width:16,height:12),sampling:.nearest),parentID:g.id,maskPNGData:mask)
        let hidden = RasterLayer(name:"隐藏",pngData:png,transform:.init(origin:CGPoint(x:6,y:28),size:CGSize(width:10,height:8)),isVisible:false,parentID:g.id)
        let b = RasterLayer(name:"二",pngData:png,transform:.init(origin:CGPoint(x:36,y:18),size:CGSize(width:16,height:12),rotation:37,sampling:.nearest))
        let d = CanvasDocument(width:64,height:48,layers:[g,a,hidden,b],activeLayerID:a.id)
        try DocumentStore.save(d,to:docs.appendingPathComponent(d.id.uuidString.lowercased()+".comp"))
        preferences.set(d.id.uuidString.lowercased(),forKey:"lastDocument")
        let model = EditorModel(documentsURL:docs,supportURL:root.appendingPathComponent("Support"),preferences:preferences,loadPairing:false)
        addTeardownBlock {
            await MainActor.run { model.suspend(); preferences.removePersistentDomain(forName:suite) }
            try? FileManager.default.removeItem(at:root)
        }
        return model
    }
    @MainActor private func selectTwo(_ model: EditorModel) {
        model.setLayerMultiSelecting(false); model.select(model.document.layers[1])
        model.setLayerMultiSelecting(true); model.toggleLayerSelection(model.document.layers[3].id)
    }
    private func moved(_ t: LayerTransform) -> LayerTransform {
        var n = t; n.origin.x += 4; n.origin.y += 3; return n
    }
    private func pixels(_ image: CGImage) throws -> Data { try XCTUnwrap(image.dataProvider?.data) as Data }

    @MainActor func testManyPreviewsCommitOneUndoPreserveSourcesAndReopen() throws {
        let m = try fixture(); selectTwo(m)
        let before = m.document; XCTAssertTrue(m.beginTransform())
        let s = try XCTUnwrap(m.transformSession); XCTAssertEqual(s.scope,.layers)
        for step in 1...8 {
            var next = moved(s.original); next.origin.x += CGFloat(step)
            next.size.width *= 1.2; next.size.height *= 1.2; next.rotation = -25; next.flipX = true
            XCTAssertTrue(m.previewTransform(next,sessionID:s.id)); XCTAssertEqual(m.document,before)
            XCTAssertEqual(m.editor.undoCount,0)
        }
        let preview = m.transformPreviewDocument, rendered = try pixels(m.renderer.render(preview))
        m.saveNow(); XCTAssertEqual(try DocumentStore.load(from:m.documentURL),before)
        XCTAssertNotEqual(preview.layers,before.layers)
        XCTAssertTrue(m.commitTransform(sessionID:s.id)); XCTAssertEqual(m.editor.undoCount,1)
        XCTAssertEqual(m.document.layers,preview.layers)
        XCTAssertEqual(try pixels(m.renderer.render(m.document)),rendered)
        for (a,b) in zip(before.layers,m.document.layers) { XCTAssertEqual(a.pngData,b.pngData); XCTAssertEqual(a.maskPNGData,b.maskPNGData) }
        let finished = m.document
        m.undo(); XCTAssertEqual(m.document.layers,before.layers)
        m.redo(); XCTAssertEqual(m.document.layers,finished.layers)
        m.saveNow(); XCTAssertEqual(try DocumentStore.load(from:m.documentURL),m.document)
    }

    @MainActor func testCancelAndReturningToOriginalPreserveRedo() throws {
        let m = try fixture(); m.updateLayer("临时透明度") { $0.opacity = 0.5 }; m.undo(); selectTwo(m)
        let before = m.document; XCTAssertTrue(m.editor.canRedo); XCTAssertTrue(m.beginTransform())
        var s = try XCTUnwrap(m.transformSession)
        XCTAssertTrue(m.previewTransform(moved(s.original),sessionID:s.id)); m.cancelTransform()
        XCTAssertEqual(m.document,before); XCTAssertTrue(m.editor.canRedo)
        XCTAssertTrue(m.beginTransform()); s = try XCTUnwrap(m.transformSession)
        XCTAssertTrue(m.previewTransform(moved(s.original),sessionID:s.id))
        XCTAssertTrue(m.previewTransform(s.original,sessionID:s.id)); XCTAssertEqual(m.transformPreviewDocument,before)
        XCTAssertTrue(m.commitTransform()); XCTAssertEqual(m.document,before); XCTAssertTrue(m.editor.canRedo)
    }

    @MainActor func testGroupAndSelectedChildMoveOnceIncludingHiddenChildAndMask() throws {
        let m = try fixture(); m.select(m.document.layers[0]); m.setLayerMultiSelecting(true); m.toggleLayerSelection(m.document.layers[1].id)
        let before = m.document; XCTAssertTrue(m.beginTransform()); let s = try XCTUnwrap(m.transformSession)
        XCTAssertTrue(m.previewTransform(moved(s.original),sessionID:s.id))
        let preview = m.transformPreviewDocument
        for i in 0..<3 {
            XCTAssertEqual(preview.layers[i].transform.origin.x,before.layers[i].transform.origin.x+4)
            XCTAssertEqual(preview.layers[i].transform.origin.y,before.layers[i].transform.origin.y+3)
        }
        XCTAssertEqual(preview.layers[3],before.layers[3]); XCTAssertTrue(m.commitTransform())
        XCTAssertEqual(m.editor.undoCount,1); m.undo(); XCTAssertEqual(m.document.layers,before.layers)
    }

    @MainActor func testSelectionNavigationAndLateEventsCannotChangeAnotherSession() throws {
        let m = try fixture(); selectTwo(m); XCTAssertTrue(m.beginTransform()); let old = try XCTUnwrap(m.transformSession)
        m.setLayerMultiSelecting(false); selectTwo(m); XCTAssertTrue(m.beginTransform()); let current = try XCTUnwrap(m.transformSession)
        XCTAssertFalse(m.previewTransform(moved(old.original),sessionID:old.id)); XCTAssertFalse(m.commitTransform(sessionID:old.id))
        XCTAssertEqual(m.transformSession,current)
        m.selectedLayerIDs.remove(m.document.layers[1].id) // Also protect against navigation bypassing the helper.
        let before = m.document
        XCTAssertEqual(m.transformPreviewDocument,before); XCTAssertFalse(m.commitTransform(sessionID:current.id)); XCTAssertEqual(m.document,before)
    }

    @MainActor func testOutOfBandSourceChangesRejectPreviewAndCommitWithoutPartialEdit() throws {
        let m = try fixture(); selectTwo(m); XCTAssertTrue(m.beginTransform()); let s = try XCTUnwrap(m.transformSession)
        XCTAssertTrue(m.previewTransform(moved(s.original),sessionID:s.id))
        try m.editor.transaction("外部锁定") { $0.layers[1].isLocked = true }
        let before = m.document
        XCTAssertEqual(m.transformPreviewDocument,before)
        XCTAssertFalse(m.commitTransform(sessionID:s.id)); XCTAssertEqual(m.document,before)
        XCTAssertNil(m.transformSession)
    }

    @MainActor func testLockedDescendantOrAncestorAndExplicitBlackSelectionReject() throws {
        let m = try fixture(); m.toggleLock(m.document.layers[2].id); m.select(m.document.layers[0])
        let locked = m.document; XCTAssertFalse(m.beginTransform()); XCTAssertEqual(m.document,locked)
        m.toggleLock(m.document.layers[2].id); m.toggleLock(m.document.layers[0].id); selectTwo(m)
        XCTAssertFalse(m.beginTransform()); m.toggleLock(m.document.layers[0].id)
        try m.editor.setSelection(RasterImage.png(RasterImage.solidMask(width:64,height:48,white:false))); m.refresh()
        let selected = m.document; XCTAssertFalse(m.beginTransform()); XCTAssertEqual(m.document,selected)
        XCTAssertTrue(m.errorMessage?.contains("取消选区") == true); XCTAssertNil(m.transformSession)
    }

    @MainActor func testRotatedSourcesForceRatioAndShearKeepsLastGoodPreview() throws {
        let m = try fixture(); selectTwo(m); m.transformAspectLocked = false
        XCTAssertTrue(m.beginTransform()); let s = try XCTUnwrap(m.transformSession)
        XCTAssertTrue(m.transformRequiresAspectLock); XCTAssertTrue(m.transformAspectLocked)
        let good = moved(s.original); XCTAssertTrue(m.previewTransform(good,sessionID:s.id))
        let preview = m.transformPreviewDocument
        var bad = good; bad.size.width *= 2
        XCTAssertFalse(m.previewTransform(bad,sessionID:s.id)); XCTAssertEqual(m.transformPreviewDocument,preview)
        XCTAssertTrue(m.errorMessage?.contains("斜切") == true)
        m.errorMessage = nil; XCTAssertTrue(m.commitTransform()); XCTAssertEqual(m.document.layers,preview.layers)
    }

    @MainActor func testFlipsToolSwitchAndBackgroundKeepSourceDocumentSafe() throws {
        let m = try fixture(); selectTwo(m); let before = m.document
        XCTAssertTrue(m.beginTransform()); m.flipCommonTransform(horizontal:true); m.flipCommonTransform(horizontal:false)
        XCTAssertNotEqual(m.transformPreviewDocument.layers,before.layers); XCTAssertEqual(m.document,before)
        let s = try XCTUnwrap(m.transformSession); m.tool = .brush
        XCTAssertNil(m.transformSession); XCTAssertFalse(m.commitTransform(sessionID:s.id)); XCTAssertEqual(m.document,before)
        XCTAssertTrue(m.beginTransform()); m.flipCommonTransform(horizontal:true); m.suspend()
        XCTAssertNil(m.transformSession); XCTAssertEqual(try DocumentStore.load(from:m.documentURL),before)
    }

    @MainActor func testWholeGroupMaskAndClippingRotationPreviewCommitAgree() throws {
        let m = try fixture()
        let gray = try RasterImage.context(width:2,height:2,gray:true)
        gray.setFillColor(gray:128.0/255,alpha:1); gray.fill(CGRect(x:0,y:0,width:2,height:2))
        try m.editor.transaction("合成样例") {
            $0.layers[0].maskPNGData = try RasterImage.png(XCTUnwrap(gray.makeImage()))
            $0.layers[2].isVisible = true; $0.layers[2].maskSourceID = $0.layers[1].id
        }
        m.refresh(); m.select(m.document.layers[0]); let before = m.document, history = m.editor.undoCount
        XCTAssertTrue(m.beginTransform()); let s = try XCTUnwrap(m.transformSession)
        var next = moved(s.original); next.size.width *= 0.8; next.size.height *= 0.8; next.rotation = 29; next.flipX = true
        XCTAssertTrue(m.previewTransform(next,sessionID:s.id))
        let expected = try pixels(m.renderer.render(m.transformPreviewDocument))
        XCTAssertTrue(m.commitTransform()); XCTAssertEqual(m.editor.undoCount,history+1)
        XCTAssertEqual(try pixels(m.renderer.render(m.document)),expected)
        for (a,b) in zip(before.layers,m.document.layers) { XCTAssertEqual(a.pngData,b.pngData); XCTAssertEqual(a.maskPNGData,b.maskPNGData); XCTAssertEqual(a.maskSourceID,b.maskSourceID) }
        m.saveNow(); XCTAssertEqual(try DocumentStore.load(from:m.documentURL),m.document)
        m.undo(); XCTAssertEqual(m.document.layers,before.layers)
    }
}
