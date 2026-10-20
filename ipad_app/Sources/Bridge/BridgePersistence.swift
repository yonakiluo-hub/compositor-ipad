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

    public init(directory: URL) throws {
        self.directory = directory
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func prepare(metadata: BridgeJobMetadata, imagePNG: Data, maskPNG: Data,
                        pairing: BridgePairing) throws -> BridgeSubmission {
        try pairing.validate(); try metadata.validate()
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
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: root.appendingPathComponent("submission.json")))
        let metadataData = try Data(contentsOf: root.appendingPathComponent("metadata.json"))
        let image = try Data(contentsOf: root.appendingPathComponent("image.png"))
        let mask = try Data(contentsOf: root.appendingPathComponent("mask.png"))
        guard manifest.version == 1, bridgeSHA256(metadataData) == manifest.metadataSHA256,
              bridgeSHA256(image) == manifest.imageSHA256, bridgeSHA256(mask) == manifest.maskSHA256 else { throw BridgeError.storageCorrupted }
        let metadata = try JSONDecoder().decode(BridgeJobMetadata.self, from: metadataData)
        try metadata.validate()
        guard metadata.clientRequestId == requestID,
              manifest.jobID == nil || bridgeValidID(manifest.jobID!),
              manifest.lastJob == nil || (manifest.lastJob!.jobId == manifest.jobID && manifest.lastJob!.clientRequestId == requestID && manifest.lastJob!.source.matches(metadata)) else {
            throw BridgeError.storageCorrupted
        }
        return BridgeSubmission(metadata: metadata, imagePNG: image, maskPNG: mask, origin: manifest.origin,
                                backend: manifest.backend, jobID: manifest.jobID, lastJob: manifest.lastJob, metadataJSON: metadataData)
    }

    @discardableResult
    public func record(job: BridgeJob, for requestID: String) throws -> BridgeSubmission {
        let original = try load(requestID: requestID)
        guard job.clientRequestId == requestID, job.source.matches(original.metadata), job.backend == original.backend,
              job.workflowPreset == original.metadata.workflowPreset, bridgeValidID(job.jobId),
              original.jobID == nil || original.jobID == job.jobId else { throw BridgeError.invalidResponse("任务与本地快照不一致") }
        let file = try folder(requestID).appendingPathComponent("submission.json")
        var manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: file))
        manifest.jobID = job.jobId; manifest.lastJob = job
        try bridgeJSON(manifest).write(to: file, options: .atomic)
        return try load(requestID: requestID)
    }

    public func list(documentID: String? = nil) throws -> [BridgeSubmission] {
        let entries = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        return try entries.filter { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
            .map { try load(requestID: $0.lastPathComponent) }
            .filter { documentID == nil || $0.metadata.documentId == documentID }
            .sorted { $0.metadata.clientRequestId < $1.metadata.clientRequestId }
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
