import XCTest
@testable import CompositorKit

final class BridgePresetTests: XCTestCase {
    func testLegacyCatalogueKeepsItsOriginalDefaultAndLimits() throws {
        let caps = try decode(catalogue(legacy: true))
        XCTAssertEqual(caps.defaultPresetID, "paint-edit-v1")
        let preset = try XCTUnwrap(caps.presets.first)
        XCTAssertTrue(preset.isAvailable)
        XCTAssertNil(preset.experimental)
        XCTAssertEqual(try caps.inputLimits(for: preset).minimumSide, 16)
        XCTAssertEqual(try caps.inputLimits(for: preset).maximumPixels, 4_194_304)
    }

    func testAdvertisedDefaultSurvivesReorderingAndDisabledExperimentsStayDisabled() throws {
        let caps = try decode(catalogue())
        XCTAssertEqual(caps.presets.first?.id, "qwen-disabled")
        XCTAssertEqual(caps.defaultPresetID, "paint-edit-v1")
        XCTAssertFalse(try XCTUnwrap(caps.preset(id: "qwen-disabled")).isAvailable)
        XCTAssertFalse(try XCTUnwrap(caps.preset(id: "broken")).isAvailable)
        XCTAssertTrue(try XCTUnwrap(caps.preset(id: "qwen-enabled")).isAvailable)
        XCTAssertEqual(caps.preset(id: "qwen-enabled")?.license?.summary, "仅供研究或评估；商业使用需另获模型许可")
        XCTAssertEqual(caps.preset(id: "qwen-enabled")?.qualification?.gpuSmoke, "not_checked")
    }

    func testMalformedDisabledDescriptorDoesNotHideHealthyPresets() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: catalogue()) as? [String: Any])
        var presets = try XCTUnwrap(object["presets"] as? [[String: Any]])
        let index = try XCTUnwrap(presets.firstIndex { $0["id"] as? String == "broken" })
        presets[index]["limits"] = ["minimumInputSide": "bad"]
        presets[index]["license"] = 42
        presets[index]["name"] = ["invalid": true]
        object["presets"] = presets
        let caps = try decode(JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(try XCTUnwrap(caps.preset(id: "paint-edit-v1")).isAvailable)
        XCTAssertFalse(try XCTUnwrap(caps.preset(id: "broken")).isAvailable)
        XCTAssertNil(caps.preset(id: "broken")?.limits)
        XCTAssertEqual(caps.defaultPresetID, "paint-edit-v1")
    }

    func testModelLimitsUseTheStricterGlobalAndPresetConstraints() throws {
        let caps = try decode(catalogue())
        let qwen = try XCTUnwrap(caps.preset(id: "qwen-enabled"))
        let limits = try caps.inputLimits(for: qwen)
        XCTAssertEqual(limits.minimumSide, 32)
        XCTAssertEqual(limits.maximumAspectRatio, 4)
        XCTAssertEqual(limits.maximumPixels, 1_048_576)
        XCTAssertThrowsError(try metadata(preset: qwen.id, width: 31, height: 32).validate(capabilities: caps))
        XCTAssertThrowsError(try metadata(preset: qwen.id, width: 200, height: 32).validate(capabilities: caps))
        XCTAssertThrowsError(try metadata(preset: qwen.id, width: 1200, height: 1000).validate(capabilities: caps))
        XCTAssertNoThrow(try metadata(preset: qwen.id, width: 1024, height: 1024).validate(capabilities: caps))
        XCTAssertThrowsError(try metadata(preset: "qwen-disabled").validate(capabilities: caps))
        XCTAssertThrowsError(try metadata(preset: "broken").validate(capabilities: caps))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: catalogue()) as? [String: Any])
        object["minInputSide"] = 64; object["maxInputPixels"] = 262_144; object["maxInputAspectRatio"] = 2
        let tighter = try decode(JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(try tighter.inputLimits(for: qwen), BridgeInputLimits(minimumSide: 64, maximumAspectRatio: 2, maximumPixels: 262_144))
    }

    func testSelectedStatusUsesQueryChecksOKAndRejectsAnotherPreset() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.respond("GET /v1/capabilities", data: catalogue())
        fixture.respond("GET /v1/backend/status?presetId=qwen-enabled", data: status("qwen-enabled", ok: true))
        fixture.respond("GET /v1/backend/status?presetId=paint-edit-v1", data: status("paint-edit-v1", ok: false))
        let caps = try await fixture.client.capabilities()
        let selected = try await fixture.client.backendStatus(presetID: "qwen-enabled", capabilities: caps)
        XCTAssertTrue(selected.ok)
        XCTAssertEqual(selected.gpuSmoke, "unverified")
        XCTAssertEqual(selected.qualityAdmission, "pending")
        _ = try await fixture.client.preflight(presetID: "qwen-enabled")
        let unavailable = try await fixture.client.backendStatus(presetID: "paint-edit-v1", capabilities: caps)
        XCTAssertFalse(unavailable.ok)
        XCTAssertTrue(try XCTUnwrap(unavailable.problem).contains("missing-model.safetensors"))
        do { _ = try await fixture.client.preflight(); XCTFail("HTTP 200 ok=false is not ready") } catch { }
        fixture.respond("GET /v1/backend/status?presetId=qwen-enabled", data: status("paint-edit-v1", ok: true))
        do { _ = try await fixture.client.backendStatus(presetID: "qwen-enabled", capabilities: caps); XCTFail("Wrong status preset accepted") } catch { }
        XCTAssertTrue(fixture.requests.allSatisfy { !$0.contains("local-test") })
    }

    func testLegacyStatusUsesOriginalEndpoint() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.respond("GET /v1/capabilities", data: catalogue(legacy: true))
        fixture.respond("GET /v1/backend/status", data: status("paint-edit-v1", ok: true))
        _ = try await fixture.client.preflight()
        XCTAssertEqual(fixture.requests, ["GET /v1/capabilities", "GET /v1/backend/status"])
    }

    func testUnacknowledgedReplaySkipsCurrentAvailabilityAndKeepsFrozenPreset() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try BridgeSubmissionStore(directory: directory)
        let meta = metadata(preset: "removed-preset")
        let image = try RasterImage.context(width: 32, height: 32)
        let mask = try RasterImage.solidMask(width: 32, height: 32, white: true)
        let submission = try await store.prepare(metadata: meta, imagePNG: RasterImage.png(XCTUnwrap(image.makeImage())),
                                                 maskPNG: RasterImage.png(mask), pairing: fixture.pairing)
        // No capabilities/status route exists: a current disabled preset or offline
        // backend must not prevent recovering this previously accepted request.
        fixture.respond("POST /v1/jobs", data: try bridgeJSON(job(meta)))
        let receipt = try await fixture.client.submit(submission, store: store)
        XCTAssertEqual(receipt.workflowPreset, "removed-preset")
        XCTAssertEqual(fixture.requests, ["POST /v1/jobs"])
        let persisted = try await store.load(requestID: meta.clientRequestId)
        XCTAssertEqual(persisted.metadataJSON, submission.metadataJSON)
        XCTAssertEqual(persisted.imagePNG, submission.imagePNG)
        XCTAssertEqual(persisted.maskPNG, submission.maskPNG)
    }

    func testQueueFullKeepsTheSameDurableRequestForExplicitRetry() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try BridgeSubmissionStore(directory: directory)
        let meta = metadata(preset: "qwen-enabled")
        let image = try RasterImage.context(width: 32, height: 32)
        let submission = try await store.prepare(metadata: meta, imagePNG: RasterImage.png(XCTUnwrap(image.makeImage())),
            maskPNG: RasterImage.png(RasterImage.solidMask(width: 32, height: 32, white: true)), pairing: fixture.pairing)
        fixture.respond("POST /v1/jobs", code: 429, data: Data(#"{"error":{"code":"queue_full","message":"Wait and retry"}}"#.utf8))
        do { _ = try await fixture.client.submit(submission, store: store); XCTFail("Expected queue limit") }
        catch { XCTAssertEqual(error as? BridgeError, .http(429, "queue_full", "Wait and retry")) }
        let reopened = try BridgeSubmissionStore(directory: directory)
        let retry = try await reopened.load(requestID: meta.clientRequestId)
        XCTAssertNil(retry.jobID)
        XCTAssertEqual(retry.metadataJSON, submission.metadataJSON)
        fixture.respond("POST /v1/jobs", data: try bridgeJSON(job(meta)))
        _ = try await fixture.client.submit(retry, store: reopened)
        XCTAssertEqual(fixture.requests, ["POST /v1/jobs", "POST /v1/jobs"])
    }

    private func decode(_ data: Data) throws -> BridgeCapabilities { try JSONDecoder().decode(BridgeCapabilities.self, from: data) }
    private func metadata(preset: String, width: Int = 32, height: Int = 32) -> BridgeJobMetadata {
        .init(documentId: "document", baseRevision: 5, sourceLayerIds: ["layer"], canvasSize: .init(width: 2048, height: 2048),
              cropRect: .init(x: 0, y: 0, width: width, height: height), workflowPreset: preset, prompt: "保留线稿，上色", seed: 78)
    }
    private func job(_ meta: BridgeJobMetadata) -> BridgeJob {
        .init(jobId: "accepted-job", clientRequestId: meta.clientRequestId, state: .queued, backend: "comfyui", isSimulation: false,
              createdAt: "2026-10-21T00:00:00Z", updatedAt: "2026-10-21T00:00:00Z",
              source: .init(documentId: meta.documentId, baseRevision: meta.baseRevision, sourceLayerIds: meta.sourceLayerIds,
                            canvasSize: meta.canvasSize, cropRect: meta.cropRect, inputSize: meta.inputSize, colorSpace: meta.colorSpace),
              workflowPreset: meta.workflowPreset, error: nil, results: [])
    }
    private func status(_ id: String, ok: Bool) -> Data {
        Data("""
        {"ok":\(ok),"backend":"comfyui","isSimulation":false,"presetId":"\(id)","installed":\(ok),"structuralPreflight":\(ok),"missingModels":\(ok ? "[]" : "[\"missing-model.safetensors\"]"),"gpuSmoke":"unverified","qualityAdmission":"pending"}
        """.utf8)
    }
    private func catalogue(legacy: Bool = false) -> Data {
        let base = #"{"id":"paint-edit-v1","technique":"reference_edit_with_output_mask","nativeInpainting":false,"maskAppliedToOutput":true}"#
        let experiments = #"{"id":"qwen-disabled","technique":"reference_edit_with_output_mask","nativeInpainting":false,"maskAppliedToOutput":true,"enabled":false,"configured":true,"experimental":true},{"id":"broken","technique":"reference_edit_with_output_mask","nativeInpainting":false,"maskAppliedToOutput":true,"enabled":true,"configured":false},{"id":"qwen-enabled","technique":"reference_edit_with_output_mask","nativeInpainting":false,"maskAppliedToOutput":true,"enabled":true,"configured":true,"experimental":true,"limits":{"minimumInputSide":32,"maximumAspectRatio":4,"maxInputPixels":1048576},"license":{"use":"research_or_evaluation_only","commercialLicenseRequired":true},"qualification":{"installed":"not_checked","structuralPreflight":"not_checked","gpuSmoke":"not_checked","qualityAdmission":"pending"}}"#
        return Data("""
        {"protocolVersion":1,"backend":"comfyui","isSimulation":false,\(legacy ? "" : "\"defaultPreset\":\"paint-edit-v1\",")"presets":[\(legacy ? base : experiments + "," + base)],"maxInputPixels":4194304,"maxImageBytes":20971520,"minInputSide":16,"maxInputAspectRatio":16,"maxSnapshotBytes":67108864,"snapshotFormat":"comp-zip","progressTransport":"polling","cancelSupported":false,"pairingScope":"single-owner-installation","resultAlphaMode":"straight"}
        """.utf8)
    }
    private struct Fixture {
        let host: String
        let pairing: BridgePairing
        let client: BridgeClient
        init() throws {
            host = UUID().uuidString.lowercased() + ".test"
            pairing = try BridgePairing(baseUrl: "https://" + host, accessToken: "local-test", backend: "comfyui")
            let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [PresetHTTPProtocol.self]
            client = try BridgeClient(pairing: pairing, configuration: config)
        }
        func respond(_ key: String, code: Int = 200, data: Data) { PresetHTTPProtocol.respond(host, key, code, data) }
        var requests: [String] { PresetHTTPProtocol.requests(host) }
        func remove() { PresetHTTPProtocol.remove(host) }
    }
}

private final class PresetHTTPProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var routes: [String: [String: (Int, Data)]] = [:]
    private static var received: [String: [String]] = [:]
    static func respond(_ host: String, _ key: String, _ code: Int, _ data: Data) {
        lock.lock(); defer { lock.unlock() }; routes[host, default: [:]][key] = (code, data)
    }
    static func requests(_ host: String) -> [String] { lock.lock(); defer { lock.unlock() }; return received[host] ?? [] }
    static func remove(_ host: String) { lock.lock(); defer { lock.unlock() }; routes.removeValue(forKey: host); received.removeValue(forKey: host) }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        let key = (request.httpMethod ?? "GET") + " " + url.path + (url.query.map { "?" + $0 } ?? "")
        Self.lock.lock(); Self.received[url.host!, default: []].append(key)
        let route = Self.routes[url.host!]?[key]; Self.lock.unlock()
        guard request.value(forHTTPHeaderField: "Authorization") == "Bearer local-test", let (code, data) = route else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
