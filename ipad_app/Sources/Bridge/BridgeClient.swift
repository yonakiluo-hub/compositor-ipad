import Foundation

private final class BridgeRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    // No authenticated request is forwarded to a redirect target, including same-origin redirects.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public actor BridgeClient {
    public let pairing: BridgePairing
    private let session: URLSession
    private let redirectGuard: BridgeRedirectGuard

    public init(pairing: BridgePairing, configuration: URLSessionConfiguration = .ephemeral) throws {
        try pairing.validate()
        self.pairing = pairing
        let configuration = configuration.copy() as! URLSessionConfiguration
        configuration.urlCache = nil; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 180
        let guardDelegate = BridgeRedirectGuard(); redirectGuard = guardDelegate
        session = URLSession(configuration: configuration, delegate: guardDelegate, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    public func preflight() async throws -> BridgeCapabilities {
        let capabilities: BridgeCapabilities = try await get("/v1/capabilities")
        guard capabilities.protocolVersion == 1, capabilities.backend == pairing.backend,
              capabilities.isSimulation == (pairing.backend == "mock"),
              capabilities.resultAlphaMode == "straight", capabilities.progressTransport == "polling",
              !capabilities.presets.isEmpty, capabilities.presets.allSatisfy({ $0.maskAppliedToOutput }),
              capabilities.maxInputPixels > 0, capabilities.maxImageBytes > 0, capabilities.minInputSide > 0,
              capabilities.maxInputAspectRatio == nil || capabilities.maxInputAspectRatio! > 0 else {
            throw BridgeError.incompatibleServer("后端、预设或透明度约定不一致")
        }
        let status: BridgeBackendStatus = try await get("/v1/backend/status")
        guard status.backend == capabilities.backend, status.isSimulation == capabilities.isSimulation else {
            throw BridgeError.incompatibleServer("服务状态与能力不一致")
        }
        guard status.ok else {
            let missing = (status.missingNodes ?? []) + (status.missingModels ?? []) + (status.invalidInputs ?? [])
            throw BridgeError.incompatibleServer(status.error?.message ?? (missing.isEmpty ? "后端未就绪" : "后端缺项：" + missing.joined(separator: "、")))
        }
        return capabilities
    }

    /// The caller must immediately persist the returned job with store.record(job:for:).
    /// If an upload response is lost, retry this exact durable submission; never create a new ID.
    public func submit(_ submission: BridgeSubmission) async throws -> BridgeJob {
        try checkServer(submission)
        if let jobID = submission.jobID {
            let existing = try await job(id: jobID)
            try validate(existing, submission: submission)
            return existing
        }
        let capabilities = try await preflight()
        try submission.metadata.validate(capabilities: capabilities)
        guard submission.imagePNG.count <= capabilities.maxImageBytes, submission.maskPNG.count <= capabilities.maxImageBytes else {
            throw BridgeError.invalidInput("输入文件超过服务限制")
        }
        let multipart = try BridgeMultipart(parts: [
            .init(name: "metadata", filename: nil, mime: "application/json; charset=utf-8", data: submission.metadataJSON),
            .init(name: "image", filename: "image.png", mime: "image/png", data: submission.imagePNG),
            .init(name: "mask", filename: "mask.png", mime: "image/png", data: submission.maskPNG)
        ])
        defer { multipart.remove() }
        let response: BridgeJob = try await upload("/v1/jobs", multipart: multipart)
        try validate(response, submission: submission)
        return response
    }

    /// Convenience entry point keeps the acknowledged server ID durable before returning to UI.
    public func submit(_ submission: BridgeSubmission, store: BridgeSubmissionStore) async throws -> BridgeJob {
        let response = try await submit(submission)
        try await store.record(job: response, for: submission.metadata.clientRequestId)
        return response
    }

    public func job(id: String) async throws -> BridgeJob {
        try requireID(id)
        let response: BridgeJob = try await get("/v1/jobs/\(id)")
        guard response.jobId == id else { throw BridgeError.invalidResponse("服务返回了另一项任务") }
        try validateBackend(response)
        return response
    }

    public func jobs(documentID: String? = nil) async throws -> [BridgeJob] {
        if let documentID { try requireID(documentID) }
        struct List: Decodable { let jobs: [BridgeJob] }
        var query = [URLQueryItem(name: "limit", value: "100")]
        if let documentID { query.append(URLQueryItem(name: "documentId", value: documentID)) }
        let response: List = try await get("/v1/jobs", query: query)
        for job in response.jobs {
            try validateBackend(job)
            guard documentID == nil || job.source.documentId == documentID else { throw BridgeError.invalidResponse("任务列表的文档不一致") }
        }
        return response.jobs
    }

    /// Only an explicitly selected, finished job can be deleted. Pass the pairing
    /// that supplied the candidate, even if the UI has since selected another server.
    public func deleteJob(_ job: BridgeJob, pairing sourcePairing: BridgePairing) async throws -> BridgeJobDeletion {
        try sourcePairing.validate()
        guard sourcePairing.origin == pairing.origin, sourcePairing.backend == pairing.backend else { throw BridgeError.wrongServer }
        try requireID(job.jobId)
        try validateBackend(job)
        guard job.state == .succeeded || job.state == .failed else { throw BridgeError.invalidInput("生成尚未结束，暂不能删除") }
        // Deletion must also work while the GPU backend is unavailable. Do not call
        // preflight(), which additionally requires a ready inference backend.
        let capabilities: BridgeCapabilities = try await get("/v1/capabilities")
        guard capabilities.protocolVersion == 1, capabilities.backend == pairing.backend,
              capabilities.isSimulation == (pairing.backend == "mock"), capabilities.jobDeletionSupported else {
            throw BridgeError.incompatibleServer("此服务尚不支持删除生成任务，可仅从本机移除")
        }
        var request = try request("/v1/jobs/\(job.jobId)")
        request.httpMethod = "DELETE"
        let (data, response) = try await session.data(for: request)
        try checkHTTP(response, data: data)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 65536 else {
            throw BridgeError.invalidResponse("删除回执状态或大小无效")
        }
        struct Receipt: Decodable { let jobId: String; let deleted: Bool }
        let receipt = try JSONDecoder().decode(Receipt.self, from: data)
        guard receipt.jobId == job.jobId, receipt.deleted else { throw BridgeError.invalidResponse("删除回执与所选任务不一致") }
        return BridgeJobDeletion(jobID: job.jobId, origin: pairing.origin, backend: pairing.backend)
    }

    public func download(result: BridgeResult, job: BridgeJob) async throws -> Data {
        try validateBackend(job)
        try requireID(job.jobId); try requireID(result.resultId)
        let expected = "/v1/jobs/\(job.jobId)/results/\(result.resultId)"
        guard job.state == .succeeded, job.results.contains(result), result.url == expected,
              result.mimeType == "image/png", result.alphaMode == "straight", result.maskApplied,
              result.colorSpace == "sRGB", result.cropRect == job.source.cropRect,
              result.width == job.source.inputSize.width, result.height == job.source.inputSize.height,
              result.width == result.cropRect.width, result.height == result.cropRect.height,
              (1...30000).contains(result.width), (1...30000).contains(result.height),
              result.width * result.height <= 4_194_304,
              result.bytes > 0, result.bytes <= 66 * 1024 * 1024 else {
            throw BridgeError.invalidResponse("候选的路径、尺寸或透明度不符合提交约定")
        }
        let (data, response) = try await session.data(for: request(expected))
        try checkHTTP(response, data: data)
        try verify(data, response: response, digest: result.sha256, byteCount: result.bytes, mime: "image/png")
        try bridgeValidatePNG(data, size: .init(width: result.width, height: result.height), mask: false)
        return data
    }

    public func uploadSnapshot(_ snapshot: BridgeSnapshotUpload) async throws -> BridgeSnapshot {
        guard snapshot.origin == pairing.origin, snapshot.backend == pairing.backend else { throw BridgeError.wrongServer }
        return try await uploadSnapshot(documentID: snapshot.documentID, revision: snapshot.revision, archive: snapshot.archive)
    }

    /// Persist the exact ZIP before invoking; retries must pass those same bytes and revision.
    public func uploadSnapshot(documentID: String, revision: Int64, archive: Data) async throws -> BridgeSnapshot {
        try requireID(documentID)
        guard revision >= 0, !archive.isEmpty, archive.count <= 64 * 1024 * 1024 else { throw BridgeError.invalidInput("备份版本或大小无效") }
        let multipart = try BridgeMultipart(parts: [.init(name: "archive", filename: "project.comp.zip", mime: "application/zip", data: archive)])
        defer { multipart.remove() }
        let snapshot: BridgeSnapshot = try await upload("/v1/documents/\(documentID)/snapshots/\(revision)", multipart: multipart)
        guard snapshot.documentId.lowercased() == documentID.lowercased(), snapshot.revision == revision,
              snapshot.sha256.lowercased() == bridgeSHA256(archive), snapshot.bytes == archive.count else { throw BridgeError.integrityFailure }
        return snapshot
    }

    public func snapshots(documentID: String) async throws -> [BridgeSnapshot] {
        try requireID(documentID)
        struct List: Decodable { let snapshots: [BridgeSnapshot] }
        let response: List = try await get("/v1/documents/\(documentID)/snapshots")
        guard response.snapshots.allSatisfy({ $0.documentId.lowercased() == documentID.lowercased() && $0.revision >= 0 }) else {
            throw BridgeError.invalidResponse("备份文档不一致")
        }
        return response.snapshots
    }

    public func downloadSnapshot(_ snapshot: BridgeSnapshot) async throws -> Data {
        try requireID(snapshot.documentId)
        guard snapshot.revision >= 0, snapshot.bytes > 0, snapshot.bytes <= 64 * 1024 * 1024 else { throw BridgeError.invalidResponse("备份版本或大小无效") }
        let (data, response) = try await session.data(for: request("/v1/documents/\(snapshot.documentId)/snapshots/\(snapshot.revision)"))
        try checkHTTP(response, data: data)
        try verify(data, response: response, digest: snapshot.sha256, byteCount: snapshot.bytes, mime: "application/zip")
        return data
    }

    private func checkServer(_ submission: BridgeSubmission) throws {
        guard submission.origin == pairing.origin, submission.backend == pairing.backend else { throw BridgeError.wrongServer }
    }
    private func validateBackend(_ job: BridgeJob) throws {
        guard job.backend == pairing.backend, job.isSimulation == (pairing.backend == "mock") else { throw BridgeError.incompatibleServer("任务的后端类型发生变化") }
    }
    private func validate(_ job: BridgeJob, submission: BridgeSubmission) throws {
        try validateBackend(job)
        guard bridgeValidID(job.jobId), job.clientRequestId == submission.metadata.clientRequestId,
              job.source.matches(submission.metadata), job.workflowPreset == submission.metadata.workflowPreset else { throw BridgeError.invalidResponse("任务与不可变提交快照不一致") }
    }
    private func requireID(_ id: String) throws { guard bridgeValidID(id) else { throw BridgeError.invalidInput("资源 ID 无效") } }

    // Only literal API paths are allowed. URLs supplied by responses never become credential destinations.
    func request(_ path: String, query: [URLQueryItem] = []) throws -> URLRequest {
        guard path.hasPrefix("/v1/"), !path.contains("%"), !path.contains("\\"), !path.contains("?"),
              !path.contains("#"), !path.contains(".."), !path.contains("//") else { throw BridgeError.invalidResponse("不安全的 API 路径") }
        var parts = URLComponents(string: pairing.origin)!
        parts.path = path; parts.queryItems = query.isEmpty ? nil : query
        guard let url = parts.url else { throw BridgeError.invalidResponse("无效的 API URL") }
        var request = URLRequest(url: url)
        request.setValue("Bearer " + pairing.accessToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        let (data, response) = try await session.data(for: request(path, query: query))
        try checkHTTP(response, data: data)
        guard data.count <= 2 * 1024 * 1024 else { throw BridgeError.invalidResponse("JSON 响应过大") }
        return try JSONDecoder().decode(T.self, from: data)
    }
    private func upload<T: Decodable>(_ path: String, multipart: BridgeMultipart) async throws -> T {
        var request = try request(path)
        request.httpMethod = "POST"
        request.setValue(multipart.contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(String(multipart.byteCount), forHTTPHeaderField: "Content-Length")
        let (data, response) = try await session.upload(for: request, fromFile: multipart.file)
        try checkHTTP(response, data: data)
        guard data.count <= 2 * 1024 * 1024 else { throw BridgeError.invalidResponse("JSON 响应过大") }
        return try JSONDecoder().decode(T.self, from: data)
    }
    private func checkHTTP(_ response: URLResponse, data: Data) throws {
        guard let response = response as? HTTPURLResponse else { throw BridgeError.invalidResponse("非 HTTP 响应") }
        guard (200..<300).contains(response.statusCode) else {
            struct Envelope: Decodable { let error: BridgeServiceError }
            let service = data.count <= 65536 ? try? JSONDecoder().decode(Envelope.self, from: data).error : nil
            throw BridgeError.http(response.statusCode, service?.code ?? "http_error", service?.message ?? "服务拒绝请求")
        }
    }
    private func verify(_ data: Data, response: URLResponse, digest: String, byteCount: Int, mime: String) throws {
        guard let response = response as? HTTPURLResponse, response.mimeType == mime,
              data.count == byteCount, digest.count == 64,
              bridgeSHA256(data) == digest.lowercased(),
              response.value(forHTTPHeaderField: "X-Content-SHA256")?.lowercased() == digest.lowercased() else { throw BridgeError.integrityFailure }
    }
}

struct BridgeMultipart {
    struct Part { let name: String; let filename: String?; let mime: String; let data: Data }
    let file: URL
    let byteCount: Int
    let contentType: String

    init(parts: [Part]) throws {
        let boundary = "Compositor-" + UUID().uuidString
        contentType = "multipart/form-data; boundary=\(boundary)"
        file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".multipart")
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw BridgeError.invalidInput("无法创建上传临时文件") }
        do {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            for part in parts {
                var header = "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(part.name)\""
                if let filename = part.filename { header += "; filename=\"\(filename)\"" }
                header += "\r\nContent-Type: \(part.mime)\r\n\r\n"
                try handle.write(contentsOf: Data(header.utf8))
                try handle.write(contentsOf: part.data)
                try handle.write(contentsOf: Data("\r\n".utf8))
            }
            try handle.write(contentsOf: Data("--\(boundary)--\r\n".utf8))
            byteCount = Int(try handle.offset())
            guard byteCount <= 66 * 1024 * 1024 else { throw BridgeError.invalidInput("上传请求超过 66 MiB") }
        } catch { try? FileManager.default.removeItem(at: file); throw error }
    }
    func remove() { try? FileManager.default.removeItem(at: file) }
}
