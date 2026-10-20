import Foundation
#if canImport(Security)
import Security
#endif

/// Pairing is kept entirely in the device Keychain, never in the document or task archive.
public struct KeychainPairingStore: Sendable {
    private let service: String
    public init(service: String = "com.compositor.ipad.bridge") { self.service = service }

    public func save(_ pairing: BridgePairing) throws {
        try pairing.validate()
        #if canImport(Security)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: "pairing-v1"]
        let attributes: [String: Any] = [kSecValueData as String: try bridgeJSON(pairing),
                                        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let result = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound {
            var insertion = query
            attributes.forEach { insertion[$0.key] = $0.value }
            guard SecItemAdd(insertion as CFDictionary, nil) == errSecSuccess else {
                throw BridgeError.invalidPairing("无法保存到设备钥匙串")
            }
        } else if result != errSecSuccess { throw BridgeError.invalidPairing("无法更新设备钥匙串") }
        #else
        throw BridgeError.invalidPairing("当前平台不支持钥匙串")
        #endif
    }

    public func load() throws -> BridgePairing? {
        #if canImport(Security)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service, kSecAttrAccount as String: "pairing-v1",
                                   kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw BridgeError.invalidPairing("无法读取设备钥匙串") }
        return try BridgePairing.decode(data)
        #else
        return nil
        #endif
    }

    public func remove() throws {
        #if canImport(Security)
        let status = SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: "pairing-v1"] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw BridgeError.invalidPairing("无法删除配对") }
        #endif
    }
}

public struct BridgeSubmission: Sendable {
    public let metadata: BridgeJobMetadata
    public let imagePNG: Data
    public let maskPNG: Data
    public let origin: String
    public let backend: String
    public let jobID: String?
    public let lastJob: BridgeJob?
    // Only the store can create a submission, so it is durable before the client sends it.
    let metadataJSON: Data
}

/// Recovery/status polling needs identities, never the original full-resolution PNGs.
public struct BridgeSubmissionSummary: Sendable {
    public let metadata: BridgeJobMetadata
    public let origin: String
    public let backend: String
    public let jobID: String?
    public let lastJob: BridgeJob?
}

public struct BridgeSnapshotUpload: Sendable {
    public let documentID: String
    public let revision: Int64
    public let archive: Data
    public let origin: String
    public let backend: String
}

/// Immutable image bytes survive failed uploads, lock/unlock and process termination.
/// A sibling directory is atomically renamed before network submission is allowed.
public actor BridgeSubmissionStore {
    private let directory: URL
    private let manager = FileManager.default
    private struct Manifest: Codable {
        let version: Int
        let origin: String
        let backend: String
        let metadataSHA256: String
        let imageSHA256: String
        let maskSHA256: String
        var jobID: String?
        var lastJob: BridgeJob?
    }
    private struct RemovedJob: Codable, Equatable {
        let origin: String
        let backend: String
        let documentID: String
        let requestID: String
        let jobID: String
        var deletedOnServer: Bool
    }
    private struct RemovalIndex: Codable {
        let version: Int
        var jobs: [RemovedJob]
    }
    private struct PendingDeletion: Codable {
        let origin: String
        let backend: String
        let job: BridgeJob
    }
    private struct PendingDeletionIndex: Codable {
        let version: Int
        var jobs: [PendingDeletion]
    }

    public init(directory: URL) throws {
        self.directory = directory
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func prepare(metadata: BridgeJobMetadata, imagePNG: Data, maskPNG: Data,
                        pairing: BridgePairing) throws -> BridgeSubmission {
        try pairing.validate(); try metadata.validate()
        guard !(try removedJobs()).contains(where: {
            $0.origin == pairing.origin && $0.backend == pairing.backend && $0.requestID == metadata.clientRequestId
        }) else { throw BridgeError.jobRemoved }
        guard imagePNG.count <= 20 * 1024 * 1024, maskPNG.count <= 20 * 1024 * 1024 else { throw BridgeError.invalidInput("输入超过 20 MiB") }
        try bridgeValidatePNG(imagePNG, size: metadata.inputSize, mask: false)
        try bridgeValidatePNG(maskPNG, size: metadata.inputSize, mask: true)
        let metadataData = try bridgeJSON(metadata)
        let destination = try folder(metadata.clientRequestId)
        if manager.fileExists(atPath: destination.path) {
            let original = try load(requestID: metadata.clientRequestId)
            guard original.metadataJSON == metadataData, original.imagePNG == imagePNG, original.maskPNG == maskPNG,
                  original.origin == pairing.origin, original.backend == pairing.backend else { throw BridgeError.submissionConflict }
            return original
        }
        let staging = directory.appendingPathComponent(".pending-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        try metadataData.write(to: staging.appendingPathComponent("metadata.json"), options: .atomic)
        try imagePNG.write(to: staging.appendingPathComponent("image.png"), options: .atomic)
        try maskPNG.write(to: staging.appendingPathComponent("mask.png"), options: .atomic)
        let manifest = Manifest(version: 1, origin: pairing.origin, backend: pairing.backend,
                                metadataSHA256: bridgeSHA256(metadataData), imageSHA256: bridgeSHA256(imagePNG),
                                maskSHA256: bridgeSHA256(maskPNG), jobID: nil, lastJob: nil)
        try bridgeJSON(manifest).write(to: staging.appendingPathComponent("submission.json"), options: .atomic)
        try manager.moveItem(at: staging, to: destination)
        return try load(requestID: metadata.clientRequestId)
    }

    public func load(requestID: String) throws -> BridgeSubmission {
        let root = try folder(requestID)
        guard let stored = try readSummary(requestID: requestID) else { throw BridgeError.storageCorrupted }
        let image = try Data(contentsOf: root.appendingPathComponent("image.png"))
        let mask = try Data(contentsOf: root.appendingPathComponent("mask.png"))
        guard bridgeSHA256(image) == stored.manifest.imageSHA256,
              bridgeSHA256(mask) == stored.manifest.maskSHA256 else { throw BridgeError.storageCorrupted }
        let summary = stored.summary
        return BridgeSubmission(metadata: summary.metadata, imagePNG: image, maskPNG: mask, origin: summary.origin,
                                backend: summary.backend, jobID: summary.jobID, lastJob: summary.lastJob, metadataJSON: stored.metadataData)
    }

    private func readSummary(requestID: String, documentID: String? = nil, pairing: BridgePairing? = nil) throws
        -> (summary: BridgeSubmissionSummary, manifest: Manifest, metadataData: Data)? {
        let root = try folder(requestID)
        if !manager.fileExists(atPath: root.path), try removedJobs().contains(where: { $0.requestID == requestID }) { throw BridgeError.jobRemoved }
        let metadataData = try Data(contentsOf: root.appendingPathComponent("metadata.json"))
        let metadata = try JSONDecoder().decode(BridgeJobMetadata.self, from: metadataData)
        if let documentID, metadata.documentId != documentID { return nil }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: root.appendingPathComponent("submission.json")))
        if let pairing, manifest.origin != pairing.origin || manifest.backend != pairing.backend { return nil }
        try metadata.validate()
        guard metadata.clientRequestId == requestID, manifest.version == 1,
              bridgeSHA256(metadataData) == manifest.metadataSHA256,
              manifest.jobID == nil || bridgeValidID(manifest.jobID!),
              manifest.lastJob == nil || (manifest.lastJob!.jobId == manifest.jobID && manifest.lastJob!.clientRequestId == requestID &&
                manifest.lastJob!.source.matches(metadata) && manifest.lastJob!.backend == manifest.backend &&
                manifest.lastJob!.isSimulation == (manifest.backend == "mock") && manifest.lastJob!.workflowPreset == metadata.workflowPreset)
        else { throw BridgeError.storageCorrupted }
        // Check the small identity files first: interruption during file reclamation
        // must not make a removed job look like an upload that needs to be recovered.
        if try removedJobs().contains(where: {
            $0.origin == manifest.origin && $0.backend == manifest.backend && $0.documentID == metadata.documentId &&
            $0.requestID == requestID && $0.jobID == manifest.jobID
        }) { throw BridgeError.jobRemoved }
        return (BridgeSubmissionSummary(metadata: metadata, origin: manifest.origin, backend: manifest.backend,
                                        jobID: manifest.jobID, lastJob: manifest.lastJob), manifest, metadataData)
    }

    @discardableResult
    public func record(job: BridgeJob, for requestID: String) throws -> BridgeSubmissionSummary {
        guard let stored = try readSummary(requestID: requestID) else { throw BridgeError.storageCorrupted }
        let original = stored.summary
        guard job.clientRequestId == requestID, job.source.matches(original.metadata), job.backend == original.backend,
              job.isSimulation == (original.backend == "mock"),
              job.workflowPreset == original.metadata.workflowPreset, bridgeValidID(job.jobId),
              original.jobID == nil || original.jobID == job.jobId else { throw BridgeError.invalidResponse("任务与本地快照不一致") }
        let file = try folder(requestID).appendingPathComponent("submission.json")
        var manifest = stored.manifest
        manifest.jobID = job.jobId; manifest.lastJob = job
        try bridgeJSON(manifest).write(to: file, options: .atomic)
        return BridgeSubmissionSummary(metadata: original.metadata, origin: original.origin, backend: original.backend, jobID: job.jobId, lastJob: job)
    }

    public func listSummaries(documentID: String, pairing: BridgePairing) throws -> [BridgeSubmissionSummary] {
        try pairing.validate()
        guard bridgeValidID(documentID) else { throw BridgeError.invalidInput("文档 ID 无效") }
        try cleanupRemovedPayloads()
        let entries = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        var summaries: [BridgeSubmissionSummary] = []
        for entry in entries where try entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
            do {
                if let stored = try readSummary(requestID: entry.lastPathComponent, documentID: documentID, pairing: pairing) {
                    summaries.append(stored.summary)
                }
            } catch BridgeError.jobRemoved {
                try reclaimPayload(requestID: entry.lastPathComponent)
            }
        }
        return summaries.sorted { $0.metadata.clientRequestId < $1.metadata.clientRequestId }
    }

    private func cleanupRemovedPayloads() throws {
        for removed in try removedJobs() {
            let reclaimed = removedPayloadFolder(requestID: removed.requestID)
            if manager.fileExists(atPath: reclaimed.path) { try manager.removeItem(at: reclaimed) }
        }
    }

    public func list(documentID: String? = nil) throws -> [BridgeSubmission] {
        try cleanupRemovedPayloads()
        let entries = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        var submissions: [BridgeSubmission] = []
        for entry in entries where try entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
            do {
                let submission = try load(requestID: entry.lastPathComponent)
                if documentID == nil || submission.metadata.documentId == documentID { submissions.append(submission) }
            } catch BridgeError.jobRemoved {
                // Finish cleanup if the process stopped after the durable tombstone.
                try reclaimPayload(requestID: entry.lastPathComponent)
            }
        }
        return submissions.sorted { $0.metadata.clientRequestId < $1.metadata.clientRequestId }
    }

    /// Apply to remote job lists before showing candidates or scheduling recovery.
    /// Local-only removals stay hidden after refresh/relaunch, including old bridges
    /// that cannot reclaim their server-side files yet.
    public func hiddenJobIDs(documentID: String, pairing: BridgePairing) throws -> Set<String> {
        try pairing.validate()
        guard bridgeValidID(documentID) else { throw BridgeError.invalidInput("文档 ID 无效") }
        return Set(try removedJobs().filter {
            $0.origin == pairing.origin && $0.backend == pairing.backend && $0.documentID == documentID
        }.map(\.jobID))
    }

    /// These candidates remain stored remotely; only the local copy was removed.
    public func locallyRemovedJobIDs(documentID: String, pairing: BridgePairing) throws -> Set<String> {
        try pairing.validate()
        guard bridgeValidID(documentID) else { throw BridgeError.invalidInput("文档 ID 无效") }
        return Set(try removedJobs().filter {
            !$0.deletedOnServer && $0.origin == pairing.origin && $0.backend == pairing.backend && $0.documentID == documentID
        }.map(\.jobID))
    }

    /// Explicitly show candidates still stored by this server again. Original local
    /// upload PNGs remain reclaimed; preview bytes are downloaded on demand.
    public func restoreLocalRemovals(documentID: String, pairing: BridgePairing) throws -> Set<String> {
        try pairing.validate()
        guard bridgeValidID(documentID) else { throw BridgeError.invalidInput("文档 ID 无效") }
        let pending = Set(try pendingDeletionRecords().filter {
            $0.origin == pairing.origin && $0.backend == pairing.backend
        }.map(\.job.jobId))
        let removed = try removedJobs()
        let restored = Set(removed.filter {
            !$0.deletedOnServer && $0.origin == pairing.origin && $0.backend == pairing.backend &&
            $0.documentID == documentID && !pending.contains($0.jobID)
        }.map(\.jobID))
        let remaining = removed.filter {
            !($0.origin == pairing.origin && $0.backend == pairing.backend && $0.documentID == documentID && restored.contains($0.jobID))
        }
        try bridgeJSON(RemovalIndex(version: 1, jobs: remaining)).write(to: directory.appendingPathComponent(".removed-jobs.json"), options: .atomic)
        return restored
    }

    /// Persist the user's confirmed deletion intent before issuing DELETE. A lost
    /// response or partial server cleanup must keep a retryable identity after restart.
    public func markPendingDeletion(_ job: BridgeJob, pairing: BridgePairing) throws {
        try validateFinishedJob(job, pairing: pairing)
        try validateLocalIdentity(job, pairing: pairing)
        var records = try pendingDeletionRecords()
        if let existing = records.first(where: { $0.origin == pairing.origin && $0.backend == pairing.backend && $0.job.jobId == job.jobId }) {
            guard existing.job.clientRequestId == job.clientRequestId, existing.job.source == job.source else { throw BridgeError.storageCorrupted }
            return
        }
        records.append(PendingDeletion(origin: pairing.origin, backend: pairing.backend, job: job))
        try writePendingDeletions(records)
    }

    public func pendingDeletions(documentID: String, pairing: BridgePairing) throws -> [BridgeJob] {
        try pairing.validate()
        guard bridgeValidID(documentID) else { throw BridgeError.invalidInput("文档 ID 无效") }
        return try pendingDeletionRecords().filter {
            $0.origin == pairing.origin && $0.backend == pairing.backend && $0.job.source.documentId == documentID
        }.map(\.job)
    }

    public func clearPendingDeletion(jobID: String, pairing: BridgePairing) throws {
        try pairing.validate()
        guard bridgeValidID(jobID) else { throw BridgeError.invalidInput("任务 ID 无效") }
        let records = try pendingDeletionRecords().filter {
            !($0.origin == pairing.origin && $0.backend == pairing.backend && $0.job.jobId == jobID)
        }
        try writePendingDeletions(records)
    }

    private func pendingDeletionRecords() throws -> [PendingDeletion] {
        let file = directory.appendingPathComponent(".pending-deletions.json")
        guard manager.fileExists(atPath: file.path) else { return [] }
        let index = try JSONDecoder().decode(PendingDeletionIndex.self, from: Data(contentsOf: file))
        guard index.version == 1 else { throw BridgeError.storageCorrupted }
        for record in index.jobs {
            let pairing = try BridgePairing(baseUrl: record.origin, accessToken: "validation-only", backend: record.backend)
            guard pairing.origin == record.origin else { throw BridgeError.storageCorrupted }
            try validateFinishedJob(record.job, pairing: pairing)
        }
        return index.jobs
    }

    private func writePendingDeletions(_ records: [PendingDeletion]) throws {
        try bridgeJSON(PendingDeletionIndex(version: 1, jobs: records)).write(to: directory.appendingPathComponent(".pending-deletions.json"), options: .atomic)
    }

    private func validateFinishedJob(_ job: BridgeJob, pairing: BridgePairing) throws {
        try pairing.validate()
        guard bridgeValidID(job.jobId), bridgeValidID(job.clientRequestId), bridgeValidID(job.source.documentId),
              job.state == .succeeded || job.state == .failed else { throw BridgeError.invalidInput("只能移除已结束且来源明确的生成任务") }
        guard job.backend == pairing.backend, job.isSimulation == (pairing.backend == "mock") else { throw BridgeError.wrongServer }
    }

    private func validateLocalIdentity(_ job: BridgeJob, pairing: BridgePairing) throws {
        let root = try folder(job.clientRequestId)
        if manager.fileExists(atPath: root.path) {
            do {
                guard let stored = try readSummary(requestID: job.clientRequestId) else { throw BridgeError.storageCorrupted }
                let original = stored.summary
                guard original.origin == pairing.origin, original.backend == pairing.backend else { throw BridgeError.wrongServer }
                guard original.jobID == job.jobId, job.source.matches(original.metadata),
                      job.workflowPreset == original.metadata.workflowPreset else { throw BridgeError.invalidResponse("任务与待清理的本地快照不一致") }
            } catch BridgeError.jobRemoved {
                guard try removedJobs().contains(where: {
                    $0.origin == pairing.origin && $0.backend == pairing.backend && $0.documentID == job.source.documentId &&
                    $0.requestID == job.clientRequestId && $0.jobID == job.jobId
                }) else { throw BridgeError.wrongServer }
            }
        }
    }

    /// Removes only a confirmed finished job. Omitting serverDeletion means local
    /// cleanup only; it never claims that the Windows files were reclaimed.
    /// Write the small tombstone first, then reclaim the immutable upload files.
    public func removeCompletedJob(_ job: BridgeJob, pairing: BridgePairing,
                                   serverDeletion: BridgeJobDeletion? = nil) throws {
        try validateFinishedJob(job, pairing: pairing)
        if let receipt = serverDeletion {
            guard receipt.jobID == job.jobId, receipt.origin == pairing.origin,
                  receipt.backend == pairing.backend else { throw BridgeError.wrongServer }
        }
        try validateLocalIdentity(job, pairing: pairing)
        var removed = try removedJobs()
        if let index = removed.firstIndex(where: {
            $0.origin == pairing.origin && $0.backend == pairing.backend && $0.documentID == job.source.documentId && $0.jobID == job.jobId
        }) {
            guard removed[index].requestID == job.clientRequestId else { throw BridgeError.storageCorrupted }
            removed[index].deletedOnServer = removed[index].deletedOnServer || serverDeletion != nil
        } else {
            removed.append(RemovedJob(origin: pairing.origin, backend: pairing.backend, documentID: job.source.documentId,
                                     requestID: job.clientRequestId, jobID: job.jobId, deletedOnServer: serverDeletion != nil))
        }
        try bridgeJSON(RemovalIndex(version: 1, jobs: removed)).write(to: directory.appendingPathComponent(".removed-jobs.json"), options: .atomic)
        try reclaimPayload(requestID: job.clientRequestId)
        if serverDeletion != nil { try clearPendingDeletion(jobID: job.jobId, pairing: pairing) }
    }

    private func removedPayloadFolder(requestID: String) -> URL {
        directory.appendingPathComponent(".removed-payload-" + requestID, isDirectory: true)
    }

    private func reclaimPayload(requestID: String) throws {
        let root = try folder(requestID)
        let reclaimed = removedPayloadFolder(requestID: requestID)
        if manager.fileExists(atPath: reclaimed.path) { try manager.removeItem(at: reclaimed) }
        if manager.fileExists(atPath: root.path) {
            // Rename as one filesystem operation before recursively removing files.
            // A crash during reclamation cannot leave a broken live submission.
            try manager.moveItem(at: root, to: reclaimed)
            try manager.removeItem(at: reclaimed)
        }
    }

    private func removedJobs() throws -> [RemovedJob] {
        let file = directory.appendingPathComponent(".removed-jobs.json")
        guard manager.fileExists(atPath: file.path) else { return [] }
        let index = try JSONDecoder().decode(RemovalIndex.self, from: Data(contentsOf: file))
        guard index.version == 1, index.jobs.allSatisfy({
            guard bridgeValidID($0.documentID), bridgeValidID($0.requestID), bridgeValidID($0.jobID),
                  let pairing = try? BridgePairing(baseUrl: $0.origin, accessToken: "validation-only", backend: $0.backend) else { return false }
            return pairing.origin == $0.origin
        }) else { throw BridgeError.storageCorrupted }
        return index.jobs
    }

    private struct SnapshotManifest: Codable {
        let documentID: String
        let revision: Int64
        let sha256: String
        // Earlier caches also contain origin/backend. Decode their archive unchanged;
        // a frozen document version is independent of its eventual backup destination.
    }

    /// Load before exporting: even ZIP timestamps or active-layer selection can change archive bytes.
    /// The caller explicitly selects the destination on each load. The returned upload stays
    /// bound to that pairing, while the immutable archive can be backed up to another service.
    public func loadSnapshot(documentID: String, revision: Int64, pairing: BridgePairing) throws -> BridgeSnapshotUpload? {
        try pairing.validate()
        let root = try snapshotFolder(documentID: documentID, revision: revision)
        guard manager.fileExists(atPath: root.path) else { return nil }
        let manifest = try JSONDecoder().decode(SnapshotManifest.self, from: Data(contentsOf: root.appendingPathComponent("snapshot.json")))
        let archive = try Data(contentsOf: root.appendingPathComponent("project.comp.zip"))
        guard manifest.documentID == documentID, manifest.revision == revision,
              manifest.sha256 == bridgeSHA256(archive) else { throw BridgeError.storageCorrupted }
        return BridgeSnapshotUpload(documentID: documentID, revision: revision, archive: archive, origin: pairing.origin, backend: pairing.backend)
    }

    public func prepareSnapshot(documentID: String, revision: Int64, archive: Data, pairing: BridgePairing) throws -> BridgeSnapshotUpload {
        try pairing.validate()
        guard !archive.isEmpty, archive.count <= 64 * 1024 * 1024 else { throw BridgeError.invalidInput("备份归档大小无效") }
        if let existing = try loadSnapshot(documentID: documentID, revision: revision, pairing: pairing) {
            guard existing.archive == archive else {
                throw BridgeError.submissionConflict
            }
            return existing
        }
        let destination = try snapshotFolder(documentID: documentID, revision: revision)
        try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staging = destination.deletingLastPathComponent().appendingPathComponent(".pending-" + UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: staging) }
        try archive.write(to: staging.appendingPathComponent("project.comp.zip"), options: .atomic)
        let manifest = SnapshotManifest(documentID: documentID, revision: revision, sha256: bridgeSHA256(archive))
        try bridgeJSON(manifest).write(to: staging.appendingPathComponent("snapshot.json"), options: .atomic)
        try manager.moveItem(at: staging, to: destination)
        guard let saved = try loadSnapshot(documentID: documentID, revision: revision, pairing: pairing) else { throw BridgeError.storageCorrupted }
        return saved
    }

    private func snapshotFolder(documentID: String, revision: Int64) throws -> URL {
        guard bridgeValidID(documentID), revision >= 0 else { throw BridgeError.invalidInput("备份文档或版本无效") }
        return directory.appendingPathComponent(".snapshots", isDirectory: true)
            .appendingPathComponent(documentID, isDirectory: true).appendingPathComponent(String(revision), isDirectory: true)
    }

    private func folder(_ requestID: String) throws -> URL {
        guard bridgeValidID(requestID) else { throw BridgeError.invalidInput("请求 ID 无效") }
        return directory.appendingPathComponent(requestID, isDirectory: true)
    }
}
