import XCTest
import UIKit
@testable import CompositorPad

final class ImageSelectionWorkflowTests:XCTestCase {
    @MainActor private func fixture() throws -> EditorModel {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("image-selection-"+UUID().uuidString),suite="image-selection-"+UUID().uuidString
        let docs=root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at:docs,withIntermediateDirectories:true)
        let m=EditorModel(documentsURL:docs,supportURL:root.appendingPathComponent("Support"),preferences:try XCTUnwrap(UserDefaults(suiteName:suite)),loadPairing:false)
        m.create(name:"图像选区",width:12,height:8);m.color = .red;m.fill();m.saveNow();m.tool = .magicWand
        addTeardownBlock {try? FileManager.default.removeItem(at:root);UserDefaults.standard.removePersistentDomain(forName:suite)}
        return m
    }
    @MainActor private func finish(_ m:EditorModel) async {while let worker=m.imageSelectionTask {await worker.value}}
    @MainActor func testWandCommitOneUndoAndRoundTripWithExplicitBlackContraction() async throws {
        let m=try fixture(),before=m.document,count=m.editor.undoCount
        XCTAssertTrue(m.selectImage(at:CGPoint(x:3,y:2),kind:.wand));await finish(m)
        XCTAssertEqual(m.editor.undoCount,count+1);XCTAssertNotNil(m.document.selectionMaskPNGData)
        XCTAssertEqual(m.document.layers,before.layers)
        m.undo();XCTAssertNil(m.document.selectionMaskPNGData);m.redo()
        m.resizeSelection(amount:-100,documentID:m.document.id,revision:m.document.revision)
        XCTAssertEqual(try NumericSelectionRaster.gray(XCTUnwrap(m.selectionPreview)),Array(repeating:0,count:96))
        m.saveNow();XCTAssertEqual(try DocumentStore.load(from:m.documentURL),m.document)
    }
    @MainActor func testVisionAdapterCommitsNumericMaskAndUnavailableDoesNotClearOldSelection() async throws {
        let m=try fixture(),mask=try NumericSelectionRaster.grayImage((0..<96).map{$0%12 < 6 ? 128:0},width:12,height:8)
        m.imageSubjectDetector = {_,_ in mask}
        m.tool = .objectSelection
        XCTAssertTrue(m.selectImage(kind:.subject));await finish(m)
        XCTAssertEqual(try NumericSelectionRaster.gray(XCTUnwrap(m.selectionPreview)),try NumericSelectionRaster.gray(mask))
        let before=m.document,count=m.editor.undoCount
        m.imageSubjectDetector = {_,_ in throw ImageSelectionError.noSubject}
        XCTAssertTrue(m.selectImage(at:CGPoint(x:1,y:1),kind:.object));await finish(m)
        XCTAssertEqual(m.document,before);XCTAssertEqual(m.editor.undoCount,count);XCTAssertNotNil(m.errorMessage)
    }
    @MainActor func testCanceledAndChangedSourceOrSettingsDiscardOldRecognition() async throws {
        let m=try fixture(),mask=try RasterImage.solidMask(width:12,height:8,white:true)
        m.imageSubjectDetector = {_,_ in Thread.sleep(forTimeInterval:0.05);return mask}
        m.tool = .objectSelection
        XCTAssertTrue(m.selectImage(kind:.subject));m.cancelImageSelection();await finish(m)
        XCTAssertNil(m.document.selectionMaskPNGData)
        XCTAssertTrue(m.selectImage(kind:.subject));m.updateLayer("修改"){$0.opacity=0.5};await finish(m)
        XCTAssertNil(m.document.selectionMaskPNGData)
        XCTAssertTrue(m.selectImage(kind:.subject));m.imageSelectionSettings.contiguous.toggle();await finish(m)
        XCTAssertNil(m.document.selectionMaskPNGData)
        XCTAssertTrue(m.selectImage(kind:.subject));m.tool = .brush;await finish(m)
        XCTAssertNil(m.document.selectionMaskPNGData)
    }
    @MainActor func testNoOpAndFailurePreserveRedoAndRawSamplingIgnoresLiveColorPreview() async throws {
        let m=try fixture();m.updateLayer("暂改"){$0.opacity=0.5};m.undo();XCTAssertTrue(m.editor.canRedo)
        let before=m.document
        m.resizeSelection(amount:0,documentID:m.document.id,revision:m.document.revision)
        XCTAssertEqual(m.document,before);XCTAssertTrue(m.editor.canRedo)
        m.selectionMode = .subtract
        XCTAssertFalse(m.selectImage(at:.zero,kind:.wand));XCTAssertTrue(m.editor.canRedo)
        m.selectionMode = .replace
        let formal=try NumericSelectionRaster.rgba(m.imageSelectionSample(m.document,allLayers:true))
        XCTAssertTrue(m.beginColorAdjustment(.levels));let s=try XCTUnwrap(m.colorAdjustmentSession)
        var value=s.value;value.levels.ranges[0].outputWhite=0
        XCTAssertTrue(m.updateColorAdjustment(value,sessionID:s.id))
        XCTAssertEqual(try NumericSelectionRaster.rgba(m.imageSelectionSample(m.document,allLayers:true)),formal)
        m.cancelTransform()
    }
}
