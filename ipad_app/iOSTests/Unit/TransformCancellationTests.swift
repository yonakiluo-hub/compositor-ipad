import XCTest
import UIKit
@testable import CompositorPad

final class TransformCancellationTests: XCTestCase {
    @MainActor
    private func fixture() throws -> (EditorModel, PadCanvasView) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("transform-cancellation-" + UUID().uuidString)
        let documents = root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let suite = "transform-cancellation-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let image = try RasterImage.context(width: 32, height: 24)
        image.setFillColor(UIColor.systemBlue.cgColor)
        image.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        let layer = RasterLayer(name: "手势测试", pngData: try RasterImage.png(XCTUnwrap(image.makeImage())),
                                transform: LayerTransform(size: CGSize(width: 32, height: 24)))
        let document = CanvasDocument(name: "手势取消测试", width: 64, height: 48, layers: [layer], activeLayerID: layer.id)
        try DocumentStore.save(document, to: documents.appendingPathComponent(document.id.uuidString.lowercased() + ".comp"))
        preferences.set(document.id.uuidString.lowercased(), forKey: "lastDocument")
        let model = EditorModel(documentsURL: documents, supportURL: root.appendingPathComponent("Support"),
                                preferences: preferences, loadPairing: false)
        let canvas = PadCanvasView(model: model)
        canvas.frame = CGRect(x: 0, y: 0, width: 640, height: 480)
        canvas.update()
        addTeardownBlock {
            await MainActor.run { model.suspend(); UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
            try? FileManager.default.removeItem(at: root)
        }
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.beginTransform())
        return (model, canvas)
    }

    @MainActor
    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @MainActor
    func testInterruptedDragRestoresPreviousPreviewButCompletedDragKeepsIt() throws {
        let (model, canvas) = try fixture()
        let before = model.document, session = try XCTUnwrap(model.transformSession)
        var previous = session.original
        previous.origin.x += 8
        XCTAssertTrue(model.previewTransform(previous, sessionID: session.id))
        canvas.beginTransformDrag(handle: .right, start: previous.point(CGPoint(x: 1, y: 0.5)))
        var interrupted = previous
        interrupted.size.width += 12
        XCTAssertTrue(model.previewTransform(interrupted, sessionID: session.id))
        canvas.cancelInput(keepingPolygon: true)
        XCTAssertEqual(model.transformSession?.current, previous)
        XCTAssertEqual(model.document, before)
        XCTAssertEqual(model.editor.undoCount, 0)

        canvas.beginTransformDrag(handle: .translate, start: previous.center)
        var completed = previous
        completed.origin.y += 6
        XCTAssertTrue(model.previewTransform(completed, sessionID: session.id))
        canvas.cancelInput(keepingTransformPreview: true)
        XCTAssertEqual(model.transformSession?.current, completed)
        XCTAssertTrue(model.commitTransform(sessionID: session.id))
        XCTAssertEqual(model.activeLayer?.transform, completed)
        XCTAssertEqual(model.editor.undoCount, 1)
    }

    @MainActor
    func testOldPointerCancellationCannotRollbackANewSession() throws {
        let (model, canvas) = try fixture()
        let old = try XCTUnwrap(model.transformSession)
        canvas.beginTransformDrag(handle: .translate, start: old.original.center)
        var changed = old.original
        changed.origin.x += 10
        XCTAssertTrue(model.previewTransform(changed, sessionID: old.id))
        model.cancelTransform()
        XCTAssertTrue(model.beginTransform())
        let new = try XCTUnwrap(model.transformSession)
        var replacement = new.original
        replacement.origin.y += 12
        XCTAssertTrue(model.previewTransform(replacement, sessionID: new.id))
        canvas.cancelInput()
        XCTAssertEqual(model.transformSession?.id, new.id)
        XCTAssertEqual(model.transformSession?.current, replacement)
        XCTAssertEqual(model.editor.undoCount, 0)
    }

    @MainActor
    func testViewportResetDefersRollbackAndRestoresOnlyInterruptedDrag() async throws {
        let (model, canvas) = try fixture()
        let session = try XCTUnwrap(model.transformSession)
        canvas.beginTransformDrag(handle: .translate, start: session.original.center)
        var changed = session.original
        changed.origin.x += 15
        XCTAssertTrue(model.previewTransform(changed, sessionID: session.id))
        model.viewportReset += 1
        model.viewportRotationReset += 1
        canvas.update()
        XCTAssertEqual(model.transformSession?.current, changed, "updateUIView must not publish a rollback synchronously")
        await drainMainQueue()
        XCTAssertEqual(model.transformSession?.current, session.original)
        XCTAssertEqual(model.editor.undoCount, 0)
    }

    @MainActor
    func testDeferredRollbackCannotOverwriteNewPointerOrNewSession() async throws {
        let (model, canvas) = try fixture()
        let session = try XCTUnwrap(model.transformSession)
        canvas.beginTransformDrag(handle: .translate, start: session.original.center)
        var changed = session.original
        changed.origin.x += 15
        XCTAssertTrue(model.previewTransform(changed, sessionID: session.id))
        model.viewportReset += 1
        canvas.update()
        // A new pointer may start with exactly the same preview, so value equality alone is insufficient.
        canvas.beginTransformDrag(handle: .right, start: changed.point(CGPoint(x: 1, y: 0.5)))
        await drainMainQueue()
        XCTAssertEqual(model.transformSession?.current, changed)
        canvas.cancelInput(keepingTransformPreview: true)

        canvas.beginTransformDrag(handle: .translate, start: changed.center)
        var interrupted = changed
        interrupted.origin.y += 6
        XCTAssertTrue(model.previewTransform(interrupted, sessionID: session.id))
        model.viewportReset += 1
        canvas.update()
        model.cancelTransform()
        XCTAssertTrue(model.beginTransform())
        let replacement = try XCTUnwrap(model.transformSession)
        var newPreview = replacement.original
        newPreview.size.width += 10
        XCTAssertTrue(model.previewTransform(newPreview, sessionID: replacement.id))
        await drainMainQueue()
        XCTAssertEqual(model.transformSession?.id, replacement.id)
        XCTAssertEqual(model.transformSession?.current, newPreview)
        XCTAssertEqual(model.editor.undoCount, 0)
    }
}
