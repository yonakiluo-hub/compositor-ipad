import XCTest
@testable import CompositorPad

@MainActor
final class AIPresetWorkflowTests: XCTestCase {
    func testDefaultAndUnavailableChoicesRemainExplicit() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.respond("GET /v1/capabilities", data: catalogue())
        fixture.respond("GET /v1/backend/status?presetId=klein", data: status("klein", ok: false))
        await fixture.model.connect()
        XCTAssertEqual(fixture.model.selectedPresetID, "klein")
        XCTAssertEqual(fixture.model.capabilities?.presets.count, 3)
        XCTAssertFalse(fixture.model.canGenerateWithSelectedPreset)
        fixture.model.choosePreset("disabled")
        XCTAssertEqual(fixture.model.selectedPresetID, "klein", "Client cannot enable an experimental combination")
        fixture.model.selectedPresetID = "qwen"
        fixture.respond("GET /v1/backend/status?presetId=qwen", data: status("qwen", ok: true))
        await fixture.model.checkSelectedPreset()
        XCTAssertTrue(fixture.model.canGenerateWithSelectedPreset)
        XCTAssertEqual(fixture.model.presetStatus?.gpuSmoke, "unverified")
        fixture.model.selectedPresetID = "removed"
        await fixture.model.checkSelectedPreset()
        XCTAssertEqual(fixture.model.selectedPresetID, "removed")
        XCTAssertFalse(fixture.model.canGenerateWithSelectedPreset)
        XCTAssertTrue(fixture.model.presetCheckMessage.contains("已从 Windows 移除"))
    }

    func testEarlierAToBToAStatusCannotOverwriteTheLatestCheck() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = fixture.model
        model.capabilities = try JSONDecoder().decode(BridgeCapabilities.self, from: catalogue())
        model.selectedPresetID = "klein"
        let started = expectation(description: "old A status is held")
        fixture.hold("GET /v1/backend/status?presetId=klein") { started.fulfill() }
        let old = Task { await model.checkSelectedPreset() }
        await fulfillment(of: [started], timeout: 3)
        model.selectedPresetID = "qwen"
        fixture.respond("GET /v1/backend/status?presetId=qwen", data: status("qwen", ok: true))
        await model.checkSelectedPreset()
        model.selectedPresetID = "klein"
        fixture.respond("GET /v1/backend/status?presetId=klein", data: status("klein", ok: true))
        await model.checkSelectedPreset()
        fixture.release("GET /v1/backend/status?presetId=klein", data: status("klein", ok: false))
        await old.value
        XCTAssertEqual(model.selectedPresetID, "klein")
        XCTAssertTrue(model.canGenerateWithSelectedPreset)
        XCTAssertFalse(model.isCheckingPresets)
        XCTAssertEqual(model.presetStatus?.ok, true)
    }

    func testPairingReplacementClearsReadinessAndIgnoresOldResponse() async throws {
        let fixture = try Fixture()
        let replacement = try Fixture()
        defer { fixture.remove(); replacement.remove() }
        let model = fixture.model
        model.capabilities = try JSONDecoder().decode(BridgeCapabilities.self, from: catalogue())
        model.selectedPresetID = "klein"
        let started = expectation(description: "old pairing status held")
        fixture.hold("GET /v1/backend/status?presetId=klein") { started.fulfill() }
        let old = Task { await model.checkSelectedPreset() }
        await fulfillment(of: [started], timeout: 3)
        model.pairing = replacement.model.pairing; model.bridge = replacement.model.bridge
        model.resetPresetContext()
        XCTAssertNil(model.capabilities); XCTAssertNil(model.presetStatus)
        XCTAssertFalse(model.canGenerateWithSelectedPreset)
        model.capabilities = try JSONDecoder().decode(BridgeCapabilities.self, from: catalogue())
        model.selectedPresetID = "qwen"
        replacement.respond("GET /v1/backend/status?presetId=qwen", data: status("qwen", ok: false))
        await model.checkSelectedPreset()
        fixture.release("GET /v1/backend/status?presetId=klein", data: status("klein", ok: true))
        await old.value
        XCTAssertEqual(model.selectedPresetID, "qwen")
        XCTAssertFalse(model.canGenerateWithSelectedPreset)
        XCTAssertEqual(model.presetStatus?.presetId, "qwen")
    }

    func testThinEdgeSelectionGetsContextWithoutResizingPixels() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let context = try RasterImage.context(width: 1000, height: 500, gray: true)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 800, y: 0, width: 200, height: 2))
        let crop = try fixture.model.generationCrop(mask: XCTUnwrap(context.makeImage()), selected: true,
            limits: .init(minimumSide: 32, maximumAspectRatio: 4, maximumPixels: 1_048_576))
        XCTAssertEqual(crop.x + crop.width, 1000)
        XCTAssertEqual(crop.y, 0)
        XCTAssertGreaterThanOrEqual(crop.height, Int(ceil(Double(crop.width) / 4)))
        XCTAssertLessThanOrEqual(crop.width * crop.height, 1_048_576)
        XCTAssertThrowsError(try fixture.model.generationCrop(mask: XCTUnwrap(context.makeImage()), selected: false,
            limits: .init(minimumSide: 32, maximumAspectRatio: 4, maximumPixels: 200_000)))
        let tiny = try RasterImage.solidMask(width: 20, height: 20, white: true)
        XCTAssertThrowsError(try fixture.model.generationCrop(mask: tiny, selected: true,
            limits: .init(minimumSide: 32, maximumAspectRatio: 4, maximumPixels: 1_048_576)))
    }

    func testGenerationFreezesPresetAndPromptBeforeNetworkWait() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let model = fixture.model
        model.create(name: "预设冻结测试", width: 64, height: 64)
        model.capabilities = try JSONDecoder().decode(BridgeCapabilities.self, from: catalogue())
        model.selectedPresetID = "klein"
        model.presetStatus = try JSONDecoder().decode(BridgeBackendStatus.self, from: status("klein", ok: true))
        model.prompt = "保留第一版描述"
        fixture.respond("GET /v1/capabilities", data: catalogue())
        let checking = expectation(description: "selected preset preflight")
        fixture.hold("GET /v1/backend/status?presetId=klein") { checking.fulfill() }
        let posting = expectation(description: "frozen snapshot posted")
        fixture.hold("POST /v1/jobs") { posting.fulfill() }
        let submitting = Task { await model.submitGeneration() }
        await fulfillment(of: [checking], timeout: 3)
        model.selectedPresetID = "qwen"; model.prompt = "后来的描述"
        fixture.release("GET /v1/backend/status?presetId=klein", data: status("klein", ok: true))
        await fulfillment(of: [posting], timeout: 3)
        let store = try XCTUnwrap(model.taskStore)
        let saved = try await store.list()
        let submission = try XCTUnwrap(saved.first)
        XCTAssertEqual(submission.metadata.workflowPreset, "klein")
        XCTAssertEqual(submission.metadata.prompt, "保留第一版描述")
        let receipt = job(submission.metadata)
        fixture.respond("GET /v1/jobs", data: try JSONSerialization.data(withJSONObject: ["jobs": []]))
        fixture.respond("GET /v1/jobs/accepted", data: try JSONEncoder().encode(receipt))
        fixture.release("POST /v1/jobs", data: try JSONEncoder().encode(receipt))
        await submitting.value
        model.recoveryTask?.cancel()
        XCTAssertNil(model.errorMessage)
        let reopened = try await store.load(requestID: submission.metadata.clientRequestId)
        XCTAssertEqual(reopened.jobID, "accepted")
        XCTAssertEqual(reopened.metadata, submission.metadata)
    }

    private func catalogue() -> Data {
        Data(#"{"protocolVersion":1,"backend":"comfyui","isSimulation":false,"defaultPreset":"klein","presets":[{"id":"disabled","name":"实验关闭","experimental":true,"enabled":false,"configured":true,"technique":"reference_edit_with_output_mask","nativeInpainting":false,"maskAppliedToOutput":true},{"id":"klein","name":"Klein","enabled":true,"configured":true,"technique":"reference_edit_with_output_mask","nativeInpainting":false,"maskAppliedToOutput":true},{"id":"qwen","name":"Qwen","experimental":true,"enabled":true,"configured":true,"technique":"reference_edit_with_output_mask","nativeInpainting":false,"maskAppliedToOutput":true,"limits":{"minimumInputSide":32,"maximumAspectRatio":4,"maxInputPixels":1048576}}],"maxInputPixels":4194304,"maxImageBytes":20971520,"minInputSide":16,"maxInputAspectRatio":16,"maxSnapshotBytes":67108864,"snapshotFormat":"comp-zip","progressTransport":"polling","cancelSupported":false,"pairingScope":"single-owner-installation","resultAlphaMode":"straight"}"#.utf8)
    }
    private func status(_ id: String, ok: Bool) -> Data {
        Data("""
        {"ok":\(ok),"backend":"comfyui","isSimulation":false,"presetId":"\(id)","installed":\(ok),"structuralPreflight":\(ok),"gpuSmoke":"unverified","qualityAdmission":"pending"}
        """.utf8)
    }
    private func job(_ meta: BridgeJobMetadata) -> BridgeJob {
        .init(jobId: "accepted", clientRequestId: meta.clientRequestId, state: .failed, backend: "comfyui", isSimulation: false,
            createdAt: "2026-10-21T00:00:00Z", updatedAt: "2026-10-21T00:00:00Z",
            source: .init(documentId: meta.documentId, baseRevision: meta.baseRevision, sourceLayerIds: meta.sourceLayerIds,
                canvasSize: meta.canvasSize, cropRect: meta.cropRect, inputSize: meta.inputSize, colorSpace: meta.colorSpace),
            workflowPreset: meta.workflowPreset, error: .init(code: "synthetic", message: "fixture finished"), results: [])
    }

    @MainActor
    private struct Fixture {
        let root: URL
        let model: EditorModel
        let host: String
        let preferences: UserDefaults
        let suite: String
        init() throws {
            suite = "PresetWorkflowTests." + UUID().uuidString
            preferences = UserDefaults(suiteName: suite)!
            root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
            model = EditorModel(documentsURL: root.appendingPathComponent("Documents"), supportURL: root.appendingPathComponent("Support"),
                                preferences: preferences, loadPairing: false)
            host = UUID().uuidString.lowercased() + ".test"
            let pairing = try BridgePairing(baseUrl: "https://" + host, accessToken: "local-test", backend: "comfyui")
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [PresetWorkflowProtocol.self]
            model.pairing = pairing; model.bridge = try BridgeClient(pairing: pairing, configuration: config)
            respond("GET /v1/jobs", data: Data(#"{"jobs":[]}"#.utf8))
        }
        func respond(_ key: String, data: Data) { PresetWorkflowProtocol.respond(host, key, data) }
        func hold(_ key: String, onStart: @escaping () -> Void) { PresetWorkflowProtocol.hold(host, key, onStart) }
        func release(_ key: String, data: Data) { PresetWorkflowProtocol.release(host, key, data) }
        func remove() {
            model.suspend(); preferences.removePersistentDomain(forName: suite)
            PresetWorkflowProtocol.remove(host); try? FileManager.default.removeItem(at: root)
        }
    }
}

/// All requests terminate locally. Held responses explicitly exercise request races.
private final class PresetWorkflowProtocol: URLProtocol {
    private enum Route { case response(Data), hold(() -> Void) }
    private static let lock = NSLock()
    private static var routes: [String: [String: Route]] = [:]
    private static var held: [String: [String: PresetWorkflowProtocol]] = [:]
    static func respond(_ host: String, _ key: String, _ data: Data) {
        lock.lock(); defer { lock.unlock() }; routes[host, default: [:]][key] = .response(data)
    }
    static func hold(_ host: String, _ key: String, _ onStart: @escaping () -> Void) {
        lock.lock(); defer { lock.unlock() }; routes[host, default: [:]][key] = .hold(onStart)
    }
    static func release(_ host: String, _ key: String, _ data: Data) {
        lock.lock(); let request = held[host]?.removeValue(forKey: key); lock.unlock()
        request?.finish(data)
    }
    static func remove(_ host: String) {
        lock.lock(); defer { lock.unlock() }; routes.removeValue(forKey: host); held.removeValue(forKey: host)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        // Job recovery sends its normal limit/documentId query, which belongs
        // to the list fixture route. Preserve all other queries, especially presetId.
        let query = request.httpMethod == "GET" && url.path == "/v1/jobs" ? "" : (url.query.map { "?" + $0 } ?? "")
        let key = (request.httpMethod ?? "GET") + " " + url.path + query
        Self.lock.lock(); let route = Self.routes[url.host!]?[key]
        if case .hold = route { Self.held[url.host!, default: [:]][key] = self }
        Self.lock.unlock()
        guard request.value(forHTTPHeaderField: "Authorization") == "Bearer local-test", let route else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        switch route { case .response(let data): finish(data); case .hold(let onStart): onStart() }
    }
    private func finish(_ data: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
