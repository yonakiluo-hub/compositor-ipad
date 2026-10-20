import XCTest
import UIKit
@testable import CompositorPad

final class TransformWorkflowTests: XCTestCase {
    @MainActor
    private func fixture() throws -> (model: EditorModel, root: URL, preferences: UserDefaults) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("transform-workflow-" + UUID().uuidString)
        let documents = root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let suite = "transform-workflow-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let source = try RasterImage.context(width: 16, height: 12)
        source.setFillColor(UIColor.systemRed.cgColor); source.fill(CGRect(x: 0, y: 0, width: 16, height: 12))
        source.setFillColor(UIColor.systemBlue.cgColor); source.fill(CGRect(x: 0, y: 0, width: 5, height: 8))
        let mask = try RasterImage.context(width: 16, height: 12, gray: true)
        for x in 0..<16 {
            mask.setFillColor(gray: CGFloat(x) / 15, alpha: 1)
            mask.fill(CGRect(x: x, y: 0, width: 1, height: 12))
        }
        let layer = RasterLayer(name: "变换源图层", pngData: try RasterImage.png(XCTUnwrap(source.makeImage())),
            transform: LayerTransform(origin: CGPoint(x: 8, y: 10), size: CGSize(width: 24, height: 18), rotation: 12,
                                      flipX: true, sampling: .nearest),
            maskPNGData: try RasterImage.png(XCTUnwrap(mask.makeImage())))
        let other = RasterLayer(name: "其他图层", pngData: layer.pngData,
                                transform: LayerTransform(origin: CGPoint(x: 50, y: 36), size: CGSize(width: 12, height: 9)))
        let document = CanvasDocument(name: "变换事务测试", width: 64, height: 48, layers: [layer, other], activeLayerID: layer.id)
        try DocumentStore.save(document, to: documents.appendingPathComponent(document.id.uuidString.lowercased() + ".comp"))
        preferences.set(document.id.uuidString.lowercased(), forKey: "lastDocument")
        let model = EditorModel(documentsURL: documents, supportURL: root.appendingPathComponent("Support"),
                                preferences: preferences, loadPairing: false)
        addTeardownBlock {
            await MainActor.run { model.suspend(); UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
            try? FileManager.default.removeItem(at: root)
        }
        XCTAssertNil(model.errorMessage)
        return (model, root, preferences)
    }

    private func moved(_ source: LayerTransform) -> LayerTransform {
        var result = source
        result.origin = CGPoint(x: 14, y: 6); result.size = CGSize(width: 36, height: 24); result.rotation = -27
        return result
    }

    private func pixels(_ image: CGImage) throws -> Data { try XCTUnwrap(image.dataProvider?.data) as Data }

    @MainActor
    func testManyPreviewsCommitExactlyOneUndoAndPreserveSourceMaskAndRenderedPixels() throws {
        let model = try fixture().model
        let before = model.document
        let original = try XCTUnwrap(model.activeLayer)
        XCTAssertTrue(model.beginTransform())
        let session = try XCTUnwrap(model.transformSession)
        XCTAssertEqual(model.tool, .transform)
        XCTAssertTrue(model.transformAspectLocked)
        for step in 1...8 {
            var transform = moved(original.transform)
            transform.origin.x += CGFloat(step)
            XCTAssertTrue(model.previewTransform(transform, sessionID: session.id))
            XCTAssertEqual(model.document, before)
            XCTAssertEqual(model.editor.undoCount, 0)
            XCTAssertFalse(model.editor.isModified)
        }
        let expected = try XCTUnwrap(model.transformSession).current
        let previewDocument = model.transformPreviewDocument
        XCTAssertEqual(previewDocument.layers[0].pngData, original.pngData)
        XCTAssertEqual(previewDocument.layers[0].maskPNGData, original.maskPNGData)
        XCTAssertEqual(previewDocument.layers[1], before.layers[1])
        let previewPixels = try pixels(model.renderer.render(previewDocument))
        XCTAssertNotEqual(previewPixels, try pixels(model.renderer.render(before)))
        XCTAssertTrue(model.commitTransform(sessionID: session.id))
        XCTAssertNil(model.transformSession)
        XCTAssertEqual(model.tool, .move)
        XCTAssertEqual(model.document.revision, before.revision + 1)
        XCTAssertEqual(model.editor.undoCount, 1)
        XCTAssertEqual(model.editor.undoName, "自由变换")
        XCTAssertEqual(model.activeLayer?.transform, expected)
        XCTAssertEqual(model.activeLayer?.pngData, original.pngData)
        XCTAssertEqual(model.activeLayer?.maskPNGData, original.maskPNGData)
        XCTAssertEqual(model.activeLayer?.maskEnabled, original.maskEnabled)
        XCTAssertEqual(previewPixels, try pixels(model.renderer.render(model.document)))
        XCTAssertEqual(previewPixels, try pixels(XCTUnwrap(model.preview)))
        model.undo()
        XCTAssertEqual(model.document.layers, before.layers)
        model.redo()
        XCTAssertEqual(model.activeLayer?.transform, expected)
        XCTAssertEqual(previewPixels, try pixels(model.renderer.render(model.document)))
    }

    @MainActor
    func testCancelNoOpAndFailedOrdinaryEditPreserveRedo() throws {
        let model = try fixture().model
        model.rename("待重做名称"); model.undo()
        let before = model.document, redoName = model.editor.redoName
        XCTAssertTrue(model.editor.canRedo)
        XCTAssertTrue(model.beginTransform())
        var session = try XCTUnwrap(model.transformSession)
        XCTAssertTrue(model.previewTransform(moved(session.original), sessionID: session.id))
        model.cancelTransform()
        XCTAssertEqual(model.document, before)
        XCTAssertTrue(model.editor.canRedo)
        XCTAssertEqual(model.editor.redoName, redoName)
        XCTAssertTrue(model.beginTransform())
        session = try XCTUnwrap(model.transformSession)
        XCTAssertTrue(model.previewTransform(moved(session.original), sessionID: session.id))
        XCTAssertTrue(model.previewTransform(session.original, sessionID: session.id))
        XCTAssertTrue(model.commitTransform(), "Returning to the original transform is a no-op even after previews")
        XCTAssertEqual(model.document, before)
        XCTAssertTrue(model.editor.canRedo)

        XCTAssertTrue(model.beginTransform())
        session = try XCTUnwrap(model.transformSession)
        XCTAssertTrue(model.previewTransform(moved(session.original), sessionID: session.id))
        model.edit("失败编辑") { _ in throw DocumentError.invalid("测试拒绝") }
        XCTAssertNil(model.transformSession)
        XCTAssertEqual(model.document, before)
        XCTAssertTrue(model.editor.canRedo)
        XCTAssertEqual(model.editor.redoName, redoName)
        model.redo()
        XCTAssertEqual(model.document.name, "待重做名称")
    }

    @MainActor
    func testSessionIdentityLayerAndRevisionRejectLatePreviewsAndCommits() throws {
        let model = try fixture().model
        XCTAssertTrue(model.beginTransform())
        let old = try XCTUnwrap(model.transformSession)
        model.cancelTransform()
        XCTAssertTrue(model.beginTransform())
        let current = try XCTUnwrap(model.transformSession)
        XCTAssertNotEqual(old.id, current.id)
        XCTAssertFalse(model.previewTransform(moved(old.original), sessionID: old.id))
        XCTAssertFalse(model.commitTransform(sessionID: old.id))
        XCTAssertEqual(model.transformSession, current, "Late events must not cancel or change a newer session")
        model.select(model.document.layers[1])
        XCTAssertNil(model.transformSession)
        XCTAssertFalse(model.previewTransform(moved(current.original), sessionID: current.id))
        XCTAssertFalse(model.commitTransform(sessionID: current.id))

        XCTAssertTrue(model.beginTransform())
        let changedRevision = try XCTUnwrap(model.transformSession)
        XCTAssertTrue(model.previewTransform(moved(changedRevision.original), sessionID: changedRevision.id))
        model.rename("普通编辑使预览过期")
        XCTAssertNil(model.transformSession)
        XCTAssertFalse(model.previewTransform(moved(changedRevision.original), sessionID: changedRevision.id))
        XCTAssertFalse(model.commitTransform(sessionID: changedRevision.id))
        XCTAssertEqual(model.editor.undoCount, 1)
    }

    @MainActor
    func testOutOfBandChangesNeverRenderOrCommitAnObsoletePreview() throws {
        let model = try fixture().model
        XCTAssertTrue(model.beginTransform())
        var session = try XCTUnwrap(model.transformSession)
        XCTAssertTrue(model.previewTransform(moved(session.original), sessionID: session.id))
        try model.editor.transaction("外部编辑") { $0.name = "新版本" }
        XCTAssertEqual(model.transformPreviewDocument, model.document)
        XCTAssertFalse(model.previewTransform(moved(session.original), sessionID: session.id))
        XCTAssertNil(model.transformSession)
        XCTAssertEqual(model.editor.undoCount, 1)

        XCTAssertTrue(model.beginTransform())
        session = try XCTUnwrap(model.transformSession)
        XCTAssertTrue(model.previewTransform(moved(session.original), sessionID: session.id))
        try model.editor.selectLayer(model.document.layers[1].id) // Navigation does not increment revision.
        XCTAssertEqual(model.transformPreviewDocument, model.document)
        XCTAssertFalse(model.commitTransform(sessionID: session.id))
        XCTAssertNil(model.transformSession)
        XCTAssertEqual(model.editor.undoCount, 1)
        XCTAssertEqual(model.document.layers[0].transform, session.original)
    }

    @MainActor
    func testToolSwitchBackgroundAndDocumentSwitchDiscardDraft() throws {
        let model = try fixture().model
        let original = model.document, sourceURL = model.documentURL
        XCTAssertTrue(model.beginTransform())
        var session = try XCTUnwrap(model.transformSession)
        XCTAssertTrue(model.previewTransform(moved(session.original), sessionID: session.id))
        model.tool = .brush
        XCTAssertNil(model.transformSession)
        XCTAssertEqual(model.tool, .brush)
        XCTAssertEqual(model.document, original)

        XCTAssertTrue(model.beginTransform())
        session = try XCTUnwrap(model.transformSession)
        XCTAssertTrue(model.previewTransform(moved(session.original), sessionID: session.id))
        model.suspend()
        XCTAssertNil(model.transformSession)
        XCTAssertEqual(model.document, original)
        XCTAssertEqual(try DocumentStore.load(from: sourceURL), original)

        XCTAssertTrue(model.beginTransform())
        session = try XCTUnwrap(model.transformSession)
        XCTAssertTrue(model.previewTransform(moved(session.original), sessionID: session.id))
        model.create(name: "另一画稿", width: 32, height: 24)
        XCTAssertNil(model.transformSession)
        XCTAssertNotEqual(model.document.id, original.id)
        XCTAssertFalse(model.previewTransform(moved(session.original), sessionID: session.id))
        model.open(sourceURL)
        XCTAssertEqual(model.document, original)
        XCTAssertEqual(model.editor.undoCount, 0)
    }

    @MainActor
    func testLockedLayersGroupsAndInvalidTransformsCannotChangeDocument() throws {
        let model = try fixture().model
        let group = RasterLayer(name: "锁定父组", transform: LayerTransform(size: model.document.size), isLocked: true, isGroup: true)
        model.edit("准备父组") { document in document.layers.append(group); document.layers[0].parentID = group.id }
        XCTAssertFalse(model.beginTransform())
        XCTAssertNil(model.transformSession)
        XCTAssertEqual(model.errorMessage, DocumentError.lockedLayer.localizedDescription)
        model.toggleLock(group.id)
        model.toggleLock(model.document.layers[0].id)
        XCTAssertFalse(model.beginTransform())
        model.select(try XCTUnwrap(model.document.layers.first(where: { $0.id == group.id })))
        XCTAssertFalse(model.beginTransform())
        XCTAssertNil(model.transformSession)

        model.select(model.document.layers[1])
        model.errorMessage = nil
        XCTAssertTrue(model.beginTransform())
        let session = try XCTUnwrap(model.transformSession), before = model.document
        var invalid = session.original
        invalid.size.width = 0
        XCTAssertFalse(model.previewTransform(invalid, sessionID: session.id))
        invalid = session.original; invalid.origin.x = .nan
        XCTAssertFalse(model.previewTransform(invalid, sessionID: session.id))
        invalid = session.original; invalid.origin.x = 1_000_001
        XCTAssertFalse(model.previewTransform(invalid, sessionID: session.id))
        XCTAssertEqual(model.transformSession, session)
        XCTAssertEqual(model.transformPreviewDocument, before)
        XCTAssertTrue(model.commitTransform())
        XCTAssertEqual(model.document, before)
    }

    @MainActor
    func testEmptyLayerCannotBeginOrProduceAnOversizedPixelSurface() throws {
        let model = try fixture().model
        model.edit("清空源像素") { $0.layers[0].pngData = nil }
        let before = model.document, history = model.editor.undoCount
        XCTAssertNotNil(model.activeLayer?.maskPNGData, "A linked mask alone does not provide source pixels")
        XCTAssertFalse(model.beginTransform())
        XCTAssertNil(model.transformSession)
        XCTAssertNotEqual(model.tool, .transform)
        XCTAssertEqual(model.errorMessage, "这个图层还没有内容，请先绘画或导入图片。")
        XCTAssertEqual(model.document, before)
        XCTAssertEqual(model.editor.undoCount, history)
    }

    @MainActor
    func testSavingPreviewKeepsCommittedArtworkAndFinishedTransformSurvivesReopen() throws {
        let fixture = try fixture(), model = fixture.model
        let before = model.document
        XCTAssertTrue(model.beginTransform())
        let session = try XCTUnwrap(model.transformSession), transformed = moved(session.original)
        XCTAssertTrue(model.previewTransform(transformed, sessionID: session.id))
        model.saveNow()
        XCTAssertEqual(try DocumentStore.load(from: model.documentURL), before)
        XCTAssertNotNil(model.transformSession, "An autosave must neither apply nor discard the user's preview")
        XCTAssertTrue(model.commitTransform())
        model.saveNow()
        let reopened = EditorModel(documentsURL: model.documentsURL, supportURL: fixture.root.appendingPathComponent("ReopenedSupport"),
                                   preferences: fixture.preferences, loadPairing: false)
        defer { reopened.suspend() }
        XCTAssertNil(reopened.errorMessage)
        XCTAssertNil(reopened.transformSession)
        XCTAssertEqual(reopened.document, model.document)
        XCTAssertEqual(reopened.activeLayer?.transform, transformed)
        XCTAssertEqual(reopened.activeLayer?.pngData, before.activeLayer?.pngData)
        XCTAssertEqual(reopened.activeLayer?.maskPNGData, before.activeLayer?.maskPNGData)
        XCTAssertEqual(try pixels(reopened.renderer.render(reopened.document)), try pixels(model.renderer.render(model.document)))
    }
}
