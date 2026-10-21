import Foundation
import CryptoKit

public enum BridgeError: Error, LocalizedError, Equatable {
    case invalidPairing(String), invalidInput(String), incompatibleServer(String)
    case http(Int, String, String), invalidResponse(String), integrityFailure
    case submissionConflict, wrongServer, storageCorrupted, jobRemoved

    public var errorDescription: String? {
        switch self {
        case .invalidPairing(let reason): return "配对信息无效：\(reason)"
        case .invalidInput(let reason): return "提交内容无效：\(reason)"
        case .incompatibleServer(let reason): return "桥接服务不兼容：\(reason)"
        case .http(let status, let code, let message): return "桥接服务 \(status)（\(code)）：\(message)"
        case .invalidResponse(let reason): return "桥接响应无效：\(reason)"
        case .integrityFailure: return "下载校验失败，请重新下载原任务结果。"
        case .submissionConflict: return "请求已存在且内容不同；重试必须使用原始文件。"
        case .wrongServer: return "此任务属于另一台桥接服务，请恢复原配对后继续。"
        case .storageCorrupted: return "本地任务快照损坏，已停止重试以保护原请求。"
        case .jobRemoved: return "此生成任务已移除；需要再次生成时请创建新任务。"
        }
    }
}

public struct BridgePairing: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let baseUrl: String
    public let accessToken: String
    public let backend: String

    public init(protocolVersion: Int = 1, baseUrl: String, accessToken: String, backend: String) throws {
        self.protocolVersion = protocolVersion; self.baseUrl = baseUrl
        self.accessToken = accessToken; self.backend = backend
        try validate()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        baseUrl = try container.decode(String.self, forKey: .baseUrl)
        accessToken = try container.decode(String.self, forKey: .accessToken)
        backend = try container.decode(String.self, forKey: .backend)
        try validate()
    }

    public static func decode(_ data: Data) throws -> Self {
        let pairing = try JSONDecoder().decode(Self.self, from: data)
        try pairing.validate()
        return pairing
    }

    public func validate() throws {
        guard protocolVersion == 1, ["mock", "comfyui"].contains(backend) else {
            throw BridgeError.invalidPairing("仅支持 API v1 的 mock 或 comfyui 后端")
        }
        guard let parts = URLComponents(string: baseUrl),
              ["http", "https"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              parts.port == nil || (1...65535).contains(parts.port!), parts.url != nil else {
            throw BridgeError.invalidPairing("服务地址必须是 HTTP(S) origin，不能包含路径、凭据或查询参数")
        }
        guard !accessToken.isEmpty, accessToken.utf8.count <= 4096,
              accessToken.utf8.allSatisfy({ (33...126).contains($0) }) else {
            throw BridgeError.invalidPairing("令牌必须是不含空格和控制字符的 ASCII 文本")
        }
    }

    /// Canonical server identity excludes the token, which only belongs in Keychain.
    public var origin: String {
        var parts = URLComponents(string: baseUrl)!
        parts.scheme = parts.scheme?.lowercased(); parts.host = parts.host?.lowercased(); parts.path = ""
        if (parts.scheme == "http" && parts.port == 80) || (parts.scheme == "https" && parts.port == 443) { parts.port = nil }
        return parts.string!
    }
}

public struct BridgePixelSize: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int
    public init(width: Int, height: Int) { self.width = width; self.height = height }
}
public struct BridgeCropRect: Codable, Equatable, Sendable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
    public init(x: Int, y: Int, width: Int, height: Int) { self.x = x; self.y = y; self.width = width; self.height = height }
}
public struct BridgePreset: Codable, Equatable, Sendable {
    public let id: String
    public let technique: String
    public let nativeInpainting: Bool
    public let maskAppliedToOutput: Bool
    public let name: String?
    public let presetVersion: String?
    public let experimental: Bool?
    public let enabled: Bool?
    public let configured: Bool?
    public let error: BridgeServiceError?
    public let license: BridgePresetLicense?
    public let limits: BridgePresetLimits?
    public let qualification: BridgePresetQualification?

    private enum CodingKeys: String, CodingKey {
        case id, technique, nativeInpainting, maskAppliedToOutput, name, presetVersion,
             experimental, enabled, configured, error, license, limits, qualification
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        technique = try c.decode(String.self, forKey: .technique)
        nativeInpainting = try c.decode(Bool.self, forKey: .nativeInpainting)
        maskAppliedToOutput = try c.decode(Bool.self, forKey: .maskAppliedToOutput)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled)
        configured = try c.decodeIfPresent(Bool.self, forKey: .configured)
        let unavailable = enabled == false || configured == false
        // v0.2 deliberately includes broken, configured=false registry entries.
        // Their malformed optional descriptors must not hide a healthy default.
        func detail<T: Decodable>(_ type: T.Type, _ key: CodingKeys) throws -> T? {
            if unavailable { return try? c.decodeIfPresent(type, forKey: key) }
            return try c.decodeIfPresent(type, forKey: key)
        }
        name = try detail(String.self, .name)
        presetVersion = try detail(String.self, .presetVersion)
        experimental = try detail(Bool.self, .experimental)
        error = try detail(BridgeServiceError.self, .error)
        license = try detail(BridgePresetLicense.self, .license)
        limits = try detail(BridgePresetLimits.self, .limits)
        qualification = try detail(BridgePresetQualification.self, .qualification)
    }

    public var displayName: String { name ?? (id == "mock-paint-v1" ? "模拟染色 · 不执行 AI" : id) }
    /// Absent switches are the original v0.1 contract. Explicit false is never ignored.
    public var isAvailable: Bool { enabled != false && configured != false && maskAppliedToOutput && !nativeInpainting }
    public var unavailableReason: String? {
        if enabled == false { return "Windows 尚未开启" }
        if configured == false { return error?.message ?? "Windows 预设配置需要修复" }
        if !maskAppliedToOutput || nativeInpainting { return "此生成方式尚不受当前客户端支持" }
        return nil
    }
}
public struct BridgePresetLicense: Codable, Equatable, Sendable {
    public let id: String?
    public let url: String?
    public let use: String?
    public let scope: String?
    public let commercialUse: String?
    public let commercialLicenseRequired: Bool?

    public var summary: String {
        if use == "research_or_evaluation_only" || commercialLicenseRequired == true {
            return "仅供研究或评估；商业使用需另获模型许可"
        }
        if commercialUse == "permitted_subject_to_license" {
            return "遵守 \(id ?? "模型") 许可及相关依赖许可"
        }
        return id.map { "许可：" + $0 } ?? "服务未提供许可用途说明"
    }
}
public struct BridgePresetLimits: Codable, Equatable, Sendable {
    public let minimumInputSide: Int?
    public let maximumAspectRatio: Double?
    public let maxInputPixels: Int?
}
public struct BridgePresetQualification: Codable, Equatable, Sendable {
    public let installed: String?
    public let structuralPreflight: String?
    public let gpuSmoke: String?
    public let qualityAdmission: String?
}
public struct BridgeInputLimits: Equatable, Sendable {
    public let minimumSide: Int
    public let maximumAspectRatio: Double?
    public let maximumPixels: Int

    public func validate(width: Int, height: Int) throws {
        guard width >= minimumSide, height >= minimumSide else {
            throw BridgeError.invalidInput("此组合要求生成区域的短边至少 \(minimumSide) 像素")
        }
        guard width > 0, height > 0, width <= 30000, height <= 30000,
              width * height <= maximumPixels else {
            throw BridgeError.invalidInput("生成区域超过此组合的 \(maximumPixels) 像素限制，请缩小选区；本地画布不会被缩小")
        }
        if let maximumAspectRatio, Double(max(width, height)) / Double(min(width, height)) > maximumAspectRatio {
            throw BridgeError.invalidInput("生成区域长宽比超过此组合的 \(maximumAspectRatio):1 限制，请增加上下文")
        }
    }
}
public struct BridgeCapabilities: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let backend: String
    public let isSimulation: Bool
    public let presets: [BridgePreset]
    public let defaultPreset: String?
    public let maxInputPixels: Int
    public let maxImageBytes: Int
    public let minInputSide: Int
    public let maxInputAspectRatio: Double?
    public let maxSnapshotBytes: Int
    public let snapshotFormat: String
    public let progressTransport: String
    public let cancelSupported: Bool
    public let pairingScope: String
    public let resultAlphaMode: String
    /// Optional API v1 extension. Older bridges remain usable without server deletion.
    public let jobDeletionSupported: Bool

    private enum CodingKeys: String, CodingKey {
        case protocolVersion, backend, isSimulation, presets, defaultPreset, maxInputPixels, maxImageBytes,
             minInputSide, maxInputAspectRatio, maxSnapshotBytes, snapshotFormat,
             progressTransport, cancelSupported, pairingScope, resultAlphaMode, jobDeletionSupported
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        protocolVersion = try c.decode(Int.self, forKey: .protocolVersion)
        backend = try c.decode(String.self, forKey: .backend)
        isSimulation = try c.decode(Bool.self, forKey: .isSimulation)
        presets = try c.decode([BridgePreset].self, forKey: .presets)
        defaultPreset = try c.decodeIfPresent(String.self, forKey: .defaultPreset)
        maxInputPixels = try c.decode(Int.self, forKey: .maxInputPixels)
        maxImageBytes = try c.decode(Int.self, forKey: .maxImageBytes)
        minInputSide = try c.decode(Int.self, forKey: .minInputSide)
        maxInputAspectRatio = try c.decodeIfPresent(Double.self, forKey: .maxInputAspectRatio)
        maxSnapshotBytes = try c.decode(Int.self, forKey: .maxSnapshotBytes)
        snapshotFormat = try c.decode(String.self, forKey: .snapshotFormat)
        progressTransport = try c.decode(String.self, forKey: .progressTransport)
        cancelSupported = try c.decode(Bool.self, forKey: .cancelSupported)
        pairingScope = try c.decode(String.self, forKey: .pairingScope)
        resultAlphaMode = try c.decode(String.self, forKey: .resultAlphaMode)
        jobDeletionSupported = try c.decodeIfPresent(Bool.self, forKey: .jobDeletionSupported) ?? false
    }

    /// Do not silently choose an experimental alternative if the advertised default fails.
    public var defaultPresetID: String? { defaultPreset ?? presets.first?.id }
    public func preset(id: String) -> BridgePreset? { presets.first { $0.id == id } }
    public func inputLimits(for preset: BridgePreset) throws -> BridgeInputLimits {
        let minimumSide = max(minInputSide, preset.limits?.minimumInputSide ?? minInputSide)
        let maximumPixels = min(4_194_304, maxInputPixels, preset.limits?.maxInputPixels ?? maxInputPixels)
        let ratios = [maxInputAspectRatio, preset.limits?.maximumAspectRatio].compactMap { $0 }
        guard minimumSide > 0, minimumSide <= 30000, maximumPixels > 0,
              ratios.allSatisfy({ $0.isFinite && $0 >= 1 }),
              preset.limits?.minimumInputSide == nil || preset.limits!.minimumInputSide! > 0,
              preset.limits?.maxInputPixels == nil || preset.limits!.maxInputPixels! > 0 else {
            throw BridgeError.invalidResponse("预设的输入限制无效")
        }
        return BridgeInputLimits(minimumSide: minimumSide, maximumAspectRatio: ratios.min(), maximumPixels: maximumPixels)
    }
}
public struct BridgeBackendStatus: Decodable, Equatable, Sendable {
    public let ok: Bool
    public let backend: String
    public let isSimulation: Bool?
    public let presetId: String?
    public let technique: String?
    public let missingNodes: [String]?
    public let missingModels: [String]?
    public let invalidInputs: [String]?
    public let installed: Bool?
    public let structuralPreflight: Bool?
    public let gpuSmoke: String?
    public let qualityAdmission: String?
    public let executorHeld: Bool?
    public let error: BridgeServiceError?

    public var problem: String? {
        guard !ok else { return nil }
        let missing = (missingNodes ?? []) + (missingModels ?? []) + (invalidInputs ?? [])
        return error?.message ?? (missing.isEmpty ? "此组合尚未就绪，请检查 Windows" : "Windows 缺少：" + missing.joined(separator: "、"))
    }
}
public struct BridgeServiceError: Codable, Equatable, Sendable {
    public let code: String
    public let message: String
}
public struct BridgeJobMetadata: Codable, Equatable, Sendable {
    public let protocolVersion: Int
    public let clientRequestId: String
    public let documentId: String
    public let baseRevision: Int64
    public let sourceLayerIds: [String]
    public let canvasSize: BridgePixelSize
    public let cropRect: BridgeCropRect
    public let inputSize: BridgePixelSize
    public let colorSpace: String
    public let maskConvention: String
    public let workflowPreset: String
    public let prompt: String
    public let seed: Int64

    public init(clientRequestId: String = UUID().uuidString.lowercased(), documentId: String,
                baseRevision: Int64, sourceLayerIds: [String], canvasSize: BridgePixelSize,
                cropRect: BridgeCropRect, workflowPreset: String, prompt: String, seed: Int64) {
        protocolVersion = 1; self.clientRequestId = clientRequestId; self.documentId = documentId
        self.baseRevision = baseRevision; self.sourceLayerIds = sourceLayerIds; self.canvasSize = canvasSize
        self.cropRect = cropRect; inputSize = BridgePixelSize(width: cropRect.width, height: cropRect.height)
        colorSpace = "sRGB"; maskConvention = "white_edit_black_preserve"
        self.workflowPreset = workflowPreset; self.prompt = prompt; self.seed = seed
    }

    public func validate(capabilities: BridgeCapabilities? = nil) throws {
        guard protocolVersion == 1, bridgeValidID(clientRequestId), bridgeValidID(documentId),
              sourceLayerIds.count <= 256, sourceLayerIds.allSatisfy(bridgeValidID),
              baseRevision >= 0, seed >= 0, colorSpace == "sRGB", maskConvention == "white_edit_black_preserve",
              prompt.unicodeScalars.count <= 4000 else { throw BridgeError.invalidInput("metadata 字段超出协议范围") }
        let sizes = [canvasSize.width, canvasSize.height, inputSize.width, inputSize.height, cropRect.width, cropRect.height]
        guard sizes.allSatisfy({ (1...30000).contains($0) }), cropRect.x >= 0, cropRect.y >= 0,
              cropRect.x <= canvasSize.width - cropRect.width, cropRect.y <= canvasSize.height - cropRect.height,
              inputSize.width == cropRect.width, inputSize.height == cropRect.height,
              inputSize.width * inputSize.height <= min(capabilities?.maxInputPixels ?? 4_194_304, 4_194_304),
              try bridgeJSON(self).count <= 16384 else { throw BridgeError.invalidInput("裁切尺寸、坐标或 metadata 大小无效") }
        if let capabilities {
            guard let preset = capabilities.preset(id: workflowPreset), preset.isAvailable else {
                throw BridgeError.invalidInput("所选组合已关闭或配置有误，请重新检查连接并选择")
            }
            try capabilities.inputLimits(for: preset).validate(width: inputSize.width, height: inputSize.height)
            if !capabilities.isSimulation && prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw BridgeError.invalidInput("请输入生成提示词")
            }
        }
    }
}
public struct BridgeJobSource: Codable, Equatable, Sendable {
    public let documentId: String
    public let baseRevision: Int64
    public let sourceLayerIds: [String]
    public let canvasSize: BridgePixelSize
    public let cropRect: BridgeCropRect
    public let inputSize: BridgePixelSize
    public let colorSpace: String

    func matches(_ metadata: BridgeJobMetadata) -> Bool {
        documentId == metadata.documentId && baseRevision == metadata.baseRevision && sourceLayerIds == metadata.sourceLayerIds &&
        canvasSize == metadata.canvasSize && cropRect == metadata.cropRect && inputSize == metadata.inputSize && colorSpace == metadata.colorSpace
    }
}
public enum BridgeJobState: String, Codable, Sendable { case queued, running, succeeded, failed }
public struct BridgeResult: Codable, Equatable, Sendable {
    public let resultId: String
    public let url: String
    public let mimeType: String
    public let width: Int
    public let height: Int
    public let cropRect: BridgeCropRect
    public let colorSpace: String
    public let alphaMode: String
    public let maskApplied: Bool
    public let sha256: String
    public let bytes: Int
}
public struct BridgeJob: Codable, Equatable, Sendable {
    public let jobId: String
    public let clientRequestId: String
    public let state: BridgeJobState
    public let backend: String
    public let isSimulation: Bool
    public let createdAt: String
    public let updatedAt: String
    public let source: BridgeJobSource
    public let workflowPreset: String
    public let error: BridgeServiceError?
    public let results: [BridgeResult]
}

/// Created only after a matching authenticated deletion acknowledgement. The server
/// origin is carried locally so a pairing switch cannot clear another server's files.
public struct BridgeJobDeletion: Equatable, Sendable {
    public let jobID: String
    public let origin: String
    public let backend: String
}
public struct BridgeSnapshot: Codable, Equatable, Sendable {
    public let documentId: String
    public let revision: Int64
    public let sha256: String
    public let bytes: Int
    public let createdAt: String
    public let projectVersion: Int
}

func bridgeValidID(_ value: String) -> Bool {
    (1...128).contains(value.utf8.count) && value.utf8.allSatisfy {
        (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95
    }
}
func bridgeJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}
func bridgeSHA256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

/// Validates the wire PNG layout; the editor additionally decodes pixels before using them.
func bridgeValidatePNG(_ data: Data, size: BridgePixelSize, mask: Bool) throws {
    guard data.count >= 33, data.prefix(8) == Data([137,80,78,71,13,10,26,10]),
          data[8..<12] == Data([0,0,0,13]), data[12..<16] == Data("IHDR".utf8) else {
        throw BridgeError.invalidInput("文件不是有效 PNG")
    }
    func uint32(_ start: Int) -> Int { data[start..<start+4].reduce(0) { ($0 << 8) | Int($1) } }
    guard uint32(16) == size.width, uint32(20) == size.height, data[24] == 8,
          data[25] == (mask ? 0 : 6), data[26] == 0, data[27] == 0 else {
        throw BridgeError.invalidInput(mask ? "蒙版必须是同尺寸无 alpha 的 8 位灰度 PNG" : "图像必须是同尺寸的 8 位 RGBA PNG")
    }
    var offset = 8
    var imageDataSeen = false
    var endSeen = false
    while offset + 12 <= data.count {
        let length = uint32(offset)
        guard length <= data.count - offset - 12 else { throw BridgeError.invalidInput("PNG 数据不完整") }
        let type = String(data: data[offset+4..<offset+8], encoding: .ascii) ?? ""
        if type == "acTL" || (mask && ["iCCP", "tRNS"].contains(type)) {
            throw BridgeError.invalidInput("PNG 含有不支持的动画或蒙版颜色信息")
        }
        if type == "IDAT" { imageDataSeen = true }
        offset += length + 12
        if type == "IEND" { endSeen = length == 0 && offset == data.count; break }
    }
    guard imageDataSeen, endSeen else { throw BridgeError.invalidInput("PNG 缺少图像或结束数据") }
}
