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
        let restored = try await reopened.loadSnapshot(documentID: "document", revision: Int64.max, pairing: pairing())
        XCTAssertEqual(restored?.archive, originalBytes)
        do {
            _ = try await reopened.prepareSnapshot(documentID: "document", revision: Int64.max, archive: Data("changed archive".utf8), pairing: pairing())
            XCTFail("Changed backup bytes must fail")
        } catch { XCTAssertEqual(error as? BridgeError, .submissionConflict) }
        let submissions = try await reopened.list()
        XCTAssertTrue(submissions.isEmpty, "Snapshots must not be interpreted as image jobs")
    }

    func testSnapshotPairingSwitchReusesFrozenBytesAcrossRestartAndLegacyCache() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = SnapshotSwitchProtocol.archive
        let mock = try BridgePairing(baseUrl: "https://mock-backup.test", accessToken: "local-test", backend: "mock")
        let windows = try BridgePairing(baseUrl: "https://windows-backup.test", accessToken: "local-test", backend: "comfyui")
        let movedWindows = try BridgePairing(baseUrl: "https://moved-backup.test", accessToken: "local-test", backend: "comfyui")
        let store = try BridgeSubmissionStore(directory: directory)
        let original = try await store.prepareSnapshot(documentID: "document", revision: 17, archive: archive, pairing: mock)

        // Existing installations have destination fields in their old manifest. Migration
        // must preserve their exact ZIP, even when a different server is selected after restart.
        let folder = directory.appendingPathComponent(".snapshots/document/17")
        let legacy: [String: Any] = ["documentID": "document", "revision": 17, "origin": mock.origin,
                                   "backend": mock.backend, "sha256": bridgeSHA256(archive)]
        try JSONSerialization.data(withJSONObject: legacy).write(to: folder.appendingPathComponent("snapshot.json"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SnapshotSwitchProtocol.self]
        let windowsClient = try BridgeClient(pairing: windows, configuration: configuration)
        do { _ = try await windowsClient.uploadSnapshot(original); XCTFail("Old upload must remain bound to its selected server") }
        catch { XCTAssertEqual(error as? BridgeError, .wrongServer) }

        for destination in [windows, movedWindows, mock] {
            let reopened = try BridgeSubmissionStore(directory: directory)
            let loaded = try await reopened.loadSnapshot(documentID: "document", revision: 17, pairing: destination)
            let upload = try XCTUnwrap(loaded)
            XCTAssertEqual(upload.archive, archive)
            XCTAssertEqual(upload.origin, destination.origin)
            XCTAssertEqual(upload.backend, destination.backend)
            let client = try BridgeClient(pairing: destination, configuration: configuration)
            let receipt = try await client.uploadSnapshot(upload)
            let retry = try await reopened.prepareSnapshot(documentID: "document", revision: 17, archive: archive, pairing: destination)
            let retryReceipt = try await client.uploadSnapshot(retry)
            XCTAssertEqual(receipt, retryReceipt)
            do {
                _ = try await reopened.prepareSnapshot(documentID: "document", revision: 17, archive: Data("repacked bytes".utf8), pairing: destination)
                XCTFail("Changing destination must not permit new bytes for an existing revision")
            } catch { XCTAssertEqual(error as? BridgeError, .submissionConflict) }
            XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("project.comp.zip")), archive)
        }
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

    func testDeletionCapabilityIsOptionalForExistingBridges() throws {
        let legacy = try JSONDecoder().decode(BridgeCapabilities.self, from: BridgeDeletionProtocol.capabilities(supportsDeletion: nil))
        XCTAssertFalse(legacy.jobDeletionSupported)
        let modern = try JSONDecoder().decode(BridgeCapabilities.self, from: BridgeDeletionProtocol.capabilities(supportsDeletion: true))
        XCTAssertTrue(modern.jobDeletionSupported)
    }

    func testDeleteJobValidatesReceiptOriginAndFinishedStateWithoutRequiringGPU() async throws {
        let pairing = try BridgePairing(baseUrl: "https://delete.test", accessToken: "local-test", backend: "mock")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BridgeDeletionProtocol.self]
        let client = try BridgeClient(pairing: pairing, configuration: configuration)
        let job = finishedJob(metadata(), id: "selected-job")
        let receipt = try await client.deleteJob(job, pairing: pairing)
        XCTAssertEqual(receipt.jobID, job.jobId)
        XCTAssertEqual(receipt.origin, pairing.origin)
        XCTAssertEqual(receipt.backend, pairing.backend)
        let retry = try await client.deleteJob(job, pairing: pairing)
        XCTAssertEqual(retry, receipt)

        let otherPairing = try BridgePairing(baseUrl: "https://other.test", accessToken: "local-test", backend: "mock")
        do { _ = try await client.deleteJob(job, pairing: otherPairing); XCTFail("Pairing changes must not redirect deletion") }
        catch { XCTAssertEqual(error as? BridgeError, .wrongServer) }
        for state in [BridgeJobState.queued, .running] {
            do { _ = try await client.deleteJob(finishedJob(metadata(), id: "selected-job", state: state), pairing: pairing); XCTFail("Active jobs cannot be deleted") }
            catch { guard case BridgeError.invalidInput = error else { return XCTFail("Unexpected error: \(error)") } }
        }
    }

    func testDeleteJobRejectsUnsupportedOrUnconfirmedDeletion() async throws {
        for host in ["legacy-delete.test", "wrong-delete.test", "false-delete.test", "incomplete-delete.test"] {
            let pairing = try BridgePairing(baseUrl: "https://" + host, accessToken: "local-test", backend: "mock")
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [BridgeDeletionProtocol.self]
            let client = try BridgeClient(pairing: pairing, configuration: configuration)
            do { _ = try await client.deleteJob(finishedJob(metadata(), id: "selected-job"), pairing: pairing); XCTFail("Unconfirmed removal accepted") }
            catch {
                switch host {
                case "legacy-delete.test": guard case BridgeError.incompatibleServer = error else { return XCTFail("Unexpected error: \(error)") }
                case "incomplete-delete.test": XCTAssertEqual(error as? BridgeError, .http(503, "job_deletion_incomplete", "Retry deletion"))
                default: guard case BridgeError.invalidResponse = error else { return XCTFail("Unexpected error: \(error)") }
                }
            }
        }
    }

    func testLocalCandidateRemovalReclaimsInputsAndStaysHiddenAfterRestart() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try BridgeSubmissionStore(directory: directory)
        let pair = try pairing(), files = try inputFiles(), meta = metadata()
        _ = try await store.prepare(metadata: meta, imagePNG: files.image, maskPNG: files.mask, pairing: pair)
        let job = finishedJob(meta)
        _ = try await store.record(job: job, for: meta.clientRequestId)
        let pending = metadata()
        _ = try await store.prepare(metadata: pending, imagePNG: files.image, maskPNG: files.mask, pairing: pair)
        let archive = Data("keep this project backup".utf8)
        _ = try await store.prepareSnapshot(documentID: meta.documentId, revision: 7, archive: archive, pairing: pair)

        try await store.removeCompletedJob(job, pairing: pair)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(meta.clientRequestId).path))
        let reopened = try BridgeSubmissionStore(directory: directory)
        let hidden = try await reopened.hiddenJobIDs(documentID: meta.documentId, pairing: pair)
        XCTAssertEqual(hidden, [job.jobId])
        let submissions = try await reopened.list()
        XCTAssertEqual(submissions.map(\.metadata.clientRequestId), [pending.clientRequestId])
        let backup = try await reopened.loadSnapshot(documentID: meta.documentId, revision: 7, pairing: pair)
        XCTAssertEqual(backup?.archive, archive)
        do { _ = try await reopened.prepare(metadata: meta, imagePNG: files.image, maskPNG: files.mask, pairing: pair); XCTFail("Removed task must not be resubmitted") }
        catch { XCTAssertEqual(error as? BridgeError, .jobRemoved) }
        do { _ = try await reopened.load(requestID: meta.clientRequestId); XCTFail("Removed input must not recover") }
        catch { XCTAssertEqual(error as? BridgeError, .jobRemoved) }

        let otherPair = try BridgePairing(baseUrl: "https://other.test", accessToken: "local-test", backend: "mock")
        let otherBackend = try BridgePairing(baseUrl: pair.baseUrl, accessToken: "local-test", backend: "comfyui")
        let otherServerHidden = try await reopened.hiddenJobIDs(documentID: meta.documentId, pairing: otherPair)
        let otherBackendHidden = try await reopened.hiddenJobIDs(documentID: meta.documentId, pairing: otherBackend)
        let otherDocumentHidden = try await reopened.hiddenJobIDs(documentID: pending.documentId, pairing: pair)
        XCTAssertTrue(otherServerHidden.isEmpty); XCTAssertTrue(otherBackendHidden.isEmpty); XCTAssertTrue(otherDocumentHidden.isEmpty)
        let index = try Data(contentsOf: directory.appendingPathComponent(".removed-jobs.json"))
        XCTAssertLessThan(index.count, 1024)
        XCTAssertFalse(String(decoding: index, as: UTF8.self).contains("local-test"))
        XCTAssertTrue(String(decoding: index, as: UTF8.self).contains("\"deletedOnServer\":false"))
    }

    func testCandidateRemovalRejectsUnknownActiveOrMismatchedLocalTasks() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try BridgeSubmissionStore(directory: directory)
        let pair = try pairing(), files = try inputFiles(), meta = metadata()
        _ = try await store.prepare(metadata: meta, imagePNG: files.image, maskPNG: files.mask, pairing: pair)
        let job = finishedJob(meta)
        do { try await store.removeCompletedJob(job, pairing: pair); XCTFail("Unacknowledged upload must be preserved") } catch { }
        _ = try await store.record(job: finishedJob(meta, state: .running), for: meta.clientRequestId)
        do { try await store.removeCompletedJob(finishedJob(meta, state: .running), pairing: pair); XCTFail("Running task must be preserved") } catch { }
        do { try await store.removeCompletedJob(finishedJob(meta, id: "different-job"), pairing: pair); XCTFail("Other job must be preserved") } catch { }
        let other = try BridgePairing(baseUrl: "https://other.test", accessToken: "local-test", backend: "mock")
        do { try await store.removeCompletedJob(job, pairing: other); XCTFail("Other server must be preserved") }
        catch { XCTAssertEqual(error as? BridgeError, .wrongServer) }
        let preserved = try await store.load(requestID: meta.clientRequestId)
        XCTAssertEqual(preserved.imagePNG, files.image)
        XCTAssertEqual(preserved.maskPNG, files.mask)
        XCTAssertEqual(preserved.lastJob?.state, .running)
        let hidden = try await store.hiddenJobIDs(documentID: meta.documentId, pairing: pair)
        XCTAssertTrue(hidden.isEmpty)
    }

    func testRemovalFinishesInterruptedReclamationWithoutRecoveringOldCandidate() async throws {
        let directory = temporaryDirectory(), copy = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: copy) }
        let store = try BridgeSubmissionStore(directory: directory)
        let pair = try pairing(), files = try inputFiles(), meta = metadata(), job = finishedJob(meta)
        _ = try await store.prepare(metadata: meta, imagePNG: files.image, maskPNG: files.mask, pairing: pair)
        _ = try await store.record(job: job, for: meta.clientRequestId)
        let root = directory.appendingPathComponent(meta.clientRequestId)
        try FileManager.default.copyItem(at: root, to: copy)
        try await store.removeCompletedJob(job, pairing: pair)
        // Emulate termination after committing a tombstone, before reclaiming input files.
        try FileManager.default.copyItem(at: copy, to: root)
        try FileManager.default.removeItem(at: root.appendingPathComponent("image.png"))
        let reopened = try BridgeSubmissionStore(directory: directory)
        let recovered = try await reopened.list()
        XCTAssertTrue(recovered.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        // Also cover termination while recursively deleting the renamed payload.
        let reclaimed = directory.appendingPathComponent(".removed-payload-" + meta.clientRequestId)
        try FileManager.default.copyItem(at: copy, to: reclaimed)
        _ = try await reopened.list()
        XCTAssertFalse(FileManager.default.fileExists(atPath: reclaimed.path))
    }

    func testRemoteOnlyAndAcknowledgedServerRemovalRemainDistinct() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try BridgeSubmissionStore(directory: directory)
        let pair = try BridgePairing(baseUrl: "https://delete.test", accessToken: "local-test", backend: "mock")
        let job = finishedJob(metadata(), id: "selected-job", state: .failed)
        try await store.removeCompletedJob(job, pairing: pair)
        let locallyRemoved = try await store.locallyRemovedJobIDs(documentID: job.source.documentId, pairing: pair)
        XCTAssertEqual(locallyRemoved, [job.jobId])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BridgeDeletionProtocol.self]
        let client = try BridgeClient(pairing: pair, configuration: configuration)
        let receipt = try await client.deleteJob(job, pairing: pair)
        let other = try BridgePairing(baseUrl: "https://other.test", accessToken: "local-test", backend: "mock")
        do { try await store.removeCompletedJob(job, pairing: other, serverDeletion: receipt); XCTFail("Receipt cannot authorize cleanup on another server") }
        catch { XCTAssertEqual(error as? BridgeError, .wrongServer) }
        try await store.removeCompletedJob(job, pairing: pair, serverDeletion: receipt)
        try await store.removeCompletedJob(job, pairing: pair)
        let hidden = try await store.hiddenJobIDs(documentID: job.source.documentId, pairing: pair)
        XCTAssertEqual(hidden, [job.jobId])
        let index = try Data(contentsOf: directory.appendingPathComponent(".removed-jobs.json"))
        XCTAssertTrue(String(decoding: index, as: UTF8.self).contains("\"deletedOnServer\":true"))
        let stillLocal = try await store.locallyRemovedJobIDs(documentID: job.source.documentId, pairing: pair)
        XCTAssertTrue(stillLocal.isEmpty)
    }

    func testRecoverySummariesFilterBeforeValidationAndNeverReadOriginalPNGs() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try BridgeSubmissionStore(directory: directory)
        let pair = try pairing(), files = try inputFiles(), meta = metadata()
        let otherDoc = metadata()
        let otherPair = try BridgePairing(baseUrl: "https://other.test", accessToken: "local-test", backend: "mock")
        let otherServerMeta = metadata(documentID: meta.documentId)
        for (metadata, pairing) in [(meta, pair), (otherDoc, pair), (otherServerMeta, otherPair)] {
            _ = try await store.prepare(metadata: metadata, imagePNG: files.image, maskPNG: files.mask, pairing: pairing)
        }
        let selectedFolder = directory.appendingPathComponent(meta.clientRequestId)
        try FileManager.default.removeItem(at: selectedFolder.appendingPathComponent("image.png"))
        try FileManager.default.removeItem(at: selectedFolder.appendingPathComponent("mask.png"))
        // An unrelated document's manifest isn't even decoded. Another pairing's
        // metadata digest is not validated while polling the selected server.
        try Data("unrelated manifest".utf8).write(to: directory.appendingPathComponent(otherDoc.clientRequestId).appendingPathComponent("submission.json"))
        let otherFile = directory.appendingPathComponent(otherServerMeta.clientRequestId).appendingPathComponent("submission.json")
        var otherManifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: otherFile)) as? [String: Any])
        otherManifest["metadataSHA256"] = "unrelated digest"
        try JSONSerialization.data(withJSONObject: otherManifest).write(to: otherFile)

        let first = try await store.listSummaries(documentID: meta.documentId, pairing: pair)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first.first?.metadata, meta)
        XCTAssertNil(first.first?.jobID)
        let job = finishedJob(meta)
        let recorded = try await store.record(job: job, for: meta.clientRequestId)
        XCTAssertEqual(recorded.lastJob, job)
        let summaries = try await store.listSummaries(documentID: meta.documentId, pairing: pair)
        XCTAssertEqual(summaries.first?.lastJob, job)
        do { _ = try await store.load(requestID: meta.clientRequestId); XCTFail("Only explicit upload loading should read missing PNGs") } catch { }

        let file = selectedFolder.appendingPathComponent("metadata.json")
        var altered = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        altered["prompt"] = "tampered selected metadata"
        try JSONSerialization.data(withJSONObject: altered).write(to: file)
        do { _ = try await store.listSummaries(documentID: meta.documentId, pairing: pair); XCTFail("Selected metadata must still be verified") }
        catch { XCTAssertEqual(error as? BridgeError, .storageCorrupted) }
    }

    func testPendingServerDeletionSurvivesLostResponseAndClearsOnlyAfterAcknowledgedCleanup() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try BridgeSubmissionStore(directory: directory)
        let pair = try BridgePairing(baseUrl: "https://delete.test", accessToken: "local-test", backend: "mock")
        let files = try inputFiles(), meta = metadata(), job = finishedJob(meta, id: "selected-job")
        _ = try await store.prepare(metadata: meta, imagePNG: files.image, maskPNG: files.mask, pairing: pair)
        _ = try await store.record(job: job, for: meta.clientRequestId)
        try await store.markPendingDeletion(job, pairing: pair)
        try await store.markPendingDeletion(job, pairing: pair)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BridgeDeletionProtocol.self]
        let client = try BridgeClient(pairing: pair, configuration: configuration)
        _ = try await client.deleteJob(job, pairing: pair) // Receipt intentionally lost before local cleanup.
        let reopened = try BridgeSubmissionStore(directory: directory)
        let pending = try await reopened.pendingDeletions(documentID: meta.documentId, pairing: pair)
        XCTAssertEqual(pending, [job])
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent(meta.clientRequestId).appendingPathComponent("image.png")), files.image)
        let privateRecord = try Data(contentsOf: directory.appendingPathComponent(".pending-deletions.json"))
        XCTAssertLessThan(privateRecord.count, 4096)
        XCTAssertFalse(String(decoding: privateRecord, as: UTF8.self).contains("local-test"))
        let other = try BridgePairing(baseUrl: "https://other.test", accessToken: "local-test", backend: "mock")
        let otherServer = try await reopened.pendingDeletions(documentID: meta.documentId, pairing: other)
        let otherDocument = try await reopened.pendingDeletions(documentID: "another-document", pairing: pair)
        XCTAssertTrue(otherServer.isEmpty); XCTAssertTrue(otherDocument.isEmpty)
        try await reopened.clearPendingDeletion(jobID: job.jobId, pairing: other)
        try await reopened.removeCompletedJob(job, pairing: pair) // Local removal does not cancel server deletion intent.
        let stillPending = try await reopened.pendingDeletions(documentID: meta.documentId, pairing: pair)
        XCTAssertEqual(stillPending, [job])
        let receipt = try await client.deleteJob(job, pairing: pair)
        try await reopened.removeCompletedJob(job, pairing: pair, serverDeletion: receipt)
        let finished = try await reopened.pendingDeletions(documentID: meta.documentId, pairing: pair)
        XCTAssertTrue(finished.isEmpty)
    }

    func testPendingDeletionRejectsUnconfirmedTasksAndCanCancelIntentWithoutDeletingFiles() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try BridgeSubmissionStore(directory: directory)
        let pair = try pairing(), files = try inputFiles(), meta = metadata(), job = finishedJob(meta)
        _ = try await store.prepare(metadata: meta, imagePNG: files.image, maskPNG: files.mask, pairing: pair)
        do { try await store.markPendingDeletion(job, pairing: pair); XCTFail("Unknown server identity must stay pending") } catch { }
        _ = try await store.record(job: job, for: meta.clientRequestId)
        do { try await store.markPendingDeletion(finishedJob(meta, state: .running), pairing: pair); XCTFail("Running task cannot be queued for deletion") } catch { }
        try await store.markPendingDeletion(job, pairing: pair)
        try await store.clearPendingDeletion(jobID: job.jobId, pairing: pair)
        let pending = try await store.pendingDeletions(documentID: meta.documentId, pairing: pair)
        XCTAssertTrue(pending.isEmpty)
        let original = try await store.load(requestID: meta.clientRequestId)
        XCTAssertEqual(original.imagePNG, files.image)
        XCTAssertEqual(original.maskPNG, files.mask)
        let hidden = try await store.hiddenJobIDs(documentID: meta.documentId, pairing: pair)
        XCTAssertTrue(hidden.isEmpty)
    }

    func testRestoringLocalRemovalsNeverRestoresDeletedFilesOrPendingServerDeletions() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try BridgeSubmissionStore(directory: directory)
        let pair = try BridgePairing(baseUrl: "https://delete.test", accessToken: "local-test", backend: "mock")
        let otherPair = try BridgePairing(baseUrl: "https://other.test", accessToken: "local-test", backend: "mock")
        let files = try inputFiles(), meta = metadata(), local = finishedJob(meta, id: "local-only")
        let pending = finishedJob(metadata(documentID: meta.documentId), id: "pending-delete")
        let server = finishedJob(metadata(documentID: meta.documentId), id: "selected-job")
        let otherDoc = finishedJob(metadata(), id: "other-document")
        let otherServer = finishedJob(metadata(documentID: meta.documentId), id: "other-server")
        _ = try await store.prepare(metadata: meta, imagePNG: files.image, maskPNG: files.mask, pairing: pair)
        _ = try await store.record(job: local, for: meta.clientRequestId)
        for job in [local, pending, server, otherDoc] { try await store.removeCompletedJob(job, pairing: pair) }
        try await store.removeCompletedJob(otherServer, pairing: otherPair)
        try await store.markPendingDeletion(pending, pairing: pair)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BridgeDeletionProtocol.self]
        let client = try BridgeClient(pairing: pair, configuration: configuration)
        let receipt = try await client.deleteJob(server, pairing: pair)
        try await store.removeCompletedJob(server, pairing: pair, serverDeletion: receipt)

        let restored = try await store.restoreLocalRemovals(documentID: meta.documentId, pairing: pair)
        XCTAssertEqual(restored, [local.jobId])
        let hidden = try await store.hiddenJobIDs(documentID: meta.documentId, pairing: pair)
        XCTAssertEqual(hidden, [pending.jobId, server.jobId])
        let otherDocumentHidden = try await store.hiddenJobIDs(documentID: otherDoc.source.documentId, pairing: pair)
        let otherServerHidden = try await store.hiddenJobIDs(documentID: meta.documentId, pairing: otherPair)
        XCTAssertEqual(otherDocumentHidden, [otherDoc.jobId]); XCTAssertEqual(otherServerHidden, [otherServer.jobId])
        let stillPending = try await store.pendingDeletions(documentID: meta.documentId, pairing: pair)
        XCTAssertEqual(stillPending, [pending])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(meta.clientRequestId).path))
        let reopened = try BridgeSubmissionStore(directory: directory)
        let afterRestart = try await reopened.hiddenJobIDs(documentID: meta.documentId, pairing: pair)
        XCTAssertFalse(afterRestart.contains(local.jobId))
    }

    /// Opt-in, mock-only: deletion is limited to a fresh synthetic task created here.
    func testHTTPDeletesOnlyItsNewSyntheticJobAndKeepsTombstone() async throws {
        guard let path = ProcessInfo.processInfo.environment["COMPOSITOR_MOCK_PAIRING"] else {
            throw XCTSkip("Set COMPOSITOR_MOCK_PAIRING for synthetic job deletion over HTTP")
        }
        let pairing = try BridgePairing.decode(Data(contentsOf: URL(fileURLWithPath: path)))
        guard pairing.backend == "mock" else { throw XCTSkip("Deletion integration never uses a real inference backend") }
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try BridgeSubmissionStore(directory: directory)
        let client = try BridgeClient(pairing: pairing)
        let capabilities = try await client.preflight()
        guard capabilities.jobDeletionSupported else { return XCTFail("Configured mock bridge must support deletion") }
        let files = try inputFiles()
        // Always create a fresh synthetic identity. Never select an existing server
        // job or reuse the normal HTTP test's optional recovery-output directory.
        let metadata = metadata(requestID: UUID().uuidString.lowercased(), preset: "mock-paint-v1", documentID: UUID().uuidString.lowercased())
        let original = try await store.prepare(metadata: metadata, imagePNG: files.image, maskPNG: files.mask, pairing: pairing)
        XCTAssertNil(original.jobID)
        var job = try await client.submit(original, store: store)
        for _ in 0..<100 {
            if job.state == .succeeded || job.state == .failed { break }
            try await Task.sleep(for: .milliseconds(100))
            job = try await client.job(id: job.jobId)
            try await store.record(job: job, for: metadata.clientRequestId)
        }
        guard job.state == .succeeded, job.clientRequestId == metadata.clientRequestId,
              job.source.documentId == metadata.documentId else {
            return XCTFail("Only this test's successful synthetic task may be deleted")
        }
        let result = try XCTUnwrap(job.results.first)
        let downloaded = try await client.download(result: result, job: job)
        XCTAssertFalse(downloaded.isEmpty)
        try await store.markPendingDeletion(job, pairing: pairing)
        let receipt = try await client.deleteJob(job, pairing: pairing)
        try await store.removeCompletedJob(job, pairing: pairing, serverDeletion: receipt)
        let repeated = try await client.deleteJob(job, pairing: pairing)
        XCTAssertEqual(repeated, receipt)
        do { _ = try await client.job(id: job.jobId); XCTFail("Deleted task GET must return 410") }
        catch { assertDeletedHTTP(error) }
        do { _ = try await client.download(result: result, job: job); XCTFail("Deleted result GET must return 410") }
        catch { assertDeletedHTTP(error) }
        do { _ = try await client.submit(original); XCTFail("The original POST must remain a tombstone, never new inference") }
        catch { assertDeletedHTTP(error) }
        let listed = try await client.jobs(documentID: metadata.documentId)
        XCTAssertFalse(listed.contains { $0.jobId == job.jobId })
        let pending = try await store.pendingDeletions(documentID: metadata.documentId, pairing: pairing)
        let hidden = try await store.hiddenJobIDs(documentID: metadata.documentId, pairing: pairing)
        XCTAssertTrue(pending.isEmpty)
        XCTAssertEqual(hidden, [job.jobId])
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(metadata.clientRequestId).path))
        print("Mock HTTP deletion: fresh synthetic job, authenticated DELETE/retry, 410 task/result/original POST, hidden list and local reclamation passed")
    }

    private func assertDeletedHTTP(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        guard case BridgeError.http(410, "job_deleted", _) = error else {
            return XCTFail("Expected 410 job_deleted, received \(error)", file: file, line: line)
        }
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
        let loaded = try await reopened.loadSnapshot(documentID: documentID, revision: revision, pairing: pairing)
        let retry = try await client.uploadSnapshot(XCTUnwrap(loaded))
        XCTAssertEqual(first, retry)
        XCTAssertEqual(first.revision, revision)
        let snapshots = try await client.snapshots(documentID: documentID)
        XCTAssertTrue(snapshots.contains(first))
        let restored = try await client.downloadSnapshot(first)
        XCTAssertEqual(restored, archive)
    }

    private func pairing() throws -> BridgePairing { try .init(baseUrl: "http://127.0.0.1:8190", accessToken: "local-test", backend: "mock") }
    private func finishedJob(_ metadata: BridgeJobMetadata, id: String = "finished-job", state: BridgeJobState = .succeeded) -> BridgeJob {
        .init(jobId: id, clientRequestId: metadata.clientRequestId, state: state, backend: "mock", isSimulation: true,
              createdAt: "2026-10-20T00:00:00Z", updatedAt: "2026-10-20T00:00:01Z",
              source: .init(documentId: metadata.documentId, baseRevision: metadata.baseRevision, sourceLayerIds: metadata.sourceLayerIds,
                            canvasSize: metadata.canvasSize, cropRect: metadata.cropRect, inputSize: metadata.inputSize, colorSpace: metadata.colorSpace),
              workflowPreset: metadata.workflowPreset, error: nil, results: [])
    }
    private func metadata(requestID: String = UUID().uuidString.lowercased(), seed: Int64 = 42, preset: String = "mock-paint-v1", documentID: String = UUID().uuidString.lowercased()) -> BridgeJobMetadata {
        .init(clientRequestId: requestID, documentId: documentID, baseRevision: 9_007_199_254_740_993,
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

/// No network or inference: stand-in backup endpoints verify a destination-bound upload can
/// reach each newly selected service and receive the same immutable archive checksum.
private final class SnapshotSwitchProtocol: URLProtocol {
    static let archive = Data("frozen snapshot version 17".utf8)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let allowed = ["mock-backup.test", "windows-backup.test", "moved-backup.test"]
        let valid = allowed.contains(request.url?.host ?? "") && request.url?.path == "/v1/documents/document/snapshots/17"
            && request.httpMethod == "POST" && request.value(forHTTPHeaderField: "Authorization") == "Bearer local-test"
            && (Int(request.value(forHTTPHeaderField: "Content-Length") ?? "") ?? 0) > Self.archive.count
        let metadata: [String: Any] = ["documentId": "document", "revision": 17, "sha256": bridgeSHA256(Self.archive),
                                       "bytes": Self.archive.count, "createdAt": "2026-10-20T00:00:00Z", "projectVersion": 14]
        let body = try! JSONSerialization.data(withJSONObject: metadata)
        let response = HTTPURLResponse(url: request.url!, statusCode: valid ? 200 : 400, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

/// Every DELETE fixture validates path, method and bearer; no actual jobs are touched.
private final class BridgeDeletionProtocol: URLProtocol {
    static func capabilities(supportsDeletion: Bool?) -> Data {
        let extra = supportsDeletion.map { ",\"jobDeletionSupported\":\($0)" } ?? ""
        return Data("""
        {"protocolVersion":1,"backend":"mock","isSimulation":true,"presets":[{"id":"mock-paint-v1","technique":"simulation","nativeInpainting":false,"maskAppliedToOutput":true}],"maxInputPixels":4194304,"maxImageBytes":20971520,"minInputSide":1,"maxInputAspectRatio":null,"maxSnapshotBytes":67108864,"snapshotFormat":"comp-zip","progressTransport":"polling","cancelSupported":false,"pairingScope":"single-owner-installation","resultAlphaMode":"straight"\(extra)}
        """.utf8)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let host = request.url?.host ?? ""
        var status = 200
        let body: Data
        if request.value(forHTTPHeaderField: "Authorization") != "Bearer local-test" {
            status = 401; body = Data(#"{"error":{"code":"unauthorized","message":"Missing bearer"}}"#.utf8)
        } else if request.url?.path == "/v1/capabilities", request.httpMethod == "GET" {
            body = Self.capabilities(supportsDeletion: host == "legacy-delete.test" ? nil : true)
        } else if request.url?.path == "/v1/jobs/selected-job", request.httpMethod == "DELETE", host != "legacy-delete.test" {
            switch host {
            case "wrong-delete.test": body = Data(#"{"jobId":"another-job","deleted":true}"#.utf8)
            case "false-delete.test": body = Data(#"{"jobId":"selected-job","deleted":false}"#.utf8)
            case "incomplete-delete.test":
                status = 503; body = Data(#"{"error":{"code":"job_deletion_incomplete","message":"Retry deletion"}}"#.utf8)
            default: body = Data(#"{"jobId":"selected-job","deleted":true}"#.utf8)
            }
        } else {
            // In particular, backend/status is unavailable: deleting old candidates
            // must not depend on ComfyUI or invoke inference preflight.
            status = 503; body = Data(#"{"error":{"code":"unavailable","message":"Backend not running"}}"#.utf8)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}
