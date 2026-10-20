import XCTest
import UIKit
@testable import CompositorPad

final class SelectionWorkflowTests: XCTestCase {
    @MainActor
    private func isolatedModel(width: Int = 32, height: Int = 24) throws -> (model: EditorModel, root: URL, preferences: UserDefaults) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("selection-workflow-" + UUID().uuidString)
        let documents = root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let suite = "selection-workflow-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let document = EditorModel.blankDocument(name: "选区整合测试", width: width, height: height)
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

    private func bytes(_ image: CGImage) throws -> [[UInt8]] {
        let data = try XCTUnwrap(image.dataProvider?.data)
        let pointer = try XCTUnwrap(CFDataGetBytePtr(data))
        let channels = image.bitsPerPixel / 8
        return (0..<image.height).flatMap { row in
            (0..<image.width).map { column in
                (0..<channels).map { pointer[row * image.bytesPerRow + column * channels + $0] }
            }
        }
    }

    private func rgba(width: Int, height: Int, samples: [[UInt8]]) throws -> CGImage {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(samples.flatMap { $0 }) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    @MainActor
    private func commit(_ shape: SelectionShape, to model: EditorModel, mode: SelectionCombineMode = .replace, feather: Double = 0) {
        model.commitSelectionShape(shape, mode: mode, feather: feather,
                                   documentID: model.document.id, revision: model.document.revision)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testFreehandPolygonAndRectangleCombineInOneTransactionPerGesture() throws {
        let model = try isolatedModel().model
        var free = SelectionGestureDraft(kind: .freehand, at: CGPoint(x: 2, y: 2),
            documentID: model.document.id, revision: model.document.revision, mode: .replace, feather: 0)
        free.move(to: CGPoint(x: 10, y: 2)); free.move(to: CGPoint(x: 10, y: 10))
        let shape = try XCTUnwrap(free.end(at: CGPoint(x: 2, y: 10), closingDistance: 1))
        model.commitSelectionShape(shape, mode: free.mode, feather: free.feather,
                                   documentID: free.documentID, revision: free.revision)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.editor.undoCount, 1)
        var coverage = try bytes(XCTUnwrap(model.selectionPreview)).map { $0[0] }
        XCTAssertEqual(coverage[6 * 32 + 6], 255)
        XCTAssertEqual(coverage[6 * 32 + 14], 0)

        var polygon = SelectionGestureDraft(kind: .polygonal, at: CGPoint(x: 12, y: 2),
            documentID: model.document.id, revision: model.document.revision, mode: .add, feather: 0)
        for point in [CGPoint(x: 12, y: 2), CGPoint(x: 20, y: 2), CGPoint(x: 20, y: 10), CGPoint(x: 12, y: 10)] {
            XCTAssertNil(polygon.end(at: point, closingDistance: 1))
        }
        model.commitSelectionShape(try XCTUnwrap(polygon.finishedShape()), mode: polygon.mode, feather: polygon.feather,
                                   documentID: polygon.documentID, revision: polygon.revision)
        XCTAssertEqual(model.editor.undoCount, 2)
        coverage = try bytes(XCTUnwrap(model.selectionPreview)).map { $0[0] }
        XCTAssertEqual(coverage[6 * 32 + 6], 255)
        XCTAssertEqual(coverage[6 * 32 + 14], 255)

        commit(.rectangle(CGRect(x: 4, y: 4, width: 14, height: 4)), to: model, mode: .intersect)
        XCTAssertEqual(model.editor.undoCount, 3)
        coverage = try bytes(XCTUnwrap(model.selectionPreview)).map { $0[0] }
        XCTAssertEqual(coverage[6 * 32 + 6], 255)
        XCTAssertEqual(coverage[6 * 32 + 14], 255)
        XCTAssertEqual(coverage[3 * 32 + 6], 0)
        commit(.rectangle(CGRect(x: 0, y: 0, width: 32, height: 24)), to: model, mode: .subtract)
        XCTAssertEqual(model.editor.undoCount, 4)
        XCTAssertNotNil(model.document.selectionMaskPNGData)
        XCTAssertEqual(try bytes(XCTUnwrap(model.selectionPreview)).map { $0[0] }, Array(repeating: 0, count: 32 * 24))
        model.color = .white; model.fill()
        let protected = try RasterImage.decode(XCTUnwrap(model.activeLayer?.pngData))
        XCTAssertEqual(try bytes(protected).map { $0[3] }, Array(repeating: 0, count: 32 * 24))
        model.clearSelection(); model.fill()
        let unrestricted = try RasterImage.decode(XCTUnwrap(model.activeLayer?.pngData))
        XCTAssertEqual(try bytes(unrestricted).map { $0[3] }, Array(repeating: 255, count: 32 * 24), "Nil selects unrestricted editing; a black image does not")
    }

    @MainActor
    func testFeatherIsOneUndoStepPreservesRedoForZeroAndSurvivesReopen() throws {
        let fixture = try isolatedModel(width: 60, height: 20)
        let model = fixture.model
        commit(.rectangle(CGRect(x: 20, y: 0, width: 20, height: 20)), to: model)
        let hard = model.document.selectionMaskPNGData
        let count = model.editor.undoCount
        model.featherSelection(radius: 6, documentID: model.document.id, revision: model.document.revision)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.editor.undoCount, count + 1)
        let soft = try XCTUnwrap(model.document.selectionMaskPNGData)
        let values = try bytes(XCTUnwrap(model.selectionPreview)).map { $0[0] }
        XCTAssertTrue(values.contains { $0 > 0 && $0 < 255 })
        XCTAssertGreaterThan(Set(values).count, 4)
        model.undo()
        XCTAssertEqual(model.document.selectionMaskPNGData, hard)
        let revision = model.document.revision
        model.featherSelection(radius: 0, documentID: model.document.id, revision: revision)
        XCTAssertEqual(model.document.revision, revision)
        XCTAssertTrue(model.editor.canRedo)
        model.redo()
        XCTAssertEqual(model.document.selectionMaskPNGData, soft)
        model.saveNow()
        XCTAssertFalse(model.saveFailed)
        let reopened = EditorModel(documentsURL: model.documentsURL, supportURL: fixture.root.appendingPathComponent("Support"),
                                   preferences: fixture.preferences, loadPairing: false)
        defer { reopened.suspend() }
        XCTAssertEqual(reopened.document, model.document)
        XCTAssertEqual(try bytes(XCTUnwrap(reopened.selectionPreview)).map { $0[0] }, values)
    }

    @MainActor
    func testSelectionCommitsRejectChangedDocumentOrRevisionWithoutTouchingHistory() throws {
        let model = try isolatedModel().model
        let shape = SelectionShape.rectangle(CGRect(x: 3, y: 2, width: 12, height: 8))
        let empty = model.document
        model.commitSelectionShape(shape, mode: .subtract, feather: 0, documentID: empty.id, revision: empty.revision)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.document, empty)
        model.errorMessage = nil
        commit(shape, to: model)
        let confirmed = model.document.revision
        model.addLayer()
        let edited = model.document
        let count = model.editor.undoCount
        model.commitSelectionShape(shape, mode: .add, feather: 2, documentID: edited.id, revision: confirmed)
        XCTAssertEqual(model.errorMessage, DocumentError.staleRevision.localizedDescription)
        XCTAssertEqual(model.document, edited)
        model.featherSelection(radius: 4, documentID: edited.id, revision: confirmed)
        XCTAssertEqual(model.errorMessage, DocumentError.staleRevision.localizedDescription)
        XCTAssertEqual(model.document, edited)
        model.commitSelectionShape(shape, mode: .replace, feather: 0, documentID: UUID(), revision: edited.revision)
        XCTAssertEqual(model.errorMessage, DocumentError.wrongDocument.localizedDescription)
        XCTAssertEqual(model.document, edited)
        XCTAssertEqual(model.editor.undoCount, count)
    }

    @MainActor
    func testOneSoftMaskDrivesBrushFillAdjustmentAndAIAlphaWithoutSquaringCoverage() throws {
        let model = try isolatedModel(width: 40, height: 24).model
        commit(.rectangle(CGRect(x: 10, y: 7, width: 16, height: 10)), to: model, feather: 4)
        let mask = try XCTUnwrap(model.selectionPreview)
        let coverage = try bytes(mask).map { $0[0] }
        XCTAssertTrue(coverage.contains { $0 > 64 && $0 < 192 })
        let brush = try PadBrushStroke(width: 40, height: 24, original: nil,
            settings: .init(diameter: 200, hardness: 1, opacity: 1, color: .white, erasing: false), selection: mask, maskMode: false)
        brush.add(.init(point: CGPoint(x: 20, y: 12), pressure: 1, altitude: .pi / 2, azimuth: 0))
        XCTAssertEqual(try bytes(brush.image()).map { $0[3] }, coverage)

        model.color = .white; model.brushOpacity = 1; model.fill()
        XCTAssertEqual(try bytes(RasterImage.decode(XCTUnwrap(model.activeLayer?.pngData))).map { $0[3] }, coverage)
        model.undo()
        let black = try RasterImage.png(rgba(width: 40, height: 24, samples: Array(repeating: [0, 0, 0, 255], count: 40 * 24)))
        model.edit("黑色底图") { $0.layers[0].pngData = black }
        model.applyAdjustment(brightness: 1, contrast: 1, saturation: 1, blur: 0)
        let adjusted = try bytes(RasterImage.decode(XCTUnwrap(model.activeLayer?.pngData)))
        for (pixel, selected) in zip(adjusted, coverage) {
            for channel in 0..<3 { XCTAssertEqual(Int(pixel[channel]), Int(selected), accuracy: 1) }
            XCTAssertEqual(pixel[3], 255)
        }
        model.undo(); model.undo()
        XCTAssertNil(model.activeLayer?.pngData)

        let crop = BridgeCropRect(x: 5, y: 3, width: 30, height: 18)
        let cropped = (crop.y..<(crop.y + crop.height)).flatMap { y in
            (crop.x..<(crop.x + crop.width)).map { x in coverage[y * 40 + x] }
        }
        // The bridge has already multiplied its mask into output alpha. White
        // premultiplied pixels with alpha=coverage become a straight-alpha PNG.
        let resultPNG = try RasterImage.png(rgba(width: crop.width, height: crop.height,
            samples: cropped.map { [$0, $0, $0, $0] }))
        let result = BridgeResult(resultId: "0", url: "/v1/jobs/soft-selection/results/0", mimeType: "image/png",
            width: crop.width, height: crop.height, cropRect: crop, colorSpace: "sRGB", alphaMode: "straight", maskApplied: true,
            sha256: bridgeSHA256(resultPNG), bytes: resultPNG.count)
        let job = BridgeJob(jobId: "soft-selection", clientRequestId: "soft-selection-request", state: .succeeded,
            backend: "mock", isSimulation: true, createdAt: "2026-10-20T00:00:00Z", updatedAt: "2026-10-20T00:00:01Z",
            source: .init(documentId: model.document.id.uuidString.lowercased(), baseRevision: model.document.revision,
                          sourceLayerIds: [], canvasSize: .init(width: 40, height: 24), cropRect: crop,
                          inputSize: .init(width: crop.width, height: crop.height), colorSpace: "sRGB"),
            workflowPreset: "mock-paint-v1", error: nil, results: [result])
        let pairing = try BridgePairing(baseUrl: "https://selection-results.test", accessToken: "test-only", backend: "mock")
        model.pairing = pairing
        model.candidates[model.candidateKey(job, result)] = resultPNG
        let before = model.document
        let history = model.editor.undoCount
        model.applyCandidate(job, result, sourcePairing: pairing)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.document.layers.last?.transform.origin, CGPoint(x: crop.x, y: crop.y))
        XCTAssertEqual(model.editor.undoCount, history + 1)
        XCTAssertEqual(model.document.selectionMaskPNGData, before.selectionMaskPNGData)
        let rendered = try bytes(model.renderer.render(model.document)).map { $0[3] }
        for y in 0..<24 { for x in 0..<40 {
            let inside = (crop.x..<(crop.x + crop.width)).contains(x) && (crop.y..<(crop.y + crop.height)).contains(y)
            XCTAssertEqual(rendered[y * 40 + x], inside ? coverage[y * 40 + x] : 0)
        } }
        model.undo()
        XCTAssertEqual(model.document.layers, before.layers)
        model.redo()
        XCTAssertEqual(try bytes(model.renderer.render(model.document)).map { $0[3] }, rendered)
    }

    @MainActor
    func testGenerationStoresExactSoftCoverageAtNonzeroCropAndRejectsEmptySelection() async throws {
        let model = try isolatedModel(width: 240, height: 200).model
        commit(.rectangle(CGRect(x: 110, y: 100, width: 14, height: 10)), to: model, feather: 4)
        let coverage = try bytes(XCTUnwrap(model.selectionPreview)).map { $0[0] }
        let pairing = try BridgePairing(baseUrl: "https://" + UUID().uuidString.lowercased() + ".test", accessToken: "test-only", backend: "mock")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SelectionSubmissionProtocol.self]
        model.pairing = pairing; model.bridge = try BridgeClient(pairing: pairing, configuration: configuration)
        await model.submitGeneration()
        XCTAssertTrue(model.errorMessage?.contains("fixture_upload_stopped") == true, "The fixture stops after the app prepares its actual immutable upload")
        let store = try XCTUnwrap(model.taskStore)
        let prepared = try await store.list(documentID: model.document.id.uuidString.lowercased())
        XCTAssertEqual(prepared.count, 1)
        let submission = try XCTUnwrap(prepared.first)
        let crop = submission.metadata.cropRect
        XCTAssertGreaterThan(crop.x, 0); XCTAssertGreaterThan(crop.y, 0)
        let expected = (crop.y..<(crop.y + crop.height)).flatMap { y in
            (crop.x..<(crop.x + crop.width)).map { x in coverage[y * 240 + x] }
        }
        let uploaded = try RasterImage.decode(submission.maskPNG)
        XCTAssertEqual(uploaded.alphaInfo, .none)
        XCTAssertEqual(uploaded.bitsPerPixel, 8)
        XCTAssertEqual(try bytes(uploaded).map { $0[0] }, expected, "AI receives the same numeric soft mask, without a second feather or gamma conversion")
        try bridgeValidatePNG(submission.maskPNG, size: submission.metadata.inputSize, mask: true)
        XCTAssertTrue(expected.contains { $0 > 0 && $0 < 255 })

        model.commitSelection(try RasterImage.solidMask(width: 240, height: 200, white: false))
        model.errorMessage = nil
        await model.submitGeneration()
        XCTAssertTrue(model.errorMessage?.contains("选区为空") == true)
        let afterEmpty = try await store.list(documentID: model.document.id.uuidString.lowercased())
        XCTAssertEqual(afterEmpty.count, 1, "An explicit black mask must not produce an unrestricted AI request")
    }
}

/// Allows only deterministic capability checks and rejects the upload before any
/// inference. The test inspects the app's persisted upload bytes, never user data.
private final class SelectionSubmissionProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status: Int
        let data: Data
        switch (request.httpMethod, request.url?.path) {
        case ("GET", "/v1/capabilities"):
            status = 200
            data = Data(#"{"protocolVersion":1,"backend":"mock","isSimulation":true,"presets":[{"id":"mock-paint-v1","technique":"simulation","nativeInpainting":false,"maskAppliedToOutput":true}],"maxInputPixels":4194304,"maxImageBytes":20971520,"minInputSide":1,"maxInputAspectRatio":null,"maxSnapshotBytes":67108864,"snapshotFormat":"comp-zip","progressTransport":"polling","cancelSupported":false,"pairingScope":"single-owner-installation","resultAlphaMode":"straight"}"#.utf8)
        case ("GET", "/v1/backend/status"):
            status = 200; data = Data(#"{"ok":true,"backend":"mock","isSimulation":true}"#.utf8)
        case ("POST", "/v1/jobs"):
            status = 503; data = Data(#"{"error":{"code":"fixture_upload_stopped","message":"Synthetic upload captured locally"}}"#.utf8)
        default:
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                                                   headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
