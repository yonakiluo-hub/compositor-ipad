import XCTest
import UIKit
@testable import CompositorPad

final class CandidateManagementTests: XCTestCase {
    @MainActor
    private func isolatedModel() throws -> (model: EditorModel, root: URL, preferences: UserDefaults) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("candidate-tests-" + UUID().uuidString)
        let documents = root.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let suite = "candidate-tests-" + UUID().uuidString
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        let initial = EditorModel.blankDocument(name: "候选管理测试", width: 32, height: 24)
        try DocumentStore.save(initial, to: documents.appendingPathComponent(initial.id.uuidString.lowercased() + ".comp"))
        preferences.set(initial.id.uuidString.lowercased(), forKey: "lastDocument")
        let model = EditorModel(documentsURL: documents, supportURL: root.appendingPathComponent("Support"),
                                preferences: preferences, loadPairing: false)
        addTeardownBlock {
            await MainActor.run {
                model.suspend()
                UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            }
            try? FileManager.default.removeItem(at: root)
        }
        XCTAssertNil(model.errorMessage)
        XCTAssertNil(model.pairing)
        return (model, root, preferences)
    }

    private func pixels(gray: Bool = false) throws -> Data {
        let context = try RasterImage.context(width: 8, height: 6, gray: gray)
        if gray { context.setFillColor(gray: 1, alpha: 1) }
        else { context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 0.75)) }
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        return try RasterImage.png(XCTUnwrap(context.makeImage()))
    }

    private func metadata(_ document: CanvasDocument) -> BridgeJobMetadata {
        .init(documentId: document.id.uuidString.lowercased(), baseRevision: document.revision,
              sourceLayerIds: document.layers.map { $0.id.uuidString.lowercased() },
              canvasSize: .init(width: document.width, height: document.height),
              cropRect: .init(x: 7, y: 5, width: 8, height: 6), workflowPreset: "mock-paint-v1", prompt: "测试", seed: 42)
    }

    private func finishedJob(_ metadata: BridgeJobMetadata, pixels: Data, id: String = "candidate-job") -> BridgeJob {
        let results = ["0", "1"].map { resultID in
            BridgeResult(resultId: resultID, url: "/v1/jobs/\(id)/results/\(resultID)", mimeType: "image/png",
                         width: 8, height: 6, cropRect: metadata.cropRect, colorSpace: "sRGB", alphaMode: "straight",
                         maskApplied: true, sha256: bridgeSHA256(pixels), bytes: pixels.count)
        }
        return .init(jobId: id, clientRequestId: metadata.clientRequestId, state: .succeeded, backend: "mock", isSimulation: true,
                     createdAt: "2026-10-20T00:00:00Z", updatedAt: "2026-10-20T00:00:01Z",
                     source: .init(documentId: metadata.documentId, baseRevision: metadata.baseRevision,
                                   sourceLayerIds: metadata.sourceLayerIds, canvasSize: metadata.canvasSize,
                                   cropRect: metadata.cropRect, inputSize: metadata.inputSize, colorSpace: metadata.colorSpace),
                     workflowPreset: metadata.workflowPreset, error: nil, results: results)
    }

    @MainActor
    private func attachFixtureBridge(to model: EditorModel, jobs: [BridgeJob]) throws -> BridgePairing {
        let host = UUID().uuidString.lowercased() + ".test"
        let pairing = try BridgePairing(baseUrl: "https://" + host, accessToken: "test-only", backend: "mock")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CandidateFixtureProtocol.self]
        let jobData = try bridgeJSON(jobs)
        var response = Data(#"{"jobs":"#.utf8)
        response.append(jobData); response.append(Data("}".utf8))
        CandidateFixtureProtocol.configure(host: host, response: response)
        addTeardownBlock { CandidateFixtureProtocol.remove(host: host) }
        model.pairing = pairing
        model.bridge = try BridgeClient(pairing: pairing, configuration: configuration)
        return pairing
    }

    func testPreviewCacheBoundsAndJobRemovalPreserveNeighboringIDs() {
        var cache = CandidatePreviewCache(byteLimit: 10, countLimit: 2)
        cache["old/0"] = Data(repeating: 1, count: 4)
        cache["middle/0"] = Data(repeating: 2, count: 4)
        cache["new/0"] = Data(repeating: 3, count: 4)
        XCTAssertNil(cache["old/0"])
        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(cache.byteCount, 8)
        cache["new/0"] = Data(repeating: 3, count: 7)
        XCTAssertNil(cache["middle/0"], "Replacing a preview must also enforce the byte budget")
        XCTAssertEqual(cache.byteCount, 7)
        cache["oversized/0"] = Data(repeating: 4, count: 11)
        XCTAssertNil(cache["oversized/0"])
        XCTAssertEqual(cache.byteCount, 7)

        cache.removeAll()
        cache["job/0"] = Data([1])
        cache["job-extra/0"] = Data([2])
        cache.remove(jobID: "job")
        XCTAssertNil(cache["job/0"])
        XCTAssertEqual(cache["job-extra/0"], Data([2]), "Job identity requires a slash boundary")
        cache["job-extra/1"] = Data([3])
        cache.remove(jobID: "job-extra")
        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(cache.byteCount, 0)
        var disabled = CandidatePreviewCache(byteLimit: 10, countLimit: 0)
        disabled["job/0"] = Data([1])
        XCTAssertEqual(disabled.count, 0)
    }

    @MainActor
    func testOldCandidatesNeedExplicitConfirmationAndKeepOriginalLayers() throws {
        let model = try isolatedModel().model
        let data = try pixels()
        let job = finishedJob(metadata(model.document), pixels: data)
        let pairing = try attachFixtureBridge(to: model, jobs: [job])
        model.jobs = [job]
        for result in job.results { model.candidates[model.candidateKey(job, result)] = data }
        let original = model.document
        model.applyCandidate(job, job.results[0], sourcePairing: pairing)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.document.layers.count, original.layers.count + 1)
        let afterFirst = model.document
        XCTAssertNil(model.candidatePlacementProblem(job, job.results[1]), "Version changes alone can be explicitly confirmed")

        model.applyCandidate(job, job.results[1], sourcePairing: pairing)
        XCTAssertEqual(model.document, afterFirst)
        XCTAssertEqual(model.errorMessage, DocumentError.staleRevision.localizedDescription)
        model.errorMessage = nil
        model.applyCandidate(job, job.results[1], sourcePairing: pairing,
                             allowChangedRevision: true, confirmedRevision: afterFirst.revision)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(Array(model.document.layers.dropLast()), afterFirst.layers)
        XCTAssertEqual(model.document.layers.last?.pngData, data)
        XCTAssertEqual(model.document.layers.last?.transform.origin, CGPoint(x: 7, y: 5))
        let inserted = model.document
        model.undo()
        XCTAssertEqual(model.document.layers, afterFirst.layers)
        model.redo()
        XCTAssertEqual(model.document.layers, inserted.layers)
    }

    @MainActor
    func testApplyRejectsPairingSwitchAndEditsAfterConfirmation() throws {
        let model = try isolatedModel().model
        let data = try pixels()
        let job = finishedJob(metadata(model.document), pixels: data)
        let pairing = try attachFixtureBridge(to: model, jobs: [job])
        model.candidates[model.candidateKey(job, job.results[0])] = data
        let original = model.document
        let other = try BridgePairing(baseUrl: "https://other-candidate.test", accessToken: "test-only", backend: "mock")
        model.applyCandidate(job, job.results[0], sourcePairing: other)
        XCTAssertEqual(model.errorMessage, BridgeError.wrongServer.localizedDescription)
        XCTAssertEqual(model.document, original)

        let confirmedRevision = model.document.revision
        model.addLayer()
        let edited = model.document
        model.errorMessage = nil
        model.applyCandidate(job, job.results[0], sourcePairing: pairing,
                             allowChangedRevision: true, confirmedRevision: confirmedRevision)
        XCTAssertEqual(model.errorMessage, DocumentError.staleRevision.localizedDescription)
        XCTAssertEqual(model.document, edited, "A later edit invalidates the earlier confirmation")
        model.edit("改变画布") { $0.width += 1 }
        XCTAssertNotNil(model.candidatePlacementProblem(job, job.results[0]))
    }

    @MainActor
    func testLocalRemovalReclaimsPayloadAndStaysHiddenAfterReopenWithoutChangingArtwork() async throws {
        let fixture = try isolatedModel()
        let model = fixture.model
        let data = try pixels(), mask = try pixels(gray: true)
        let metadata = metadata(model.document)
        let job = finishedJob(metadata, pixels: data)
        let pairing = try attachFixtureBridge(to: model, jobs: [job])
        let store = try XCTUnwrap(model.taskStore)
        _ = try await store.prepare(metadata: metadata, imagePNG: data, maskPNG: mask, pairing: pairing)
        _ = try await store.record(job: job, for: metadata.clientRequestId)
        let payload = fixture.root.appendingPathComponent("Support/BridgeTasks").appendingPathComponent(metadata.clientRequestId)
        XCTAssertTrue(FileManager.default.fileExists(atPath: payload.appendingPathComponent("image.png").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: payload.appendingPathComponent("mask.png").path))
        model.jobs = [job]
        for result in job.results { model.candidates[model.candidateKey(job, result)] = data }
        model.applyCandidate(job, job.results[0], sourcePairing: pairing)
        model.saveNow()
        XCTAssertFalse(model.saveFailed)
        let artwork = model.document
        let saved = try DocumentStore.load(from: model.documentURL)

        await model.removeCandidateJob(job, sourcePairing: pairing, fromServer: false)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.jobs.isEmpty)
        XCTAssertEqual(model.candidates.count, 0)
        XCTAssertTrue(model.hiddenJobIDs.contains(job.jobId))
        XCTAssertFalse(FileManager.default.fileExists(atPath: payload.path), "Input PNGs must be reclaimed, not only hidden")
        let remaining = try await store.list(documentID: metadata.documentId)
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(model.document, artwork)
        XCTAssertEqual(try DocumentStore.load(from: model.documentURL), saved)
        let host = try XCTUnwrap(URL(string: pairing.baseUrl)?.host)
        XCTAssertTrue(CandidateFixtureProtocol.requests(host: host).isEmpty, "Local removal must make no HTTP request")

        let reopened = EditorModel(documentsURL: model.documentsURL, supportURL: fixture.root.appendingPathComponent("Support"),
                                   preferences: fixture.preferences, loadPairing: false)
        defer { reopened.suspend() }
        reopened.pairing = pairing
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CandidateFixtureProtocol.self]
        reopened.bridge = try BridgeClient(pairing: pairing, configuration: configuration)
        // The fixture returns the old job again, as an older server still would.
        await reopened.refreshJobs()
        XCTAssertNil(reopened.errorMessage)
        XCTAssertTrue(reopened.jobs.isEmpty)
        XCTAssertEqual(reopened.candidates.count, 0)
        XCTAssertTrue(reopened.hiddenJobIDs.contains(job.jobId))
        XCTAssertEqual(reopened.document, artwork)
        XCTAssertEqual(CandidateFixtureProtocol.requests(host: host), ["GET /v1/jobs"], "Hidden results must not be downloaded again")
        reopened.accept(job)
        XCTAssertTrue(reopened.jobs.isEmpty, "A late recovery callback cannot restore a removed candidate")
    }

    @MainActor
    func testCancelledPreviewLoadReleasesLoadingStateAndCanRetry() async throws {
        let model = try isolatedModel().model
        let data = try pixels()
        let job = finishedJob(metadata(model.document), pixels: data)
        let pairing = try attachFixtureBridge(to: model, jobs: [job])
        let host = try XCTUnwrap(URL(string: pairing.baseUrl)?.host)
        let result = job.results[0]
        let request = "GET " + result.url
        let key = model.candidateKey(job, result)
        let started = expectation(description: "Preview request reached the suspended fixture")
        CandidateFixtureProtocol.hold(host: host, request: request) { started.fulfill() }
        model.jobs = [job]

        let loading = Task { @MainActor in await model.loadCandidate(job, result) }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertTrue(model.loadingCandidateKeys.contains(key))
        loading.cancel()
        await loading.value
        XCTAssertFalse(model.loadingCandidateKeys.contains(key), "Cancellation must release the load slot in its own context")
        XCTAssertNil(model.candidates[key])

        CandidateFixtureProtocol.respond(host: host, request: request, data: data,
            headers: ["Content-Type": "image/png", "X-Content-SHA256": bridgeSHA256(data)])
        await model.loadCandidate(job, result)
        XCTAssertFalse(model.loadingCandidateKeys.contains(key))
        XCTAssertEqual(model.candidates[key], data)
        XCTAssertEqual(CandidateFixtureProtocol.requests(host: host), [request, request], "Retry must reach the bridge again")
    }

    @MainActor
    func testIncompleteServerDeletionRetainsPendingIntentUntilAcknowledgedAfterReopen() async throws {
        let fixture = try isolatedModel()
        let model = fixture.model
        let data = try pixels()
        let metadata = metadata(model.document)
        let job = finishedJob(metadata, pixels: data)
        let pairing = try attachFixtureBridge(to: model, jobs: [])
        let host = try XCTUnwrap(URL(string: pairing.baseUrl)?.host)
        let deleteRequest = "DELETE /v1/jobs/" + job.jobId
        let capabilities = Data(#"{"protocolVersion":1,"backend":"mock","isSimulation":true,"presets":[{"id":"mock-paint-v1","technique":"simulation","nativeInpainting":false,"maskAppliedToOutput":true}],"maxInputPixels":4194304,"maxImageBytes":20971520,"minInputSide":1,"maxInputAspectRatio":null,"maxSnapshotBytes":67108864,"snapshotFormat":"comp-zip","progressTransport":"polling","cancelSupported":false,"pairingScope":"single-owner-installation","resultAlphaMode":"straight","jobDeletionSupported":true}"#.utf8)
        CandidateFixtureProtocol.respond(host: host, request: "GET /v1/capabilities", data: capabilities)
        CandidateFixtureProtocol.respond(host: host, request: deleteRequest, status: 503,
            data: Data(#"{"error":{"code":"job_deletion_incomplete","message":"Retry deletion"}}"#.utf8))
        let removedResponse = Data(#"{"error":{"code":"job_deleted","message":"Job no longer readable"}}"#.utf8)
        CandidateFixtureProtocol.respond(host: host, request: "GET /v1/jobs/" + job.jobId, status: 410, data: removedResponse)
        CandidateFixtureProtocol.respond(host: host, request: "GET " + job.results[1].url, status: 410, data: removedResponse)

        let store = try XCTUnwrap(model.taskStore)
        _ = try await store.prepare(metadata: metadata, imagePNG: data, maskPNG: pixels(gray: true), pairing: pairing)
        _ = try await store.record(job: job, for: metadata.clientRequestId)
        let payload = fixture.root.appendingPathComponent("Support/BridgeTasks").appendingPathComponent(metadata.clientRequestId)
        model.jobs = [job]
        let firstKey = model.candidateKey(job, job.results[0])
        model.candidates[firstKey] = data
        model.applyCandidate(job, job.results[0], sourcePairing: pairing)
        model.saveNow()
        let artwork = model.document

        await model.removeCandidateJob(job, sourcePairing: pairing, fromServer: true)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.jobs.contains { $0.jobId == job.jobId })
        XCTAssertEqual(model.candidates[firstKey], data)
        XCTAssertFalse(model.hiddenJobIDs.contains(job.jobId))
        XCTAssertFalse(model.removingJobIDs.contains(job.jobId))
        XCTAssertFalse(model.candidateManagementStatus.contains("已删除"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: payload.path))
        let pending = try await store.pendingDeletions(documentID: metadata.documentId, pairing: pairing)
        XCTAssertEqual(pending.map(\.jobId), [job.jobId])

        // A partial cleanup can make GET return 410 before DELETE has confirmed all
        // server files were reclaimed. That response must not complete the intent.
        await model.refreshJobs(retryDeletions: false)
        XCTAssertTrue(CandidateFixtureProtocol.requests(host: host).contains("GET /v1/jobs/" + job.jobId))
        XCTAssertTrue(model.unavailableJobIDs.contains(job.jobId))
        XCTAssertTrue(model.jobs.contains { $0.jobId == job.jobId })
        XCTAssertEqual(model.candidates[firstKey], data)
        XCTAssertFalse(model.hiddenJobIDs.contains(job.jobId))
        XCTAssertFalse(model.candidateManagementStatus.contains("已删除"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: payload.path))
        XCTAssertEqual(model.document, artwork)

        let reopened = EditorModel(documentsURL: model.documentsURL, supportURL: fixture.root.appendingPathComponent("Support"),
                                   preferences: fixture.preferences, loadPairing: false)
        defer { reopened.suspend() }
        let reopenedStore = try XCTUnwrap(reopened.taskStore)
        let persisted = try await reopenedStore.pendingDeletions(documentID: metadata.documentId, pairing: pairing)
        XCTAssertEqual(persisted.map(\.jobId), [job.jobId], "Deletion intent must survive a fresh store and app model")
        reopened.pairing = pairing
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CandidateFixtureProtocol.self]
        reopened.bridge = try BridgeClient(pairing: pairing, configuration: configuration)
        CandidateFixtureProtocol.respond(host: host, request: deleteRequest,
            data: try JSONSerialization.data(withJSONObject: ["jobId": job.jobId, "deleted": true]))
        await reopened.refreshJobs()
        XCTAssertNil(reopened.errorMessage)
        XCTAssertTrue(reopened.jobs.isEmpty)
        XCTAssertTrue(reopened.hiddenJobIDs.contains(job.jobId))
        XCTAssertFalse(FileManager.default.fileExists(atPath: payload.path))
        let remaining = try await reopenedStore.pendingDeletions(documentID: metadata.documentId, pairing: pairing)
        XCTAssertTrue(remaining.isEmpty)
        XCTAssertEqual(reopened.document, artwork)
        XCTAssertEqual(try DocumentStore.load(from: reopened.documentURL), artwork)
        XCTAssertEqual(CandidateFixtureProtocol.requests(host: host).filter { $0 == deleteRequest }.count, 2)
    }
}

/// All fixture requests terminate here; these tests cannot contact a real bridge.
private final class CandidateFixtureProtocol: URLProtocol {
    private enum Route {
        case response(status: Int, data: Data, headers: [String: String])
        case hold(onStart: () -> Void)
    }
    private static let lock = NSLock()
    private static var routes: [String: [String: Route]] = [:]
    private static var received: [String: [String]] = [:]
    static func configure(host: String, response: Data) {
        lock.lock(); defer { lock.unlock() }
        routes[host] = ["GET /v1/jobs": .response(status: 200, data: response, headers: ["Content-Type": "application/json"])]
        received[host] = []
    }
    static func respond(host: String, request: String, status: Int = 200, data: Data,
                        headers: [String: String] = ["Content-Type": "application/json"]) {
        lock.lock(); defer { lock.unlock() }
        routes[host, default: [:]][request] = .response(status: status, data: data, headers: headers)
    }
    static func hold(host: String, request: String, onStart: @escaping () -> Void) {
        lock.lock(); defer { lock.unlock() }
        routes[host, default: [:]][request] = .hold(onStart: onStart)
    }
    static func requests(host: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return received[host] ?? []
    }
    static func remove(host: String) {
        lock.lock(); defer { lock.unlock() }
        routes.removeValue(forKey: host); received.removeValue(forKey: host)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let host = url.host else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        Self.lock.lock()
        let requestKey = (request.httpMethod ?? "") + " " + url.path
        Self.received[host, default: []].append(requestKey)
        let route = Self.routes[host]?[requestKey]
        Self.lock.unlock()
        guard let route else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        switch route {
        case .hold(let onStart): onStart()
        case .response(let status, let data, let headers):
            guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
