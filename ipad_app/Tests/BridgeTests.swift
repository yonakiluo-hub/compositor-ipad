import XCTest
import CoreGraphics
@testable import CompositorKit

final class BridgeTests: XCTestCase {
    func testPairingRejectsCredentialDestinationsAndHeaderInjection() throws {
        for url in ["https://owner:pass@example.com", "https://example.com/v1", "https://example.com?token=x", "https://example.com#fragment", "file:///tmp/server", "http://example.com:0"] {
            XCTAssertThrowsError(try BridgePairing(baseUrl: url, accessToken: "local-test", backend: "mock"))
        }
        XCTAssertThrowsError(try BridgePairing(baseUrl: "https://example.com", accessToken: "test\r\nInjected: yes", backend: "mock"))
        XCTAssertThrowsError(try BridgePairing.decode(Data(#"{"protocolVersion":2,"baseUrl":"https://example.com","accessToken":"test","backend":"mock"}"#.utf8)))
        XCTAssertEqual(try pairing().origin, "http://127.0.0.1:8190")
        XCTAssertEqual(try BridgePairing(baseUrl: "https://EXAMPLE.COM:443/", accessToken: "test", backend: "mock").origin, "https://example.com")
    }

    func testMetadataPreservesInt64AndChecksCrop() throws {
        let original = metadata(seed: Int64.max)
        let data = try bridgeJSON(original)
        let decoded = try JSONDecoder().decode(BridgeJobMetadata.self, from: data)
        XCTAssertEqual(decoded.seed, Int64.max)
        XCTAssertEqual(decoded.baseRevision, 9_007_199_254_740_993)
        try decoded.validate()
        let invalid = BridgeJobMetadata(documentId: "document", baseRevision: 0, sourceLayerIds: [], canvasSize: .init(width: 40, height: 40), cropRect: .init(x: Int.max, y: 0, width: 10, height: 10), workflowPreset: "mock-paint-v1", prompt: "", seed: 0)
        XCTAssertThrowsError(try invalid.validate())
    }

    func testDurableSubmissionPreservesBytesAndRejectsChangedRetry() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try BridgeSubmissionStore(directory: directory)
        let files = try inputFiles()
        let original = metadata()
        _ = try await store.prepare(metadata: original, imagePNG: files.image, maskPNG: files.mask, pairing: pairing())
        let reopened = try BridgeSubmissionStore(directory: directory)
        let loaded = try await reopened.load(requestID: original.clientRequestId)
        XCTAssertEqual(loaded.imagePNG, files.image); XCTAssertEqual(loaded.maskPNG, files.mask)
        XCTAssertEqual(loaded.metadata, original)
        let changed = metadata(requestID: original.clientRequestId, seed: 5)
        do {
            _ = try await reopened.prepare(metadata: changed, imagePNG: files.image, maskPNG: files.mask, pairing: pairing())
            XCTFail("Changed retries must fail")
        } catch { XCTAssertEqual(error as? BridgeError, .submissionConflict) }
        try Data("corrupt".utf8).write(to: directory.appendingPathComponent(original.clientRequestId).appendingPathComponent("image.png"))
        do { _ = try await reopened.load(requestID: original.clientRequestId); XCTFail("Tampering must fail") }
        catch { XCTAssertEqual(error as? BridgeError, .storageCorrupted) }
    }

    func testImmutableSnapshotSurvivesRestartAndDetectsChangedArchive() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try BridgeSubmissionStore(directory: directory)
        let originalBytes = Data("original immutable archive".utf8)
        _ = try await store.prepareSnapshot(documentID: "document", revision: Int64.max, archive: originalBytes, pairing: pairing())
        let reopened = try BridgeSubmissionStore(directory: directory)
        let restored = try await reopened.loadSnapshot(documentID: "document", revision: Int64.max)
        XCTAssertEqual(restored?.archive, originalBytes)
        do {
            _ = try await reopened.prepareSnapshot(documentID: "document", revision: Int64.max, archive: Data("changed archive".utf8), pairing: pairing())
            XCTFail("Changed backup bytes must fail")
        } catch { XCTAssertEqual(error as? BridgeError, .submissionConflict) }
        let submissions = try await reopened.list()
        XCTAssertTrue(submissions.isEmpty, "Snapshots must not be interpreted as image jobs")
    }

    func testPNGMaskAndMultipartConventions() throws {
        let files = try inputFiles()
        try bridgeValidatePNG(files.image, size: .init(width: 32, height: 24), mask: false)
        try bridgeValidatePNG(files.mask, size: .init(width: 32, height: 24), mask: true)
        XCTAssertThrowsError(try bridgeValidatePNG(files.image, size: .init(width: 32, height: 24), mask: true))
        XCTAssertThrowsError(try bridgeValidatePNG(files.mask, size: .init(width: 31, height: 24), mask: true))
        let multipart = try BridgeMultipart(parts: [.init(name: "metadata", filename: nil, mime: "application/json", data: try bridgeJSON(metadata())), .init(name: "mask", filename: "mask.png", mime: "image/png", data: files.mask)])
        defer { multipart.remove() }
        let body = try Data(contentsOf: multipart.file)
        XCTAssertEqual(body.count, multipart.byteCount)
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"metadata\"\r\n"))
        XCTAssertFalse(text.contains("name=\"metadata\"; filename="))
        XCTAssertTrue(text.contains("name=\"mask\"; filename=\"mask.png\""))
    }

    func testDecodedCroppedMaskKeepsNumericCoverageWithoutICC() throws {
        // Reproduce the UI route: saved selection -> decode -> crop -> PNG upload.
        // ImageIO assigns a gray profile on decode and can emit iCCP when re-encoding.
        let files = try inputFiles()
        let decoded = try RasterImage.decode(files.mask)
        let cropped = try XCTUnwrap(decoded.cropping(to: CGRect(x: 8, y: 5, width: 16, height: 12)))
        let encoded = try RasterImage.png(cropped)
        try bridgeValidatePNG(encoded, size: .init(width: 16, height: 12), mask: true)
        let reopened = try RasterImage.decode(encoded)
        XCTAssertEqual(reopened.bitsPerComponent, 8)
        XCTAssertEqual(reopened.bitsPerPixel, 8)
        XCTAssertEqual(reopened.alphaInfo, .none)
        let samples = try XCTUnwrap(reopened.dataProvider?.data) as Data
        XCTAssertEqual(samples[0], 0)
        XCTAssertEqual(samples[4], 128)
        XCTAssertEqual(samples[14], 255)
    }

    func testServerPathsCannotLeakBearer() async throws {
        let client = try BridgeClient(pairing: pairing())
        for path in ["https://example.com/v1/jobs", "//example.com/v1/jobs", "/v1/../health", "/v1/%2e%2e/health", "/v1/jobs?redirect=foo", "/v1/\\evil"] {
            do { _ = try await client.request(path); XCTFail("Unsafe path accepted") } catch { }
        }
        let request = try await client.request("/v1/jobs", query: [.init(name: "documentId", value: "document")])
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer local-test")
        XCTAssertFalse(request.url!.absoluteString.contains("local-test"))
    }

    func testBackendReadinessMustInspectOKAndNeverSwitchModes() async throws {
        for host in ["unready.test", "mismatch.test"] {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [BridgeTestProtocol.self]
            let client = try BridgeClient(pairing: .init(baseUrl: "https://" + host, accessToken: "local-test", backend: "mock"), configuration: configuration)
            do { _ = try await client.preflight(); XCTFail("Unready or mismatched backend accepted") }
            catch { guard case BridgeError.incompatibleServer = error else { return XCTFail("Unexpected error: \(error)") } }
        }
    }

    func testHTTPErrorPreservesAuthenticationFailure() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BridgeTestProtocol.self]
        let client = try BridgeClient(pairing: .init(baseUrl: "https://unauthorized.test", accessToken: "local-test", backend: "mock"), configuration: configuration)
        do { _ = try await client.preflight(); XCTFail("Unauthorized response accepted") }
        catch { XCTAssertEqual(error as? BridgeError, .http(401, "unauthorized", "Pair this device first")) }
    }

    /// Opt-in because ordinary unit tests never start a service or inference.
    /// Pairing stays private. A real GPU run additionally requires COMPOSITOR_ALLOW_REAL=1.
    /// Set COMPOSITOR_HTTP_OUTPUT to reuse durable bytes after an interrupted test.
    func testHTTPRoundTripAndRecovery() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["COMPOSITOR_PAIRING"] ?? environment["COMPOSITOR_MOCK_PAIRING"] else { throw XCTSkip("Set COMPOSITOR_PAIRING to run the existing bridge HTTP integration") }
        let pairing = try BridgePairing.decode(Data(contentsOf: URL(fileURLWithPath: path)))
        guard pairing.backend == "mock" || environment["COMPOSITOR_ALLOW_REAL"] == "1" else { throw XCTSkip("Real inference requires explicit COMPOSITOR_ALLOW_REAL=1") }
        let directory = environment["COMPOSITOR_HTTP_OUTPUT"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? temporaryDirectory()
        var completed = false
        defer { if completed && environment["COMPOSITOR_HTTP_OUTPUT"] == nil { try? FileManager.default.removeItem(at: directory) } }
        let store = try BridgeSubmissionStore(directory: directory)
        let client = try BridgeClient(pairing: pairing)
        let capabilities = try await client.preflight()
        XCTAssertEqual(capabilities.isSimulation, pairing.backend == "mock")
        let files = try inputFiles()
        let stored = try await store.list()
        let submission: BridgeSubmission
        if let existing = stored.first { submission = existing }
        else {
            let meta = metadata(preset: try XCTUnwrap(capabilities.presets.first).id)
            // Exercise the same saved-selection decode/crop/re-encode path as the iPad UI.
            let decodedMask = try RasterImage.decode(files.mask)
            let croppedMask = try XCTUnwrap(decodedMask.cropping(to: CGRect(x: 0, y: 0, width: 32, height: 24)))
            let maskPNG = try RasterImage.png(croppedMask)
            submission = try await store.prepare(metadata: meta, imagePNG: files.image, maskPNG: maskPNG, pairing: pairing)
        }
        let meta = submission.metadata
        // Lose the first receipt on purpose: retry the original PNG bytes and request ID.
        let first = try await client.submit(submission)
        let reopened = try BridgeSubmissionStore(directory: directory)
        let recovered = try await reopened.load(requestID: meta.clientRequestId)
        var job = try await client.submit(recovered, store: reopened)
        XCTAssertEqual(first.jobId, job.jobId)
        let afterReceipt = try await reopened.load(requestID: meta.clientRequestId)
        XCTAssertEqual(afterReceipt.jobID, job.jobId)
        let listed = try await client.jobs(documentID: meta.documentId)
        XCTAssertTrue(listed.contains(where: { $0.jobId == job.jobId }))
        for _ in 0..<900 {
            if job.state == .succeeded || job.state == .failed { break }
            try await Task.sleep(nanoseconds: 1_000_000_000)
            job = try await client.job(id: job.jobId)
            try await reopened.record(job: job, for: meta.clientRequestId)
        }
        XCTAssertEqual(job.state, .succeeded, job.error?.message ?? "")
        let result = try XCTUnwrap(job.results.first)
        XCTAssertEqual(result.cropRect, meta.cropRect)
        let downloaded = try await client.download(result: result, job: job)
        let image = try RasterImage.decode(downloaded)
        let context = try RasterImage.context(width: image.width, height: image.height)
        RasterImage.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), context: context)
        let pixels = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
        XCTAssertEqual(pixels[3], 0, "Black mask must preserve the original through zero alpha")
        XCTAssertEqual(pixels[12 * 4 + 3], 128, "Gray mask is already applied exactly once")
        XCTAssertEqual(pixels[25 * 4 + 3], 255)
        let persisted = try await reopened.load(requestID: meta.clientRequestId)
        XCTAssertEqual(persisted.lastJob?.state, .succeeded)
        XCTAssertEqual(persisted.imagePNG, submission.imagePNG)
        XCTAssertEqual(persisted.maskPNG, submission.maskPNG)
        // Cross-origin result URLs and altered checksums are rejected before pixels reach the editor.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bridgeJSON(job)) as? [String: Any])
        var results = try XCTUnwrap(object["results"] as? [[String: Any]])
        results[0]["url"] = "https://example.com/steal"; object["results"] = results
        let poisoned = try JSONDecoder().decode(BridgeJob.self, from: JSONSerialization.data(withJSONObject: object))
        do { _ = try await client.download(result: poisoned.results[0], job: poisoned); XCTFail("Unsafe result URL accepted") } catch { }
        results[0]["url"] = result.url; results[0]["sha256"] = String(repeating: "0", count: 64); object["results"] = results
        let damaged = try JSONDecoder().decode(BridgeJob.self, from: JSONSerialization.data(withJSONObject: object))
        do { _ = try await client.download(result: damaged.results[0], job: damaged); XCTFail("Bad digest accepted") }
        catch { XCTAssertEqual(error as? BridgeError, .integrityFailure) }
        completed = true
        print("HTTP backend=\(pairing.backend), isSimulation=\(capabilities.isSimulation): retry identity, persisted recovery, crop placement, 0/128/255 mask alpha, authenticated checksummed download passed")
    }

    func testSnapshotHTTPRoundTrip() async throws {
        guard let path = ProcessInfo.processInfo.environment["COMPOSITOR_MOCK_PAIRING"] else { throw XCTSkip("Set COMPOSITOR_MOCK_PAIRING for the synthetic snapshot HTTP test") }
        let pairing = try BridgePairing.decode(Data(contentsOf: URL(fileURLWithPath: path)))
        guard pairing.backend == "mock" else { throw XCTSkip("Synthetic snapshot tests use the mock backend") }
        let client = try BridgeClient(pairing: pairing)
        // A fixed, stored ZIP with a minimal valid manifest; these exact bytes remain stable on retry.
        let archive = try XCTUnwrap(Data(base64Encoded: "UEsDBBQAAAAAAAAAIVyjGPgeZgAAAGYAAAANAAAAbWFuaWZlc3QuanNvbnsiZm9ybWF0IjoiY29tLmNvbXBvc2l0b3IucHJvamVjdCIsInZlcnNpb24iOjE0LCJkb2N1bWVudElEIjoiYnJpZGdlLXN3aWZ0LXNuYXBzaG90LXRlc3QiLCJsYXllcnMiOltdfVBLAQIUAxQAAAAAAAAAIVyjGPgeZgAAAGYAAAANAAAAAAAAAAAAAACAAQAAAABtYW5pZmVzdC5qc29uUEsFBgAAAAABAAEAOwAAAJEAAAAAAA=="))
        try await verifySnapshot(client: client, pairing: pairing, documentID: "bridge-swift-snapshot-test", revision: Int64.max, archive: archive)
        if let packagePath = ProcessInfo.processInfo.environment["COMPOSITOR_SNAPSHOT_PACKAGE"] {
            let package = URL(fileURLWithPath: packagePath)
            let document = try DocumentStore.load(from: package)
            let exported = try ProjectArchive.zip(contentsOf: package)
            try await verifySnapshot(client: client, pairing: pairing, documentID: document.id.uuidString.lowercased(), revision: document.revision, archive: exported)
            print("Native .comp export: immutable ZIP cache, HTTP upload/retry/list, checksum and exact-byte restore passed")
        }
    }

    private func verifySnapshot(client: BridgeClient, pairing: BridgePairing, documentID: String, revision: Int64, archive: Data) async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try BridgeSubmissionStore(directory: directory)
        let upload = try await store.prepareSnapshot(documentID: documentID, revision: revision, archive: archive, pairing: pairing)
        let first = try await client.uploadSnapshot(upload)
        let reopened = try BridgeSubmissionStore(directory: directory)
        let loaded = try await reopened.loadSnapshot(documentID: documentID, revision: revision)
        let retry = try await client.uploadSnapshot(XCTUnwrap(loaded))
        XCTAssertEqual(first, retry)
        XCTAssertEqual(first.revision, revision)
        let snapshots = try await client.snapshots(documentID: documentID)
        XCTAssertTrue(snapshots.contains(first))
        let restored = try await client.downloadSnapshot(first)
        XCTAssertEqual(restored, archive)
    }

    private func pairing() throws -> BridgePairing { try .init(baseUrl: "http://127.0.0.1:8190", accessToken: "local-test", backend: "mock") }
    private func metadata(requestID: String = UUID().uuidString.lowercased(), seed: Int64 = 42, preset: String = "mock-paint-v1") -> BridgeJobMetadata {
        .init(clientRequestId: requestID, documentId: UUID().uuidString.lowercased(), baseRevision: 9_007_199_254_740_993,
              sourceLayerIds: ["layer-1"], canvasSize: .init(width: 80, height: 60), cropRect: .init(x: 7, y: 5, width: 32, height: 24),
              workflowPreset: preset, prompt: "保持轮廓，尝试丝绸材质和侧面光", seed: seed)
    }
    private func temporaryDirectory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("compositor-tests-" + UUID().uuidString, isDirectory: true) }
    private func inputFiles() throws -> (image: Data, mask: Data) {
        let context = try RasterImage.context(width: 32, height: 24)
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        let mask = try RasterImage.context(width: 32, height: 24, gray: true)
        mask.setFillColor(gray: 0, alpha: 1); mask.fill(CGRect(x: 0, y: 0, width: 10, height: 24))
        mask.setFillColor(gray: 128.0 / 255, alpha: 1); mask.fill(CGRect(x: 10, y: 0, width: 10, height: 24))
        mask.setFillColor(gray: 1, alpha: 1); mask.fill(CGRect(x: 20, y: 0, width: 12, height: 24))
        return (try RasterImage.png(XCTUnwrap(context.makeImage())), try RasterImage.png(XCTUnwrap(mask.makeImage())))
    }
}

/// An in-memory HTTP fixture exercises protocol handling without permitting network access.
private final class BridgeTestProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let unauthorized = request.url?.host == "unauthorized.test"
        let mismatch = request.url?.host == "mismatch.test"
        let body: Data
        if unauthorized { body = Data(#"{"error":{"code":"unauthorized","message":"Pair this device first"}}"#.utf8) }
        else if request.url?.path == "/v1/capabilities" {
            let backend = mismatch ? "comfyui" : "mock"
            body = Data("""
            {"protocolVersion":1,"backend":"\(backend)","isSimulation":true,"presets":[{"id":"mock-paint-v1","technique":"simulation","nativeInpainting":false,"maskAppliedToOutput":true}],"maxInputPixels":4194304,"maxImageBytes":20971520,"minInputSide":1,"maxInputAspectRatio":null,"maxSnapshotBytes":67108864,"snapshotFormat":"comp-zip","progressTransport":"polling","cancelSupported":false,"pairingScope":"single-owner-installation","resultAlphaMode":"straight"}
            """.utf8)
        } else { body = Data(#"{"ok":false,"backend":"mock","isSimulation":true,"missingNodes":["RequiredNode"]}"#.utf8) }
        let response = HTTPURLResponse(url: request.url!, statusCode: unauthorized ? 401 : 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
