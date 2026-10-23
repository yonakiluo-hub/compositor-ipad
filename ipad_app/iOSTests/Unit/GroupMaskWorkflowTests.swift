import XCTest
import UIKit
@testable import CompositorPad

final class GroupMaskWorkflowTests: XCTestCase {
    @MainActor
    private func fixture() throws -> EditorModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("group-mask-"+UUID().uuidString)
        let docs = root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at:docs,withIntermediateDirectories:true)
        let suite = "group-mask-"+UUID().uuidString, preferences = try XCTUnwrap(UserDefaults(suiteName:suite))
        let context = try RasterImage.context(width:16,height:12)
        context.setFillColor(UIColor.red.cgColor); context.fill(CGRect(x:0,y:0,width:16,height:12))
        let data = try RasterImage.png(XCTUnwrap(context.makeImage()))
        let group = RasterLayer(name:"组",transform:.init(size:CGSize(width:32,height:24)),isGroup:true)
        let a = RasterLayer(name:"一",pngData:data,transform:.init(size:CGSize(width:32,height:24)),parentID:group.id)
        let b = RasterLayer(name:"二",pngData:data,transform:.init(size:CGSize(width:32,height:24)),parentID:group.id)
        let doc = CanvasDocument(width:32,height:24,layers:[group,a,b],activeLayerID:group.id)
        try DocumentStore.save(doc,to:docs.appendingPathComponent(doc.id.uuidString.lowercased()+".comp"))
        preferences.set(doc.id.uuidString.lowercased(),forKey:"lastDocument")
        let model = EditorModel(documentsURL:docs,supportURL:root.appendingPathComponent("Support"),preferences:preferences,loadPairing:false)
        addTeardownBlock {
            await MainActor.run { model.suspend(); UserDefaults(suiteName:suite)?.removePersistentDomain(forName:suite) }
            try? FileManager.default.removeItem(at:root)
        }
        return model
    }
    private func samples(_ data: Data) throws -> [UInt8] {
        let image = try RasterImage.decode(data), raw = try XCTUnwrap(image.dataProvider?.data)
        let bytes = try XCTUnwrap(CFDataGetBytePtr(raw))
        return (0..<image.height).flatMap { y in (0..<image.width).map { x in bytes[y*image.bytesPerRow+x] } }
    }

    @MainActor
    func testWhiteGroupMaskKeepsAppearanceAndChildrenThenUndoRedoReopens() throws {
        let model = try fixture(), original = model.document
        let pixels = try RasterImage.png(model.renderer.render(original))
        model.addLayerMask()
        XCTAssertNil(model.errorMessage); XCTAssertEqual(model.layerEditTarget,.mask)
        XCTAssertTrue(try samples(XCTUnwrap(model.activeLayer?.maskPNGData)).allSatisfy { $0 == 255 })
        XCTAssertEqual(Array(model.document.layers.dropFirst()),Array(original.layers.dropFirst()))
        XCTAssertEqual(try RasterImage.png(model.renderer.render(model.document)),pixels)
        XCTAssertEqual(model.editor.undoCount,1)
        let masked = model.document
        model.undo(); XCTAssertEqual(model.document.layers,original.layers)
        model.redo(); XCTAssertEqual(model.document.layers,masked.layers)
        model.saveNow(); XCTAssertEqual(try DocumentStore.load(from:model.documentURL),model.document)
    }

    @MainActor
    func testGroupMaskStrokePreviewCommitOnceAndLateStrokeRejected() throws {
        let model = try fixture(); model.addLayerMask(); model.chooseMaskPaintMode(reveals:false)
        model.diameter = 10; model.hardness = 1; model.brushOpacity = 1
        let session = try LayerMaskStrokeSession(model:model), before = model.document
        session.stroke.add(BrushSample(point:CGPoint(x:16,y:12),pressure:1,altitude:.pi/2,azimuth:0))
        let image = try session.stroke.image()
        let preview = try model.renderer.render(before,replacing:session.layer.id,with:session.sourcePixels,replacementMask:image)
        XCTAssertEqual(model.document,before)
        XCTAssertTrue(model.commitLayerMaskStroke(session)); XCTAssertEqual(model.editor.undoCount,2)
        XCTAssertEqual(try RasterImage.png(preview),try RasterImage.png(model.renderer.render(model.document)))
        XCTAssertEqual(Array(model.document.layers.dropFirst()),Array(before.layers.dropFirst()))
        XCTAssertFalse(model.commitLayerMaskStroke(session))
        let strokeResult = model.document
        model.undo(); XCTAssertEqual(model.document.layers,before.layers)
        model.redo(); XCTAssertEqual(model.document.layers,strokeResult.layers)
    }

    @MainActor
    func testSoftSelectionLimitsGroupMaskFillOnceAndBlackSelectionProtects() throws {
        let model = try fixture(); model.addLayerMask()
        let gray = try RasterImage.context(width:32,height:24,gray:true)
        gray.setFillColor(gray:128.0/255,alpha:1); gray.fill(CGRect(x:0,y:0,width:32,height:24))
        try model.editor.setSelection(RasterImage.png(XCTUnwrap(gray.makeImage()))); model.refresh()
        model.brushOpacity = 1; model.fillLayerMask(reveal:false)
        XCTAssertTrue(try samples(XCTUnwrap(model.activeLayer?.maskPNGData)).allSatisfy { abs(Int($0)-127) <= 1 })
        let before = model.document
        try model.editor.setSelection(RasterImage.png(RasterImage.solidMask(width:32,height:24,white:false))); model.refresh()
        let protected = model.document
        model.fillLayerMask(reveal:true); model.invertLayerMask()
        XCTAssertEqual(model.document,protected)
        XCTAssertEqual(model.activeLayer?.maskPNGData,before.layers[0].maskPNGData)
    }

    @MainActor
    func testSelectionToGroupMaskLoadDisableInvertAndRemoveAreEditable() throws {
        let model = try fixture(), originalChildren = Array(model.document.layers.dropFirst())
        let gray = try RasterImage.context(width:32,height:24,gray:true)
        gray.setFillColor(gray:128.0/255,alpha:1); gray.fill(CGRect(x:0,y:0,width:32,height:24))
        try model.editor.setSelection(RasterImage.png(XCTUnwrap(gray.makeImage()))); model.refresh()
        model.selectionToLayerMask()
        XCTAssertTrue(try samples(XCTUnwrap(model.activeLayer?.maskPNGData)).allSatisfy { $0 == 128 })
        try model.editor.setSelection(RasterImage.png(RasterImage.solidMask(width:32,height:24,white:false))); model.refresh()
        model.selectionToLayerMask()
        XCTAssertTrue(try samples(XCTUnwrap(model.activeLayer?.maskPNGData)).allSatisfy { $0 == 0 })
        model.layerMaskToSelection()
        XCTAssertTrue(try samples(XCTUnwrap(model.document.selectionMaskPNGData)).allSatisfy { $0 == 0 })
        model.clearSelection(); model.invertLayerMask()
        XCTAssertTrue(try samples(XCTUnwrap(model.activeLayer?.maskPNGData)).allSatisfy { $0 == 255 })
        model.setLayerMaskEnabled(false); XCTAssertEqual(model.activeLayer?.maskEnabled,false)
        model.setLayerEditTarget(.mask); model.fillLayerMask(reveal:false)
        XCTAssertTrue(try samples(XCTUnwrap(model.activeLayer?.maskPNGData)).allSatisfy { $0 == 0 })
        model.setLayerMaskEnabled(true); XCTAssertEqual(model.activeLayer?.maskEnabled,true)
        model.removeLayerMask(); XCTAssertNil(model.activeLayer?.maskPNGData); XCTAssertEqual(model.layerEditTarget,.pixels)
        model.undo(); XCTAssertNotNil(model.activeLayer?.maskPNGData)
        XCTAssertEqual(Array(model.document.layers.dropFirst()),originalChildren)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testGroupLockAndNavigationPreventStaleMaskEdits() throws {
        let model = try fixture(); model.addLayerMask()
        let session = try LayerMaskStrokeSession(model:model)
        model.select(model.document.layers[1]); XCTAssertFalse(model.commitLayerMaskStroke(session))
        model.select(model.document.layers[0]); model.setLayerEditTarget(.mask)
        model.toggleLock(model.document.layers[0].id)
        let locked = model.document
        XCTAssertThrowsError(try LayerMaskStrokeSession(model:model))
        model.fillLayerMask(reveal:false); XCTAssertEqual(model.document,locked)
        model.errorMessage = nil; model.removeLayerMask(); XCTAssertEqual(model.document,locked)
        XCTAssertNotNil(model.errorMessage)
    }

    @MainActor
    func testMultiSelectionAndGroupTransformKeepMaskSourcesProtected() throws {
        let model = try fixture(); model.addLayerMask()
        let session = try LayerMaskStrokeSession(model:model)
        model.setLayerMultiSelecting(true); model.toggleLayerSelection(model.document.layers[1].id)
        XCTAssertFalse(model.commitLayerMaskStroke(session))
        XCTAssertThrowsError(try LayerMaskStrokeSession(model:model))
        let before = model.document
        XCTAssertTrue(model.beginTransform())
        XCTAssertEqual(model.transformSession?.scope, .layers)
        model.cancelTransform(); XCTAssertEqual(model.document, before)
        XCTAssertTrue(model.document.layers[0].isGroup); XCTAssertNil(model.document.layers[0].pngData)
    }
}
